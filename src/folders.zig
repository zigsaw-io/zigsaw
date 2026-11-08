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
//!
//! A store that isn't the default one, %LOCALAPPDATA%\zigsaw, leaves the real
//! folders out until told otherwise (`zigsaw override --global --real-folders`).
//! Such a store is most often a test's or an experiment's, and a run in it that
//! labelled your Documents low leaves it so when the store is deleted, as
//! happened twice while building zigsaw.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");
const junction = @import("junction.zig");
const oci = @import("oci.zig");
const environment = @import("environment.zig");
const override = @import("override.zig");
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
    var left_out: std.ArrayList([]const u8) = .empty;
    for (std.enums.values(oci.UserFolder)) |folder| try applyOne(ctx, data_dir, env, folder, granted, &out, &left_out);
    if (left_out.items.len > 0) note("note: left out your {s}: this store, {s}, isn't your default one, so its apps don't get your real folders. `zigsaw override --global --real-folders` lets them", .{
        try std.mem.join(ctx.arena, ", ", left_out.items),
        ctx.store.root,
    });
    return out.items;
}

fn applyOne(
    ctx: *Context,
    data_dir: []const u8,
    env: []const environment.Var,
    folder: oci.UserFolder,
    granted: []const Grant,
    out: *std.ArrayList(HostPath),
    left_out: *std.ArrayList([]const u8),
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
    if (!try mayUseFolders(ctx)) {
        try left_out.append(arena, info(folder).name);
        if (in_data) try unlink(io, arena, app_path);
        return;
    }
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

/// Where the user's folder is, as runs grant it; null if they don't have
/// it.
pub fn hostPathOf(ctx: *Context, folder: oci.UserFolder) !?[]const u8 {
    if (!try mayUseFolders(ctx)) return null;
    return hostPath(ctx.io, ctx.arena, folder, testFolders(ctx));
}

/// The profile and those of the user's folders they have, whether this
/// store's apps may use them or not: where `zigsaw grants` looks for labels
/// no record explains. With ZIGSAW_USER_FOLDERS, that directory and the
/// folders in it.
pub fn allHostPaths(ctx: *Context) ![]const []const u8 {
    const arena = ctx.arena;
    const hook = testFolders(ctx);
    var out: std.ArrayList([]const u8) = .empty;
    if (hook orelse ctx.env.get("USERPROFILE")) |profile| try out.append(arena, profile);
    for (std.enums.values(oci.UserFolder)) |folder|
        if (try hostPath(ctx.io, arena, folder, hook)) |p| try out.append(arena, p);
    return out.items;
}

/// Whether a run in this store gets the folders it names: test folders
/// always, the real ones as `realFoldersAllowed` says.
fn mayUseFolders(ctx: *Context) !bool {
    if (testFolders(ctx) != null) return true;
    const saved = (try override.load(ctx.store, ctx.arena, null)).real_folders;
    return realFoldersAllowed(try isDefaultStore(ctx), saved);
}

/// What's saved goes; without that, only the default store's apps get them.
fn realFoldersAllowed(default_store: bool, saved: ?bool) bool {
    return saved orelse default_store;
}

/// Whether the store is the one zigsaw uses when ZIGSAW_HOME isn't set. A shim
/// sets ZIGSAW_HOME to its own store, so whether it's set doesn't say.
fn isDefaultStore(ctx: *Context) !bool {
    const arena = ctx.arena;
    const local = ctx.env.get("LOCALAPPDATA") orelse return false;
    const default = try std.fs.path.join(arena, &.{ local, "zigsaw" });
    if (samePath(ctx.store.root, default)) return true;
    // The same place by another name: a short name, or a link.
    const dir = Io.Dir.cwd();
    const a = dir.realPathFileAlloc(ctx.io, ctx.store.root, arena) catch return false;
    const b = dir.realPathFileAlloc(ctx.io, default, arena) catch return false;
    return samePath(a, b);
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
// Junctions (see junction.zig)

/// Makes the place the app looks for `folder` a junction to the user's,
/// unless the app has files of its own there.
fn link(io: Io, arena: Allocator, at: []const u8, target: []const u8, folder: oci.UserFolder) !void {
    if (try junction.link(io, arena, at, target) == .kept)
        note("note: kept {s}, which has the app's own files; move them out, and its {t} folder will be yours", .{ at, folder });
}

fn unlink(io: Io, arena: Allocator, at: []const u8) !void {
    _ = try junction.unlink(io, arena, at);
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

test realFoldersAllowed {
    try std.testing.expect(realFoldersAllowed(true, null));
    try std.testing.expect(!realFoldersAllowed(false, null));
    try std.testing.expect(realFoldersAllowed(false, true));
    try std.testing.expect(!realFoldersAllowed(true, false));
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
