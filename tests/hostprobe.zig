//! Asks Windows what an ordinary desktop program asks it: where the user's
//! folders are, whether they can be written, and what the registry allows.
//! zigsaw points a run's USERPROFILE, APPDATA and LOCALAPPDATA into the
//! app's data directory, which only steers programs that read those
//! variables; this shows where the others end up, in each sandbox (see
//! docs/findings.md). Built by `zig build hostprobe`; tests/hostprobe/app.json
//! makes an app of it.
//!
//! Prints a `#` line saying what the process is, then one line per check:
//!
//!   env <NAME> = <value>|(unset)
//!   folder <name> = <path> (write ok|write error <code> (<name>))
//!   folder <name> error 0x<hresult>
//!   registry <what> ok|error <code> (<name>)
//!   com <what> ok|error 0x<hresult>
//!
//! A folder is written by creating a file in it that Windows deletes as it's
//! closed, named after the probe's process, so nothing is left behind; a
//! registry key is created and deleted the same way.

const std = @import("std");
const win32 = @import("win32");

const DWORD = win32.DWORD;
const HANDLE = win32.HANDLE;
const GUID = win32.GUID;
const HRESULT = win32.HRESULT;

const GENERIC_WRITE: DWORD = 0x40000000;
const DELETE: DWORD = 0x00010000;
const CREATE_NEW: DWORD = 1;
const FILE_FLAG_DELETE_ON_CLOSE: DWORD = 0x04000000;
/// SHGetKnownFolderPath: the path even if the folder doesn't exist.
const KF_FLAG_DONT_VERIFY: DWORD = 0x4000;
const HKEY_LOCAL_MACHINE: win32.HKEY = @ptrFromInt(0x80000002);
const KEY_QUERY_VALUE: DWORD = 0x1;

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, len: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetTempPathW(len: DWORD, buf: [*]u16) callconv(.winapi) DWORD;
extern "kernel32" fn GetTempPath2W(len: DWORD, buf: [*]u16) callconv(.winapi) DWORD;
extern "userenv" fn GetUserProfileDirectoryW(token: HANDLE, buf: [*]u16, len: *DWORD) callconv(.winapi) win32.BOOL;
extern "user32" fn OpenClipboard(owner: ?*anyopaque) callconv(.winapi) win32.BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) win32.BOOL;

const folders = [_]struct { []const u8, GUID }{
    .{ "RoamingAppData", .{ .Data1 = 0x3EB685DB, .Data2 = 0x65F9, .Data3 = 0x4CF6, .Data4 = .{ 0xA0, 0x3A, 0xE3, 0xEF, 0x65, 0x72, 0x9F, 0x3D } } },
    .{ "LocalAppData", .{ .Data1 = 0xF1B32785, .Data2 = 0x6FBA, .Data3 = 0x4FCF, .Data4 = .{ 0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91 } } },
    .{ "LocalAppDataLow", .{ .Data1 = 0xA520A1A4, .Data2 = 0x1780, .Data3 = 0x4FF6, .Data4 = .{ 0xBD, 0x18, 0x16, 0x73, 0x43, 0xC5, 0xAF, 0x16 } } },
    .{ "Profile", .{ .Data1 = 0x5E6C858F, .Data2 = 0x0E22, .Data3 = 0x4760, .Data4 = .{ 0x9A, 0xFE, 0xEA, 0x33, 0x17, 0xB6, 0x71, 0x73 } } },
    .{ "Desktop", .{ .Data1 = 0xB4BFCC3A, .Data2 = 0xDB2C, .Data3 = 0x424C, .Data4 = .{ 0xB0, 0x29, 0x7F, 0xE9, 0x9A, 0x87, 0xC6, 0x41 } } },
    .{ "Documents", .{ .Data1 = 0xFDD39AD0, .Data2 = 0x238F, .Data3 = 0x46AF, .Data4 = .{ 0xAD, 0xB4, 0x6C, 0x85, 0x48, 0x03, 0x69, 0xC7 } } },
    .{ "Downloads", .{ .Data1 = 0x374DE290, .Data2 = 0x123F, .Data3 = 0x4565, .Data4 = .{ 0x91, 0x64, 0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B } } },
    .{ "Music", .{ .Data1 = 0x4BD8D571, .Data2 = 0x6D19, .Data3 = 0x48D3, .Data4 = .{ 0xBE, 0x97, 0x42, 0x22, 0x20, 0x08, 0x0E, 0x43 } } },
    .{ "Pictures", .{ .Data1 = 0x33E28130, .Data2 = 0x4E1E, .Data3 = 0x4676, .Data4 = .{ 0x83, 0x5A, 0x98, 0x39, 0x5C, 0x3B, 0xC3, 0xBB } } },
    .{ "Videos", .{ .Data1 = 0x18989B1D, .Data2 = 0x99B5, .Data3 = 0x455B, .Data4 = .{ 0x84, 0x1C, 0xAB, 0x7C, 0x74, 0xE4, 0xDD, 0xFC } } },
    .{ "ProgramData", .{ .Data1 = 0x62AB5D82, .Data2 = 0xFDC1, .Data3 = 0x4DC3, .Data4 = .{ 0xA9, 0xDD, 0x07, 0x0D, 0x1D, 0x49, 0x5D, 0x97 } } },
};

const variables = [_][]const u8{
    "USERPROFILE", "APPDATA",         "LOCALAPPDATA",      "TEMP",
    "ProgramData", "ProgramFiles",    "ProgramFiles(x86)", "CommonProgramFiles",
    "PUBLIC",      "ALLUSERSPROFILE", "COMPUTERNAME",      "USERDOMAIN",
    "USERNAME",
};

const CLSID_FileOpenDialog: GUID = .{ .Data1 = 0xDC1C5A9C, .Data2 = 0xE88A, .Data3 = 0x4DDE, .Data4 = .{ 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7 } };
const IID_IFileOpenDialog: GUID = .{ .Data1 = 0xD57C7288, .Data2 = 0xD4AD, .Data3 = 0x4768, .Data4 = .{ 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60 } };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;

    try printSelf(out);

    for (variables) |name| {
        var value: [32 * 1024]u16 = undefined;
        const len = GetEnvironmentVariableW(try win32.wide(arena, name), &value, value.len);
        if (len == 0 or len >= value.len) {
            try out.print("env {s} = (unset)\n", .{name});
        } else {
            try out.print("env {s} = {s}\n", .{ name, try std.unicode.wtf16LeToWtf8Alloc(arena, value[0..len]) });
        }
    }

    for (folders) |folder| {
        const name, const id = folder;
        var path: ?win32.LPWSTR = null;
        var hr = win32.SHGetKnownFolderPath(&id, 0, null, &path);
        const missing = hr != win32.S_OK;
        if (missing) {
            win32.CoTaskMemFree(path);
            path = null;
            hr = win32.SHGetKnownFolderPath(&id, KF_FLAG_DONT_VERIFY, null, &path);
        }
        defer win32.CoTaskMemFree(path);
        if (hr != win32.S_OK) {
            try out.print("folder {s} error 0x{x:0>8}\n", .{ name, @as(u32, @bitCast(hr)) });
            continue;
        }
        const dir = try std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.span(path.?));
        try reportFolder(arena, out, name, dir, missing);
    }

    var tmp: [32 * 1024]u16 = undefined;
    var len = GetTempPathW(tmp.len, &tmp);
    if (len > 0 and len < tmp.len) try reportFolder(arena, out, "GetTempPath", try std.unicode.wtf16LeToWtf8Alloc(arena, tmp[0..len]), false);
    len = GetTempPath2W(tmp.len, &tmp);
    if (len > 0 and len < tmp.len) try reportFolder(arena, out, "GetTempPath2", try std.unicode.wtf16LeToWtf8Alloc(arena, tmp[0..len]), false);

    var token: ?HANDLE = null;
    if (win32.OpenProcessToken(win32.GetCurrentProcess(), win32.TOKEN_QUERY, &token) != 0) {
        defer _ = win32.CloseHandle(token.?);
        var profile_len: DWORD = tmp.len;
        if (GetUserProfileDirectoryW(token.?, &tmp, &profile_len) != 0) {
            try out.print("folder GetUserProfileDirectory = {s}\n", .{try std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.span(@as([*:0]u16, @ptrCast(&tmp))))});
        } else {
            const code = win32.GetLastError();
            try out.print("folder GetUserProfileDirectory error {d} ({s})\n", .{ code, win32.errorName(code) });
        }
    }

    const pid = GetCurrentProcessId();
    try reportRegistry(out, "write HKCU\\Software", createAndDelete(try win32.wide(arena, try std.fmt.allocPrint(arena, "Software\\ZigsawHostProbe-{d}", .{pid}))));
    try reportRegistry(out, "write HKCU\\Software\\AppDataLow", createAndDelete(try win32.wide(arena, try std.fmt.allocPrint(arena, "Software\\AppDataLow\\ZigsawHostProbe-{d}", .{pid}))));
    try reportRegistry(out, "read HKLM", readMachine());

    var hr = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED);
    if (hr == win32.S_OK or hr == win32.S_FALSE) {
        var dialog: ?*anyopaque = null;
        hr = win32.CoCreateInstance(&CLSID_FileOpenDialog, null, win32.CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog, &dialog);
    }
    // Not released: the process ends here.
    if (hr == win32.S_OK) try out.print("com file-dialog ok\n", .{}) else try out.print("com file-dialog error 0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});

    if (OpenClipboard(null) != 0) {
        _ = CloseClipboard();
        try out.print("clipboard open ok\n", .{});
    } else {
        const code = win32.GetLastError();
        try out.print("clipboard open error {d} ({s})\n", .{ code, win32.errorName(code) });
    }
    try out.flush();
}

/// A check's result: null when it succeeded, else the Win32 error.
const Result = ?DWORD;

fn reportFolder(arena: std.mem.Allocator, out: *std.Io.Writer, name: []const u8, dir: []const u8, missing: bool) !void {
    if (missing) return out.print("folder {s} = {s} (missing)\n", .{ name, dir });
    const file = try std.fs.path.join(arena, &.{ dir, try std.fmt.allocPrint(arena, "zigsaw-hostprobe-{d}.tmp", .{GetCurrentProcessId()}) });
    const h = win32.CreateFileW(try win32.wide(arena, file), GENERIC_WRITE | DELETE, 0, null, CREATE_NEW, FILE_FLAG_DELETE_ON_CLOSE, null);
    if (h == win32.INVALID_HANDLE_VALUE) {
        const code = win32.GetLastError();
        return out.print("folder {s} = {s} (write error {d} ({s}))\n", .{ name, dir, code, win32.errorName(code) });
    }
    _ = win32.CloseHandle(h);
    try out.print("folder {s} = {s} (write ok)\n", .{ name, dir });
}

fn reportRegistry(out: *std.Io.Writer, what: []const u8, result: Result) !void {
    if (result) |code| {
        try out.print("registry {s} error {d} ({s})\n", .{ what, code, win32.errorName(code) });
    } else {
        try out.print("registry {s} ok\n", .{what});
    }
}

fn createAndDelete(sub_key: [*:0]const u16) Result {
    var key: win32.HKEY = undefined;
    const status = win32.RegCreateKeyExW(win32.HKEY_CURRENT_USER, sub_key, 0, null, 0, win32.KEY_WRITE, null, &key, null);
    if (status != win32.ERROR_SUCCESS) return status;
    _ = win32.RegCloseKey(key);
    const deleted = win32.RegDeleteKeyW(win32.HKEY_CURRENT_USER, sub_key);
    return if (deleted == win32.ERROR_SUCCESS) null else deleted;
}

fn readMachine() Result {
    var key: win32.HKEY = undefined;
    const status = win32.RegOpenKeyExW(HKEY_LOCAL_MACHINE, std.unicode.utf8ToUtf16LeStringLiteral("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion"), 0, KEY_QUERY_VALUE, &key);
    if (status != win32.ERROR_SUCCESS) return status;
    defer _ = win32.RegCloseKey(key);
    var size: DWORD = 0;
    const read = win32.RegQueryValueExW(key, std.unicode.utf8ToUtf16LeStringLiteral("CurrentBuild"), null, null, null, &size);
    return if (read == win32.ERROR_SUCCESS) null else read;
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
