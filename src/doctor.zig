//! `zigsaw doctor`: what in this machine, this zigsaw and its store would make
//! zigsaw fail, and what fixes each, in one report.
//!
//! It changes nothing. `main` runs it before the store is opened (which makes
//! the store's folders) and before a store from before 0.85 has its data
//! moved, and it takes no lock. It reads, and asks whether a lock is held
//! (`Store.isLocked`, as `ps` does), on lock files that are there. It never
//! calls what settles what it finds, though other commands find the same
//! things that way: `ps.live`, `hkcu.settleLeftovers`, `grants.settle*`,
//! `exports.repair`, `prune`, `updates.show`. Each finding names the command
//! that fixes it instead.
//!
//! A check that fails to find something out says so, as a note, and the
//! report goes on. What it can't tell about the network in a few seconds it
//! leaves (see `Probe`): `main` ends the process with ExitProcess, which ends
//! the threads still waiting.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const Registry = @import("Registry.zig");
const Sidecar = @import("Sidecar.zig");
const acl = @import("acl.zig");
const associations = @import("associations.zig");
const cloudfiles = @import("cloudfiles.zig");
const credentials = @import("credentials.zig");
const container = @import("container.zig");
const drive = @import("drive.zig");
const exports = @import("exports.zig");
const folders = @import("folders.zig");
const grants = @import("grants.zig");
const hkcu = @import("hkcu.zig");
const lazy = @import("lazy.zig");
const oci = @import("oci.zig");
const override = @import("override.zig");
const process = @import("process.zig");
const ps = @import("ps.zig");
const remote = @import("remote.zig");
const schedule = @import("schedule.zig");
const shortcuts = @import("shortcuts.zig");
const snapshot = @import("snapshot.zig");
const updates = @import("updates.zig");
const upgrade = @import("upgrade.zig");
const volumes = @import("volumes.zig");
const win32 = @import("win32.zig");
const options = @import("options");

pub const Options = struct {
    /// Leave out the network: the registries and the release.
    offline: bool = false,
    /// One installed app, to be told about at length.
    app: ?[]const u8 = null,
};

pub const Level = enum { ok, note, warning, problem };

/// The report, as it's written: sections of findings, each a line with its
/// level, and under some what fixes it.
pub const Report = struct {
    w: *Io.Writer,
    counts: std.EnumArray(Level, usize) = .initFill(0),
    sections: usize = 0,

    pub fn section(r: *Report, comptime fmt: []const u8, args: anytype) !void {
        if (r.sections > 0) {
            try r.w.writeAll("\n");
            // What's done shows while the rest is looked at.
            try r.w.flush();
        }
        r.sections += 1;
        try r.w.print(fmt ++ "\n", args);
    }

    pub fn add(r: *Report, level: Level, comptime fmt: []const u8, args: anytype) !void {
        r.counts.getPtr(level).* += 1;
        try r.w.print("  {s:<9}", .{@tagName(level)});
        try r.w.print(fmt ++ "\n", args);
    }

    /// What fixes the finding above it, on a line of its own.
    pub fn fix(r: *Report, comptime fmt: []const u8, args: anytype) !void {
        try r.w.print("           " ++ fmt ++ "\n", args);
    }

    /// The summary line; the exit code: 1 if anything is a problem.
    pub fn finish(r: *Report) !u32 {
        const problems = r.counts.get(.problem);
        const warnings = r.counts.get(.warning);
        try r.w.writeAll("\n");
        if (problems == 0 and warnings == 0) {
            try r.w.writeAll("Nothing wrong found.\n");
        } else if (problems == 0) {
            try r.w.print("{d} warning{s}.\n", .{ warnings, plural(warnings) });
        } else if (warnings == 0) {
            try r.w.print("{d} problem{s}.\n", .{ problems, plural(problems) });
        } else {
            try r.w.print("{d} problem{s}, {d} warning{s}.\n", .{ problems, plural(problems), warnings, plural(warnings) });
        }
        try r.w.flush();
        return if (problems > 0) 1 else 0;
    }
};

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

pub fn doctor(ctx: *Context, opts: Options) !u32 {
    var buf: [8 * 1024]u8 = undefined;
    var out = Context.stdout().writerStreaming(ctx.io, &buf);
    var d: Doctor = .{ .ctx = ctx, .opts = opts, .r = .{ .w = &out.interface } };
    return d.run() catch |err| switch (err) {
        // Nobody reads the rest, as with `zigsaw doctor | head`.
        error.WriteFailed => 1,
        else => |e| e,
    };
}

const Doctor = struct {
    ctx: *Context,
    opts: Options,
    r: Report,
    /// This zigsaw's file, and its folder.
    self: []const u8 = "",
    self_dir: []const u8 = "",
    /// Null when neither ZIGSAW_HOME nor LOCALAPPDATA says where it is.
    store: ?Store = null,
    /// Whether the store's folder is there.
    store_there: bool = false,
    /// The integrity level zigsaw runs at.
    rid: win32.DWORD = win32.SECURITY_MANDATORY_MEDIUM_RID,
    /// The store's command shims.
    shims: []const exports.Shim = &.{},
    /// The network's requests, going while the rest is looked at.
    registries: []const *Probe = &.{},
    release: ?*Probe = null,
    net_started: u64 = 0,
    /// Why the requests couldn't be started, if they couldn't.
    net_failed: ?anyerror = null,

    fn run(d: *Doctor) !u32 {
        const ctx = d.ctx;
        d.self = try win32.selfExePath(ctx.arena);
        d.self_dir = std.fs.path.dirname(d.self) orelse d.self;
        if (try Store.rootFrom(ctx.arena, ctx.env)) |root| {
            d.store = .{ .io = ctx.io, .root = root, .ledger_key = ctx.env.get("ZIGSAW_GRANTS_KEY") orelse @import("ledger.zig").default_key };
            ctx.store = d.store.?;
            d.store_there = isDir(ctx.io, root);
        }
        // First, so that they go on while the rest is looked at.
        if (!d.opts.offline) d.startNetwork() catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => d.net_failed = err,
        };

        try d.r.section("zigsaw {s}, {s}", .{ options.version, d.self });
        try d.check("Windows", d.windows());
        try d.check("its programs", d.companions());
        try d.check("PATH", d.paths());
        try d.check("its variables", d.variables());

        if (d.store) |s| {
            try d.r.section("The store, {s} ({s})", .{ s.root, if (shortcuts.isDefaultStore(ctx.env.get("LOCALAPPDATA"), s.root)) "your default one" else "from ZIGSAW_HOME" });
            try d.check("the store's place", d.storePlace());
            if (d.store_there) {
                try d.check("the store's labels", d.labels());
                try d.check("who owns the store", d.owners());
            }
            try d.check("your folders", d.userFolders());
            try d.check("the build drive", d.buildDrive());
            if (d.store_there) try d.check("contained builds", d.containedBuilds());
            if (d.store_there) {
                try d.check("data waiting to move", d.dataToMove());
                try d.check("runs going", d.runsGoing());

                try d.r.section("Left behind", .{});
                const before = d.findings();
                try d.check("runs that didn't end", d.staleRuns());
                try d.check("keys left in HKCU", d.hkcuKeys());
                try d.check("what runs were given", d.grantsLeft());
                try d.check("upgrades", d.upgradeLeftovers());
                try d.check("volume imports", d.imports());
                try d.check("rollbacks", d.swaps());
                try d.check("shortcuts and links", d.staleLinks());
                try d.check("the daily check", d.dailyCheck());
                if (d.findings() == before) try d.r.add(.ok, "nothing: no run, build, upgrade or deleted store left anything to put right", .{});

                try d.check("the apps", d.apps());
            }
        } else {
            try d.r.section("The store", .{});
            try d.r.add(.problem, "neither ZIGSAW_HOME nor LOCALAPPDATA is set, so zigsaw has no store", .{});
            try d.r.fix("set ZIGSAW_HOME to a folder for it", .{});
        }

        if (d.opts.offline) {
            try d.r.section("Network: not checked (--offline)", .{});
        } else {
            try d.r.section("Network", .{});
            if (d.net_failed) |err| try d.check("the network", err);
            try d.check("proxies", d.proxies());
            try d.check("the registries", d.registryAnswers());
            try d.check("the release", d.releaseAnswer());
            try d.check("logins", d.login());
        }

        return d.r.finish();
    }

    /// How many findings there are so far, other than ok ones.
    fn findings(d: *const Doctor) usize {
        return d.r.counts.get(.note) + d.r.counts.get(.warning) + d.r.counts.get(.problem);
    }

    /// Runs one check: what it couldn't find out is a note, and the report
    /// goes on.
    fn check(d: *Doctor, what: []const u8, result: anyerror!void) !void {
        result catch |err| switch (err) {
            error.WriteFailed, error.OutOfMemory => |e| return e,
            // Already said, on stderr.
            error.Failed => try d.r.add(.note, "couldn't check {s} (see the error above)", .{what}),
            else => try d.r.add(.note, "couldn't check {s}: {t}", .{ what, err }),
        };
    }

    // -----------------------------------------------------------------------
    // This zigsaw

    fn windows(d: *Doctor) !void {
        var v: std.os.windows.RTL_OSVERSIONINFOW = undefined;
        v.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);
        _ = std.os.windows.ntdll.RtlGetVersion(&v);
        var process_machine: u16 = 0;
        var native: u16 = win32.IMAGE_FILE_MACHINE_UNKNOWN;
        _ = win32.IsWow64Process2(win32.GetCurrentProcess(), &process_machine, &native);
        d.rid = try acl.integrityRid();
        const elevated = try isElevated();
        const facts = Facts{ .rid = d.rid, .elevated = elevated, .native = native };
        const as = if (elevated) "as administrator" else "not as administrator";
        try d.r.add(if (facts.fine()) .ok else .note, "Windows {d}.{d}.{d}, {s}; {s} integrity, {s}", .{ v.dwMajorVersion, v.dwMinorVersion, v.dwBuildNumber, machineName(native), integrityName(d.rid), as });
        if (native == win32.IMAGE_FILE_MACHINE_ARM64)
            try d.r.add(.note, "zigsaw is x64, and runs emulated on this ARM64 machine, which nobody has tried", .{});
        if (d.rid < win32.SECURITY_MANDATORY_MEDIUM_RID) {
            try d.r.add(.problem, "zigsaw runs at {s} integrity: it can't change its store, nor take back what runs were given", .{integrityName(d.rid)});
            try d.r.fix("start it from a terminal that isn't low integrity; if its file is labelled low, that's why (see below)", .{});
        }
        if (elevated) {
            try d.r.add(.warning, "zigsaw runs as administrator: what it makes then belongs to Administrators, which a zigsaw that isn't elevated can't change", .{});
            try d.r.fix("run zigsaw from a terminal that isn't elevated", .{});
        }

        if (d.ctx.env.get("ZIGSAW_ID")) |id|
            try d.r.add(.note, "this zigsaw was started inside a run of {s}; it looks at your own store, as you see it", .{id});

        var in_job: win32.BOOL = win32.FALSE;
        if (win32.IsProcessInJob(win32.GetCurrentProcess(), null, &in_job) != 0 and in_job != 0) {
            var info: win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};
            if (win32.QueryInformationJobObject(null, win32.JobObjectExtendedLimitInformation, &info, @sizeOf(@TypeOf(info)), null) != 0 and
                !mayBreakAway(info.BasicLimitInformation.LimitFlags))
                try d.r.add(.note, "this terminal's job keeps what zigsaw starts: detached runs (`run -d`) and lazy installs end with it", .{});
        }
    }

    /// The programs installed next to zigsaw.exe, each of which something needs.
    fn companions(d: *Doctor) !void {
        const arena = d.ctx.arena;
        var missing: usize = 0;
        for (upgrade.programs[0 .. upgrade.programs.len - 1]) |name| {
            const p = try std.fs.path.join(arena, &.{ d.self_dir, name });
            const code = try openForReading(arena, p);
            if (code == 0) continue;
            missing += 1;
            if (code == win32.ERROR_VIRUS_INFECTED or code == win32.ERROR_VIRUS_DELETED) {
                try d.r.add(.problem, "{s} is beside zigsaw, but Windows Security found a threat in it, so {s}", .{ name, whatNeeds(name) });
                try d.r.fix("if you trust this zigsaw, restore {s} in Windows Security's protection history", .{name});
            } else if (code == win32.ERROR_FILE_NOT_FOUND) {
                try d.r.add(.problem, "{s} isn't beside zigsaw, so {s}", .{ name, whatNeeds(name) });
                try d.r.fix("installing zigsaw again puts it back: {s}", .{upgrade.reinstall});
            } else {
                try d.r.add(.problem, "{s} can't be read: error {d} ({s}), so {s}", .{ name, code, win32.errorName(code), whatNeeds(name) });
            }
        }
        if (missing == 0) try d.r.add(.ok, "zigsaw-shim.exe, zigsaw-shimw.exe, zigsaw-relay.exe, zigsaw-host.exe and zigsaw-notify.exe are beside it", .{});
        if (d.store != null and !try upgrade.inStoreBin(d.ctx) and d.ctx.env.get("ZIGSAW_UPGRADE_FROM") == null)
            try d.r.add(.note, "it isn't in its store's bin, where zigsaw is installed, so `zigsaw upgrade` won't replace it", .{});
    }

    /// The store's bin on PATH: on the one your next terminal gets, and on
    /// this one; and what finds a command there first.
    fn paths(d: *Doctor) !void {
        const ctx = d.ctx;
        const arena = ctx.arena;
        const s = d.store orelse return;
        const bin = try s.path(arena, &.{"bin"});
        const shims = try exports.list(ctx);
        const here = ctx.env.get("PATH") orelse "";
        const saved = try savedPath(arena);
        const on_saved = if (saved) |p| exports.onPath(p, bin) else false;
        const on_here = exports.onPath(here, bin);
        if (on_saved) {
            try d.r.add(.ok, "{s} is on your PATH", .{bin});
            if (!on_here) try d.r.add(.note, "but not this terminal's: a new one finds the apps' commands", .{});
        } else if (shims.len == 0) {
            try d.r.add(.note, "{s} isn't on your PATH, where the apps' commands would be found", .{bin});
        } else {
            try d.r.add(if (on_here) .note else .warning, "{s} isn't on your PATH{s}, so the apps' commands aren't found by name", .{ bin, if (on_here) " (only this terminal's)" else "" });
            try d.r.fix("[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'User') + ';{s}', 'User')", .{bin});
            try d.r.fix("in PowerShell adds it, for terminals opened after", .{});
        }

        if (on_here and shims.len > 0) {
            for (try shadowed(ctx.io, arena, here, bin, ctx.env.get("PATHEXT"), shims)) |sh|
                try d.r.add(.warning, "{s} runs {s}, which comes before zigsaw's bin on PATH", .{ sh.name, sh.path });
        }
        if (try firstOnPath(ctx.io, arena, here, "zigsaw.exe")) |found| {
            if (!sameFile(ctx.io, arena, found, d.self))
                try d.r.add(.note, "`zigsaw` on this terminal's PATH is {s}, not this one", .{found});
        }
    }

    fn variables(d: *Doctor) !void {
        const env = d.ctx.env;
        for (env.keys(), env.values()) |name, value| {
            if (!std.ascii.startsWithIgnoreCase(name, "ZIGSAW_")) continue;
            const v = known(name) orelse {
                try d.r.add(.warning, "{s} isn't a variable zigsaw reads; a misspelt one?", .{name});
                continue;
            };
            switch (v.kind) {
                .setting => try d.r.add(.note, "{s}={s}: {s}", .{ name, value, v.says }),
                .secret => try d.r.add(.note, "{s} is set: {s}", .{ name, v.says }),
                // ZIGSAW_ID has its line above.
                .inside => if (!std.ascii.eqlIgnoreCase(name, "ZIGSAW_ID")) try d.r.add(.note, "{s}={s}: {s}", .{ name, value, v.says }),
                .testing => try d.r.add(.warning, "{s}={s}, as tests set it: {s}", .{ name, value, v.says }),
            }
        }
        if (env.get("ZIGSAW_UPGRADE_KEY") != null) {
            if (env.get("ZIGSAW_UPGRADE_FROM") != null)
                try d.r.add(.warning, "with ZIGSAW_UPGRADE_FROM and ZIGSAW_UPGRADE_KEY, releases signed with that key are trusted too", .{})
            else
                try d.r.add(.note, "ZIGSAW_UPGRADE_KEY does nothing without ZIGSAW_UPGRADE_FROM", .{});
        }
        if (env.get(remote.registry_var)) |registry| {
            if (!validRegistry(d.ctx.arena, registry)) {
                try d.r.add(.problem, "{s}={s} isn't a registry and a path in it, as ghcr.io/zigsaw-io is: apps named by id can't be installed", .{ remote.registry_var, registry });
                try d.r.fix("set it as <registry>[/<path>], or unset it for {s}", .{remote.default_registry});
            }
        }
    }

    // -----------------------------------------------------------------------
    // The store

    /// Its path, and the volume it's on.
    fn storePlace(d: *Doctor) !void {
        const ctx = d.ctx;
        const arena = ctx.arena;
        const s = d.store.?;
        if (!d.store_there)
            try d.r.add(.note, "it isn't there yet: the first command that needs it makes it", .{});
        const full = if (d.store_there) s.fullRoot(arena) else s.root;
        const vol = try volumeOf(arena, full);
        const shape = PathShape.of(full);
        if (vol.fine() and shape.fine())
            try d.r.add(.ok, "{s} on {s}, {d} characters long", .{ vol.file_system, vol.root, full.len })
        else
            try d.r.add(.note, "{s} on {s}, {d} characters long", .{ vol.file_system, vol.root, full.len });
        if (shape.too_long) {
            try d.r.add(.warning, "its path is {d} characters long: Rust builds fail past about {d}, as rustc starts its linker by a path that then passes 260", .{ full.len, PathShape.rust_limit });
            try d.r.fix("a store with a shorter path (ZIGSAW_HOME) builds them", .{});
        }
        if (shape.space)
            try d.r.add(.note, "its path has a space, which some builds split paths at (pkg-config's output, in GTK's)", .{});
        if (vol.remote)
            try d.r.add(.warning, "it's on a network drive: low and appcontainer runs, volume mounts and lazy installs may not work there", .{});
        if (!vol.acls) {
            try d.r.add(.problem, "{s} keeps no permissions: apps' files can't be protected, and low and appcontainer runs can't be sandboxed", .{vol.file_system});
            try d.r.fix("a store on an NTFS drive (ZIGSAW_HOME)", .{});
        } else if (!vol.reparse) {
            try d.r.add(.warning, "{s} has no links: volumes can't be mounted in apps' data", .{vol.file_system});
        }
        if (vol.acls and !std.ascii.eqlIgnoreCase(vol.file_system, "NTFS"))
            try d.r.add(.note, "lazy installs (`--lazy`) download whole layers on {s}: Windows' Cloud Files, which they use, needs NTFS", .{vol.file_system});
        if (d.store_there and cloudfiles.isSyncRoot(ctx.gpa, full))
            try d.r.add(.warning, "it's in a folder a sync app keeps (OneDrive's, say): lazy installs can't keep their files there", .{});
    }

    /// Low labels on the store or this zigsaw: what's started from either
    /// starts at low integrity.
    fn labels(d: *Doctor) !void {
        const arena = d.ctx.arena;
        const s = d.store.?;
        for ([_]struct { what: []const u8, path: []const u8 }{
            .{ .what = "the store", .path = s.root },
            .{ .what = "this zigsaw's file", .path = d.self },
        }) |t| {
            const rid = try acl.effectiveLabel(arena, t.path) orelse continue;
            if (rid >= win32.SECURITY_MANDATORY_MEDIUM_RID) continue;
            const labelled = try labelledAt(arena, t.path) orelse t.path;
            try d.r.add(.problem, "{s} is labelled {s} integrity{s}: programs started from it run so, and can't change the store", .{
                t.what, integrityName(rid), if (labelled.ptr == t.path.ptr) "" else try std.fmt.allocPrint(arena, ", from {s}", .{labelled}),
            });
            if (d.rid < win32.SECURITY_MANDATORY_MEDIUM_RID)
                try d.r.fix("icacls \"{s}\" /setintegritylevel medium, from a terminal that isn't low, takes it away", .{labelled})
            else
                try d.r.fix("`zigsaw permission-remove {s}` takes it away", .{labelled});
        }
    }

    /// The store's folders, and its apps' files, are to be the user's: an
    /// elevated zigsaw made them Administrators', which a zigsaw that isn't
    /// can't change, nor delete the files it protects.
    fn owners(d: *Doctor) !void {
        const ctx = d.ctx;
        const arena = ctx.arena;
        const s = d.store.?;
        var dirs: std.ArrayList([]const u8) = .empty;
        try dirs.append(arena, s.root);
        for ([_][]const u8{ "blobs", "refs", "deploy", "volumes", "bin", "tmp" }) |sub| try dirs.append(arena, try s.path(arena, &.{sub}));
        const deploy = try s.path(arena, &.{"deploy"});
        if (Io.Dir.cwd().openDir(ctx.io, deploy, .{ .iterate = true })) |opened| {
            var dir = opened;
            defer dir.close(ctx.io);
            var it = dir.iterate();
            while (try it.next(ctx.io)) |e| if (e.kind == .directory) try dirs.append(arena, try std.fs.path.join(arena, &.{ deploy, e.name }));
        } else |_| {}

        var foreign: usize = 0;
        var first: ?[]const u8 = null;
        var first_owner: []const u8 = "";
        for (dirs.items) |p| {
            const owner = try ownerOf(arena, p) orelse continue;
            if (owner.usable) continue;
            foreign += 1;
            if (first == null) {
                first = p;
                first_owner = owner.name;
            }
        }
        if (foreign == 0) {
            try d.r.add(.ok, "its folders and apps' files are yours", .{});
            return;
        }
        if (foreign == 1) {
            try d.r.add(.problem, "{s} belongs to {s}, as an elevated zigsaw makes it: zigsaw can't change it here", .{ first.?, first_owner });
        } else {
            try d.r.add(.problem, "{s} and {d} more of its folders belong to {s}, as an elevated zigsaw makes them: zigsaw can't change them here", .{ first.?, foreign - 1, first_owner });
        }
        try d.r.fix("icacls \"{s}\" /setowner %USERNAME% /T /C, from an elevated prompt, gives them back to you", .{s.root});
    }

    /// The user's folders that hold the store or this zigsaw: runs can't be
    /// given those (see `grants.Own`).
    fn userFolders(d: *Doctor) !void {
        const ctx = d.ctx;
        const s = d.store.?;
        const all = try folders.allHostPaths(ctx);
        // The first is the profile, which the default store is always in.
        for (all[@min(1, all.len)..]) |folder| {
            if (within(s.root, folder))
                try d.r.add(.note, "{s} holds the store, so runs can't be given that folder under low or appcontainer", .{folder});
            if (within(d.self, folder))
                try d.r.add(.note, "{s} holds this zigsaw, so runs can't be given that folder under low or appcontainer", .{folder});
        }
    }

    fn buildDrive(d: *Doctor) !void {
        const arena = d.ctx.arena;
        const target_w = try drive.query(arena) orelse return;
        const raw = try std.unicode.wtf16LeToWtf8Alloc(arena, target_w);
        const target = if (std.mem.startsWith(u8, raw, "\\??\\")) raw[4..] else raw;
        if (drive.isBuildRoot(raw)) {
            try d.r.add(.note, "{s} is {s}, a zigsaw build's: the next build replaces it, unless that build is still going", .{ drive.letter, target });
        } else {
            try d.r.add(.warning, "{s} is {s}, which zigsaw builds need: builds with build commands fail until it's freed", .{ drive.letter, target });
            try d.r.fix("`subst {s} /d` frees it, if subst made it", .{drive.letter});
        }
    }

    /// What builds found of running their commands in a container without
    /// the network (see container.zig). Doctor doesn't ask itself, which
    /// would make the container's profile; nothing if no build has asked.
    fn containedBuilds(d: *Doctor) !void {
        const seen = try container.recall(d.ctx) orelse return;
        const asked = if (seen.current) "" else "; another zigsaw or Windows build found that, and the next such build asks again";
        if (seen.verdict) |why| {
            try d.r.add(.note, "this Windows doesn't run build commands in a container ({s}): recipes that say \"contained\" build with only proxy variables keeping them off the network{s}", .{ why, asked });
        } else try d.r.add(.ok, "build commands of recipes that say \"contained\" run in a container, without the network{s}", .{asked});
    }

    /// Apps' data still in data\, as a zigsaw before 0.85 kept it: the next
    /// command but this one moves it (see volumes.adoptAll).
    fn dataToMove(d: *Doctor) !void {
        const ctx = d.ctx;
        const data = try d.store.?.path(ctx.arena, &.{"data"});
        var dir = Io.Dir.cwd().openDir(ctx.io, data, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => |e| return e,
        };
        defer dir.close(ctx.io);
        var count: usize = 0;
        var it = dir.iterate();
        while (try it.next(ctx.io)) |e| {
            if (e.kind == .directory and oci.isValidId(e.name)) count += 1;
        }
        if (count == 0) return;
        try d.r.add(.note, "the data of {d} app{s} waits in {s} to move into volumes\\, as zigsaw 0.85 keeps it", .{ count, plural(count), data });
        try d.r.fix("the next zigsaw command moves it; `zigsaw repair` then points the apps' commands there", .{});
    }

    /// Runs and builds going now hold what they were given, and may be
    /// changing the store as doctor reads it.
    fn runsGoing(d: *Doctor) !void {
        var going: usize = 0;
        for (try ps.allRecords(d.store.?, d.ctx.arena)) |seen| {
            if (!seen.gone) going += 1;
        }
        if (going > 0) try d.r.add(.note, "{d} run{s} or build{s} going (`zigsaw ps` lists them): what follows is as they leave it now", .{ going, plural(going), plural(going) });
        // A prune holds the store's lock alone; every other command shares it.
        const lock = try d.store.?.path(d.ctx.arena, &.{"lock"});
        if (try Store.exists(d.ctx.io, lock)) {
            if (try Store.tryLock(d.ctx.io, lock, .shared)) |l| l.release(d.ctx.io) else try d.r.add(.note, "zigsaw prune is deleting what no app needs as doctor reads the store", .{});
        }
    }

    // -----------------------------------------------------------------------
    // Left behind

    fn staleRuns(d: *Doctor) !void {
        for (try ps.allRecords(d.store.?, d.ctx.arena)) |seen| {
            if (!seen.gone) continue;
            const r = seen.record;
            try d.r.add(.warning, "{s} {d} of {s} ended without cleaning up after itself", .{ @tagName(r.kind), r.pid, r.id });
            try d.r.fix("`zigsaw ps` clears its record", .{});
        }
    }

    fn hkcuKeys(d: *Doctor) !void {
        for (try hkcu.leftovers(d.ctx, null)) |l| {
            try d.r.add(.warning, "HKCU\\{s} is {s} where a run of {s} that didn't end left it, in place of yours", .{ l.key, if (std.mem.eql(u8, l.state(), "moving")) "half moved" else "still", l.app() });
            try d.r.fix("`zigsaw repair` puts it back in {s}'s data, and yours back", .{l.app()});
        }
        const asides = try hkcu.orphanAsides(d.ctx.arena);
        if (asides.len > 0) {
            try d.r.add(.note, "{d} key{s} moved aside for runs that nothing will put back, as what {s} held is in HKCU again", .{ asides.len, plural(asides.len), if (asides.len == 1) "it" else "they" });
            try d.r.fix("`zigsaw repair` deletes {s}", .{if (asides.len == 1) "it" else "them"});
        }
    }

    fn grantsLeft(d: *Doctor) !void {
        for (try grants.lapsed(d.ctx)) |l| {
            try d.r.add(.warning, "{s}'s runs were given this, which nothing stands behind now: {f}", .{ l.id, grants.Line{ .grant = l.grant } });
            try d.r.fix("`zigsaw repair` takes it back", .{});
        }
        const left = try grants.leftovers(d.ctx);
        for (left.orphans) |e| {
            try d.r.add(.warning, "{s}, a store since deleted, left this for {s}: {f}", .{ e.store, e.id, grants.Line{ .grant = e.grant } });
            try d.r.fix("`zigsaw repair` takes it back", .{});
        }
        for (left.unexplained) |p| {
            try d.r.add(.warning, "{s} is labelled low, which no record explains", .{p});
            try d.r.fix("`zigsaw permission-remove {s}` removes it", .{p});
        }
    }

    fn upgradeLeftovers(d: *Doctor) !void {
        const left = try upgrade.leftovers(d.ctx.io, d.ctx.arena, d.self_dir);
        if (left.len == 0) return;
        try d.r.add(.note, "earlier upgrades left {s} beside zigsaw", .{try std.mem.join(d.ctx.arena, ", ", left)});
        try d.r.fix("the next `zigsaw upgrade` deletes those nothing runs", .{});
    }

    fn imports(d: *Doctor) !void {
        const arena = d.ctx.arena;
        for (try volumes.list(d.store.?, arena)) |v| {
            const left = volumes.importLeftovers(d.ctx.io, arena, v) catch continue;
            if (left.betweenRenames()) {
                try d.r.add(.problem, "an import into volume {s} stopped between its renames: the files it was replacing are in {s}, the archive's in {s}", .{ v.name, left.replaced[0], left.unpacked[0] });
                try d.r.fix("move the ones you want back into {s}, and delete both folders", .{v.path});
            } else if (left.unpacked.len + left.replaced.len > 0) {
                try d.r.add(.note, "an import into volume {s} that didn't finish left {s}", .{ v.name, if (left.unpacked.len > 0) left.unpacked[0] else left.replaced[0] });
                try d.r.fix("the volume's next import or export deletes it", .{});
            }
        }
    }

    fn swaps(d: *Doctor) !void {
        for (try snapshot.interruptedSwaps(d.store.?, d.ctx.arena)) |id| {
            try d.r.add(.warning, "a rollback of {s} stopped halfway, with its data set aside in snapshots\\", .{id});
            try d.r.fix("its next run, rollback or `zigsaw uninstall` puts it right", .{});
        }
    }

    fn staleLinks(d: *Doctor) !void {
        const installed = (try d.store.?.listRefs(d.ctx.arena)).len > 0;
        for (try shortcuts.stale(d.ctx)) |name| {
            try d.r.add(.warning, "the shortcut \"{s}\" runs a command no app has now", .{name});
            if (installed) try d.r.fix("`zigsaw repair` deletes it", .{}) else try d.r.fix("delete it from {s}", .{(try shortcuts.dir(d.ctx)).?});
        }
        for (try associations.staleSchemes(d.ctx)) |scheme| {
            try d.r.add(.warning, "{s}: links start a program in this store's apps directly, as an app set it up from inside a run", .{scheme});
            try d.r.fix("`zigsaw repair` removes it", .{});
        }
    }

    fn dailyCheck(d: *Doctor) !void {
        const ctx = d.ctx;
        const tasks = try schedule.listTasks(ctx);
        const mine = try schedule.taskName(ctx);
        var on = false;
        for (tasks) |t| {
            if (t.gone) {
                try d.r.add(.warning, "the daily check \"{s}\" is for {s}, a store since deleted", .{ t.name, t.store.? });
                try d.r.fix("`zigsaw repair` removes it", .{});
                continue;
            }
            if (!std.mem.eql(u8, t.name, mine)) continue;
            on = true;
            if (t.command) |c| if (!try Store.exists(ctx.io, c)) {
                try d.r.add(.problem, "the daily check starts {s}, which isn't there: it checks for nothing", .{c});
                try d.r.fix("`zigsaw updates on` points it at this zigsaw", .{});
            };
        }
        const s = try updates.summary(ctx);
        if (on and s.checked != 0) {
            const ago = Io.Timestamp.now(ctx.io, .real).toSeconds() - s.checked;
            if (ago > 3 * 24 * 60 * 60) try d.r.add(.note, "the daily check last looked for updates {f}", .{updates.Ago{ .seconds = ago }});
        }
        const waiting = s.apps + @intFromBool(s.zigsaw != null);
        if (waiting > 0) try d.r.add(.note, "{d} update{s} waiting, as the last check found: `zigsaw updates` lists {s}", .{ waiting, plural(waiting), if (waiting == 1) "it" else "them" });
    }

    // -----------------------------------------------------------------------
    // Apps

    fn apps(d: *Doctor) !void {
        const ctx = d.ctx;
        const arena = ctx.arena;
        const refs = try d.store.?.listRefs(arena);
        d.shims = try exports.list(ctx);
        if (d.opts.app) |id| {
            for (refs) |ref| if (std.ascii.eqlIgnoreCase(ref.id, id)) {
                try d.r.section("{s} {s}, from {s}", .{ ref.id, ref.version, ref.source orelse "a registry" });
                try d.check(ref.id, d.checkApp(ref, true));
                return;
            };
            try d.r.section("Apps", .{});
            try d.r.add(.note, "{s} isn't installed (`zigsaw list` lists the apps that are)", .{id});
            return;
        }
        try d.r.section("Apps", .{});
        if (refs.len == 0) return d.r.add(.note, "none are installed", .{});
        var fine: usize = 0;
        for (refs) |ref| {
            const before = d.findings();
            try d.check(ref.id, d.checkApp(ref, false));
            if (d.findings() == before) fine += 1;
        }
        try d.orphanShims(refs);
        if (fine == refs.len) {
            if (refs.len == 1)
                try d.r.add(.ok, "1 app: its image, files and commands are there", .{})
            else
                try d.r.add(.ok, "{d} apps: their images, files and commands are there", .{refs.len});
        } else if (fine > 0) {
            try d.r.add(.ok, "{d} other app{s}: {s} images, files and commands are there", .{ fine, plural(fine), if (fine == 1) "its" else "their" });
        }
    }

    /// One app: its image, files, commands, overrides and recipe. `detail`
    /// says what's fine too.
    fn checkApp(d: *Doctor, ref: Store.Ref, detail: bool) !void {
        const ctx = d.ctx;
        const arena = ctx.arena;
        const s = d.store.?;
        const what = try std.fmt.allocPrint(arena, "{s} {s}", .{ ref.id, ref.version });
        const again = try reinstallText(arena, ref);

        // The manifest and config, checked against their digests.
        const manifest_bytes = switch (try blobState(s, arena, ref.manifest)) {
            .ok => |b| b,
            else => |st| {
                try d.r.add(.problem, "{s}: its manifest, blob {s}, is {s}", .{ what, short(ref.manifest), st.word() });
                try d.r.fix("`zigsaw uninstall {s}`, then {s}, installs it again", .{ ref.id, again });
                return;
            },
        };
        const manifest = std.json.parseFromSliceLeaky(oci.Manifest, arena, manifest_bytes, .{ .ignore_unknown_fields = true }) catch {
            try d.r.add(.problem, "{s}: its manifest, blob {s}, isn't one zigsaw can read", .{ what, short(ref.manifest) });
            try d.r.fix("`zigsaw uninstall {s}`, then {s}, installs it again", .{ ref.id, again });
            return;
        };
        switch (try blobState(s, arena, manifest.config.digest)) {
            .ok => {},
            else => |st| {
                try d.r.add(.problem, "{s}: its config, blob {s}, is {s}", .{ what, short(manifest.config.digest), st.word() });
                try d.r.fix("`zigsaw uninstall {s}`, then {s}, installs it again", .{ ref.id, again });
                return;
            },
        }
        const image = try s.readImage(arena, ref.id, ref.manifest);
        if (detail) try d.r.add(.ok, "its image, {s}, is in the store", .{short(ref.manifest)});

        // Its layers, its runtimes' too: unpacked, being fetched, or there to unpack.
        var unpacked: usize = 0;
        for (manifest.layers) |l| {
            const hex = oci.digestHex(l.digest) orelse continue;
            if (try Store.exists(ctx.io, try s.deployPath(arena, l.digest)) and !try lazy.isLazy(s, arena, hex)) {
                unpacked += 1;
                continue;
            }
            if (try lazy.isLazy(s, arena, hex)) {
                const how = try lazy.describe(s, arena, .{ .config = manifest.config, .layers = &.{l} }) orelse "(fetching)";
                try d.r.add(.note, "{s}: a lazy install of layer {s} goes on {s}", .{ what, short(l.digest), how });
            } else if (try Store.exists(ctx.io, try s.blobPath(arena, hex))) {
                try d.r.add(.note, "{s}: layer {s} isn't unpacked; its next run unpacks it", .{ what, short(l.digest) });
            } else {
                try d.r.add(.problem, "{s}: layer {s} is neither unpacked nor in the store", .{ what, short(l.digest) });
                try d.r.fix("`zigsaw uninstall {s}`, then {s}, installs it again", .{ ref.id, again });
            }
        }
        if (detail and unpacked == manifest.layers.len) try d.r.add(.ok, "its files are unpacked: {d} layer{s}", .{ unpacked, plural(unpacked) });

        // Its commands: a shim each, that runs a zigsaw that's there, for this store.
        var commands: std.ArrayList([]const u8) = .empty;
        for (image.config.exports.map.keys()) |name| {
            const shim = findShim(d.shims, name) orelse {
                try d.r.add(.warning, "{s}: its command {s} has no shim in {s}", .{ what, name, try s.path(arena, &.{"bin"}) });
                try d.r.fix("`zigsaw repair` writes it", .{});
                continue;
            };
            if (!std.mem.eql(u8, shim.sidecar.app, ref.id)) {
                if (detail) try d.r.add(.note, "its command {s} is {s}'s, which has it too", .{ name, shim.sidecar.app });
                continue;
            }
            try commands.append(arena, name);
        }
        for (d.shims) |shim| {
            if (!std.mem.eql(u8, shim.sidecar.app, ref.id)) continue;
            try d.checkShim(what, shim, detail);
        }
        if (detail and commands.items.len > 0) try d.r.add(.ok, "its commands: {s}", .{try std.mem.join(arena, ", ", commands.items)});

        // What's saved for it, and the recipe it's built from.
        const saved = override.loadFor(s, arena, ref.id) catch |err| switch (err) {
            error.Failed => {
                try d.r.add(.problem, "{s}: its overrides can't be read (see the error above)", .{what});
                try d.r.fix("`zigsaw override --reset {s}` removes them", .{ref.id});
                return;
            },
            else => |e| return e,
        };
        for (saved.volumes) |value| switch (try volumes.parse(arena, value)) {
            .ok => |m| switch (m.source) {
                .name => |n| if (try volumes.find(s, arena, n) == null)
                    try d.r.add(.note, "{s}: its overrides mount volume {s}, which isn't there: its next run makes it", .{ what, n }),
                .path => |p| if (!isDir(ctx.io, p))
                    try d.r.add(.warning, "{s}: its overrides mount {s}, which isn't there: its runs fail until it is", .{ what, p }),
            },
            else => {},
        };
        if (ref.source) |src| if (isRecipePath(src) and !try Store.exists(ctx.io, src)) {
            try d.r.add(.note, "{s}: it was built from {s}, which isn't there now, so `zigsaw update` can't build it again", .{ what, src });
        };
    }

    fn checkShim(d: *Doctor, what: []const u8, shim: exports.Shim, detail: bool) !void {
        const ctx = d.ctx;
        const arena = ctx.arena;
        const s = d.store.?;
        const bin = try s.path(arena, &.{"bin"});
        const exe = try std.fmt.allocPrint(arena, "{s}\\{s}.exe", .{ bin, shim.name });
        if (!try Store.exists(ctx.io, exe)) {
            try d.r.add(.problem, "{s}: its command {s} has a {s} but no {s}.exe", .{ what, shim.name, Sidecar.extension, shim.name });
            try d.r.fix("`zigsaw repair` writes it", .{});
            return;
        }
        if (!sameFile(ctx.io, arena, shim.sidecar.home, s.root) and !std.os.windows.eqlIgnoreCaseWtf8(std.mem.trimEnd(u8, shim.sidecar.home, "\\/"), std.mem.trimEnd(u8, s.root, "\\/"))) {
            try d.r.add(.problem, "{s}: its command {s} runs it from another store, {s}", .{ what, shim.name, shim.sidecar.home });
            try d.r.fix("`zigsaw repair` points it at this one", .{});
            return;
        }
        if (!try Store.exists(ctx.io, shim.sidecar.zigsaw)) {
            try d.r.add(.problem, "{s}: its command {s} runs {s}, which isn't there", .{ what, shim.name, shim.sidecar.zigsaw });
            try d.r.fix("`zigsaw repair`, by the zigsaw you use now, points it at that one", .{});
            return;
        }
        // A copy of the shim beside the zigsaw it names, as `repair` writes it.
        const beside = try std.fs.path.join(arena, &.{ std.fs.path.dirname(shim.sidecar.zigsaw) orelse "", if (shim.sidecar.gui) "zigsaw-shimw.exe" else "zigsaw-shim.exe" });
        const want = Io.Dir.cwd().readFileAlloc(ctx.io, beside, arena, .limited(16 << 20)) catch return;
        const have = try Io.Dir.cwd().readFileAlloc(ctx.io, exe, arena, .limited(16 << 20));
        if (!std.mem.eql(u8, want, have)) {
            try d.r.add(.warning, "{s}: its command {s} isn't a copy of {s}", .{ what, shim.name, beside });
            try d.r.fix("`zigsaw repair` writes it again", .{});
        } else if (detail and !sameFile(ctx.io, arena, shim.sidecar.zigsaw, d.self)) {
            try d.r.add(.note, "its command {s} runs {s}, not this zigsaw", .{ shim.name, shim.sidecar.zigsaw });
        }
    }

    // -----------------------------------------------------------------------
    // Network

    /// The registries' API roots, the default one's and those of the
    /// registries installed apps came from, and the release's VERSION.
    fn startNetwork(d: *Doctor) !void {
        const ctx = d.ctx;
        const arena = ctx.arena;
        d.net_started = win32.GetTickCount64();
        var hosts: std.ArrayList(Registry.Reference) = .empty;
        const default = ctx.env.get(remote.registry_var) orelse remote.default_registry;
        if (validRegistry(arena, default)) try hosts.append(arena, try Registry.Reference.parse(try std.fmt.allocPrint(arena, "{s}/some.app", .{default})));
        if (d.store != null) for (try d.store.?.listRefs(arena)) |ref| {
            const src = ref.source orelse continue;
            if (isRecipePath(src) or hosts.items.len >= max_registries) continue;
            const r = Registry.Reference.parse(src) catch continue;
            const seen = for (hosts.items) |h| {
                if (std.ascii.eqlIgnoreCase(h.host, r.host)) break true;
            } else false;
            if (!seen) try hosts.append(arena, r);
        };
        var probes: std.ArrayList(*Probe) = .empty;
        for (hosts.items) |h| {
            const url = try std.fmt.allocPrint(arena, "{s}/v2/", .{try h.baseUrl(arena)});
            try probes.append(arena, try Probe.start(ctx, h.host, url, false, d.net_started));
        }
        d.registries = probes.items;
        const from = upgrade.releaseFrom(ctx.env);
        if (upgrade.isUrl(from))
            d.release = try Probe.start(ctx, "the release", try std.fmt.allocPrint(arena, "{s}/VERSION", .{from}), true, d.net_started);
    }

    /// The deadline every request has, from when they started.
    fn deadline(d: *const Doctor) u64 {
        return d.net_started + network_wait_ms;
    }

    fn proxies(d: *Doctor) !void {
        const ctx = d.ctx;
        const arena = ctx.arena;
        const env_proxy = ctx.env.get("HTTPS_PROXY") orelse ctx.env.get("ALL_PROXY");
        const system = try systemProxy(arena);
        if (env_proxy) |p| {
            try d.r.add(.note, "zigsaw reaches registries through the proxy {s} (HTTPS_PROXY)", .{p});
        } else if (system.server) |server| {
            try d.r.add(.warning, "Windows uses the proxy {s}, which zigsaw doesn't read: it goes to registries without it", .{server});
            try d.r.fix("HTTPS_PROXY=http://{s} has zigsaw use it too", .{server});
        } else if (system.script) |script| {
            try d.r.add(.note, "Windows finds its proxy by a script, {s}, which zigsaw doesn't read: if it needs a proxy, set HTTPS_PROXY", .{script});
        }
        if (ctx.env.get("NO_PROXY")) |hosts| if (env_proxy != null or ctx.env.get("HTTP_PROXY") != null)
            try d.r.add(.warning, "NO_PROXY is {s}, which zigsaw doesn't read: it reaches those hosts through the proxy too", .{hosts});
        for (d.registries) |p| {
            const ref = Registry.Reference.parse(try std.fmt.allocPrint(arena, "{s}/x", .{p.what})) catch continue;
            if (ref.isLocal() and (ctx.env.get("HTTP_PROXY") != null or ctx.env.get("ALL_PROXY") != null))
                try d.r.add(.warning, "{s} is on this machine, but zigsaw asks the proxy (HTTP_PROXY) for it, as it doesn't read NO_PROXY", .{p.what});
        }
    }

    fn registryAnswers(d: *Doctor) !void {
        const arena = d.ctx.arena;
        if (d.registries.len == 0) {
            try d.r.add(.note, "no registry to ask: {s} isn't one", .{remote.registry_var});
            return;
        }
        for (d.registries) |p| {
            const via = try d.viaProxy(p.url);
            const a = try registryAnswer(arena, p.what, if (p.wait(d.deadline())) p.result() else null, via, network_wait_ms / 1000);
            try d.r.add(a.level, "{s}", .{a.text});
            if (a.fix) |f| try d.r.fix("{s}", .{f});
        }
    }

    fn releaseAnswer(d: *Doctor) !void {
        const ctx = d.ctx;
        const arena = ctx.arena;
        const from = upgrade.releaseFrom(ctx.env);
        const version: []const u8 = if (d.release) |p| version: {
            const url = p.url;
            const via = try d.viaProxy(url);
            if (!p.wait(d.deadline())) {
                try d.r.add(.warning, "{s} didn't answer in {d} s{s}: zigsaw can't tell whether it's the latest", .{ url, network_wait_ms / 1000, via });
                return;
            }
            const res = p.result();
            if (res.err) |err| {
                try d.r.add(.warning, "{s} can't be reached{s}: {t}", .{ url, via, err });
                return;
            }
            if (res.status != 200) {
                try d.r.add(.warning, "{s} answered HTTP {d}: zigsaw can't tell whether it's the latest", .{ url, res.status });
                return;
            }
            break :version std.mem.trim(u8, res.body, " \t\r\n");
        } else version: {
            const file = try std.fs.path.join(arena, &.{ from, "VERSION" });
            const text = Io.Dir.cwd().readFileAlloc(ctx.io, file, arena, .limited(256)) catch |err| {
                try d.r.add(.warning, "{s} can't be read ({t}): `zigsaw upgrade` can't take releases from {s}", .{ file, err, from });
                return;
            };
            break :version std.mem.trim(u8, text, " \t\r\n");
        };
        if (std.SemanticVersion.parse(version)) |_| {} else |_| {
            try d.r.add(.warning, "the release's VERSION, from {s}, isn't a version: \"{s}\"", .{ from, version });
            return;
        }
        if (upgrade.isNewer(version)) {
            try d.r.add(.note, "zigsaw {s} is out; this is {s}", .{ version, upgrade.this_version });
            if (upgrade.applies(ctx)) try d.r.fix("`zigsaw upgrade` installs it", .{}) else try d.r.fix("{s} installs it", .{upgrade.reinstall});
        } else {
            try d.r.add(.ok, "the latest release is {s}{s}", .{ version, if (std.mem.eql(u8, version, upgrade.this_version)) ", this one" else "" });
        }
    }

    fn login(d: *Doctor) !void {
        const ctx = d.ctx;
        const arena = ctx.arena;
        const default = ctx.env.get(remote.registry_var) orelse remote.default_registry;
        if (!validRegistry(arena, default)) return;
        const host = try credentials.normalizeHost(arena, (try Registry.Reference.parse(try std.fmt.allocPrint(arena, "{s}/x", .{default}))).host);
        switch (try credentials.savedFor(ctx, host)) {
            .none => {},
            .environment => try d.r.add(.ok, "a login for {s} is in ZIGSAW_REGISTRY_USERNAME and ZIGSAW_REGISTRY_PASSWORD", .{host}),
            .credential_manager => |user| try d.r.add(.ok, "a login for {s} is saved, as {s} (`zigsaw remote-modify --login`)", .{ host, user }),
            .docker_config => try d.r.add(.ok, "a login for {s} is in Docker's config.json", .{host}),
            .docker_helper => |name| try d.r.add(.ok, "a login for {s} may be with docker-credential-{s}, as Docker's config says", .{ host, name }),
            .docker_unreadable => |p| try d.r.add(.warning, "Docker's config, {s}, can't be read: zigsaw goes on without the logins in it", .{p}),
        }
    }

    /// " (through the proxy X)", for what went wrong on the way to `url`: the
    /// proxy std's client takes for its scheme.
    fn viaProxy(d: *Doctor, url: []const u8) ![]const u8 {
        const env = d.ctx.env;
        const https = std.ascii.startsWithIgnoreCase(url, "https:");
        const p = (if (https) env.get("HTTPS_PROXY") else env.get("HTTP_PROXY")) orelse env.get("ALL_PROXY") orelse return "";
        return std.fmt.allocPrint(d.ctx.arena, " (through the proxy {s})", .{p});
    }

    /// Shims whose app isn't installed, which nothing deletes.
    fn orphanShims(d: *Doctor, refs: []const Store.Ref) !void {
        const bin = try d.store.?.path(d.ctx.arena, &.{"bin"});
        for (d.shims) |shim| {
            const installed = for (refs) |ref| {
                if (std.mem.eql(u8, ref.id, shim.sidecar.app)) break true;
            } else false;
            if (installed) continue;
            try d.r.add(.warning, "the command {s} is {s}'s, which isn't installed", .{ shim.name, shim.sidecar.app });
            try d.r.fix("delete {s}\\{s}.exe and {s}{s}", .{ bin, shim.name, shim.name, Sidecar.extension });
        }
    }
};

// ---------------------------------------------------------------------------
// The network

/// How long doctor waits for the network, all of it together.
const network_wait_ms = 5000;
/// Registries asked, the default one among them.
const max_registries = 4;

/// One request, on a thread of its own, which doctor waits for until a
/// deadline and then leaves. std's client can't be given a timeout on
/// Windows (a connect with one panics), and can't cancel a name's lookup, so
/// nothing stops the thread: it runs until it's done, or until the process
/// ends. Nothing frees a probe, as a thread left behind may still write it.
const Probe = struct {
    /// The registry's host, or "the release".
    what: []const u8,
    url: []const u8,
    /// Follow redirects and keep the body, as for the release's VERSION.
    follow: bool,
    io: Io,
    gpa: Allocator,
    env: *const std.process.Environ.Map,
    started: u64,
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),
    /// What came back, once `done`.
    answer: Answer = .{},

    const Answer = struct {
        status: u16 = 0,
        /// Whether a 401 said how to authenticate, as registries do.
        challenge: bool = false,
        body: []const u8 = "",
        err: ?anyerror = null,
    };

    fn start(ctx: *Context, what: []const u8, url: []const u8, follow: bool, started: u64) !*Probe {
        const p = try ctx.gpa.create(Probe);
        p.* = .{ .what = what, .url = url, .follow = follow, .io = ctx.io, .gpa = ctx.gpa, .env = ctx.env, .started = started };
        p.thread = try std.Thread.spawn(.{}, run, .{p});
        return p;
    }

    fn run(p: *Probe) void {
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        p.answer = p.get(arena_state.allocator()) catch |err| .{ .err = err };
        p.done.store(true, .release);
    }

    fn get(p: *Probe, arena: Allocator) !Answer {
        var client: std.http.Client = .{ .allocator = p.gpa, .io = p.io };
        defer client.deinit();
        try client.initDefaultProxies(arena, @constCast(p.env));
        if (p.follow) {
            var body: Io.Writer.Allocating = .init(arena);
            const status = try Registry.getTo(&client, p.url, &body.writer);
            return .{ .status = @backingInt(status), .body = body.written() };
        }
        var req = try client.request(.GET, try std.Uri.parse(p.url), .{ .redirect_behavior = .unhandled });
        defer req.deinit();
        try req.sendBodiless();
        var buf: [8 * 1024]u8 = undefined;
        const res = try req.receiveHead(&buf);
        var answer: Answer = .{ .status = @backingInt(res.head.status) };
        var it = res.head.iterateHeaders();
        while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "www-authenticate")) {
            answer.challenge = true;
        };
        return answer;
    }

    /// Waits for it until `until` (GetTickCount64), and says whether it's
    /// done. One that isn't is left to itself, never to be looked at again.
    fn wait(p: *Probe, until: u64) bool {
        const now = win32.GetTickCount64();
        const left: win32.DWORD = if (now >= until) 0 else @intCast(@min(until - now, std.math.maxInt(u31)));
        _ = win32.WaitForSingleObject(p.thread.getHandle(), left);
        if (p.done.load(.acquire)) {
            p.thread.join();
            return true;
        }
        p.thread.detach();
        return false;
    }

    fn result(p: *const Probe) Answer {
        return p.answer;
    }
};

const Said = struct { level: Level, text: []const u8, fix: ?[]const u8 = null };

/// What a registry's answer to /v2/ says: null if it didn't answer in time.
fn registryAnswer(arena: Allocator, host: []const u8, answer: ?Probe.Answer, via: []const u8, waited_s: u64) !Said {
    const a = answer orelse return .{
        .level = .problem,
        .text = try std.fmt.allocPrint(arena, "{s} didn't answer in {d} s{s}", .{ host, waited_s, via }),
        .fix = "pulls and pushes wait for it too: check the network, or the proxy",
    };
    if (a.err) |err| return switch (err) {
        error.UnknownHostName => .{
            .level = .problem,
            .text = try std.fmt.allocPrint(arena, "{s} isn't a name this machine finds (DNS){s}", .{ host, via }),
            .fix = "check the network, and the name",
        },
        error.ConnectionRefused => .{
            .level = .problem,
            .text = try std.fmt.allocPrint(arena, "{s} refused the connection{s}", .{ host, via }),
        },
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => .{
            .level = .problem,
            .text = try std.fmt.allocPrint(arena, "TLS with {s} failed{s}: its certificate isn't one Windows trusts, as when a proxy looks into TLS, or this machine's clock is wrong", .{ host, via }),
            .fix = "a proxy's certificate authority has to be among Windows' trusted roots",
        },
        else => .{
            .level = .problem,
            .text = try std.fmt.allocPrint(arena, "{s} can't be reached{s}: {t}", .{ host, via, err }),
        },
    };
    return switch (a.status) {
        200 => .{ .level = .ok, .text = try std.fmt.allocPrint(arena, "{s} answers", .{host}) },
        401 => if (a.challenge)
            .{ .level = .ok, .text = try std.fmt.allocPrint(arena, "{s} answers, and asks for a token as registries do", .{host}) }
        else
            .{ .level = .warning, .text = try std.fmt.allocPrint(arena, "{s} refuses its API without saying how to log in", .{host}) },
        407 => .{
            .level = .problem,
            .text = try std.fmt.allocPrint(arena, "the proxy wants a login{s}", .{via}),
            .fix = "HTTPS_PROXY=http://<user>:<password>@<proxy>:<port> gives it one",
        },
        404 => .{ .level = .problem, .text = try std.fmt.allocPrint(arena, "{s} answers /v2/ with HTTP 404: it isn't an OCI registry", .{host}) },
        300...399 => .{ .level = .warning, .text = try std.fmt.allocPrint(arena, "{s} redirects its API elsewhere (HTTP {d}): a network that wants a sign-in first?", .{ host, a.status }) },
        500...599 => .{ .level = .warning, .text = try std.fmt.allocPrint(arena, "{s} answered HTTP {d}: it may be down", .{ host, a.status }) },
        else => .{ .level = .warning, .text = try std.fmt.allocPrint(arena, "{s} answered its API with HTTP {d}", .{ host, a.status }) },
    };
}

/// Windows' own proxy for this user, which WinINet and WinHTTP programs
/// use, and zigsaw doesn't.
const SystemProxy = struct { server: ?[]const u8 = null, script: ?[]const u8 = null };

fn systemProxy(arena: Allocator) !SystemProxy {
    const Key = @import("regkey.zig").Key;
    const k = try Key.open(arena, win32.HKEY_CURRENT_USER, "Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings", win32.KEY_READ) orelse return .{};
    defer k.close();
    var out: SystemProxy = .{};
    if ((try k.getDword(arena, "ProxyEnable") orelse 0) != 0) out.server = try k.getString(arena, "ProxyServer");
    if (try k.getString(arena, "AutoConfigURL")) |url| if (url.len > 0) {
        out.script = url;
    };
    return out;
}

// ---------------------------------------------------------------------------
// What the checks are made of

const BlobState = union(enum) {
    ok: []const u8,
    missing,
    damaged,

    fn word(s: BlobState) []const u8 {
        return switch (s) {
            .ok => "there",
            .missing => "missing",
            .damaged => "damaged: its bytes aren't what its digest says",
        };
    }
};

/// A small blob (a manifest or config), read and checked against its digest,
/// saying nothing: what `Store.readBlob` does, for a look at it.
fn blobState(s: Store, arena: Allocator, digest: []const u8) !BlobState {
    const hex = oci.digestHex(digest) orelse return .damaged;
    const bytes = Io.Dir.cwd().readFileAlloc(s.io, try s.blobPath(arena, hex), arena, .limited(16 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        error.StreamTooLong => return .damaged,
        else => |e| return e,
    };
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(actual, .lower), hex)) return .damaged;
    return .{ .ok = bytes };
}

/// A digest as messages show it: "sha256:" and 12 of its digits.
fn short(digest: []const u8) []const u8 {
    return digest[0..@min(digest.len, "sha256:".len + 12)];
}

/// How the app is installed again: from its recipe, or its image.
fn reinstallText(arena: Allocator, ref: Store.Ref) ![]const u8 {
    const src = ref.source orelse return std.fmt.allocPrint(arena, "`zigsaw install {s}`", .{ref.id});
    return if (isRecipePath(src))
        std.fmt.allocPrint(arena, "`zigsaw build {s}`", .{src})
    else
        std.fmt.allocPrint(arena, "`zigsaw install {s}`", .{src});
}

/// Whether a ref's source is a recipe's path, not an image's reference.
fn isRecipePath(source: []const u8) bool {
    return std.fs.path.isAbsolute(source);
}

fn findShim(shims: []const exports.Shim, name: []const u8) ?exports.Shim {
    for (shims) |s| if (std.ascii.eqlIgnoreCase(s.name, name)) return s;
    return null;
}

const Facts = struct {
    rid: win32.DWORD,
    elevated: bool,
    native: u16,

    fn fine(f: Facts) bool {
        return f.rid == win32.SECURITY_MANDATORY_MEDIUM_RID and !f.elevated and f.native != win32.IMAGE_FILE_MACHINE_ARM64;
    }
};

fn integrityName(rid: win32.DWORD) []const u8 {
    if (rid < win32.SECURITY_MANDATORY_LOW_RID) return "untrusted";
    if (rid < win32.SECURITY_MANDATORY_MEDIUM_RID) return "low";
    if (rid < win32.SECURITY_MANDATORY_HIGH_RID) return "medium";
    if (rid < win32.SECURITY_MANDATORY_SYSTEM_RID) return "high";
    return "system";
}

fn machineName(native: u16) []const u8 {
    return switch (native) {
        win32.IMAGE_FILE_MACHINE_AMD64 => "x64",
        win32.IMAGE_FILE_MACHINE_ARM64 => "ARM64",
        else => "x64",
    };
}

fn mayBreakAway(limit_flags: win32.DWORD) bool {
    return limit_flags & (win32.JOB_OBJECT_LIMIT_BREAKAWAY_OK | win32.JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK) != 0;
}

fn isElevated() !bool {
    var token: ?win32.HANDLE = null;
    if (win32.OpenProcessToken(win32.GetCurrentProcess(), win32.TOKEN_QUERY, &token) == 0) return win32.lastErrorFail("OpenProcessToken");
    defer _ = win32.CloseHandle(token.?);
    var e: win32.TOKEN_ELEVATION = .{ .TokenIsElevated = 0 };
    var len: win32.DWORD = 0;
    if (win32.GetTokenInformation(token.?, win32.TokenElevation, &e, @sizeOf(win32.TOKEN_ELEVATION), &len) == 0) return win32.lastErrorFail("GetTokenInformation");
    return e.TokenIsElevated != 0;
}

/// What a program beside zigsaw.exe is for, as what goes wrong without it.
fn whatNeeds(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "zigsaw-shim.exe")) return "the apps' commands can't be written";
    if (std.mem.eql(u8, name, "zigsaw-shimw.exe")) return "the apps' shortcuts and GUI commands can't be written";
    if (std.mem.eql(u8, name, "zigsaw-relay.exe")) return "appcontainer runs can't serve their ports";
    if (std.mem.eql(u8, name, "zigsaw-host.exe")) return "--share=host has nothing to run";
    if (std.mem.eql(u8, name, "zigsaw-notify.exe")) return "the daily update check has nothing to start";
    return "something can't work";
}

/// 0 if the file opens for reading; else the Win32 error.
fn openForReading(arena: Allocator, path: []const u8) !win32.DWORD {
    const h = win32.CreateFileW(try win32.wide(arena, path), win32.GENERIC_READ, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE, null, win32.OPEN_EXISTING, 0, null);
    if (h == win32.INVALID_HANDLE_VALUE) {
        const code = win32.GetLastError();
        return if (code == win32.ERROR_PATH_NOT_FOUND) win32.ERROR_FILE_NOT_FOUND else code;
    }
    _ = win32.CloseHandle(h);
    return 0;
}

const Var = struct {
    name: []const u8,
    kind: enum {
        /// The user's to set.
        setting,
        /// The same, but not to be shown.
        secret,
        /// Set by zigsaw for what it starts.
        inside,
        /// Set by zigsaw's tests, which nobody else should.
        testing,
    },
    says: []const u8,
};

/// Every ZIGSAW_ variable zigsaw reads (tests/doctor.sh checks the list).
/// Those starting ZIGSAW_TEST_ are test hooks.
const variables_read = [_]Var{
    .{ .name = "ZIGSAW_HOME", .kind = .setting, .says = "the store is there" },
    .{ .name = "ZIGSAW_REGISTRY", .kind = .setting, .says = "apps named by id come from there" },
    .{ .name = "ZIGSAW_REGISTRY_USERNAME", .kind = .setting, .says = "the login for the default registry" },
    .{ .name = "ZIGSAW_REGISTRY_PASSWORD", .kind = .secret, .says = "the password for the default registry" },
    .{ .name = "ZIGSAW_UPLOAD_CHUNK_SIZE", .kind = .setting, .says = "pushes send large blobs in chunks of that size" },
    .{ .name = "ZIGSAW_LOOPBACK_EXEMPTION", .kind = .setting, .says = "whether appcontainer runs may reach this machine" },
    .{ .name = "ZIGSAW_KEPT_BUILDS_SIZE", .kind = .setting, .says = "what the builds kept may take together" },
    .{ .name = "ZIGSAW_ID", .kind = .inside, .says = "inside a run" },
    .{ .name = "ZIGSAW_SHORTCUT", .kind = .inside, .says = "started by a shortcut" },
    .{ .name = "ZIGSAW_BUILD", .kind = .inside, .says = "inside a build's command" },
    .{ .name = "ZIGSAW_GRANTS_KEY", .kind = .testing, .says = "what runs are given is recorded under that key, not zigsaw's own" },
    .{ .name = "ZIGSAW_CLASSES_KEY", .kind = .testing, .says = "file associations go under that key, not Software\\Classes" },
    .{ .name = "ZIGSAW_SHORTCUTS_DIR", .kind = .testing, .says = "shortcuts go there, not to the Start menu" },
    .{ .name = "ZIGSAW_TASK_NAME", .kind = .testing, .says = "the daily check's task has that name" },
    .{ .name = "ZIGSAW_USER_FOLDERS", .kind = .testing, .says = "apps get the folders there, not yours" },
    .{ .name = "ZIGSAW_SHIM_REPORT", .kind = .testing, .says = "shims write what they did there" },
    .{ .name = "ZIGSAW_NOTIFY_REPORT", .kind = .testing, .says = "update notices are written there, not shown" },
    .{ .name = "ZIGSAW_UPGRADE_FROM", .kind = .testing, .says = "`zigsaw upgrade` and the daily check take releases from there" },
    .{ .name = "ZIGSAW_UPGRADE_KEY", .kind = .testing, .says = "a key releases may be signed with" },
};

fn known(name: []const u8) ?Var {
    for (variables_read) |v| if (std.ascii.eqlIgnoreCase(v.name, name)) return v;
    if (std.ascii.startsWithIgnoreCase(name, "ZIGSAW_TEST_"))
        return .{ .name = name, .kind = .testing, .says = "a test hook changes what zigsaw does" };
    return null;
}

/// Whether ZIGSAW_REGISTRY names a registry, and a path in it, as
/// `remote.resolve` takes it.
fn validRegistry(arena: Allocator, registry: []const u8) bool {
    const ref = Registry.Reference.parse(std.fmt.allocPrint(arena, "{s}/some.app", .{registry}) catch return false) catch return false;
    _ = credentials.normalizeHost(arena, ref.host) catch return false;
    return true;
}

/// The PATH the user's next terminal gets: Windows' for a new sign-in.
fn savedPath(arena: Allocator) !?[]const u8 {
    return pathFromBlock(arena, try process.userEnvironmentBlock(arena));
}

fn pathFromBlock(arena: Allocator, block: []const u16) !?[]const u8 {
    var rest = block;
    while (rest.len > 0 and rest[0] != 0) {
        const end = std.mem.indexOfScalar(u16, rest, 0) orelse rest.len;
        const entry = try std.unicode.wtf16LeToWtf8Alloc(arena, rest[0..end]);
        if (entry.len > 5 and std.ascii.eqlIgnoreCase(entry[0..5], "PATH=")) return entry[5..];
        rest = rest[@min(end + 1, rest.len)..];
    }
    return null;
}

const Shadowed = struct { name: []const u8, path: []const u8 };

/// The apps' commands that a directory before `bin` on `path_var` has a
/// program of the same name in, which then runs instead.
fn shadowed(io: Io, arena: Allocator, path_var: []const u8, bin: []const u8, pathext: ?[]const u8, shims: []const exports.Shim) ![]const Shadowed {
    var names: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (shims) |s| try names.put(arena, try std.ascii.allocLowerString(arena, s.name), s.name);
    const exts = pathext orelse ".COM;.EXE;.BAT;.CMD";
    var found: std.ArrayList(Shadowed) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    const want = std.mem.trimEnd(u8, bin, "\\/");
    var it = std.mem.tokenizeScalar(u8, path_var, ';');
    while (it.next()) |raw| {
        const entry = std.mem.trimEnd(u8, std.mem.trim(u8, raw, " \""), "\\/");
        if (entry.len == 0) continue;
        if (std.os.windows.eqlIgnoreCaseWtf8(entry, want)) break;
        var dir = Io.Dir.cwd().openDir(io, entry, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var files = dir.iterate();
        while (files.next(io) catch null) |f| {
            if (f.kind == .directory) continue;
            const dot = std.mem.lastIndexOfScalar(u8, f.name, '.') orelse continue;
            if (!hasExt(exts, f.name[dot..])) continue;
            const stem = try std.ascii.allocLowerString(arena, f.name[0..dot]);
            const name = names.get(stem) orelse continue;
            if ((try seen.getOrPut(arena, stem)).found_existing) continue;
            try found.append(arena, .{ .name = name, .path = try std.fs.path.join(arena, &.{ entry, f.name }) });
        }
    }
    return found.items;
}

fn hasExt(pathext: []const u8, ext: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, pathext, ';');
    while (it.next()) |e| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, e, " "), ext)) return true;
    return false;
}

fn firstOnPath(io: Io, arena: Allocator, path_var: []const u8, file: []const u8) !?[]const u8 {
    var it = std.mem.tokenizeScalar(u8, path_var, ';');
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \"");
        if (entry.len == 0) continue;
        const p = try std.fs.path.join(arena, &.{ entry, file });
        if (Store.exists(io, p) catch false) return p;
    }
    return null;
}

fn sameFile(io: Io, arena: Allocator, a: []const u8, b: []const u8) bool {
    if (std.os.windows.eqlIgnoreCaseWtf8(a, b)) return true;
    const ra = Io.Dir.cwd().realPathFileAlloc(io, a, arena) catch return false;
    const rb = Io.Dir.cwd().realPathFileAlloc(io, b, arena) catch return false;
    return std.os.windows.eqlIgnoreCaseWtf8(ra, rb);
}

fn isDir(io: Io, p: []const u8) bool {
    const stat = Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return stat.kind == .directory;
}

/// Whether `path` is `dir` or in it.
fn within(path: []const u8, dir: []const u8) bool {
    const base = std.mem.trimEnd(u8, dir, "\\/");
    if (path.len < base.len or !std.os.windows.eqlIgnoreCaseWtf8(path[0..base.len], base)) return false;
    return path.len == base.len or path[base.len] == '\\' or path[base.len] == '/';
}

/// The nearest folder, from `path` up, with a low label of its own: where
/// `path`'s comes from.
fn labelledAt(arena: Allocator, path: []const u8) !?[]const u8 {
    var p: ?[]const u8 = path;
    while (p) |here| : (p = std.fs.path.dirname(here)) {
        const rid = acl.ownLabel(arena, here) catch return null;
        if (rid) |r| if (r < win32.SECURITY_MANDATORY_MEDIUM_RID) return here;
    }
    return null;
}

const Owner = struct {
    /// Whether this zigsaw can act as the owner: it's the user, or a group
    /// enabled in its token (Administrators, when elevated).
    usable: bool,
    name: []const u8,
};

fn ownerOf(arena: Allocator, path: []const u8) !?Owner {
    var sd: ?*anyopaque = null;
    var owner: ?win32.PSID = null;
    const rc = win32.GetNamedSecurityInfoW(try win32.wide(arena, path), win32.SE_FILE_OBJECT, win32.OWNER_SECURITY_INFORMATION, &owner, null, null, null, &sd);
    if (rc != 0) return null;
    defer _ = win32.LocalFree(sd);
    const sid = owner orelse return null;
    if (win32.EqualSid(sid, try acl.currentUserSid(arena)) != 0) return .{ .usable = true, .name = "you" };
    var member: win32.BOOL = win32.FALSE;
    const usable = win32.CheckTokenMembership(null, sid, &member) != 0 and member != 0;
    var text: ?[*:0]u16 = null;
    const name: []const u8 = if (win32.ConvertSidToStringSidW(sid, &text) != 0) named: {
        defer _ = win32.LocalFree(text);
        const s = try std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.span(text.?));
        break :named if (std.mem.eql(u8, s, "S-1-5-32-544")) "Administrators" else s;
    } else "someone else";
    return .{ .usable = usable, .name = name };
}

/// The volume a path is on, as far as its checks go.
const Volume = struct {
    root: []const u8,
    file_system: []const u8,
    acls: bool,
    reparse: bool,
    remote: bool,

    fn fine(v: Volume) bool {
        return v.acls and v.reparse and !v.remote and std.ascii.eqlIgnoreCase(v.file_system, "NTFS");
    }
};

fn volumeOf(arena: Allocator, path: []const u8) !Volume {
    const path_w = try win32.wide(arena, path);
    var root_buf: [520:0]u16 = @splat(0);
    if (win32.GetVolumePathNameW(path_w, &root_buf, root_buf.len) == 0) {
        // As on a subst drive: the drive's root, then.
        if (path_w.len < 3 or path_w[1] != ':') return win32.lastErrorFail("GetVolumePathNameW");
        @memcpy(root_buf[0..2], path_w[0..2]);
        root_buf[2] = '\\';
        root_buf[3] = 0;
    }
    const root_w = std.mem.sliceTo(&root_buf, 0);
    const root_z = try arena.dupeSentinel(u16, root_w, 0);
    var fs_buf: [64:0]u16 = @splat(0);
    var flags: win32.DWORD = 0;
    if (win32.GetVolumeInformationW(root_z, null, 0, null, null, &flags, &fs_buf, fs_buf.len) == 0)
        return win32.lastErrorFail("GetVolumeInformationW");
    return .{
        .root = try std.unicode.wtf16LeToWtf8Alloc(arena, root_w),
        .file_system = try std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.sliceTo(&fs_buf, 0)),
        .acls = flags & win32.FILE_PERSISTENT_ACLS != 0,
        .reparse = flags & win32.FILE_SUPPORTS_REPARSE_POINTS != 0,
        .remote = win32.GetDriveTypeW(root_z) == win32.DRIVE_REMOTE,
    };
}

/// What a store's path is like, for builds.
const PathShape = struct {
    too_long: bool,
    space: bool,

    /// rustc starts the Rust image's self-contained linker by its full path in
    /// the deployment, which CreateProcess caps at 260 (docs/gaps.md).
    const rust_limit = 100;

    fn of(path: []const u8) PathShape {
        return .{ .too_long = path.len > rust_limit, .space = std.mem.indexOfScalar(u8, path, ' ') != null };
    }

    fn fine(s: PathShape) bool {
        return !s.too_long and !s.space;
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test Report {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var r: Report = .{ .w = &w };
    try r.section("zigsaw {s}", .{"0.1.0"});
    try r.add(.ok, "fine", .{});
    try r.section("The store", .{});
    try r.add(.warning, "B: is {s}", .{"D:\\x"});
    try r.fix("`subst B: /d` frees it", .{});
    try r.add(.problem, "it's {s}", .{"broken"});
    try testing.expectEqual(@as(u32, 1), try r.finish());
    try testing.expectEqualStrings(
        \\zigsaw 0.1.0
        \\  ok       fine
        \\
        \\The store
        \\  warning  B: is D:\x
        \\           `subst B: /d` frees it
        \\  problem  it's broken
        \\
        \\1 problem, 1 warning.
        \\
    , w.buffered());
}

test "a report with only notes finds nothing wrong" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var r: Report = .{ .w = &w };
    try r.section("x", .{});
    try r.add(.note, "a note", .{});
    try testing.expectEqual(@as(u32, 0), try r.finish());
    try testing.expect(std.mem.endsWith(u8, w.buffered(), "\nNothing wrong found.\n"));
    var buf2: [256]u8 = undefined;
    var w2: Io.Writer = .fixed(&buf2);
    var r2: Report = .{ .w = &w2 };
    try r2.add(.warning, "a", .{});
    try r2.add(.warning, "b", .{});
    try testing.expectEqual(@as(u32, 0), try r2.finish());
    try testing.expect(std.mem.endsWith(u8, w2.buffered(), "\n2 warnings.\n"));
}

test known {
    try testing.expectEqual(.setting, known("ZIGSAW_HOME").?.kind);
    try testing.expectEqual(.setting, known("zigsaw_home").?.kind);
    try testing.expectEqual(.secret, known("ZIGSAW_REGISTRY_PASSWORD").?.kind);
    try testing.expectEqual(.testing, known("ZIGSAW_TEST_LAZY_MIN").?.kind);
    try testing.expectEqual(.inside, known("ZIGSAW_ID").?.kind);
    try testing.expect(known("ZIGSAW_REGSITRY") == null);
}

test validRegistry {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect(validRegistry(arena, "ghcr.io/zigsaw-io"));
    try testing.expect(validRegistry(arena, "localhost:5000"));
    try testing.expect(!validRegistry(arena, "not a registry"));
    try testing.expect(!validRegistry(arena, ""));
}

test PathShape {
    try testing.expect(PathShape.of("C:\\Users\\me\\AppData\\Local\\zigsaw").fine());
    try testing.expect(PathShape.of("D:\\a b").space);
    try testing.expect(PathShape.of("C:\\" ++ @import("testing.zig").repeat("x", 120)).too_long);
}

test pathFromBlock {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const block = std.unicode.utf8ToUtf16LeStringLiteral("A=1\x00Path=C:\\x;D:\\y\x00Z=2\x00\x00");
    try testing.expectEqualStrings("C:\\x;D:\\y", (try pathFromBlock(arena, block)).?);
    try testing.expect(try pathFromBlock(arena, std.unicode.utf8ToUtf16LeStringLiteral("A=1\x00\x00")) == null);
}

test hasExt {
    try testing.expect(hasExt(".COM;.EXE;.BAT;.CMD", ".exe"));
    try testing.expect(!hasExt(".COM;.EXE", ".dll"));
}

test within {
    try testing.expect(within("C:\\Users\\me\\Documents\\zs", "C:\\Users\\me\\Documents"));
    try testing.expect(within("C:\\Users\\me\\Documents", "c:\\users\\me\\documents\\"));
    try testing.expect(!within("C:\\Users\\me\\Documents2", "C:\\Users\\me\\Documents"));
}

test mayBreakAway {
    try testing.expect(mayBreakAway(0x1800));
    try testing.expect(mayBreakAway(0x0800));
    try testing.expect(!mayBreakAway(0x2000));
}

test integrityName {
    try testing.expectEqualStrings("low", integrityName(0x1000));
    try testing.expectEqualStrings("medium", integrityName(0x2000));
    try testing.expectEqualStrings("medium", integrityName(0x2100));
    try testing.expectEqualStrings("high", integrityName(0x3000));
}
