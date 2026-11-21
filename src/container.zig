//! Build commands in a container, without the network (iteration 103).
//!
//! A recipe that says `"contained": true` has its build commands run in an
//! AppContainer of zigsaw's, `zigsaw.build`, which holds no network
//! capability: Windows refuses its processes the internet and this machine's
//! servers, and lets them write only the build root (see builder.zig's
//! `BuildRoot.contain`). Recipes say so once a build in the container has
//! made the same image as without one, since some toolchains don't run in a
//! container at all (see docs/gaps.md).
//!
//! Not every Windows can run builds that way: Windows Server 2025, which CI
//! runs on, denies containers NUL and their own paths, which compilers need.
//! So a build first asks, by running zigsaw in the container as
//! `zigsaw build-check`; where that fails, the commands run as they always
//! have, kept off the network only by proxy variables, and the build says so.
//! The answer is kept in the store, for this zigsaw on this Windows build.
//!
//! The image doesn't record which way it was built: it is the same either way.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const process = @import("process.zig");
const regkey = @import("regkey.zig");
const win32 = @import("win32.zig");

/// Where `zigsaw build` runs build commands: in the container if the recipe
/// says it can and Windows lets it (`auto`), always in it (failing where
/// Windows doesn't let it), or never.
pub const Sandbox = enum { auto, appcontainer, soft };

/// The check's answer: null if builds run in the container here, else why
/// not ("NUL: error 5").
pub const Verdict = ?[]const u8;

const cache_name = "build-container.txt";

/// Whether this Windows runs build commands in the container: asked of
/// `build-check` in it, in the build root `root` (B:), the first time this
/// zigsaw builds on this Windows build, and remembered.
pub fn check(ctx: *Context, root: []const u8, security: *const win32.SECURITY_CAPABILITIES) !Verdict {
    const io = ctx.io;
    const arena = ctx.arena;
    const key = try cacheKey(ctx);
    if (try remembered(ctx, key)) |known| return known.verdict;

    // A copy of zigsaw in the root: the container may read nothing else of
    // this machine's but Windows' own files and what builds are granted.
    const self = try win32.selfExePath(arena);
    const exe = try std.fs.path.join(arena, &.{ root, "zigsaw-build-check.exe" });
    const answer = try std.fs.path.join(arena, &.{ root, "zigsaw-build-check.txt" });
    defer for ([_][]const u8{ exe, answer }) |p| Io.Dir.cwd().deleteFile(io, p) catch {};
    try Io.Dir.cwd().copyFile(self, Io.Dir.cwd(), exe, io, .{});
    Io.Dir.cwd().deleteFile(io, answer) catch {};
    const in_root = drive_letter ++ "\\zigsaw-build-check.exe";
    var child = try process.start(arena, .{
        .exe = in_root,
        .command_line = try process.buildCommandLine(arena, in_root, &.{ "build-check", drive_letter ++ "\\zigsaw-build-check.txt" }),
        .cwd = drive_letter ++ "\\",
        .security = security,
        .stdio = ctx.childStdio(),
    });
    const code = try child.wait();
    const said = Io.Dir.cwd().readFileAlloc(io, answer, arena, .limited(4096)) catch "";
    const verdict: Verdict = if (code == 0 and std.mem.eql(u8, std.mem.trim(u8, said, " \r\n"), "ok"))
        null
    else if (std.mem.trim(u8, said, " \r\n").len > 0)
        try arena.dupe(u8, std.mem.trim(u8, said, " \r\n"))
    else
        try std.fmt.allocPrint(arena, "zigsaw didn't start in it (exit code 0x{x})", .{code});
    try remember(ctx, key, verdict);
    return verdict;
}

/// What the store remembers of the check, for `doctor`: the verdict, and
/// whether it was for this zigsaw on this Windows build.
pub const Remembered = struct { verdict: Verdict, current: bool };

pub fn recall(ctx: *Context) !?Remembered {
    const key = try cacheKey(ctx);
    const text = try readCache(ctx) orelse return null;
    const parsed = parse(text) orelse return null;
    return .{ .verdict = parsed.verdict, .current = std.mem.eql(u8, parsed.key, key) };
}

fn remembered(ctx: *Context, key: []const u8) !?Remembered {
    const text = try readCache(ctx) orelse return null;
    const parsed = parse(text) orelse return null;
    if (!std.mem.eql(u8, parsed.key, key)) return null;
    return .{ .verdict = parsed.verdict, .current = true };
}

fn readCache(ctx: *Context) !?[]const u8 {
    const p = try ctx.store.path(ctx.arena, &.{ "cache", cache_name });
    return Io.Dir.cwd().readFileAlloc(ctx.io, p, ctx.arena, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| e,
    };
}

fn remember(ctx: *Context, key: []const u8, verdict: Verdict) !void {
    const p = try ctx.store.path(ctx.arena, &.{ "cache", cache_name });
    try Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(p).?);
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = p, .data = try format(ctx.arena, key, verdict) });
}

/// The cache's text: the key on the first line, then "ok" or why not.
fn format(arena: Allocator, key: []const u8, verdict: Verdict) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}\n{s}\n", .{ key, verdict orelse "ok" });
}

fn parse(text: []const u8) ?struct { key: []const u8, verdict: Verdict } {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const key = std.mem.trim(u8, lines.next() orelse return null, " \r");
    const said = std.mem.trim(u8, lines.next() orelse return null, " \r");
    if (key.len == 0 or said.len == 0) return null;
    return .{ .key = key, .verdict = if (std.mem.eql(u8, said, "ok")) null else said };
}

/// This zigsaw, by its file's hash, and Windows' version with its update
/// revision: an update has lifted what containers were denied before
/// (docs/findings.md, iteration 8).
fn cacheKey(ctx: *Context) ![]const u8 {
    const arena = ctx.arena;
    const self = try Store.sha256File(ctx.io, try win32.selfExePath(arena));
    var v: std.os.windows.RTL_OSVERSIONINFOW = undefined;
    v.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);
    _ = std.os.windows.ntdll.RtlGetVersion(&v);
    var ubr: win32.DWORD = 0;
    if (try regkey.Key.open(arena, win32.HKEY_LOCAL_MACHINE, "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion", win32.KEY_READ)) |k| {
        defer k.close();
        ubr = (try k.getDword(arena, "UBR")) orelse 0;
    }
    return std.fmt.allocPrint(arena, "zigsaw {s} on Windows {d}.{d}.{d}.{d}", .{ self.hex[0..16], v.dwMajorVersion, v.dwMinorVersion, v.dwBuildNumber, ubr });
}

const drive_letter = @import("drive.zig").letter;

// ---------------------------------------------------------------------------
// The check itself, in the container

extern "kernel32" fn GetFinalPathNameByHandleW(file: win32.HANDLE, path: [*]u16, len: win32.DWORD, flags: win32.DWORD) callconv(.winapi) win32.DWORD;

/// `zigsaw build-check <answer file>`, run in the container: what compilers
/// need there, Windows' own NUL and their own paths with drive letters, and
/// the build root to write. Writes "ok", or the first that fails, to the
/// answer file, and exits 0 only for "ok".
pub fn selfCheck(arena: Allocator, io: Io, answer: []const u8) !u32 {
    const failed = try firstFailure(arena, io);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = answer, .data = failed orelse "ok" });
    return if (failed == null) 0 else 1;
}

fn firstFailure(arena: Allocator, io: Io) !?[]const u8 {
    const GENERIC_WRITE: win32.DWORD = 0x40000000;
    const FILE_READ_ATTRIBUTES: win32.DWORD = 0x80;
    const share: win32.DWORD = 0x7;
    if (openError(std.unicode.utf8ToUtf16LeStringLiteral("NUL"), win32.GENERIC_READ | GENERIC_WRITE)) |code|
        return try std.fmt.allocPrint(arena, "NUL: error {d}", .{code});

    // As zig and Go find their own files.
    const self = try win32.wide(arena, try win32.selfExePath(arena));
    const h = win32.CreateFileW(self, FILE_READ_ATTRIBUTES, share, null, win32.OPEN_EXISTING, 0, null);
    if (h == win32.INVALID_HANDLE_VALUE) return try std.fmt.allocPrint(arena, "its own file: error {d}", .{win32.GetLastError()});
    defer _ = win32.CloseHandle(h);
    var buf: [32 * 1024]u16 = undefined;
    const len = GetFinalPathNameByHandleW(h, &buf, buf.len, 0);
    if (len == 0 or len >= buf.len) return try std.fmt.allocPrint(arena, "its own path with a drive letter: error {d}", .{win32.GetLastError()});

    const probe = "zigsaw-build-check.written";
    Io.Dir.cwd().writeFile(io, .{ .sub_path = probe, .data = "x" }) catch |err|
        return try std.fmt.allocPrint(arena, "writing in the build root: {t}", .{err});
    Io.Dir.cwd().deleteFile(io, probe) catch {};
    return null;
}

fn openError(path: [*:0]const u16, access: win32.DWORD) ?win32.DWORD {
    const h = win32.CreateFileW(path, access, 0x7, null, win32.OPEN_EXISTING, 0, null);
    if (h == win32.INVALID_HANDLE_VALUE) return win32.GetLastError();
    _ = win32.CloseHandle(h);
    return null;
}

test "the remembered check" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ok = parse(try format(arena, "zigsaw abc on Windows 10.0.26300.1", null)).?;
    try std.testing.expectEqualStrings("zigsaw abc on Windows 10.0.26300.1", ok.key);
    try std.testing.expectEqual(@as(Verdict, null), ok.verdict);
    const denied = parse("k\r\nNUL: error 5\r\n").?;
    try std.testing.expectEqualStrings("NUL: error 5", denied.verdict.?);
    try std.testing.expectEqual(null, parse("k\n"));
    try std.testing.expectEqual(null, parse(""));
}
