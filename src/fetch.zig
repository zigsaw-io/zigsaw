//! Resolves recipe sources to verified local files. URL downloads are cached
//! by sha256, so rebuilding a recipe doesn't download anything again.

const Fetcher = @This();

const std = @import("std");
const Io = std.Io;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const recipe = @import("recipe.zig");
const fail = Context.fail;
const note = Context.note;

ctx: *Context,
/// Directory that relative `path` sources are resolved against.
base_dir: []const u8,
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
    try f.download(url, tmp);

    // Cache under the actual hash even if it's not the expected one: the cache
    // is content-addressed, and this way pinning a new hash won't download again.
    const got = try Store.sha256File(io, tmp);
    const cached = try f.ctx.store.path(arena, &.{ "cache", "downloads", &got.hex });
    try Io.Dir.rename(.cwd(), tmp, .cwd(), cached, io);

    const want = src.sha256 orelse
        return fail("source {s} has no sha256. Pin it with:\n  \"sha256\": \"{s}\"", .{ url, &got.hex });
    try check(url, want, got);
    return cached;
}

fn check(what: []const u8, want: []const u8, got: Store.FileHash) error{Failed}!void {
    if (!std.mem.eql(u8, want, &got.hex))
        return fail("sha256 mismatch for {s}\n  expected {s}\n  got      {s}", .{ what, want, &got.hex });
}

fn download(f: *Fetcher, url: []const u8, dest: []const u8) !void {
    const io = f.ctx.io;
    if (f.client == null) {
        f.client = .{ .allocator = f.ctx.gpa, .io = io };
        try f.client.?.initDefaultProxies(f.ctx.arena, f.ctx.env);
    }

    var file = try Io.Dir.cwd().createFile(io, dest, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    const result = f.client.?.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer.interface,
    }) catch |err| return fail("downloading {s}: {t}", .{ url, err });
    try writer.interface.flush();
    if (result.status != .ok)
        return fail("downloading {s}: HTTP {d}", .{ url, @intFromEnum(result.status) });
}
