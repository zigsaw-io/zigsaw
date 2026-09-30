//! Process-wide handles shared by every command.

const Context = @This();

const std = @import("std");
const Store = @import("Store.zig");

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
    std.log.err(fmt, args);
    return error.Failed;
}

/// Progress and diagnostic output, always on stderr so stdout stays the app's.
pub fn note(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

pub fn now(ctx: *const Context) std.Io.Timestamp {
    return .now(ctx.io, .awake);
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
