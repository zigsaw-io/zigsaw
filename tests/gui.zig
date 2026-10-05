//! A GUI program for testing the GUI shim (zigsaw-shimw.exe): it records its
//! arguments and whether whoever started it has a console, writes a line to
//! stderr, and exits with the code it's given. Built by `zig build
//! gui-fixture` for tests/shims.sh.
//!
//!   zigsaw-gui <record-file> <exit-code> [<stderr line>]
//!   zigsaw-gui            as a shortcut starts it: records that it ran in
//!                         gui-record.txt in its working directory

const std = @import("std");

const ATTACH_PARENT_PROCESS: u32 = @bitCast(@as(i32, -1));
extern "kernel32" fn AttachConsole(pid: u32) callconv(.winapi) c_int;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 1) {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "gui-record.txt", .data = "started without arguments\n" });
        return 0;
    }
    if (args.len < 3) return 2;
    // zigsaw starts the app; a GUI shim starts zigsaw without a console.
    const parent_console = AttachConsole(ATTACH_PARENT_PROCESS) != 0;
    var record: std.ArrayList(u8) = .empty;
    try record.print(arena, "parent console: {s}\n", .{if (parent_console) "yes" else "no"});
    for (args[3..]) |arg| try record.print(arena, "arg: {s}\n", .{arg});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = record.items });
    if (args.len > 3) {
        var buf: [256]u8 = undefined;
        var stderr = std.Io.File.stderr().writerStreaming(io, &buf);
        stderr.interface.print("{s}\n", .{args[3]}) catch {};
        stderr.interface.flush() catch {};
    }
    return std.fmt.parseInt(u8, args[2], 10);
}
