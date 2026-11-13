//! What runs read of an image's layers while they were pulled lazily, which
//! the next lazy pull of the image asks for before any run does (see lazy.zig
//! and LazyHelper.zig): a prefetch list nobody wrote, for the files this
//! machine's runs read, of whatever version comes next.
//!
//!   <root>\learned\<id>.txt   one per image, an app's or a runtime's: a line
//!                             `<layer hex> <path>` for each file a run read
//!                             of that layer while a helper served it
//!
//! A layer's helper appends a line the first time something reads a file. The
//! list is the paths of the last `kept_layers` layers the file has lines of,
//! by when each last got one: a file that nothing reads any more is gone from
//! it once that many layers have been read from without it. A layer nothing
//! read from while it was lazy has no line, and counts for nothing.
//!
//! `prune` deletes the lists of images no installed app is or uses; `rm`
//! leaves them. A zigsaw before 0.96 neither writes nor reads them.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = @import("Store.zig");
const oci = @import("oci.zig");

/// How many layers' reads make the list.
pub const kept_layers = 3;

const hex_len = 64;

pub fn filePath(store: Store, arena: Allocator, id: []const u8) ![]u8 {
    return store.path(arena, &.{ "learned", try std.fmt.allocPrint(arena, "{s}.txt", .{id}) });
}

pub const List = struct {
    /// The paths, in the order they were first read, each once.
    names: []const []const u8,
    /// What the file is to hold instead, if it has lines the list doesn't
    /// come from: older layers', the same one twice, or none of this.
    rewrite: ?[]const u8 = null,
};

fn parseLine(raw: []const u8) ?struct { []const u8, []const u8 } {
    const line = std.mem.trimEnd(u8, raw, "\r");
    if (line.len < hex_len + 2 or line[hex_len] != ' ') return null;
    if (!oci.isSha256Hex(line[0..hex_len])) return null;
    return .{ line[0..hex_len], line[hex_len + 1 ..] };
}

/// The list a file's text makes.
pub fn select(arena: Allocator, text: []const u8) !List {
    const Line = struct { hex: []const u8, name: []const u8, text: []const u8, kept: bool = false };
    var lines: std.ArrayList(Line) = .empty;
    var total: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        if (std.mem.trimEnd(u8, raw, "\r").len == 0) continue;
        total += 1;
        const hex, const name = parseLine(raw) orelse continue;
        try lines.append(arena, .{ .hex = hex, .name = name, .text = std.mem.trimEnd(u8, raw, "\r") });
    }

    // From the last line back: the layers by when each last got a line, and
    // of a line there twice, the later one.
    var layers: std.StringArrayHashMapUnmanaged(void) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var kept: usize = 0;
    var i = lines.items.len;
    while (i > 0) {
        i -= 1;
        const line = &lines.items[i];
        const layer = try layers.getOrPut(arena, line.hex);
        if (layer.index >= kept_layers) continue;
        const gop = try seen.getOrPut(arena, line.text);
        if (gop.found_existing) continue;
        line.kept = true;
        kept += 1;
    }

    var names: std.ArrayList([]const u8) = .empty;
    var named: std.StringHashMapUnmanaged(void) = .empty;
    var out: std.ArrayList(u8) = .empty;
    for (lines.items) |line| {
        if (!line.kept) continue;
        try out.appendSlice(arena, line.text);
        try out.append(arena, '\n');
        const gop = try named.getOrPut(arena, line.name);
        if (!gop.found_existing) try names.append(arena, line.name);
    }
    return .{ .names = names.items, .rewrite = if (kept != total) out.items else null };
}

/// The image's list: empty if nothing was learned of it. Leaves the file with
/// only what the list comes from.
pub fn read(store: Store, arena: Allocator, id: []const u8) ![]const []const u8 {
    const io = store.io;
    const path = try filePath(store, arena, id);
    if (!try Store.exists(io, path)) return &.{};
    const lock = try Store.openLock(io, try Store.lockPathFor(arena, path), .exclusive, .wait);
    defer lock.release(io);
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => |e| return e,
    };
    const list = try select(arena, text);
    if (list.rewrite) |bytes| {
        const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = bytes });
        try Io.Dir.rename(.cwd(), tmp, .cwd(), path, io);
    }
    return list.names;
}

/// Writes down that something read `name` of the image's layer `hex`.
pub fn record(store: Store, arena: Allocator, id: []const u8, hex: []const u8, name: []const u8) !void {
    const io = store.io;
    // A line each: a path that wouldn't be one isn't learned.
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "\r\n") != null) return;
    const path = try filePath(store, arena, id);
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    const lock = try Store.openLock(io, try Store.lockPathFor(arena, path), .exclusive, .wait);
    defer lock.release(io);
    var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer file.close(io);
    const line = try std.fmt.allocPrint(arena, "{s} {s}\n", .{ hex, name });
    try file.writePositionalAll(io, line, try file.length(io));
}

/// Deletes the lists of images that aren't among `used`, and the locks left
/// without a list. Returns how many lists went.
pub fn pruneUnused(store: Store, arena: Allocator, used: []const []const u8) !usize {
    const io = store.io;
    const dir_path = try store.path(arena, &.{"learned"});
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => |e| return e,
    };
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| try names.append(arena, try arena.dupe(u8, entry.name));
    var deleted: usize = 0;
    for (names.items) |name| {
        if (!std.mem.endsWith(u8, name, ".txt")) continue;
        const id = name[0 .. name.len - ".txt".len];
        const in_use = for (used) |u| {
            if (std.ascii.eqlIgnoreCase(u, id)) break true;
        } else false;
        if (in_use) continue;
        const path = try std.fs.path.join(arena, &.{ dir_path, name });
        // A helper that's writing it serves a layer prune left: it stays.
        const lock = try Store.tryLock(io, try Store.lockPathFor(arena, path), .exclusive) orelse continue;
        defer lock.release(io);
        Io.Dir.cwd().deleteFile(io, path) catch continue;
        deleted += 1;
    }
    for (names.items) |name| {
        if (!std.mem.endsWith(u8, name, ".lock") and !std.mem.endsWith(u8, name, ".tmp")) continue;
        const path = try std.fs.path.join(arena, &.{ dir_path, name });
        if (try Store.exists(io, path[0 .. path.len - std.fs.path.extension(name).len])) continue;
        Io.Dir.cwd().deleteFile(io, path) catch {};
    }
    return deleted;
}

const testing = std.testing;

fn hexOf(comptime c: u8) [hex_len]u8 {
    return @splat(c);
}

test "select: the paths of the last three layers, in the order they were read, each once" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = comptime hexOf('a');
    const b = comptime hexOf('b');
    const c = comptime hexOf('c');
    const d = comptime hexOf('d');

    const one = try select(arena, a ++ " bin/app.exe\n" ++ a ++ " share/a file.txt\r\n");
    try testing.expectEqual(2, one.names.len);
    try testing.expectEqualStrings("bin/app.exe", one.names[0]);
    try testing.expectEqualStrings("share/a file.txt", one.names[1]);
    // A line ending Windows' way is the same line: nothing to write again.
    try testing.expect(one.rewrite == null);

    // Four layers: the first one's own file is gone, and what the others
    // read too stays, once.
    const four = try select(arena, a ++ " only-a\n" ++ a ++ " app.exe\n" ++ b ++ " app.exe\n" ++ b ++ " b.dll\n" ++ c ++ " app.exe\n" ++ d ++ " d.dll\n");
    try testing.expectEqual(3, four.names.len);
    try testing.expectEqualStrings("app.exe", four.names[0]);
    try testing.expectEqualStrings("b.dll", four.names[1]);
    try testing.expectEqualStrings("d.dll", four.names[2]);
    try testing.expectEqualStrings(b ++ " app.exe\n" ++ b ++ " b.dll\n" ++ c ++ " app.exe\n" ++ d ++ " d.dll\n", four.rewrite.?);
    // What's written again says the same.
    const again = try select(arena, four.rewrite.?);
    try testing.expectEqual(3, again.names.len);
    try testing.expect(again.rewrite == null);
}

test "select: a layer read from again is the latest, and a line there twice counts once" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = comptime hexOf('a');
    const b = comptime hexOf('b');
    const c = comptime hexOf('c');
    const d = comptime hexOf('d');

    // a, pulled lazily again after d (a rollback): b is the one that goes.
    const list = try select(arena, a ++ " x\n" ++ b ++ " only-b\n" ++ c ++ " y\n" ++ d ++ " z\n" ++ a ++ " x\n");
    try testing.expectEqual(3, list.names.len);
    try testing.expectEqualStrings("y", list.names[0]);
    try testing.expectEqualStrings("z", list.names[1]);
    try testing.expectEqualStrings("x", list.names[2]);
    try testing.expectEqualStrings(c ++ " y\n" ++ d ++ " z\n" ++ a ++ " x\n", list.rewrite.?);

    // What isn't a line of this is left out, and written out.
    const odd = try select(arena, "not a line\n" ++ a ++ " x\n" ++ a ++ "\n\n" ++ a ++ "  spaced\n");
    try testing.expectEqual(2, odd.names.len);
    try testing.expectEqualStrings("x", odd.names[0]);
    try testing.expectEqualStrings(" spaced", odd.names[1]);
    try testing.expectEqualStrings(a ++ " x\n" ++ a ++ "  spaced\n", odd.rewrite.?);

    const none = try select(arena, "");
    try testing.expectEqual(0, none.names.len);
    try testing.expect(none.rewrite == null);
}

test "record and read: a list in a store, rewritten once it has older layers, and pruned" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const store: Store = .{ .io = testing.io, .root = root };

    try testing.expectEqual(0, (try read(store, arena, "x.app")).len);
    for ([_]u8{ 'a', 'b', 'c', 'd' }) |c| {
        const hex: [hex_len]u8 = @splat(c);
        try record(store, arena, "x.app", &hex, "app.exe");
        try record(store, arena, "x.app", &hex, &.{ 'f', '-', c });
    }
    try record(store, arena, "x.app", &comptime hexOf('d'), "two\nlines");
    const names = try read(store, arena, "x.app");
    try testing.expectEqual(4, names.len);
    try testing.expectEqualStrings("app.exe", names[0]);
    try testing.expectEqualStrings("f-b", names[1]);
    const text = try Io.Dir.cwd().readFileAlloc(testing.io, try filePath(store, arena, "x.app"), arena, .limited(1 << 20));
    try testing.expectEqual(6, std.mem.count(u8, text, "\n"));
    try testing.expect(std.mem.indexOf(u8, text, "f-a") == null);

    try record(store, arena, "y.runtime", &comptime hexOf('a'), "lib.dll");
    try testing.expectEqual(1, try pruneUnused(store, arena, &.{"Y.Runtime"}));
    try testing.expectEqual(0, (try read(store, arena, "x.app")).len);
    try testing.expectEqual(1, (try read(store, arena, "y.runtime")).len);
    try testing.expect(!try Store.exists(testing.io, try Store.lockPathFor(arena, try filePath(store, arena, "x.app"))));
}
