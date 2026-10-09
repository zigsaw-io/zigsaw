//! The images a recipe names: its runtimes, which the app runs with and whose
//! layers go into its image, and its SDK, which only the build uses. Both are
//! named by image reference and pinned by manifest digest, as sources are by
//! sha256, so a recipe always builds with the same images.
//!
//! A pinned image comes from the store if it's there, whether it was built
//! there or pulled (builds reproduce, so both give the same digest), and from
//! its registry otherwise. Images that builds use are kept like cached
//! downloads, until `zigsaw prune --downloads`.

const std = @import("std");
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const oci = @import("oci.zig");
const remote = @import("remote.zig");
const fail = Context.fail;

/// What the recipe uses the image as: a runtime, an SDK, or a module's
/// source of files (then its alias is the module's name).
pub const Kind = enum { runtime, sdk, source };

pub const Dependency = struct {
    alias: []const u8,
    manifest_digest: []const u8,
    manifest: oci.Manifest,
    config: oci.AppConfig,

    /// The image's own files.
    pub fn layer(d: Dependency) oci.Descriptor {
        return oci.ownLayer(d.manifest);
    }

    /// What an app's config records about it as a runtime.
    pub fn runtime(d: Dependency) oci.Runtime {
        return .{
            .id = d.config.id,
            .version = d.config.version,
            .image = d.manifest_digest,
            .layer = d.layer().digest,
            .path = d.config.path,
            .env = d.config.env,
            .aliases = if (d.config.aliases) |a| (if (a.map.count() > 0) a else null) else null,
        };
    }
};

/// Finds the image `reference` names, downloading it if the store doesn't
/// have it. `recipe` names the recipe in messages.
pub fn resolve(ctx: *Context, recipe: []const u8, kind: Kind, alias: []const u8, reference: []const u8) !Dependency {
    const arena = ctx.arena;
    const target = remote.resolve(ctx, reference) catch
        return fail("{s}: {t} {s}: \"{s}\" isn't an app id or an image reference", .{ recipe, kind, alias, reference });
    const digest = target.ref.digest orelse return failUnpinned(ctx, recipe, kind, alias, reference, target);

    const image = try ctx.store.readCompleteImage(arena, digest) orelse pulled: {
        const fetched = (try remote.fetch(ctx, reference, .{})).?;
        break :pulled Store.Loaded{ .manifest = fetched.manifest, .config = fetched.config };
    };
    if (target.app_id) |id| if (!std.ascii.eqlIgnoreCase(id, image.config.id))
        return fail("{s}: {t} {s}: {s} is {s}, not {s}", .{ recipe, kind, alias, digest, image.config.id, id });
    // Like Flatpak's runtimes, so a runtime is always one layer. An SDK may
    // have runtimes, which join the build with it, and a source takes only
    // the image's own files.
    if (kind == .runtime and image.config.runtimes.map.count() > 0)
        return fail("{s}: {t} {s} is {s}, which has runtimes of its own; zigsaw doesn't support that", .{ recipe, kind, alias, image.config.id });
    try ctx.store.markBuildImage(arena, digest);
    return .{ .alias = alias, .manifest_digest = digest, .manifest = image.manifest, .config = image.config };
}

/// Fails, saying which digest to pin: the installed app's, if its version is
/// the one named, or else whatever the registry has under that name.
fn failUnpinned(ctx: *Context, recipe: []const u8, kind: Kind, alias: []const u8, reference: []const u8, target: remote.Target) error{ Failed, OutOfMemory } {
    const arena = ctx.arena;
    const digest = digest: {
        if (target.app_id) |id| if (ctx.store.readRef(arena, id) catch null) |ref| {
            if (target.ref.tag == null or std.mem.eql(u8, target.ref.tag.?, ref.version)) break :digest ref.manifest;
        };
        break :digest remote.manifestDigest(ctx, reference) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return fail("{s}: {t} {s} \"{s}\" must be pinned with \"@sha256:...\", and zigsaw can't find the digest: build or pull the image first", .{ recipe, kind, alias, reference }),
        };
    };
    const key = if (kind == .source) "image" else alias;
    return fail("{s}: {t} {s} isn't pinned to a digest. Pin it with:\n  \"{s}\": \"{s}@{s}\"", .{ recipe, kind, alias, key, reference, digest });
}
