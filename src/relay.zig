//! zigsaw-relay.exe: carries an AppContainer run's connections across the
//! container's loopback isolation (see services.zig and forward.zig). zigsaw
//! starts it in the app's container and job:
//!
//!   zigsaw-relay [<socket>=<port>]... [forward=<in>:<out> use=<port>...]
//!
//! <socket>=<port>: a service the run publishes. zigsaw listens on its port
//! outside the container, where programs on this machine can reach it, and
//! hands the relay that socket. For each connection it accepts, the relay
//! connects to the app on <port>, its internal port, on 127.0.0.1 or ::1, as
//! runs in one container may.
//!
//! use=<port>: a port the run uses, which zigsaw forwards. The relay listens
//! on <port> itself, inside the container, on 127.0.0.1 and ::1, where the
//! app connects (${uses:<name>}), and then writes a byte to <out>: zigsaw
//! starts the app after the relay. For each connection it accepts, it asks
//! zigsaw over the pipes <in> and <out> (handles it inherits) for a
//! connection to the port the app uses: it writes the use's index, in the
//! order of the arguments, and reads a status byte, 0 for a connection, and
//! then the connection zigsaw made outside the container and duplicated into
//! this process (a WSAPROTOCOL_INFOW), which it acknowledges with a byte.
//!
//! Either way, it then copies bytes both ways until both sides are done. It
//! needs no network capability, and ends with the run's job.
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

/// Where a connection the relay accepts goes.
const Upstream = union(enum) {
    /// The app, on its internal port for a service.
    app: u16,
    /// What zigsaw connects to for the use of this index.
    forward: u8,
};

/// The pipes to zigsaw, for forwards, and the lock that keeps one request
/// at a time on them.
var zigsaw: ?Pipes = null;
var zigsaw_lock: win32.SRWLOCK = .{};

const Pipes = struct { in: win32.HANDLE, out: win32.HANDLE };

pub fn main() void {
    net.startup() catch win32.ExitProcess(1);
    var listeners: usize = 0;
    var uses: u8 = 0;
    var it: Arguments = .{ .line = std.mem.span(win32.GetCommandLineW()) };
    it.skipProgram();
    while (it.next()) |arg| switch (parse(arg) orelse win32.ExitProcess(2)) {
        .service => |s| {
            listen(s.socket, .{ .app = s.port });
            listeners += 1;
        },
        .forward => |p| zigsaw = p,
        .use => |port| {
            if (zigsaw == null or uses == std.math.maxInt(u8)) win32.ExitProcess(2);
            // Its own sockets: one zigsaw made would be outside the
            // container, where the app can't connect.
            for ([_]net.Family{ .ipv4, .ipv6 }) |family| switch (net.listen(.loopback(family, port))) {
                .socket => |s| {
                    listen(s, .{ .forward = uses });
                    listeners += 1;
                },
                // A machine without IPv6 has no ::1; a port that's taken
                // leaves that use unforwarded.
                .failed => {},
            };
            uses += 1;
        },
    };
    if (listeners == 0) win32.ExitProcess(2);
    // zigsaw starts the app once the relay listens for its forwards.
    if (zigsaw) |pipes| if (!writeAll(pipes.out, &.{0})) win32.ExitProcess(1);
    // The accepting threads run until the job ends.
    while (true) win32.Sleep(win32.INFINITE);
}

fn listen(listener: SOCKET, upstream: Upstream) void {
    const thread = std.Thread.spawn(.{ .stack_size = stack_size }, acceptLoop, .{ listener, upstream }) catch
        win32.ExitProcess(1);
    thread.detach();
}

fn acceptLoop(listener: SOCKET, upstream: Upstream) void {
    while (true) {
        const client = win32.accept(listener, null, null);
        if (client == win32.INVALID_SOCKET) {
            // Out of resources, say: try again in a while.
            win32.Sleep(100);
            continue;
        }
        const thread = std.Thread.spawn(.{ .stack_size = stack_size }, relay, .{ client, upstream }) catch {
            _ = win32.closesocket(client);
            continue;
        };
        thread.detach();
    }
}

/// Passes one connection on.
fn relay(client: SOCKET, upstream: Upstream) void {
    defer _ = win32.closesocket(client);
    const other = switch (upstream) {
        .app => |port| connectApp(port),
        .forward => |index| askZigsaw(index),
    } orelse return;
    defer _ = win32.closesocket(other);
    const back = std.Thread.spawn(.{ .stack_size = stack_size }, pump, .{ other, client }) catch return;
    pump(client, other);
    back.join();
}

/// The app's end of a connection: on 127.0.0.1, or on ::1 for an app that
/// listens only there. Tried for about two seconds, while the app starts.
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

/// A connection zigsaw made for the use of `index`, or null if it couldn't.
fn askZigsaw(index: u8) ?SOCKET {
    const pipes = zigsaw orelse return null;
    win32.AcquireSRWLockExclusive(&zigsaw_lock);
    defer win32.ReleaseSRWLockExclusive(&zigsaw_lock);
    if (!writeAll(pipes.out, &.{index})) return null;
    var status: [1]u8 = undefined;
    if (!readAll(pipes.in, &status) or status[0] != 0) return null;
    var info: win32.WSAPROTOCOL_INFOW = undefined;
    if (!readAll(pipes.in, std.mem.asBytes(&info))) return null;
    const s = win32.WSASocketW(win32.FROM_PROTOCOL_INFO, win32.FROM_PROTOCOL_INFO, win32.FROM_PROTOCOL_INFO, &info, 0, win32.WSA_FLAG_OVERLAPPED);
    // zigsaw keeps its own until this one is open.
    _ = writeAll(pipes.out, &.{1});
    return if (s == win32.INVALID_SOCKET) null else s;
}

fn readAll(h: win32.HANDLE, buf: []u8) bool {
    var got: usize = 0;
    while (got < buf.len) {
        var n: win32.DWORD = 0;
        if (win32.ReadFile(h, buf[got..].ptr, @intCast(buf.len - got), &n, null) == 0 or n == 0) return false;
        got += n;
    }
    return true;
}

fn writeAll(h: win32.HANDLE, bytes: []const u8) bool {
    var sent: usize = 0;
    while (sent < bytes.len) {
        var n: win32.DWORD = 0;
        if (win32.WriteFile(h, bytes[sent..].ptr, @intCast(bytes.len - sent), &n, null) == 0) return false;
        sent += n;
    }
    return true;
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

const Arg = union(enum) {
    service: struct { socket: SOCKET, port: u16 },
    forward: Pipes,
    use: u16,
};

/// "<socket>=<port>", "forward=<in>:<out>" or "use=<port>", all decimal.
fn parse(arg: []const u16) ?Arg {
    const eq = std.mem.indexOfScalar(u16, arg, '=') orelse return null;
    const key = arg[0..eq];
    const value = arg[eq + 1 ..];
    if (std.mem.eql(u16, key, std.unicode.utf8ToUtf16LeStringLiteral("use"))) {
        const port = parseDecimal(u16, value) orelse return null;
        return if (port == 0) null else .{ .use = port };
    }
    if (std.mem.eql(u16, key, std.unicode.utf8ToUtf16LeStringLiteral("forward"))) {
        const colon = std.mem.indexOfScalar(u16, value, ':') orelse return null;
        const in = parseDecimal(usize, value[0..colon]) orelse return null;
        const out = parseDecimal(usize, value[colon + 1 ..]) orelse return null;
        if (in == 0 or out == 0) return null;
        return .{ .forward = .{ .in = @ptrFromInt(in), .out = @ptrFromInt(out) } };
    }
    const socket = parseDecimal(SOCKET, key) orelse return null;
    const port = parseDecimal(u16, value) orelse return null;
    if (port == 0) return null;
    return .{ .service = .{ .socket = socket, .port = port } };
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
    const line = std.unicode.utf8ToUtf16LeStringLiteral("\"D:\\zigsaw store\\relay\\zigsaw-relay.exe\" 412=23817  508=23817 forward=600:604 use=31000");
    var it: Arguments = .{ .line = line };
    it.skipProgram();
    const first = parse(it.next().?).?.service;
    try std.testing.expectEqual(@as(SOCKET, 412), first.socket);
    try std.testing.expectEqual(@as(u16, 23817), first.port);
    try std.testing.expectEqual(@as(SOCKET, 508), parse(it.next().?).?.service.socket);
    const pipes = parse(it.next().?).?.forward;
    try std.testing.expectEqual(@as(usize, 600), @intFromPtr(pipes.in));
    try std.testing.expectEqual(@as(usize, 604), @intFromPtr(pipes.out));
    try std.testing.expectEqual(@as(u16, 31000), parse(it.next().?).?.use);
    try std.testing.expectEqual(null, it.next());

    var bare: Arguments = .{ .line = std.unicode.utf8ToUtf16LeStringLiteral("relay.exe 1=2") };
    bare.skipProgram();
    try std.testing.expectEqual(@as(u16, 2), parse(bare.next().?).?.service.port);
    for ([_][]const u8{ "1=0", "1=65536", "=5", "x=5", "5", "use=0", "use=x", "forward=1", "forward=0:1", "forward=1:" }) |bad| {
        var w: [16]u16 = undefined;
        const n = try std.unicode.utf8ToUtf16Le(&w, bad);
        try std.testing.expectEqual(null, parse(w[0..n]));
    }
}
