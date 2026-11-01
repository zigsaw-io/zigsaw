//! Says how a process and its descendants are confined, one line each: what
//! Chromium's sandbox made of its processes, as Windows sees them rather than
//! as the program reports them. Built by `zig build procprobe` for
//! tests/chromium.sh.
//!
//!   zigsaw-procprobe <pid>
//!
//! <pid> is the `zigsaw run` that started the app. Each line is
//!
//!   <pid> <exe> type=<--type> sub=<--utility-sub-type> svc=<--service-sandbox-type>
//!     il=<untrusted|low|medium|high|system|?> ac=<yes|no|?> restricted=<yes|no|?>
//!     no-sandbox=<yes|no|?> sandbox-flags=<other flags that loosen it>
//!
//! on one line, `-` for a switch the process doesn't have and `?` for what
//! couldn't be read: a sandboxed process's token may refuse being asked. Exits
//! 0 if it listed anything, 1 if the process isn't there.

const std = @import("std");

const BOOL = c_int;
const DWORD = u32;
const HANDLE = *anyopaque;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

extern "kernel32" fn CreateToolhelp32Snapshot(flags: DWORD, pid: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn Process32FirstW(snapshot: HANDLE, entry: *PROCESSENTRY32W) callconv(.winapi) BOOL;
extern "kernel32" fn Process32NextW(snapshot: HANDLE, entry: *PROCESSENTRY32W) callconv(.winapi) BOOL;
extern "kernel32" fn OpenProcess(access: DWORD, inherit: BOOL, pid: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
extern "advapi32" fn OpenProcessToken(process: HANDLE, access: DWORD, token: *HANDLE) callconv(.winapi) BOOL;
extern "advapi32" fn GetTokenInformation(token: HANDLE, class: c_int, info: ?*anyopaque, len: DWORD, ret: *DWORD) callconv(.winapi) BOOL;
extern "advapi32" fn IsTokenRestricted(token: HANDLE) callconv(.winapi) BOOL;
extern "advapi32" fn GetSidSubAuthorityCount(sid: *anyopaque) callconv(.winapi) *u8;
extern "advapi32" fn GetSidSubAuthority(sid: *anyopaque, index: DWORD) callconv(.winapi) *DWORD;
extern "ntdll" fn NtQueryInformationProcess(process: HANDLE, class: c_int, info: *anyopaque, len: u32, ret: *u32) callconv(.winapi) i32;

const TH32CS_SNAPPROCESS: DWORD = 0x2;
const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
const TOKEN_QUERY: DWORD = 0x8;
const TokenIntegrityLevel: c_int = 25;
const TokenIsAppContainer: c_int = 29;
const ProcessCommandLineInformation: c_int = 60;

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

const UNICODE_STRING = extern struct {
    Length: u16,
    MaximumLength: u16,
    Buffer: ?[*]u16,
};

const Process = struct { pid: DWORD, parent: DWORD, exe: [260]u16 };

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

fn integrity(token: HANDLE) []const u8 {
    var buf: [128]u8 align(@alignOf(usize)) = undefined;
    var ret: DWORD = 0;
    if (GetTokenInformation(token, TokenIntegrityLevel, &buf, buf.len, &ret) == 0) return "?";
    // TOKEN_MANDATORY_LABEL starts with SID_AND_ATTRIBUTES, whose first field
    // points to the SID.
    const sid: *anyopaque = @as(*const *anyopaque, @ptrCast(&buf)).*;
    const rid = GetSidSubAuthority(sid, GetSidSubAuthorityCount(sid).* - 1).*;
    return if (rid < 0x1000) "untrusted" else if (rid < 0x2000) "low" else if (rid < 0x3000) "medium" else if (rid < 0x4000) "high" else "system";
}

/// The value of `--<name>=<value>` in a command line, or null.
fn switchValue(line: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, line, " \"");
    while (it.next()) |arg| {
        if (arg.len > name.len + 3 and std.mem.startsWith(u8, arg, "--") and
            std.mem.eql(u8, arg[2 .. 2 + name.len], name) and arg[2 + name.len] == '=')
            return arg[3 + name.len ..];
    }
    return null;
}

fn hasSwitch(line: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, line, " \"");
    while (it.next()) |arg| {
        if (arg.len == name.len + 2 and std.mem.startsWith(u8, arg, "--") and std.mem.eql(u8, arg[2..], name)) return true;
    }
    return false;
}

test switchValue {
    const line = "\"C:\\a b\\chrome.exe\" --type=utility --utility-sub-type=network.mojom.NetworkService --no-sandbox";
    try std.testing.expectEqualStrings("utility", switchValue(line, "type").?);
    try std.testing.expectEqualStrings("network.mojom.NetworkService", switchValue(line, "utility-sub-type").?);
    try std.testing.expect(switchValue(line, "service-sandbox-type") == null);
    try std.testing.expect(hasSwitch(line, "no-sandbox"));
    try std.testing.expect(!hasSwitch(line, "sandbox"));
}

/// Switches that take part of Chromium's sandbox away, short of --no-sandbox.
const loosening = [_][]const u8{
    "disable-gpu-sandbox",
    "in-process-gpu",
    "single-process",
    "allow-no-sandbox-job",
    "disable-gpu",
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: zigsaw-procprobe <pid>\n", .{});
        return 2;
    }
    const root = try std.fmt.parseInt(DWORD, args[1], 10);

    const all = try arena.alloc(Process, 8192);
    var count: usize = 0;
    const snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return 1;
    defer _ = CloseHandle(snapshot);
    var entry: PROCESSENTRY32W = .{};
    var more = Process32FirstW(snapshot, &entry) != 0;
    while (more and count < all.len) : (more = Process32NextW(snapshot, &entry) != 0) {
        all[count] = .{ .pid = entry.th32ProcessID, .parent = entry.th32ParentProcessID, .exe = entry.szExeFile };
        count += 1;
    }

    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &writer.interface;
    var listed: usize = 0;
    for (all[0..count]) |proc| {
        if (proc.pid == root or !descends(all[0..count], proc.pid, root)) continue;
        listed += 1;
        const exe_len = std.mem.indexOfScalar(u16, &proc.exe, 0) orelse proc.exe.len;
        var exe: [260 * 3]u8 = undefined;
        const exe_n = std.unicode.wtf16LeToWtf8(&exe, proc.exe[0..exe_len]);
        try out.print("{d} {s}", .{ proc.pid, exe[0..exe_n] });

        const process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, proc.pid);
        defer if (process) |p| {
            _ = CloseHandle(p);
        };

        var line: []const u8 = "";
        var known_line = false;
        if (process) |p| {
            const info: []align(@alignOf(usize)) u8 = try arena.alignedAlloc(u8, .of(usize), 65536);
            var ret: u32 = 0;
            if (NtQueryInformationProcess(p, ProcessCommandLineInformation, info.ptr, @intCast(info.len), &ret) >= 0) {
                const string: *const UNICODE_STRING = @ptrCast(info.ptr);
                if (string.Buffer) |text| {
                    const wide = text[0 .. string.Length / 2];
                    const utf8 = try arena.alloc(u8, wide.len * 3);
                    line = utf8[0..std.unicode.wtf16LeToWtf8(utf8, wide)];
                    known_line = true;
                }
            }
        }
        try out.print(" type={s} sub={s} svc={s}", .{
            switchValue(line, "type") orelse "-",
            switchValue(line, "utility-sub-type") orelse "-",
            switchValue(line, "service-sandbox-type") orelse "-",
        });

        var token: HANDLE = undefined;
        if (process != null and OpenProcessToken(process.?, TOKEN_QUERY, &token) != 0) {
            defer _ = CloseHandle(token);
            var is_ac: DWORD = 0;
            var ret: DWORD = 0;
            const ac_known = GetTokenInformation(token, TokenIsAppContainer, &is_ac, @sizeOf(DWORD), &ret) != 0;
            try out.print(" il={s} ac={s} restricted={s}", .{
                integrity(token),
                if (!ac_known) "?" else if (is_ac != 0) "yes" else "no",
                if (IsTokenRestricted(token) != 0) "yes" else "no",
            });
        } else {
            try out.print(" il=? ac=? restricted=?", .{});
        }

        try out.print(" no-sandbox={s} sandbox-flags=", .{if (!known_line) "?" else if (hasSwitch(line, "no-sandbox")) "yes" else "no"});
        var any = false;
        for (loosening) |flag| {
            const present = hasSwitch(line, flag) or switchValue(line, flag) != null;
            if (!present) continue;
            try out.print("{s}{s}", .{ if (any) "," else "", flag });
            any = true;
        }
        if (!any) try out.writeAll("-");
        try out.writeAll("\n");
    }
    try out.flush();
    return if (listed > 0) 0 else 1;
}
