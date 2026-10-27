//! The network probe: what Windows lets AppContainers do on this machine's
//! loopback, and tests/network.sh's test app. Built by `zig build netprobe`.
//!
//!   zigsaw-netprobe report        one line per check: `<check> <result>`
//!   zigsaw-netprobe serve <port>  answers "ping" with "pong" on
//!                                 127.0.0.1:<port>, until it's ended
//!   zigsaw-netprobe ping <port>   exits 0 if 127.0.0.1:<port> answers
//!   zigsaw-netprobe env <name>... prints `<name>=<value>` for each one set
//!   zigsaw-netprobe wait <ms>     exits after <ms> milliseconds
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
//! Then AF_UNIX, each check in a directory of its own under TEMP, which
//! gives containers nothing but what the check grants them (Modify, on the
//! directory and what's made in it, unless it says read):
//!
//!   unix-host-to-container       a container connects to a host server's
//!                                socket
//!   unix-container-to-host       the host connects to a container's
//!   unix-container-to-container  between two containers granted the
//!                                directory, neither with a network
//!                                capability
//!   unix-not-granted             from a container that isn't granted it
//!   unix-read-only               from one granted only read and execute:
//!                                whether connecting needs more
//!   unix-low-to-host             from a low-integrity process to a host
//!                                server's socket, in a directory with no
//!                                label of its own (medium)
//!   unix-host-to-low             from the host to a low-integrity server's,
//!                                in a directory labelled low
//!   unix-path-107, unix-path-108 the host to itself at a path that many
//!                                bytes long (sun_path has 108)
//!
//! Then the loopback exemption, on a third container (.c), which the probe
//! exempts and takes back after:
//!
//!   exempt-set              whether this account may change the list of
//!                           exempt containers, and how long that took:
//!                           `ok <ms> ms`, or `refused <Win32 error>`
//!   exempt-to-host          from the exempt container, with the `network`
//!                           permission's capabilities, to the host
//!   exempt-no-caps          the same, with no network capability
//!   exempt-inbound          from the host to the exempt container
//!   exempt-unset            taking the exemption back, as `exempt-set`
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

const profiles = [_][]const u8{ "zigsaw.test.netprobe.a", "zigsaw.test.netprobe.b", "zigsaw.test.netprobe.c" };
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
        const temp = init.environ_map.get("TEMP") orelse return error.NoTemp;
        try report(arena, init.io, temp, out);
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
    if (std.mem.eql(u8, mode, "wait") and args.len == 3) {
        win32.Sleep(try std.fmt.parseInt(DWORD, args[2], 10));
        return 0;
    }
    // The report's endpoints, which exit with 0 for a round trip, or a
    // Winsock error.
    if (args.len == 3 and std.mem.eql(u8, mode, "_listen")) return exitCode(listenAndPong(try port(args[2])));
    if (args.len == 3 and std.mem.eql(u8, mode, "_connect")) return exitCode(connectAndPing(.loopback(.ipv4, try port(args[2]))));
    if (args.len == 3 and std.mem.eql(u8, mode, "_accept")) return exitCode(acceptAndPong(try socket(args[2]), 2 * timeout_ms));
    if (args.len == 3 and std.mem.eql(u8, mode, "_ping")) return exitCode(ping(try socket(args[2])));
    if (args.len == 4 and std.mem.eql(u8, mode, "_connect-socket")) return exitCode(connectSocket(try socket(args[2]), try port(args[3])));
    if (args.len == 3 and std.mem.eql(u8, mode, "_unix-listen")) return exitCode(unixListenAndPong(args[2]));
    if (args.len == 3 and std.mem.eql(u8, mode, "_unix-connect")) return exitCode(unixConnectAndPing(args[2]));
    return usage();
}

fn usage() u8 {
    std.debug.print("usage: zigsaw-netprobe report | serve <port> | ping <port> | env <name>... | wait <ms>\n", .{});
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

/// An AF_UNIX socket bound at `path` and listening, or the error.
fn unixListenAndPong(path: []const u8) c_int {
    const address = unixAddress(path) orelse return win32.WSAEINVAL;
    const s = win32.WSASocketW(win32.AF_UNIX, win32.SOCK_STREAM, 0, null, 0, 0);
    if (s == win32.INVALID_SOCKET) return win32.WSAGetLastError();
    defer _ = win32.closesocket(s);
    if (win32.bind(s, &address, @sizeOf(win32.sockaddr_un)) != 0) return win32.WSAGetLastError();
    if (win32.listen(s, 1) != 0) return win32.WSAGetLastError();
    return acceptAndPong(s, 2 * timeout_ms);
}

fn unixConnectAndPing(path: []const u8) c_int {
    const address = unixAddress(path) orelse return win32.WSAEINVAL;
    const s = win32.WSASocketW(win32.AF_UNIX, win32.SOCK_STREAM, 0, null, 0, 0);
    if (s == win32.INVALID_SOCKET) return win32.WSAGetLastError();
    defer _ = win32.closesocket(s);
    if (win32.connect(s, &address, @sizeOf(win32.sockaddr_un)) != 0) return win32.WSAGetLastError();
    return ping(s);
}

/// `path` as an address; null if it doesn't fit, NUL or not.
fn unixAddress(path: []const u8) ?win32.sockaddr_un {
    var a: win32.sockaddr_un = .{};
    if (path.len > a.path.len) return null;
    @memcpy(a.path[0..path.len], path);
    return a;
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
    /// The host's user at low integrity, as `--sandbox=low` runs.
    low,
    container: struct { profile: usize, network: bool },
};

fn report(arena: std.mem.Allocator, io: std.Io, temp: []const u8, out: *std.Io.Writer) !void {
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
    const ctx: Spawner = .{ .arena = arena, .sids = &sids, .network_caps = &caps, .low_token = try lowToken(arena) };

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
    // A directory it couldn't make or grant leaves out the rows after, not
    // the report's others.
    unixRows(ctx, io, temp, out) catch |err| try out.print("unix rows stopped: {t}\n", .{err});
    try out.flush();
    try exemptRows(ctx, io, out);
    try out.flush();
    try profileRace(arena, out);
}

/// The AF_UNIX rows, in directories under `temp` that it deletes after.
fn unixRows(s: Spawner, io: std.Io, temp: []const u8, out: *std.Io.Writer) !void {
    const base = try std.fmt.allocPrint(s.arena, "{s}\\zigsaw-netprobe-unix", .{temp});
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try makeDir(s.arena, base);
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    const a: Where = .{ .container = .{ .profile = 0, .network = false } };
    const b: Where = .{ .container = .{ .profile = 1, .network = false } };
    const modify = win32.FILE_MODIFY | win32.FILE_GENERIC_READ_EXECUTE;
    const read = win32.FILE_GENERIC_READ_EXECUTE;

    try out.print("unix-host-to-container {f}\n", .{try s.unixPair(try s.unixDir(base, "1", &.{.{ 0, modify }}, false), .host, a)});
    try out.print("unix-container-to-host {f}\n", .{try s.unixPair(try s.unixDir(base, "2", &.{.{ 0, modify }}, false), a, .host)});
    try out.print("unix-container-to-container {f}\n", .{try s.unixPair(try s.unixDir(base, "3", &.{ .{ 0, modify }, .{ 1, modify } }, false), a, b)});
    try out.print("unix-not-granted {f}\n", .{try s.unixPair(try s.unixDir(base, "4", &.{.{ 0, modify }}, false), a, b)});
    try out.print("unix-read-only {f}\n", .{try s.unixPair(try s.unixDir(base, "5", &.{ .{ 0, modify }, .{ 1, read } }, false), a, b)});
    try out.print("unix-low-to-host {f}\n", .{try s.unixPair(try s.unixDir(base, "6", &.{}, false), .host, .low)});
    try out.print("unix-host-to-low {f}\n", .{try s.unixPair(try s.unixDir(base, "7", &.{}, true), .low, .host)});
    const dir = try s.unixDir(base, "8", &.{}, false);
    for ([_]usize{ 107, 108 }) |len| {
        // `<dir>\` and a name of x's, `len` bytes in all.
        if (dir.len + 2 > len) {
            try out.print("unix-path-{d} not tried: TEMP is too long\n", .{len});
            continue;
        }
        const name = try s.arena.alloc(u8, len - dir.len - 1);
        @memset(name, 'x');
        const at = try std.fmt.allocPrint(s.arena, "{s}\\{s}", .{ dir, name });
        const outcome = try s.unixPairAt(at, .host, .host);
        try out.print("unix-path-{d} {f}\n", .{ len, outcome });
    }
}

fn makeDir(arena: std.mem.Allocator, path: []const u8) !void {
    if (win32.CreateDirectoryW(try win32.wide(arena, path), null) == 0) return error.MakeDir;
}

/// Adds an allow ACE for `sid` to `path`'s DACL, which the directory's
/// files and subdirectories inherit.
fn grant(arena: std.mem.Allocator, path: []const u8, sid: win32.PSID, access: DWORD) !void {
    const path_w = try win32.wide(arena, path);
    var sd: ?*anyopaque = null;
    var dacl: ?*win32.ACL = null;
    if (win32.GetNamedSecurityInfoW(path_w, win32.SE_FILE_OBJECT, win32.DACL_SECURITY_INFORMATION, null, null, &dacl, null, &sd) != 0) return error.Acl;
    defer _ = win32.LocalFree(sd);
    var entries = [1]win32.EXPLICIT_ACCESS_W{.{
        .grfAccessPermissions = access,
        .grfAccessMode = win32.GRANT_ACCESS,
        .grfInheritance = win32.SUB_CONTAINERS_AND_OBJECTS_INHERIT,
        .Trustee = .{ .ptstrName = sid },
    }};
    var new: ?*win32.ACL = null;
    if (win32.SetEntriesInAclW(1, &entries, dacl, &new) != 0) return error.Acl;
    defer _ = win32.LocalFree(new);
    if (win32.SetNamedSecurityInfoW(path_w, win32.SE_FILE_OBJECT, win32.DACL_SECURITY_INFORMATION, null, null, new, null) != 0) return error.Acl;
}

/// Labels `path` low integrity, with NO_WRITE_UP, as `--sandbox=low` labels
/// a writable grant; what's made in it inherits the label.
fn labelLow(arena: std.mem.Allocator, path: []const u8) !void {
    var low: ?win32.PSID = null;
    if (win32.ConvertStringSidToSidW(try win32.wide(arena, win32.low_integrity_sid), &low) == 0) return error.BadSid;
    const size = @sizeOf(win32.ACL) + @sizeOf(win32.ACCESS_ALLOWED_ACE) + win32.GetLengthSid(low.?);
    const buf = try arena.alignedAlloc(u8, .of(u64), size);
    const sacl: *win32.ACL = @ptrCast(buf.ptr);
    if (win32.InitializeAcl(sacl, @intCast(size), win32.ACL_REVISION) == 0) return error.Acl;
    const inherit = win32.OBJECT_INHERIT_ACE | win32.CONTAINER_INHERIT_ACE;
    if (win32.AddMandatoryAce(sacl, win32.ACL_REVISION, inherit, win32.SYSTEM_MANDATORY_LABEL_NO_WRITE_UP, low.?) == 0) return error.Acl;
    if (win32.SetNamedSecurityInfoW(try win32.wide(arena, path), win32.SE_FILE_OBJECT, win32.LABEL_SECURITY_INFORMATION, null, null, null, sacl) != 0) return error.Acl;
}

/// A copy of our token at low integrity, as process.zig's
/// lowIntegrityToken makes for `--sandbox=low`.
fn lowToken(arena: std.mem.Allocator) !win32.HANDLE {
    var own: ?win32.HANDLE = null;
    const access = win32.TOKEN_ASSIGN_PRIMARY | win32.TOKEN_DUPLICATE | win32.TOKEN_QUERY | win32.TOKEN_ADJUST_DEFAULT;
    if (win32.OpenProcessToken(win32.GetCurrentProcess(), access, &own) == 0) return error.Token;
    defer _ = win32.CloseHandle(own.?);
    var low: ?win32.HANDLE = null;
    if (win32.DuplicateTokenEx(own.?, 0, null, win32.SecurityImpersonation, win32.TokenPrimary, &low) == 0) return error.Token;
    var sid: ?win32.PSID = null;
    if (win32.ConvertStringSidToSidW(try win32.wide(arena, win32.low_integrity_sid), &sid) == 0) return error.BadSid;
    const label: win32.TOKEN_MANDATORY_LABEL = .{ .Label = .{ .Sid = sid.?, .Attributes = win32.SE_GROUP_INTEGRITY } };
    if (win32.SetTokenInformation(low.?, win32.TokenIntegrityLevel, &label, @sizeOf(win32.TOKEN_MANDATORY_LABEL) + win32.GetLengthSid(sid.?)) == 0)
        return error.Token;
    return low.?;
}

/// The loopback exemption's rows, on container c, which ends as it started:
/// not exempt.
fn exemptRows(s: Spawner, io: std.Io, out: *std.Io.Writer) !void {
    const sid = s.sids[2];
    var start = std.Io.Timestamp.now(io, .awake);
    const set = setExempt(s.arena, sid, true);
    if (set != 0) {
        try out.print("exempt-set refused {d}\n", .{set});
        return;
    }
    try out.print("exempt-set ok {d} ms\n", .{start.untilNow(io, .awake).toMilliseconds()});
    var unset_done = false;
    defer if (!unset_done) {
        _ = setExempt(s.arena, sid, false);
    };
    try out.flush();
    const c: Where = .{ .container = .{ .profile = 2, .network = false } };
    const c_net: Where = .{ .container = .{ .profile = 2, .network = true } };
    try out.print("exempt-to-host {f}\n", .{try s.pair(.host, c_net)});
    try out.print("exempt-no-caps {f}\n", .{try s.pair(.host, c)});
    try out.print("exempt-inbound {f}\n", .{try s.pair(c_net, .host)});
    start = std.Io.Timestamp.now(io, .awake);
    const unset = setExempt(s.arena, sid, false);
    unset_done = true;
    if (unset != 0)
        try out.print("exempt-unset refused {d}\n", .{unset})
    else
        try out.print("exempt-unset ok {d} ms\n", .{start.untilNow(io, .awake).toMilliseconds()});
}

/// Adds `sid` to the exempt containers, or takes it out, keeping the rest:
/// 0, or the Win32 error.
fn setExempt(arena: std.mem.Allocator, sid: win32.PSID, on: bool) DWORD {
    var count: DWORD = 0;
    var list: ?[*]win32.SID_AND_ATTRIBUTES = null;
    const got = win32.NetworkIsolationGetAppContainerConfig(&count, &list);
    if (got != 0) return got;
    var next: std.ArrayList(win32.SID_AND_ATTRIBUTES) = .empty;
    if (list) |l| for (l[0..count]) |e| if (win32.EqualSid(e.Sid, sid) == 0) next.append(arena, e) catch return 8;
    if (on) next.append(arena, .{ .Sid = sid, .Attributes = 0 }) catch return 8;
    return win32.NetworkIsolationSetAppContainerConfig(@intCast(next.items.len), if (next.items.len > 0) next.items.ptr else null);
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
    low_token: win32.HANDLE,

    /// A container's profile, and what it's granted.
    const Grant = struct { usize, DWORD };

    /// `<base>\<name>`, made with `grants` for the profiles' containers, and
    /// labelled low if `low`.
    fn unixDir(s: Spawner, base: []const u8, name: []const u8, grants: []const Grant, low: bool) ![]const u8 {
        const dir = try std.fmt.allocPrint(s.arena, "{s}\\{s}", .{ base, name });
        try makeDir(s.arena, dir);
        for (grants) |g| try grant(s.arena, dir, s.sids[g[0]], g[1]);
        if (low) try labelLow(s.arena, dir);
        return dir;
    }

    /// An AF_UNIX listener and connector, on a socket in `dir`.
    fn unixPair(s: Spawner, dir: []const u8, listener_at: Where, connector_at: Where) !Outcome {
        return s.unixPairAt(try std.fmt.allocPrint(s.arena, "{s}\\s", .{dir}), listener_at, connector_at);
    }

    fn unixPairAt(s: Spawner, path: []const u8, listener_at: Where, connector_at: Where) !Outcome {
        const listener = try s.spawn(listener_at, null, try std.fmt.allocPrint(s.arena, "_unix-listen \"{s}\"", .{path}));
        win32.Sleep(500);
        const connector = try s.spawn(connector_at, null, try std.fmt.allocPrint(s.arena, "_unix-connect \"{s}\"", .{path}));
        const code = finish(connector, 3 * timeout_ms);
        _ = finish(listener, if (code == 0) timeout_ms else 0);
        return .{ .code = code };
    }

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

    /// Starts this program with `args`, on the host, at low integrity or in
    /// a container, with `inherit` as its only inherited handle.
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
            .host, .low => {},
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
        const inherits = @intFromBool(inherit != null);
        const started = if (at == .low)
            win32.CreateProcessAsUserW(s.low_token, null, command_line.ptr, null, null, inherits, win32.EXTENDED_STARTUPINFO_PRESENT, null, null, &startup.StartupInfo, &info)
        else
            win32.CreateProcessW(null, command_line.ptr, null, null, inherits, win32.EXTENDED_STARTUPINFO_PRESENT, null, null, &startup.StartupInfo, &info);
        if (started == 0) {
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
