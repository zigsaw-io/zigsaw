//! `zigsaw pull` and `zigsaw push`: installing apps from OCI registries and
//! publishing them there. An image's manifest travels byte for byte, so its
//! digest is the same everywhere.
//!
//! An image can be named in full, `<registry>/<repository>[:tag][@digest]`,
//! or by app id alone, `<app-id>[:tag][@digest]`, for the image of that app in
//! the default registry: `org.nodejs.node` is ghcr.io/zigsaw-io/org.nodejs.node.
//! A name may stand for a multi-platform index: then it's the index's image
//! for Windows on x64 (see `resolveImage`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Registry = @import("Registry.zig");
const Store = @import("Store.zig");
const info = @import("info.zig");
const install = @import("install.zig");
const oci = @import("oci.zig");
const prompt = @import("prompt.zig");
const repeat = @import("testing.zig").repeat;
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
    /// The version installed, for `update` and a `pull` over it: then only
    /// what the image may reach beyond it is told, and asked about.
    installed: ?Installed = null,
    /// Whether to ask before downloading the layers.
    consent: Consent = .not_asked,

    pub const Installed = struct { version: []const u8, access: oci.Access };
};

pub const Consent = enum {
    /// What a build pulls: the images its recipe pins.
    not_asked,
    /// `pull` and `update`.
    ask,
    /// `--yes`: told, not asked.
    given,
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
    const fetched = try resolveImage(&registry, ref, opts.unless) orelse return null;
    ctx.timed(start, "fetch manifest", .{});
    if (fetched.index) |index| note("{f} is a multi-platform index ({s}): its image for windows/amd64 is {s}", .{ ref, oci.shortDigest(index), fetched.digest });
    const manifest = fetched.manifest;

    // The config first: the image has to be a zigsaw app, and the one asked
    // for, before any layer is worth downloading.
    if (!oci.isConfigType(manifest.config.mediaType))
        return fail("{f} is not a zigsaw app (its config type is {s}; it may be a container image)", .{ ref, manifest.config.mediaType });
    try downloadBlob(ctx, &registry, manifest.config);
    const config = try oci.parseConfig(arena, target.text, manifest.config.mediaType, try ctx.store.readBlob(arena, manifest.config.digest));
    try oci.validateLayers(target.text, manifest, config);
    if (target.app_id) |id| if (!std.ascii.eqlIgnoreCase(id, config.id))
        return fail("{f} holds {s}, not {s}", .{ ref, config.id, id });
    // What it is and may reach, before any layer is downloaded, so that
    // nobody installs an app without seeing it, or agreeing to it. A pull
    // over an installed version asks only about what's new, as `update`.
    var told = opts;
    if (told.installed == null and told.consent != .not_asked) if (try ctx.store.readRef(arena, config.id)) |r| {
        const installed = try ctx.store.readImage(arena, r.id, r.manifest);
        told.installed = .{ .version = r.version, .access = try .of(arena, installed.config) };
    };
    try agree(ctx, manifest, config, told);

    try downloadBlobs(ctx, &registry, manifest.layers);
    const manifest_desc = try ctx.store.putBlob(arena, fetched.bytes, oci.media_type.manifest);
    return .{
        .manifest_digest = manifest_desc.digest,
        .manifest = manifest,
        .config = config,
        .source = target.text,
        .described = true,
    };
}

/// An image's manifest and config, as a registry has them.
pub const Info = struct {
    target: Target,
    manifest_digest: []const u8,
    /// The multi-platform index the image is in, if the target names one.
    index: ?[]const u8 = null,
    manifest: oci.Manifest,
    config: oci.AppConfig,
};

/// Reads an image's manifest and config from its registry, without its
/// layers: what `info` shows and the catalog lists. The config stays in the
/// store as a blob.
pub fn fetchInfo(ctx: *Context, image_text: []const u8) !Info {
    const arena = ctx.arena;
    const target = try resolve(ctx, image_text);
    var registry: Registry = undefined;
    try registry.init(ctx, target.ref, "pull");
    defer registry.deinit();
    const fetched = (try resolveImage(&registry, target.ref, null)).?;
    const manifest = fetched.manifest;
    if (!oci.isConfigType(manifest.config.mediaType))
        return fail("{f} is not a zigsaw app (its config type is {s}; it may be a container image)", .{ target.ref, manifest.config.mediaType });
    try downloadBlob(ctx, &registry, manifest.config);
    const config = try oci.parseConfig(arena, target.text, manifest.config.mediaType, try ctx.store.readBlob(arena, manifest.config.digest));
    try oci.validateLayers(target.text, manifest, config);
    if (target.app_id) |id| if (!std.ascii.eqlIgnoreCase(id, config.id))
        return fail("{f} holds {s}, not {s}", .{ target.ref, config.id, id });
    return .{ .target = target, .manifest_digest = fetched.digest, .index = fetched.index, .manifest = manifest, .config = config };
}

/// Tells what an app about to be installed is and may reach, and asks
/// whether to go on; for an update, only what it may reach beyond the
/// installed version, if anything, and asks only then.
fn agree(ctx: *Context, manifest: oci.Manifest, cfg: oci.AppConfig, opts: FetchOptions) !void {
    const arena = ctx.arena;
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    if (opts.installed) |before| {
        const added = try oci.addedAccess(arena, before.access, try .of(arena, cfg));
        if (added.isEmpty()) {
            const permits = try oci.describePermissions(arena, cfg.permissions);
            const was = try oci.describePermissions(arena, before.access.permissions);
            if (!std.mem.eql(u8, permits, was)) note("{s} {s} now permits {s}; it permitted {s}", .{ cfg.id, cfg.version, permits, was });
            return;
        }
        try w.print("{s} {s} may reach more than {s}:\n", .{ cfg.id, cfg.version, before.version });
        if (added.permissions.sandbox != null or added.permissions.network or added.permissions.filesystem.len > 0)
            try info.writeLine(w, "permits", try oci.describePermissions(arena, added.permissions));
        if (added.uses.len > 0)
            try info.writeLine(w, "uses", try oci.describeUses(arena, added.uses));
        if (added.registry.len > 0)
            try info.writeLine(w, "keeps", try std.fmt.allocPrint(arena, "{s} with its data", .{try oci.describeRegistry(arena, added.registry)}));
    } else {
        try info.writeName(w, cfg);
        try info.writeContents(ctx, w, manifest, cfg);
    }
    Context.printStderr("{s}", .{out.written()});
    if (opts.consent != .ask) return;

    const what = if (opts.installed != null) "updated" else "installed";
    switch (try prompt.askYesNo(ctx, if (opts.installed != null) "Update it?" else "Install it?")) {
        .yes => {},
        .no => return fail("{s} {s} wasn't {s}", .{ cfg.id, cfg.version, what }),
        .none => return fail("{s} {s} wasn't {s}: nothing answered whether to go on. Run it at a console, or add --yes", .{ cfg.id, cfg.version, what }),
    }
}

/// Downloads the blobs the store doesn't have, several at a time: an app's
/// runtimes are layers of its image. Each worker speaks to the registry with
/// its own connection and the token `registry` has already.
fn downloadBlobs(ctx: *Context, registry: *Registry, descs: []const oci.Descriptor) !void {
    const arena = ctx.arena;
    var missing: std.ArrayList(oci.Descriptor) = .empty;
    for (descs) |desc| {
        const hex = oci.digestHex(desc.digest) orelse return fail("{f}: malformed digest {s}", .{ registry.ref, desc.digest });
        if (!try Store.exists(ctx.io, try ctx.store.blobPath(arena, hex))) try missing.append(arena, desc);
    }
    if (missing.items.len <= 1) {
        for (missing.items) |desc| try downloadBlob(ctx, registry, desc);
        return;
    }

    var next: std.atomic.Value(usize) = .init(0);
    const workers = try arena.alloc(BlobWorker, @min(missing.items.len, max_blob_workers));
    var ready: usize = 0;
    defer for (workers[0..ready]) |*w| w.registry.deinit();
    for (workers) |*w| {
        w.* = .{ .ctx = ctx, .registry = undefined, .descs = missing.items, .next = &next };
        try w.registry.init(ctx, registry.ref, registry.actions);
        ready += 1;
        w.registry.pull_from = registry.pull_from;
        w.registry.authorization = registry.authorization;
        w.registry.credential = registry.credential;
        w.registry.looked_up = registry.looked_up;
    }
    var group: Io.Group = .init;
    for (workers) |*w| group.concurrent(ctx.io, BlobWorker.run, .{w}) catch w.run();
    group.await(ctx.io) catch |err| return err;
    for (workers) |w| if (w.err) |err| if (err == error.Failed) return error.Failed;
    for (workers) |w| if (w.err) |err| return err;
}

const max_blob_workers = 4;

const BlobWorker = struct {
    ctx: *Context,
    registry: Registry,
    descs: []const oci.Descriptor,
    /// Index of the next blob to take, shared by all workers.
    next: *std.atomic.Value(usize),
    err: ?anyerror = null,

    fn run(w: *BlobWorker) void {
        while (true) {
            const i = w.next.fetchAdd(1, .monotonic);
            if (i >= w.descs.len) return;
            downloadBlob(w.ctx, &w.registry, w.descs[i]) catch |err| {
                w.err = err;
                _ = w.next.swap(w.descs.len, .monotonic);
                return;
            };
        }
    }
};

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

pub const PushOptions = struct {
    /// Also push the files the app was built from (see `pushSources`).
    sources: bool = false,
};

/// Publishes an installed app. Without an image, it goes to its own image in
/// the default registry. The tag defaults to the app's version.
pub fn push(ctx: *Context, id: []const u8, image_text: ?[]const u8, opts: PushOptions) !void {
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
    const image = try ctx.store.readImage(arena, id, installed.manifest);
    const mounts = try mountSources(arena, ref, installed.source, image.manifest, image.config);

    var registry: Registry = undefined;
    try registry.init(ctx, ref, "pull,push");
    defer registry.deinit();
    registry.pull_from = try mounts.repositories(arena);

    // Blobs before the manifest that refers to them; skip what's already there.
    for ([_][]const oci.Descriptor{ &.{image.manifest.config}, image.manifest.layers }) |descs| {
        for (descs) |desc| try uploadIfMissing(ctx, &registry, desc, try ctx.store.blobPath(arena, oci.digestHex(desc.digest).?), mounts.by_digest.get(desc.digest));
    }
    try registry.pushManifest(ref.tag.?, manifest_bytes);
    note("pushed {s} {s} to {f}\n  manifest {s}", .{ id, installed.version, ref, installed.manifest });
    if (opts.sources) try pushSources(ctx, &registry, installed);
}

/// Keeps the files an app was built from next to its image, so that a build
/// of its recipe still finds them if they're gone from where they came from
/// (see Fetcher.fromSources): a manifest in the image's repository, tagged
/// by the image's digest, whose layers are the build's pinned sources and
/// what its vendor steps made, from the download cache. A registry keeps
/// blobs a manifest refers to, and serves them by digest, which is their
/// sha256.
fn pushSources(ctx: *Context, registry: *Registry, installed: Store.Ref) !void {
    const io = ctx.io;
    const arena = ctx.arena;
    const image = try ctx.store.readImage(arena, installed.id, installed.manifest);
    const build = image.config.build orelse {
        note("  {s} {s} wasn't built from a recipe here, so it has no sources to push", .{ installed.id, installed.version });
        return;
    };
    var hashes: std.ArrayList([]const u8) = .empty;
    for (build.sources) |h| if (!contains(hashes.items, h)) try hashes.append(arena, h);
    if (build.vendor) |v| for (v.map.values()) |h| if (!contains(hashes.items, h)) try hashes.append(arena, h);

    var layers: std.ArrayList(oci.Descriptor) = .empty;
    var missing: usize = 0;
    for (hashes.items) |h| {
        const p = try ctx.store.path(arena, &.{ "cache", "downloads", h });
        if (!try Store.exists(io, p)) {
            missing += 1;
            continue;
        }
        const file = try Store.sha256File(io, p);
        if (!std.mem.eql(u8, &file.hex, h)) return fail("{s} in the download cache isn't what its name says; delete it and build {s} again", .{ p, installed.id });
        const desc: oci.Descriptor = .{ .mediaType = oci.media_type.source, .digest = try std.fmt.allocPrint(arena, "sha256:{s}", .{h}), .size = file.size };
        try uploadIfMissing(ctx, registry, desc, p, null);
        try layers.append(arena, desc);
    }
    if (missing > 0) note("  {d} of its sources aren't in the download cache (local files, or deleted by prune --downloads), so they aren't pushed", .{missing});
    if (layers.items.len == 0) return;

    const config: oci.SourcesConfig = .{ .id = installed.id, .version = installed.version, .image = installed.manifest };
    const config_desc = try ctx.store.putBlob(arena, try oci.toJson(arena, config), oci.media_type.sources_config);
    try uploadIfMissing(ctx, registry, config_desc, try ctx.store.blobPath(arena, oci.digestHex(config_desc.digest).?), null);
    var annotations: std.json.ArrayHashMap([]const u8) = .{};
    try annotations.map.put(arena, "org.opencontainers.image.title", try std.fmt.allocPrint(arena, "{s} {s} sources", .{ installed.id, installed.version }));
    const manifest: oci.Manifest = .{ .config = config_desc, .layers = layers.items, .annotations = annotations };
    const tag = try oci.sourcesTag(arena, installed.manifest);
    try registry.pushManifest(tag, try oci.toJson(arena, manifest));
    note("pushed its {d} source file(s) next to it, as {s}", .{ layers.items.len, tag });
}

/// Uploads a blob unless the repository has it, or mounts it from
/// `mount_from` if the registry can.
pub fn uploadIfMissing(ctx: *Context, registry: *Registry, desc: oci.Descriptor, path: []const u8, mount_from: ?[]const u8) !void {
    if (try registry.hasBlob(desc.digest)) return;
    const start = ctx.now();
    switch (try registry.startUpload(desc.digest, mount_from)) {
        .mounted => {
            if (desc.size > 1 << 20) note("mounted {s} ({d} bytes) from {s}", .{ desc.digest, desc.size, mount_from.? });
            ctx.timed(start, "mount {s}", .{desc.digest});
        },
        .started => |started| {
            if (mount_from) |from| if (ctx.verbose) note("  couldn't mount {s} from {s}", .{ oci.shortDigest(desc.digest), from });
            if (desc.size > 1 << 20) note("uploading {s} ({d} bytes)", .{ desc.digest, desc.size });
            try registry.finishUpload(started, desc, path);
            ctx.timed(start, "upload {s}", .{desc.digest});
        },
    }
}

/// Where on the target's registry a pushed image's blobs may be already, so
/// that they're mounted rather than uploaded: by digest, the repository.
const Mounts = struct {
    by_digest: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    /// Each repository once.
    fn repositories(m: Mounts, arena: std.mem.Allocator) ![]const []const u8 {
        var repos: std.ArrayList([]const u8) = .empty;
        for (m.by_digest.values()) |r| if (!contains(repos.items, r)) try repos.append(arena, r);
        return repos.items;
    }
};

/// - Every blob in the repository the app was pulled from (`pulled_from`, as
///   its ref records it), if that's on the target's registry.
/// - Otherwise each runtime's layer in the runtime's own repository there,
///   in the default layout: next to the target, named by the runtime's id,
///   where `zigsaw push <runtime id>` puts it.
fn mountSources(arena: std.mem.Allocator, target: Registry.Reference, pulled_from: ?[]const u8, manifest: oci.Manifest, config: oci.AppConfig) !Mounts {
    var m: Mounts = .{};
    if (pulled_from) |text| if (Registry.Reference.parse(text)) |pulled| {
        if (std.ascii.eqlIgnoreCase(pulled.host, target.host) and !std.mem.eql(u8, pulled.repository, target.repository)) {
            try m.by_digest.put(arena, manifest.config.digest, pulled.repository);
            for (manifest.layers) |l| try m.by_digest.put(arena, l.digest, pulled.repository);
            return m;
        }
    } else |_| {};
    const namespace = if (std.mem.lastIndexOfScalar(u8, target.repository, '/')) |i| target.repository[0 .. i + 1] else "";
    for (config.runtimes.map.values()) |r| {
        const repository = try std.mem.concat(arena, u8, &.{ namespace, try std.ascii.allocLowerString(arena, r.id) });
        if (!std.mem.eql(u8, repository, target.repository)) try m.by_digest.put(arena, r.layer, repository);
    }
    return m;
}

fn contains(hashes: []const []const u8, h: []const u8) bool {
    for (hashes) |x| if (std.mem.eql(u8, x, h)) return true;
    return false;
}

/// Downloads the file with this sha256 from the sources kept next to app
/// `id`'s image in the default registry (see `pushSources`) to `dest`. Null
/// if the repository doesn't have it.
pub fn fetchSource(ctx: *Context, id: []const u8, sha256: []const u8, dest: []const u8) !?Store.FileHash {
    const target = try resolve(ctx, id);
    var registry: Registry = undefined;
    try registry.init(ctx, target.ref, "pull");
    defer registry.deinit();
    return registry.downloadBlobByDigest(try std.fmt.allocPrint(ctx.arena, "sha256:{s}", .{sha256}), dest);
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
pub fn parseManifest(arena: std.mem.Allocator, ref: Registry.Reference, bytes: []const u8) !oci.Manifest {
    return switch (try classify(arena, ref, bytes)) {
        .image => |m| m,
        .index => fail("{f} is a multi-platform index, not a single image", .{ref}),
    };
}

/// The digest of the image `image_text` names in its registry (in an index,
/// its image for windows/amd64), without downloading anything else.
pub fn manifestDigest(ctx: *Context, image_text: []const u8) ![]const u8 {
    const target = try resolve(ctx, image_text);
    var registry: Registry = undefined;
    try registry.init(ctx, target.ref, "pull");
    defer registry.deinit();
    return (try resolveImage(&registry, target.ref, null)).?.digest;
}

/// An image's manifest as its registry has it: the one a reference names, or
/// when that's a multi-platform index, the index's image for Windows on x64,
/// the platform zigsaw runs.
const Resolved = struct {
    bytes: []const u8,
    digest: []const u8,
    manifest: oci.Manifest,
    /// The index's digest, if the reference named one.
    index: ?[]const u8 = null,
};

/// Fetches the manifest of the image `ref` names; null if its digest is
/// `unless`, without fetching more. A digest in `ref` names exactly what it
/// fetches first, the index or the image.
fn resolveImage(registry: *Registry, ref: Registry.Reference, unless: ?[]const u8) !?Resolved {
    const arena = registry.ctx.arena;
    const top = try registry.fetchManifest();
    if (ref.digest) |want| if (!std.mem.eql(u8, want, top.digest))
        return fail("{f} returned a manifest with digest {s}", .{ ref, top.digest });
    const entries = switch (try classify(arena, ref, top.bytes)) {
        .image => |m| {
            if (unless) |d| if (std.mem.eql(u8, d, top.digest)) return null;
            return .{ .bytes = top.bytes, .digest = top.digest, .manifest = m };
        },
        .index => |entries| entries,
    };
    const entry = pickPlatform(entries) orelse
        return fail("{f} is a multi-platform index {s}; none for windows/amd64, which zigsaw runs", .{ ref, try describePlatforms(arena, entries) });
    if (unless) |d| if (std.mem.eql(u8, d, entry.digest)) return null;
    const child = try registry.fetchManifestRef(entry.digest);
    if (!std.mem.eql(u8, child.digest, entry.digest))
        return fail("{f} returned a manifest with digest {s} for {s}", .{ ref, child.digest, entry.digest });
    return switch (try classify(arena, ref, child.bytes)) {
        .image => |m| .{ .bytes = child.bytes, .digest = child.digest, .manifest = m, .index = top.digest },
        .index => fail("{f}: its entry for windows/amd64 is an index too, which zigsaw doesn't follow", .{ref}),
    };
}

/// An entry of a multi-platform index (OCI's, or Docker's manifest list).
const IndexEntry = struct {
    mediaType: ?[]const u8 = null,
    digest: []const u8,
    platform: ?struct {
        os: []const u8 = "",
        architecture: []const u8 = "",
        variant: ?[]const u8 = null,
    } = null,
};

const Parsed = union(enum) {
    image: oci.Manifest,
    index: []const IndexEntry,
};

/// Parses a fetched manifest: an image's, or an index's.
fn classify(arena: std.mem.Allocator, ref: Registry.Reference, bytes: []const u8) !Parsed {
    const Probe = struct { mediaType: ?[]const u8 = null, manifests: ?[]const std.json.Value = null };
    const probe = std.json.parseFromSliceLeaky(Probe, arena, bytes, .{ .ignore_unknown_fields = true }) catch
        return fail("{f} returned a manifest that isn't JSON", .{ref});
    if (probe.manifests != null) {
        const Index = struct { manifests: []const IndexEntry };
        const index = std.json.parseFromSliceLeaky(Index, arena, bytes, .{ .ignore_unknown_fields = true }) catch
            return fail("{f} returned an index zigsaw can't read", .{ref});
        return .{ .index = index.manifests };
    }
    return .{ .image = std.json.parseFromSliceLeaky(oci.Manifest, arena, bytes, .{ .ignore_unknown_fields = true }) catch
        return fail("{f} returned a manifest zigsaw can't read", .{ref}) };
}

/// The index's first entry for Windows on x64.
fn pickPlatform(entries: []const IndexEntry) ?IndexEntry {
    for (entries) |e| {
        const p = e.platform orelse continue;
        if (std.ascii.eqlIgnoreCase(p.os, "windows") and std.ascii.eqlIgnoreCase(p.architecture, "amd64")) return e;
    }
    return null;
}

/// "with images for linux/amd64, linux/arm64/v8": each platform once,
/// without the "unknown/unknown" of attestations.
fn describePlatforms(arena: std.mem.Allocator, entries: []const IndexEntry) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (entries) |e| {
        const p = e.platform orelse continue;
        if (std.mem.eql(u8, p.os, "unknown")) continue;
        const name = if (p.variant) |v|
            try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ p.os, p.architecture, v })
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ p.os, p.architecture });
        if (!contains(names.items, name)) try names.append(arena, name);
    }
    if (names.items.len == 0) return "without platforms";
    return std.fmt.allocPrint(arena, "with images for {s}", .{try std.mem.join(arena, ", ", names.items)});
}

test "indexes: the image for windows/amd64, or the platforms there are" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ref = try Registry.Reference.parse("ghcr.io/a/b:1");
    const d = "sha256:" ++ repeat("a", 64);
    const w = "sha256:" ++ repeat("b", 64);

    // Docker's manifest list, with an attestation, as buildx makes them.
    const list = "{\"schemaVersion\":2,\"mediaType\":\"application/vnd.docker.distribution.manifest.list.v2+json\",\"manifests\":[" ++
        "{\"mediaType\":\"application/vnd.docker.distribution.manifest.v2+json\",\"digest\":\"" ++ d ++ "\",\"size\":1,\"platform\":{\"architecture\":\"arm64\",\"os\":\"linux\",\"variant\":\"v8\"}}," ++
        "{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"" ++ d ++ "\",\"size\":1,\"platform\":{\"architecture\":\"unknown\",\"os\":\"unknown\"}}," ++
        "{\"mediaType\":\"application/vnd.docker.distribution.manifest.v2+json\",\"digest\":\"" ++ w ++ "\",\"size\":1,\"platform\":{\"architecture\":\"amd64\",\"os\":\"windows\",\"os.version\":\"10.0.26100.1\"}}]}";
    const parsed = try classify(arena, ref, list);
    try std.testing.expectEqualStrings(w, pickPlatform(parsed.index).?.digest);

    // An OCI index without one.
    const linux = "{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.index.v1+json\",\"manifests\":[" ++
        "{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"" ++ d ++ "\",\"size\":1,\"platform\":{\"architecture\":\"amd64\",\"os\":\"linux\"}}," ++
        "{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"" ++ d ++ "\",\"size\":1,\"platform\":{\"architecture\":\"amd64\",\"os\":\"linux\"}}," ++
        "{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"" ++ d ++ "\",\"size\":1}]}";
    const entries = (try classify(arena, ref, linux)).index;
    try std.testing.expectEqual(null, pickPlatform(entries));
    try std.testing.expectEqualStrings("with images for linux/amd64", try describePlatforms(arena, entries));
    try std.testing.expectEqualStrings("with images for linux/arm64/v8", try describePlatforms(arena, (try classify(arena, ref, list)).index[0..2]));
    try std.testing.expectEqualStrings("without platforms", try describePlatforms(arena, entries[2..]));

    // An image's manifest is one.
    const image = "{\"schemaVersion\":2,\"config\":{\"mediaType\":\"x\",\"digest\":\"" ++ d ++ "\",\"size\":1},\"layers\":[]}";
    try std.testing.expectEqualStrings(d, (try classify(arena, ref, image)).image.config.digest);
}

test mountSources {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const node_layer = "sha256:" ++ repeat("a", 64);
    const own_layer = "sha256:" ++ repeat("b", 64);
    const config_digest = "sha256:" ++ repeat("c", 64);
    const layer = struct {
        fn of(d: []const u8) oci.Descriptor {
            return .{ .mediaType = oci.media_type.layer_tar_gzip, .digest = d, .size = 1 };
        }
    }.of;
    const manifest: oci.Manifest = .{
        .config = .{ .mediaType = oci.media_type.config, .digest = config_digest, .size = 1 },
        .layers = &.{ layer(node_layer), layer(own_layer) },
    };
    var config: oci.AppConfig = .{ .id = "io.prettier.prettier", .version = "3", .command = "${node}\\node.exe" };
    try config.runtimes.map.put(arena, "node", .{ .id = "org.nodejs.node", .version = "24", .image = "sha256:" ++ repeat("d", 64), .layer = node_layer });
    const target = try Registry.Reference.parse("ghcr.io/zigsaw-io/io.prettier.prettier:3");

    // Built here: the runtime's layer, from the runtime's repository next to the target.
    const built = try mountSources(arena, target, "D:\\recipes\\prettier.json", manifest, config);
    try std.testing.expectEqualStrings("zigsaw-io/org.nodejs.node", built.by_digest.get(node_layer).?);
    try std.testing.expectEqual(null, built.by_digest.get(own_layer));
    const repositories = try built.repositories(arena);
    try std.testing.expectEqual(1, repositories.len);
    try std.testing.expectEqualStrings("zigsaw-io/org.nodejs.node", repositories[0]);

    // Pulled from elsewhere on the same registry: everything, from there.
    const pulled = try mountSources(arena, target, "ghcr.io/me/prettier:3", manifest, config);
    for ([_][]const u8{ config_digest, node_layer, own_layer }) |d| try std.testing.expectEqualStrings("me/prettier", pulled.by_digest.get(d).?);

    // Pulled from another registry, or from the target itself: only the runtime's layer.
    for ([_][]const u8{ "docker.io/me/prettier:3", "ghcr.io/zigsaw-io/io.prettier.prettier:2" }) |source| {
        const m = try mountSources(arena, target, source, manifest, config);
        try std.testing.expectEqual(1, m.by_digest.count());
        try std.testing.expectEqualStrings("zigsaw-io/org.nodejs.node", m.by_digest.get(node_layer).?);
    }

    // A runtime pushed to a repository of its own id, at the registry's top level.
    const top = try mountSources(arena, try Registry.Reference.parse("localhost:5000/io.prettier.prettier"), null, manifest, config);
    try std.testing.expectEqualStrings("org.nodejs.node", top.by_digest.get(node_layer).?);
}
