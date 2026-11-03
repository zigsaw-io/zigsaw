//! zigsaw-host.exe: runs one of the user's own programs from inside a run,
//! as `flatpak-spawn --host` does on Linux. On the PATH of runs that have
//! `--share=host`:
//!
//!   zigsaw-host <program> [arguments]
//!
//! A run's environment is made from scratch (see environment.zig), so programs
//! installed the usual way aren't on its PATH, and those found by their path
//! look for their settings in the app's data. This starts the program with the
//! variables Windows gives the user's programs instead, finds it on that PATH,
//! and returns its exit code.
//!
//! Only the environment changes. Unlike Flatpak's, nothing on the other side
//! runs it: it keeps this process's token and is in its job, so in a low run
//! it runs at low integrity, and it ends with the run. The working directory,
//! console and standard handles are the caller's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const process = @import("process.zig");
const win32 = @import("win32.zig");

// Small, as the shim is: no std.Io, and no stack traces.
pub const panic = std.debug.simple_panic;
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .logFn = log,
};

fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
    _ = scope;
    _ = level;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zigsaw-host: " ++ fmt ++ "\n", args) catch return;
    const stderr = win32.GetStdHandle(win32.STD_ERROR_HANDLE) orelse return;
    _ = win32.WriteFile(stderr, msg.ptr, @intCast(msg.len), null, null);
}

pub fn main() void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const code = host(arena_state.allocator()) catch |err| code: {
        if (err != error.Failed) std.log.err("{t}", .{err});
        break :code 1;
    };
    win32.ExitProcess(code);
}

fn host(arena: Allocator) !u32 {
    const line = std.mem.span(win32.GetCommandLineW());
    var it: std.process.Args.Iterator.Windows = try .init(arena, line);
    _ = it.next();
    const program = it.next() orelse {
        std.log.err("usage: zigsaw-host <program> [arguments]: runs one of your programs in your real environment", .{});
        return 2;
    };
    var args: std.ArrayList([]const u8) = .empty;
    while (it.next()) |arg| try args.append(arena, arg);

    const block = try process.userEnvironmentBlock(arena);
    const path = try variable(arena, block, "PATH") orelse "";
    const pathext = try variable(arena, block, "PATHEXT") orelse ".COM;.EXE;.BAT;.CMD";
    const exe = try find(arena, path, pathext, program) orelse {
        std.log.err("{s} isn't on your PATH", .{program});
        return 127;
    };
    if (isBatch(exe)) {
        const root = try variable(arena, block, "SystemRoot") orelse "C:\\Windows";
        const cmd = try std.fmt.allocPrint(arena, "{s}\\System32\\cmd.exe", .{root});
        const command_line = process.buildBatchCommandLine(arena, cmd, exe, args.items) catch |err| switch (err) {
            error.InvalidBatchArgument => {
                std.log.err("{s} is a batch file, and cmd.exe can't pass it an argument with a line break or a NUL character", .{exe});
                return 1;
            },
            error.InvalidBatchScript => {
                std.log.err("{s} can't be run as a batch file", .{exe});
                return 1;
            },
            error.OutOfMemory => |e| return e,
        };
        return process.spawn(arena, .{ .exe = cmd, .command_line = command_line, .env_block = block });
    }
    return process.spawn(arena, .{ .exe = exe, .command_line = try process.buildCommandLine(arena, exe, args.items), .env_block = block });
}

/// A variable of an environment block, by name, ignoring case.
fn variable(arena: Allocator, block: []const u16, name: []const u8) !?[]const u8 {
    var rest = block;
    while (rest.len > 0 and rest[0] != 0) {
        const end = std.mem.indexOfScalar(u16, rest, 0) orelse break;
        const entry = rest[0..end];
        rest = rest[end + 1 ..];
        const eq = std.mem.indexOfScalarPos(u16, entry, 1, '=') orelse continue;
        if (eq != name.len) continue;
        for (entry[0..eq], name) |a, b| {
            if (a >= 0x80 or std.ascii.toLower(@intCast(a)) != std.ascii.toLower(b)) break;
        } else return try std.unicode.wtf16LeToWtf8Alloc(arena, entry[eq + 1 ..]);
    }
    return null;
}

test variable {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const block = std.unicode.utf8ToUtf16LeStringLiteral("=C:=C:\\x\x00Path=a;b\x00PATHEXT=.EXE\x00\x00");
    try std.testing.expectEqualStrings("a;b", (try variable(arena, block, "PATH")).?);
    try std.testing.expectEqualStrings(".EXE", (try variable(arena, block, "pathext")).?);
    try std.testing.expectEqual(null, try variable(arena, block, "PAT"));
}

/// Where cmd.exe would find the program: in each directory on `path`, in
/// order, by each extension of `pathext`; and by its own name if it has an
/// extension. A name with a directory in it is looked for there alone.
fn find(arena: Allocator, path: []const u8, pathext: []const u8, program: []const u8) !?[]const u8 {
    const has_dir = std.mem.indexOfAny(u8, program, "\\/:") != null;
    if (has_dir) return tryNames(arena, null, pathext, program);
    var dirs = std.mem.tokenizeScalar(u8, path, ';');
    while (dirs.next()) |raw| {
        const dir = std.mem.trim(u8, raw, "\" ");
        if (dir.len == 0) continue;
        if (try tryNames(arena, dir, pathext, program)) |found| return found;
    }
    return null;
}

fn tryNames(arena: Allocator, dir: ?[]const u8, pathext: []const u8, program: []const u8) !?[]const u8 {
    if (std.fs.path.extension(program).len > 0) if (try existing(arena, dir, program, "")) |found| return found;
    var exts = std.mem.tokenizeScalar(u8, pathext, ';');
    while (exts.next()) |ext| if (try existing(arena, dir, program, ext)) |found| return found;
    return null;
}

fn existing(arena: Allocator, dir: ?[]const u8, program: []const u8, ext: []const u8) !?[]const u8 {
    const full = if (dir) |d|
        try std.fmt.allocPrint(arena, "{s}\\{s}{s}", .{ std.mem.trimEnd(u8, d, "\\"), program, ext })
    else
        try std.fmt.allocPrint(arena, "{s}{s}", .{ program, ext });
    const attributes = win32.GetFileAttributesW(try win32.wide(arena, full));
    if (attributes == win32.INVALID_FILE_ATTRIBUTES or attributes & win32.FILE_ATTRIBUTE_DIRECTORY != 0) return null;
    return full;
}

fn isBatch(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".cmd") or std.ascii.eqlIgnoreCase(ext, ".bat");
}

test isBatch {
    try std.testing.expect(isBatch("C:\\x\\a.CMD"));
    try std.testing.expect(isBatch("a.bat"));
    try std.testing.expect(!isBatch("a.exe"));
    try std.testing.expect(!isBatch("a.cmd.exe"));
}
