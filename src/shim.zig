//! zigsaw-shim.exe, copied to `<root>\bin\<name>.exe` for each exported
//! command. It reads `<name>.shim` next to itself (see Sidecar.zig), runs
//!
//!   zigsaw run --command=<export> <app> <the caller's arguments>
//!
//! and exits with the app's exit code. The caller's arguments are passed on
//! exactly as typed, so nothing is re-quoted on the way through.
//!
//! Built a second time as zigsaw-shimw.exe, a GUI program, for commands that
//! are GUI programs themselves (`gui` in the build options): started from
//! Explorer or the Start menu, it opens no console window, and neither does
//! the zigsaw it starts. Without a console, what zigsaw and the app write to
//! stderr would be lost, so when the caller gave it no file or pipe for
//! stderr, it keeps the end of that output, and shows it in a message box if
//! the app fails.
//!
//! Builds also copy it, as `B:\bin\<name>.exe`, for each alias their tools
//! provide. Its `.shim` then holds an alias (Sidecar.Alias), and the shim runs
//! the alias's command line and the caller's arguments directly. An alias
//! that drops some of the caller's arguments is the one case where they're
//! split and quoted again.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sidecar = @import("Sidecar.zig");
const process = @import("process.zig");
const win32 = @import("win32.zig");
const gui = @import("options").gui;

// The shim is copied for every export, so it avoids what makes executables
// big: std.process.Init and std.Io, stack-trace printing in panics and
// segfaults, and std.debug.print for logging.
pub const panic = std.debug.simple_panic;
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .logFn = log,
};

/// The GUI shim's own messages, for its report.
var own_log: Tail = .{};

fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
    _ = scope;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, level.asText() ++ ": " ++ fmt ++ "\n", args) catch return;
    if (gui) own_log.append(msg);
    const stderr = win32.GetStdHandle(win32.STD_ERROR_HANDLE) orelse return;
    _ = win32.WriteFile(stderr, msg.ptr, @intCast(msg.len), null, null);
}

pub fn main() void {
    // Checked first: a GUI program started from a console can find handle
    // values in its std slots that aren't its own, and the shim's own files
    // could reuse them.
    const report_failures = gui and !hasStderr();
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arena = arena_state.allocator();
    const code = shim(arena, report_failures) catch |err| code: {
        if (err != error.Failed) std.log.err("zigsaw shim: {t}", .{err});
        if (report_failures) {
            var copy: [Tail.capacity]u8 = undefined;
            report(arena, selfName(arena), own_log.text(&copy));
        }
        break :code 1;
    };
    win32.ExitProcess(code);
}

fn shim(arena: Allocator, report_failures: bool) !u32 {
    const self = try win32.selfExePath(arena);
    const sidecar_path = try std.mem.concat(arena, u8, &.{ self[0 .. self.len - std.fs.path.extension(self).len], Sidecar.extension });
    const bytes = try readSmallFile(arena, sidecar_path);
    const args = try argumentsAsTyped(arena, std.mem.span(win32.GetCommandLineW()));
    const sidecar = Sidecar.parse(bytes) catch {
        if (Sidecar.Alias.parse(arena, bytes)) |alias| return runAlias(arena, alias, args) else |_| {}
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
    try appendArguments(arena, &command_line, args);

    const spec: process.SpawnSpec = .{ .exe = sidecar.zigsaw, .command_line = command_line.items };
    if (!gui) return process.spawn(arena, spec);
    if (!report_failures) {
        var detached = spec;
        detached.creation_flags = win32.DETACHED_PROCESS;
        return process.spawn(arena, detached);
    }
    return runReporting(arena, spec, sidecar);
}

/// Runs zigsaw without a console, with its stdout and stderr, which the app
/// inherits, going to a pipe whose end is kept. If the app fails, shows that
/// end with its exit code.
fn runReporting(arena: Allocator, spec: process.SpawnSpec, sidecar: Sidecar) !u32 {
    var read: win32.HANDLE = undefined;
    var write: win32.HANDLE = undefined;
    // Neither end is inheritable; `start` makes the write end so for zigsaw.
    if (win32.CreatePipe(&read, &write, null, 0) == 0) return win32.lastErrorFail("CreatePipe");
    defer _ = win32.CloseHandle(read);
    var detached = spec;
    detached.creation_flags = win32.DETACHED_PROCESS;
    detached.stdio = .{ null, write, write };
    const child = process.start(arena, detached) catch |err| {
        _ = win32.CloseHandle(write);
        return err;
    };
    // The pipe ends when the last writer is gone: zigsaw, the app, and what
    // the app started, all in zigsaw's job, which ends them all with it.
    _ = win32.CloseHandle(write);
    var tail: Tail = .{};
    var buf: [4096]u8 = undefined;
    while (true) {
        var n: win32.DWORD = 0;
        if (win32.ReadFile(read, &buf, buf.len, &n, null) == 0) break;
        tail.append(buf[0..n]);
    }
    const code = try child.wait();
    if (code != 0) {
        var copy: [Tail.capacity]u8 = undefined;
        const output = lastLines(tail.text(&copy), 20);
        const exit = if (code >= 0xC0000000)
            try std.fmt.allocPrint(arena, "0x{X:0>8}", .{code})
        else
            try std.fmt.allocPrint(arena, "{d}", .{code});
        report(arena, sidecar.command, try std.fmt.allocPrint(arena, "{s} ({s}) exited with code {s}.{s}{s}", .{
            sidecar.command, sidecar.app, exit, if (output.len > 0) "\n\n" else "", output,
        }));
    }
    return code;
}

/// Whether the caller gave us a file or a pipe for stderr: then whoever
/// started us sees what's written there.
fn hasStderr() bool {
    const h = win32.GetStdHandle(win32.STD_ERROR_HANDLE) orelse return false;
    if (h == win32.INVALID_HANDLE_VALUE) return false;
    const kind = win32.GetFileType(h);
    return kind == win32.FILE_TYPE_DISK or kind == win32.FILE_TYPE_PIPE;
}

/// Shows a failure in a message box, or, for tests, writes it to the file
/// ZIGSAW_SHIM_REPORT names.
fn report(arena: Allocator, title: []const u8, message: []const u8) void {
    if (envVar(arena, "ZIGSAW_SHIM_REPORT")) |path| {
        const text = std.fmt.allocPrint(arena, "{s}\n{s}\n", .{ title, message }) catch return;
        const file = win32.CreateFileW(win32.wide(arena, path) catch return, win32.GENERIC_WRITE, 0, null, win32.CREATE_ALWAYS, 0, null);
        if (file == win32.INVALID_HANDLE_VALUE) return;
        defer _ = win32.CloseHandle(file);
        _ = win32.WriteFile(file, text.ptr, @intCast(text.len), null, null);
        return;
    }
    const text = lossyWide(arena, message) catch return;
    const caption = lossyWide(arena, title) catch return;
    _ = win32.MessageBoxW(null, text, caption, win32.MB_OK | win32.MB_ICONERROR);
}

fn envVar(arena: Allocator, name: []const u8) ?[]const u8 {
    const buf = arena.alloc(u16, 32 * 1024) catch return null;
    const len = win32.GetEnvironmentVariableW(win32.wide(arena, name) catch return null, buf.ptr, @intCast(buf.len));
    if (len == 0 or len >= buf.len) return null;
    return std.unicode.wtf16LeToWtf8Alloc(arena, buf[0..len]) catch null;
}

/// The shim's file name without extension: the command's name.
fn selfName(arena: Allocator) []const u8 {
    const self = win32.selfExePath(arena) catch return "zigsaw shim";
    return std.fs.path.stem(self);
}

/// UTF-16 for text that may not be valid UTF-8, such as an app's output:
/// what isn't becomes U+FFFD.
fn lossyWide(arena: Allocator, text: []const u8) ![:0]u16 {
    var out: std.ArrayList(u16) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
        const decoded: ?u21 = if (len > 0 and i + len <= text.len) std.unicode.utf8Decode(text[i..][0..len]) catch null else null;
        const cp = decoded orelse 0xFFFD;
        i += if (decoded != null) len else 1;
        if (cp < 0x10000) {
            try out.append(arena, @intCast(cp));
        } else {
            const v = cp - 0x10000;
            try out.appendSlice(arena, &.{ @intCast(0xD800 + (v >> 10)), @intCast(0xDC00 + (v & 0x3FF)) });
        }
    }
    return out.toOwnedSliceSentinel(arena, 0);
}

/// The last bytes written to it.
const Tail = struct {
    const capacity = 8192;
    buf: [capacity]u8 = undefined,
    /// How many bytes were appended in all.
    total: usize = 0,

    fn append(t: *Tail, bytes: []const u8) void {
        for (bytes) |b| {
            t.buf[t.total % capacity] = b;
            t.total += 1;
        }
    }

    /// What it holds, in order, copied into `out`. When earlier bytes were
    /// dropped, it starts after the first line break, so it doesn't start
    /// in the middle of a line or of a character.
    fn text(t: *const Tail, out: *[capacity]u8) []const u8 {
        if (t.total <= capacity) {
            @memcpy(out[0..t.total], t.buf[0..t.total]);
            return out[0..t.total];
        }
        const start = t.total % capacity;
        @memcpy(out[0 .. capacity - start], t.buf[start..]);
        @memcpy(out[capacity - start ..], t.buf[0..start]);
        const nl = std.mem.indexOfScalar(u8, out, '\n') orelse return out;
        return out[nl + 1 ..];
    }
};

/// The last `n` lines of `text`, without trailing white space.
fn lastLines(text: []const u8, n: usize) []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, " \t\r\n");
    var start = trimmed.len;
    var lines: usize = 0;
    while (start > 0) : (start -= 1) {
        if (trimmed[start - 1] == '\n') {
            lines += 1;
            if (lines == n) break;
        }
    }
    return trimmed[start..];
}

fn runAlias(arena: Allocator, alias: Sidecar.Alias, args: []const u8) !u32 {
    var command_line: std.ArrayList(u8) = .empty;
    try command_line.appendSlice(arena, alias.command_line);
    if (alias.drop.len == 0) {
        try appendArguments(arena, &command_line, args);
    } else {
        try appendKept(arena, &command_line, args, alias.drop);
    }
    return process.spawn(arena, .{ .exe = alias.exe, .command_line = command_line.items });
}

/// Appends the caller's arguments, split as the C runtime splits them, less
/// those equal to one in `drop`, quoted again.
fn appendKept(arena: Allocator, command_line: *std.ArrayList(u8), args: []const u8, drop: []const []const u8) !void {
    // The iterator reads its first argument as a program name, by other rules.
    const line = try std.unicode.wtf8ToWtf16LeAlloc(arena, try std.mem.concat(arena, u8, &.{ "x ", args }));
    var it: std.process.Args.Iterator.Windows = try .init(arena, line);
    _ = it.next();
    next: while (it.next()) |arg| {
        for (drop) |d| if (std.mem.eql(u8, arg, d)) continue :next;
        try command_line.append(arena, ' ');
        try process.appendQuoted(arena, command_line, arg);
    }
}

test appendKept {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { args: []const u8, want: []const u8 }{
        .{ .args = " --64 -o x.o x.s", .want = "as -o x.o x.s" },
        .{ .args = "", .want = "as" },
        .{ .args = " --64", .want = "as" },
        .{ .args = "\t\"--64\"  \"a b\" --640 c\\\"d \"e\\\\\"", .want = "as \"a b\" --640 \"c\\\"d\" e\\" },
    };
    for (cases) |c| {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, "as");
        try appendKept(arena, &out, c.args, &.{"--64"});
        try std.testing.expectEqualStrings(c.want, out.items);
    }
}

/// Appends the caller's arguments as typed, separated by a space.
fn appendArguments(arena: Allocator, command_line: *std.ArrayList(u8), args: []const u8) !void {
    if (args.len > 0 and args[0] != ' ' and args[0] != '\t') try command_line.append(arena, ' ');
    try command_line.appendSlice(arena, args);
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

test Tail {
    var t: Tail = .{};
    var out: [Tail.capacity]u8 = undefined;
    t.append("one\ntwo\n");
    try std.testing.expectEqualStrings("one\ntwo\n", t.text(&out));
    // Past its capacity, it keeps the end, from the first whole line.
    for (0..1000) |i| {
        var line: [16]u8 = undefined;
        t.append(try std.fmt.bufPrint(&line, "line {d}\n", .{i}));
    }
    const kept = t.text(&out);
    try std.testing.expect(std.mem.startsWith(u8, kept, "line "));
    try std.testing.expect(std.mem.endsWith(u8, kept, "line 999\n"));
    try std.testing.expectEqualStrings("line 998\nline 999", lastLines(kept, 2));
}

test lastLines {
    try std.testing.expectEqualStrings("b\nc", lastLines("a\nb\nc\n\n", 2));
    try std.testing.expectEqualStrings("a\nb", lastLines("a\nb", 5));
    try std.testing.expectEqualStrings("", lastLines("\r\n", 3));
}

test lossyWide {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("héllo 😀"), try lossyWide(arena, "héllo 😀"));
    try std.testing.expectEqualSlices(u16, &.{ 'a', 0xFFFD, 'b', 0xFFFD, 'c', 0xFFFD }, try lossyWide(arena, "a\xffb\xc3c\xc3"));
}
