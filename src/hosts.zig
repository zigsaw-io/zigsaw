//! Allow lists: the hosts an app with a list may reach, and nothing else
//! (docs/networking.md). A run with one holds no network capability; its
//! relay is an HTTP proxy, and zigsaw connects for it only to what the list
//! names (see proxy.zig).
//!
//! A pattern is one of:
//!
//!   example.org         that name
//!   *.example.org       any name under it, not example.org itself
//!   192.0.2.7           that IPv4 address
//!   [2001:db8::7]       that IPv6 address
//!
//! each with an optional `:<port>`. Without one, ports 443 and 80. Names are
//! ASCII (an IDN in its xn-- form), matched without regard to case or a
//! trailing dot.

const std = @import("std");

pub const Pattern = struct {
    host: Host,
    /// Null for 443 and 80.
    port: ?u16,

    pub const Host = union(enum) {
        /// Lowercase, without a trailing dot: borrowed from the text when it
        /// already is, so only `parse`'s caller's buffer holds it.
        name: []const u8,
        /// What follows "*.".
        suffix: []const u8,
        ip4: [4]u8,
        ip6: [16]u8,
    };

    pub fn allowsPort(p: Pattern, port: u16) bool {
        return if (p.port) |want| want == port else port == 443 or port == 80;
    }
};

/// The pattern `text` says, or null if it isn't one. Names keep the case
/// they're given in; matching ignores it.
pub fn parse(text: []const u8) ?Pattern {
    if (text.len == 0 or text.len > 300) return null;
    var host = text;
    var port: ?u16 = null;
    if (host[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host, ']') orelse return null;
        const rest = host[close + 1 ..];
        if (rest.len > 0) {
            if (rest[0] != ':') return null;
            port = parsePort(rest[1..]) orelse return null;
        }
        const ip6 = parseIp6(host[1..close]) orelse return null;
        return .{ .host = .{ .ip6 = ip6 }, .port = port };
    }
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
        port = parsePort(host[colon + 1 ..]) orelse return null;
        host = host[0..colon];
    }
    if (parseIp4(host)) |ip4| return .{ .host = .{ .ip4 = ip4 }, .port = port };
    if (std.mem.startsWith(u8, host, "*.")) {
        const suffix = trimDot(host[2..]);
        if (!isName(suffix) or std.mem.indexOfScalar(u8, suffix, '.') == null) return null;
        return .{ .host = .{ .suffix = suffix }, .port = port };
    }
    const name = trimDot(host);
    if (!isName(name)) return null;
    return .{ .host = .{ .name = name }, .port = port };
}

fn trimDot(name: []const u8) []const u8 {
    return if (name.len > 1 and name[name.len - 1] == '.') name[0 .. name.len - 1] else name;
}

fn parsePort(digits: []const u8) ?u16 {
    if (digits.len == 0 or digits.len > 5) return null;
    for (digits) |c| if (c < '0' or c > '9') return null;
    const p = std.fmt.parseInt(u16, digits, 10) catch return null;
    return if (p == 0) null else p;
}

/// Labels of letters, digits, '-' and '_', 1 to 63 bytes, not starting or
/// ending with '-'; 253 bytes at most; not all digits and dots (an address
/// that didn't parse as one).
fn isName(name: []const u8) bool {
    if (name.len == 0 or name.len > 253) return false;
    var labels = std.mem.splitScalar(u8, name, '.');
    var all_digits = true;
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63) return false;
        if (label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |c| switch (c) {
            'a'...'z', 'A'...'Z', '-', '_' => all_digits = false,
            '0'...'9' => {},
            else => return false,
        };
    }
    return !all_digits;
}

pub fn parseIp4(text: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, text, '.');
    var i: usize = 0;
    while (parts.next()) |part| : (i += 1) {
        if (i == 4 or part.len == 0 or part.len > 3) return null;
        for (part) |c| if (c < '0' or c > '9') return null;
        // No leading zeros: "010" is octal to some parsers.
        if (part.len > 1 and part[0] == '0') return null;
        out[i] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    return if (i == 4) out else null;
}

pub fn parseIp6(text: []const u8) ?[16]u8 {
    const addr = std.Io.net.Ip6Address.parse(text, 0) catch return null;
    // No zone: an allow list names addresses, not interfaces.
    if (std.mem.indexOfScalar(u8, text, '%') != null) return null;
    return addr.bytes;
}

/// The host a request names, as `matches` takes it: a name, or an address,
/// with or without brackets.
pub const Target = union(enum) {
    name: []const u8,
    ip4: [4]u8,
    ip6: [16]u8,

    pub fn of(host: []const u8) ?Target {
        if (host.len > 2 and host[0] == '[' and host[host.len - 1] == ']')
            return .{ .ip6 = parseIp6(host[1 .. host.len - 1]) orelse return null };
        if (parseIp4(host)) |ip4| return .{ .ip4 = ip4 };
        if (parseIp6(host)) |ip6| return .{ .ip6 = ip6 };
        const name = trimDot(host);
        return if (isName(name)) .{ .name = name } else null;
    }
};

pub fn matches(p: Pattern, target: Target, port: u16) bool {
    if (!p.allowsPort(port)) return false;
    return switch (p.host) {
        .name => |want| target == .name and std.ascii.eqlIgnoreCase(target.name, want),
        .suffix => |suffix| target == .name and isUnder(target.name, suffix),
        .ip4 => |want| target == .ip4 and std.mem.eql(u8, &target.ip4, &want),
        .ip6 => |want| target == .ip6 and std.mem.eql(u8, &target.ip6, &want),
    };
}

/// Whether `name` is a name under `suffix`, not `suffix` itself.
fn isUnder(name: []const u8, suffix: []const u8) bool {
    if (name.len <= suffix.len + 1) return false;
    const tail = name[name.len - suffix.len ..];
    return name[name.len - suffix.len - 1] == '.' and std.ascii.eqlIgnoreCase(tail, suffix);
}

/// Whether one of `list`'s patterns lets a run reach `host` on `port`.
/// Patterns that don't parse allow nothing.
pub fn allows(list: []const []const u8, host: []const u8, port: u16) bool {
    const target = Target.of(host) orelse return false;
    for (list) |text| if (parse(text)) |p| if (matches(p, target, port)) return true;
    return false;
}

/// Whether `list` names `target` as an address, rather than by a name that
/// resolves to it: the only way a run with a list reaches this machine's
/// loopback through the proxy (see proxy.zig).
pub fn namesAddress(list: []const []const u8, address: Target, port: u16) bool {
    if (address == .name) return false;
    for (list) |text| if (parse(text)) |p| if (p.host != .name and p.host != .suffix and matches(p, address, port)) return true;
    return false;
}

/// Whether `had` lets a run reach all `want` does, for what an update asks
/// about: a name under a suffix, or a port among 443 and 80, counts as had.
pub fn covers(had: Pattern, want: Pattern) bool {
    const ports_ok = if (want.port) |p| had.allowsPort(p) else had.port == null;
    if (!ports_ok) return false;
    return switch (want.host) {
        .name => |n| switch (had.host) {
            .name => |h| std.ascii.eqlIgnoreCase(h, n),
            .suffix => |s| isUnder(n, s),
            else => false,
        },
        .suffix => |n| switch (had.host) {
            .suffix => |s| std.ascii.eqlIgnoreCase(n, s) or isUnder(n, s),
            else => false,
        },
        .ip4 => |a| had.host == .ip4 and std.mem.eql(u8, &had.host.ip4, &a),
        .ip6 => |a| had.host == .ip6 and std.mem.eql(u8, &had.host.ip6, &a),
    };
}

/// The patterns of `after` that `before`'s don't cover.
pub fn added(arena: std.mem.Allocator, before: []const []const u8, after: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (after) |text| {
        const want = parse(text) orelse continue;
        const had = for (before) |b| {
            const p = parse(b) orelse continue;
            if (covers(p, want)) break true;
        } else false;
        if (!had) try out.append(arena, text);
    }
    return out.items;
}

pub const invalid_message = "must be a host name, *.<domain>, an IPv4 address or an [IPv6] one, with an optional :<port>";

test parse {
    const t = std.testing;
    try t.expectEqualStrings("example.org", parse("example.org").?.host.name);
    try t.expectEqual(null, parse("example.org").?.port);
    try t.expectEqualStrings("Example.ORG", parse("Example.ORG.").?.host.name);
    try t.expectEqual(@as(u16, 8443), parse("api.example.org:8443").?.port.?);
    try t.expectEqualStrings("example.org", parse("*.example.org").?.host.suffix);
    try t.expectEqualSlices(u8, &.{ 192, 0, 2, 7 }, &parse("192.0.2.7:5432").?.host.ip4);
    try t.expectEqual(@as(u16, 443), parse("[2001:db8::7]:443").?.port.?);
    try t.expectEqual(@as(u8, 7), parse("[2001:db8::7]").?.host.ip6[15]);
    try t.expectEqualStrings("localhost", parse("localhost").?.host.name);
    for ([_][]const u8{
        "",           "*",              "*.org",          "**.example.org", "a.*.example.org", "example.org:0",
        "example.org:65536", "example.org:", "-a.example.org", "a-.example.org", "ex ample.org",   "exämple.org",
        "1.2.3",      "1.2.3.4.5",      "01.2.3.4",       "256.1.1.1",      "[::1",            "[::1]x",
        "[fe80::1%3]", "http://example.org", "example.org/path", "user@example.org", "a..b",
    }) |bad| if (parse(bad) != null) {
        std.debug.print("parsed: {s}\n", .{bad});
        return error.TestUnexpectedResult;
    };
}

test allows {
    const list = [_][]const u8{ "api.github.com", "*.npmjs.org", "192.0.2.7:5432", "[2001:db8::7]", "Example.ORG:8080" };
    const t = std.testing;
    try t.expect(allows(&list, "api.github.com", 443));
    try t.expect(allows(&list, "API.GitHub.com.", 80));
    try t.expect(!allows(&list, "api.github.com", 22));
    try t.expect(!allows(&list, "github.com", 443));
    try t.expect(allows(&list, "registry.npmjs.org", 443));
    try t.expect(allows(&list, "a.b.npmjs.org", 443));
    try t.expect(!allows(&list, "npmjs.org", 443));
    try t.expect(!allows(&list, "evilnpmjs.org", 443));
    try t.expect(allows(&list, "192.0.2.7", 5432));
    try t.expect(!allows(&list, "192.0.2.7", 443));
    try t.expect(allows(&list, "[2001:db8::7]", 443));
    try t.expect(allows(&list, "2001:db8:0::7", 80));
    try t.expect(allows(&list, "example.org", 8080));
    try t.expect(!allows(&list, "example.org", 443));
    try t.expect(!allows(&list, "", 443));
    try t.expect(!allows(&.{"not a pattern"}, "not a pattern", 443));
}

test namesAddress {
    const t = std.testing;
    try t.expect(namesAddress(&.{"127.0.0.1:5432"}, Target.of("127.0.0.1").?, 5432));
    try t.expect(!namesAddress(&.{"localhost:5432"}, Target.of("127.0.0.1").?, 5432));
    try t.expect(!namesAddress(&.{"127.0.0.1:5432"}, Target.of("127.0.0.1").?, 5433));
    try t.expect(namesAddress(&.{"[::1]"}, Target.of("::1").?, 443));
}

test added {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const t = std.testing;
    const before = [_][]const u8{ "*.github.com", "pypi.org", "192.0.2.7:5432" };
    try t.expectEqual(0, (try added(arena, &before, &.{ "api.github.com", "x.api.github.com:443", "PyPI.org.", "pypi.org:80", "192.0.2.7:5432" })).len);
    const more = try added(arena, &before, &.{ "github.com", "*.github.com:8443", "pypi.org:8080", "192.0.2.7", "*.api.github.com" });
    try t.expectEqual(4, more.len);
    try t.expectEqualStrings("github.com", more[0]);
    try t.expectEqualStrings("*.github.com:8443", more[1]);
    try t.expectEqualStrings("pypi.org:8080", more[2]);
    try t.expectEqualStrings("192.0.2.7", more[3]);
}
