//! Layers are plain tar files. They are written deterministically (sorted
//! entries, zero timestamps, fixed modes) so the same app tree always produces
//! the same bytes, and therefore the same digest.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const fail = Context.fail;

/// Writes the tree at `root_path` as a tar file at `out_path`.
pub fn write(io: Io, arena: Allocator, root_path: []const u8, out_path: []const u8) !void {
    var root = try Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);

    const Entry = struct {
        path: []const u8,
        is_dir: bool,

        fn lessThan(_: void, a: @This(), b: @This()) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    };
    var entries: std.ArrayList(Entry) = .empty;
    var walker = try root.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        const p = try arena.dupe(u8, e.path);
        std.mem.replaceScalar(u8, p, '\\', '/');
        switch (e.kind) {
            .directory => try entries.append(arena, .{ .path = p, .is_dir = true }),
            .file => try entries.append(arena, .{ .path = p, .is_dir = false }),
            else => return fail("{s}: only regular files and directories are supported in an app tree", .{p}),
        }
    }
    std.mem.sort(Entry, entries.items, {}, Entry.lessThan);

    var out = try Io.Dir.cwd().createFile(io, out_path, .{});
    defer out.close(io);
    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer = out.writer(io, &out_buf);
    var tar: std.tar.Writer = .{ .underlying_writer = &out_writer.interface };

    var read_buf: [64 * 1024]u8 = undefined;
    for (entries.items) |e| {
        if (e.is_dir) {
            try tar.writeDir(e.path, .{ .mode = 0o755 });
            continue;
        }
        var file = try root.openFile(io, e.path, .{});
        defer file.close(io);
        var reader = file.reader(io, &read_buf);
        try tar.writeFile(e.path, &reader, 0);
    }
    // Zig's reader doesn't need the end-of-archive blocks, but other tar readers expect them.
    try tar.finishPedantically();
    try out_writer.interface.flush();
}

/// Extracts the tar file at `tar_path` into `dest_path`, creating it if needed.
pub fn extract(io: Io, tar_path: []const u8, dest_path: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, dest_path);
    var dest = try Io.Dir.cwd().openDir(io, dest_path, .{});
    defer dest.close(io);
    var file = try Io.Dir.cwd().openFile(io, tar_path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buf);
    try std.tar.extract(io, dest, &reader.interface, .{ .mode_mode = .ignore });
}

test "layers are deterministic and round-trip" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const tree = try std.fs.path.join(arena, &.{ base, "tree" });
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ tree, "bin" }));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ tree, "bin", "tool.exe" }), .data = "MZ fake" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ tree, "README" }), .data = "hi" });

    const a = try std.fs.path.join(arena, &.{ base, "a.tar" });
    const b = try std.fs.path.join(arena, &.{ base, "b.tar" });
    try write(io, arena, tree, a);
    try write(io, arena, tree, b);
    const a_bytes = try Io.Dir.cwd().readFileAlloc(io, a, arena, .unlimited);
    const b_bytes = try Io.Dir.cwd().readFileAlloc(io, b, arena, .unlimited);
    try std.testing.expectEqualSlices(u8, a_bytes, b_bytes);

    const out = try std.fs.path.join(arena, &.{ base, "out" });
    try extract(io, a, out);
    const got = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ out, "bin", "tool.exe" }), arena, .unlimited);
    try std.testing.expectEqualStrings("MZ fake", got);
}
