//! Command shims. Each command an installed app exports becomes
//! `<root>\bin\<name>.exe`, a copy of zigsaw-shim.exe, next to a
//! `<name>.shim` sidecar saying what it runs. With `<root>\bin` on PATH, apps
//! run by name. The sidecars also record which app owns each name.

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

/// Makes the store's shims match `config.exports`: creates or updates the
/// app's shims and removes the ones it no longer exports. A name another app
/// already provides is skipped with a warning.
pub fn sync(ctx: *Context, config: oci.AppConfig) !void {
    const arena = ctx.arena;
    const installed = try list(ctx);
    const zigsaw = try win32.selfExePath(arena);
    const shim_exe = try shimExe(ctx, zigsaw);

    var exported: std.ArrayList([]const u8) = .empty;
    var it = config.exports.map.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        if (find(installed, name)) |owner| if (!std.mem.eql(u8, owner.sidecar.app, config.id)) {
            note("warning: not exporting {s}: {s} already provides it", .{ name, owner.sidecar.app });
            continue;
        };
        try writeShim(ctx, name, shim_exe, .{ .zigsaw = zigsaw, .home = ctx.store.root, .app = config.id, .command = name });
        try exported.append(arena, name);
    }

    for (installed) |shim| {
        if (!std.mem.eql(u8, shim.sidecar.app, config.id)) continue;
        if (!exportsName(config, shim.name)) try removeShim(ctx, shim.name);
    }

    if (exported.items.len == 0) return;
    note("  exports  {s}", .{try std.mem.join(arena, ", ", exported.items)});
    const bin = try binDir(ctx);
    if (!onPath(ctx.env.get("PATH") orelse "", bin)) {
        note(
            \\
            \\{0s} isn't on your PATH, so these commands won't be found by name yet.
            \\To add it for your user, run this in PowerShell and open a new terminal:
            \\  [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'User') + ';{0s}', 'User')
        , .{bin});
    }
}

/// Removes all of an app's shims and returns their names.
pub fn removeAll(ctx: *Context, app: []const u8) ![]const []const u8 {
    var removed: std.ArrayList([]const u8) = .empty;
    for (try list(ctx)) |shim| {
        if (!std.mem.eql(u8, shim.sidecar.app, app)) continue;
        try removeShim(ctx, shim.name);
        try removed.append(ctx.arena, shim.name);
    }
    return removed.items;
}

fn binDir(ctx: *Context) ![]const u8 {
    return ctx.store.path(ctx.arena, &.{"bin"});
}

/// zigsaw-shim.exe's bytes. It is installed next to zigsaw.exe.
fn shimExe(ctx: *Context, zigsaw: []const u8) ![]const u8 {
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
        Io.Dir.cwd().writeFile(io, .{ .sub_path = exe_path, .data = shim_exe }) catch |err|
            return fail("writing {s} (is it running?): {t}", .{ exe_path, err });
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
            else => return fail("removing {s} (is it running?): {t}", .{ p, err }),
        };
    }
}

fn find(shims: []const Shim, name: []const u8) ?Shim {
    for (shims) |s| if (std.ascii.eqlIgnoreCase(s.name, name)) return s;
    return null;
}

fn exportsName(config: oci.AppConfig, name: []const u8) bool {
    var it = config.exports.map.iterator();
    while (it.next()) |e| if (std.ascii.eqlIgnoreCase(e.key_ptr.*, name)) return true;
    return false;
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
