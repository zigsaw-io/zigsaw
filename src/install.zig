//! Making an image in the store the installed version of its app, whether it
//! was just built or pulled.

const std = @import("std");
const Context = @import("Context.zig");
const exports = @import("exports.zig");
const oci = @import("oci.zig");
const note = Context.note;

pub const Image = struct {
    manifest_digest: []const u8,
    manifest: oci.Manifest,
    config: oci.AppConfig,
    /// Where the image came from: a recipe path or a registry reference.
    source: []const u8,
};

/// Deploys the image, points the app's ref at it, and syncs its command shims.
pub fn install(ctx: *Context, image: Image) !void {
    const arena = ctx.arena;
    const cfg = image.config;
    const start = ctx.now();
    _ = try ctx.store.deploy(arena, image.manifest_digest, image.manifest);
    ctx.timed(start, "deploy", .{});
    try ctx.store.writeRef(arena, .{
        .id = cfg.id,
        .version = cfg.version,
        .manifest = image.manifest_digest,
        .source = image.source,
    });

    note("installed {s} {s}\n  manifest {s}", .{ cfg.id, cfg.version, image.manifest_digest });
    for (image.manifest.layers) |l| note("  layer    {s} ({d} bytes)", .{ l.digest, l.size });
    // What the app may reach, so nobody installs an app without seeing it.
    var permissions: std.ArrayList([]const u8) = .empty;
    if (cfg.permissions.network) try permissions.append(arena, "network");
    for (cfg.permissions.filesystem) |f| try permissions.append(arena, try std.fmt.allocPrint(arena, "filesystem {s}", .{f}));
    note("  permits  {s}", .{if (permissions.items.len == 0) "nothing outside its own files" else try std.mem.join(arena, ", ", permissions.items)});
    try exports.sync(ctx, cfg);
}
