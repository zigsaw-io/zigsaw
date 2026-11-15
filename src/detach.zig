//! A zigsaw that goes on alone, for `run --detach` and `exec --detach`: the
//! zigsaw asked starts itself again with `--detached-child`, which starts the
//! app or command, says on a pipe that it has, and then waits for it with no
//! console, as a run's zigsaw always does. Everything it says before that,
//! warnings and -v's notes among it, comes on the same pipe, and the zigsaw
//! asked prints it. A child that doesn't get as far says why there, too.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const process = @import("process.zig");
const win32 = @import("win32.zig");
const note = Context.note;

/// What the child writes last, once what it waits for has started. No line
/// zigsaw prints starts with a NUL.
const marker = "\x00started\n";

pub const Started = struct {
    /// The child's PID: the number `ps` lists the run by.
    pid: u32,
    /// Whether it's out of every job this zigsaw is in. When one of them
    /// refuses, it ends as that job does (see process.Detached).
    broke_away: bool,
};

/// Starts this zigsaw again with `args`, which hold `--detached-child`, in
/// our working directory, and waits until it says it has started, or ends.
/// What it said before goes to our stderr. Fails, having printed why, if it
/// didn't start.
pub fn start(ctx: *Context, args: []const []const u8) !Started {
    const arena = ctx.arena;
    const self = try win32.selfExePath(arena);
    const command_line = try process.buildCommandLine(arena, self, args);
    const cwd = try std.process.currentPathAlloc(ctx.io, arena);
    const nul = try openNul(arena);
    // Its stdout and stderr: one pipe, so that what it says comes in order,
    // and a full stderr can't keep it from saying it started.
    var read: win32.HANDLE = undefined;
    var write: win32.HANDLE = undefined;
    if (win32.CreatePipe(&read, &write, null, 0) == 0) {
        _ = win32.CloseHandle(nul);
        return win32.lastErrorFail("CreatePipe");
    }
    defer _ = win32.CloseHandle(read);
    const started = process.startDetachedWith(arena, self, command_line, cwd, .{ nul, write, write });
    // Ours closed, its ends are its own: the pipe ends when it lets go.
    _ = win32.CloseHandle(write);
    _ = win32.CloseHandle(nul);
    const child = try started;
    defer _ = win32.CloseHandle(child.process);

    const said = try readAll(arena, read);
    if (std.mem.endsWith(u8, said, marker)) {
        Context.printStderr("{s}", .{said[0 .. said.len - marker.len]});
        return .{ .pid = child.pid, .broke_away = child.broke_away };
    }
    Context.printStderr("{s}", .{said});
    if (said.len == 0) note("error: the zigsaw that was to start it ended without saying why", .{});
    return error.Failed;
}

/// In the child, once what it waits for has started: says so on the pipe
/// `start` reads, then points its standard handles at `out` (stdout and
/// stderr: a log, or NUL) and `nul` (stdin), and lets go of the pipe, which
/// ends `start`'s wait.
pub fn tellStarted(nul: win32.HANDLE, out: win32.HANDLE) void {
    const pipe = win32.GetStdHandle(win32.STD_OUTPUT_HANDLE);
    const err = win32.GetStdHandle(win32.STD_ERROR_HANDLE);
    if (pipe) |h| {
        var written: win32.DWORD = 0;
        _ = win32.WriteFile(h, marker.ptr, marker.len, &written, null);
    }
    _ = win32.SetStdHandle(win32.STD_INPUT_HANDLE, nul);
    _ = win32.SetStdHandle(win32.STD_OUTPUT_HANDLE, out);
    _ = win32.SetStdHandle(win32.STD_ERROR_HANDLE, out);
    if (pipe) |h| _ = win32.CloseHandle(h);
    if (err) |h| if (h != pipe) {
        _ = win32.CloseHandle(h);
    };
}

pub fn openNul(arena: Allocator) !win32.HANDLE {
    const h = win32.CreateFileW(try win32.wide(arena, "NUL"), win32.GENERIC_READ | win32.GENERIC_WRITE, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE, null, win32.OPEN_EXISTING, 0, null);
    if (h == win32.INVALID_HANDLE_VALUE) return win32.lastErrorFail("CreateFileW(NUL)");
    return h;
}

fn readAll(arena: Allocator, pipe: win32.HANDLE) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        var n: win32.DWORD = 0;
        if (win32.ReadFile(pipe, &buf, buf.len, &n, null) == 0 or n == 0) break;
        try out.appendSlice(arena, buf[0..n]);
    }
    return out.items;
}
