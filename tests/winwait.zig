//! Waits for a visible top-level window of a process or its descendants
//! whose title has a given text, prints its title, and closes it if asked,
//! as its close button would, waiting for its program to end: GUI apps save
//! their settings as they close. Built by `zig build winwait` for
//! tests/guiapps.sh.
//!
//!   zigsaw-winwait <pid> <text> <seconds> [--close]
//!
//! <pid> is the `zigsaw run` that started the app: windows of other programs
//! never count, whatever their titles (a browser showing the app's web page
//! has its name in its title). A text `class:<name>` matches the window's
//! class name instead, exactly: for windows whose title is whatever they
//! show.
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
extern "kernel32" fn CreateToolhelp32Snapshot(flags: DWORD, pid: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn Process32FirstW(snapshot: HANDLE, entry: *PROCESSENTRY32W) callconv(.winapi) BOOL;
extern "kernel32" fn Process32NextW(snapshot: HANDLE, entry: *PROCESSENTRY32W) callconv(.winapi) BOOL;

const WM_CLOSE: u32 = 0x0010;
const SYNCHRONIZE: DWORD = 0x00100000;
const WAIT_OBJECT_0: DWORD = 0;
const TH32CS_SNAPPROCESS: DWORD = 0x2;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

const PROCESSENTRY32W = extern struct {
    dwSize: DWORD = @sizeOf(PROCESSENTRY32W),
    cntUsage: DWORD = 0,
    th32ProcessID: DWORD = 0,
    th32DefaultHeapID: usize = 0,
    th32ModuleID: DWORD = 0,
    cntThreads: DWORD = 0,
    th32ParentProcessID: DWORD = 0,
    pcPriClassBase: c_long = 0,
    dwFlags: DWORD = 0,
    szExeFile: [260]u16 = undefined,
};

/// A process and its parent, from a snapshot.
const Process = struct { pid: DWORD, parent: DWORD };

/// The processes running now, up to as many as `buf` holds.
fn processes(buf: []Process) []Process {
    const snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return buf[0..0];
    defer _ = CloseHandle(snapshot);
    var entry: PROCESSENTRY32W = .{};
    var n: usize = 0;
    var more = Process32FirstW(snapshot, &entry) != 0;
    while (more and n < buf.len) : (more = Process32NextW(snapshot, &entry) != 0) {
        buf[n] = .{ .pid = entry.th32ProcessID, .parent = entry.th32ParentProcessID };
        n += 1;
    }
    return buf[0..n];
}

/// Whether `pid` is `root` or one of its descendants. Parents are followed a
/// bounded number of times: a parent's id may have been reused by a process
/// started later, which can make a cycle.
fn descends(all: []const Process, pid: DWORD, root: DWORD) bool {
    var p = pid;
    for (0..64) |_| {
        if (p == root) return true;
        const parent = for (all) |proc| {
            if (proc.pid == p) break proc.parent;
        } else return false;
        if (parent == 0 or parent == p) return false;
        p = parent;
    }
    return false;
}

test descends {
    const all = [_]Process{
        .{ .pid = 10, .parent = 4 }, // zigsaw run
        .{ .pid = 11, .parent = 10 }, // the app
        .{ .pid = 12, .parent = 11 }, // its child
        .{ .pid = 20, .parent = 4 }, // a browser
        .{ .pid = 30, .parent = 31 }, // a cycle through reused ids
        .{ .pid = 31, .parent = 30 },
    };
    try std.testing.expect(descends(&all, 10, 10));
    try std.testing.expect(descends(&all, 12, 10));
    try std.testing.expect(!descends(&all, 20, 10));
    try std.testing.expect(!descends(&all, 30, 10));
    try std.testing.expect(!descends(&all, 99, 10));
}

const Search = struct {
    root: DWORD,
    processes: []const Process,
    want: []const u8,
    found: ?HWND = null,
    title: [512]u8 = undefined,
    title_len: usize = 0,
};

fn visit(window: HWND, param: LPARAM) callconv(.winapi) BOOL {
    const search: *Search = @ptrFromInt(@as(usize, @bitCast(param)));
    if (IsWindowVisible(window) == 0) return 1;
    var owner: DWORD = 0;
    _ = GetWindowThreadProcessId(window, &owner);
    if (!descends(search.processes, owner, search.root)) return 1;
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
    if (!std.mem.startsWith(u8, search.want, "class:") and std.ascii.findIgnoreCase(buf[0..n], search.want) == null) return 1;
    search.found = window;
    search.title_len = @min(n, search.title.len);
    @memcpy(search.title[0..search.title_len], buf[0..search.title_len]);
    return 0;
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) {
        std.debug.print("usage: zigsaw-winwait <pid> <text> <seconds> [--close]\n", .{});
        return 1;
    }
    const root = try std.fmt.parseInt(DWORD, args[1], 10);
    const close = args.len > 4 and std.mem.eql(u8, args[4], "--close");
    const deadline = GetTickCount64() + 1000 * try std.fmt.parseInt(u64, args[3], 10);

    const all = try init.arena.allocator().alloc(Process, 8192);
    var search: Search = .{ .root = root, .processes = &.{}, .want = args[2] };
    while (true) {
        search.processes = processes(all);
        _ = EnumWindows(visit, @bitCast(@intFromPtr(&search)));
        if (search.found != null) break;
        if (GetTickCount64() >= deadline) {
            std.debug.print("no visible window of process {d} or its descendants has \"{s}\" in its title\n", .{ root, args[2] });
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
