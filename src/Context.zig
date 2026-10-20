//! Process-wide handles shared by every command.

const Context = @This();

const std = @import("std");
const Store = @import("Store.zig");
const win32 = @import("win32.zig");

io: std.Io,
/// Thread-safe allocator for long-lived or shared allocations (e.g. the HTTP client).
gpa: std.mem.Allocator,
/// Freed at process exit; zigsaw is a short-lived CLI, so most allocations go here.
arena: std.mem.Allocator,
env: *std.process.Environ.Map,
store: Store,
verbose: bool = false,

/// Logs an error for the user and returns `error.Failed`, which `main` exits on
/// without printing anything further.
pub fn fail(comptime fmt: []const u8, args: anytype) error{Failed} {
    // The test runner counts error logs as failures, and tests check for
    // failures on purpose.
    if (@import("builtin").is_test) std.log.debug(fmt, args) else printStderr("error: " ++ fmt ++ "\n", args);
    return error.Failed;
}

/// Progress and diagnostic output, always on stderr so stdout stays the app's.
pub fn note(comptime fmt: []const u8, args: anytype) void {
    printStderr(fmt ++ "\n", args);
}

/// Writes to stderr, ignoring failures. std.debug.print means to as well,
/// but in Zig 0.16 it crashes on Windows once stderr is a pipe nobody reads
/// any more, as in `zigsaw build ... | head`. A build ending that way would
/// leave its build drive mapped and its files behind.
pub fn printStderr(comptime fmt: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    var w: std.Io.Writer = .{ .vtable = &.{ .drain = drainToStderr }, .buffer = &buffer };
    w.print(fmt, args) catch {};
    w.flush() catch {};
}

fn drainToStderr(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    writeStderr(w.buffered());
    w.end = 0;
    const pattern = data[data.len - 1];
    var written: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        writeStderr(bytes);
        written += bytes.len;
    }
    for (0..splat) |_| writeStderr(pattern);
    return written + pattern.len * splat;
}

fn writeStderr(bytes: []const u8) void {
    const handle = win32.GetStdHandle(win32.STD_ERROR_HANDLE) orelse return;
    var rest = bytes;
    while (rest.len > 0) {
        var written: win32.DWORD = 0;
        if (win32.WriteFile(handle, rest.ptr, @intCast(@min(rest.len, 1 << 20)), &written, null) == 0 or written == 0) return;
        rest = rest[written..];
    }
}

pub fn now(ctx: *const Context) std.Io.Timestamp {
    return .now(ctx.io, .awake);
}

/// How long since `start`, as `Duration` shows it.
pub fn since(ctx: *const Context, start: std.Io.Timestamp) Duration {
    return .{ .ms = @intCast(@max(0, start.untilNow(ctx.io, .awake).toMilliseconds())) };
}

/// A duration as a build's log shows it, `{f}`: "850 ms", "12.3 s",
/// "4m 07s", "1h 03m".
pub const Duration = struct {
    ms: u64,

    pub fn format(d: Duration, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const s = d.ms / 1000;
        if (d.ms < 1000) {
            try w.print("{d} ms", .{d.ms});
        } else if (s < 60) {
            try w.print("{d}.{d} s", .{ s, d.ms % 1000 / 100 });
        } else if (s < 3600) {
            try w.print("{d}m {d:0>2}s", .{ s / 60, s % 60 });
        } else {
            try w.print("{d}h {d:0>2}m", .{ s / 3600, s % 3600 / 60 });
        }
    }
};

test Duration {
    const cases = [_]struct { u64, []const u8 }{
        .{ 0, "0 ms" },         .{ 850, "850 ms" },        .{ 1000, "1.0 s" },
        .{ 12_345, "12.3 s" },  .{ 59_999, "59.9 s" },     .{ 60_000, "1m 00s" },
        .{ 247_000, "4m 07s" }, .{ 3_599_000, "59m 59s" }, .{ 3_780_000, "1h 03m" },
    };
    for (cases) |c| {
        const got = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{Duration{ .ms = c[0] }});
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
}

/// In verbose mode, reports how long a step that began at `start` took.
pub fn timed(ctx: *const Context, start: std.Io.Timestamp, comptime what: []const u8, args: anytype) void {
    reportTime(ctx.io, ctx.verbose, start, what, args);
}

/// `timed` for code that has no Context.
pub fn reportTime(io: std.Io, verbose: bool, start: std.Io.Timestamp, comptime what: []const u8, args: anytype) void {
    if (!verbose) return;
    const ms: u64 = @intCast(@max(0, start.untilNow(io, .awake).toMilliseconds()));
    note("{d:>7} ms  " ++ what, .{ms} ++ args);
}
