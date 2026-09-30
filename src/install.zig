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

/// Deploys the image, points the app's ref at it, and syncs its command shims.
/// The deployment of the version it replaces is deleted, unless that's in use.
pub fn install(ctx: *Context, image: Image) !void {
    const arena = ctx.arena;
    const cfg = image.config;
    const previous = try ctx.store.readRef(arena, cfg.id);
    const start = ctx.now();
    _ = try ctx.store.deploy(arena, image.manifest_digest, image.manifest);
    ctx.timed(start, "deploy", .{});
    try ctx.store.writeRef(arena, .{
        .id = cfg.id,
        .version = cfg.version,
        .manifest = image.manifest_digest,
        .source = image.source,
    });
    if (previous) |p| if (!std.mem.eql(u8, p.manifest, image.manifest_digest)) {
        if (try ctx.store.deleteDeploymentIfUnused(arena, p.manifest)) |deletion| if (deletion == .in_use)
            note("  kept     {s} {s}, which is still running; `zigsaw prune` removes it later", .{ cfg.id, p.version });
    };

    note("installed {s} {s}\n  manifest {s}", .{ cfg.id, cfg.version, image.manifest_digest });
    for (image.manifest.layers) |l| note("  layer    {s} ({d} bytes)", .{ l.digest, l.size });
    // What the app may reach, so nobody installs an app without seeing it.
    var permissions: std.ArrayList([]const u8) = .empty;
    if (cfg.permissions.network) try permissions.append(arena, "network");
    for (cfg.permissions.filesystem) |f| try permissions.append(arena, try std.fmt.allocPrint(arena, "filesystem {s}", .{f}));
    note("  permits  {s}", .{if (permissions.items.len == 0) "nothing outside its own files" else try std.mem.join(arena, ", ", permissions.items)});
    const saved = try override.load(ctx.store, arena, cfg.id);
    if (!saved.isEmpty()) note("  override {f}", .{saved});
    try exports.sync(ctx, cfg);
}
