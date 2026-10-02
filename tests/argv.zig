//! Prints its arguments, one per line, as hex (of their WTF-8 bytes), so a
//! test can compare them byte for byte whatever they contain. Built by
//! `zig build argv-echo` for tests/batch.sh, which runs it behind a batch file.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    for (args[1..]) |arg| try stdout.interface.print("{x}\n", .{arg});
    try stdout.interface.flush();
}
