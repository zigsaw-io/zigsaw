//! Runs a command as another Windows account, for tests/standard-user.sh:
//!
//!   zigsaw-asuser <account file> <stdout+stderr file> <command line>
//!
//! The account file has the user name on its first line and the password on its
//! second, so the password is in no command line or log. The command runs in that
//! user's own logon, with their profile loaded, in the session and on the desktop
//! this program has, and everything it prints goes to the file. Exits with the
//! command's exit code; 125 if it couldn't be started.

const std = @import("std");
const Io = std.Io;
const windows = std.os.windows;
const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const HANDLE = windows.HANDLE;
const LPCWSTR = windows.LPCWSTR;
const LPWSTR = windows.LPWSTR;

const STARTUPINFOW = extern struct {
    cb: DWORD = @sizeOf(STARTUPINFOW),
    lpReserved: ?LPWSTR = null,
    lpDesktop: ?LPWSTR = null,
    lpTitle: ?LPWSTR = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};
const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};
const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD = @sizeOf(SECURITY_ATTRIBUTES),
    lpSecurityDescriptor: ?*anyopaque = null,
    bInheritHandle: BOOL = .TRUE,
};

extern "advapi32" fn CreateProcessWithLogonW(
    username: LPCWSTR,
    domain: ?LPCWSTR,
    password: LPCWSTR,
    logon_flags: DWORD,
    application: ?LPCWSTR,
    command_line: ?LPWSTR,
    creation_flags: DWORD,
    environment: ?*anyopaque,
    current_directory: ?LPCWSTR,
    startup: *STARTUPINFOW,
    info: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;
extern "kernel32" fn CreateFileW(name: LPCWSTR, access: DWORD, share: DWORD, sa: ?*SECURITY_ATTRIBUTES, disposition: DWORD, flags: DWORD, template: ?HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(handle: HANDLE, code: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;

const LOGON_WITH_PROFILE = 1;
const CREATE_NO_WINDOW = 0x08000000;
const STARTF_USESTDHANDLES = 0x100;
const GENERIC_WRITE = 0x40000000;
const FILE_SHARE_READ = 1;
const FILE_SHARE_WRITE = 2;
const CREATE_ALWAYS = 2;
const FILE_ATTRIBUTE_NORMAL = 0x80;
const INFINITE = 0xFFFFFFFF;

fn wide(arena: std.mem.Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(arena, s);
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zigsaw-asuser: " ++ fmt ++ "\n", args);
    ExitProcess(125);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) die("usage: zigsaw-asuser <account file> <output file> <command line>", .{});

    const account = try Io.Dir.cwd().readFileAlloc(init.io, args[1], arena, .limited(4096));
    var lines = std.mem.splitScalar(u8, account, '\n');
    const user = std.mem.trim(u8, lines.next() orelse "", " \r\t");
    const password = std.mem.trim(u8, lines.next() orelse "", "\r");
    if (user.len == 0 or password.len == 0) die("{s} needs the user name on line 1, the password on line 2", .{args[1]});

    var sa: SECURITY_ATTRIBUTES = .{};
    const output = CreateFileW(try wide(arena, args[2]), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (output == windows.INVALID_HANDLE_VALUE) die("can't write {s}: error {d}", .{ args[2], GetLastError() });

    var startup: STARTUPINFOW = .{ .dwFlags = STARTF_USESTDHANDLES, .hStdOutput = output, .hStdError = output };
    var info: PROCESS_INFORMATION = undefined;
    if (CreateProcessWithLogonW(try wide(arena, user), try wide(arena, "."), try wide(arena, password), LOGON_WITH_PROFILE, null, try wide(arena, args[3]), CREATE_NO_WINDOW, null, null, &startup, &info) == .FALSE)
        die("couldn't start it as {s}: error {d}", .{ user, GetLastError() });
    _ = WaitForSingleObject(info.hProcess, INFINITE);
    var code: DWORD = 125;
    _ = GetExitCodeProcess(info.hProcess, &code);
    _ = CloseHandle(info.hThread);
    _ = CloseHandle(info.hProcess);
    _ = CloseHandle(output);
    ExitProcess(code);
}
