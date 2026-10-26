//! Forwards: how a run in an AppContainer that isn't exempt from loopback
//! isolation reaches the ports it uses (see services.zig), which nothing in
//! its container can connect to.
//!
//! The run's relay (relay.zig) listens inside the container on a port of
//! its own for each, where ${uses:<name>} has the app connect. For each
//! connection it accepts, it asks zigsaw over a pair of pipes, which it
//! inherits; zigsaw connects to the port outside the container, on
//! 127.0.0.1 or ::1, and duplicates that socket into the relay, which then
//! copies bytes between the two. Only connected sockets go in: with an
//! unconnected one, the app could connect anywhere (docs/networking.md).
//!
//! zigsaw answers one request at a time, from a thread of its own that
//! ends when the relay does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");
const net = @import("net.zig");

pub const Forwards = struct {
    /// The pipes' ends the relay inherits: what it reads, and what it writes.
    relay_in: win32.HANDLE,
    relay_out: win32.HANDLE,
    /// Ours.
    in: win32.HANDLE,
    out: win32.HANDLE,
    /// The ports zigsaw connects to, by the index the relay asks for.
    ports: []const u16,
    /// Where the relay listens for each, in the same order.
    connect: []const u16,

    pub fn open(arena: Allocator, ports: []const u16, listen: []const u16) !Forwards {
        var f: Forwards = undefined;
        if (win32.CreatePipe(&f.relay_in, &f.out, null, 0) == 0) return win32.lastErrorFail("CreatePipe");
        if (win32.CreatePipe(&f.in, &f.relay_out, null, 0) == 0) return win32.lastErrorFail("CreatePipe");
        f.ports = try arena.dupe(u16, ports);
        f.connect = try arena.dupe(u16, listen);
        return f;
    }

    /// The relay's arguments for them.
    pub fn args(f: Forwards, arena: Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        try out.append(arena, try std.fmt.allocPrint(arena, "forward={d}:{d}", .{ @intFromPtr(f.relay_in), @intFromPtr(f.relay_out) }));
        for (f.connect) |port| try out.append(arena, try std.fmt.allocPrint(arena, "use={d}", .{port}));
        return out.items;
    }

    /// Once the relay has started, holding the pipes' other ends, waits
    /// until it listens, which it says with a byte, and answers its requests
    /// from a thread of its own. False if it doesn't listen; if the thread
    /// can't start, the app's connections to the ports it uses fail.
    pub fn serve(f: Forwards, relay: win32.HANDLE) bool {
        _ = win32.CloseHandle(f.relay_in);
        _ = win32.CloseHandle(f.relay_out);
        var ready: [1]u8 = undefined;
        if (!readAll(f.in, &ready)) return false;
        const thread = std.Thread.spawn(.{}, answer, .{ f, win32.GetProcessId(relay) }) catch return true;
        thread.detach();
        return true;
    }

    /// When the relay didn't start.
    pub fn close(f: Forwards) void {
        for ([_]win32.HANDLE{ f.relay_in, f.relay_out, f.in, f.out }) |h| _ = win32.CloseHandle(h);
    }
};

fn answer(f: Forwards, relay_pid: win32.DWORD) void {
    net.startup() catch return;
    while (true) {
        var index: [1]u8 = undefined;
        if (!readAll(f.in, &index) or index[0] >= f.ports.len) return;
        const s = connect(f.ports[index[0]]) orelse {
            if (!writeAll(f.out, &.{1})) return;
            continue;
        };
        defer _ = win32.closesocket(s);
        var info: win32.WSAPROTOCOL_INFOW = undefined;
        if (win32.WSADuplicateSocketW(s, relay_pid, &info) != 0) {
            if (!writeAll(f.out, &.{1})) return;
            continue;
        }
        if (!writeAll(f.out, &.{0}) or !writeAll(f.out, std.mem.asBytes(&info))) return;
        // Ours stays open until the relay has opened its copy.
        var ack: [1]u8 = undefined;
        if (!readAll(f.in, &ack)) return;
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
