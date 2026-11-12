//! Loopback TCP, for services (see services.zig): the listening sockets a
//! serving run makes outside its AppContainer, and the relay's connections
//! inside it (relay.zig). Plain Winsock, as the relay is built small without
//! std.Io; failures are Winsock's error codes, for the caller to report.

const std = @import("std");
/// For tests/netprobe.zig, which has this file as a module.
pub const win32 = @import("win32.zig");

const SOCKET = win32.SOCKET;

pub fn startup() !void {
    var data: win32.WSADATA = undefined;
    if (win32.WSAStartup(0x0202, &data) != 0) return error.WinsockUnavailable;
}

pub const Family = enum { ipv4, ipv6 };

/// 127.0.0.1 or ::1, with a port.
pub const Address = union(Family) {
    ipv4: win32.sockaddr_in,
    ipv6: win32.sockaddr_in6,

    pub fn loopback(family: Family, port: u16) Address {
        const p = std.mem.nativeToBig(u16, port);
        return switch (family) {
            .ipv4 => .{ .ipv4 = .{ .port = p, .addr = .{ 127, 0, 0, 1 } } },
            .ipv6 => .{ .ipv6 = .{ .port = p, .addr = @as([15]u8, @splat(0)) ++ [1]u8{1} } },
        };
    }

    /// An address of either family, with its port: what GetAddrInfoW gave.
    pub fn of(raw: *const anyopaque, port: u16) ?Address {
        const family: *const u16 = @ptrCast(@alignCast(raw));
        const p = std.mem.nativeToBig(u16, port);
        switch (family.*) {
            win32.AF_INET => {
                var in: win32.sockaddr_in = @as(*const win32.sockaddr_in, @ptrCast(@alignCast(raw))).*;
                in.port = p;
                return .{ .ipv4 = in };
            },
            win32.AF_INET6 => {
                var in6: win32.sockaddr_in6 = @as(*const win32.sockaddr_in6, @ptrCast(@alignCast(raw))).*;
                in6.port = p;
                return .{ .ipv6 = in6 };
            },
            else => return null,
        }
    }

    fn ptr(a: *const Address) *const anyopaque {
        return switch (a.*) {
            .ipv4 => |*in| in,
            .ipv6 => |*in6| in6,
        };
    }

    fn len(a: Address) c_int {
        return switch (a) {
            .ipv4 => @sizeOf(win32.sockaddr_in),
            .ipv6 => @sizeOf(win32.sockaddr_in6),
        };
    }

    fn af(a: Address) c_int {
        return switch (a) {
            .ipv4 => win32.AF_INET,
            .ipv6 => win32.AF_INET6,
        };
    }
};

/// A socket, or the Winsock error that kept it from being one.
pub const Result = union(enum) {
    socket: SOCKET,
    failed: c_int,
};

fn newSocket(family: c_int) Result {
    // Sockets made this way can be inherited, but only a process whose
    // handle list names them gets them (see process.zig).
    const s = win32.WSASocketW(family, win32.SOCK_STREAM, win32.IPPROTO_TCP, null, 0, win32.WSA_FLAG_OVERLAPPED);
    if (s == win32.INVALID_SOCKET) return .{ .failed = win32.WSAGetLastError() };
    return .{ .socket = s };
}

/// Closes `s` and returns the error before it.
fn failWith(s: SOCKET) Result {
    const code = win32.WSAGetLastError();
    _ = win32.closesocket(s);
    return .{ .failed = code };
}

/// A socket listening on `address`, which no other socket can take over.
pub fn listen(address: Address) Result {
    const s = switch (newSocket(address.af())) {
        .socket => |s| s,
        .failed => |code| return .{ .failed = code },
    };
    const on: c_int = 1;
    if (win32.setsockopt(s, win32.SOL_SOCKET, win32.SO_EXCLUSIVEADDRUSE, &on, @sizeOf(c_int)) != 0) return failWith(s);
    if (win32.bind(s, address.ptr(), address.len()) != 0) return failWith(s);
    if (win32.listen(s, 64) != 0) return failWith(s);
    return .{ .socket = s };
}

/// A socket connected to `address`, waiting at most `timeout_ms` for an
/// answer: `WSAETIMEDOUT` if none came, as when a connection is dropped
/// rather than refused.
pub fn connect(address: Address, timeout_ms: u32) Result {
    const s = switch (newSocket(address.af())) {
        .socket => |s| s,
        .failed => |code| return .{ .failed = code },
    };
    var nonblocking: u32 = 1;
    if (win32.ioctlsocket(s, win32.FIONBIO, &nonblocking) != 0) return failWith(s);
    if (win32.connect(s, address.ptr(), address.len()) != 0) {
        if (win32.WSAGetLastError() != win32.WSAEWOULDBLOCK) return failWith(s);
        var writable: win32.fd_set = .{ .fd_count = 1, .fd_array = undefined };
        writable.fd_array[0] = s;
        var failed: win32.fd_set = writable;
        const timeout: win32.timeval = .{ .tv_sec = @intCast(timeout_ms / 1000), .tv_usec = @intCast(timeout_ms % 1000 * 1000) };
        switch (win32.select(0, null, &writable, &failed, &timeout)) {
            0 => {
                _ = win32.closesocket(s);
                return .{ .failed = win32.WSAETIMEDOUT };
            },
            win32.SOCKET_ERROR => return failWith(s),
            else => if (failed.fd_count > 0) {
                var code: c_int = 0;
                var code_len: c_int = @sizeOf(c_int);
                _ = win32.getsockopt(s, win32.SOL_SOCKET, win32.SO_ERROR, &code, &code_len);
                _ = win32.closesocket(s);
                return .{ .failed = if (code != 0) code else win32.WSAECONNREFUSED };
            },
        }
    }
    nonblocking = 0;
    if (win32.ioctlsocket(s, win32.FIONBIO, &nonblocking) != 0) return failWith(s);
    return .{ .socket = s };
}

/// The addresses `name` resolves to, with `port`, as many as fit in `out`;
/// or GetAddrInfoW's error. Names of either family, IPv4 first, as Windows
/// orders them.
pub fn resolve(name: [*:0]const u16, port: u16, out: []Address) union(enum) { found: usize, failed: c_int } {
    const hints: win32.ADDRINFOW = .{ .family = win32.AF_UNSPEC, .socktype = win32.SOCK_STREAM, .protocol = win32.IPPROTO_TCP };
    var list: ?*win32.ADDRINFOW = null;
    const code = win32.GetAddrInfoW(name, null, &hints, &list);
    if (code != 0) return .{ .failed = code };
    defer if (list) |l| win32.FreeAddrInfoW(l);
    var n: usize = 0;
    var it = list;
    while (it) |info| : (it = info.next) {
        if (n == out.len) break;
        const raw = info.addr orelse continue;
        out[n] = Address.of(raw, port) orelse continue;
        n += 1;
    }
    return .{ .found = n };
}

/// The port a socket is bound to.
pub fn localPort(s: SOCKET) ?u16 {
    // Big enough for either family; the port is at the same offset in both.
    var addr: win32.sockaddr_in6 = undefined;
    var len: c_int = @sizeOf(win32.sockaddr_in6);
    if (win32.getsockname(s, &addr, &len) != 0) return null;
    return std.mem.bigToNative(u16, addr.port);
}

/// Sends all of `bytes`; false if the connection failed first.
pub fn sendAll(s: SOCKET, bytes: []const u8) bool {
    var rest = bytes;
    while (rest.len > 0) {
        const n = win32.send(s, rest.ptr, @intCast(@min(rest.len, std.math.maxInt(c_int))), 0);
        if (n <= 0) return false;
        rest = rest[@intCast(n)..];
    }
    return true;
}

test "Address.loopback" {
    const a = Address.loopback(.ipv4, 5432);
    try std.testing.expectEqual(@as(u16, 0x3815), a.ipv4.port);
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &a.ipv4.addr);
    const b = Address.loopback(.ipv6, 8471);
    try std.testing.expectEqual(@as(u8, 1), b.ipv6.addr[15]);
    try std.testing.expectEqual(@as(u8, 0), b.ipv6.addr[0]);
    try std.testing.expectEqual(@as(c_int, 28), b.len());
}

// ---------------------------------------------------------------------------
// The proxy of a run with an allow list (relay.zig, forward.zig, proxy.zig)

/// What the relay writes on a channel to ask zigsaw for a host, in place of
/// a forward's index: then the host's length (a byte), the host, and the
/// port (two bytes, little-endian).
pub const proxy_request: u8 = 0xFF;

/// zigsaw's answer to a proxy request, a byte; after `connected`, the
/// connection, as a forward's.
pub const ProxyStatus = enum(u8) {
    connected = 0,
    failed = 1,
    /// The allow list doesn't name the host, or its name is this machine's.
    refused = 2,
    timed_out = 3,
    unresolved = 4,
    _,
};
