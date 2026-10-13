//! A GUI program for testing the GUI shim (zigsaw-shimw.exe): it records its
//! arguments and whether whoever started it has a console, writes a line to
//! stderr, and exits with the code it's given. Built by `zig build
//! gui-fixture` for tests/shims.sh.
//!
//!   zigsaw-gui <record-file> <exit-code> [<stderr line>]
//!   zigsaw-gui            as a shortcut starts it: records that it ran, and
//!                         the shortcut Windows says started it, in
//!                         gui-record.txt in its working directory
//!   zigsaw-gui <file>     as a file association starts it: writes the file
//!                         again, with a first line saying what it was given

const std = @import("std");

const ATTACH_PARENT_PROCESS: u32 = @bitCast(@as(i32, -1));
extern "kernel32" fn AttachConsole(pid: u32) callconv(.winapi) c_int;

const STARTF_TITLEISLINKNAME: u32 = 0x800;
/// STARTUPINFOW, as far as its flags.
const StartupInfo = extern struct {
    cb: u32,
    reserved: ?[*:0]u16,
    desktop: ?[*:0]u16,
    title: ?[*:0]u16,
    position_and_size: [7]u32,
    flags: u32,
    rest: [40]u8,
};
extern "kernel32" fn GetStartupInfoW(info: *StartupInfo) callconv(.winapi) void;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 1) {
        // The shortcut it counts as started from, which the taskbar goes by.
        var startup: StartupInfo = undefined;
        GetStartupInfoW(&startup);
        const shortcut = if (startup.flags & STARTF_TITLEISLINKNAME != 0 and startup.title != null)
            try std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.span(startup.title.?))
        else
            "none";
        const record = try std.fmt.allocPrint(arena, "started without arguments\nshortcut: {s}\n", .{shortcut});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "gui-record.txt", .data = record });
        return 0;
    }
    if (args.len == 2) {
        const old = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1 << 20));
        const new = try std.fmt.allocPrint(arena, "opened {s}\n{s}", .{ args[1], old });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = new });
        return 0;
    }
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
