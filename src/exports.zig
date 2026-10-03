//! Command shims. Each command an installed app provides becomes
//! `<root>\bin\<name>.exe`, a copy of zigsaw-shim.exe, next to a
//! `<name>.shim` sidecar saying what it runs. With `<root>\bin` on PATH, apps
//! run by name. The sidecars also record which app owns each name.
//!
//! An app provides its exports, and the commands its runs install in its
//! command directories: its PATH entries in its data directory, such as the
//! global prefix of npm (`npm install -g typescript` gives `tsc`). Its shims
//! are synced as it's installed, and after each of its runs.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Sidecar = @import("Sidecar.zig");
const oci = @import("oci.zig");
const win32 = @import("win32.zig");
const fail = Context.fail;
const note = Context.note;

pub const Shim = struct {
    /// Command name: the shim's file name without extension.
    name: []const u8,
    sidecar: Sidecar,
};

/// All shims in the store, sorted by name.
pub fn list(ctx: *Context) ![]Shim {
    const io = ctx.io;
    const arena = ctx.arena;
    var dir = try Io.Dir.cwd().openDir(io, try binDir(ctx), .{ .iterate = true });
    defer dir.close(io);
    var shims: std.ArrayList(Shim) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, Sidecar.extension)) continue;
        const bytes = try dir.readFileAlloc(io, entry.name, arena, .limited(64 * 1024));
        const sidecar = Sidecar.parse(bytes) catch continue; // Not ours to manage.
        try shims.append(arena, .{
            .name = try arena.dupe(u8, entry.name[0 .. entry.name.len - Sidecar.extension.len]),
            .sidecar = sidecar,
        });
    }
    std.mem.sort(Shim, shims.items, {}, struct {
        fn lessThan(_: void, a: Shim, b: Shim) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan);
    return shims.items;
}

/// Makes the store's shims match what the app provides, as it's installed.
/// See `syncLocked`.
pub fn sync(ctx: *Context, config: oci.AppConfig) !void {
    const lock = try ctx.store.lockShims(ctx.arena);
    defer lock.release(ctx.io);
    try syncLocked(ctx, config, .install);
}

/// After a run of the app, gives the commands it installed shims, and
/// removes those of commands it uninstalled. Only reports changes, and only
/// warns if one fails: the run itself went fine.
pub fn syncAfterRun(ctx: *Context, id: []const u8) void {
    const arena = ctx.arena;
    const start = ctx.now();
    const lock = ctx.store.lockShims(arena) catch |err| {
        note("warning: couldn't update {s}'s commands: {t}", .{ id, err });
        return;
    };
    defer lock.release(ctx.io);
    // The app may have been removed while it ran, or updated: what's
    // installed now counts.
    const ref = (ctx.store.readRef(arena, id) catch null) orelse return;
    const image = ctx.store.readImage(arena, id, ref.manifest) catch return;
    syncLocked(ctx, image.config, .run) catch |err| switch (err) {
        error.Failed => {},
        else => note("warning: couldn't update {s}'s commands: {t}", .{ id, err }),
    };
    ctx.timed(start, "sync commands", .{});
}

const When = enum { install, run };

/// Makes the store's shims match what the app provides: its exports, and
/// the commands in its command directories, which exports win over. Creates
/// or updates the app's shims and removes those it no longer provides. A name
/// another app already provides is skipped, with a warning on install. The
/// caller holds the shims' lock (Store.lockShims).
fn syncLocked(ctx: *Context, config: oci.AppConfig, when: When) !void {
    const io = ctx.io;
    const arena = ctx.arena;
    const installed = try list(ctx);
    const zigsaw = try win32.selfExePath(arena);
    const data_dir = try ctx.store.path(arena, &.{ "data", config.id });
    const found = try findCommands(io, arena, try commandDirs(arena, config, data_dir));

    var exported: std.ArrayList([]const u8) = .empty;
    var from_runs: std.ArrayList([]const u8) = .empty;
    var added: std.ArrayList([]const u8) = .empty;
    var shim_exe: ?[]const u8 = null;
    const names = try std.mem.concat(arena, []const u8, &.{ config.exports.map.keys(), found });
    for (names, 0..) |name, i| {
        const is_export = i < config.exports.map.count();
        if (!is_export and exportsName(config, name)) continue;
        const owner = find(installed, name);
        if (owner) |o| if (!std.mem.eql(u8, o.sidecar.app, config.id)) {
            switch (when) {
                .install => note("warning: not exporting {s}: {s} already provides it", .{ name, o.sidecar.app }),
                .run => if (ctx.verbose) note("not adding {s}: {s} already provides it", .{ name, o.sidecar.app }),
            }
            continue;
        };
        const sidecar: Sidecar = .{ .zigsaw = zigsaw, .home = ctx.store.root, .app = config.id, .command = name };
        try (if (is_export) &exported else &from_runs).append(arena, name);
        // After a run, a shim that's there already is left as it is.
        if (when == .run and owner != null and owner.?.sidecar.eql(sidecar)) continue;
        if (shim_exe == null) shim_exe = try shimExe(ctx, zigsaw);
        writeShim(ctx, name, shim_exe.?, sidecar) catch |err| switch (when) {
            .install => return fail("writing the shim for {s} in {s} (is it running?): {t}", .{ name, try binDir(ctx), err }),
            .run => {
                note("warning: couldn't add {s} to {s}: {t}", .{ name, try binDir(ctx), err });
                continue;
            },
        };
        if (owner == null) try added.append(arena, name);
    }

    var removed: std.ArrayList([]const u8) = .empty;
    for (installed) |shim| {
        if (!std.mem.eql(u8, shim.sidecar.app, config.id)) continue;
        if (containsIgnoreCase(exported.items, shim.name) or containsIgnoreCase(from_runs.items, shim.name)) continue;
        removeShim(ctx, shim.name) catch |err| switch (when) {
            .install => return fail("removing the shim for {s} from {s} (is it running?): {t}", .{ shim.name, try binDir(ctx), err }),
            .run => {
                note("warning: couldn't remove {s} from {s}: {t}", .{ shim.name, try binDir(ctx), err });
                continue;
            },
        };
        try removed.append(arena, shim.name);
    }

    const bin = try binDir(ctx);
    switch (when) {
        .install => {
            if (exported.items.len > 0) note("  exports  {s}", .{try std.mem.join(arena, ", ", exported.items)});
            if (from_runs.items.len > 0) note("  commands {s} (installed by its runs)", .{try std.mem.join(arena, ", ", from_runs.items)});
            if (exported.items.len + from_runs.items.len > 0) pathHint(ctx, bin);
        },
        .run => {
            if (added.items.len > 0) {
                note("added {s} to {s} (installed by {s})", .{ try std.mem.join(arena, ", ", added.items), bin, config.id });
                pathHint(ctx, bin);
            }
            if (removed.items.len > 0) note("removed {s} from {s} (gone from {s})", .{ try std.mem.join(arena, ", ", removed.items), bin, config.id });
        },
    }
}

/// Removes all of an app's shims and returns their names. The caller holds
/// the shims' lock (Store.lockShims).
pub fn removeAll(ctx: *Context, app: []const u8) ![]const []const u8 {
    var removed: std.ArrayList([]const u8) = .empty;
    for (try list(ctx)) |shim| {
        if (!std.mem.eql(u8, shim.sidecar.app, app)) continue;
        removeShim(ctx, shim.name) catch |err|
            return fail("removing the shim for {s} from {s} (is it running?): {t}", .{ shim.name, try binDir(ctx), err });
        try removed.append(ctx.arena, shim.name);
    }
    return removed.items;
}

/// Whether the app has command directories, so that its runs may install
/// commands.
pub fn hasCommandDirs(config: oci.AppConfig) bool {
    for (config.path) |p| if (isDataEntry(p)) return true;
    for (config.runtimes.map.values()) |r| for (r.path) |p| if (isDataEntry(p)) return true;
    return false;
}

/// The directories where the app's runs install commands: its PATH entries
/// in its data directory `data_dir`, then its runtimes' (whose ${data} is
/// the app's too), in PATH order.
pub fn commandDirs(arena: Allocator, config: oci.AppConfig, data_dir: []const u8) ![]const []const u8 {
    const p: oci.Placeholders = .{ .app = "", .data = data_dir };
    var dirs: std.ArrayList([]const u8) = .empty;
    const runtimes = config.runtimes.map.values();
    for (0..runtimes.len + 1) |i| {
        const entries = if (i == 0) config.path else runtimes[i - 1].path;
        for (entries) |entry| {
            if (!isDataEntry(entry)) continue;
            const dir = try p.expand(arena, entry);
            std.mem.replaceScalar(u8, dir, '/', '\\');
            if (!containsIgnoreCase(dirs.items, dir)) try dirs.append(arena, dir);
        }
    }
    return dirs.items;
}

fn isDataEntry(entry: []const u8) bool {
    return std.mem.startsWith(u8, entry, "${data}");
}

/// The commands in `dirs`: the executables and batch files directly in them,
/// by file name without extension, sorted within each directory. Of two with
/// the same name, the one in the earlier directory wins, as on PATH.
pub fn findCommands(io: Io, arena: Allocator, dirs: []const []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (dirs) |dir_path| {
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => |e| return e,
        };
        defer dir.close(io);
        var here: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const name = commandName(entry.name) orelse continue;
            if (containsIgnoreCase(names.items, name) or containsIgnoreCase(here.items, name)) continue;
            try here.append(arena, try arena.dupe(u8, name));
        }
        std.mem.sort([]const u8, here.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.ascii.lessThanIgnoreCase(a, b);
            }
        }.lessThan);
        try names.appendSlice(arena, here.items);
    }
    return names.items;
}

/// The command a file in a command directory is: an executable or batch
/// file, named without its extension. npm's other files for a command (`tsc`
/// for sh, `tsc.ps1`) aren't commands.
fn commandName(file_name: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(file_name);
    for ([_][]const u8{ ".exe", ".com", ".cmd", ".bat" }) |e| if (std.ascii.eqlIgnoreCase(ext, e)) {
        const name = file_name[0 .. file_name.len - ext.len];
        return if (oci.isValidExportName(name)) name else null;
    };
    return null;
}

fn binDir(ctx: *Context) ![]const u8 {
    return ctx.store.path(ctx.arena, &.{"bin"});
}

/// zigsaw-shim.exe's bytes. It is installed next to zigsaw.exe.
pub fn shimExe(ctx: *Context, zigsaw: []const u8) ![]const u8 {
    const path = try std.fs.path.join(ctx.arena, &.{ std.fs.path.dirname(zigsaw).?, "zigsaw-shim.exe" });
    return Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(16 << 20)) catch |err|
        fail("reading {s}, which should be installed next to zigsaw.exe: {t}", .{ path, err });
}

fn writeShim(ctx: *Context, name: []const u8, shim_exe: []const u8, sidecar: Sidecar) !void {
    const io = ctx.io;
    const arena = ctx.arena;
    const bin = try binDir(ctx);
    const exe_path = try std.fmt.allocPrint(arena, "{s}\\{s}.exe", .{ bin, name });

    // Leave an up-to-date shim alone: it may be running, and Windows can't
    // overwrite a running executable.
    const current = Io.Dir.cwd().readFileAlloc(io, exe_path, arena, .limited(16 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
    if (current == null or !std.mem.eql(u8, current.?, shim_exe)) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = exe_path, .data = shim_exe });
    }

    var text: Io.Writer.Allocating = .init(arena);
    try sidecar.format(&text.writer);
    const sidecar_path = try std.fmt.allocPrint(arena, "{s}\\{s}{s}", .{ bin, name, Sidecar.extension });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = sidecar_path, .data = text.written() });
}

fn removeShim(ctx: *Context, name: []const u8) !void {
    const bin = try binDir(ctx);
    for ([_][]const u8{ ".exe", Sidecar.extension }) |ext| {
        const p = try std.fmt.allocPrint(ctx.arena, "{s}\\{s}{s}", .{ bin, name, ext });
        Io.Dir.cwd().deleteFile(ctx.io, p) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }
}

fn find(shims: []const Shim, name: []const u8) ?Shim {
    for (shims) |s| if (std.ascii.eqlIgnoreCase(s.name, name)) return s;
    return null;
}

fn exportsName(config: oci.AppConfig, name: []const u8) bool {
    return containsIgnoreCase(config.exports.map.keys(), name);
}

fn containsIgnoreCase(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.ascii.eqlIgnoreCase(n, name)) return true;
    return false;
}

/// Says how to put `bin` on PATH, if it isn't.
fn pathHint(ctx: *Context, bin: []const u8) void {
    if (onPath(ctx.env.get("PATH") orelse "", bin)) return;
    note(
        \\
        \\{0s} isn't on your PATH, so these commands won't be found by name yet.
        \\To add it for your user, run this in PowerShell and open a new terminal:
        \\  [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'User') + ';{0s}', 'User')
    , .{bin});
}

/// Whether `dir` is one of the directories in a PATH value.
fn onPath(path_var: []const u8, dir: []const u8) bool {
    const want = std.mem.trimEnd(u8, dir, "\\/");
    var it = std.mem.tokenizeScalar(u8, path_var, ';');
    while (it.next()) |entry| {
        const got = std.mem.trimEnd(u8, std.mem.trim(u8, entry, " \""), "\\/");
        if (std.os.windows.eqlIgnoreCaseWtf8(got, want)) return true;
    }
    return false;
}

test onPath {
    const bin = "C:\\Users\\me\\AppData\\Local\\zigsaw\\bin";
    try std.testing.expect(onPath("C:\\Windows;c:\\users\\ME\\AppData\\Local\\zigsaw\\bin\\;D:\\x", bin));
    try std.testing.expect(onPath("\"C:\\Users\\me\\AppData\\Local\\zigsaw\\bin\"", bin));
    try std.testing.expect(!onPath("C:\\Windows;C:\\Users\\me\\AppData\\Local\\zigsaw", bin));
}

test commandDirs {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var c: oci.AppConfig = .{ .id = "x", .version = "1", .command = "x.exe", .path = &.{ ".", "${data}\\npm", "${cache}\\bin", "${app}\\tools", "bin" } };
    try std.testing.expect(hasCommandDirs(c));
    try c.runtimes.map.put(arena, "node", .{
        .id = "org.nodejs.node",
        .version = "24",
        .image = "sha256:" ++ "a" ** 64,
        .layer = "sha256:" ++ "b" ** 64,
        .path = &.{ ".", "${data}/cargo/bin", "${data}\\npm" },
    });
    const dirs = try commandDirs(arena, c, "C:\\z\\data\\x");
    try std.testing.expectEqual(2, dirs.len);
    try std.testing.expectEqualStrings("C:\\z\\data\\x\\npm", dirs[0]);
    try std.testing.expectEqualStrings("C:\\z\\data\\x\\cargo\\bin", dirs[1]);

    const plain: oci.AppConfig = .{ .id = "x", .version = "1", .command = "x.exe", .path = &.{ ".", "${cache}" } };
    try std.testing.expect(!hasCommandDirs(plain));
    try std.testing.expectEqual(0, (try commandDirs(arena, plain, "C:\\z\\data\\x")).len);
}

test findCommands {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "one/tsc.cmd", "one/tsc", "one/tsc.ps1", "one/Semver.CMD", "one/a.exe", "one/.hidden.exe", "one/zigsaw.exe", "one/b.bat", "one/notes.txt", "two/a.cmd", "two/c.com" }) |f| {
        if (std.fs.path.dirname(f)) |d| try tmp.dir.createDirPath(io, d);
        try tmp.dir.writeFile(io, .{ .sub_path = f, .data = "" });
    }
    try tmp.dir.createDirPath(io, "one/d.exe");
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const dirs: []const []const u8 = &.{
        try std.fs.path.join(arena, &.{ root, "one" }),
        try std.fs.path.join(arena, &.{ root, "missing" }),
        try std.fs.path.join(arena, &.{ root, "two" }),
    };
    const names = try findCommands(io, arena, dirs);
    const want: []const []const u8 = &.{ "a", "b", "Semver", "tsc", "c" };
    try std.testing.expectEqual(want.len, names.len);
    for (want, names) |w, n| try std.testing.expectEqualStrings(w, n);
}
