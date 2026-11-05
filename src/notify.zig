//! zigsaw-notify.exe, which the daily scheduled task starts (see schedule.zig):
//! has zigsaw look for updates, with no window, and shows what it says. Clicking
//! the notification opens a console listing what's waiting. It installs nothing,
//! and neither does what it starts.
//!
//!   zigsaw-notify.exe --store <dir> --task <name>
//!
//! A task whose store has gone removes itself. ZIGSAW_NOTIFY_REPORT names a file
//! to write the notification to instead of showing it, for tests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const process = @import("process.zig");
const win32 = @import("win32.zig");
const W = std.unicode.utf8ToUtf16LeStringLiteral;

pub const panic = std.debug.simple_panic;
pub const std_options: std.Options = .{ .enable_segfault_handler = false, .logFn = log };

fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
    // Nobody's there to read it: a task has no console, and `zigsaw updates` says
    // what couldn't be checked.
    _ = level;
    _ = scope;
    _ = fmt;
    _ = args;
}

const HWND = ?*anyopaque;
const HICON = ?*anyopaque;
const GUID = extern struct { a: u32 = 0, b: u16 = 0, c: u16 = 0, d: [8]u8 = @splat(0) };

const NOTIFYICONDATAW = extern struct {
    cbSize: u32,
    hWnd: HWND,
    uID: u32,
    uFlags: u32,
    uCallbackMessage: u32,
    hIcon: HICON,
    szTip: [128]u16,
    dwState: u32,
    dwStateMask: u32,
    szInfo: [256]u16,
    uVersion: u32,
    szInfoTitle: [64]u16,
    dwInfoFlags: u32,
    guidItem: GUID,
    hBalloonIcon: HICON,
};

const WNDCLASSW = extern struct {
    style: u32 = 0,
    lpfnWndProc: *const fn (HWND, u32, usize, isize) callconv(.winapi) isize,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?*anyopaque,
    hIcon: HICON = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
};

const MSG = extern struct { hwnd: HWND, message: u32, wParam: usize, lParam: isize, time: u32, pt: [2]i32, lPrivate: u32 };

extern "shell32" fn Shell_NotifyIconW(message: u32, data: *NOTIFYICONDATAW) callconv(.winapi) win32.BOOL;
extern "shell32" fn CommandLineToArgvW(line: [*:0]const u16, count: *i32) callconv(.winapi) ?[*][*:0]u16;
extern "shell32" fn SHQueryUserNotificationState(state: *i32) callconv(.winapi) i32;
extern "user32" fn RegisterClassW(class: *const WNDCLASSW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(ex: u32, class: [*:0]const u16, name: [*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: HWND, menu: ?*anyopaque, instance: ?*anyopaque, param: ?*anyopaque) callconv(.winapi) HWND;
extern "user32" fn DefWindowProcW(hwnd: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize;
extern "user32" fn GetMessageW(msg: *MSG, hwnd: HWND, min: u32, max: u32) callconv(.winapi) win32.BOOL;
extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) isize;
extern "user32" fn PostQuitMessage(code: i32) callconv(.winapi) void;
extern "user32" fn SetTimer(hwnd: HWND, id: usize, ms: u32, callback: ?*anyopaque) callconv(.winapi) usize;
extern "user32" fn LoadIconW(instance: ?*anyopaque, name: usize) callconv(.winapi) HICON;
extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;

const wm_timer: u32 = 0x0113;
const wm_tray: u32 = 0x8000 + 1;
const nin_balloon_user_click: u32 = 0x0400 + 5;
/// QUNS_ACCEPTS_NOTIFICATIONS: not full screen, presenting, or in quiet hours.
const quns_accepts: i32 = 5;
/// How long the check may take, a long way inside the task's own limit.
const check_ms: u32 = 5 * 60 * 1000;
/// How long a click may still come. A banner lasts seconds, but this is what's in
/// the tray for as long as it could be noticed there.
const listen_ms: u32 = 2 * 60 * 1000;

var clicked = false;

fn wndProc(hwnd: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize {
    switch (msg) {
        wm_tray => {
            // With NOTIFYICON_VERSION_4, the event's in the low word.
            if ((@as(usize, @bitCast(lp)) & 0xffff) == nin_balloon_user_click) {
                clicked = true;
                PostQuitMessage(0);
            }
            return 0;
        },
        wm_timer => {
            PostQuitMessage(0);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wp, lp),
    }
}

pub fn main() void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    run(arena_state.allocator()) catch win32.ExitProcess(1);
    win32.ExitProcess(0);
}

fn run(arena: Allocator) !void {
    var argc: i32 = 0;
    const argv = CommandLineToArgvW(win32.GetCommandLineW(), &argc) orelse return error.NoArguments;
    var store: ?[*:0]const u16 = null;
    var task: ?[*:0]const u16 = null;
    var i: usize = 1;
    while (i + 1 < argc) : (i += 2) {
        const name = std.mem.span(argv[i]);
        if (std.mem.eql(u16, name, W("--store"))) store = argv[i + 1];
        if (std.mem.eql(u16, name, W("--task"))) task = argv[i + 1];
    }
    const root = store orelse return error.NoStore;

    if (win32.GetFileAttributesW(root) == win32.INVALID_FILE_ATTRIBUTES) {
        if (task) |t| try removeTask(arena, t);
        return;
    }
    if (win32.SetEnvironmentVariableW(W("ZIGSAW_HOME"), root) == 0) return error.Environment;

    const self = try win32.selfExePath(arena);
    const zigsaw = try std.fs.path.join(arena, &.{ std.fs.path.dirname(self).?, "zigsaw.exe" });
    const report = envVar(arena, "ZIGSAW_NOTIFY_REPORT");

    // Not told while Windows would hold it back: then it isn't counted as told,
    // and the next check tries again.
    var state: i32 = 0;
    const accepting = report != null or (SHQueryUserNotificationState(&state) == 0 and state == quns_accepts);

    const nul = win32.CreateFileW(W("NUL"), win32.GENERIC_READ | win32.GENERIC_WRITE, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE, null, win32.OPEN_EXISTING, 0, null);
    const args: []const []const u8 = if (accepting) &.{ "updates", "check", "--notify" } else &.{ "updates", "check", "--quiet" };
    const said = try process.output(arena, .{
        .exe = zigsaw,
        .command_line = try process.buildCommandLine(arena, zigsaw, args),
        .creation_flags = win32.CREATE_NO_WINDOW,
        .stdio = .{ null, null, nul },
    }, "", check_ms) orelse return;

    var lines = std.mem.tokenizeAny(u8, said.stdout, "\r\n");
    const title = lines.next() orelse return;
    const text = lines.next() orelse return;
    if (report) |path| return writeReport(arena, path, title, text);
    if (try show(arena, title, text)) try openList(arena, zigsaw);
}

fn envVar(arena: Allocator, comptime name: []const u8) ?[]const u8 {
    const buf = arena.alloc(u16, 32 * 1024) catch return null;
    const len = win32.GetEnvironmentVariableW(W(name), buf.ptr, @intCast(buf.len));
    if (len == 0 or len >= buf.len) return null;
    return std.unicode.wtf16LeToWtf8Alloc(arena, buf[0..len]) catch null;
}

fn writeReport(arena: Allocator, path: []const u8, title: []const u8, text: []const u8) !void {
    const data = try std.fmt.allocPrint(arena, "{s}\n{s}\n", .{ title, text });
    const file = win32.CreateFileW(try win32.wide(arena, path), win32.GENERIC_WRITE, 0, null, win32.CREATE_ALWAYS, 0, null);
    if (file == win32.INVALID_HANDLE_VALUE) return error.Report;
    defer _ = win32.CloseHandle(file);
    _ = win32.WriteFile(file, data.ptr, @intCast(data.len), null, null);
}

fn copyInto(dest: []u16, arena: Allocator, text: []const u8) !void {
    const wide = try std.unicode.wtf8ToWtf16LeAlloc(arena, text);
    const n = @min(wide.len, dest.len - 1);
    @memcpy(dest[0..n], wide[0..n]);
    dest[n] = 0;
}

/// Shows the notification, and returns whether it was clicked.
fn show(arena: Allocator, title: []const u8, text: []const u8) !bool {
    const instance = GetModuleHandleW(null);
    const class = W("ZigsawNotify");
    if (RegisterClassW(&.{ .lpfnWndProc = wndProc, .hInstance = instance, .lpszClassName = class }) == 0) return error.Window;
    const hwnd = CreateWindowExW(0, class, W("zigsaw"), 0, 0, 0, 0, 0, null, null, instance, null);
    if (hwnd == null) return error.Window;

    var data = std.mem.zeroes(NOTIFYICONDATAW);
    data.cbSize = @sizeOf(NOTIFYICONDATAW);
    data.hWnd = hwnd;
    data.uID = 1;
    const nif_message = 0x1;
    const nif_icon = 0x2;
    const nif_tip = 0x4;
    const nif_info = 0x10;
    data.uFlags = nif_message | nif_icon | nif_tip | nif_info;
    data.uCallbackMessage = wm_tray;
    const idi_information = 32516;
    data.hIcon = LoadIconW(null, idi_information);
    try copyInto(&data.szTip, arena, title);
    try copyInto(&data.szInfoTitle, arena, title);
    try copyInto(&data.szInfo, arena, text);
    data.dwInfoFlags = 1; // NIIF_INFO
    const nim_add = 0;
    const nim_delete = 2;
    const nim_setversion = 4;
    if (Shell_NotifyIconW(nim_add, &data) == 0) return error.Notification;
    defer _ = Shell_NotifyIconW(nim_delete, &data);
    data.uVersion = 4; // NOTIFYICON_VERSION_4
    _ = Shell_NotifyIconW(nim_setversion, &data);

    _ = SetTimer(hwnd, 1, listen_ms, null);
    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) _ = DispatchMessageW(&msg);
    return clicked;
}

/// A console of its own, which stays open, showing `zigsaw updates`. Not in a job,
/// as this program is about to end.
fn openList(arena: Allocator, zigsaw: []const u8) !void {
    const cmd = try win32.systemProgram(arena, "cmd.exe");
    // cmd takes the outer quotes off what /k gets, leaving the path quoted.
    const line = try std.fmt.allocPrint(arena, "\"{s}\" /k \"\"{s}\" updates\"", .{ cmd, zigsaw });
    var startup: win32.STARTUPINFOW = .{ .cb = @sizeOf(win32.STARTUPINFOW) };
    var info: win32.PROCESS_INFORMATION = undefined;
    if (win32.CreateProcessW(try win32.wide(arena, cmd), try win32.wide(arena, line), null, null, win32.FALSE, win32.CREATE_NEW_CONSOLE, null, null, &startup, &info) == 0)
        return error.Console;
    _ = win32.CloseHandle(info.hProcess);
    _ = win32.CloseHandle(info.hThread);
}

fn removeTask(arena: Allocator, task: [*:0]const u16) !void {
    const exe = try win32.systemProgram(arena, "schtasks.exe");
    const name = try std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.span(task));
    const nul = win32.CreateFileW(W("NUL"), win32.GENERIC_READ | win32.GENERIC_WRITE, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE, null, win32.OPEN_EXISTING, 0, null);
    _ = try process.output(arena, .{
        .exe = exe,
        .command_line = try process.buildCommandLine(arena, exe, &.{ "/delete", "/tn", name, "/f" }),
        .creation_flags = win32.CREATE_NO_WINDOW,
        .stdio = .{ null, null, nul },
    }, "", 60 * 1000);
}
