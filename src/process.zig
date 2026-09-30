//! Starting processes: command-line quoting, and running a child inside a
//! job object while forwarding stdio, Ctrl+C and the exit code.

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");

/// Quotes arguments the way the Microsoft C runtime (and CommandLineToArgvW)
/// parses them back.
pub fn buildCommandLine(arena: Allocator, exe: []const u8, args: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendQuoted(arena, &out, exe);
    for (args) |arg| {
        try out.append(arena, ' ');
        try appendQuoted(arena, &out, arg);
    }
    return out.items;
}

pub fn appendQuoted(arena: Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
    if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\n\x0b\"") == null) {
        return out.appendSlice(arena, arg);
    }
    try out.append(arena, '"');
    var backslashes: usize = 0;
    for (arg) |c| {
        switch (c) {
            '\\' => backslashes += 1,
            '"' => {
                // Backslashes before a quote are escapes, and so is the quote.
                try out.appendNTimes(arena, '\\', backslashes * 2 + 1);
                try out.append(arena, '"');
                backslashes = 0;
            },
            else => {
                try out.appendNTimes(arena, '\\', backslashes);
                try out.append(arena, c);
                backslashes = 0;
            },
        }
    }
    // Backslashes before the closing quote must be doubled.
    try out.appendNTimes(arena, '\\', backslashes * 2);
    try out.append(arena, '"');
}

pub const SpawnSpec = struct {
    exe: []const u8,
    /// WTF-8; see `buildCommandLine`.
    command_line: []const u8,
    /// UTF-16 "NAME=VALUE", each null-terminated, then a final null; null inherits ours.
    env_block: ?[]const u16 = null,
    /// Null inherits ours.
    cwd: ?[]const u8 = null,
    security: ?*const win32.SECURITY_CAPABILITIES = null,
};

/// Runs a process to completion and returns its exit code. The child gets
/// our stdio handles and nothing else, and runs in a job object, so its whole
/// process tree ends when it does, or when we do.
pub fn spawn(arena: Allocator, spec: SpawnSpec) !u32 {
    const job = win32.CreateJobObjectW(null, null) orelse return win32.lastErrorFail("CreateJobObjectW");
    defer _ = win32.CloseHandle(job);
    var limits: win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};
    limits.BasicLimitInformation.LimitFlags = win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (win32.SetInformationJobObject(job, win32.JobObjectExtendedLimitInformation, &limits, @sizeOf(@TypeOf(limits))) == 0)
        return win32.lastErrorFail("SetInformationJobObject");

    // Hand the app our stdio handles and nothing else.
    var std_handles: [3]?win32.HANDLE = .{ null, null, null };
    var inherit: [3]win32.HANDLE = undefined;
    var inherit_count: usize = 0;
    for ([_]win32.DWORD{ win32.STD_INPUT_HANDLE, win32.STD_OUTPUT_HANDLE, win32.STD_ERROR_HANDLE }, 0..) |which, i| {
        const h = win32.GetStdHandle(which) orelse continue;
        if (h == win32.INVALID_HANDLE_VALUE) continue;
        if (win32.SetHandleInformation(h, win32.HANDLE_FLAG_INHERIT, win32.HANDLE_FLAG_INHERIT) == 0) continue;
        std_handles[i] = h;
        if (std.mem.indexOfScalar(win32.HANDLE, inherit[0..inherit_count], h) == null) {
            inherit[inherit_count] = h;
            inherit_count += 1;
        }
    }

    const attr_count: win32.DWORD = 1 + @as(win32.DWORD, @intFromBool(inherit_count > 0)) + @intFromBool(spec.security != null);
    var attr_size: usize = 0;
    _ = win32.InitializeProcThreadAttributeList(null, attr_count, 0, &attr_size);
    const attrs = try arena.alignedAlloc(u8, .of(usize), attr_size);
    if (win32.InitializeProcThreadAttributeList(attrs.ptr, attr_count, 0, &attr_size) == 0)
        return win32.lastErrorFail("InitializeProcThreadAttributeList");
    defer win32.DeleteProcThreadAttributeList(attrs.ptr);

    // Assigning the job at creation means no child process can start outside it.
    const jobs = [1]win32.HANDLE{job};
    if (win32.UpdateProcThreadAttribute(attrs.ptr, 0, win32.PROC_THREAD_ATTRIBUTE_JOB_LIST, &jobs, @sizeOf(win32.HANDLE), null, null) == 0)
        return win32.lastErrorFail("UpdateProcThreadAttribute(JOB_LIST)");
    if (inherit_count > 0) {
        if (win32.UpdateProcThreadAttribute(attrs.ptr, 0, win32.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &inherit, inherit_count * @sizeOf(win32.HANDLE), null, null) == 0)
            return win32.lastErrorFail("UpdateProcThreadAttribute(HANDLE_LIST)");
    }
    if (spec.security) |security| {
        if (win32.UpdateProcThreadAttribute(attrs.ptr, 0, win32.PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, security, @sizeOf(win32.SECURITY_CAPABILITIES), null, null) == 0)
            return win32.lastErrorFail("UpdateProcThreadAttribute(SECURITY_CAPABILITIES)");
    }

    var startup: win32.STARTUPINFOEXW = .{
        .StartupInfo = .{ .cb = @sizeOf(win32.STARTUPINFOEXW) },
        .lpAttributeList = attrs.ptr,
    };
    if (inherit_count > 0) {
        startup.StartupInfo.dwFlags = win32.STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdInput = std_handles[0];
        startup.StartupInfo.hStdOutput = std_handles[1];
        startup.StartupInfo.hStdError = std_handles[2];
    }

    var info: win32.PROCESS_INFORMATION = undefined;
    if (win32.CreateProcessW(
        try win32.wide(arena, spec.exe),
        try win32.wide(arena, spec.command_line),
        null,
        null,
        @intFromBool(inherit_count > 0),
        win32.EXTENDED_STARTUPINFO_PRESENT | win32.CREATE_UNICODE_ENVIRONMENT,
        if (spec.env_block) |b| b.ptr else null,
        if (spec.cwd) |c| try win32.wide(arena, c) else null,
        &startup.StartupInfo,
        &info,
    ) == 0) return win32.lastErrorFail("CreateProcessW");
    _ = win32.CloseHandle(info.hThread);
    defer _ = win32.CloseHandle(info.hProcess);

    // The app shares our console, so it receives Ctrl+C too and decides what
    // to do; we keep waiting so we can report its exit code.
    _ = win32.SetConsoleCtrlHandler(&ignoreCtrlC, win32.TRUE);

    if (win32.WaitForSingleObject(info.hProcess, win32.INFINITE) != win32.WAIT_OBJECT_0)
        return win32.lastErrorFail("WaitForSingleObject");
    var code: win32.DWORD = 0;
    if (win32.GetExitCodeProcess(info.hProcess, &code) == 0)
        return win32.lastErrorFail("GetExitCodeProcess");
    return code;
}

fn ignoreCtrlC(event: win32.DWORD) callconv(.winapi) win32.BOOL {
    return if (event == win32.CTRL_C_EVENT or event == win32.CTRL_BREAK_EVENT) win32.TRUE else win32.FALSE;
}

test buildCommandLine {
    const cases = [_]struct { args: []const []const u8, want: []const u8 }{
        .{ .args = &.{"plain"}, .want = "C:\\app\\x.exe plain" },
        .{ .args = &.{"two words"}, .want = "C:\\app\\x.exe \"two words\"" },
        .{ .args = &.{""}, .want = "C:\\app\\x.exe \"\"" },
        .{ .args = &.{"say \"hi\""}, .want = "C:\\app\\x.exe \"say \\\"hi\\\"\"" },
        .{ .args = &.{"C:\\dir with space\\"}, .want = "C:\\app\\x.exe \"C:\\dir with space\\\\\"" },
        .{ .args = &.{"a\\\\b"}, .want = "C:\\app\\x.exe a\\\\b" },
    };
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    for (cases) |c| {
        try std.testing.expectEqualStrings(c.want, try buildCommandLine(arena_state.allocator(), "C:\\app\\x.exe", c.args));
    }
}
