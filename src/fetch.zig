//! Resolves recipe sources to verified local files. URL downloads are cached
//! by sha256, so rebuilding a recipe doesn't download anything again.
//!
//! A pinned source whose URL fails, or no longer serves the pinned file, is
//! fetched by its sha256 from the sources kept next to the recipe's image in
//! the default registry instead (see remote.pushSources).

const Fetcher = @This();

const std = @import("std");
const Io = std.Io;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const recipe = @import("recipe.zig");
const remote = @import("remote.zig");
const fail = Context.fail;
const note = Context.note;

ctx: *Context,
/// Directory that relative `path` sources are resolved against.
base_dir: []const u8,
/// The id of the app whose recipe this is, whose image's sources pinned
/// files are fetched from when their own location fails. Null for none.
app: ?[]const u8 = null,
client: ?std.http.Client = null,

pub fn deinit(f: *Fetcher) void {
    if (f.client) |*c| c.deinit();
}

/// Returns the path of a local file holding the source's bytes.
pub fn fetch(f: *Fetcher, src: recipe.Source) ![]const u8 {
    const io = f.ctx.io;
    const arena = f.ctx.arena;

    if (src.path) |p| {
        const full = if (std.fs.path.isAbsolute(p)) p else try std.fs.path.join(arena, &.{ f.base_dir, p });
        if (src.sha256) |want| try check(full, want, try Store.sha256File(io, full));
        return full;
    }

    const url = src.url.?;
    if (src.sha256) |want| {
        const cached = try f.ctx.store.path(arena, &.{ "cache", "downloads", want });
        if (try Store.exists(io, cached)) return cached;
    }

    const tmp = try f.ctx.store.tmpPath(arena, "download");
    errdefer Io.Dir.cwd().deleteFile(io, tmp) catch {};
    note("fetching {s}", .{url});
    if (try f.download(url, tmp)) |problem| {
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        const want = src.sha256 orelse return fail("downloading {s}: {s}", .{ url, problem });
        return f.fromSources(want, src.fileName(), problem);
    }

    // Cache under the actual hash even if it's not the expected one: the cache
    // is content-addressed, and this way pinning a new hash won't download again.
    const got = try Store.sha256File(io, tmp);
    const cached = try f.ctx.store.path(arena, &.{ "cache", "downloads", &got.hex });
    try Io.Dir.rename(.cwd(), tmp, .cwd(), cached, io);

    const want = src.sha256 orelse
        return fail("source {s} has no sha256. Pin it with:\n  \"sha256\": \"{s}\"", .{ url, &got.hex });
    if (std.mem.eql(u8, want, &got.hex)) return cached;
    if (f.app == null) try check(url, want, got);
    return f.fromSources(want, src.fileName(), try std.fmt.allocPrint(arena, "it's no longer the pinned file (its sha256 is {s})", .{&got.hex}));
}

/// Fetches the pinned file with this sha256 from the sources next to the
/// app's image, into the download cache, after its own location failed:
/// `what` couldn't be had because of `why`.
pub fn fromSources(f: *Fetcher, sha256: []const u8, what: []const u8, why: []const u8) ![]const u8 {
    const ctx = f.ctx;
    const arena = ctx.arena;
    const app = f.app orelse return fail("{s}: {s}", .{ what, why });
    const where = (try remote.resolve(ctx, app)).text;
    note("{s}: {s}; fetching sha256 {s} from the sources next to {s}", .{ what, why, sha256[0..12], where });
    const tmp = try ctx.store.tmpPath(arena, "download");
    const found = remote.fetchSource(ctx, app, sha256, tmp) catch |err| switch (err) {
        error.Failed => return fail("{s}: {s}, and fetching it from the sources next to {s} failed too", .{ what, why, where }),
        else => |e| return e,
    };
    if (found == null) return fail("{s}: {s}, and the sources next to {s} don't have it (sha256 {s})", .{ what, why, where, sha256 });
    const cached = try ctx.store.path(arena, &.{ "cache", "downloads", sha256 });
    try Io.Dir.rename(.cwd(), tmp, .cwd(), cached, ctx.io);
    return cached;
}

fn check(what: []const u8, want: []const u8, got: Store.FileHash) error{Failed}!void {
    if (!std.mem.eql(u8, want, &got.hex))
        return fail("sha256 mismatch for {s}\n  expected {s}\n  got      {s}", .{ what, want, &got.hex });
}

/// Downloads `url` to `dest`. Returns what went wrong, if it did.
fn download(f: *Fetcher, url: []const u8, dest: []const u8) !?[]const u8 {
    const io = f.ctx.io;
    const arena = f.ctx.arena;
    if (f.client == null) {
        f.client = .{ .allocator = f.ctx.gpa, .io = io };
        try f.client.?.initDefaultProxies(arena, f.ctx.env);
    }

    var file = try Io.Dir.cwd().createFile(io, dest, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    const result = f.client.?.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer.interface,
    }) catch |err| return try std.fmt.allocPrint(arena, "{t}", .{err});
    try writer.interface.flush();
    if (result.status != .ok) return try std.fmt.allocPrint(arena, "HTTP {d}", .{@intFromEnum(result.status)});
    return null;
}
