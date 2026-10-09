//! `zigsaw run`: starts an installed app in a clean environment.
//!
//! Every run gets:
//! - an environment built from scratch: PATH is the app's directories, then
//!   its runtimes', then the system directories; the runtimes' variables and
//!   then the app's are set; and the user profile folders (USERPROFILE,
//!   APPDATA, LOCALAPPDATA, TEMP) point into the app's data directory;
//! - the data directory as its working directory, unless the app has the
//!   "cwd" filesystem permission;
//! - a job object, so the whole process tree ends when the run ends.
//!
//! The `appcontainer` sandbox additionally runs the app under its AppContainer
//! identity, which enforces the filesystem and network permissions. The `low`
//! sandbox runs it at low integrity, with its data directory and the paths it
//! may write labelled low, which keeps it from writing anywhere else; reading
//! and the network stay open. The `soft` sandbox only shapes what the app
//! sees; it enforces nothing.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");
const acl = @import("acl.zig");
const aliases = @import("aliases.zig");
const appcontainer = @import("appcontainer.zig");
const oci = @import("oci.zig");
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const environment = @import("environment.zig");
const exports = @import("exports.zig");
const override = @import("override.zig");
const process = @import("process.zig");
const fail = Context.fail;
const note = Context.note;

pub const Options = struct {
    id: []const u8,
    args: []const []const u8 = &.{},
    /// Runs this executable instead of the app's command. Looked up in the
    /// app's PATH directories, then in System32.
    command: ?[]const u8 = null,
    /// From the command line. They go over the app's saved overrides.
    settings: override.Settings = .{},
};

/// Runs the app and returns its exit code.
pub fn run(ctx: *Context, opts: Options) !u32 {
    const io = ctx.io;
    const arena = ctx.arena;
    // Held while preparing the run, not while the app runs. The deployment
    // and any ephemeral data directory stay locked as in use until the end.
    // (On errors, zigsaw exits and that releases every lock.)
    const store_lock = try ctx.store.lock(arena, .shared);
    const image = try ctx.store.loadImage(arena, opts.id);
    const cfg = image.config;

    // Effective settings: the command line over the app's overrides, over the
    // app's own permissions.
    const saved = try override.load(ctx.store, arena, cfg.id);
    const settings = try override.Settings.merge(arena, saved, opts.settings);
    const sandbox = settings.sandbox orelse .soft;
    const network = settings.network orelse cfg.permissions.network;
    var grants: std.ArrayList(oci.FsGrant) = .empty;
    for ([_][]const []const u8{ cfg.permissions.filesystem, settings.filesystem }) |specs| {
        for (specs) |spec| try grants.append(arena, oci.parseFsGrant(spec) orelse
            return fail("invalid filesystem permission \"{s}\"", .{spec}));
    }
    var cwd_granted = false;
    for (grants.items) |g| {
        if (g.path == null) cwd_granted = true;
    }

    // Per-app writable state, laid out like a Windows user profile.
    const run_dir: ?Store.RunDir = if (settings.ephemeral orelse false) try ctx.store.makeRunDir(arena) else null;
    defer if (run_dir) |d| d.delete(ctx.store, arena);
    const app_aliases = try syncAliases(ctx, image);
    store_lock.release(io);
    const data_dir = if (run_dir) |d| d.path else try ctx.store.path(arena, &.{ "data", cfg.id });
    const profile: environment.Profile = try .init(arena, data_dir);
    for ([_][]const u8{ profile.roaming, profile.temp }) |dir| try Io.Dir.cwd().createDirPath(io, dir);

    const host_cwd = try std.process.currentPathAlloc(io, arena);
    const cwd = if (cwd_granted) host_cwd else profile.home;

    const cache_dir = try std.fs.path.join(arena, &.{ data_dir, "cache" });
    if (usesCache(cfg)) try Io.Dir.cwd().createDirPath(io, cache_dir);

    const system_root = ctx.env.get("SystemRoot") orelse "C:\\Windows";
    const runtimes = try runtimeDirs(arena, cfg, image.runtime_dirs, data_dir, cache_dir);
    const placeholders: oci.Placeholders = .{ .app = image.deploy_dir, .data = data_dir, .cache = cache_dir, .runtimes = runtimes.dirs };
    // The aliases first, as in builds, then the app's directories, then each
    // runtime's.
    var app_path: std.ArrayList([]const u8) = .empty;
    if (app_aliases) |a| try app_path.append(arena, a.dir);
    try app_path.appendSlice(arena, try environment.pathDirs(arena, placeholders, cfg.path));
    for (runtimes.own, cfg.runtimes.map.values()) |p, r| try app_path.appendSlice(arena, try environment.pathDirs(arena, p, r.path));
    const command = try resolveCommand(io, arena, placeholders, cfg, opts.command, app_path.items, system_root);
    const args = try std.mem.concat(arena, []const u8, &.{ command.args, opts.args });
    // Batch files run through cmd.exe; System32's, not ComSpec's.
    const exe = if (command.batch) try std.fmt.allocPrint(arena, "{s}\\System32\\cmd.exe", .{system_root}) else command.exe;
    const command_line = if (command.batch)
        process.buildBatchCommandLine(arena, exe, command.exe, args) catch |err| switch (err) {
            error.InvalidBatchArgument => return fail("{s} is a batch file, and cmd.exe can't pass it an argument with a line break or a NUL character", .{command.exe}),
            error.InvalidBatchScript => return fail("{s} can't be run as a batch file", .{command.exe}),
            error.OutOfMemory => |e| return e,
        }
    else
        try process.buildCommandLine(arena, exe, args);
    // The runtimes' variables first, so the app's win.
    var app_env: std.ArrayList(environment.Var) = .empty;
    for (runtimes.own, cfg.runtimes.map.values()) |p, r| try environment.expand(arena, &app_env, p, r.env);
    try environment.expand(arena, &app_env, placeholders, cfg.env);
    if (app_aliases) |a| try environment.set(arena, &app_env, "BB_OVERRIDE_APPLETS", a.names);
    const env = try environment.build(arena, ctx.env, .{
        .id = cfg.id,
        .profile = profile,
        .path = app_path.items,
        .system_root = system_root,
        .vars = app_env.items,
        .extra = settings.env,
    });

    if (ctx.verbose) {
        note("app      {s} {s} ({s})", .{ cfg.id, cfg.version, image.ref.manifest });
        for (cfg.runtimes.map.keys(), cfg.runtimes.map.values(), image.runtime_dirs) |alias, r, dir|
            note("runtime  {s}: {s} {s} ({s})", .{ alias, r.id, r.version, dir });
        if (app_aliases) |a| note("aliases  {s} ({s})", .{ a.names, a.dir });
        if (!saved.isEmpty()) note("override {f}", .{saved});
        note("sandbox  {t}, network {s}", .{ sandbox, if (network) "on" else "off" });
        note("exe      {s}", .{exe});
        if (command.batch) note("script   {s}", .{command.exe});
        note("cmdline  {s}", .{command_line});
        note("cwd      {s}", .{cwd});
        for (env.items) |kv| note("env      {s}={s}", .{ kv.name, kv.value });
    }

    var security: ?win32.SECURITY_CAPABILITIES = null;
    var token: ?win32.HANDLE = null;
    switch (sandbox) {
        .soft => if (ctx.verbose) {
            for (grants.items) |g| if (g.path) |p|
                note("note: soft sandbox doesn't enforce filesystem permissions; {s} is as reachable as any other path", .{p});
        },
        .low => token = try setUpLow(ctx, cfg.id, .{
            .data_dir = data_dir,
            .host_cwd = host_cwd,
            .grants = grants.items,
            .network = network,
        }),
        .appcontainer => security = try setUpAppContainer(ctx, cfg.id, .{
            .deploy_dir = image.deploy_dir,
            .runtime_dirs = image.runtime_dirs,
            .alias_dir = if (app_aliases) |a| a.dir else null,
            .data_dir = data_dir,
            .local_app_data = profile.local,
            .host_cwd = host_cwd,
            .grants = grants.items,
            .network = network,
        }),
    }

    const code = try process.spawn(arena, .{
        .exe = exe,
        .command_line = command_line,
        .env_block = try environment.encodeBlock(arena, env.items),
        .cwd = cwd,
        .security = if (security) |*s| s else null,
        .token = token,
    });
    // Commands the run installed, as `npm install -g` does, get shims. An
    // --ephemeral run's are gone with its data directory.
    if (run_dir == null and exports.hasCommandDirs(cfg)) exports.syncAfterRun(ctx, cfg.id);
    return code;
}

// ---------------------------------------------------------------------------
// Aliases

const AppAliases = struct {
    /// The store's aliases\<id>\, first on the run's PATH.
    dir: []const u8,
    /// For BB_OVERRIDE_APPLETS.
    names: []const u8,
};

/// Brings the shims of the app's aliases, and its runtimes', up to date in
/// the store (see aliases.zig); null if it has none. Runs with the store
/// lock held, so prune doesn't delete them meanwhile.
fn syncAliases(ctx: *Context, image: Store.Image) !?AppAliases {
    const arena = ctx.arena;
    const cfg = image.config;
    const dir = try ctx.store.aliasDir(arena, cfg.id);
    const resolved = try aliases.resolve(ctx, try aliasProviders(arena, image), .skip);
    if (resolved.len == 0) {
        // Left by a version of the app that had some.
        if (try Store.exists(ctx.io, dir)) {
            const l = try ctx.store.lockAliases(arena, cfg.id);
            defer l.release(ctx.io);
            Store.deleteTree(ctx.io, arena, dir) catch {};
        }
        return null;
    }
    const l = try ctx.store.lockAliases(arena, cfg.id);
    defer l.release(ctx.io);
    const start = ctx.now();
    const written = try aliases.sync(ctx, dir, resolved);
    if (written > 0) ctx.timed(start, "update {d} alias file(s)", .{written});
    return .{ .dir = dir, .names = try aliases.names(arena, resolved) };
}

/// The app first, then its runtimes in order: the first to have an alias
/// of a name wins it.
fn aliasProviders(arena: Allocator, image: Store.Image) ![]const aliases.Provider {
    const cfg = image.config;
    var out: std.ArrayList(aliases.Provider) = .empty;
    try out.append(arena, .{ .id = cfg.id, .dir = image.deploy_dir, .aliases = cfg.aliases });
    for (cfg.runtimes.map.values(), image.runtime_dirs) |r, dir| try out.append(arena, .{ .id = r.id, .dir = dir, .aliases = r.aliases });
    return out.items;
}

test aliasProviders {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const digest = "sha256:" ++ "a" ** 64;
    var cfg: oci.AppConfig = .{ .id = "app", .version = "1", .command = "x.exe" };
    try cfg.runtimes.map.put(arena, "b", .{ .id = "rt.b", .version = "1", .image = digest, .layer = digest });
    try cfg.runtimes.map.put(arena, "a", .{ .id = "rt.a", .version = "1", .image = digest, .layer = digest });
    const image: Store.Image = .{
        .ref = .{ .id = "app", .version = "1", .manifest = digest },
        .manifest = .{ .config = .{ .mediaType = "", .digest = digest, .size = 0 }, .layers = &.{} },
        .config = cfg,
        .deploy_dir = "D:\\app",
        .runtime_dirs = &.{ "D:\\b", "D:\\a" },
    };
    const p = try aliasProviders(arena, image);
    try std.testing.expectEqual(3, p.len);
    for ([_][]const u8{ "app", "rt.b", "rt.a" }, [_][]const u8{ "D:\\app", "D:\\b", "D:\\a" }, p) |id, dir, got| {
        try std.testing.expectEqualStrings(id, got.id);
        try std.testing.expectEqualStrings(dir, got.dir);
    }
}

// ---------------------------------------------------------------------------
// AppContainer

const AppContainerSetup = struct {
    deploy_dir: []const u8,
    runtime_dirs: []const []const u8,
    /// The app's alias shims, if it has aliases.
    alias_dir: ?[]const u8,
    data_dir: []const u8,
    /// The run's LOCALAPPDATA, in its data directory.
    local_app_data: []const u8,
    host_cwd: []const u8,
    grants: []const oci.FsGrant,
    network: bool,
};

fn setUpAppContainer(ctx: *Context, id: []const u8, setup: AppContainerSetup) !win32.SECURITY_CAPABILITIES {
    const arena = ctx.arena;
    const profile = try appcontainer.Profile.ensure(arena, id);
    // In an AppContainer, Windows' temporary directory isn't TEMP but the
    // container's own, under LOCALAPPDATA, which is in the data directory
    // here. Programs that ask Windows for it (GetTempPath2), as Go's and
    // Rust's standard libraries do, need it to exist.
    try Io.Dir.cwd().createDirPath(ctx.io, try std.fs.path.join(arena, &.{ setup.local_app_data, "Packages", profile.name, "AC", "Temp" }));

    const Grant = struct { path: []const u8, access: acl.Access, host: bool };
    var wanted: std.ArrayList(Grant) = .empty;
    try wanted.append(arena, .{ .path = setup.deploy_dir, .access = .read_execute, .host = false });
    for (setup.runtime_dirs) |dir| try wanted.append(arena, .{ .path = dir, .access = .read_execute, .host = false });
    if (setup.alias_dir) |dir| try wanted.append(arena, .{ .path = dir, .access = .read_execute, .host = false });
    try wanted.append(arena, .{ .path = setup.data_dir, .access = .full, .host = false });
    for (setup.grants) |g| try wanted.append(arena, .{
        .path = g.path orelse setup.host_cwd,
        .access = if (g.read_only) .read_execute else .full,
        .host = true,
    });

    for (wanted.items) |w| {
        // Record host grants before changing anything, so `zigsaw rm` can undo
        // them even if a later step fails.
        if (w.host) try ctx.store.recordGrant(arena, id, .{ .kind = .appcontainer, .path = w.path });
        // Access goes to the app's capability. What zigsaw granted the
        // profile's package SID before goes in the same change: on the host,
        // the app's own; in the store, any app's.
        const old: acl.Revoke = if (w.host) .{ .sids = &.{profile.sid} } else .package_sids;
        const start = Io.Timestamp.now(ctx.io, .awake);
        const changed = try acl.grant(arena, w.path, profile.capability, w.access, old);
        if (changed and (w.host or ctx.verbose)) {
            note("granted {s} {t} access to {s} ({d} ms)", .{
                profile.name, w.access, w.path, start.untilNow(ctx.io, .awake).toMilliseconds(),
            });
        }
    }

    var caps: std.ArrayList(win32.SID_AND_ATTRIBUTES) = .empty;
    try caps.append(arena, .{ .Sid = profile.capability, .Attributes = win32.SE_GROUP_ENABLED });
    if (setup.network) {
        for ([_][]const u8{ appcontainer.capability.internet_client, appcontainer.capability.private_network_client_server }) |s| {
            try caps.append(arena, .{ .Sid = try appcontainer.sidFromString(arena, s), .Attributes = win32.SE_GROUP_ENABLED });
        }
    }
    return .{
        .AppContainerSid = profile.sid,
        .Capabilities = caps.items.ptr,
        .CapabilityCount = @intCast(caps.items.len),
    };
}

// ---------------------------------------------------------------------------
// Low integrity

const LowSetup = struct {
    data_dir: []const u8,
    host_cwd: []const u8,
    grants: []const oci.FsGrant,
    network: bool,
};

/// Labels the data directory and the host paths the app may write low
/// integrity, and returns the token the app runs with.
fn setUpLow(ctx: *Context, id: []const u8, setup: LowSetup) !win32.HANDLE {
    const arena = ctx.arena;
    // Before iteration 9, AppContainer runs granted the app's package SID
    // access, which keeps low-integrity processes out (see appcontainer.zig).
    // The app's next AppContainer run grants its capability instead.
    const package = try appcontainer.packageSid(arena, id);
    _ = try acl.revoke(arena, setup.data_dir, .package_sids);
    _ = try acl.labelLow(arena, setup.data_dir);

    for (setup.grants) |g| {
        const p = g.path orelse setup.host_cwd;
        _ = try acl.revoke(arena, p, .{ .sids = &.{package} });
        // Low integrity reads what the user can.
        if (g.read_only) continue;
        if (labelRefusal(p, ctx.env.get("USERPROFILE"))) |why| {
            // The app's own permissions can't be taken back, only added to.
            const instead = if (g.path == null) "run it from a directory inside it" else "grant a directory inside it, or read-only access (:ro)";
            return fail("--sandbox=low won't label {s} low integrity: {s}, and every low-integrity process could then write anywhere in it; {s}", .{ p, why, instead });
        }
        const label: Store.Grant = .{ .kind = .low, .path = p };
        if (try acl.ownLabel(arena, p)) |rid| if (rid <= win32.SECURITY_MANDATORY_LOW_RID) {
            // Labelled for another app's runs: this app's need it too, so
            // removing that app keeps it. A label that zigsaw didn't give
            // stays when the app goes.
            if (try ctx.store.grantedToOthers(arena, id, label)) try ctx.store.recordGrant(arena, id, label);
            continue;
        };
        // Recorded first, so `zigsaw rm` can undo it even if a later step fails.
        try ctx.store.recordGrant(arena, id, label);
        const start = Io.Timestamp.now(ctx.io, .awake);
        if (try acl.labelLow(arena, p))
            note("labelled {s} low integrity ({d} ms)", .{ p, start.untilNow(ctx.io, .awake).toMilliseconds() });
    }
    if (ctx.verbose) {
        note("note: low sandbox doesn't keep the app from reading what you can", .{});
        if (!setup.network) note("note: low sandbox doesn't enforce network permissions", .{});
    }
    try acl.letChildrenQueryUs(arena);
    return process.lowIntegrityToken(arena);
}

/// Why zigsaw won't label `path` low for a run, if it won't: it's a drive's
/// root, the user's profile, or a directory the profile is in.
fn labelRefusal(path: []const u8, user_profile: ?[]const u8) ?[]const u8 {
    const p = trimSeparators(path);
    if (std.fs.path.dirnameWindows(p) == null) return "it's the root of a drive";
    const profile = trimSeparators(user_profile orelse return null);
    if (profile.len < p.len or !eqlPathPrefix(profile[0..p.len], p)) return null;
    if (profile.len == p.len) return "it's your user profile";
    if (profile[p.len] == '\\' or profile[p.len] == '/') return "your user profile is in it";
    return null;
}

fn trimSeparators(path: []const u8) []const u8 {
    return std.mem.trimEnd(u8, path, "\\/");
}

/// Equal ignoring ASCII case, with '/' and '\' alike.
fn eqlPathPrefix(a: []const u8, b: []const u8) bool {
    for (a, b) |x, y| {
        const sx = x == '/' or x == '\\';
        const sy = y == '/' or y == '\\';
        if (sx and sy) continue;
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

test labelRefusal {
    const home = "C:\\Users\\Ann";
    for ([_][]const u8{ "C:\\", "C:", "D:\\", "d:/", "\\\\server\\share\\" }) |root|
        try std.testing.expectEqualStrings("it's the root of a drive", labelRefusal(root, home).?);
    try std.testing.expectEqualStrings("it's your user profile", labelRefusal("c:\\users\\ann\\", home).?);
    try std.testing.expectEqualStrings("it's your user profile", labelRefusal("C:/Users/Ann", home ++ "\\").?);
    try std.testing.expectEqualStrings("your user profile is in it", labelRefusal("C:\\Users", home).?);
    for ([_][]const u8{ "C:\\Users\\Ann\\src", "C:\\Users\\Anna", "C:\\Users\\An", "D:\\src", "\\\\server\\share\\dir" }) |ok|
        try std.testing.expectEqual(null, labelRefusal(ok, home));
    try std.testing.expectEqual(null, labelRefusal("C:\\Users", null));
}

// ---------------------------------------------------------------------------
// Command resolution and command lines

const Runtimes = struct {
    /// Each runtime's directory, by alias, for the app's placeholders.
    dirs: []const oci.Placeholders.Dir,
    /// The placeholders of each runtime's own entries: ${app} is the
    /// runtime's directory, and ${data} and ${cache} are the app's.
    own: []const oci.Placeholders,
};

fn runtimeDirs(arena: Allocator, cfg: oci.AppConfig, dirs: []const []const u8, data_dir: []const u8, cache_dir: []const u8) !Runtimes {
    const named = try arena.alloc(oci.Placeholders.Dir, dirs.len);
    const own = try arena.alloc(oci.Placeholders, dirs.len);
    for (cfg.runtimes.map.keys(), dirs, named, own) |alias, dir, *n, *o| {
        n.* = .{ .alias = alias, .path = dir };
        o.* = .{ .app = dir, .data = data_dir, .cache = cache_dir };
    }
    return .{ .dirs = named, .own = own };
}

/// Whether the app's entries or its runtimes' use ${cache}, which is then
/// created before the run.
fn usesCache(cfg: oci.AppConfig) bool {
    if (oci.usesCache(cfg.path, cfg.env)) return true;
    for (cfg.runtimes.map.values()) |r| if (oci.usesCache(r.path, r.env)) return true;
    return false;
}

const Command = struct {
    /// The executable, or the batch file.
    exe: []const u8,
    /// Arguments that go before the caller's.
    args: []const []const u8 = &.{},
    /// A .bat or .cmd file, which runs through cmd.exe.
    batch: bool = false,

    fn init(exe: []const u8, args: []const []const u8) Command {
        const ext = std.fs.path.extension(exe);
        return .{
            .exe = exe,
            .args = args,
            .batch = std.ascii.eqlIgnoreCase(ext, ".bat") or std.ascii.eqlIgnoreCase(ext, ".cmd"),
        };
    }
};

/// What to run: the app's command, or with `--command`, one of the app's
/// exports or an executable from the app or System32.
fn resolveCommand(
    io: Io,
    arena: Allocator,
    placeholders: oci.Placeholders,
    config: oci.AppConfig,
    requested: ?[]const u8,
    app_path: []const []const u8,
    system_root: []const u8,
) !Command {
    const deploy_dir = placeholders.app;
    const name = requested orelse
        return .init(try placeholders.commandPath(arena, config.command), try expandAll(arena, placeholders, config.args));

    var exported = config.exports.map.iterator();
    while (exported.next()) |e| {
        if (!std.ascii.eqlIgnoreCase(e.key_ptr.*, name)) continue;
        return .init(try placeholders.commandPath(arena, e.value_ptr.command), try expandAll(arena, placeholders, e.value_ptr.args));
    }

    const resolved = try findCommand(io, arena, deploy_dir, name, app_path, system_root) orelse {
        // A relative path is the app's; one of yours is absolute.
        if (std.mem.indexOfAny(u8, name, "/\\") != null and !std.fs.path.isAbsolute(name))
            return fail("command \"{s}\" is not a file in the app; for a program of yours, give its absolute path (e.g. --command=%CD%\\{s})", .{ name, std.fs.path.basename(name) });
        return fail("command \"{s}\" is not an export of the app, or an executable or batch file in it or in System32", .{name});
    };
    return .init(resolved, &.{});
}

fn expandAll(arena: Allocator, placeholders: oci.Placeholders, templates: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, templates.len);
    for (out, templates) |*arg, template| arg.* = try placeholders.expand(arena, template);
    return out;
}

fn findCommand(
    io: Io,
    arena: Allocator,
    deploy_dir: []const u8,
    name: []const u8,
    app_path: []const []const u8,
    system_root: []const u8,
) !?[]const u8 {
    if (std.fs.path.isAbsolute(name)) return if (try Store.exists(io, name)) name else null;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) {
        const p = try std.fs.path.join(arena, &.{ deploy_dir, name });
        return if (try Store.exists(io, p)) p else null;
    }

    var dirs: std.ArrayList([]const u8) = .empty;
    try dirs.appendSlice(arena, app_path);
    try dirs.append(arena, try std.fs.path.join(arena, &.{ system_root, "System32" }));
    const exts: []const []const u8 = if (std.fs.path.extension(name).len == 0)
        &.{ ".exe", ".com", ".cmd", ".bat" }
    else
        &.{""};
    for (dirs.items) |dir| for (exts) |ext| {
        const p = try std.fmt.allocPrint(arena, "{s}\\{s}{s}", .{ dir, name, ext });
        if (try Store.exists(io, p)) return p;
    };
    return null;
}
