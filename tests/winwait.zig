//! Waits for a visible top-level window whose title has a given text, prints
//! its title, and closes it if asked, as its close button would, waiting for
//! its program to end: GUI apps save their settings as they close. Built by
//! `zig build winwait` for tests/guiapps.sh.
//!
//!   zigsaw-winwait <text> <seconds> [--close]
//!
//! A text `class:<name>` matches the window's class name instead, exactly:
//! for windows whose title is whatever they show.
//!
//! Exits 0 when it found the window (and, with --close, the program ended),
//! 1 when no such window appeared in time, 2 when the program didn't end.

const std = @import("std");

const BOOL = c_int;
const HWND = *opaque {};
const LPARAM = isize;
const DWORD = u32;
const HANDLE = *anyopaque;

extern "user32" fn EnumWindows(callback: *const fn (HWND, LPARAM) callconv(.winapi) BOOL, param: LPARAM) callconv(.winapi) BOOL;
extern "user32" fn IsWindowVisible(window: HWND) callconv(.winapi) BOOL;
extern "user32" fn GetWindowTextW(window: HWND, text: [*]u16, max: c_int) callconv(.winapi) c_int;
extern "user32" fn GetClassNameW(window: HWND, name: [*]u16, max: c_int) callconv(.winapi) c_int;
extern "user32" fn GetWindowThreadProcessId(window: HWND, pid: *DWORD) callconv(.winapi) DWORD;
extern "user32" fn PostMessageW(window: HWND, msg: u32, wparam: usize, lparam: LPARAM) callconv(.winapi) BOOL;
extern "kernel32" fn OpenProcess(access: DWORD, inherit: BOOL, pid: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

const WM_CLOSE: u32 = 0x0010;
const SYNCHRONIZE: DWORD = 0x00100000;
const WAIT_OBJECT_0: DWORD = 0;

const Search = struct {
    want: []const u8,
    found: ?HWND = null,
    title: [512]u8 = undefined,
    title_len: usize = 0,
};

fn visit(window: HWND, param: LPARAM) callconv(.winapi) BOOL {
    const search: *Search = @ptrFromInt(@as(usize, @bitCast(param)));
    if (IsWindowVisible(window) == 0) return 1;
    var wide: [512]u16 = undefined;
    var buf: [512 * 3]u8 = undefined;
    if (std.mem.startsWith(u8, search.want, "class:")) {
        const class_len = GetClassNameW(window, &wide, wide.len);
        if (class_len <= 0) return 1;
        const n = std.unicode.wtf16LeToWtf8(&buf, wide[0..@intCast(class_len)]);
        if (!std.mem.eql(u8, buf[0..n], search.want["class:".len..])) return 1;
    }
    const len = GetWindowTextW(window, &wide, wide.len);
    if (len <= 0) return 1;
    const n = std.unicode.wtf16LeToWtf8(&buf, wide[0..@intCast(len)]);
    if (!std.mem.startsWith(u8, search.want, "class:") and std.ascii.indexOfIgnoreCase(buf[0..n], search.want) == null) return 1;
    search.found = window;
    search.title_len = @min(n, search.title.len);
    @memcpy(search.title[0..search.title_len], buf[0..search.title_len]);
    return 0;
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: zigsaw-winwait <text> <seconds> [--close]\n", .{});
        return 1;
    }
    const close = args.len > 3 and std.mem.eql(u8, args[3], "--close");
    const deadline = GetTickCount64() + 1000 * try std.fmt.parseInt(u64, args[2], 10);

    var search: Search = .{ .want = args[1] };
    while (true) {
        _ = EnumWindows(visit, @bitCast(@intFromPtr(&search)));
        if (search.found != null) break;
        if (GetTickCount64() >= deadline) {
            std.debug.print("no visible window has \"{s}\" in its title\n", .{args[1]});
            return 1;
        }
        Sleep(200);
    }
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    try stdout.interface.print("{s}\n", .{search.title[0..search.title_len]});
    try stdout.interface.flush();
    if (!close) return 0;

    var pid: DWORD = 0;
    _ = GetWindowThreadProcessId(search.found.?, &pid);
    const process = OpenProcess(SYNCHRONIZE, 0, pid) orelse return 2;
    defer _ = CloseHandle(process);
    _ = PostMessageW(search.found.?, WM_CLOSE, 0, 0);
    const now = GetTickCount64();
    // At least ten seconds to close, however long finding the window took.
    const left = @max(deadline -| now, 10_000);
    return if (WaitForSingleObject(process, @intCast(left)) == WAIT_OBJECT_0) 0 else 2;
}
