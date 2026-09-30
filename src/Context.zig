//! Process-wide handles shared by every command.

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
