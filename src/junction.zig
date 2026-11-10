//! Directory junctions: how a user's folder (folders.zig) or a volume
//! (volumes.zig) appears inside an app's data directory. A junction, unlike a
//! symbolic link, needs no privilege, and can only point into a local
//! volume. Deleting a tree, and changing its ACL through inheritance, stop at
//! a junction: they remove or change the link itself, never what it points
//! to. Windows grants or denies access through a junction by what it points
//! to.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");
const Context = @import("Context.zig");
const fail = Context.fail;

/// What is at a place where a junction goes.
pub const Place = union(enum) {
    missing,
    /// A directory link: a junction, with its target, or another kind.
    link: ?[]const u8,
    empty_dir,
    /// A directory with files in it, or a file: the app's own.
    other,
};

pub fn inspect(io: Io, arena: Allocator, path: []const u8) !Place {
    const attrs = win32.GetFileAttributesW(try win32.wide(arena, path));
    if (attrs == win32.INVALID_FILE_ATTRIBUTES) {
        const code = win32.GetLastError();
        if (code == win32.ERROR_FILE_NOT_FOUND or code == win32.ERROR_PATH_NOT_FOUND) return .missing;
        return fail("reading {s}: error {d} ({s})", .{ path, code, win32.errorName(code) });
    }
    if (attrs & win32.FILE_ATTRIBUTE_DIRECTORY == 0) return .other;
    if (attrs & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0) return .{ .link = try target(arena, path) };
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    return if (try it.next(io) == null) .empty_dir else .other;
}

/// What `link` did.
pub const Linked = enum {
    made,
    /// The junction was there already.
    already,
    /// The place has files of the app's own, which stay: no junction.
    kept,
};

/// Makes `at` a junction to the directory `to`, replacing a junction that
/// points elsewhere or an empty directory, but never the app's own files.
/// Makes the directories above `at` that are missing.
pub fn link(io: Io, arena: Allocator, at: []const u8, to: []const u8) !Linked {
    switch (try inspect(io, arena, at)) {
        .missing => {},
        .link => |old| {
            if (old) |t| if (samePath(t, to)) return .already;
            try removeLink(arena, at);
        },
        .empty_dir => try removeLink(arena, at),
        .other => return .kept,
    }
    // Unless it's there: it may itself be a link, which isn't a directory to
    // make (a volume mounted as an app's data directory, see volumes.zig).
    if (std.fs.path.dirname(at)) |parent| {
        const attrs = win32.GetFileAttributesW(try win32.wide(arena, parent));
        if (attrs == win32.INVALID_FILE_ATTRIBUTES or attrs & win32.FILE_ATTRIBUTE_DIRECTORY == 0) try Io.Dir.cwd().createDirPath(io, parent);
    }
    try create(arena, at, to);
    return .made;
}

/// Removes the directory link at `at`, if there is one, and says whether
/// there was.
pub fn unlink(io: Io, arena: Allocator, at: []const u8) !bool {
    switch (try inspect(io, arena, at)) {
        .link => {
            try removeLink(arena, at);
            return true;
        },
        else => return false,
    }
}

/// Removes a directory link, or an empty directory: RemoveDirectoryW
/// removes a link itself, whatever it points to.
fn removeLink(arena: Allocator, path: []const u8) !void {
    if (win32.RemoveDirectoryW(try win32.wide(arena, path)) == 0) return win32.lastErrorFail("RemoveDirectoryW");
}

fn create(arena: Allocator, at: []const u8, to: []const u8) !void {
    const at_w = try win32.wide(arena, at);
    if (win32.CreateDirectoryW(at_w, null) == 0) return win32.lastErrorFail("CreateDirectoryW");
    errdefer _ = win32.RemoveDirectoryW(at_w);
    const h = win32.CreateFileW(at_w, win32.GENERIC_WRITE, 0, null, win32.OPEN_EXISTING, win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OPEN_REPARSE_POINT, null);
    if (h == win32.INVALID_HANDLE_VALUE) return win32.lastErrorFail("CreateFileW");
    defer _ = win32.CloseHandle(h);
    const buf = try reparseData(arena, to);
    var returned: win32.DWORD = 0;
    if (win32.DeviceIoControl(h, win32.FSCTL_SET_REPARSE_POINT, buf.ptr, @intCast(buf.len), null, 0, &returned, null) == 0)
        return fail("making {s} a link to {s}: error {d} ({s})", .{ at, to, win32.GetLastError(), win32.errorName(win32.GetLastError()) });
}

const nt_prefix = "\\??\\";

/// A junction's reparse data: the NT path of `to` to substitute, and `to`
/// itself to print.
fn reparseData(arena: Allocator, to: []const u8) ![]align(4) u8 {
    const substitute = try std.unicode.wtf8ToWtf16LeAlloc(arena, try std.mem.concat(arena, u8, &.{ nt_prefix, to }));
    const print = try std.unicode.wtf8ToWtf16LeAlloc(arena, to);
    const names_size = (substitute.len + 1 + print.len + 1) * 2;
    const Header = win32.MOUNT_POINT_REPARSE_HEADER;
    // The header's first 8 bytes don't count in ReparseDataLength.
    const data_length = @sizeOf(Header) - 8 + names_size;
    if (data_length > win32.MAXIMUM_REPARSE_DATA_BUFFER_SIZE - 8) return fail("{s} is too long a path to link to", .{to});
    const buf = try arena.alignedAlloc(u8, .of(u32), @sizeOf(Header) + names_size);
    @memset(buf, 0);
    const header: *Header = @ptrCast(buf.ptr);
    header.* = .{
        .ReparseTag = win32.IO_REPARSE_TAG_MOUNT_POINT,
        .ReparseDataLength = @intCast(data_length),
        .SubstituteNameOffset = 0,
        .SubstituteNameLength = @intCast(substitute.len * 2),
        .PrintNameOffset = @intCast((substitute.len + 1) * 2),
        .PrintNameLength = @intCast(print.len * 2),
    };
    const names = buf[@sizeOf(Header)..];
    @memcpy(names[0 .. substitute.len * 2], std.mem.sliceAsBytes(substitute));
    @memcpy(names[header.PrintNameOffset..][0 .. print.len * 2], std.mem.sliceAsBytes(print));
    return buf;
}

/// Where the junction at `path` points; null if it's another kind of link.
pub fn target(arena: Allocator, path: []const u8) !?[]const u8 {
    const h = win32.CreateFileW(
        try win32.wide(arena, path),
        win32.FILE_READ_ATTRIBUTES,
        win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
        null,
        win32.OPEN_EXISTING,
        win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OPEN_REPARSE_POINT,
        null,
    );
    if (h == win32.INVALID_HANDLE_VALUE) return win32.lastErrorFail("CreateFileW");
    defer _ = win32.CloseHandle(h);
    const buf = try arena.alignedAlloc(u8, .of(u32), win32.MAXIMUM_REPARSE_DATA_BUFFER_SIZE);
    var returned: win32.DWORD = 0;
    if (win32.DeviceIoControl(h, win32.FSCTL_GET_REPARSE_POINT, null, 0, buf.ptr, @intCast(buf.len), &returned, null) == 0)
        return win32.lastErrorFail("reading a link");
    return parse(arena, buf[0..returned]);
}

fn parse(arena: Allocator, data: []align(4) const u8) !?[]const u8 {
    const Header = win32.MOUNT_POINT_REPARSE_HEADER;
    if (data.len < @sizeOf(Header)) return null;
    const header: *const Header = @ptrCast(data.ptr);
    if (header.ReparseTag != win32.IO_REPARSE_TAG_MOUNT_POINT) return null;
    const names = data[@sizeOf(Header)..];
    const start = header.SubstituteNameOffset;
    const len = header.SubstituteNameLength;
    if (start + len > names.len or start % 2 != 0 or len % 2 != 0) return null;
    const units = try arena.alloc(u16, len / 2);
    @memcpy(std.mem.sliceAsBytes(units), names[start..][0..len]);
    const substitute = try std.unicode.wtf16LeToWtf8Alloc(arena, units);
    return if (std.mem.startsWith(u8, substitute, nt_prefix)) substitute[nt_prefix.len..] else substitute;
}

/// Whether two paths name the same place: ignoring ASCII case, '/' for '\',
/// and separators at the end.
fn samePath(a: []const u8, b: []const u8) bool {
    const x = std.mem.trimEnd(u8, a, "\\/");
    const y = std.mem.trimEnd(u8, b, "\\/");
    if (x.len != y.len) return false;
    for (x, y) |c, d| {
        if ((c == '\\' or c == '/') and (d == '\\' or d == '/')) continue;
        if (std.ascii.toLower(c) != std.ascii.toLower(d)) return false;
    }
    return true;
}

test "junctions: made, read back, replaced, and removed without touching their target" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    for ([_][]const u8{ "docs", "other" }) |d| try tmp.dir.createDirPath(io, d);
    try tmp.dir.writeFile(io, .{ .sub_path = "docs\\keep.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "other\\keep.txt", .data = "x" });
    const docs = try std.fs.path.join(arena, &.{ root, "docs" });
    const other = try std.fs.path.join(arena, &.{ root, "other" });
    const at = try std.fs.path.join(arena, &.{ root, "home", "Documents" });

    try std.testing.expectEqual(Place.missing, try inspect(io, arena, at));
    try std.testing.expectEqual(Linked.made, try link(io, arena, at, docs));
    try std.testing.expectEqualStrings(docs, (try inspect(io, arena, at)).link.?);
    try std.testing.expect(try Store.exists(io, try std.fs.path.join(arena, &.{ at, "keep.txt" })));
    // Again: nothing to do.
    try std.testing.expectEqual(Linked.already, try link(io, arena, at, docs));
    // Elsewhere: replaced.
    try std.testing.expectEqual(Linked.made, try link(io, arena, at, other));
    try std.testing.expectEqualStrings(other, (try inspect(io, arena, at)).link.?);

    try std.testing.expect(try unlink(io, arena, at));
    try std.testing.expect(!try unlink(io, arena, at));
    try std.testing.expectEqual(Place.missing, try inspect(io, arena, at));
    for ([_][]const u8{ docs, other }) |d| try std.testing.expect(try Store.exists(io, try std.fs.path.join(arena, &.{ d, "keep.txt" })));

    // The app's own Documents stays; an empty one is replaced.
    try tmp.dir.createDirPath(io, "home\\Documents");
    try tmp.dir.writeFile(io, .{ .sub_path = "home\\Documents\\mine.txt", .data = "x" });
    try std.testing.expectEqual(Linked.kept, try link(io, arena, at, docs));
    try std.testing.expectEqual(Place.other, try inspect(io, arena, at));
    // Unlinking leaves a directory that isn't a link alone.
    try std.testing.expect(!try unlink(io, arena, at));
    try tmp.dir.deleteFile(io, "home\\Documents\\mine.txt");
    try std.testing.expectEqual(Linked.made, try link(io, arena, at, docs));
    try std.testing.expectEqualStrings(docs, (try inspect(io, arena, at)).link.?);

    // Deleting the tree that has the link leaves the folder it points to.
    try Store.deleteTree(io, arena, try std.fs.path.join(arena, &.{ root, "home" }));
    try std.testing.expect(try Store.exists(io, try std.fs.path.join(arena, &.{ docs, "keep.txt" })));
}

const Store = @import("Store.zig");
