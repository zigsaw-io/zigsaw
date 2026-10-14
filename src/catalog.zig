//! The catalog of the apps a registry has, so that they can be found:
//! `zigsaw search` reads it, and `zigsaw push --catalog` makes it, from the
//! images the registry has, as their configs describe them (name, summary,
//! commands, shortcuts, the kinds of file they open, permissions).
//!
//! It's an artifact next to the apps' images, `<registry>/catalog:latest`
//! (ghcr.io/zigsaw-io/catalog), whose config is the catalog's JSON. No app
//! may have the id "catalog" (see oci.zig). A copy is kept in
//! cache\catalog\, used again while the registry has the same one, and when
//! the registry can't be reached.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Registry = @import("Registry.zig");
const Store = @import("Store.zig");
const oci = @import("oci.zig");
const remote = @import("remote.zig");
const fail = Context.fail;
const note = Context.note;

pub const media_type = "application/vnd.zigsaw.catalog.v1+json";
/// The catalog's name among the registry's repositories, which no app id
/// may take.
pub const name = "catalog";

pub const Catalog = struct {
    /// Where the apps' images are: <registry>/<app id, lowercased>.
    registry: []const u8,
    apps: []const Entry,
};

/// An app as the registry has it at its latest tag.
pub const Entry = struct {
    id: []const u8,
    version: []const u8,
    manifest: []const u8,
    /// What pulling it downloads: its config and layers, its runtimes'
    /// included.
    download: u64,
    name: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
    license: ?[]const u8 = null,
    commands: []const []const u8 = &.{},
    /// By name: what each says it does.
    shortcuts: std.json.ArrayHashMap([]const u8) = .{},
    /// By extension: what kind of file it is.
    associations: std.json.ArrayHashMap([]const u8) = .{},
    permissions: oci.Permissions = .{},
    registry: ?[]const []const u8 = null,
    /// "<id> <version>" of each.
    runtimes: []const []const u8 = &.{},

    fn of(arena: Allocator, info: remote.Info) !Entry {
        const cfg = info.config;
        var download: u64 = info.manifest.config.size;
        for (info.manifest.layers) |l| download += l.size;
        var e: Entry = .{
            .id = cfg.id,
            .version = cfg.version,
            .manifest = info.manifest_digest,
            .download = download,
            .name = cfg.name,
            .summary = cfg.summary,
            .homepage = cfg.homepage,
            .license = cfg.license,
            .commands = cfg.exports.map.keys(),
            .permissions = cfg.permissions,
            .registry = cfg.registry,
        };
        if (cfg.shortcuts) |s| for (s.map.keys(), s.map.values()) |n, shortcut| try e.shortcuts.map.put(arena, n, shortcut.description orelse "");
        if (cfg.associations) |a| for (a.map.keys(), a.map.values()) |ext, association| try e.associations.map.put(arena, ext, association.description orelse "");
        var runtimes: std.ArrayList([]const u8) = .empty;
        for (cfg.runtimes.map.values()) |r| try runtimes.append(arena, try std.fmt.allocPrint(arena, "{s} {s}", .{ r.id, r.version }));
        e.runtimes = runtimes.items;
        return e;
    }

    /// What it is, in a line: its name and summary, or its commands.
    pub fn describe(e: Entry, arena: Allocator) ![]const u8 {
        if (e.name) |n| return if (e.summary) |s| std.fmt.allocPrint(arena, "{s}: {s}", .{ n, s }) else n;
        if (e.summary) |s| return s;
        if (e.commands.len == 0) return "";
        return std.fmt.allocPrint(arena, "commands: {s}", .{try std.mem.join(arena, ", ", e.commands)});
    }
};

// ---------------------------------------------------------------------------
// Making it

/// `zigsaw push --catalog`: makes the default registry's catalog list the
/// apps `ids` names, as the registry has them at their "latest" tag.
pub fn push(ctx: *Context, ids: []const []const u8) !void {
    const arena = ctx.arena;
    var entries: std.ArrayList(Entry) = .empty;
    for (ids) |id| {
        for (entries.items) |e| if (std.ascii.eqlIgnoreCase(e.id, id)) return fail("{s} is named twice", .{id});
        const info = try remote.fetchInfo(ctx, try std.fmt.allocPrint(arena, "{s}:latest", .{id}));
        try entries.append(arena, try .of(arena, info));
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.ascii.lessThanIgnoreCase(a.id, b.id);
        }
    }.lessThan);
    const target = try remote.resolve(ctx, name ++ ":latest");
    const catalog: Catalog = .{ .registry = registryOf(target), .apps = entries.items };

    var registry: Registry = undefined;
    try registry.init(ctx, target.ref, "pull,push");
    defer registry.deinit();
    const config_desc = try ctx.store.putBlob(arena, try oci.toJson(arena, catalog), media_type);
    try remote.uploadIfMissing(ctx, &registry, config_desc, try ctx.store.blobPath(arena, oci.digestHex(config_desc.digest).?), null);
    var annotations: std.json.ArrayHashMap([]const u8) = .{};
    try annotations.map.put(arena, "org.opencontainers.image.title", "zigsaw catalog");
    try annotations.map.put(arena, "org.opencontainers.image.description", try std.fmt.allocPrint(arena, "The {d} apps in {s}, for `zigsaw search`", .{ entries.items.len, catalog.registry }));
    const manifest: oci.Manifest = .{ .config = config_desc, .layers = &.{}, .annotations = annotations };
    try registry.pushManifest("latest", try oci.toJson(arena, manifest));
    note("pushed the catalog of {d} app(s) to {f}", .{ entries.items.len, target.ref });
}

/// The registry a reference's repository is in: "ghcr.io/zigsaw-io" for
/// ghcr.io/zigsaw-io/catalog:latest.
fn registryOf(target: remote.Target) []const u8 {
    const text = target.text;
    const slash = std.mem.lastIndexOfScalar(u8, text, '/') orelse return text;
    return text[0..slash];
}

// ---------------------------------------------------------------------------
// Reading it

pub const Loaded = struct {
    catalog: Catalog,
    /// Where it's from: <registry>/catalog:latest.
    source: []const u8,
};

/// The default registry's catalog: the registry's, or the copy kept from it
/// if the registry has the same one, or can't be reached.
pub fn load(ctx: *Context) !Loaded {
    const io = ctx.io;
    const arena = ctx.arena;
    const target = try remote.resolve(ctx, name ++ ":latest");
    const cache_dir = try ctx.store.path(arena, &.{ "cache", "catalog" });
    try Io.Dir.cwd().createDirPath(io, cache_dir);
    const base = try std.fs.path.join(arena, &.{ cache_dir, try fileName(arena, target.text) });
    const cached_path = try std.fmt.allocPrint(arena, "{s}.json", .{base});
    const digest_path = try std.fmt.allocPrint(arena, "{s}.digest", .{base});
    const cached_digest = readSmall(io, arena, digest_path);

    const fresh = fetch(ctx, target, cached_digest, cached_path, digest_path) catch |err| switch (err) {
        error.Failed => {
            const digest = cached_digest orelse return err;
            note("using the catalog of {s} fetched {s} instead", .{ registryOf(target), try fetchedWhen(ctx, digest) });
            return .{ .catalog = try parse(arena, target.text, try readSmallOrFail(io, arena, cached_path)), .source = target.text };
        },
        else => |e| return e,
    };
    return .{ .catalog = try parse(arena, target.text, fresh), .source = target.text };
}

/// The catalog's JSON from the registry, or from the cache while the
/// registry's is the same; the cache is brought up to date.
fn fetch(ctx: *Context, target: remote.Target, cached_digest: ?[]const u8, cached_path: []const u8, digest_path: []const u8) ![]const u8 {
    const io = ctx.io;
    const arena = ctx.arena;
    var registry: Registry = undefined;
    try registry.init(ctx, target.ref, "pull");
    defer registry.deinit();
    const fetched = registry.fetchManifest() catch |err| {
        note("{s} has no catalog of its apps, or it can't be read; `zigsaw push --catalog` makes one", .{registryOf(target)});
        return err;
    };
    const manifest = try remote.parseManifest(arena, target.ref, fetched.bytes);
    if (!std.mem.eql(u8, manifest.config.mediaType, media_type))
        return fail("{f} isn't a zigsaw catalog (its config type is {s})", .{ target.ref, manifest.config.mediaType });
    const now = Io.Timestamp.now(io, .real);
    const seconds: i64 = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_s));
    if (cached_digest) |c| if (std.mem.startsWith(u8, c, manifest.config.digest)) {
        if (readSmall(io, arena, cached_path)) |bytes| {
            try writeFile(io, digest_path, try std.fmt.allocPrint(arena, "{s} {d}", .{ manifest.config.digest, seconds }));
            return bytes;
        }
    };
    const tmp = try ctx.store.tmpPath(arena, "catalog");
    _ = try registry.downloadBlob(manifest.config, tmp);
    const bytes = try readSmallOrFail(io, arena, tmp);
    Io.Dir.cwd().deleteFile(io, tmp) catch {};
    try writeFile(io, cached_path, bytes);
    try writeFile(io, digest_path, try std.fmt.allocPrint(arena, "{s} {d}", .{ manifest.config.digest, seconds }));
    return bytes;
}

fn parse(arena: Allocator, what: []const u8, bytes: []const u8) !Catalog {
    return std.json.parseFromSliceLeaky(Catalog, arena, bytes, .{ .ignore_unknown_fields = true }) catch
        fail("{s}: the catalog can't be read", .{what});
}

/// "on 2026-10-15", from the time the cache's .digest file records.
fn fetchedWhen(ctx: *Context, digest_line: []const u8) ![]const u8 {
    const space = std.mem.indexOfScalar(u8, digest_line, ' ') orelse return "earlier";
    const seconds = std.fmt.parseInt(u64, std.mem.trim(u8, digest_line[space + 1 ..], " \r\n"), 10) catch return "earlier";
    const day = (std.time.epoch.EpochSeconds{ .secs = seconds }).getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(ctx.arena, "on {d}-{d:0>2}-{d:0>2}", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1 });
}

/// A file name for a reference: what isn't a letter, digit, '.' or '-' as '_'.
fn fileName(arena: Allocator, text: []const u8) ![]u8 {
    const out = try arena.dupe(u8, text);
    for (out) |*ch| switch (ch.*) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-' => {},
        else => ch.* = '_',
    };
    return out;
}

fn readSmall(io: Io, arena: Allocator, p: []const u8) ?[]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(16 << 20)) catch null;
}

fn readSmallOrFail(io: Io, arena: Allocator, p: []const u8) ![]const u8 {
    return readSmall(io, arena, p) orelse fail("can't read {s}", .{p});
}

fn writeFile(io: Io, p: []const u8, bytes: []const u8) !void {
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = bytes });
}

// ---------------------------------------------------------------------------
// Searching it

/// `zigsaw search`: the apps every word is in (ignoring case), in their id,
/// name, summary, commands, shortcuts or kinds of file; all of them without
/// words. Returns 1 if none is.
pub fn search(ctx: *Context, words: []const []const u8) !u32 {
    const arena = ctx.arena;
    const loaded = try load(ctx);
    const Match = struct { entry: Entry, rank: u8 };
    var matches: std.ArrayList(Match) = .empty;
    for (loaded.catalog.apps) |e| if (try rankOf(arena, e, words)) |rank| try matches.append(arena, .{ .entry = e, .rank = rank });
    if (matches.items.len == 0) {
        note("no app in {s}'s catalog matches {s}", .{ loaded.catalog.registry, try std.mem.join(arena, " ", words) });
        return 1;
    }
    std.mem.sort(Match, matches.items, {}, struct {
        fn lessThan(_: void, a: Match, b: Match) bool {
            if (a.rank != b.rank) return a.rank < b.rank;
            return std.ascii.lessThanIgnoreCase(a.entry.id, b.entry.id);
        }
    }.lessThan);

    var id_width: usize = "ID".len;
    var version_width: usize = "VERSION".len;
    for (matches.items) |m| {
        id_width = @max(id_width, m.entry.id.len);
        version_width = @max(version_width, m.entry.version.len);
    }
    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const w = &stdout.interface;
    try w.print("{s} {s} DESCRIPTION\n", .{ try pad(arena, "ID", id_width), try pad(arena, "VERSION", version_width) });
    for (matches.items) |m|
        try w.print("{s} {s} {s}\n", .{ try pad(arena, m.entry.id, id_width), try pad(arena, m.entry.version, version_width), try m.entry.describe(arena) });
    try w.flush();
    return 0;
}

fn pad(arena: Allocator, s: []const u8, width: usize) ![]const u8 {
    if (s.len >= width) return s;
    const out = try arena.alloc(u8, width);
    @memcpy(out[0..s.len], s);
    @memset(out[s.len..], ' ');
    return out;
}

/// Null if a word isn't in the entry anywhere; otherwise 0 if every word is
/// in its id, name or a command, and 1 if some are only elsewhere.
fn rankOf(arena: Allocator, e: Entry, words: []const []const u8) !?u8 {
    var main: std.ArrayList([]const u8) = .empty;
    try main.appendSlice(arena, &.{ e.id, e.name orelse "" });
    try main.appendSlice(arena, e.commands);
    var other: std.ArrayList([]const u8) = .empty;
    try other.append(arena, e.summary orelse "");
    for (e.shortcuts.map.keys(), e.shortcuts.map.values()) |k, v| try other.appendSlice(arena, &.{ k, v });
    for (e.associations.map.keys(), e.associations.map.values()) |k, v| try other.appendSlice(arena, &.{ k, v });
    var rank: u8 = 0;
    for (words) |word| {
        if (containsAny(main.items, word)) continue;
        if (!containsAny(other.items, word)) return null;
        rank = 1;
    }
    return rank;
}

fn containsAny(fields: []const []const u8, word: []const u8) bool {
    for (fields) |f| if (std.ascii.indexOfIgnoreCase(f, word) != null) return true;
    return false;
}

test rankOf {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var vlc: Entry = .{ .id = "org.videolan.VLC", .version = "3.0.24", .manifest = "", .download = 0, .name = "VLC media player", .summary = "Plays video and audio files", .commands = &.{"vlc"} };
    try vlc.associations.map.put(arena, ".mkv", "Matroska video");
    try std.testing.expectEqual(0, try rankOf(arena, vlc, &.{"vlc"}));
    try std.testing.expectEqual(0, try rankOf(arena, vlc, &.{ "MEDIA", "videolan" }));
    try std.testing.expectEqual(1, try rankOf(arena, vlc, &.{ "vlc", ".mkv" }));
    try std.testing.expectEqual(1, try rankOf(arena, vlc, &.{"matroska"}));
    try std.testing.expectEqual(null, try rankOf(arena, vlc, &.{ "vlc", "pdf" }));
    try std.testing.expectEqual(0, try rankOf(arena, vlc, &.{}));
    try std.testing.expectEqualStrings("VLC media player: Plays video and audio files", try vlc.describe(arena));
    const zig: Entry = .{ .id = "org.ziglang.zig", .version = "0.16.0", .manifest = "", .download = 0, .commands = &.{"zig"} };
    try std.testing.expectEqualStrings("commands: zig", try zig.describe(arena));
}

test "a catalog's JSON round-trips, and leaves out what an app doesn't have" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entry: Entry = .{ .id = "org.ziglang.zig", .version = "0.16.0", .manifest = "sha256:" ++ "a" ** 64, .download = 88, .commands = &.{"zig"} };
    const json = try oci.toJson(arena, Catalog{ .registry = "ghcr.io/zigsaw-io", .apps = &.{entry} });
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"registry\": \"ghcr.io/zigsaw-io\"") != null);
    const back = try parse(arena, "test", json);
    try std.testing.expectEqualStrings("org.ziglang.zig", back.apps[0].id);
    try std.testing.expectEqual(88, back.apps[0].download);
    try std.testing.expectEqualStrings("zig", back.apps[0].commands[0]);
}
