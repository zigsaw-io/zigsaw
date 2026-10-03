//! Prints an htpasswd line, with a bcrypt hash, for a registry that wants
//! logins, such as zot (see tests/registry.sh):
//!
//!   zig run tests/htpasswd.zig -- <user> <password>

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.log.err("usage: htpasswd <user> <password>", .{});
        std.process.exit(2);
    }
    const bcrypt = std.crypto.pwhash.bcrypt;
    var hash_buf: [bcrypt.hash_length * 2]u8 = undefined;
    const hash = try bcrypt.strHash(args[2], .{ .params = .owasp, .encoding = .crypt }, &hash_buf, init.io);
    var buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    try stdout.interface.print("{s}:{s}\n", .{ args[1], hash });
    try stdout.interface.flush();
}
