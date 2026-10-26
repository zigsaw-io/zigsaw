//! zigsaw-relay.exe: publishes an app's services from inside its
//! AppContainer (see services.zig). A serving run listens on the services'
//! ports outside the container, where programs on this machine can reach
//! them, and starts the relay in the app's container and job, with those
//! sockets:
//!
//!   zigsaw-relay <socket>=<port> ...
//!
//! For each connection a socket accepts, the relay connects to the app on
//! <port>, its internal port, on 127.0.0.1 or ::1, as runs in one container
//! may, and copies bytes both ways until both sides are done. It needs no
//! network capability, and zigsaw takes no part once it has started it. It
//! ends with the run's job.
//!
//! It has no console and nothing to report to: a connection it can't pass
//! on is closed, as a refused one would be.

const std = @import("std");
const win32 = @import("win32.zig");
const net = @import("net.zig");

const SOCKET = win32.SOCKET;

// Small, as the shim is: no std.Io, and no stack traces.
pub const panic = std.debug.simple_panic;
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .logFn = log,
};

fn log(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}

const stack_size = 64 * 1024;

pub fn main() void {
    net.startup() catch win32.ExitProcess(1);
    var listeners: usize = 0;
    var it: Arguments = .{ .line = std.mem.span(win32.GetCommandLineW()) };
    it.skipProgram();
    while (it.next()) |arg| {
        const pair = parsePair(arg) orelse win32.ExitProcess(2);
        const thread = std.Thread.spawn(.{ .stack_size = stack_size }, acceptLoop, .{ pair.socket, pair.port }) catch
            win32.ExitProcess(1);
        thread.detach();
        listeners += 1;
    }
    if (listeners == 0) win32.ExitProcess(2);
    // The accepting threads run until the job ends.
    while (true) win32.Sleep(win32.INFINITE);
}

fn acceptLoop(listener: SOCKET, port: u16) void {
    while (true) {
        const client = win32.accept(listener, null, null);
        if (client == win32.INVALID_SOCKET) {
            // Out of resources, say: try again in a while.
            win32.Sleep(100);
            continue;
        }
        const thread = std.Thread.spawn(.{ .stack_size = stack_size }, relay, .{ client, port }) catch {
            _ = win32.closesocket(client);
            continue;
        };
        thread.detach();
    }
}

/// Passes one connection on to the app, which may still be starting.
fn relay(client: SOCKET, port: u16) void {
    defer _ = win32.closesocket(client);
    const app = connectApp(port) orelse return;
    defer _ = win32.closesocket(app);
    const back = std.Thread.spawn(.{ .stack_size = stack_size }, pump, .{ app, client }) catch return;
    pump(client, app);
    back.join();
}

/// The app's end of a connection: on 127.0.0.1, or on ::1 for an app that
/// listens only there. Tried for about two seconds.
fn connectApp(port: u16) ?SOCKET {
    for (0..20) |_| {
        for ([_]net.Family{ .ipv4, .ipv6 }) |family| switch (net.connect(.loopback(family, port), 1000)) {
            .socket => |s| return s,
            .failed => {},
        };
        win32.Sleep(100);
    }
    return null;
}

/// Copies what `from` receives to `to`. At the end of `from`'s data, `to`
/// gets the end too; if either side fails, so does the other.
fn pump(from: SOCKET, to: SOCKET) void {
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = win32.recv(from, &buf, buf.len, 0);
        if (n == 0) {
            _ = win32.shutdown(to, win32.SD_SEND);
            return;
        }
        if (n < 0 or !net.sendAll(to, buf[0..@intCast(n)])) {
            _ = win32.shutdown(from, win32.SD_BOTH);
            _ = win32.shutdown(to, win32.SD_BOTH);
            return;
        }
    }
}

const Pair = struct { socket: SOCKET, port: u16 };

/// "<socket>=<port>", both decimal.
fn parsePair(arg: []const u16) ?Pair {
    const eq = std.mem.indexOfScalar(u16, arg, '=') orelse return null;
    const socket = parseDecimal(SOCKET, arg[0..eq]) orelse return null;
    const port = parseDecimal(u16, arg[eq + 1 ..]) orelse return null;
    if (port == 0) return null;
    return .{ .socket = socket, .port = port };
}

fn parseDecimal(comptime T: type, digits: []const u16) ?T {
    if (digits.len == 0) return null;
    var n: T = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return null;
        n = std.math.mul(T, n, 10) catch return null;
        n = std.math.add(T, n, @intCast(c - '0')) catch return null;
    }
    return n;
}

/// The relay's own arguments, which zigsaw writes: words without quotes or
/// spaces, after the program's path, which may be quoted.
const Arguments = struct {
    line: []const u16,
    i: usize = 0,

    fn skipProgram(a: *Arguments) void {
        if (a.line.len > 0 and a.line[0] == '"') {
            a.i = 1;
            while (a.i < a.line.len and a.line[a.i] != '"') a.i += 1;
            a.i += 1;
        }
        while (a.i < a.line.len and a.line[a.i] != ' ' and a.line[a.i] != '\t') a.i += 1;
    }

    fn next(a: *Arguments) ?[]const u16 {
        while (a.i < a.line.len and (a.line[a.i] == ' ' or a.line[a.i] == '\t')) a.i += 1;
        if (a.i >= a.line.len) return null;
        const start = a.i;
        while (a.i < a.line.len and a.line[a.i] != ' ' and a.line[a.i] != '\t') a.i += 1;
        return a.line[start..a.i];
    }
};

test Arguments {
    const line = std.unicode.utf8ToUtf16LeStringLiteral("\"D:\\zigsaw store\\relay\\zigsaw-relay.exe\" 412=23817  508=23817");
    var it: Arguments = .{ .line = line };
    it.skipProgram();
    const first = parsePair(it.next().?).?;
    try std.testing.expectEqual(@as(SOCKET, 412), first.socket);
    try std.testing.expectEqual(@as(u16, 23817), first.port);
    try std.testing.expectEqual(@as(SOCKET, 508), parsePair(it.next().?).?.socket);
    try std.testing.expectEqual(null, it.next());

    var bare: Arguments = .{ .line = std.unicode.utf8ToUtf16LeStringLiteral("relay.exe 1=2") };
    bare.skipProgram();
    try std.testing.expectEqual(@as(u16, 2), parsePair(bare.next().?).?.port);
    for ([_][]const u8{ "1=0", "1=65536", "=5", "x=5", "5" }) |bad| {
        var w: [16]u16 = undefined;
        const n = try std.unicode.utf8ToUtf16Le(&w, bad);
        try std.testing.expectEqual(null, parsePair(w[0..n]));
    }
}
