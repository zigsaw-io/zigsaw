//! Forwards: how a run in an AppContainer that isn't exempt from loopback
//! isolation reaches the ports it uses (see services.zig), which nothing in
//! its container can connect to; and how a run with an allow list reaches
//! the hosts on it, through the proxy the relay is (see proxy.zig).
//!
//! The run's relay (relay.zig) listens inside the container on a port of
//! its own for each use, where ${uses:<name>} has the app connect, and on
//! one for its proxy. For each connection it accepts, it asks zigsaw over a
//! channel, a pair of pipes it inherits; zigsaw connects outside the
//! container, to the port on 127.0.0.1 or ::1, or to the host a proxy
//! request names, if the list allows it, and duplicates that socket into the
//! relay, which then copies bytes between the two. Only connected sockets go
//! in: with an unconnected one, the app could connect anywhere
//! (docs/networking.md).
//!
//! Each channel carries one request at a time, answered by a thread of
//! zigsaw's own that ends when the relay does. A proxy's connections take
//! as long as a host on the internet does, so a run with one has several.

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");
const net = @import("net.zig");
const proxy = @import("proxy.zig");

/// A run with a proxy's: as many connections at once as are being made.
const proxy_channels = 8;

pub const Forwards = struct {
    channels: []Channel,
    /// The ports zigsaw connects to, by the index the relay asks for.
    ports: []const u16,
    /// Where the relay listens for each, in the same order.
    connect: []const u16,
    /// The run's allow list, and where the relay listens for its proxy.
    proxy: ?*proxy.Proxy,
    proxy_port: u16,

    pub const Channel = struct {
        /// The pipes' ends the relay inherits: what it reads, and what it
        /// writes.
        relay_in: win32.HANDLE,
        relay_out: win32.HANDLE,
        /// Ours.
        in: win32.HANDLE,
        out: win32.HANDLE,
    };

    pub fn open(arena: Allocator, ports: []const u16, listen: []const u16, p: ?*proxy.Proxy, proxy_port: u16) !Forwards {
        const channels = try arena.alloc(Channel, if (p != null) proxy_channels else 1);
        for (channels, 0..) |*c, i| {
            errdefer for (channels[0..i]) |done| closeAll(done);
            if (win32.CreatePipe(&c.relay_in, &c.out, null, 0) == 0) return win32.lastErrorFail("CreatePipe");
            if (win32.CreatePipe(&c.in, &c.relay_out, null, 0) == 0) {
                _ = win32.CloseHandle(c.relay_in);
                _ = win32.CloseHandle(c.out);
                return win32.lastErrorFail("CreatePipe");
            }
        }
        return .{
            .channels = channels,
            .ports = try arena.dupe(u16, ports),
            .connect = try arena.dupe(u16, listen),
            .proxy = p,
            .proxy_port = proxy_port,
        };
    }

    /// The relay's arguments for them.
    pub fn args(f: Forwards, arena: Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (f.channels) |c| try out.append(arena, try std.fmt.allocPrint(arena, "forward={d}:{d}", .{ @intFromPtr(c.relay_in), @intFromPtr(c.relay_out) }));
        for (f.connect) |port| try out.append(arena, try std.fmt.allocPrint(arena, "use={d}", .{port}));
        if (f.proxy != null) try out.append(arena, try std.fmt.allocPrint(arena, "proxy={d}", .{f.proxy_port}));
        return out.items;
    }

    /// The handles the relay inherits.
    pub fn relayHandles(f: Forwards, arena: Allocator) ![]const win32.HANDLE {
        var out: std.ArrayList(win32.HANDLE) = .empty;
        for (f.channels) |c| try out.appendSlice(arena, &.{ c.relay_in, c.relay_out });
        return out.items;
    }

    /// Once the relay has started, holding the pipes' other ends, waits
    /// until it listens, which it says with a byte on the first channel,
    /// and answers its requests from a thread of each channel's. False if
    /// it doesn't listen; if a thread can't start, its channel stays
    /// unanswered, and with no channel answered the app's connections fail.
    pub fn serve(f: Forwards, relay: win32.HANDLE) bool {
        for (f.channels) |c| {
            _ = win32.CloseHandle(c.relay_in);
            _ = win32.CloseHandle(c.relay_out);
        }
        var ready: [1]u8 = undefined;
        if (!readAll(f.channels[0].in, &ready)) return false;
        const pid = win32.GetProcessId(relay);
        for (f.channels) |c| {
            const thread = std.Thread.spawn(.{}, answer, .{ f, c, pid }) catch continue;
            thread.detach();
        }
        return true;
    }

    /// When the relay didn't start.
    pub fn close(f: Forwards) void {
        for (f.channels) |c| closeAll(c);
    }

    fn closeAll(c: Channel) void {
        for ([_]win32.HANDLE{ c.relay_in, c.relay_out, c.in, c.out }) |h| _ = win32.CloseHandle(h);
    }
};

fn answer(f: Forwards, c: Forwards.Channel, relay_pid: win32.DWORD) void {
    net.startup() catch return;
    while (true) {
        var request: [1]u8 = undefined;
        if (!readAll(c.in, &request)) return;
        const outcome: proxy.Outcome = if (request[0] == net.proxy_request) outcome: {
            var len: [1]u8 = undefined;
            var host: [255]u8 = undefined;
            var port: [2]u8 = undefined;
            if (!readAll(c.in, &len) or !readAll(c.in, host[0..len[0]]) or !readAll(c.in, &port)) return;
            const p = f.proxy orelse break :outcome .{ .status = .refused };
            break :outcome p.open(host[0..len[0]], std.mem.readInt(u16, &port, .little));
        } else if (request[0] < f.ports.len)
            if (connect(f.ports[request[0]])) |s| .{ .socket = s } else .{ .status = .failed }
        else
            return;
        const s = switch (outcome) {
            .socket => |s| s,
            .status => |status| {
                if (!writeAll(c.out, &.{@intFromEnum(status)})) return;
                continue;
            },
        };
        defer _ = win32.closesocket(s);
        var info: win32.WSAPROTOCOL_INFOW = undefined;
        if (win32.WSADuplicateSocketW(s, relay_pid, &info) != 0) {
            if (!writeAll(c.out, &.{@intFromEnum(net.ProxyStatus.failed)})) return;
            continue;
        }
        if (!writeAll(c.out, &.{0}) or !writeAll(c.out, std.mem.asBytes(&info))) return;
        // Ours stays open until the relay has opened its copy.
        var ack: [1]u8 = undefined;
        if (!readAll(c.in, &ack)) return;
    }
}

/// A connection to `port` on this machine, on 127.0.0.1 or ::1.
fn connect(port: u16) ?win32.SOCKET {
    for ([_]net.Family{ .ipv4, .ipv6 }) |family| switch (net.connect(.loopback(family, port), 2000)) {
        .socket => |s| return s,
        .failed => {},
    };
    return null;
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
