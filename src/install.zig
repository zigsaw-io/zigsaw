//! Making an image in the store the installed version of its app, whether it
//! was just built or pulled.

const std = @import("std");
const Context = @import("Context.zig");
const exports = @import("exports.zig");
const oci = @import("oci.zig");
const override = @import("override.zig");
const note = Context.note;

pub const Image = struct {
    manifest_digest: []const u8,
    manifest: oci.Manifest,
    config: oci.AppConfig,
    /// Where the image came from: a recipe path or a registry reference.
    source: []const u8,
};

/// Deploys the image's layers, points the app's ref at it, and syncs its
/// command shims. The deployments of the version it replaces are deleted,
/// unless they are in use.
pub fn install(ctx: *Context, image: Image) !void {
    const arena = ctx.arena;
    const cfg = image.config;
    const previous = try ctx.store.readRef(arena, cfg.id);
    const start = ctx.now();
    for (image.manifest.layers) |l| _ = try ctx.store.deploy(arena, l);
    ctx.timed(start, "deploy", .{});
    try ctx.store.writeRef(arena, .{
        .id = cfg.id,
        .version = cfg.version,
        .manifest = image.manifest_digest,
        .source = image.source,
    });
    if (previous) |p| if (!std.mem.eql(u8, p.manifest, image.manifest_digest)) {
        if (try ctx.store.deleteUnusedDeployments(arena, p.manifest))
            note("  kept     {s} {s}, which is still running; `zigsaw prune` removes it later", .{ cfg.id, p.version });
    };

    note("installed {s} {s}\n  manifest {s}", .{ cfg.id, cfg.version, image.manifest_digest });
    var runtimes = cfg.runtimes.map.iterator();
    while (runtimes.next()) |r| note("  runtime  {s}: {s} {s}", .{ r.key_ptr.*, r.value_ptr.id, r.value_ptr.version });
    note("  layer    {s} ({d} bytes)", .{ oci.ownLayer(image.manifest).digest, oci.ownLayer(image.manifest).size });
    if (cfg.build) |b| {
        if (b.network) note("  warning: a build step used the network, so this image may not rebuild the same", .{});
        if (b.host.map.count() > 0) note("  warning: built with the host's {s}, so this image won't rebuild the same elsewhere", .{
            try std.mem.join(arena, ", ", b.host.map.keys()),
        });
    }
    // What the app may reach, so nobody installs an app without seeing it.
    var permissions: std.ArrayList([]const u8) = .empty;
    if (cfg.permissions.network) try permissions.append(arena, "network");
    for (cfg.permissions.filesystem) |f| try permissions.append(arena, try std.fmt.allocPrint(arena, "filesystem {s}", .{f}));
    note("  permits  {s}", .{if (permissions.items.len == 0) "nothing outside its own files" else try std.mem.join(arena, ", ", permissions.items)});
    const saved = try override.load(ctx.store, arena, cfg.id);
    if (!saved.isEmpty()) note("  override {f}", .{saved});
    try exports.sync(ctx, cfg);
}
