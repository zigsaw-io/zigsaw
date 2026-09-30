//! The `<name>.shim` file next to each command shim in `<root>\bin`. It says
//! which zigsaw, store, app and export the shim runs, and so also which app
//! owns the command name. Plain "key = value" lines, easy to read and fix by
//! hand.

const Sidecar = @This();

const std = @import("std");

/// Absolute path of zigsaw.exe.
zigsaw: []const u8,
/// The store (ZIGSAW_HOME) the app is installed in.
home: []const u8,
/// App id.
app: []const u8,
/// Export name, passed as `zigsaw run --command=<command>`.
command: []const u8,

pub const extension = ".shim";

/// Parses sidecar text. The result points into `bytes`.
pub fn parse(bytes: []const u8) error{InvalidShimFile}!Sidecar {
    var zigsaw: ?[]const u8 = null;
    var home: ?[]const u8 = null;
    var app: ?[]const u8 = null;
    var command: ?[]const u8 = null;
    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidShimFile;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "zigsaw")) zigsaw = value;
        if (std.mem.eql(u8, key, "home")) home = value;
        if (std.mem.eql(u8, key, "app")) app = value;
        if (std.mem.eql(u8, key, "command")) command = value;
    }
    return .{
        .zigsaw = zigsaw orelse return error.InvalidShimFile,
        .home = home orelse return error.InvalidShimFile,
        .app = app orelse return error.InvalidShimFile,
        .command = command orelse return error.InvalidShimFile,
    };
}

pub fn format(s: Sidecar, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print(
        \\# Written by zigsaw. The .exe next to this file runs:
        \\#   zigsaw run --command=<command> <app>
        \\zigsaw = {s}
        \\home = {s}
        \\app = {s}
        \\command = {s}
        \\
    , .{ s.zigsaw, s.home, s.app, s.command });
}

test "round-trips" {
    const want: Sidecar = .{
        .zigsaw = "D:\\tools\\zigsaw.exe",
        .home = "C:\\Users\\me\\AppData\\Local\\zigsaw",
        .app = "org.nodejs.node",
        .command = "npm",
    };
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try want.format(&w);
    try std.testing.expectEqualDeep(want, try parse(w.buffered()));
    try std.testing.expectError(error.InvalidShimFile, parse("app = x\r\n"));
}
