//! Just enough of the PE format to tell a GUI executable from a console one,
//! which decides the shim a command gets (see exports.zig).

const std = @import("std");
const Io = std.Io;

pub const Subsystem = enum { gui, console };

/// The subsystem of the executable at `path`; null for other subsystems and
/// for files that aren't executables.
pub fn subsystem(io: Io, path: []const u8) !?Subsystem {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var dos: [64]u8 = undefined;
    if (try file.readPositionalAll(io, &dos, 0) != dos.len) return null;
    const offset = ntHeaderOffset(&dos) orelse return null;
    var nt: [nt_len]u8 = undefined;
    if (try file.readPositionalAll(io, &nt, offset) != nt.len) return null;
    return fromNtHeaders(&nt);
}

/// The PE signature, the file header, and the optional header up to and
/// including Subsystem, which is at the same offset in PE32 and PE32+.
const nt_len = 4 + 20 + 70;

/// Where the NT headers start, from the DOS header's e_lfanew.
fn ntHeaderOffset(dos: *const [64]u8) ?u32 {
    if (!std.mem.eql(u8, dos[0..2], "MZ")) return null;
    return std.mem.readInt(u32, dos[0x3c..0x40], .little);
}

fn fromNtHeaders(nt: *const [nt_len]u8) ?Subsystem {
    if (!std.mem.eql(u8, nt[0..4], "PE\x00\x00")) return null;
    return switch (std.mem.readInt(u16, nt[4 + 20 + 68 ..][0..2], .little)) {
        2 => .gui, // IMAGE_SUBSYSTEM_WINDOWS_GUI
        3 => .console, // IMAGE_SUBSYSTEM_WINDOWS_CUI
        else => null,
    };
}

/// A minimal PE header with the given subsystem value, for tests.
fn testImage(value: u16) [0x80 + nt_len]u8 {
    var b = std.mem.zeroes([0x80 + nt_len]u8);
    b[0] = 'M';
    b[1] = 'Z';
    std.mem.writeInt(u32, b[0x3c..0x40], 0x80, .little);
    @memcpy(b[0x80..0x84], "PE\x00\x00");
    std.mem.writeInt(u16, b[0x80 + 4 + 20 + 68 ..][0..2], value, .little);
    return b;
}

test subsystem {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cases = [_]struct { name: []const u8, data: []const u8, want: ?Subsystem }{
        .{ .name = "gui.exe", .data = &testImage(2), .want = .gui },
        .{ .name = "console.exe", .data = &testImage(3), .want = .console },
        .{ .name = "native.exe", .data = &testImage(1), .want = null },
        .{ .name = "script.cmd", .data = "@echo off\r\n", .want = null },
        .{ .name = "truncated.exe", .data = testImage(2)[0..0x90], .want = null },
        .{ .name = "empty.exe", .data = "", .want = null },
    };
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena_state.allocator());
    for (cases) |c| {
        try tmp.dir.writeFile(io, .{ .sub_path = c.name, .data = c.data });
        const p = try std.fs.path.join(arena_state.allocator(), &.{ root, c.name });
        try std.testing.expectEqual(c.want, try subsystem(io, p));
    }
    try std.testing.expectError(error.FileNotFound, subsystem(io, try std.fs.path.join(arena_state.allocator(), &.{ root, "missing.exe" })));
}
