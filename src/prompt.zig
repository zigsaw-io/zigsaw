//! Asking the user something: on the console, or from what's piped to stdin
//! when there's no console, as `echo y | zigsaw pull ...` does.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const win32 = @import("win32.zig");
const note = Context.note;

// The console mode to restore if Ctrl+C ends zigsaw during a password prompt.
var prompt_console: ?win32.HANDLE = null;
var prompt_mode: win32.DWORD = 0;

fn restoreEcho(event: win32.DWORD) callconv(.winapi) win32.BOOL {
    _ = event;
    if (prompt_console) |h| _ = win32.SetConsoleMode(h, prompt_mode);
    // Let the default handler end zigsaw.
    return win32.FALSE;
}

pub const Echo = enum { echo, no_echo };

/// Asks for a line on the console, with or without echoing what's typed.
/// Null if stdin isn't a console; error.EndOfInput on Ctrl+C or the end of
/// input.
pub fn consoleLine(arena: Allocator, label: []const u8, echo: Echo) !?[]const u8 {
    const console = win32.GetStdHandle(win32.STD_INPUT_HANDLE);
    var mode: win32.DWORD = 0;
    if (console == null or console == win32.INVALID_HANDLE_VALUE or win32.GetConsoleMode(console.?, &mode) == win32.FALSE)
        return null;
    const h = console.?;

    Context.printStderr("{s}", .{label});
    if (echo == .no_echo) {
        prompt_console = h;
        prompt_mode = mode;
        _ = win32.SetConsoleCtrlHandler(&restoreEcho, win32.TRUE);
        if (win32.SetConsoleMode(h, (mode | win32.ENABLE_LINE_INPUT | win32.ENABLE_PROCESSED_INPUT) & ~win32.ENABLE_ECHO_INPUT) == win32.FALSE)
            return win32.lastErrorFail("turning off the console's echo (SetConsoleMode)");
    }
    defer if (echo == .no_echo) {
        _ = win32.SetConsoleMode(h, mode);
        _ = win32.SetConsoleCtrlHandler(&restoreEcho, win32.FALSE);
        prompt_console = null;
    };

    var line: std.ArrayList(u16) = .empty;
    const complete = while (std.mem.indexOfScalar(u16, line.items, '\n') == null) {
        var buf: [256]u16 = undefined;
        var n: win32.DWORD = 0;
        // Nothing read means Ctrl+C, or the end of input.
        if (win32.ReadConsoleW(h, &buf, buf.len, &n, null) == win32.FALSE or n == 0) break false;
        try line.appendSlice(arena, buf[0..n]);
    } else true;
    // The Enter that ended the line wasn't echoed either.
    if (echo == .no_echo) Context.printStderr("\n", .{});
    if (!complete) return error.EndOfInput;
    const end = std.mem.indexOfScalar(u16, line.items, '\n').?;
    const text = std.mem.trimEnd(u16, line.items[0..end], &.{'\r'});
    return try std.unicode.wtf16LeToWtf8Alloc(arena, text);
}

pub const Answer = enum { yes, no, none };

/// Asks a yes-or-no question, whose answer is yes by default. Without a
/// console, the answer is the next line on stdin; `none` at its end, or when
/// there's no stdin.
pub fn askYesNo(ctx: *Context, question: []const u8) !Answer {
    const label = try std.fmt.allocPrint(ctx.arena, "{s} [Y/n] ", .{question});
    while (true) {
        const line = (consoleLine(ctx.arena, label, .echo) catch |err| switch (err) {
            error.EndOfInput => {
                Context.printStderr("\n", .{});
                return .none;
            },
            else => |e| return e,
        }) orelse piped: {
            Context.printStderr("{s}", .{label});
            const l = stdinLine(ctx) orelse {
                Context.printStderr("\n", .{});
                return .none;
            };
            // So that a log shows what was answered.
            Context.printStderr("{s}\n", .{l});
            break :piped l;
        };
        if (parseAnswer(line)) |a| return a;
        note("answer y or n", .{});
    }
}

/// "y", "yes" or nothing is yes; "n" or "no" is no; anything else is no
/// answer yet.
fn parseAnswer(line: []const u8) ?Answer {
    const a = std.mem.trim(u8, line, " \t\r");
    if (a.len == 0 or std.ascii.eqlIgnoreCase(a, "y") or std.ascii.eqlIgnoreCase(a, "yes")) return .yes;
    if (std.ascii.eqlIgnoreCase(a, "n") or std.ascii.eqlIgnoreCase(a, "no")) return .no;
    return null;
}

// One reader for the whole process, so that each question takes one line
// of what's piped in: `update` may ask about several apps.
var stdin_buf: [4096]u8 = undefined;
var stdin_reader: ?Io.File.Reader = null;

/// The next line on stdin, or null at its end, or if it can't be read.
fn stdinLine(ctx: *Context) ?[]const u8 {
    if (stdin_reader == null) stdin_reader = Io.File.stdin().readerStreaming(ctx.io, &stdin_buf);
    const line = stdin_reader.?.interface.takeDelimiter('\n') catch return null;
    return ctx.arena.dupe(u8, line orelse return null) catch null;
}

test parseAnswer {
    try std.testing.expectEqual(Answer.yes, parseAnswer("").?);
    try std.testing.expectEqual(Answer.yes, parseAnswer("Y\r").?);
    try std.testing.expectEqual(Answer.yes, parseAnswer(" yes ").?);
    try std.testing.expectEqual(Answer.no, parseAnswer("n").?);
    try std.testing.expectEqual(Answer.no, parseAnswer("NO").?);
    try std.testing.expectEqual(@as(?Answer, null), parseAnswer("maybe"));
}
