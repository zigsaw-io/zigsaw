//! `zigsaw pull` and `zigsaw push`: installing apps from OCI registries and
//! publishing them there. An image's manifest travels byte for byte, so its
//! digest is the same everywhere.

const std = @import("std");
const Context = @import("Context.zig");
const Registry = @import("Registry.zig");
const Store = @import("Store.zig");
const install = @import("install.zig");
const oci = @import("oci.zig");
const fail = Context.fail;
const note = Context.note;

pub fn pull(ctx: *Context, ref_text: []const u8) !void {
    const arena = ctx.arena;
    const ref = try parseReference(ref_text);
    var registry: Registry = undefined;
    try registry.init(ctx, ref, "pull");
    defer registry.deinit();

    var start = ctx.now();
    const fetched = try registry.fetchManifest();
    ctx.timed(start, "fetch manifest", .{});
    if (ref.digest) |want| if (!std.mem.eql(u8, want, fetched.digest))
        return fail("{f} returned a manifest with digest {s}", .{ ref, fetched.digest });
    const manifest = try parseManifest(arena, ref, fetched.bytes);

    // The config first: it has to be a zigsaw app before any layer is worth downloading.
    for ([_][]const oci.Descriptor{ &.{manifest.config}, manifest.layers }) |descs| {
        for (descs) |desc| {
            const hex = oci.digestHex(desc.digest) orelse return fail("{f}: malformed digest {s}", .{ ref, desc.digest });
            if (try Store.exists(ctx.io, try ctx.store.blobPath(arena, hex))) continue;
            if (desc.size > 1 << 20) note("downloading {s} ({d} bytes)", .{ desc.digest, desc.size });
            start = ctx.now();
            const tmp = try ctx.store.tmpPath(arena, "pull");
            const hash = try registry.downloadBlob(desc, tmp);
            _ = try ctx.store.putBlobFile(arena, tmp, hash, desc.mediaType);
            ctx.timed(start, "download {s}", .{desc.digest});
        }
    }
    const manifest_desc = try ctx.store.putBlob(arena, fetched.bytes, oci.media_type.manifest);

    const config = std.json.parseFromSliceLeaky(oci.AppConfig, arena, try ctx.store.readBlob(arena, manifest.config.digest), .{
        .ignore_unknown_fields = true,
    }) catch return fail("{f}: its app config can't be read", .{ref});
    try oci.validateConfig(try std.fmt.allocPrint(arena, "{f}", .{ref}), config);

    try install.install(ctx, .{
        .manifest_digest = manifest_desc.digest,
        .manifest = manifest,
        .config = config,
        .source = ref_text,
    });
}

pub fn push(ctx: *Context, id: []const u8, ref_text: []const u8) !void {
    const arena = ctx.arena;
    var ref = try parseReference(ref_text);
    if (ref.digest != null) return fail("push to a tag, not a digest: {s}", .{ref_text});
    const installed = try ctx.store.readRef(arena, id) orelse return fail("{s} is not installed", .{id});
    ref.tag = ref.tag orelse if (Registry.Reference.isValidTag(installed.version))
        installed.version
    else
        return fail("{s}'s version \"{s}\" can't be a tag; add one: {s}:<tag>", .{ id, installed.version, ref_text });

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

fn parseReference(text: []const u8) !Registry.Reference {
    return Registry.Reference.parse(text) catch
        fail("\"{s}\" isn't an image reference like ghcr.io/owner/app:tag or localhost:5000/app@sha256:...", .{text});
}

/// Parses a fetched manifest, and checks it is a single zigsaw image zigsaw
/// can unpack.
fn parseManifest(arena: std.mem.Allocator, ref: Registry.Reference, bytes: []const u8) !oci.Manifest {
    const Probe = struct { mediaType: ?[]const u8 = null, manifests: ?[]const std.json.Value = null };
    const probe = std.json.parseFromSliceLeaky(Probe, arena, bytes, .{ .ignore_unknown_fields = true }) catch
        return fail("{f} returned a manifest that isn't JSON", .{ref});
    if (probe.manifests != null)
        return fail("{f} is a multi-platform index, not a zigsaw image", .{ref});

    const manifest = std.json.parseFromSliceLeaky(oci.Manifest, arena, bytes, .{ .ignore_unknown_fields = true }) catch
        return fail("{f} returned a manifest zigsaw can't read", .{ref});
    if (!std.mem.eql(u8, manifest.config.mediaType, oci.media_type.config))
        return fail("{f} is not a zigsaw app (its config type is {s}; it may be a container image)", .{ ref, manifest.config.mediaType });
    for (manifest.layers) |l| {
        if (!std.mem.eql(u8, l.mediaType, oci.media_type.layer_tar))
            return fail("{f} has a layer of type {s}, which zigsaw can't unpack", .{ ref, l.mediaType });
    }
    return manifest;
}
