//! `zigsaw pull` and `zigsaw push`: installing apps from OCI registries and
//! publishing them there. An image's manifest travels byte for byte, so its
//! digest is the same everywhere.
//!
//! An image can be named in full, `<registry>/<repository>[:tag][@digest]`,
//! or by app id alone, `<app-id>[:tag][@digest]`, for the image of that app in
//! the default registry: `org.nodejs.node` is ghcr.io/zigsaw-io/org.nodejs.node.

const std = @import("std");
const Context = @import("Context.zig");
const Registry = @import("Registry.zig");
const Store = @import("Store.zig");
const install = @import("install.zig");
const oci = @import("oci.zig");
const fail = Context.fail;
const note = Context.note;

/// Where images named by app id live, unless ZIGSAW_REGISTRY says otherwise.
pub const default_registry = "ghcr.io/zigsaw-io";
pub const registry_var = "ZIGSAW_REGISTRY";

/// An image as the user named it, resolved to a full reference.
pub const Target = struct {
    /// The full reference, as refs record it.
    text: []const u8,
    ref: Registry.Reference,
    /// The app id it was named by, which the image must provide.
    app_id: ?[]const u8,
};

pub fn resolve(ctx: *Context, text: []const u8) !Target {
    const registry = ctx.env.get(registry_var) orelse default_registry;
    const short = expandShort(ctx.arena, registry, text) catch
        return fail("\"{s}\" isn't an app id, or an image reference like ghcr.io/owner/app:tag", .{text});
    const full = if (short) |s| s.text else text;
    const ref = Registry.Reference.parse(full) catch return if (short != null)
        fail("{s} (from {s}) isn't a valid image reference; check {s}", .{ full, text, registry_var })
    else
        fail("\"{s}\" isn't an image reference like ghcr.io/owner/app:tag or localhost:5000/app@sha256:...", .{text});
    return .{ .text = full, .ref = ref, .app_id = if (short) |s| s.app_id else null };
}

const Short = struct { text: []const u8, app_id: []const u8 };

/// Expands `<app-id>[:tag][@digest]` into `<registry>/<app id,
/// lowercased>[:tag][@digest]`. Null for a full reference, which has a '/'.
fn expandShort(arena: std.mem.Allocator, registry: []const u8, text: []const u8) error{ InvalidId, OutOfMemory }!?Short {
    if (std.mem.indexOfScalar(u8, text, '/') != null) return null;
    const id_end = std.mem.indexOfAny(u8, text, ":@") orelse text.len;
    const id = text[0..id_end];
    if (!oci.isValidId(id)) return error.InvalidId;
    return .{
        .text = try std.fmt.allocPrint(arena, "{s}/{s}{s}", .{
            std.mem.trimEnd(u8, registry, "/"), try std.ascii.allocLowerString(arena, id), text[id_end..],
        }),
        .app_id = id,
    };
}

pub const FetchOptions = struct {
    /// The manifest digest already installed: if the image still has it,
    /// `fetch` returns null without downloading any blob.
    unless: ?[]const u8 = null,
};

/// Downloads an image into the store, ready to install. `zigsaw pull` is this
/// followed by `install.install`.
pub fn fetch(ctx: *Context, image_text: []const u8, opts: FetchOptions) !?install.Image {
    const arena = ctx.arena;
    const target = try resolve(ctx, image_text);
    const ref = target.ref;
    var registry: Registry = undefined;
    try registry.init(ctx, ref, "pull");
    defer registry.deinit();

    const start = ctx.now();
    const fetched = try registry.fetchManifest();
    ctx.timed(start, "fetch manifest", .{});
    if (ref.digest) |want| if (!std.mem.eql(u8, want, fetched.digest))
        return fail("{f} returned a manifest with digest {s}", .{ ref, fetched.digest });
    if (opts.unless) |installed| if (std.mem.eql(u8, installed, fetched.digest)) return null;
    const manifest = try parseManifest(arena, ref, fetched.bytes);

    // The config first: the image has to be a zigsaw app, and the one asked
    // for, before any layer is worth downloading.
    if (!oci.isConfigType(manifest.config.mediaType))
        return fail("{f} is not a zigsaw app (its config type is {s}; it may be a container image)", .{ ref, manifest.config.mediaType });
    try downloadBlob(ctx, &registry, manifest.config);
    const config = try oci.parseConfig(arena, target.text, manifest.config.mediaType, try ctx.store.readBlob(arena, manifest.config.digest));
    try oci.validateLayers(target.text, manifest, config);
    if (target.app_id) |id| if (!std.ascii.eqlIgnoreCase(id, config.id))
        return fail("{f} holds {s}, not {s}", .{ ref, config.id, id });

    for (manifest.layers) |desc| try downloadBlob(ctx, &registry, desc);
    const manifest_desc = try ctx.store.putBlob(arena, fetched.bytes, oci.media_type.manifest);
    return .{
        .manifest_digest = manifest_desc.digest,
        .manifest = manifest,
        .config = config,
        .source = target.text,
    };
}

/// Downloads a blob into the store, unless it's there already.
fn downloadBlob(ctx: *Context, registry: *Registry, desc: oci.Descriptor) !void {
    const arena = ctx.arena;
    const hex = oci.digestHex(desc.digest) orelse return fail("{f}: malformed digest {s}", .{ registry.ref, desc.digest });
    if (try Store.exists(ctx.io, try ctx.store.blobPath(arena, hex))) return;
    if (desc.size > 1 << 20) note("downloading {s} ({d} bytes)", .{ desc.digest, desc.size });
    const start = ctx.now();
    const tmp = try ctx.store.tmpPath(arena, "pull");
    const hash = try registry.downloadBlob(desc, tmp);
    _ = try ctx.store.putBlobFile(arena, tmp, hash, desc.mediaType);
    ctx.timed(start, "download {s}", .{desc.digest});
}

/// Publishes an installed app. Without an image, it goes to its own image in
/// the default registry. The tag defaults to the app's version.
pub fn push(ctx: *Context, id: []const u8, image_text: ?[]const u8) !void {
    const arena = ctx.arena;
    const installed = try ctx.store.readRef(arena, id) orelse return fail("{s} is not installed", .{id});
    const target = try resolve(ctx, image_text orelse id);
    var ref = target.ref;
    if (target.app_id) |named| if (!std.ascii.eqlIgnoreCase(named, id))
        return fail("{s} is the image of {s}; push {s} to its own, or give a full image reference", .{ image_text.?, named, id });
    if (ref.digest != null) return fail("push to a tag, not a digest: {s}", .{target.text});
    ref.tag = ref.tag orelse if (Registry.Reference.isValidTag(installed.version))
        installed.version
    else
        return fail("{s}'s version \"{s}\" can't be a tag; add one: {s}:<tag>", .{ id, installed.version, target.text });

    const manifest_bytes = try ctx.store.readBlob(arena, installed.manifest);
    const manifest = try std.json.parseFromSliceLeaky(oci.Manifest, arena, manifest_bytes, .{ .ignore_unknown_fields = true });

    var registry: Registry = undefined;
    try registry.init(ctx, ref, "pull,push");
    defer registry.deinit();

    // Blobs before the manifest that refers to them; skip what's already there.
    for ([_][]const oci.Descriptor{ &.{manifest.config}, manifest.layers }) |descs| {
        for (descs) |desc| {
            if (try registry.hasBlob(desc.digest)) continue;
            if (desc.size > 1 << 20) note("uploading {s} ({d} bytes)", .{ desc.digest, desc.size });
            const start = ctx.now();
            try registry.uploadBlob(desc, try ctx.store.blobPath(arena, oci.digestHex(desc.digest).?));
            ctx.timed(start, "upload {s}", .{desc.digest});
        }
    }
    try registry.pushManifest(ref.tag.?, manifest_bytes);
    note("pushed {s} {s} to {f}\n  manifest {s}", .{ id, installed.version, ref, installed.manifest });
}

test expandShort {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mingit = (try expandShort(arena, default_registry, "org.git_scm.MinGit:2.56.0.windows.1")).?;
    try std.testing.expectEqualStrings("ghcr.io/zigsaw-io/org.git_scm.mingit:2.56.0.windows.1", mingit.text);
    try std.testing.expectEqualStrings("org.git_scm.MinGit", mingit.app_id);
    try std.testing.expectEqualStrings("localhost:5000/test/org.nodejs.node", (try expandShort(arena, "localhost:5000/test/", "org.nodejs.node")).?.text);
    try std.testing.expectEqualStrings("r.io/net.frippery.busybox@sha256:ab", (try expandShort(arena, "r.io", "net.frippery.busybox@sha256:ab")).?.text);
    try std.testing.expectEqual(null, try expandShort(arena, default_registry, "ghcr.io/owner/app:1"));
    try std.testing.expectError(error.InvalidId, expandShort(arena, default_registry, "has space:1"));
    try std.testing.expectError(error.InvalidId, expandShort(arena, default_registry, ":latest"));
}

/// Parses a fetched manifest, and checks it is a single image rather than an
/// index. Whether it's a zigsaw app is up to its config.
fn parseManifest(arena: std.mem.Allocator, ref: Registry.Reference, bytes: []const u8) !oci.Manifest {
    const Probe = struct { mediaType: ?[]const u8 = null, manifests: ?[]const std.json.Value = null };
    const probe = std.json.parseFromSliceLeaky(Probe, arena, bytes, .{ .ignore_unknown_fields = true }) catch
        return fail("{f} returned a manifest that isn't JSON", .{ref});
    if (probe.manifests != null)
        return fail("{f} is a multi-platform index, not a zigsaw image", .{ref});

    return std.json.parseFromSliceLeaky(oci.Manifest, arena, bytes, .{ .ignore_unknown_fields = true }) catch
        fail("{f} returned a manifest zigsaw can't read", .{ref});
}

/// The digest of the manifest `image_text` names in its registry, without
/// downloading anything else.
pub fn manifestDigest(ctx: *Context, image_text: []const u8) ![]const u8 {
    const target = try resolve(ctx, image_text);
    var registry: Registry = undefined;
    try registry.init(ctx, target.ref, "pull");
    defer registry.deinit();
    return (try registry.fetchManifest()).digest;
}
