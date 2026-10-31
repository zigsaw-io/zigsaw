//! `zigsaw info`: what an app in a registry is, needs and may reach, before
//! it's installed, from its image's manifest and config.

const std = @import("std");
const Io = std.Io;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const format = @import("format.zig");
const oci = @import("oci.zig");
const remote = @import("remote.zig");

pub fn info(ctx: *Context, image_text: []const u8) !void {
    const arena = ctx.arena;
    const app = try remote.fetchInfo(ctx, image_text);
    const cfg = app.config;

    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const w = &stdout.interface;
    try writeName(w, cfg);
    try writeLine(w, "homepage", cfg.homepage orelse "");
    try writeLine(w, "license", cfg.license orelse "");
    try writeLine(w, "image", app.target.text);
    try writeLine(w, "manifest", app.manifest_digest);
    if (app.index) |index| try writeLine(w, "index", try std.fmt.allocPrint(arena, "{s}, as its image for windows/amd64", .{index}));
    try writeContents(ctx, w, app.manifest, cfg);
    if (cfg.build) |b| try writeLine(w, "built", try describeBuild(arena, b));
    const installed = try ctx.store.readRef(arena, cfg.id);
    try writeLine(w, "installed", if (installed) |ref|
        if (std.mem.eql(u8, ref.manifest, app.manifest_digest))
            try std.fmt.allocPrint(arena, "{s}, this image", .{ref.version})
        else
            try std.fmt.allocPrint(arena, "{s} ({s})", .{ ref.version, oci.shortDigest(ref.manifest) })
    else
        "no");
    try w.flush();
}

/// What the app is: the first lines of `info`, and of what `pull` shows
/// before it asks.
pub fn writeName(w: *Io.Writer, cfg: oci.AppConfig) !void {
    if (cfg.name) |n| try w.print("{s} {s}: {s}\n", .{ cfg.id, cfg.version, n }) else try w.print("{s} {s}\n", .{ cfg.id, cfg.version });
    if (cfg.summary) |s| try w.print("  {s}\n", .{s});
}

/// What pulling the image downloads, and what the app brings and may reach,
/// as `info` and `pull` show it.
pub fn writeContents(ctx: *Context, w: *Io.Writer, manifest: oci.Manifest, cfg: oci.AppConfig) !void {
    const arena = ctx.arena;
    // What pulling it downloads, and how much of that the store has already
    // (a runtime another app has, say).
    var total: u64 = manifest.config.size;
    var missing: u64 = 0;
    for (manifest.layers) |l| {
        total += l.size;
        if (!try Store.exists(ctx.io, try ctx.store.blobPath(arena, oci.digestHex(l.digest).?))) missing += l.size;
    }
    try writeLine(w, "download", if (missing == total - manifest.config.size)
        try std.fmt.allocPrint(arena, "{Bi:.1}", .{total})
    else if (missing == 0)
        try std.fmt.allocPrint(arena, "{Bi:.1}, all in the store already", .{total})
    else
        try std.fmt.allocPrint(arena, "{Bi:.1}, of which {Bi:.1} isn't in the store yet", .{ total, missing }));

    var runtimes: std.ArrayList([]const u8) = .empty;
    for (cfg.runtimes.map.values()) |r| try runtimes.append(arena, try std.fmt.allocPrint(arena, "{s} {s}", .{ r.id, r.version }));
    try writeLine(w, "runtimes", try std.mem.join(arena, ", ", runtimes.items));
    // Only when it isn't what builds make by default.
    if (format.Format.ofDescriptor(oci.ownLayer(manifest))) |f| if (f != .gzip) try writeLine(w, "layer", f.label());
    if (cfg.extensions) |e| {
        var pts: std.ArrayList([]const u8) = .empty;
        for (e.map.keys(), e.map.values()) |name, p| try pts.append(arena, try std.fmt.allocPrint(arena, "{s} {s}", .{ name, p.version }));
        try writeLine(w, "points", try std.fmt.allocPrint(arena, "{s} (installed extensions of it join its runs)", .{try std.mem.join(arena, ", ", pts.items)}));
    }
    if (cfg.extends) |x| try writeLine(w, "extends", try std.fmt.allocPrint(arena, "{s} {s}{s}{s}", .{
        x.point,
        x.version,
        if (x.needs != null) ", after " else "",
        if (x.needs) |n| try oci.joinAnd(arena, n) else "",
    }));
    try writeLine(w, "commands", try std.mem.join(arena, ", ", cfg.exports.map.keys()));
    if (cfg.shortcuts) |s| {
        var names: std.ArrayList([]const u8) = .empty;
        for (s.map.keys()) |n| try names.append(arena, try std.fmt.allocPrint(arena, "\"{s}\"", .{n}));
        try writeLine(w, "shortcuts", try std.mem.join(arena, ", ", names.items));
    }
    if (cfg.associations) |a| try writeLine(w, "opens", try std.mem.join(arena, ", ", a.map.keys()));
    if (cfg.permissions.services) |s| try writeLine(w, "serves", try oci.describeServices(arena, s));
    try writeAccess(arena, w, try .of(arena, cfg));
}

/// The lines saying what an app may reach: all of it, or what an update adds.
pub fn writeAccess(arena: std.mem.Allocator, w: *Io.Writer, access: oci.Access) !void {
    try writeLine(w, "permits", try oci.describePermissions(arena, access.permissions));
    if (access.uses.len > 0) try writeLine(w, "uses", try oci.describeUses(arena, access.uses));
    if (access.registry.len > 0) try writeLine(w, "keeps", try std.fmt.allocPrint(arena, "{s} with its data", .{try oci.describeRegistry(arena, access.registry)}));
}

/// A labelled line, unless there's nothing to say.
pub fn writeLine(w: *Io.Writer, label: []const u8, value: []const u8) !void {
    if (value.len > 0) try w.print("  {s:<10} {s}\n", .{ label, value });
}

/// How the image was built, as far as its config says: with which SDKs, and
/// whether it should rebuild the same.
fn describeBuild(arena: std.mem.Allocator, b: oci.Build) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var sdks: std.ArrayList([]const u8) = .empty;
    for (b.sdk.map.keys()) |alias| try sdks.append(arena, alias);
    // Not "from its sources": the config doesn't say whether anything was
    // compiled, and a recipe may only unpack upstream's own build.
    const downloads = try std.fmt.allocPrint(arena, "from {d} pinned download{s}", .{ b.sources.len, if (b.sources.len == 1) "" else "s" });
    try parts.append(arena, if (sdks.items.len > 0)
        try std.fmt.allocPrint(arena, "{s}, with {s}", .{ downloads, try oci.joinAnd(arena, sdks.items) })
    else
        try std.fmt.allocPrint(arena, "{s}, without an SDK", .{downloads}));
    if (b.network) try parts.append(arena, "a step used the network, so it may not rebuild the same");
    if (b.host.map.count() > 0) try parts.append(arena, try std.fmt.allocPrint(arena, "with the build machine's {s}, so it won't rebuild the same elsewhere", .{try std.mem.join(arena, ", ", b.host.map.keys())}));
    return std.mem.join(arena, "; ", parts.items);
}

test describeBuild {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("from 1 pinned download, without an SDK", try describeBuild(arena, .{ .sources = &.{"a"} }));
    var with: oci.Build = .{ .sources = &.{ "a", "b" }, .network = true };
    try with.sdk.map.put(arena, "zig", "sha256:z");
    try with.sdk.map.put(arena, "busybox", "sha256:b");
    try std.testing.expectEqualStrings("from 2 pinned downloads, with zig and busybox; a step used the network, so it may not rebuild the same", try describeBuild(arena, with));
}
