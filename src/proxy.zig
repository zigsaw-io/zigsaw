//! zigsaw's side of a run's allow list (see hosts.zig): the relay in the
//! run's container is an HTTP proxy, and for each request it asks zigsaw for
//! a connection to the host and port the request names (see forward.zig).
//! The relay can't decide: the app can open it, as any process in its
//! container, and so ask for anything itself. zigsaw does:
//!
//! - It connects only to what the list allows.
//! - A name that resolves to this machine (loopback, an unspecified or a
//!   link-local address) is refused: a run reaches this machine only at an
//!   address its list names, or on the ports it uses (services.zig). DNS
//!   can't point a listed name here.
//! - With your proxy set (HTTPS_PROXY, HTTP_PROXY or ALL_PROXY, which zigsaw's
//!   own requests honour too), it asks that proxy for a tunnel (CONNECT),
//!   unless NO_PROXY names the host, and the proxy resolves the name. Only
//!   Basic authentication, from the URL's user and password, which stay in
//!   zigsaw: the relay, in the app's container, never sees them.
//!
//! It keeps what it refused, which the run says when it ends.

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");
const net = @import("net.zig");
const hosts = @import("hosts.zig");
const note = @import("Context.zig").note;

const SOCKET = win32.SOCKET;

/// How long one address may take to answer.
const connect_ms = 5000;

pub const Outcome = union(enum) { socket: SOCKET, status: net.ProxyStatus };

pub const Proxy = struct {
    id: []const u8,
    list: []const []const u8,
    verbose: bool,
    upstream: ?Upstream = null,
    lock: win32.SRWLOCK = .{},
    refusals: [max_refusals]Refusal = undefined,
    refusal_count: usize = 0,
    /// Refusals of other hosts, past the ones kept.
    more: usize = 0,

    const max_refusals = 16;

    const Refusal = struct {
        host: [255]u8,
        host_len: u8,
        port: u16,
        why: Why,
        times: u32,

        fn name(r: *const Refusal) []const u8 {
            return r.host[0..r.host_len];
        }
    };

    const Why = enum { unlisted, local };

    /// A connection to `host` on `port`, made outside the container, or why
    /// there's none. Called from a thread of each channel's.
    pub fn open(p: *Proxy, host: []const u8, port: u16) Outcome {
        const target = hosts.Target.of(host) orelse return p.refuse(host, port, .unlisted);
        if (!hosts.allows(p.list, host, port)) return p.refuse(host, port, .unlisted);
        if (p.upstream) |u| if (!u.bypasses(host)) return p.say(host, port, u.tunnel(host, port));

        var found: [8]net.Address = undefined;
        var n: usize = 0;
        switch (target) {
            .ip4 => |a| {
                found[0] = .{ .ipv4 = .{ .port = std.mem.nativeToBig(u16, port), .addr = a } };
                n = 1;
            },
            .ip6 => |a| {
                found[0] = .{ .ipv6 = .{ .port = std.mem.nativeToBig(u16, port), .addr = a } };
                n = 1;
            },
            .name => |name| {
                var wide: [256:0]u16 = undefined;
                for (name, 0..) |c, i| wide[i] = c;
                wide[name.len] = 0;
                switch (net.resolve(&wide, port, &found)) {
                    .found => |count| n = count,
                    .failed => return p.say(host, port, .{ .status = .unresolved }),
                }
                // Only a list's address reaches this machine; a name doesn't.
                var kept: usize = 0;
                for (found[0..n]) |a| if (!isLocal(a)) {
                    found[kept] = a;
                    kept += 1;
                };
                if (n > 0 and kept == 0) return p.refuse(host, port, .local);
                n = kept;
            },
        }
        if (n == 0) return p.say(host, port, .{ .status = .unresolved });
        var timed_out = false;
        for (found[0..n]) |a| switch (net.connect(a, connect_ms)) {
            .socket => |s| return p.say(host, port, .{ .socket = s }),
            .failed => |code| timed_out = timed_out or code == win32.WSAETIMEDOUT,
        };
        return p.say(host, port, .{ .status = if (timed_out) .timed_out else .failed });
    }

    fn say(p: *Proxy, host: []const u8, port: u16, o: Outcome) Outcome {
        if (p.verbose) note("proxy    {s}:{d}: {s}", .{ host, port, switch (o) {
            .socket => if (p.upstream != null and !p.upstream.?.bypasses(host)) "connected, through your proxy" else "connected",
            .status => |s| switch (s) {
                .unresolved => "its name doesn't resolve",
                .timed_out => "timed out",
                else => "couldn't connect",
            },
        } });
        return o;
    }

    fn refuse(p: *Proxy, host: []const u8, port: u16, why: Why) Outcome {
        if (p.verbose) note("proxy    {s}:{d}: refused, {s}", .{ host, port, switch (why) {
            .unlisted => "as the allow list doesn't name it",
            .local => "as its name is this machine's",
        } });
        win32.AcquireSRWLockExclusive(&p.lock);
        defer win32.ReleaseSRWLockExclusive(&p.lock);
        for (p.refusals[0..p.refusal_count]) |*r| {
            if (r.port == port and r.why == why and std.ascii.eqlIgnoreCase(r.name(), host)) {
                r.times += 1;
                return .{ .status = .refused };
            }
        }
        if (p.refusal_count == max_refusals or host.len > 255) {
            p.more += 1;
            return .{ .status = .refused };
        }
        const r = &p.refusals[p.refusal_count];
        @memcpy(r.host[0..host.len], host);
        r.* = .{ .host = r.host, .host_len = @intCast(host.len), .port = port, .why = why, .times = 1 };
        p.refusal_count += 1;
        return .{ .status = .refused };
    }

    /// Says what was refused, once the run has ended.
    pub fn report(p: *Proxy, arena: Allocator) void {
        win32.AcquireSRWLockExclusive(&p.lock);
        defer win32.ReleaseSRWLockExclusive(&p.lock);
        for ([_]Why{ .unlisted, .local }) |why| {
            var parts: std.ArrayList([]const u8) = .empty;
            for (p.refusals[0..p.refusal_count]) |*r| if (r.why == why) {
                const part = switch (why) {
                    .unlisted => if (r.times == 1)
                        std.fmt.allocPrint(arena, "{s}:{d}", .{ r.name(), r.port })
                    else
                        std.fmt.allocPrint(arena, "{s}:{d} ({d} times)", .{ r.name(), r.port, r.times }),
                    .local => std.fmt.allocPrint(arena, "{s}", .{r.name()}),
                } catch return;
                parts.append(arena, part) catch return;
            };
            if (why == .unlisted and p.more > 0)
                parts.append(arena, std.fmt.allocPrint(arena, "{d} more", .{p.more}) catch return) catch return;
            if (parts.items.len == 0) continue;
            const listed = hosts_list: {
                if (parts.items.len == 1) break :hosts_list parts.items[0];
                const head = std.mem.join(arena, ", ", parts.items[0 .. parts.items.len - 1]) catch return;
                break :hosts_list std.fmt.allocPrint(arena, "{s} and {s}", .{ head, parts.items[parts.items.len - 1] }) catch return;
            };
            switch (why) {
                .unlisted => note("zigsaw: {s} was refused {s}: its allow list doesn't name {s}; --allow-host=<host> lets a run reach one", .{
                    p.id, listed, if (parts.items.len == 1) "it" else "them",
                }),
                .local => note("zigsaw: {s} was refused {s}, as {s} this machine's: a run with an allow list reaches this machine at an address its list names, or on the ports it uses", .{
                    p.id, listed, if (parts.items.len == 1) "its name is" else "their names are",
                }),
            }
        }
    }
};

/// Whether a name's address is this machine's, or no machine's: loopback,
/// unspecified or link-local, also as an IPv4-mapped IPv6 address.
pub fn isLocal(a: net.Address) bool {
    return switch (a) {
        .ipv4 => |in| isLocal4(in.addr),
        .ipv6 => |in6| blk: {
            const b = in6.addr;
            const zero10 = std.mem.allEqual(u8, b[0..10], 0);
            if (zero10 and b[10] == 0xff and b[11] == 0xff) break :blk isLocal4(b[12..16].*);
            if (std.mem.allEqual(u8, b[0..15], 0) and (b[15] == 0 or b[15] == 1)) break :blk true;
            break :blk b[0] == 0xfe and b[1] & 0xc0 == 0x80;
        },
    };
}

fn isLocal4(a: [4]u8) bool {
    return a[0] == 127 or a[0] == 0 or (a[0] == 169 and a[1] == 254);
}

// ---------------------------------------------------------------------------
// Your proxy

pub const Upstream = struct {
    host: []const u8,
    port: u16,
    /// "Basic <base64 of user:password>", if the URL had a user.
    authorization: ?[]const u8,
    /// NO_PROXY, as it was.
    no_proxy: []const u8,
    /// The variable it came from, for messages.
    variable: []const u8,

    /// Your proxy, from the variables zigsaw's own requests honour: for
    /// tunnels, HTTPS_PROXY first, then HTTP_PROXY, then ALL_PROXY. Null if
    /// none is set; a note and null if it's one zigsaw can't use.
    pub fn fromEnv(arena: Allocator, env: *const std.process.Environ.Map) !?Upstream {
        const variable, const value = for ([_][]const u8{ "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY" }) |name| {
            if (env.get(name)) |v| if (std.mem.trim(u8, v, " ").len > 0) break .{ name, std.mem.trim(u8, v, " ") };
        } else return null;
        return parse(arena, value, env.get("NO_PROXY") orelse "", variable) catch |err| {
            note("note: zigsaw can't use {s} ({s}) for an allow list's hosts: {s}; it connects to them directly", .{ variable, value, switch (err) {
                error.Scheme => "only an http:// proxy",
                error.OutOfMemory => |e| return e,
                else => "it isn't a proxy's URL",
            } });
            return null;
        };
    }

    fn parse(arena: Allocator, value: []const u8, no_proxy: []const u8, variable: []const u8) !Upstream {
        const url = if (std.mem.indexOf(u8, value, "://") == null) try std.fmt.allocPrint(arena, "http://{s}", .{value}) else value;
        const uri = try std.Uri.parse(url);
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.Scheme;
        const host = try (uri.host orelse return error.NoHost).toRawMaybeAlloc(arena);
        if (host.len == 0) return error.NoHost;
        var authorization: ?[]const u8 = null;
        if (uri.user) |user| {
            const u = try user.toRawMaybeAlloc(arena);
            const pw = if (uri.password) |pw| try pw.toRawMaybeAlloc(arena) else "";
            const plain = try std.fmt.allocPrint(arena, "{s}:{s}", .{ try percentDecode(arena, u), try percentDecode(arena, pw) });
            const enc = std.base64.standard.Encoder;
            const out = try arena.alloc(u8, enc.calcSize(plain.len));
            authorization = try std.fmt.allocPrint(arena, "Basic {s}", .{enc.encode(out, plain)});
        }
        return .{
            .host = if (host[0] == '[' and host[host.len - 1] == ']') host[1 .. host.len - 1] else host,
            .port = uri.port orelse 80,
            .authorization = authorization,
            .no_proxy = no_proxy,
            .variable = variable,
        };
    }

    /// Whether NO_PROXY has `host` reached directly: `*`, the host, or a
    /// domain it's under (with or without a leading dot or "*."), ports
    /// left aside.
    pub fn bypasses(u: Upstream, host: []const u8) bool {
        const h = std.mem.trimEnd(u8, std.mem.trim(u8, host, "[]"), ".");
        var entries = std.mem.splitScalar(u8, u.no_proxy, ',');
        while (entries.next()) |raw| {
            var e = std.mem.trim(u8, raw, " \t");
            if (e.len == 0) continue;
            if (std.mem.eql(u8, e, "*")) return true;
            if (e[0] == '[') {
                const close = std.mem.indexOfScalar(u8, e, ']') orelse continue;
                e = e[1..close];
            } else if (std.mem.indexOfScalar(u8, e, ':')) |colon| {
                // A port, unless it's an IPv6 address of its own.
                if (std.mem.indexOfScalarPos(u8, e, colon + 1, ':') == null) e = e[0..colon];
            }
            if (std.mem.startsWith(u8, e, "*.")) e = e[1..];
            e = std.mem.trimEnd(u8, e, ".");
            if (e.len == 0) continue;
            if (e[0] == '.') {
                if (h.len > e.len and std.ascii.eqlIgnoreCase(h[h.len - e.len ..], e)) return true;
                if (std.ascii.eqlIgnoreCase(h, e[1..])) return true;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(h, e)) return true;
            if (h.len > e.len + 1 and h[h.len - e.len - 1] == '.' and std.ascii.eqlIgnoreCase(h[h.len - e.len ..], e)) return true;
        }
        return false;
    }

    /// A tunnel to `host` on `port` through the proxy.
    fn tunnel(u: Upstream, host: []const u8, port: u16) Outcome {
        var found: [4]net.Address = undefined;
        var wide: [256:0]u16 = undefined;
        if (u.host.len > 255) return .{ .status = .failed };
        for (u.host, 0..) |c, i| wide[i] = c;
        wide[u.host.len] = 0;
        const n = switch (net.resolve(&wide, u.port, &found)) {
            .found => |n| n,
            .failed => return .{ .status = .failed },
        };
        const s = for (found[0..n]) |a| switch (net.connect(a, connect_ms)) {
            .socket => |s| break s,
            .failed => {},
        } else return .{ .status = .failed };
        var req_buf: [1024]u8 = undefined;
        const req = std.fmt.bufPrint(&req_buf, "CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\n{s}{s}{s}\r\n", .{
            host,                                         port, host, port,
            if (u.authorization != null) "Proxy-Authorization: " else "",
            u.authorization orelse "",
            if (u.authorization != null) "\r\n" else "",
        }) catch {
            _ = win32.closesocket(s);
            return .{ .status = .failed };
        };
        if (!net.sendAll(s, req) or !tunnelOpened(s)) {
            _ = win32.closesocket(s);
            return .{ .status = .failed };
        }
        return .{ .socket = s };
    }
};

/// Reads the proxy's answer to a CONNECT, head only: whether it's 200.
fn tunnelOpened(s: SOCKET) bool {
    const t: win32.DWORD = 10_000;
    _ = win32.setsockopt(s, win32.SOL_SOCKET, win32.SO_RCVTIMEO, &t, @sizeOf(win32.DWORD));
    defer {
        const none: win32.DWORD = 0;
        _ = win32.setsockopt(s, win32.SOL_SOCKET, win32.SO_RCVTIMEO, &none, @sizeOf(win32.DWORD));
    }
    var buf: [8192]u8 = undefined;
    var len: usize = 0;
    // One byte at a time: what follows the head is the tunnel's.
    while (len < buf.len) {
        const n = win32.recv(s, buf[len..].ptr, 1, 0);
        if (n <= 0) return false;
        len += 1;
        if (len >= 4 and std.mem.eql(u8, buf[len - 4 .. len], "\r\n\r\n")) break;
    } else return false;
    const line_end = std.mem.indexOf(u8, buf[0..len], "\r\n").?;
    var parts = std.mem.splitScalar(u8, buf[0..line_end], ' ');
    const version = parts.next() orelse return false;
    const code = parts.next() orelse return false;
    return std.mem.startsWith(u8, version, "HTTP/1.") and std.mem.eql(u8, code, "200");
}

fn percentDecode(arena: Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) return text;
    const out = try arena.alloc(u8, text.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |b| {
                out[n] = b;
                n += 1;
                i += 2;
                continue;
            } else |_| {}
        }
        out[n] = text[i];
        n += 1;
    }
    return out[0..n];
}

test isLocal {
    const t = std.testing;
    const v4 = struct {
        fn of(a: [4]u8) net.Address {
            return .{ .ipv4 = .{ .port = 0, .addr = a } };
        }
    }.of;
    const v6 = struct {
        fn of(text: []const u8) net.Address {
            return .{ .ipv6 = .{ .port = 0, .addr = hosts.parseIp6(text).? } };
        }
    }.of;
    try t.expect(isLocal(v4(.{ 127, 0, 0, 1 })));
    try t.expect(isLocal(v4(.{ 127, 9, 9, 9 })));
    try t.expect(isLocal(v4(.{ 0, 0, 0, 0 })));
    try t.expect(isLocal(v4(.{ 169, 254, 169, 254 })));
    try t.expect(!isLocal(v4(.{ 10, 0, 0, 1 })));
    try t.expect(!isLocal(v4(.{ 192, 0, 2, 7 })));
    try t.expect(isLocal(v6("::1")));
    try t.expect(isLocal(v6("::")));
    try t.expect(isLocal(v6("fe80::1")));
    try t.expect(isLocal(v6("::ffff:127.0.0.1")));
    try t.expect(!isLocal(v6("::ffff:192.0.2.7")));
    try t.expect(!isLocal(v6("2001:db8::7")));
}

test "Upstream.parse and NO_PROXY" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const t = std.testing;
    const u = try Upstream.parse(arena, "http://us%40er:p%3Ass@proxy.corp:3128/", "localhost, .internal.corp,*.dev.corp,10.0.0.5:8080,[::1],example.org", "HTTPS_PROXY");
    try t.expectEqualStrings("proxy.corp", u.host);
    try t.expectEqual(@as(u16, 3128), u.port);
    // "us@er:p:ss"
    try t.expectEqualStrings("Basic dXNAZXI6cDpzcw==", u.authorization.?);
    try t.expect(u.bypasses("localhost"));
    try t.expect(u.bypasses("a.internal.corp"));
    try t.expect(u.bypasses("internal.corp"));
    try t.expect(u.bypasses("x.dev.corp"));
    try t.expect(u.bypasses("10.0.0.5"));
    try t.expect(u.bypasses("[::1]"));
    try t.expect(u.bypasses("example.org"));
    try t.expect(u.bypasses("api.example.org."));
    try t.expect(!u.bypasses("notexample.org"));
    try t.expect(!u.bypasses("github.com"));
    const bare = try Upstream.parse(arena, "127.0.0.1:8888", "*", "HTTP_PROXY");
    try t.expectEqualStrings("127.0.0.1", bare.host);
    try t.expectEqual(@as(u16, 8888), bare.port);
    try t.expectEqual(null, bare.authorization);
    try t.expect(bare.bypasses("anything"));
    try t.expectError(error.Scheme, Upstream.parse(arena, "socks5://proxy:1080", "", "ALL_PROXY"));
    try t.expectError(error.Scheme, Upstream.parse(arena, "https://proxy:443", "", "HTTPS_PROXY"));
}
