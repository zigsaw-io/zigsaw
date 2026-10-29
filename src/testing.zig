//! Helpers for tests.

/// `s` repeated `n` times, what `s ** n` made before Zig 0.17 took the
/// operator out.
pub fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    return comptime blk: {
        const buf: [n][s.len]u8 = @splat(s[0..s.len].*);
        break :blk @ptrCast(&buf);
    };
}

test repeat {
    const std = @import("std");
    try std.testing.expectEqualStrings("abab", repeat("ab", 2));
    try std.testing.expectEqualStrings("sha256:aaaa", "sha256:" ++ repeat("a", 4));
}
