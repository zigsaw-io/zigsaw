//! zigsaw-shim.exe, copied to `<root>\bin\<name>.exe` for each exported
//! command. It reads `<name>.shim` next to itself (see Sidecar.zig), runs
//!
//!   zigsaw run --command=<export> <app> <the caller's arguments>
//!
//! and exits with the app's exit code. The caller's arguments are passed on
//! exactly as typed, so nothing is re-quoted on the way through.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sidecar = @import("Sidecar.zig");
const process = @import("process.zig");
const win32 = @import("win32.zig");

// The shim is copied for every export, so it avoids what makes executables
// big: std.process.Init and std.Io, stack-trace printing in panics and
// segfaults, and std.debug.print for logging.
pub const panic = std.debug.simple_panic;
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .logFn = log,
};

fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
    _ = scope;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, level.asText() ++ ": " ++ fmt ++ "\n", args) catch return;
    const stderr = win32.GetStdHandle(win32.STD_ERROR_HANDLE) orelse return;
    _ = win32.WriteFile(stderr, msg.ptr, @intCast(msg.len), null, null);
}

pub fn main() void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const code = shim(arena_state.allocator()) catch |err| code: {
        if (err != error.Failed) std.log.err("zigsaw shim: {t}", .{err});
        break :code 1;
    };
    win32.ExitProcess(code);
}

fn shim(arena: Allocator) !u32 {
    const self = try win32.selfExePath(arena);
    const sidecar_path = try std.mem.concat(arena, u8, &.{ self[0 .. self.len - std.fs.path.extension(self).len], Sidecar.extension });
    const bytes = try readSmallFile(arena, sidecar_path);
    const sidecar = Sidecar.parse(bytes) catch {
        std.log.err("zigsaw shim: {s} is missing zigsaw, home, app or command", .{sidecar_path});
        return error.Failed;
    };

    // Use the store this shim belongs to, whatever ZIGSAW_HOME the caller has.
    if (win32.SetEnvironmentVariableW(try win32.wide(arena, "ZIGSAW_HOME"), try win32.wide(arena, sidecar.home)) == 0)
        return win32.lastErrorFail("SetEnvironmentVariableW");

    var command_line: std.ArrayList(u8) = .empty;
    try process.appendQuoted(arena, &command_line, sidecar.zigsaw);
    try command_line.appendSlice(arena, " run ");
    try process.appendQuoted(arena, &command_line, try std.fmt.allocPrint(arena, "--command={s}", .{sidecar.command}));
    try command_line.append(arena, ' ');
    try process.appendQuoted(arena, &command_line, sidecar.app);
    const args = try argumentsAsTyped(arena, std.mem.span(win32.GetCommandLineW()));
    if (args.len > 0 and args[0] != ' ' and args[0] != '\t') try command_line.append(arena, ' ');
    try command_line.appendSlice(arena, args);

    return process.spawn(arena, .{ .exe = sidecar.zigsaw, .command_line = command_line.items });
}

fn readSmallFile(arena: Allocator, path: []const u8) ![]const u8 {
    const file = win32.CreateFileW(try win32.wide(arena, path), win32.GENERIC_READ, win32.FILE_SHARE_READ, null, win32.OPEN_EXISTING, 0, null);
    if (file == win32.INVALID_HANDLE_VALUE) {
        const code = win32.GetLastError();
        std.log.err("zigsaw shim: can't read {s}: error {d} ({s})", .{ path, code, win32.errorName(code) });
        return error.Failed;
    }
    defer _ = win32.CloseHandle(file);
    const buf = try arena.alloc(u8, 64 * 1024);
    var len: win32.DWORD = 0;
    if (win32.ReadFile(file, buf.ptr, @intCast(buf.len), &len, null) == 0) return win32.lastErrorFail("ReadFile");
    return buf[0..len];
}

/// Everything in `command_line` after the program name, as WTF-8.
fn argumentsAsTyped(arena: Allocator, command_line: []const u16) ![]const u8 {
    return std.unicode.wtf16LeToWtf8Alloc(arena, command_line[programNameEnd(command_line)..]);
}

/// Where the program name ends, by the C runtime's rule: at the closing quote
/// if it starts with one, otherwise at the first space or tab.
fn programNameEnd(command_line: []const u16) usize {
    if (command_line.len > 0 and command_line[0] == '"') {
        const close = std.mem.indexOfScalarPos(u16, command_line, 1, '"') orelse return command_line.len;
        return close + 1;
    }
    return std.mem.indexOfAny(u16, command_line, &.{ ' ', '\t' }) orelse command_line.len;
}

test argumentsAsTyped {
    const cases = [_]struct { line: []const u8, args: []const u8 }{
        .{ .line = "npm install", .args = " install" },
        .{ .line = "\"C:\\Program Files\\x\\npm.exe\" install \"a b\"", .args = " install \"a b\"" },
        .{ .line = "npm", .args = "" },
        .{ .line = "\"C:\\x y\\npm.exe\"", .args = "" },
        .{ .line = "C:\\bin\\npm.exe\t-v  \"\\\"q\\\"\"", .args = "\t-v  \"\\\"q\\\"\"" },
    };
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (cases) |c| {
        const line = try std.unicode.wtf8ToWtf16LeAlloc(arena, c.line);
        try std.testing.expectEqualStrings(c.args, try argumentsAsTyped(arena, line));
    }
}
