//! Extension points: images that plug into an app or runtime once installed,
//! like a Flatpak runtime's extensions. PHP's runtime has a point for PHP's
//! extensions: installing net.php.php.Xdebug makes every run of PHP, and of
//! apps that have PHP as a runtime, load it, without them listing it.
//!
//! An image declares points (`oci.AppConfig.extensions`), which apps that
//! have it as a runtime copy; an extension names the point it plugs into and
//! the point's version it was built for (`oci.AppConfig.extends`). A run
//! finds the installed images that extend one of its points at the point's
//! version, and has each, in turn, as a runtime it didn't list: its
//! directory, its PATH entries after the runtimes' and its variables before
//! the app's. The variables a point joins add up instead of replacing each
//! other, so every extension can add its directory to one list.
//!
//! What runs therefore depends on what's installed, as with Flatpak's; an
//! app that lists an extension as a runtime has its own copy, and the
//! installed one of the same id doesn't join. `--noextension` leaves one out.
//! Builds have only the images their recipes pin.

const std = @import("std");
const Allocator = std.mem.Allocator;
const oci = @import("oci.zig");
const Store = @import("Store.zig");
const Context = @import("Context.zig");

/// An extension point a run has.
pub const Point = struct {
    name: []const u8,
    version: []const u8,
    join: []const []const u8,
};

/// The app's own extension points, then its runtimes', in order: the first
/// of a name is the run's.
pub fn points(arena: Allocator, cfg: oci.AppConfig) ![]const Point {
    var out: std.ArrayList(Point) = .empty;
    var all: std.ArrayList(std.json.ArrayHashMap(oci.ExtensionPoint)) = .empty;
    if (cfg.extensions) |e| try all.append(arena, e);
    for (cfg.runtimes.map.values()) |r| if (r.extensions) |e| try all.append(arena, e);
    for (all.items) |e| for (e.map.keys(), e.map.values()) |name, p| {
        const known = for (out.items) |o| {
            if (std.mem.eql(u8, o.name, name)) break true;
        } else false;
        if (!known) try out.append(arena, .{ .name = name, .version = p.version, .join = p.join });
    };
    return out.items;
}

/// The variables a run's extension points join, which its runtimes, its
/// extensions and the app add to (see environment.join).
pub fn joined(arena: Allocator, pts: []const Point) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (pts) |p| try out.appendSlice(arena, p.join);
    return out.items;
}

/// An installed image that extends a point.
pub const Candidate = struct {
    id: []const u8,
    extends: oci.Extends,
};

/// An installed extension of one of the run's points that doesn't join it.
pub const Skip = struct {
    id: []const u8,
    reason: []const u8,
    /// Whether the user should hear of it on every run: it's something to
    /// fix, not something they asked for.
    warn: bool,
};

pub const Choice = struct {
    /// Indexes into the candidates, in the order the extensions join.
    chosen: []const usize,
    skipped: []const Skip,
};

/// Which candidates join a run: those of a point the run has, at its
/// version, that the run doesn't have already (`present`: the app and its
/// runtimes, by id) and that aren't left out (`off`). Each comes after those
/// it needs; otherwise they go in id order.
pub fn choose(arena: Allocator, pts: []const Point, candidates: []const Candidate, present: []const []const u8, off: []const []const u8) !Choice {
    var skipped: std.ArrayList(Skip) = .empty;
    var pending: std.ArrayList(usize) = .empty;
    for (candidates, 0..) |c, i| {
        const point = for (pts) |p| {
            if (std.mem.eql(u8, p.name, c.extends.point)) break p;
        } else continue;
        if (contains(present, c.id)) continue;
        if (contains(off, c.id)) {
            try skipped.append(arena, .{ .id = c.id, .reason = "left out (--noextension)", .warn = false });
            continue;
        }
        if (!std.mem.eql(u8, c.extends.version, point.version)) {
            try skipped.append(arena, .{
                .id = c.id,
                .reason = try std.fmt.allocPrint(arena, "it was built for {s} {s}, and this is {s}", .{ point.name, c.extends.version, point.version }),
                .warn = true,
            });
            continue;
        }
        try pending.append(arena, i);
    }
    std.mem.sort(usize, pending.items, candidates, struct {
        fn lessThan(cs: []const Candidate, a: usize, b: usize) bool {
            return std.ascii.lessThanIgnoreCase(cs[a].id, cs[b].id);
        }
    }.lessThan);

    // The first, in id order, whose needs have joined already; again until
    // none is left that can.
    var chosen: std.ArrayList(usize) = .empty;
    var chosen_ids: std.ArrayList([]const u8) = .empty;
    place: while (true) {
        for (pending.items, 0..) |i, k| {
            const ready = for (candidates[i].extends.needs orelse &.{}) |need| {
                if (!contains(present, need) and !contains(chosen_ids.items, need)) break false;
            } else true;
            if (!ready) continue;
            try chosen.append(arena, i);
            try chosen_ids.append(arena, candidates[i].id);
            _ = pending.orderedRemove(k);
            continue :place;
        }
        break;
    }
    for (pending.items) |i| {
        const c = candidates[i];
        var missing: std.ArrayList([]const u8) = .empty;
        for (c.extends.needs orelse &.{}) |need| if (!contains(present, need) and !contains(chosen_ids.items, need))
            try missing.append(arena, need);
        try skipped.append(arena, .{
            .id = c.id,
            .reason = try std.fmt.allocPrint(arena, "it needs {s}, which isn't installed or doesn't join", .{try oci.joinAnd(arena, missing.items)}),
            .warn = true,
        });
    }
    return .{ .chosen = chosen.items, .skipped = skipped.items };
}

fn contains(ids: []const []const u8, id: []const u8) bool {
    for (ids) |x| if (std.ascii.eqlIgnoreCase(x, id)) return true;
    return false;
}

/// An extension that joins a run.
pub const Extension = struct {
    id: []const u8,
    version: []const u8,
    /// Its deployment, locked as in use.
    dir: []const u8,
    config: oci.AppConfig,
};

pub const Found = struct {
    points: []const Point = &.{},
    loaded: []const Extension = &.{},
    skipped: []const Skip = &.{},
};

/// The installed extensions that join a run of `cfg`, deployed and locked
/// as in use (see `choose`). Runs with the store lock held.
pub fn find(store: Store, arena: Allocator, cfg: oci.AppConfig, off: []const []const u8) !Found {
    const pts = try points(arena, cfg);
    if (pts.len == 0) return .{};
    var candidates: std.ArrayList(Candidate) = .empty;
    for (try store.listRefs(arena)) |ref| {
        if (std.mem.eql(u8, ref.id, cfg.id)) continue;
        // An image this zigsaw can't read isn't one to join anything; what's
        // wrong with it was said.
        const image = store.readImage(arena, ref.id, ref.manifest) catch |err| switch (err) {
            error.Failed => continue,
            else => |e| return e,
        };
        if (image.config.extends) |x| try candidates.append(arena, .{ .id = ref.id, .extends = x });
    }
    var present: std.ArrayList([]const u8) = .empty;
    try present.append(arena, cfg.id);
    for (cfg.runtimes.map.values()) |r| try present.append(arena, r.id);
    const choice = try choose(arena, pts, candidates.items, present.items, off);
    const loaded = try arena.alloc(Extension, choice.chosen.len);
    for (loaded, choice.chosen) |*e, i| {
        const image = try store.loadImage(arena, candidates.items[i].id);
        e.* = .{ .id = image.config.id, .version = image.config.version, .dir = image.deploy_dir, .config = image.config };
    }
    return .{ .points = pts, .loaded = loaded, .skipped = choice.skipped };
}

test choose {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pts: []const Point = &.{.{ .name = "php", .version = "API1", .join = &.{"SCAN"} }};
    const candidates: []const Candidate = &.{
        .{ .id = "php.Redis", .extends = .{ .point = "php", .version = "API1", .needs = &.{"php.Igbinary"} } },
        .{ .id = "php.Xdebug", .extends = .{ .point = "php", .version = "API1" } },
        .{ .id = "php.Old", .extends = .{ .point = "php", .version = "API0" } },
        .{ .id = "php.Igbinary", .extends = .{ .point = "php", .version = "API1" } },
        .{ .id = "gtk.Theme", .extends = .{ .point = "gtk", .version = "4" } },
        .{ .id = "php.APCu", .extends = .{ .point = "php", .version = "API1" } },
        .{ .id = "php.Msgpack", .extends = .{ .point = "php", .version = "API1", .needs = &.{"php.Missing"} } },
    };

    // Id order, Redis once Igbinary, which it needs, has joined. Msgpack
    // needs one that isn't there; Old is for another version.
    var c = try choose(arena, pts, candidates, &.{"app"}, &.{});
    try std.testing.expectEqualSlices(usize, &.{ 5, 3, 0, 1 }, c.chosen);
    try std.testing.expectEqual(2, c.skipped.len);
    try std.testing.expectEqualStrings("php.Old", c.skipped[0].id);
    try std.testing.expectEqualStrings("it was built for php API0, and this is API1", c.skipped[0].reason);
    try std.testing.expectEqualStrings("php.Msgpack", c.skipped[1].id);
    try std.testing.expect(c.skipped[1].warn);

    // Left out: Igbinary, so Redis too. The app's own copy of Xdebug.
    c = try choose(arena, pts, candidates, &.{ "app", "PHP.xdebug" }, &.{"php.igbinary"});
    try std.testing.expectEqualSlices(usize, &.{5}, c.chosen);
    try std.testing.expectEqualStrings("php.Igbinary", c.skipped[1].id);
    try std.testing.expect(!c.skipped[1].warn);
    try std.testing.expectEqualStrings("php.Msgpack", c.skipped[2].id);
    try std.testing.expectEqualStrings("php.Redis", c.skipped[3].id);
    try std.testing.expectEqualStrings("it needs php.Igbinary, which isn't installed or doesn't join", c.skipped[3].reason);

    // A runtime the app lists meets a need.
    c = try choose(arena, pts, candidates[0..1], &.{"php.Igbinary"}, &.{});
    try std.testing.expectEqualSlices(usize, &.{0}, c.chosen);

    // No point, no extensions.
    c = try choose(arena, &.{}, candidates, &.{}, &.{});
    try std.testing.expectEqual(0, c.chosen.len + c.skipped.len);
}

test points {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const digest = "sha256:" ++ "a" ** 64;
    var own: std.json.ArrayHashMap(oci.ExtensionPoint) = .{};
    try own.map.put(arena, "p", .{ .version = "app's" });
    var rt: std.json.ArrayHashMap(oci.ExtensionPoint) = .{};
    try rt.map.put(arena, "p", .{ .version = "runtime's" });
    try rt.map.put(arena, "q", .{ .version = "1", .join = &.{ "A", "B" } });
    var cfg: oci.AppConfig = .{ .id = "app", .version = "1", .command = "x.exe", .extensions = own };
    try cfg.runtimes.map.put(arena, "r", .{ .id = "r", .version = "1", .image = digest, .layer = digest, .extensions = rt });
    const pts = try points(arena, cfg);
    try std.testing.expectEqual(2, pts.len);
    try std.testing.expectEqualStrings("app's", pts[0].version);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "A", "B" }), try joined(arena, pts));
}
