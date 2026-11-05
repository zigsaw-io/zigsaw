//! A proxy in front of a registry that resets a connection part way through a
//! response, as a network does: the peer gets WSAECONNRESET, not a clean end.
//! It's what tests/registry.sh breaks real downloads with, as a simulated break
//! doesn't reach the code that reads the connection's error.
//!
//!   zig build-exe tests/resetproxy.zig
//!   zigsaw-resetproxy <port> <upstream port> <path part> <bytes>
//!
//! It listens on 127.0.0.1:<port> and takes one request at a time, and ends only
//! when it's killed. The first GET whose path has <path part> in it, with a longer
//! response than <bytes>, gets <bytes> of the body, and then the reset. Everything
//! else goes through. Requests have no bodies, which is enough for pulling.
//!
//!   zigsaw-resetproxy <port> <upstream port> <path part> 0 --answer-500
//!
//! Instead answers each GET whose path has <path part> in it with a 500, as a
//! registry having a bad day does (tests/signing.sh).

const std = @import("std");

const Socket = usize;
const invalid_socket = ~@as(Socket, 0);

const SockaddrIn = extern struct {
    family: u16 = 2, // AF_INET
    port: u16,
    addr: u32 = 0x0100007f, // 127.0.0.1
    zero: [8]u8 = @splat(0),
};
const Linger = extern struct { onoff: u16, seconds: u16 };

extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) c_int;
extern "ws2_32" fn socket(af: c_int, kind: c_int, protocol: c_int) callconv(.winapi) Socket;
extern "ws2_32" fn bind(s: Socket, addr: *const SockaddrIn, len: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn listen(s: Socket, backlog: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn accept(s: Socket, addr: ?*anyopaque, len: ?*c_int) callconv(.winapi) Socket;
extern "ws2_32" fn connect(s: Socket, addr: *const SockaddrIn, len: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn recv(s: Socket, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn send(s: Socket, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn setsockopt(s: Socket, level: c_int, name: c_int, value: *const Linger, len: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn closesocket(s: Socket) callconv(.winapi) c_int;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

var answer_500 = false;

const sock_stream = 1;
const sol_socket = 0xffff;
const so_linger = 0x0080;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5 and !(args.len == 6 and std.mem.eql(u8, args[5], "--answer-500"))) {
        std.log.err("usage: resetproxy <port> <upstream port> <path part> <bytes> [--answer-500]", .{});
        std.process.exit(2);
    }
    answer_500 = args.len == 6;
    const port = try std.fmt.parseInt(u16, args[1], 10);
    const upstream = try std.fmt.parseInt(u16, args[2], 10);
    const part: []const u8 = args[3];
    const bytes = try std.fmt.parseInt(u64, args[4], 10);

    var wsa: [512]u8 = undefined;
    if (WSAStartup(0x0202, &wsa) != 0) return error.WinsockUnavailable;
    const listener = socket(2, sock_stream, 0);
    if (listener == invalid_socket) return error.NoSocket;
    const here: SockaddrIn = .{ .port = std.mem.nativeToBig(u16, port) };
    if (bind(listener, &here, @sizeOf(SockaddrIn)) != 0) return error.NoBind;
    if (listen(listener, 16) != 0) return error.NoListen;

    var reset_done = false;
    while (true) {
        const client = accept(listener, null, null);
        if (client == invalid_socket) continue;
        // One failed exchange is only that one's: a client that goes away, say.
        reset_done = serve(client, upstream, part, bytes, reset_done) catch reset_done;
    }
}

/// Answers one request, and closes `client`, by a reset if this is the one.
/// Returns whether the reset has been done, by now.
fn serve(client: Socket, upstream: u16, part: []const u8, bytes: u64, reset_done: bool) !bool {
    defer _ = closesocket(client);

    var request_buf: [64 * 1024]u8 = undefined;
    const request = request_buf[0..try readHead(client, &request_buf)];
    const line = request[0 .. std.mem.indexOf(u8, request, "\r\n") orelse return error.BadRequest];

    if (answer_500 and std.mem.startsWith(u8, line, "GET ") and std.mem.indexOf(u8, line, part) != null) {
        try sendAll(client, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return reset_done;
    }

    const server = socket(2, sock_stream, 0);
    if (server == invalid_socket) return error.NoSocket;
    defer _ = closesocket(server);
    const there: SockaddrIn = .{ .port = std.mem.nativeToBig(u16, upstream) };
    if (connect(server, &there, @sizeOf(SockaddrIn)) != 0) return error.NoUpstream;
    try sendAll(server, request);

    var head_buf: [64 * 1024]u8 = undefined;
    const got = try readHead(server, &head_buf);
    const head_end = (std.mem.indexOf(u8, head_buf[0..got], "\r\n\r\n") orelse return error.BadResponse) + 4;
    const head = head_buf[0..head_end];
    const status_end = std.mem.indexOf(u8, head, "\r\n") orelse return error.BadResponse;

    // Each connection takes one request, which the client has to be told.
    try sendAll(client, head[0 .. status_end + 2]);
    try sendAll(client, "Connection: close\r\n");
    try sendAll(client, head[status_end + 2..]);

    const is_head = std.mem.startsWith(u8, line, "HEAD ");
    const length = contentLength(head);
    const hit = !reset_done and std.mem.startsWith(u8, line, "GET ") and
        std.mem.indexOf(u8, line, part) != null and (length orelse 0) > bytes;

    var sent: u64 = 0;
    var body = head_buf[head_end..got];
    while (!is_head) {
        if (length) |n| if (sent >= n) break;
        if (body.len == 0) {
            const n = recv(server, &head_buf, head_buf.len, 0);
            if (n <= 0) break;
            body = head_buf[0..@intCast(n)];
        }
        var take: usize = body.len;
        if (hit) take = @min(take, bytes - sent);
        try sendAll(client, body[0..take]);
        sent += take;
        body = body[take..];
        if (hit and sent == bytes) {
            // Time to read what it was sent: a reset can throw away what's still
            // waiting to be. No linger is what makes closing it a reset.
            Sleep(500);
            const abort: Linger = .{ .onoff = 1, .seconds = 0 };
            _ = setsockopt(client, sol_socket, so_linger, &abort, @sizeOf(Linger));
            return true;
        }
    }
    return reset_done;
}

/// Reads until the buffer holds a whole head, and maybe some of what follows.
fn readHead(s: Socket, buf: []u8) !usize {
    var got: usize = 0;
    while (std.mem.indexOf(u8, buf[0..got], "\r\n\r\n") == null) {
        if (got == buf.len) return error.HeadTooLong;
        const n = recv(s, buf[got..].ptr, @intCast(buf.len - got), 0);
        if (n <= 0) return error.Closed;
        got += @intCast(n);
    }
    return got;
}

fn sendAll(s: Socket, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = send(s, rest.ptr, @intCast(rest.len), 0);
        if (n <= 0) return error.Closed;
        rest = rest[@intCast(n)..];
    }
}

fn contentLength(head: []const u8) ?u64 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) continue;
        return std.fmt.parseInt(u64, std.mem.trim(u8, line[colon + 1 ..], " "), 10) catch null;
    }
    return null;
}
