//! zigsaw-relay.exe: carries an AppContainer run's connections across the
//! container's loopback isolation (see services.zig and forward.zig). zigsaw
//! starts it in the app's container and job:
//!
//!   zigsaw-relay [<socket>=<port>]... [forward=<in>:<out>... [use=<port>...] [proxy=<port>]]
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
//! zigsaw may give it several pairs of pipes, channels, each carrying one
//! request at a time: a connection that waits for one doesn't keep the
//! others from going on. The ready byte goes on the first.
//!
//! proxy=<port>: the run has an allow list (see hosts.zig), and holds no
//! network capability. The relay listens on <port> inside the container,
//! where HTTP_PROXY and HTTPS_PROXY have the app connect, as an HTTP proxy:
//! for a CONNECT, or a request for an http:// URL, it asks zigsaw for the
//! host and port the request names (net.proxy_request), and zigsaw decides,
//! as the app can open this process and so ask for anything itself. A
//! request for a URL goes on with the URL's path only, and as the
//! connection's only request.
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
    /// Where a proxy request says.
    proxy,
};

/// The channels to zigsaw, for forwards and proxy requests, each with the
/// lock that keeps one request at a time on it.
const max_channels = 16;
var channels: [max_channels]Channel = undefined;
var channel_count: usize = 0;

const Channel = struct { pipes: Pipes, lock: win32.SRWLOCK = .{} };
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
        .forward => |p| {
            if (channel_count == max_channels) win32.ExitProcess(2);
            channels[channel_count] = .{ .pipes = p };
            channel_count += 1;
        },
        .proxy => |port| {
            if (channel_count == 0) win32.ExitProcess(2);
            for ([_]net.Family{ .ipv4, .ipv6 }) |family| switch (net.listen(.loopback(family, port))) {
                .socket => |s| {
                    listen(s, .proxy);
                    listeners += 1;
                },
                .failed => {},
            };
        },
        .use => |port| {
            // The last index is a proxy request's.
            if (channel_count == 0 or uses == net.proxy_request) win32.ExitProcess(2);
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
    // zigsaw starts the app once the relay listens for its forwards and
    // its proxy.
    if (channel_count > 0) if (!writeAll(channels[0].pipes.out, &.{0})) win32.ExitProcess(1);
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
        .forward => |index| askZigsaw(&.{index}),
        .proxy => return proxied(client),
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

/// A connection zigsaw made for `request` (a forward's index, or a proxy
/// request), or null if it couldn't.
fn askZigsaw(request: []const u8) ?SOCKET {
    return switch (ask(request)) {
        .socket => |s| s,
        .status => null,
    };
}

const Answer = union(enum) { socket: SOCKET, status: net.ProxyStatus };

fn ask(request: []const u8) Answer {
    const channel = take() orelse return .{ .status = .failed };
    defer win32.ReleaseSRWLockExclusive(&channel.lock);
    const pipes = channel.pipes;
    if (!writeAll(pipes.out, request)) return .{ .status = .failed };
    var status: [1]u8 = undefined;
    if (!readAll(pipes.in, &status)) return .{ .status = .failed };
    if (status[0] != 0) return .{ .status = @enumFromInt(status[0]) };
    var info: win32.WSAPROTOCOL_INFOW = undefined;
    if (!readAll(pipes.in, std.mem.asBytes(&info))) return .{ .status = .failed };
    const s = win32.WSASocketW(win32.FROM_PROTOCOL_INFO, win32.FROM_PROTOCOL_INFO, win32.FROM_PROTOCOL_INFO, &info, 0, win32.WSA_FLAG_OVERLAPPED);
    // zigsaw keeps its own until this one is open.
    _ = writeAll(pipes.out, &.{1});
    return if (s == win32.INVALID_SOCKET) .{ .status = .failed } else .{ .socket = s };
}

/// A channel no other request holds, which the caller releases; null if
/// there are none.
fn take() ?*Channel {
    if (channel_count == 0) return null;
    while (true) {
        for (channels[0..channel_count]) |*c| if (win32.TryAcquireSRWLockExclusive(&c.lock) != 0) return c;
        win32.Sleep(5);
    }
}

// ---------------------------------------------------------------------------
// The proxy

const head_max = 8192;

/// One connection to the proxy: a request, and then what it carries.
fn proxied(client: SOCKET) void {
    var buf: [head_max]u8 = undefined;
    // A client that sends no request in a while doesn't keep a thread.
    setReceiveTimeout(client, 30_000);
    const got = readHead(client, &buf) orelse return respond(client, .bad_request, "", 0);
    const req = parseRequest(buf[0..got.head]) orelse return respond(client, .bad_request, "", 0);
    if (req.host.len > 255) return respond(client, .bad_request, "", 0);
    var ask_buf: [4 + 255]u8 = undefined;
    ask_buf[0] = net.proxy_request;
    ask_buf[1] = @intCast(req.host.len);
    @memcpy(ask_buf[2..][0..req.host.len], req.host);
    std.mem.writeInt(u16, ask_buf[2 + req.host.len ..][0..2], req.port, .little);
    const upstream = switch (ask(ask_buf[0 .. 4 + req.host.len])) {
        .socket => |s| s,
        .status => |status| return respond(client, switch (status) {
            .refused => .forbidden,
            .timed_out => .gateway_timeout,
            else => .bad_gateway,
        }, req.host, req.port),
    };
    defer _ = win32.closesocket(upstream);
    setReceiveTimeout(client, 0);
    if (req.connect) {
        if (!net.sendAll(client, "HTTP/1.1 200 Connection established\r\n\r\n")) return;
    } else {
        var out: [head_max + 64]u8 = undefined;
        const head = rewriteHead(&out, buf[0..got.head], req) orelse return;
        if (!net.sendAll(upstream, head)) return;
    }
    // What came after the head: a request's body, or the start of TLS.
    if (got.len > got.head and !net.sendAll(upstream, buf[got.head..got.len])) return;
    const back = std.Thread.spawn(.{ .stack_size = stack_size }, pump, .{ upstream, client }) catch return;
    pump(client, upstream);
    back.join();
}

fn setReceiveTimeout(s: SOCKET, ms: win32.DWORD) void {
    _ = win32.setsockopt(s, win32.SOL_SOCKET, win32.SO_RCVTIMEO, &ms, @sizeOf(win32.DWORD));
}

const Head = struct { head: usize, len: usize };

/// Reads until the end of a request's head: its length, and how much came.
fn readHead(s: SOCKET, buf: *[head_max]u8) ?Head {
    var len: usize = 0;
    while (len < buf.len) {
        const n = win32.recv(s, buf[len..].ptr, @intCast(buf.len - len), 0);
        if (n <= 0) return null;
        const from = len -| 3;
        len += @intCast(n);
        if (std.mem.indexOfPos(u8, buf[0..len], from, "\r\n\r\n")) |end| return .{ .head = end + 4, .len = len };
    }
    return null;
}

const Request = struct {
    connect: bool,
    /// As the request names it: a name or an address, with brackets for
    /// IPv6.
    host: []const u8,
    port: u16,
    method: []const u8 = "",
    /// For a URL: its path and query, "/" if it has none.
    path: []const u8 = "",
    version: []const u8 = "",
};

/// The request line of `head`: a CONNECT to host:port, or any method for an
/// http:// URL; null for anything else.
fn parseRequest(head: []const u8) ?Request {
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse return null;
    var parts = std.mem.splitScalar(u8, head[0..line_end], ' ');
    const method = parts.next() orelse return null;
    const target = parts.next() orelse return null;
    const version = parts.next() orelse return null;
    if (parts.next() != null or method.len == 0 or !std.mem.startsWith(u8, version, "HTTP/1.")) return null;
    if (std.mem.eql(u8, method, "CONNECT")) {
        const a = parseAuthority(target, null) orelse return null;
        return .{ .connect = true, .host = a.host, .port = a.port };
    }
    const scheme = "http://";
    if (target.len <= scheme.len or !std.ascii.eqlIgnoreCase(target[0..scheme.len], scheme)) return null;
    const rest = target[scheme.len..];
    const path_at = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    const a = parseAuthority(rest[0..path_at], 80) orelse return null;
    if (path_at < rest.len and rest[path_at] == '?') return null;
    const path = if (path_at == rest.len) "/" else rest[path_at..];
    return .{ .connect = false, .host = a.host, .port = a.port, .method = method, .path = path, .version = version };
}

const Authority = struct { host: []const u8, port: u16 };

/// "host:port", "[v6]:port", or without the port where `default` is one.
fn parseAuthority(text: []const u8, default: ?u16) ?Authority {
    if (text.len == 0 or std.mem.indexOfScalar(u8, text, '@') != null) return null;
    var host = text;
    var port_text: ?[]const u8 = null;
    if (text[0] == '[') {
        const close = std.mem.indexOfScalar(u8, text, ']') orelse return null;
        host = text[0 .. close + 1];
        const after = text[close + 1 ..];
        if (after.len > 0) {
            if (after[0] != ':') return null;
            port_text = after[1..];
        }
    } else if (std.mem.lastIndexOfScalar(u8, text, ':')) |colon| {
        host = text[0..colon];
        port_text = text[colon + 1 ..];
    }
    if (host.len == 0) return null;
    const port: u16 = if (port_text) |t| (portOf(t) orelse return null) else default orelse return null;
    return .{ .host = host, .port = port };
}

fn portOf(digits: []const u8) ?u16 {
    if (digits.len == 0 or digits.len > 5) return null;
    var n: u32 = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
    }
    return if (n == 0 or n > std.math.maxInt(u16)) null else @intCast(n);
}

/// The head a request for a URL goes on with: its path only, without the
/// headers meant for a proxy or for keeping the connection, and with
/// `Connection: close`, as the relay carries one request per connection.
fn rewriteHead(out: []u8, head: []const u8, req: Request) ?[]const u8 {
    var w: std.Io.Writer = .fixed(out);
    w.print("{s} {s} {s}\r\n", .{ req.method, req.path, req.version }) catch return null;
    const first_end = std.mem.indexOf(u8, head, "\r\n") orelse return null;
    var lines = std.mem.splitSequence(u8, head[first_end + 2 ..], "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const dropped = for ([_][]const u8{ "proxy-connection", "proxy-authorization", "connection", "keep-alive" }) |d| {
            if (std.ascii.eqlIgnoreCase(name, d)) break true;
        } else false;
        if (dropped) continue;
        w.print("{s}\r\n", .{line}) catch return null;
    }
    w.writeAll("Connection: close\r\n\r\n") catch return null;
    return w.buffered();
}

const Response = enum { bad_request, forbidden, bad_gateway, gateway_timeout };

/// An answer from the proxy itself, which ends the connection.
fn respond(client: SOCKET, r: Response, host: []const u8, port: u16) void {
    var body_buf: [512]u8 = undefined;
    const status: []const u8, const body: []const u8 = switch (r) {
        .bad_request => .{ "400 Bad Request", "zigsaw's proxy takes a CONNECT, or a request for an http:// URL\n" },
        .forbidden => .{ "403 Forbidden", std.fmt.bufPrint(&body_buf, "zigsaw: this app's allow list doesn't let it reach {s}:{d}; --allow-host lets a run reach a host\n", .{ host, port }) catch "" },
        .bad_gateway => .{ "502 Bad Gateway", std.fmt.bufPrint(&body_buf, "zigsaw couldn't connect to {s}:{d}\n", .{ host, port }) catch "" },
        .gateway_timeout => .{ "504 Gateway Timeout", std.fmt.bufPrint(&body_buf, "zigsaw's connection to {s}:{d} timed out\n", .{ host, port }) catch "" },
    };
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "HTTP/1.1 {s}\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, body.len, body }) catch return;
    _ = net.sendAll(client, msg);
    _ = win32.shutdown(client, win32.SD_SEND);
    // Let the answer go before the socket closes.
    var drain: [256]u8 = undefined;
    setReceiveTimeout(client, 2000);
    while (win32.recv(client, &drain, drain.len, 0) > 0) {}
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
    proxy: u16,
};

/// "<socket>=<port>", "forward=<in>:<out>", "use=<port>" or "proxy=<port>",
/// all decimal.
fn parse(arg: []const u16) ?Arg {
    const eq = std.mem.indexOfScalar(u16, arg, '=') orelse return null;
    const key = arg[0..eq];
    const value = arg[eq + 1 ..];
    if (std.mem.eql(u16, key, std.unicode.utf8ToUtf16LeStringLiteral("use"))) {
        const port = parseDecimal(u16, value) orelse return null;
        return if (port == 0) null else .{ .use = port };
    }
    if (std.mem.eql(u16, key, std.unicode.utf8ToUtf16LeStringLiteral("proxy"))) {
        const port = parseDecimal(u16, value) orelse return null;
        return if (port == 0) null else .{ .proxy = port };
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
    for ([_][]const u8{ "1=0", "1=65536", "=5", "x=5", "5", "use=0", "use=x", "forward=1", "forward=0:1", "forward=1:", "proxy=0", "proxy=x" }) |bad| {
        var w: [16]u16 = undefined;
        const n = try std.unicode.utf8ToUtf16Le(&w, bad);
        try std.testing.expectEqual(null, parse(w[0..n]));
    }
}

test parseRequest {
    const t = std.testing;
    const c = parseRequest("CONNECT api.github.com:443 HTTP/1.1\r\nHost: api.github.com:443\r\n\r\n").?;
    try t.expect(c.connect);
    try t.expectEqualStrings("api.github.com", c.host);
    try t.expectEqual(@as(u16, 443), c.port);
    const v6 = parseRequest("CONNECT [2001:db8::7]:8443 HTTP/1.1\r\n\r\n").?;
    try t.expectEqualStrings("[2001:db8::7]", v6.host);
    try t.expectEqual(@as(u16, 8443), v6.port);
    const g = parseRequest("GET http://example.org/a/b?c=d HTTP/1.1\r\nHost: example.org\r\n\r\n").?;
    try t.expect(!g.connect);
    try t.expectEqualStrings("example.org", g.host);
    try t.expectEqual(@as(u16, 80), g.port);
    try t.expectEqualStrings("/a/b?c=d", g.path);
    const bare = parseRequest("POST HTTP://Example.org:8080 HTTP/1.0\r\n\r\n").?;
    try t.expectEqualStrings("Example.org", bare.host);
    try t.expectEqual(@as(u16, 8080), bare.port);
    try t.expectEqualStrings("/", bare.path);
    for ([_][]const u8{
        "GET / HTTP/1.1\r\n\r\n",
        "CONNECT example.org HTTP/1.1\r\n\r\n",
        "CONNECT example.org:0 HTTP/1.1\r\n\r\n",
        "CONNECT example.org:443 HTTP/2\r\n\r\n",
        "GET https://example.org/ HTTP/1.1\r\n\r\n",
        "GET http://user@example.org/ HTTP/1.1\r\n\r\n",
        "GET http:///x HTTP/1.1\r\n\r\n",
        "GET http://example.org/ HTTP/1.1 x\r\n\r\n",
        "CONNECT [::1 HTTP/1.1\r\n\r\n",
        "GET http://example.org?q HTTP/1.1\r\n\r\n",
        "CONNECT example.org:99999 HTTP/1.1\r\n\r\n",
    }) |bad| if (parseRequest(bad) != null) {
        std.debug.print("parsed: {s}\n", .{bad});
        return error.TestUnexpectedResult;
    };
}

test rewriteHead {
    const head = "GET http://example.org/x HTTP/1.1\r\nHost: example.org\r\nProxy-Connection: keep-alive\r\nconnection: keep-alive\r\nKeep-Alive: 5\r\nProxy-Authorization: Basic eA==\r\nAccept: */*\r\n\r\n";
    var out: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "GET /x HTTP/1.1\r\nHost: example.org\r\nAccept: */*\r\nConnection: close\r\n\r\n",
        rewriteHead(&out, head, parseRequest(head).?).?,
    );
}
