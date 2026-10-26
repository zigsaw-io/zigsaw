//! Services: what an app serves to other programs on this machine, which
//! its config declares (oci.Service), and how its runs publish them.
//!
//! Under `soft` and `low`, the app listens on each service's port itself:
//! ${listen:<name>} and ${port:<name>} are both that port, the config's or
//! the one --port gives.
//!
//! Nothing outside an AppContainer can connect into it, but runs in one
//! container reach each other on the loopback (docs/networking.md). So under
//! `appcontainer`, ${listen:<name>} is an internal port of the app's, picked
//! once and kept in <root>\ports\<id>.txt so that all its runs agree, and a
//! run of the command that serves the service publishes it: zigsaw listens
//! on its port, on 127.0.0.1 and ::1, outside the container, and hands those
//! sockets to the relay (relay.zig), which it starts in the app's container
//! and job. Services are on the loopback only.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");
const net = @import("net.zig");
const oci = @import("oci.zig");
const override = @import("override.zig");
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const fail = Context.fail;
const note = Context.note;

/// A service's ports for a run.
pub const Ports = struct {
    service: oci.Service,
    /// Where other programs reach it.
    port: u16,
    /// Where the app listens, and its own runs connect.
    listen: u16,
};

/// The app's services and their ports, for a run in `sandbox` with
/// `moved` ("NAME=PORT", from --port and overrides).
pub fn resolve(ctx: *Context, cfg: oci.AppConfig, moved: []const []const u8, sandbox: override.Sandbox) ![]const Ports {
    const arena = ctx.arena;
    const services = cfg.permissions.services orelse &.{};
    for (moved) |m| {
        const p = override.parsePort(m) orelse return fail("--port expects <service>=<port>; got \"{s}\"", .{m});
        for (services) |s| {
            if (std.mem.eql(u8, s.name, p.name)) break;
        } else return fail("--port={s}: {s} has no service \"{s}\"{s}", .{ m, cfg.id, p.name, try namesOf(arena, services) });
    }
    const out = try arena.alloc(Ports, services.len);
    for (out, services) |*o, s| {
        var port = s.port;
        for (moved) |m| {
            const p = override.parsePort(m).?;
            if (std.mem.eql(u8, p.name, s.name)) port = p.port;
        }
        o.* = .{ .service = s, .port = port, .listen = port };
    }
    if (sandbox == .appcontainer and out.len > 0) {
        const internal = try internalPorts(ctx, cfg.id, out);
        for (out, internal) |*o, p| o.listen = p;
    }
    return out;
}

fn namesOf(arena: Allocator, services: []const oci.Service) ![]const u8 {
    if (services.len == 0) return "; it has none";
    const names = try arena.alloc([]const u8, services.len);
    for (names, services) |*n, s| n.* = s.name;
    return std.fmt.allocPrint(arena, "; it has {s}", .{try oci.joinAnd(arena, names)});
}

/// What the app's placeholders say for them.
pub fn placeholders(arena: Allocator, ports: []const Ports) ![]const oci.Placeholders.ServicePorts {
    const out = try arena.alloc(oci.Placeholders.ServicePorts, ports.len);
    for (out, ports) |*o, p| o.* = .{
        .name = p.service.name,
        .listen = try std.fmt.allocPrint(arena, "{d}", .{p.listen}),
        .port = try std.fmt.allocPrint(arena, "{d}", .{p.port}),
    };
    return out;
}

/// Whether a run of `command` (an export; null for the app's own command)
/// serves `s`. A service's export and the app's own command are one if
/// they run the same program with the same arguments, as PostgreSQL's
/// `postgresql` and its command do.
pub fn serves(cfg: oci.AppConfig, s: oci.Service, command: ?[]const u8) bool {
    const run = entry(cfg, command) orelse return false;
    const serving = entry(cfg, s.command) orelse return false;
    if (!std.mem.eql(u8, run.command, serving.command) or run.args.len != serving.args.len) return false;
    for (run.args, serving.args) |a, b| if (!std.mem.eql(u8, a, b)) return false;
    return true;
}

const Entry = struct { command: []const u8, args: []const []const u8 };

/// What a run of `command` runs: the app's command, an export, or (null)
/// something else from the app, which serves nothing.
fn entry(cfg: oci.AppConfig, command: ?[]const u8) ?Entry {
    const name = command orelse return .{ .command = cfg.command, .args = cfg.args };
    var it = cfg.exports.map.iterator();
    while (it.next()) |e| if (std.ascii.eqlIgnoreCase(e.key_ptr.*, name))
        return .{ .command = e.value_ptr.command, .args = e.value_ptr.args };
    return null;
}

// ---------------------------------------------------------------------------
// Internal ports

/// Where the app's internal ports are kept.
pub fn portsPath(store: Store, arena: Allocator, id: []const u8) ![]u8 {
    return store.path(arena, &.{ "ports", try std.fmt.allocPrint(arena, "{s}.txt", .{id}) });
}

/// The app's internal port for each of `ports`' services: those kept, and
/// new ones for the rest, which are kept from then on. Kept as lines of
/// "<name> <port>".
fn internalPorts(ctx: *Context, id: []const u8, ports: []const Ports) ![]const u16 {
    const io = ctx.io;
    const arena = ctx.arena;
    const p = try portsPath(ctx.store, arena, id);
    const lock = try Store.openLock(io, try Store.lockPathFor(arena, p), .exclusive, .wait);
    defer lock.release(io);
    const text = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => |e| return e,
    };
    var kept = try parseKept(arena, text);
    const out = try arena.alloc(u16, ports.len);
    var picked = false;
    for (out, ports) |*o, s| {
        o.* = for (kept.items) |k| {
            if (std.mem.eql(u8, k.name, s.service.name)) break k.port;
        } else port: {
            const new = try pick(ctx, kept.items, ports);
            try kept.append(arena, .{ .name = s.service.name, .port = new });
            picked = true;
            break :port new;
        };
    }
    if (picked) {
        var lines: std.ArrayList(u8) = .empty;
        for (kept.items) |k| try lines.print(arena, "{s} {d}\n", .{ k.name, k.port });
        const tmp = try ctx.store.tmpPath(arena, "ports");
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = lines.items });
        try Io.Dir.rename(.cwd(), tmp, .cwd(), p, io);
    }
    return out;
}

const Kept = struct { name: []const u8, port: u16 };

fn parseKept(arena: Allocator, text: []const u8) !std.ArrayList(Kept) {
    var kept: std.ArrayList(Kept) = .empty;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const port = std.fmt.parseInt(u16, line[space + 1 ..], 10) catch continue;
        if (port == 0) continue;
        try kept.append(arena, .{ .name = line[0..space], .port = port });
    }
    return kept;
}

/// Internal ports come from below Windows' dynamic range (49152 up), which
/// outgoing connections take theirs from, and above most fixed ones.
const internal_first = 20000;
const internal_count = 29000;

/// A port that's free now, and none of the app's others.
fn pick(ctx: *Context, kept: []const Kept, ports: []const Ports) !u16 {
    net.startup() catch return fail("Windows' sockets aren't available", .{});
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        var random: [4]u8 = undefined;
        ctx.io.random(&random);
        const candidate: u16 = @intCast(internal_first + std.mem.readInt(u32, &random, .little) % internal_count);
        if (isTaken(candidate, kept, ports)) continue;
        if (!isFree(candidate)) continue;
        return candidate;
    }
    return fail("found no free port for the app's services", .{});
}

fn isTaken(candidate: u16, kept: []const Kept, ports: []const Ports) bool {
    for (kept) |k| if (k.port == candidate) return true;
    for (ports) |p| if (p.port == candidate) return true;
    return false;
}

fn isFree(port: u16) bool {
    for ([_]net.Family{ .ipv4, .ipv6 }) |family| switch (net.listen(.loopback(family, port))) {
        .socket => |s| _ = win32.closesocket(s),
        .failed => |code| if (code == win32.WSAEADDRINUSE or code == win32.WSAEACCES) return false,
    };
    return true;
}

test parseKept {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const kept = try parseKept(arena_state.allocator(), "http 23817\r\nbad\nadmin 0\ndb 30001\n");
    try std.testing.expectEqual(2, kept.items.len);
    try std.testing.expectEqualStrings("http", kept.items[0].name);
    try std.testing.expectEqual(23817, kept.items[0].port);
    try std.testing.expectEqual(30001, kept.items[1].port);
}

// ---------------------------------------------------------------------------
// Publishing, under appcontainer

/// The listening sockets a run hands to the relay.
pub const Published = struct {
    sockets: []const win32.SOCKET,
    /// The relay's arguments: "<socket>=<internal port>" for each.
    args: []const []const u8,

    pub fn close(p: Published) void {
        for (p.sockets) |s| _ = win32.closesocket(s);
    }
};

/// Listens on the published ports of the services that a run of `command`
/// serves, on 127.0.0.1 and ::1. A port that's taken is left out, saying so;
/// null if nothing is published.
pub fn publish(ctx: *Context, cfg: oci.AppConfig, ports: []const Ports, command: ?[]const u8) !?Published {
    const arena = ctx.arena;
    var sockets: std.ArrayList(win32.SOCKET) = .empty;
    var args: std.ArrayList([]const u8) = .empty;
    for (ports) |p| {
        if (!serves(cfg, p.service, command)) continue;
        net.startup() catch return fail("Windows' sockets aren't available", .{});
        const before = sockets.items.len;
        for ([_]net.Family{ .ipv4, .ipv6 }) |family| switch (net.listen(.loopback(family, p.port))) {
            .socket => |s| {
                try sockets.append(arena, s);
                try args.append(arena, try std.fmt.allocPrint(arena, "{d}={d}", .{ s, p.listen }));
            },
            .failed => |code| {
                // A machine without IPv6 has no ::1.
                if (family == .ipv6 and (code == win32.WSAEAFNOSUPPORT or code == win32.WSAEADDRNOTAVAIL)) continue;
                if (code == win32.WSAEADDRINUSE or code == win32.WSAEACCES)
                    note("note: port {d} is taken, so {s} isn't published this run", .{ p.port, p.service.name })
                else
                    note("note: can't listen on port {d}, so {s} isn't published this run: Winsock error {d}", .{ p.port, p.service.name, code });
                // Both addresses or neither: `localhost` is either.
                for (sockets.items[before..]) |s| _ = win32.closesocket(s);
                sockets.shrinkRetainingCapacity(before);
                args.shrinkRetainingCapacity(before);
                break;
            },
        };
    }
    if (sockets.items.len == 0) return null;
    return .{ .sockets = sockets.items, .args = args.items };
}

/// The relay's copy in the store, which AppContainers are granted. It's
/// named by its contents, so a relay that's running is never replaced.
pub fn relayExe(ctx: *Context) ![]const u8 {
    const io = ctx.io;
    const arena = ctx.arena;
    const relay = try installedRelay(ctx);
    const dest = try ctx.store.path(arena, &.{ "relay", relay.name });
    if (try Store.exists(io, dest)) return dest;
    const tmp = try ctx.store.tmpPath(arena, "relay");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = relay.bytes });
    Io.Dir.rename(.cwd(), tmp, .cwd(), dest, io) catch |err| {
        // Another run put it there first.
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        if (!try Store.exists(io, dest)) return err;
    };
    return dest;
}

/// The relay next to zigsaw.exe, and the name of its copy in the store.
fn installedRelay(ctx: *Context) !struct { bytes: []const u8, name: []const u8 } {
    const arena = ctx.arena;
    const zigsaw = try win32.selfExePath(arena);
    const src = try std.fs.path.join(arena, &.{ std.fs.path.dirname(zigsaw).?, "zigsaw-relay.exe" });
    const bytes = Io.Dir.cwd().readFileAlloc(ctx.io, src, arena, .limited(16 << 20)) catch |err|
        return fail("reading {s}, which should be installed next to zigsaw.exe: {t}", .{ src, err });
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return .{ .bytes = bytes, .name = try std.fmt.allocPrint(arena, "zigsaw-relay-{x}.exe", .{hash[0..8]}) };
}

/// Deletes the store's copies of relays other than this zigsaw's, except
/// those running, and the internal ports of apps that aren't installed,
/// as `prune` does.
pub fn prune(ctx: *Context, installed: []const []const u8) !void {
    const io = ctx.io;
    const arena = ctx.arena;
    const current = (installedRelay(ctx) catch null);
    var relays = try Io.Dir.cwd().openDir(io, try ctx.store.path(arena, &.{"relay"}), .{ .iterate = true });
    defer relays.close(io);
    var it = relays.iterate();
    var stale: std.ArrayList([]const u8) = .empty;
    while (try it.next(io)) |e| {
        if (current) |c| if (std.mem.eql(u8, e.name, c.name)) continue;
        try stale.append(arena, try arena.dupe(u8, e.name));
    }
    for (stale.items) |name| relays.deleteFile(io, name) catch {};

    var ports = try Io.Dir.cwd().openDir(io, try ctx.store.path(arena, &.{"ports"}), .{ .iterate = true });
    defer ports.close(io);
    var pit = ports.iterate();
    var orphans: std.ArrayList([]const u8) = .empty;
    while (try pit.next(io)) |e| {
        const id = if (std.mem.endsWith(u8, e.name, ".txt.lock"))
            e.name[0 .. e.name.len - ".txt.lock".len]
        else if (std.mem.endsWith(u8, e.name, ".txt"))
            e.name[0 .. e.name.len - ".txt".len]
        else
            continue;
        for (installed) |i| {
            if (std.mem.eql(u8, i, id)) break;
        } else try orphans.append(arena, try arena.dupe(u8, e.name));
    }
    for (orphans.items) |name| ports.deleteFile(io, name) catch {};
}

/// Forgets the app's internal ports, as `rm` does: a later install picks
/// new ones.
pub fn forget(store: Store, arena: Allocator, id: []const u8) !void {
    Io.Dir.cwd().deleteFile(store.io, try portsPath(store, arena, id)) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
}

test serves {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cfg: oci.AppConfig = .{ .id = "app", .version = "1", .command = "bin/server.exe" };
    try cfg.exports.map.put(arena, "server", .{ .command = "bin/server.exe" });
    try cfg.exports.map.put(arena, "client", .{ .command = "bin/client.exe" });
    try cfg.exports.map.put(arena, "verbose-server", .{ .command = "bin/server.exe", .args = &.{"-v"} });
    const by_export: oci.Service = .{ .name = "db", .port = 5432, .command = "server" };
    // Its export, under any case, and the app's own command, which is the same.
    try std.testing.expect(serves(cfg, by_export, "server"));
    try std.testing.expect(serves(cfg, by_export, "Server"));
    try std.testing.expect(serves(cfg, by_export, null));
    // Other exports, and what isn't one, don't.
    try std.testing.expect(!serves(cfg, by_export, "client"));
    try std.testing.expect(!serves(cfg, by_export, "verbose-server"));
    try std.testing.expect(!serves(cfg, by_export, "bin/server.exe"));
    // Without an export, the app's own command serves it.
    const by_app: oci.Service = .{ .name = "db", .port = 5432 };
    try std.testing.expect(serves(cfg, by_app, null));
    try std.testing.expect(serves(cfg, by_app, "server"));
    try std.testing.expect(!serves(cfg, by_app, "client"));
}
