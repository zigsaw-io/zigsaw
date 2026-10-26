//! The network probe: what Windows lets AppContainers do on this machine's
//! loopback, and tests/network.sh's test app. Built by `zig build netprobe`.
//!
//!   zigsaw-netprobe report        one line per check: `<check> <result>`
//!   zigsaw-netprobe serve <port>  answers "ping" with "pong" on
//!                                 127.0.0.1:<port>, until it's ended
//!   zigsaw-netprobe ping <port>   exits 0 if 127.0.0.1:<port> answers
//!   zigsaw-netprobe env <name>... prints `<name>=<value>` for each one set
//!
//! The report's endpoints are processes of its own, on the host or in two
//! AppContainer profiles it makes and deletes (zigsaw.test.netprobe.a and
//! .b), so its executable must be readable to ALL APPLICATION PACKAGES.
//! Each check passes a "ping" and a "pong" between two of them:
//!
//!   same-container          two runs in one container, with no network
//!                           capability: an app's private loopback
//!   container-to-container  from one container to another
//!   host-to-container       from the host to a container that holds every
//!                           network capability
//!   container-to-host       from a container with the `network` permission's
//!                           capabilities to the host
//!   handed-listening        a socket the host listens on, handed to a
//!                           container process, accepts a host connection:
//!                           how zigsaw publishes services (relay.zig)
//!   handed-connected        a socket the host connected to a host server,
//!                           handed to a container process with no network
//!                           capability, which talks on it
//!   handed-unconnected      a socket the host made but didn't connect,
//!                           handed in: the container connects it to the
//!                           host, which is why zigsaw never hands one in
//!
//! Results are `connects`, `dropped` (no answer within 3 s), or
//! `error <Winsock code>`. Last, `profile-race`: one new profile created by
//! 8 threads at once, 5 times, and how many calls failed with errors other
//! than "already exists", as zigsaw's runs did before they made profiles one
//! at a time (appcontainer.zig).

const std = @import("std");
const net = @import("net");
const win32 = net.win32;

const SOCKET = win32.SOCKET;
const DWORD = win32.DWORD;

/// How long a connector waits for an answer: a dropped connection never gets
/// one.
const timeout_ms = 3000;

const profiles = [_][]const u8{ "zigsaw.test.netprobe.a", "zigsaw.test.netprobe.b" };
const race_profile = "zigsaw.test.netprobe.race";

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    net.startup() catch return 99;
    if (args.len < 2) return usage();
    const mode = args[1];
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    if (std.mem.eql(u8, mode, "report")) {
        try report(arena, out);
        return 0;
    }
    if (std.mem.eql(u8, mode, "serve") and args.len == 3) return serve(out, try port(args[2]));
    if (std.mem.eql(u8, mode, "ping") and args.len == 3) {
        const code = connectAndPing(.loopback(.ipv4, try port(args[2])));
        try out.print("{f}\n", .{Outcome{ .code = code }});
        return if (code == 0) 0 else 1;
    }
    if (std.mem.eql(u8, mode, "env")) {
        for (args[2..]) |name| if (init.environ_map.get(name)) |value| try out.print("{s}={s}\n", .{ name, value });
        return 0;
    }
    // The report's endpoints, which exit with 0 for a round trip, or a
    // Winsock error.
    if (args.len == 3 and std.mem.eql(u8, mode, "_listen")) return exitCode(listenAndPong(try port(args[2])));
    if (args.len == 3 and std.mem.eql(u8, mode, "_connect")) return exitCode(connectAndPing(.loopback(.ipv4, try port(args[2]))));
    if (args.len == 3 and std.mem.eql(u8, mode, "_accept")) return exitCode(acceptAndPong(try socket(args[2]), 2 * timeout_ms));
    if (args.len == 3 and std.mem.eql(u8, mode, "_ping")) return exitCode(ping(try socket(args[2])));
    if (args.len == 4 and std.mem.eql(u8, mode, "_connect-socket")) return exitCode(connectSocket(try socket(args[2]), try port(args[3])));
    return usage();
}

fn usage() u8 {
    std.debug.print("usage: zigsaw-netprobe report | serve <port> | ping <port> | env <name>...\n", .{});
    return 2;
}

fn port(arg: []const u8) !u16 {
    return std.fmt.parseInt(u16, arg, 10);
}

fn socket(arg: []const u8) !SOCKET {
    return std.fmt.parseInt(SOCKET, arg, 10);
}

/// Ends an endpoint with its outcome as its exit code: Winsock's error codes
/// don't fit in main's u8.
fn exitCode(code: c_int) noreturn {
    win32.ExitProcess(@bitCast(code));
}

const Outcome = struct {
    code: c_int,

    pub fn format(o: Outcome, w: *std.Io.Writer) !void {
        switch (o.code) {
            0 => try w.writeAll("connects"),
            win32.WSAETIMEDOUT => try w.writeAll("dropped"),
            else => try w.print("error {d}", .{o.code}),
        }
    }
};

// ---------------------------------------------------------------------------
// Endpoints

fn serve(out: *std.Io.Writer, p: u16) !u8 {
    const listener = switch (net.listen(.loopback(.ipv4, p))) {
        .socket => |s| s,
        .failed => |code| {
            try out.print("can't listen on 127.0.0.1:{d}: error {d}\n", .{ p, code });
            return 1;
        },
    };
    try out.print("listening on 127.0.0.1:{d}\n", .{p});
    try out.flush();
    while (true) {
        const c = win32.accept(listener, null, null);
        if (c == win32.INVALID_SOCKET) continue;
        _ = pong(c);
        _ = win32.closesocket(c);
    }
}

fn listenAndPong(p: u16) c_int {
    const listener = switch (net.listen(.loopback(.ipv4, p))) {
        .socket => |s| s,
        .failed => |code| return code,
    };
    return acceptAndPong(listener, 2 * timeout_ms);
}

fn acceptAndPong(listener: SOCKET, wait_ms: u32) c_int {
    var readable: win32.fd_set = .{ .fd_count = 1, .fd_array = undefined };
    readable.fd_array[0] = listener;
    const timeout: win32.timeval = .{ .tv_sec = @intCast(wait_ms / 1000), .tv_usec = 0 };
    switch (win32.select(0, &readable, null, null, &timeout)) {
        0 => return win32.WSAETIMEDOUT,
        win32.SOCKET_ERROR => return win32.WSAGetLastError(),
        else => {},
    }
    const c = win32.accept(listener, null, null);
    if (c == win32.INVALID_SOCKET) return win32.WSAGetLastError();
    defer _ = win32.closesocket(c);
    return pong(c);
}

fn connectAndPing(address: net.Address) c_int {
    const s = switch (net.connect(address, timeout_ms)) {
        .socket => |s| s,
        .failed => |code| return code,
    };
    defer _ = win32.closesocket(s);
    return ping(s);
}

/// Connects a socket the host made, which isn't connected yet, to the host.
fn connectSocket(s: SOCKET, p: u16) c_int {
    const address: net.Address = .loopback(.ipv4, p);
    if (win32.connect(s, &address.ipv4, @sizeOf(win32.sockaddr_in)) != 0) return win32.WSAGetLastError();
    return ping(s);
}

/// The 4-byte message that came, or the error.
fn receive4(s: SOCKET, buf: *[4]u8) c_int {
    const t: DWORD = timeout_ms;
    _ = win32.setsockopt(s, win32.SOL_SOCKET, win32.SO_RCVTIMEO, &t, @sizeOf(DWORD));
    var got: usize = 0;
    while (got < 4) {
        const n = win32.recv(s, buf[got..].ptr, @intCast(4 - got), 0);
        if (n < 0) return win32.WSAGetLastError();
        if (n == 0) return win32.WSAECONNREFUSED;
        got += @intCast(n);
    }
    return 0;
}

fn ping(s: SOCKET) c_int {
    if (!net.sendAll(s, "ping")) return win32.WSAGetLastError();
    var buf: [4]u8 = undefined;
    const code = receive4(s, &buf);
    if (code != 0) return code;
    return if (std.mem.eql(u8, &buf, "pong")) 0 else win32.WSAECONNREFUSED;
}

fn pong(s: SOCKET) c_int {
    var buf: [4]u8 = undefined;
    const code = receive4(s, &buf);
    if (code != 0) return code;
    if (!std.mem.eql(u8, &buf, "ping")) return win32.WSAECONNREFUSED;
    return if (net.sendAll(s, "pong")) 0 else win32.WSAGetLastError();
}

// ---------------------------------------------------------------------------
// The report

const Where = union(enum) {
    host,
    container: struct { profile: usize, network: bool },
};

fn report(arena: std.mem.Allocator, out: *std.Io.Writer) !void {
    var sids: [profiles.len]win32.PSID = undefined;
    for (&sids, profiles) |*sid, name| sid.* = try profile(arena, name);
    defer for (profiles) |name| {
        _ = win32.DeleteAppContainerProfile(win32.wide(arena, name) catch continue);
    };
    var caps: [2]win32.SID_AND_ATTRIBUTES = undefined;
    for (&caps, [_][]const u8{ "S-1-15-3-1", "S-1-15-3-3" }) |*c, s| {
        var sid: ?win32.PSID = null;
        if (win32.ConvertStringSidToSidW(try win32.wide(arena, s), &sid) == 0) return error.BadSid;
        c.* = .{ .Sid = sid.?, .Attributes = win32.SE_GROUP_ENABLED };
    }
    const ctx: Spawner = .{ .arena = arena, .sids = &sids, .network_caps = &caps };

    const a: Where = .{ .container = .{ .profile = 0, .network = false } };
    const a_net: Where = .{ .container = .{ .profile = 0, .network = true } };
    const b_net: Where = .{ .container = .{ .profile = 1, .network = true } };
    try out.print("same-container {f}\n", .{try ctx.pair(a, a)});
    try out.print("container-to-container {f}\n", .{try ctx.pair(b_net, a_net)});
    try out.print("host-to-container {f}\n", .{try ctx.pair(a_net, .host)});
    try out.print("container-to-host {f}\n", .{try ctx.pair(.host, a_net)});
    try out.flush();
    try out.print("handed-listening {f}\n", .{try ctx.handedListening(a)});
    try out.print("handed-connected {f}\n", .{try ctx.handedConnected(a)});
    try out.print("handed-unconnected {f}\n", .{try ctx.handedUnconnected(a)});
    try out.flush();
    try profileRace(arena, out);
}

fn profile(arena: std.mem.Allocator, name: []const u8) !win32.PSID {
    const w = try win32.wide(arena, name);
    var sid: ?win32.PSID = null;
    var hr = win32.CreateAppContainerProfile(w, w, w, null, 0, &sid);
    if (hr == win32.E_ALREADY_EXISTS) hr = win32.DeriveAppContainerSidFromAppContainerName(w, &sid);
    if (hr < 0) {
        std.debug.print("AppContainer profile {s}: HRESULT 0x{x}\n", .{ name, @as(u32, @bitCast(hr)) });
        return error.NoProfile;
    }
    return sid.?;
}

/// A port nothing listens on now.
fn freePort() !u16 {
    const s = switch (net.listen(.loopback(.ipv4, 0))) {
        .socket => |s| s,
        .failed => return error.NoPort,
    };
    defer _ = win32.closesocket(s);
    return net.localPort(s) orelse error.NoPort;
}

const Spawner = struct {
    arena: std.mem.Allocator,
    sids: []const win32.PSID,
    network_caps: []win32.SID_AND_ATTRIBUTES,

    /// A listener and a connector of their own: the connector's outcome.
    fn pair(s: Spawner, listener_at: Where, connector_at: Where) !Outcome {
        const p = try freePort();
        const listener = try s.spawn(listener_at, null, try std.fmt.allocPrint(s.arena, "_listen {d}", .{p}));
        win32.Sleep(500);
        const connector = try s.spawn(connector_at, null, try std.fmt.allocPrint(s.arena, "_connect {d}", .{p}));
        const code = finish(connector, 3 * timeout_ms);
        _ = finish(listener, if (code == 0) timeout_ms else 0);
        return .{ .code = code };
    }

    /// A socket the host listens on, accepted in a container; a host client.
    fn handedListening(s: Spawner, at: Where) !Outcome {
        const p = try freePort();
        const listener = switch (net.listen(.loopback(.ipv4, p))) {
            .socket => |l| l,
            .failed => |code| return .{ .code = code },
        };
        defer _ = win32.closesocket(listener);
        const acceptor = try s.spawn(at, listener, try std.fmt.allocPrint(s.arena, "_accept {d}", .{listener}));
        win32.Sleep(500);
        const client = try s.spawn(.host, null, try std.fmt.allocPrint(s.arena, "_connect {d}", .{p}));
        const code = finish(client, 3 * timeout_ms);
        _ = finish(acceptor, if (code == 0) timeout_ms else 0);
        return .{ .code = code };
    }

    /// A connection the host made to a host server, used in a container.
    fn handedConnected(s: Spawner, at: Where) !Outcome {
        const p = try freePort();
        const server = try s.spawn(.host, null, try std.fmt.allocPrint(s.arena, "_listen {d}", .{p}));
        win32.Sleep(500);
        const conn = switch (net.connect(.loopback(.ipv4, p), timeout_ms)) {
            .socket => |c| c,
            .failed => |code| {
                _ = finish(server, 0);
                return .{ .code = code };
            },
        };
        defer _ = win32.closesocket(conn);
        const user = try s.spawn(at, conn, try std.fmt.allocPrint(s.arena, "_ping {d}", .{conn}));
        const code = finish(user, 3 * timeout_ms);
        _ = finish(server, if (code == 0) timeout_ms else 0);
        return .{ .code = code };
    }

    /// A socket the host made, unconnected, connected in a container to a
    /// host server.
    fn handedUnconnected(s: Spawner, at: Where) !Outcome {
        const p = try freePort();
        const server = try s.spawn(.host, null, try std.fmt.allocPrint(s.arena, "_listen {d}", .{p}));
        win32.Sleep(500);
        const sock = win32.WSASocketW(win32.AF_INET, win32.SOCK_STREAM, win32.IPPROTO_TCP, null, 0, win32.WSA_FLAG_OVERLAPPED);
        if (sock == win32.INVALID_SOCKET) return .{ .code = win32.WSAGetLastError() };
        defer _ = win32.closesocket(sock);
        const user = try s.spawn(at, sock, try std.fmt.allocPrint(s.arena, "_connect-socket {d} {d}", .{ sock, p }));
        const code = finish(user, 3 * timeout_ms);
        _ = finish(server, if (code == 0) timeout_ms else 0);
        return .{ .code = code };
    }

    /// Starts this program with `args`, on the host or in a container, with
    /// `inherit` as its only inherited handle.
    fn spawn(s: Spawner, at: Where, inherit: ?SOCKET, args: []const u8) !win32.HANDLE {
        const arena = s.arena;
        const self = try win32.selfExePath(arena);
        const command_line = try win32.wide(arena, try std.fmt.allocPrint(arena, "\"{s}\" {s}", .{ self, args }));

        var security: win32.SECURITY_CAPABILITIES = undefined;
        const attr_count: DWORD = @as(DWORD, @intFromBool(at == .container)) + @intFromBool(inherit != null);
        var size: usize = 0;
        _ = win32.InitializeProcThreadAttributeList(null, @max(attr_count, 1), 0, &size);
        const attrs = try arena.alignedAlloc(u8, .of(usize), size);
        if (win32.InitializeProcThreadAttributeList(attrs.ptr, @max(attr_count, 1), 0, &size) == 0) return error.Spawn;
        switch (at) {
            .host => {},
            .container => |c| {
                security = .{
                    .AppContainerSid = s.sids[c.profile],
                    .Capabilities = if (c.network) s.network_caps.ptr else null,
                    .CapabilityCount = if (c.network) @intCast(s.network_caps.len) else 0,
                };
                if (win32.UpdateProcThreadAttribute(attrs.ptr, 0, win32.PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, &security, @sizeOf(win32.SECURITY_CAPABILITIES), null, null) == 0)
                    return error.Spawn;
            },
        }
        var handles: [1]win32.HANDLE = undefined;
        if (inherit) |h| {
            handles[0] = @ptrFromInt(h);
            _ = win32.SetHandleInformation(handles[0], win32.HANDLE_FLAG_INHERIT, win32.HANDLE_FLAG_INHERIT);
            if (win32.UpdateProcThreadAttribute(attrs.ptr, 0, win32.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &handles, @sizeOf(win32.HANDLE), null, null) == 0)
                return error.Spawn;
        }
        var startup: win32.STARTUPINFOEXW = .{
            .StartupInfo = .{ .cb = @sizeOf(win32.STARTUPINFOEXW) },
            .lpAttributeList = attrs.ptr,
        };
        var info: win32.PROCESS_INFORMATION = undefined;
        if (win32.CreateProcessW(null, command_line.ptr, null, null, @intFromBool(inherit != null), win32.EXTENDED_STARTUPINFO_PRESENT, null, null, &startup.StartupInfo, &info) == 0) {
            std.debug.print("starting the probe in {t}: error {d}\n", .{ at, win32.GetLastError() });
            return error.Spawn;
        }
        _ = win32.CloseHandle(info.hThread);
        return info.hProcess;
    }
};

/// The endpoint's exit code, once it has exited, or `WSAETIMEDOUT` if it
/// hadn't within `ms` and was ended.
fn finish(process: win32.HANDLE, ms: DWORD) c_int {
    defer _ = win32.CloseHandle(process);
    if (win32.WaitForSingleObject(process, ms) != win32.WAIT_OBJECT_0) {
        _ = win32.TerminateProcess(process, 1);
        _ = win32.WaitForSingleObject(process, win32.INFINITE);
        return win32.WSAETIMEDOUT;
    }
    var code: DWORD = 0;
    _ = win32.GetExitCodeProcess(process, &code);
    return @bitCast(code);
}

fn profileRace(arena: std.mem.Allocator, out: *std.Io.Writer) !void {
    const name = try win32.wide(arena, race_profile);
    const threads = 8;
    const rounds = 5;
    var failed: usize = 0;
    var codes: std.ArrayList(u32) = .empty;
    for (0..rounds) |_| {
        _ = win32.DeleteAppContainerProfile(name);
        var results: [threads]win32.HRESULT = undefined;
        var go: std.atomic.Value(bool) = .init(false);
        var started: [threads]std.Thread = undefined;
        for (&started, &results) |*t, *r| t.* = try std.Thread.spawn(.{}, createOne, .{ name, r, &go });
        win32.Sleep(50);
        go.store(true, .release);
        for (started) |t| t.join();
        for (results) |hr| if (hr < 0 and hr != win32.E_ALREADY_EXISTS) {
            failed += 1;
            const code: u32 = @bitCast(hr);
            if (std.mem.indexOfScalar(u32, codes.items, code) == null) try codes.append(arena, code);
        };
    }
    _ = win32.DeleteAppContainerProfile(name);
    try out.print("profile-race {d} of {d} failed", .{ failed, threads * rounds });
    for (codes.items) |c| try out.print(" 0x{x}", .{c});
    try out.writeByte('\n');
}

fn createOne(name: [:0]const u16, result: *win32.HRESULT, go: *std.atomic.Value(bool)) void {
    while (!go.load(.acquire)) std.atomic.spinLoopHint();
    var sid: ?win32.PSID = null;
    result.* = win32.CreateAppContainerProfile(name, name, name, null, 0, &sid);
}
