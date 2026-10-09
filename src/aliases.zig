//! Aliases: the commands an image provides to whatever runs with it (see
//! `aliases` in oci.AppConfig), as shims first on PATH. A shim runs its
//! alias's executable directly, in the caller's environment, with the alias's
//! arguments and then the caller's (see shim.zig).
//!
//! Builds write their tools' aliases into B:\bin, fresh for each build. Runs
//! keep the aliases of the app and of its runtimes in the store's
//! aliases\<id>\, and bring that directory up to date before each run,
//! rewriting only what changed. It is in the store rather than the app's data
//! directory, which sandboxed runs may write: a later run outside the
//! sandbox would run whatever they put there. And it is by app rather than by
//! image, so the absolute paths that build tools note (Meson writes cc's into
//! build.ninja) stay valid across updates.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Sidecar = @import("Sidecar.zig");
const Store = @import("Store.zig");
const exports = @import("exports.zig");
const oci = @import("oci.zig");
const process = @import("process.zig");
const win32 = @import("win32.zig");
const fail = Context.fail;
const note = Context.note;

/// An image whose aliases apply, in its deployment `dir` (${app} in them).
/// `id` names it in messages.
pub const Provider = struct {
    id: []const u8,
    dir: []const u8,
    aliases: ?std.json.ArrayHashMap(oci.Export),
};

pub const Resolved = struct {
    name: []const u8,
    alias: Sidecar.Alias,
};

/// What to do with an alias whose executable isn't in its image: fail a
/// build, which checks what it's about to use, or leave it out of a run.
pub const Missing = enum { fail, skip };

/// The aliases of `providers`, in order. Of two with the same name, the
/// earlier provider's wins, as on PATH.
pub fn resolve(ctx: *Context, providers: []const Provider, missing: Missing) ![]const Resolved {
    const arena = ctx.arena;
    var out: std.ArrayList(Resolved) = .empty;
    for (providers) |pr| if (pr.aliases) |a| for (a.map.keys(), a.map.values()) |name, e| {
        if (find(out.items, name) != null) continue;
        // Aliases can't name ${data} or ${cache} (see oci.validateAliases).
        const p: oci.Placeholders = .{ .app = pr.dir, .data = "${data}" };
        const exe = try p.commandPath(arena, e.command);
        if (!try Store.exists(ctx.io, exe)) switch (missing) {
            .fail => return fail("{s}'s alias {s} runs {s}, which isn't in it", .{ pr.id, name, e.command }),
            .skip => {
                if (!@import("builtin").is_test)
                    note("warning: {s}'s alias {s} runs {s}, which isn't in it; leaving it out", .{ pr.id, name, e.command });
                continue;
            },
        };
        const args = try arena.alloc([]const u8, e.args.len);
        for (args, e.args) |*arg, template| arg.* = try p.expand(arena, template);
        try out.append(arena, .{ .name = name, .alias = .{
            .exe = exe,
            .command_line = try process.buildCommandLine(arena, exe, args),
            .drop = e.drop orelse &.{},
        } });
    };
    return out.items;
}

fn find(resolved: []const Resolved, name: []const u8) ?Resolved {
    for (resolved) |r| if (std.ascii.eqlIgnoreCase(r.name, name)) return r;
    return null;
}

/// Their names, space-separated: BusyBox's sh runs its own applets before
/// anything on PATH unless BB_OVERRIDE_APPLETS names them, so that zig's
/// `ar` wins over BusyBox's.
pub fn names(arena: Allocator, resolved: []const Resolved) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (resolved, 0..) |r, i| {
        if (i > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, r.name);
    }
    return out.items;
}

/// Writes the shims into `dir`, a fresh directory, as builds do.
pub fn writeAll(ctx: *Context, dir: []const u8, resolved: []const Resolved) !void {
    const io = ctx.io;
    const arena = ctx.arena;
    if (resolved.len == 0) return;
    try Io.Dir.cwd().createDirPath(io, dir);
    const shim_exe = try exports.shimExe(ctx, try win32.selfExePath(arena), .console);
    for (resolved) |r| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try shimPath(arena, dir, r.name, ".exe"), .data = shim_exe });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try shimPath(arena, dir, r.name, Sidecar.extension), .data = try sidecarText(arena, r.alias) });
    }
}

/// Makes `dir` hold the shims of `resolved` and nothing else, as runs do,
/// writing only what differs from what's there: unchanged shims stay as
/// they are, and Defender has nothing new to scan. Returns how many files it
/// wrote. A shim that is running can't be replaced, so it stays until a later
/// run; shims don't change often (a new zigsaw, or an alias that changed).
pub fn sync(ctx: *Context, dir: []const u8, resolved: []const Resolved) !usize {
    const io = ctx.io;
    const arena = ctx.arena;
    try Io.Dir.cwd().createDirPath(io, dir);
    var written: usize = 0;
    var shim_exe: ?[]const u8 = null;
    for (resolved) |r| {
        const exe_path = try shimPath(arena, dir, r.name, ".exe");
        if (shim_exe == null) shim_exe = try exports.shimExe(ctx, try win32.selfExePath(arena), .console);
        if (try replaceIfDifferent(ctx, exe_path, shim_exe.?)) written += 1;
        const sidecar_path = try shimPath(arena, dir, r.name, Sidecar.extension);
        if (try replaceIfDifferent(ctx, sidecar_path, try sidecarText(arena, r.alias))) written += 1;
    }

    // Whatever else is there: aliases the app no longer has, under any case
    // of their names, and files a failed write left.
    var d = try Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var stale: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (isWanted(resolved, entry.name)) continue;
        try stale.append(arena, try std.fs.path.join(arena, &.{ dir, entry.name }));
    }
    for (stale.items) |p| Io.Dir.cwd().deleteFile(io, p) catch |err| {
        if (ctx.verbose) note("couldn't remove {s} ({t}); a later run will", .{ p, err });
    };
    return written;
}

fn isWanted(resolved: []const Resolved, file_name: []const u8) bool {
    for ([_][]const u8{ ".exe", Sidecar.extension }) |ext| {
        if (file_name.len <= ext.len or !std.ascii.endsWithIgnoreCase(file_name, ext)) continue;
        const stem = file_name[0 .. file_name.len - ext.len];
        // Any case: CC.exe is the file cc.exe on Windows.
        for (resolved) |r| if (std.ascii.eqlIgnoreCase(r.name, stem)) return true;
    }
    return false;
}

/// Replaces the file at `p` with `bytes` unless it has them already, through
/// a file next to it, so that a shim starting meanwhile reads the old or the
/// new, and the file gets the directory's permissions, as an AppContainer's
/// grant. Whether it wrote it.
fn replaceIfDifferent(ctx: *Context, p: []const u8, bytes: []const u8) !bool {
    const io = ctx.io;
    const arena = ctx.arena;
    const current = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(16 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
    if (current) |c| if (std.mem.eql(u8, c, bytes)) return false;
    var random: [4]u8 = undefined;
    io.random(&random);
    const tmp = try std.fmt.allocPrint(arena, "{s}.{s}.tmp", .{ p, &std.fmt.bytesToHex(random, .lower) });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = bytes });
    Io.Dir.rename(.cwd(), tmp, .cwd(), p, io) catch |err| {
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        switch (err) {
            // Running: it keeps working as it is, with the sidecar next to it.
            error.AccessDenied, error.FileBusy => {
                if (ctx.verbose) note("{s} is in use; a later run will update it", .{p});
                return false;
            },
            else => |e| return e,
        }
    };
    return true;
}

fn shimPath(arena: Allocator, dir: []const u8, name: []const u8, ext: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}\\{s}{s}", .{ dir, name, ext });
}

fn sidecarText(arena: Allocator, alias: Sidecar.Alias) ![]const u8 {
    var text: Io.Writer.Allocating = .init(arena);
    try alias.format(&text.writer);
    return text.written();
}

test "resolve: the first provider wins a name, and ${app} is its directory" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    for ([_][]const u8{ "app", "rt" }) |sub| try tmp.dir.createDirPath(io, sub);
    try tmp.dir.writeFile(io, .{ .sub_path = "app\\tool.exe", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "rt\\zig.exe", .data = "" });

    var env: std.process.Environ.Map = .init(arena);
    var ctx: Context = .{ .io = io, .gpa = std.testing.allocator, .arena = arena, .env = &env, .store = .{ .io = io, .root = root } };
    var app_aliases: std.json.ArrayHashMap(oci.Export) = .{};
    try app_aliases.map.put(arena, "CC", .{ .command = "tool.exe" });
    var rt_aliases: std.json.ArrayHashMap(oci.Export) = .{};
    try rt_aliases.map.put(arena, "cc", .{ .command = "zig.exe", .args = &.{"cc"} });
    try rt_aliases.map.put(arena, "ar", .{ .command = "zig.exe", .args = &.{ "ar", "${app}\\lib" }, .drop = &.{"--64"} });
    try rt_aliases.map.put(arena, "gone", .{ .command = "bin/gone.exe" });
    const app_dir = try std.fs.path.join(arena, &.{ root, "app" });
    const rt_dir = try std.fs.path.join(arena, &.{ root, "rt" });
    const providers = [_]Provider{
        .{ .id = "app", .dir = app_dir, .aliases = app_aliases },
        .{ .id = "rt", .dir = rt_dir, .aliases = rt_aliases },
        .{ .id = "none", .dir = rt_dir, .aliases = null },
    };

    try std.testing.expectError(error.Failed, resolve(&ctx, &providers, .fail));
    const resolved = try resolve(&ctx, &providers, .skip);
    try std.testing.expectEqual(2, resolved.len);
    try std.testing.expectEqualStrings("CC", resolved[0].name);
    try std.testing.expectEqualStrings(try std.fs.path.join(arena, &.{ app_dir, "tool.exe" }), resolved[0].alias.exe);
    try std.testing.expectEqualStrings("ar", resolved[1].name);
    const zig = try std.fs.path.join(arena, &.{ rt_dir, "zig.exe" });
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s} ar {s}\\lib", .{ zig, rt_dir }), resolved[1].alias.command_line);
    try std.testing.expectEqualStrings("--64", resolved[1].alias.drop[0]);
    try std.testing.expectEqualStrings("CC ar", try names(arena, resolved));
}

test "sync writes what changed and removes the rest" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const dir = try std.fs.path.join(arena, &.{ root, "aliases" });
    var env: std.process.Environ.Map = .init(arena);
    var ctx: Context = .{ .io = io, .gpa = std.testing.allocator, .arena = arena, .env = &env, .store = .{ .io = io, .root = root } };

    // Unchanged files aren't written: what replaceIfDifferent decides.
    const p = try std.fs.path.join(arena, &.{ root, "f.shim" });
    try std.testing.expect(try replaceIfDifferent(&ctx, p, "one"));
    try std.testing.expect(!try replaceIfDifferent(&ctx, p, "one"));
    try std.testing.expect(try replaceIfDifferent(&ctx, p, "two"));
    try std.testing.expectEqualStrings("two", try tmp.dir.readFileAlloc(io, "f.shim", arena, .limited(64)));

    // With no aliases (no shim executable needed), everything else goes.
    try tmp.dir.createDirPath(io, "aliases");
    try tmp.dir.writeFile(io, .{ .sub_path = "aliases\\old.exe", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "aliases\\old.shim", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "aliases\\cc.shim.1234abcd.tmp", .data = "x" });
    try std.testing.expectEqual(0, try sync(&ctx, dir, &.{}));
    var d = try tmp.dir.openDir(io, "aliases", .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    try std.testing.expectEqual(null, try it.next(io));

    const cc: Resolved = .{ .name = "cc", .alias = .{ .exe = "C:\\z\\zig.exe", .command_line = "C:\\z\\zig.exe cc" } };
    try std.testing.expect(isWanted(&.{cc}, "cc.exe"));
    try std.testing.expect(isWanted(&.{cc}, "cc.SHIM"));
    try std.testing.expect(isWanted(&.{cc}, "CC.exe"));
    try std.testing.expect(!isWanted(&.{cc}, "c.exe"));
    try std.testing.expect(!isWanted(&.{cc}, "cc.exe.0a1b2c3d.tmp"));
    try std.testing.expect(!isWanted(&.{cc}, ".exe"));
}
