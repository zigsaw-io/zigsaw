//! Asks Windows for what it has been seen to deny AppContainers, and prints
//! one line per check: `<check> ok`, or `<check> error <code> (<name>)`,
//! after a `#` line saying what the process is. Built by `zig build acprobe`;
//! tests/matrix.sh runs it under --sandbox=appcontainer and expects the known
//! gaps whose causes it finds lifted to pass (see docs/findings.md).
//!
//!   zigsaw-acprobe                  the checks, from the working directory
//!   zigsaw-acprobe --low <command>  runs <command> at low integrity, and
//!                                   exits with its exit code
//!
//! The checks:
//!
//!   final-path-dos  the working directory's real path, with its drive letter
//!                   (GetFinalPathNameByHandleW with VOLUME_NAME_DOS): how
//!                   git, Node and Python resolve real paths
//!   self-path-dos   the same for the probe's own executable, as zig finds
//!                   its own
//!   final-path-nt   the working directory's NT path (VOLUME_NAME_NT), which
//!                   needs no drive letter
//!   mount-manager   opening the Mount Manager, which maps volumes to drive
//!                   letters
//!   drive-root      the working directory's drive root, opened to read its
//!                   attributes, as Node's lstat("C:\\") does
//!   nul             NUL, opened to read and write, as git and Go open it

const std = @import("std");
const win32 = @import("win32");

const DWORD = win32.DWORD;
const HANDLE = win32.HANDLE;

const FILE_READ_ATTRIBUTES: DWORD = 0x80;
const GENERIC_WRITE: DWORD = 0x40000000;
const FILE_SHARE_ALL: DWORD = 0x7;
const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;
const VOLUME_NAME_DOS: DWORD = 0x0;
const VOLUME_NAME_NT: DWORD = 0x2;

extern "kernel32" fn GetFinalPathNameByHandleW(file: HANDLE, path: [*]u16, len: DWORD, flags: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetCurrentDirectoryW(len: DWORD, buf: [*]u16) callconv(.winapi) DWORD;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and std.mem.eql(u8, args[1], "--low")) return runLow();

    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;

    try printSelf(out);

    var cwd_buf: [32 * 1024]u16 = undefined;
    const cwd_len = GetCurrentDirectoryW(cwd_buf.len, &cwd_buf);
    if (cwd_len == 0 or cwd_len >= cwd_buf.len) return error.NoWorkingDirectory;
    cwd_buf[cwd_len] = 0;
    const cwd: [:0]const u16 = cwd_buf[0..cwd_len :0];

    var exe_buf: [32 * 1024]u16 = undefined;
    const exe_len = win32.GetModuleFileNameW(null, &exe_buf, exe_buf.len - 1);
    if (exe_len == 0) return error.NoExePath;
    exe_buf[exe_len] = 0;
    const exe: [:0]const u16 = exe_buf[0..exe_len :0];

    try report(out, "final-path-dos", finalPath(cwd, VOLUME_NAME_DOS));
    try report(out, "self-path-dos", finalPath(exe, VOLUME_NAME_DOS));
    try report(out, "final-path-nt", finalPath(cwd, VOLUME_NAME_NT));
    try report(out, "mount-manager", open(std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\MountPointManager"), 0, 0));
    if (cwd.len >= 2 and cwd[1] == ':') {
        const root = [_:0]u16{ cwd[0], ':', '\\' };
        try report(out, "drive-root", open(&root, FILE_READ_ATTRIBUTES, FILE_FLAG_BACKUP_SEMANTICS));
    } else {
        try out.print("drive-root skipped: the working directory has no drive letter\n", .{});
    }
    try report(out, "nul", open(std.unicode.utf8ToUtf16LeStringLiteral("NUL"), win32.GENERIC_READ | GENERIC_WRITE, 0));
    try out.flush();
}

/// A check's result: null when it succeeded, else the Win32 error.
const Result = ?DWORD;

fn report(out: *std.Io.Writer, name: []const u8, result: Result) !void {
    if (result) |code| {
        try out.print("{s} error {d} ({s})\n", .{ name, code, win32.errorName(code) });
    } else {
        try out.print("{s} ok\n", .{name});
    }
}

fn open(path: [*:0]const u16, access: DWORD, flags: DWORD) Result {
    const h = win32.CreateFileW(path, access, FILE_SHARE_ALL, null, win32.OPEN_EXISTING, flags, null);
    if (h == win32.INVALID_HANDLE_VALUE) return win32.GetLastError();
    _ = win32.CloseHandle(h);
    return null;
}

fn finalPath(path: [*:0]const u16, volume: DWORD) Result {
    const h = win32.CreateFileW(path, FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, null, win32.OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, null);
    if (h == win32.INVALID_HANDLE_VALUE) return win32.GetLastError();
    defer _ = win32.CloseHandle(h);
    var buf: [32 * 1024]u16 = undefined;
    const len = GetFinalPathNameByHandleW(h, &buf, buf.len, volume);
    if (len == 0 or len >= buf.len) return win32.GetLastError();
    return null;
}

/// Prints the process's integrity level, and whether it's in an AppContainer.
fn printSelf(out: *std.Io.Writer) !void {
    var token: ?HANDLE = null;
    if (win32.OpenProcessToken(win32.GetCurrentProcess(), win32.TOKEN_QUERY, &token) == 0) return out.print("# token unreadable\n", .{});
    defer _ = win32.CloseHandle(token.?);
    var is_ac: DWORD = 0;
    var len: DWORD = 0;
    _ = win32.GetTokenInformation(token.?, win32.TokenIsAppContainer, &is_ac, @sizeOf(DWORD), &len);
    var label: [256]u8 align(@alignOf(win32.TOKEN_MANDATORY_LABEL)) = undefined;
    if (win32.GetTokenInformation(token.?, win32.TokenIntegrityLevel, &label, label.len, &len) == 0) return out.print("# integrity unreadable\n", .{});
    const sid = @as(*const win32.TOKEN_MANDATORY_LABEL, @ptrCast(&label)).Label.Sid;
    const rid = win32.GetSidSubAuthority(sid, win32.GetSidSubAuthorityCount(sid).* - 1).*;
    const level = if (rid < 0x1000) "untrusted" else if (rid < 0x2000) "low" else if (rid < 0x3000) "medium" else if (rid < 0x4000) "high" else "system";
    try out.print("# integrity {s}{s}\n", .{ level, if (is_ac != 0) ", in an AppContainer" else "" });
}

/// Runs the rest of the command line at low integrity, with a copy of this
/// process's token labelled low, which needs no privileges.
fn runLow() !void {
    const cmdline = std.mem.span(win32.GetCommandLineW());
    const rest = afterLowFlag(cmdline) orelse return error.NoCommand;
    var command: [32 * 1024:0]u16 = undefined;
    if (rest.len >= command.len) return error.CommandTooLong;
    @memcpy(command[0..rest.len], rest);
    command[rest.len] = 0;

    var token: ?HANDLE = null;
    if (win32.OpenProcessToken(win32.GetCurrentProcess(), win32.TOKEN_ASSIGN_PRIMARY | win32.TOKEN_DUPLICATE | win32.TOKEN_QUERY | win32.TOKEN_ADJUST_DEFAULT, &token) == 0)
        return lastError("OpenProcessToken");
    var low: ?HANDLE = null;
    if (win32.DuplicateTokenEx(token.?, 0, null, win32.SecurityImpersonation, win32.TokenPrimary, &low) == 0) return lastError("DuplicateTokenEx");
    var sid: ?win32.PSID = null;
    if (win32.ConvertStringSidToSidW(std.unicode.utf8ToUtf16LeStringLiteral("S-1-16-4096"), &sid) == 0) return lastError("ConvertStringSidToSidW");
    const label: win32.TOKEN_MANDATORY_LABEL = .{ .Label = .{ .Sid = sid.?, .Attributes = win32.SE_GROUP_INTEGRITY } };
    if (win32.SetTokenInformation(low.?, win32.TokenIntegrityLevel, &label, @sizeOf(win32.TOKEN_MANDATORY_LABEL) + win32.GetLengthSid(sid.?)) == 0)
        return lastError("SetTokenInformation");

    var si: win32.STARTUPINFOW = .{ .cb = @sizeOf(win32.STARTUPINFOW), .dwFlags = win32.STARTF_USESTDHANDLES };
    si.hStdInput = win32.GetStdHandle(win32.STD_INPUT_HANDLE);
    si.hStdOutput = win32.GetStdHandle(win32.STD_OUTPUT_HANDLE);
    si.hStdError = win32.GetStdHandle(win32.STD_ERROR_HANDLE);
    for ([_]?HANDLE{ si.hStdInput, si.hStdOutput, si.hStdError }) |h| {
        if (h) |handle| _ = win32.SetHandleInformation(handle, win32.HANDLE_FLAG_INHERIT, win32.HANDLE_FLAG_INHERIT);
    }
    var pi: win32.PROCESS_INFORMATION = undefined;
    if (win32.CreateProcessAsUserW(low.?, null, &command, null, null, win32.TRUE, 0, null, null, &si, &pi) == 0)
        return lastError("CreateProcessAsUserW");
    _ = win32.WaitForSingleObject(pi.hProcess, win32.INFINITE);
    var code: DWORD = 1;
    _ = win32.GetExitCodeProcess(pi.hProcess, &code);
    win32.ExitProcess(code);
}

/// What follows `--low` and the spaces after it in a command line whose
/// program name may be quoted.
fn afterLowFlag(cmdline: []const u16) ?[]const u16 {
    var i: usize = 0;
    if (cmdline.len > 0 and cmdline[0] == '"') {
        i = 1;
        while (i < cmdline.len and cmdline[i] != '"') i += 1;
        i += 1;
    } else {
        while (i < cmdline.len and cmdline[i] != ' ' and cmdline[i] != '\t') i += 1;
    }
    while (i < cmdline.len and (cmdline[i] == ' ' or cmdline[i] == '\t')) i += 1;
    const flag = std.unicode.utf8ToUtf16LeStringLiteral("--low");
    if (!std.mem.startsWith(u16, cmdline[i..], flag)) return null;
    i += flag.len;
    while (i < cmdline.len and (cmdline[i] == ' ' or cmdline[i] == '\t')) i += 1;
    if (i == cmdline.len) return null;
    return cmdline[i..];
}

fn lastError(what: []const u8) error{Failed} {
    const code = win32.GetLastError();
    std.debug.print("{s} failed: error {d} ({s})\n", .{ what, code, win32.errorName(code) });
    return error.Failed;
}
