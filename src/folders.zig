//! The user's own folders (Desktop, Documents, Downloads, Music, Pictures and
//! Videos) as filesystem permissions, like Flatpak's xdg-documents.
//!
//! A run's USERPROFILE is the home in the app's data directory, and Windows
//! finds these folders from it, as `%USERPROFILE%\Documents` and so on, so an
//! app sees none of the user's (docs/findings.md). For each folder the app
//! may use, zigsaw makes the place the app looks for it a directory junction
//! to the user's folder, and the run grants the folder as it grants any host
//! path. A junction, unlike a symbolic link, needs no privilege. Deleting a
//! data directory, and changing its ACL through inheritance, remove or change
//! the junction itself, never what it points to.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");
const oci = @import("oci.zig");
const environment = @import("environment.zig");
const Context = @import("Context.zig");
const fail = Context.fail;
const note = Context.note;

pub const Grant = struct { folder: oci.UserFolder, read_only: bool };

/// A user's folder, to grant as a host path.
pub const HostPath = struct { path: []const u8, read_only: bool };

/// Gives the run whose data directory is `data_dir` the user's folders that
/// `granted` names: where the app looks for each becomes a junction to the
/// user's folder, which is returned to be granted. Folders the user doesn't
/// have are left out. The junction of a folder no longer granted is
/// removed. `env` is the run's environment, which decides where the app
/// looks.
pub fn apply(ctx: *Context, data_dir: []const u8, env: []const environment.Var, granted: []const Grant) ![]const HostPath {
    var out: std.ArrayList(HostPath) = .empty;
    for (std.enums.values(oci.UserFolder)) |folder| try applyOne(ctx, data_dir, env, folder, granted, &out);
    return out.items;
}

fn applyOne(
    ctx: *Context,
    data_dir: []const u8,
    env: []const environment.Var,
    folder: oci.UserFolder,
    granted: []const Grant,
    out: *std.ArrayList(HostPath),
) !void {
    const io = ctx.io;
    const arena = ctx.arena;
    const hook = testFolders(ctx);
    const app_path = try appPath(arena, folder, env, hook);
    const in_data = isInside(app_path, data_dir);

    // Granted twice, as "documents:ro" and "documents"? Writable wins.
    var wanted: ?Grant = null;
    for (granted) |g| if (g.folder == folder) {
        if (wanted == null or !g.read_only) wanted = g;
    };
    const grant = wanted orelse {
        if (in_data) try unlink(io, arena, app_path);
        return;
    };
    const host = try hostPath(io, arena, folder, hook) orelse {
        if (ctx.verbose) note("folder   {t}: you have no such folder", .{folder});
        if (in_data) try unlink(io, arena, app_path);
        return;
    };
    // Granting it would grant the app's own data, and the store around it.
    if (isInside(data_dir, host)) {
        note("note: the app's data directory is in your {t} folder, {s}, which zigsaw won't give it", .{ folder, host });
        if (in_data) try unlink(io, arena, app_path);
        return;
    }
    try out.append(arena, .{ .path = host, .read_only = grant.read_only });
    if (ctx.verbose) note("folder   {t}: {s}, at {s}", .{ folder, host, app_path });

    // Where the folder setting names a place outside the profile, the app
    // finds the folder itself.
    if (samePath(app_path, host)) return;
    if (!in_data) {
        note("note: the app looks for your {t} folder at {s}, which zigsaw can't link to {s}", .{ folder, app_path, host });
        return;
    }
    // A junction can only point into a local volume.
    if (std.mem.startsWith(u8, host, "\\\\")) {
        note("note: {s} is on the network, and zigsaw can't link {s} to it", .{ host, app_path });
        return;
    }
    try link(io, arena, app_path, host, folder);
}

/// Where the user's folder is, or null if they don't have it. With
/// ZIGSAW_USER_FOLDERS (for tests), the folder of that name in that
/// directory.
fn hostPath(io: Io, arena: Allocator, folder: oci.UserFolder, hook: ?[]const u8) !?[]const u8 {
    if (hook) |dir| {
        const p = try std.fs.path.resolve(arena, &.{ dir, info(folder).name });
        const stat = Io.Dir.cwd().statFile(io, p, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |e| return e,
        };
        return if (stat.kind == .directory) p else null;
    }
    var path: ?win32.LPWSTR = null;
    // Fails if the folder doesn't exist.
    const hr = win32.SHGetKnownFolderPath(&info(folder).id, 0, null, &path);
    defer win32.CoTaskMemFree(path);
    if (hr != win32.S_OK) return null;
    return try std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.span(path.?));
}

fn testFolders(ctx: *Context) ?[]const u8 {
    const dir = ctx.env.get("ZIGSAW_USER_FOLDERS") orelse return null;
    return if (dir.len > 0) dir else null;
}

/// Where the app will look for the folder: its User Shell Folders setting,
/// `%USERPROFILE%\Documents` and the like, expanded with the run's
/// environment, as Windows does in the app's process.
fn appPath(arena: Allocator, folder: oci.UserFolder, env: []const environment.Var, hook: ?[]const u8) ![]const u8 {
    const default = try std.fmt.allocPrint(arena, "%USERPROFILE%\\{s}", .{info(folder).name});
    const template = if (hook != null) default else try readShellFolder(arena, info(folder).value) orelse default;
    return expand(arena, template, env);
}

const shell_folders_key = "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders";

/// The value as stored, with its variables unexpanded; null if there's none.
fn readShellFolder(arena: Allocator, name: []const u8) !?[]const u8 {
    var key: win32.HKEY = undefined;
    if (win32.RegOpenKeyExW(win32.HKEY_CURRENT_USER, try win32.wide(arena, shell_folders_key), 0, win32.KEY_READ, &key) != win32.ERROR_SUCCESS) return null;
    defer _ = win32.RegCloseKey(key);
    const name_w = try win32.wide(arena, name);
    var size: win32.DWORD = 0;
    if (win32.RegQueryValueExW(key, name_w, null, null, null, &size) != win32.ERROR_SUCCESS) return null;
    const buf = try arena.alloc(u16, size / 2 + 1);
    size = @intCast(buf.len * 2);
    if (win32.RegQueryValueExW(key, name_w, null, null, @ptrCast(buf.ptr), &size) != win32.ERROR_SUCCESS) return null;
    const value = std.mem.sliceTo(buf[0 .. size / 2], 0);
    if (value.len == 0) return null;
    return try std.unicode.wtf16LeToWtf8Alloc(arena, value);
}

/// Replaces each `%NAME%` with the variable's value in `env`. As Windows
/// does, a variable that isn't set stays as written.
fn expand(arena: Allocator, template: []const u8, env: []const environment.Var) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = template;
    while (std.mem.indexOfScalar(u8, rest, '%')) |start| {
        const end = std.mem.indexOfScalarPos(u8, rest, start + 1, '%') orelse break;
        try out.appendSlice(arena, rest[0..start]);
        const name = rest[start + 1 .. end];
        const value = for (env) |kv| {
            if (std.os.windows.eqlIgnoreCaseWtf8(kv.name, name)) break kv.value;
        } else null;
        if (value) |v| {
            try out.appendSlice(arena, v);
            rest = rest[end + 1 ..];
        } else {
            // The second % may start a variable that is set.
            try out.appendSlice(arena, rest[start..end]);
            rest = rest[end..];
        }
    }
    try out.appendSlice(arena, rest);
    return out.items;
}

const Info = struct {
    /// The folder's name, and its directory's in a profile.
    name: []const u8,
    id: win32.GUID,
    /// Its value under User Shell Folders.
    value: []const u8,
};

fn info(folder: oci.UserFolder) Info {
    return switch (folder) {
        .desktop => .{ .name = "Desktop", .value = "Desktop", .id = .{ .Data1 = 0xB4BFCC3A, .Data2 = 0xDB2C, .Data3 = 0x424C, .Data4 = .{ 0xB0, 0x29, 0x7F, 0xE9, 0x9A, 0x87, 0xC6, 0x41 } } },
        .documents => .{ .name = "Documents", .value = "Personal", .id = .{ .Data1 = 0xFDD39AD0, .Data2 = 0x238F, .Data3 = 0x46AF, .Data4 = .{ 0xAD, 0xB4, 0x6C, 0x85, 0x48, 0x03, 0x69, 0xC7 } } },
        .downloads => .{ .name = "Downloads", .value = "{374DE290-123F-4565-9164-39C4925E467B}", .id = .{ .Data1 = 0x374DE290, .Data2 = 0x123F, .Data3 = 0x4565, .Data4 = .{ 0x91, 0x64, 0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B } } },
        .music => .{ .name = "Music", .value = "My Music", .id = .{ .Data1 = 0x4BD8D571, .Data2 = 0x6D19, .Data3 = 0x48D3, .Data4 = .{ 0xBE, 0x97, 0x42, 0x22, 0x20, 0x08, 0x0E, 0x43 } } },
        .pictures => .{ .name = "Pictures", .value = "My Pictures", .id = .{ .Data1 = 0x33E28130, .Data2 = 0x4E1E, .Data3 = 0x4676, .Data4 = .{ 0x83, 0x5A, 0x98, 0x39, 0x5C, 0x3B, 0xC3, 0xBB } } },
        .videos => .{ .name = "Videos", .value = "My Video", .id = .{ .Data1 = 0x18989B1D, .Data2 = 0x99B5, .Data3 = 0x455B, .Data4 = .{ 0x84, 0x1C, 0xAB, 0x7C, 0x74, 0xE4, 0xDD, 0xFC } } },
    };
}

// ---------------------------------------------------------------------------
// Junctions

/// What is at a place where a folder's junction goes.
const Place = union(enum) {
    missing,
    /// A directory link: a junction, with its target, or another kind.
    link: ?[]const u8,
    empty_dir,
    /// A directory with files in it, or a file: the app's own.
    other,
};

fn inspect(io: Io, arena: Allocator, path: []const u8) !Place {
    const attrs = win32.GetFileAttributesW(try win32.wide(arena, path));
    if (attrs == win32.INVALID_FILE_ATTRIBUTES) {
        const code = win32.GetLastError();
        if (code == win32.ERROR_FILE_NOT_FOUND or code == win32.ERROR_PATH_NOT_FOUND) return .missing;
        return fail("reading {s}: error {d} ({s})", .{ path, code, win32.errorName(code) });
    }
    if (attrs & win32.FILE_ATTRIBUTE_DIRECTORY == 0) return .other;
    if (attrs & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0) return .{ .link = try junctionTarget(arena, path) };
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    return if (try it.next(io) == null) .empty_dir else .other;
}

/// Makes `at` a junction to the directory `target`, replacing a junction
/// that points elsewhere or an empty directory, but never the app's own
/// files.
fn link(io: Io, arena: Allocator, at: []const u8, target: []const u8, folder: oci.UserFolder) !void {
    switch (try inspect(io, arena, at)) {
        .missing => {},
        .link => |old| {
            if (old) |t| if (samePath(t, target)) return;
            try removeLink(arena, at);
        },
        .empty_dir => try removeLink(arena, at),
        .other => {
            note("note: kept {s}, which has the app's own files; move them out, and its {t} folder will be yours", .{ at, folder });
            return;
        },
    }
    if (std.fs.path.dirname(at)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    try createJunction(arena, at, target);
}

/// Removes the directory link at `at`, if there is one.
fn unlink(io: Io, arena: Allocator, at: []const u8) !void {
    switch (try inspect(io, arena, at)) {
        .link => try removeLink(arena, at),
        else => {},
    }
}

/// Removes a directory link, or an empty directory: RemoveDirectoryW
/// removes a link itself, whatever it points to.
fn removeLink(arena: Allocator, path: []const u8) !void {
    if (win32.RemoveDirectoryW(try win32.wide(arena, path)) == 0) return win32.lastErrorFail("RemoveDirectoryW");
}

fn createJunction(arena: Allocator, at: []const u8, target: []const u8) !void {
    const at_w = try win32.wide(arena, at);
    if (win32.CreateDirectoryW(at_w, null) == 0) return win32.lastErrorFail("CreateDirectoryW");
    errdefer _ = win32.RemoveDirectoryW(at_w);
    const h = win32.CreateFileW(at_w, win32.GENERIC_WRITE, 0, null, win32.OPEN_EXISTING, win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OPEN_REPARSE_POINT, null);
    if (h == win32.INVALID_HANDLE_VALUE) return win32.lastErrorFail("CreateFileW");
    defer _ = win32.CloseHandle(h);
    const buf = try junctionData(arena, target);
    var returned: win32.DWORD = 0;
    if (win32.DeviceIoControl(h, win32.FSCTL_SET_REPARSE_POINT, buf.ptr, @intCast(buf.len), null, 0, &returned, null) == 0)
        return fail("making {s} a link to {s}: error {d} ({s})", .{ at, target, win32.GetLastError(), win32.errorName(win32.GetLastError()) });
}

const nt_prefix = "\\??\\";

/// A junction's reparse data: the NT path of `target` to substitute, and
/// `target` itself to print.
fn junctionData(arena: Allocator, target: []const u8) ![]align(4) u8 {
    const substitute = try std.unicode.wtf8ToWtf16LeAlloc(arena, try std.mem.concat(arena, u8, &.{ nt_prefix, target }));
    const print = try std.unicode.wtf8ToWtf16LeAlloc(arena, target);
    const names_size = (substitute.len + 1 + print.len + 1) * 2;
    const Header = win32.MOUNT_POINT_REPARSE_HEADER;
    // The header's first 8 bytes don't count in ReparseDataLength.
    const data_length = @sizeOf(Header) - 8 + names_size;
    if (data_length > win32.MAXIMUM_REPARSE_DATA_BUFFER_SIZE - 8) return fail("{s} is too long a path to link to", .{target});
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
fn junctionTarget(arena: Allocator, path: []const u8) !?[]const u8 {
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
    return parseJunction(arena, buf[0..returned]);
}

fn parseJunction(arena: Allocator, data: []align(4) const u8) !?[]const u8 {
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

// ---------------------------------------------------------------------------
// Paths

/// Whether `path` is inside the directory `dir`, ignoring case, with '/'
/// and '\' alike.
fn isInside(path: []const u8, dir: []const u8) bool {
    const d = std.mem.trimEnd(u8, dir, "\\/");
    if (path.len <= d.len + 1 or !eqlPaths(path[0..d.len], d)) return false;
    return path[d.len] == '\\' or path[d.len] == '/';
}

fn samePath(a: []const u8, b: []const u8) bool {
    const x = std.mem.trimEnd(u8, a, "\\/");
    const y = std.mem.trimEnd(u8, b, "\\/");
    return x.len == y.len and eqlPaths(x, y);
}

fn eqlPaths(a: []const u8, b: []const u8) bool {
    for (a, b) |x, y| {
        const sx = x == '/' or x == '\\';
        const sy = y == '/' or y == '\\';
        if (sx and sy) continue;
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

test expand {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const env: []const environment.Var = &.{
        .{ .name = "USERPROFILE", .value = "D:\\store\\data\\app\\home" },
        .{ .name = "SystemDrive", .value = "C:" },
    };
    try std.testing.expectEqualStrings("D:\\store\\data\\app\\home\\Documents", try expand(arena, "%USERPROFILE%\\Documents", env));
    try std.testing.expectEqualStrings("D:\\store\\data\\app\\home\\Documents", try expand(arena, "%userprofile%\\Documents", env));
    try std.testing.expectEqualStrings("C:\\Users\\Ann\\OneDrive\\Documents", try expand(arena, "C:\\Users\\Ann\\OneDrive\\Documents", env));
    try std.testing.expectEqualStrings("%OneDrive%\\Documents", try expand(arena, "%OneDrive%\\Documents", env));
    try std.testing.expectEqualStrings("50%C:\\x", try expand(arena, "50%%SystemDrive%\\x", env));
    try std.testing.expectEqualStrings("a%b", try expand(arena, "a%b", env));
}

test isInside {
    try std.testing.expect(isInside("D:\\s\\data\\app\\home\\Documents", "D:\\s\\data\\app"));
    try std.testing.expect(isInside("d:/S/data/APP/home/Documents", "D:\\s\\data\\app\\"));
    try std.testing.expect(!isInside("D:\\s\\data\\app", "D:\\s\\data\\app"));
    try std.testing.expect(!isInside("D:\\s\\data\\apple\\x", "D:\\s\\data\\app"));
    try std.testing.expect(!isInside("C:\\Users\\Ann\\Documents", "D:\\s\\data\\app"));
    try std.testing.expect(samePath("C:\\Users\\Ann\\Documents\\", "c:/users/ann/documents"));
    try std.testing.expect(!samePath("C:\\Users\\Ann\\Documents2", "C:\\Users\\Ann\\Documents"));
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
    try link(io, arena, at, docs, .documents);
    try std.testing.expectEqualStrings(docs, (try inspect(io, arena, at)).link.?);
    try std.testing.expect(try Store.exists(io, try std.fs.path.join(arena, &.{ at, "keep.txt" })));
    // Again: nothing to do.
    try link(io, arena, at, docs, .documents);
    // Elsewhere: replaced.
    try link(io, arena, at, other, .documents);
    try std.testing.expectEqualStrings(other, (try inspect(io, arena, at)).link.?);

    try unlink(io, arena, at);
    try std.testing.expectEqual(Place.missing, try inspect(io, arena, at));
    for ([_][]const u8{ docs, other }) |d| try std.testing.expect(try Store.exists(io, try std.fs.path.join(arena, &.{ d, "keep.txt" })));

    // The app's own Documents stays; an empty one is replaced.
    try tmp.dir.createDirPath(io, "home\\Documents");
    try tmp.dir.writeFile(io, .{ .sub_path = "home\\Documents\\mine.txt", .data = "x" });
    try link(io, arena, at, docs, .documents);
    try std.testing.expectEqual(Place.other, try inspect(io, arena, at));
    try tmp.dir.deleteFile(io, "home\\Documents\\mine.txt");
    try link(io, arena, at, docs, .documents);
    try std.testing.expectEqualStrings(docs, (try inspect(io, arena, at)).link.?);

    // Deleting the tree that has the link leaves the folder it points to.
    try Store.deleteTree(io, arena, try std.fs.path.join(arena, &.{ root, "home" }));
    try std.testing.expect(try Store.exists(io, try std.fs.path.join(arena, &.{ docs, "keep.txt" })));
}

const Store = @import("Store.zig");
