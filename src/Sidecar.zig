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
/// Whether the command is a GUI program, so the shim next to this file is
/// zigsaw-shimw.exe, which opens no console. Absent in sidecars written
/// before iteration 11, whose shims are all console ones.
gui: bool = false,

pub const extension = ".shim";

/// Parses sidecar text. The result points into `bytes`.
pub fn parse(bytes: []const u8) error{InvalidShimFile}!Sidecar {
    var zigsaw: ?[]const u8 = null;
    var home: ?[]const u8 = null;
    var app: ?[]const u8 = null;
    var command: ?[]const u8 = null;
    var gui = false;
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
        if (std.mem.eql(u8, key, "gui")) gui = std.mem.eql(u8, value, "true");
    }
    return .{
        .zigsaw = zigsaw orelse return error.InvalidShimFile,
        .home = home orelse return error.InvalidShimFile,
        .app = app orelse return error.InvalidShimFile,
        .command = command orelse return error.InvalidShimFile,
        .gui = gui,
    };
}

pub fn eql(a: Sidecar, b: Sidecar) bool {
    return std.mem.eql(u8, a.zigsaw, b.zigsaw) and std.mem.eql(u8, a.home, b.home) and
        std.mem.eql(u8, a.app, b.app) and std.mem.eql(u8, a.command, b.command) and a.gui == b.gui;
}

pub fn format(s: Sidecar, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print(
        \\# Written by zigsaw. The .exe next to this file runs:
        \\#   zigsaw run --command=<command> <app>
        \\zigsaw = {s}
        \\home = {s}
        \\app = {s}
        \\command = {s}
        \\gui = {}
        \\
    , .{ s.zigsaw, s.home, s.app, s.command, s.gui });
}

/// The sidecar of an alias shim, which a build puts on its PATH for a
/// command one of its tools provides (see `aliases` in oci.AppConfig). The
/// shim runs `command_line` and then the caller's arguments, less those in
/// `drop`, in the caller's environment, without zigsaw in between.
pub const Alias = struct {
    /// Absolute path of the executable.
    exe: []const u8,
    /// The executable, quoted, and the alias's own arguments.
    command_line: []const u8,
    /// The caller's arguments to leave out, one `drop` line each. Values
    /// can't start or end with spaces or tabs, which parsing trims.
    drop: []const []const u8 = &.{},

    pub fn parse(arena: std.mem.Allocator, bytes: []const u8) error{ InvalidShimFile, OutOfMemory }!Alias {
        var exe: ?[]const u8 = null;
        var command_line: ?[]const u8 = null;
        var drop: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidShimFile;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (std.mem.eql(u8, key, "exe")) exe = value;
            if (std.mem.eql(u8, key, "command_line")) command_line = value;
            if (std.mem.eql(u8, key, "drop")) try drop.append(arena, value);
        }
        return .{
            .exe = exe orelse return error.InvalidShimFile,
            .command_line = command_line orelse return error.InvalidShimFile,
            .drop = drop.items,
        };
    }

    pub fn format(a: Alias, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print(
            \\# Written by zigsaw for a build. The .exe next to this file runs
            \\# command_line, then the caller's arguments, less any it drops.
            \\exe = {s}
            \\command_line = {s}
            \\
        , .{ a.exe, a.command_line });
        for (a.drop) |d| try w.print("drop = {s}\n", .{d});
    }
};

test "aliases round-trip" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const want: Alias = .{ .exe = "C:\\z\\deploy\\ab\\zig.exe", .command_line = "C:\\z\\deploy\\ab\\zig.exe ar" };
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try want.format(&w);
    try std.testing.expectEqualDeep(want, try Alias.parse(arena, w.buffered()));
    try std.testing.expectError(error.InvalidShimFile, parse(w.buffered()));

    const dropping: Alias = .{ .exe = want.exe, .command_line = "C:\\z\\deploy\\ab\\zig.exe cc -c", .drop = &.{ "--64", "-x c" } };
    w = .fixed(&buf);
    try dropping.format(&w);
    try std.testing.expectEqualDeep(dropping, try Alias.parse(arena, w.buffered()));
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

    var gui = want;
    gui.gui = true;
    w = .fixed(&buf);
    try gui.format(&w);
    try std.testing.expectEqualDeep(gui, try parse(w.buffered()));
    try std.testing.expect(!gui.eql(want));
    // Sidecars from before iteration 11 have no gui line.
    const old = try parse("zigsaw = z.exe\r\nhome = h\r\napp = a\r\ncommand = c\r\n");
    try std.testing.expect(!old.gui);
}
