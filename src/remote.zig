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
const RemoteBlob = @import("RemoteBlob.zig");
const Store = @import("Store.zig");
const format = @import("format.zig");
const info = @import("info.zig");
const install = @import("install.zig");
const lazy = @import("lazy.zig");
const oci = @import("oci.zig");
const prompt = @import("prompt.zig");
const repeat = @import("testing.zig").repeat;
const signature = @import("signature.zig");
const sigstore = @import("sigstore.zig");
const trust = @import("trust.zig");
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
    /// `--lazy`: indexed layers the store lacks become placeholders, fetched
    /// as they're used, while they download (see lazy.zig).
    lazy: bool = false,

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

    // Before anything of the image is downloaded. A build's images aren't checked:
    // its recipe pins them by digest, which says exactly what they are.
    if (opts.consent != .not_asked) switch (try checkSignature(ctx, &registry, ref, fetched.index, fetched.digest)) {
        .no_key => note("{f}: no key here for its registry, so its signature wasn't checked (`zigsaw trust add` gives one)", .{ref}),
        .signed => |by| note("{f}: signed, by {s}", .{ ref, by }),
        .missing => note("warning: {f} isn't signed, though zigsaw knows whose signature counts for it. Whoever made it isn't known; in a later release, this will be refused", .{ref}),
        .wrong => |why| return fail("{f}: {s}. Nothing was installed", .{ ref, why }),
    };

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

    // With --lazy, the layers that can be fetched as they're used first, so
    // that a layer that can't goes on to download with the rest.
    var eager: std.ArrayList(oci.Descriptor) = .empty;
    var lazy_layers: std.ArrayList(oci.Descriptor) = .empty;
    errdefer for (lazy_layers.items) |l| {
        _ = ctx.store.deleteDeployment(arena, l.digest) catch {};
    };
    for (manifest.layers) |l| {
        const have = try Store.exists(ctx.io, try ctx.store.blobPath(arena, oci.digestHex(l.digest).?));
        if (opts.lazy and !have and lazy.eligible(ctx, l)) {
            if (try lazy.prepare(ctx, &registry, l) == .lazy) {
                note("  lazy     layer {s} ({d} bytes): its files are fetched as they're used; the rest downloads meanwhile", .{ oci.shortDigest(l.digest), l.size });
                try lazy_layers.append(arena, l);
                continue;
            }
        }
        try eager.append(arena, l);
    }
    try downloadBlobs(ctx, &registry, eager.items);
    const manifest_desc = try ctx.store.putBlob(arena, fetched.bytes, oci.media_type.manifest);
    return .{
        .manifest_digest = manifest_desc.digest,
        .manifest = manifest,
        .config = config,
        .source = target.text,
        .described = true,
    };
}

/// What a look for an image's signature found.
pub const SignatureCheck = union(enum) {
    /// Nobody's signature counts for this registry.
    no_key,
    /// Someone's counts here, and the image has no signature at all.
    missing,
    /// Whose signature is good: "key <fingerprint>", or who a certificate names.
    signed: []const u8,
    /// There's something where a signature goes, and it isn't good: why.
    wrong: []const u8,
};

/// Looks for a signature of the image `digest`, or of the index it's in, by someone
/// whose signature counts for its repository. A registry that won't say is an error,
/// not `missing`.
pub fn checkSignature(ctx: *Context, registry: *Registry, ref: Registry.Reference, index: ?[]const u8, digest: []const u8) !SignatureCheck {
    const repository = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ ref.host, ref.repository });
    const signers = try trust.forImage(ctx, repository);
    if (signers.len == 0) return .no_key;
    if (index) |i| switch (try checkSignatureOf(ctx, registry, signers, repository, i)) {
        .missing => {},
        else => |found| return found,
    };
    return checkSignatureOf(ctx, registry, signers, repository, digest);
}

/// Keyless first, beside the image under a tag of its own, then a key's, in cosign's
/// classic layout. Either being good will do; if neither is, what's wrong with the
/// keyless one says the most, as that's what's signed now.
fn checkSignatureOf(ctx: *Context, registry: *Registry, signers: []const trust.Signer, repository: []const u8, digest: []const u8) !SignatureCheck {
    const keyless = try checkKeyless(ctx, registry, signers, repository, digest);
    if (keyless == .signed) return keyless;
    const classic = try checkClassic(ctx, registry, signers, repository, digest);
    if (classic == .signed or keyless == .missing) return classic;
    return keyless;
}

fn checkKeyless(ctx: *Context, registry: *Registry, signers: []const trust.Signer, repository: []const u8, digest: []const u8) !SignatureCheck {
    const arena = ctx.arena;
    const found = try registry.fetchManifestIfThere(try signature.bundleTagFor(arena, digest)) orelse return .missing;
    const manifest = switch (try classify(arena, registry.ref, found.bytes)) {
        .image => |m| m,
        .index => return .{ .wrong = "what's where its signature goes isn't a signature" },
    };
    // What's signed is always the same for an image: its digest and repository.
    const payload = try signature.makePayload(arena, repository, digest);
    const roots = try sigstore.trustRoots(arena);
    var why: []const u8 = "what's where its signature goes has no signature in it";
    for (manifest.layers) |layer| {
        if (!std.mem.eql(u8, layer.mediaType, sigstore.bundle_media_type)) continue;
        if (layer.size > sigstore.max_bundle_size) {
            why = "its signature is too big to be one";
            continue;
        }
        const bundle = try arena.alloc(u8, @intCast(layer.size));
        var sink: Io.Writer = .fixed(bundle);
        const there = registry.getBlob(layer.digest, .{ .len = layer.size }, &sink) catch |err| switch (err) {
            error.WriteFailed => {
                why = "its signature is bigger than it says";
                continue;
            },
            else => |e| return e,
        };
        if (!there or sink.end != bundle.len) {
            why = "its signature isn't there";
            continue;
        }
        var keyless_signers: usize = 0;
        for (signers) |signer| switch (signer) {
            .key => {},
            .keyless => |identity| {
                keyless_signers += 1;
                switch (try sigstore.verify(arena, roots, bundle, payload, identity)) {
                    .good => return .{ .signed = try std.fmt.allocPrint(arena, "{f}", .{signer}) },
                    .bad => |b| why = try std.fmt.allocPrint(arena, "its signature isn't good: {s}", .{b}),
                }
            },
        };
        if (keyless_signers == 0) why = "it's signed keyless, and nobody's keyless signature counts for it";
    }
    return .{ .wrong = why };
}

fn checkClassic(ctx: *Context, registry: *Registry, signers: []const trust.Signer, repository: []const u8, digest: []const u8) !SignatureCheck {
    const arena = ctx.arena;
    const found = try registry.fetchManifestIfThere(try signature.tagFor(arena, digest)) orelse return .missing;
    const manifest = switch (try classify(arena, registry.ref, found.bytes)) {
        .image => |m| m,
        .index => return .{ .wrong = "what's where its signature goes isn't a signature" },
    };
    // Any good one will do: there may be several, and any of them wrong says nothing
    // about the others. If none is, what a trusted key signed says the most.
    var why: []const u8 = "what's where its signature goes has no signature in it";
    var by_a_key = false;
    for (manifest.layers) |layer| {
        if (!std.mem.eql(u8, layer.mediaType, signature.payload_media_type)) continue;
        const annotations = layer.annotations orelse continue;
        const text = annotations.map.get(signature.signature_annotation) orelse continue;
        if (layer.size > signature.max_payload_size) {
            why = "its signature is about something too big to be an image's";
            continue;
        }
        const payload = try arena.alloc(u8, @intCast(layer.size));
        var sink: Io.Writer = .fixed(payload);
        const there = registry.getBlob(layer.digest, .{ .len = layer.size }, &sink) catch |err| switch (err) {
            error.WriteFailed => {
                why = "its signature is about something bigger than it says";
                continue;
            },
            else => |e| return e,
        };
        if (!there or sink.end != payload.len) {
            why = "what its signature is about isn't there";
            continue;
        }
        const key = for (signers) |signer| switch (signer) {
            .key => |k| if (k.verifies(payload, text)) break signer,
            .keyless => {},
        } else {
            if (!by_a_key) why = "it's signed, but not by any key that counts for it";
            continue;
        };
        by_a_key = true;
        signature.checkPayload(arena, payload, repository, digest) catch |err| {
            why = switch (err) {
                error.OutOfMemory => |e| return e,
                error.NotAPayload => "what its signature says isn't what an image's says",
                error.OtherImage => "its signature is of another image",
                error.OtherRepository => "its signature is of an image in another repository",
            };
            continue;
        };
        return .{ .signed = try std.fmt.allocPrint(arena, "{f}", .{key}) };
    }
    return .{ .wrong = why };
}

/// What to sign for the image `image_text` names, as it is in its registry now.
pub fn signaturePayload(ctx: *Context, image_text: []const u8) ![]const u8 {
    const target = try resolve(ctx, image_text);
    const repository = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ target.ref.host, target.ref.repository });
    return signature.makePayload(ctx.arena, repository, try manifestDigest(ctx, image_text));
}

/// Puts a signature someone made of `payload` beside the image it names, in cosign's
/// classic layout, keeping those already there: during a change of keys, an image has
/// both. Which image it is comes from the payload, so that the tag can't have moved
/// since it was signed.
pub fn pushSignature(ctx: *Context, image_text: []const u8, payload: []const u8, text: []const u8) !void {
    const arena = ctx.arena;
    const target = try resolve(ctx, image_text);
    const named = try payloadFor(ctx, target, payload);

    var registry: Registry = undefined;
    try registry.init(ctx, target.ref, "pull,push");
    defer registry.deinit();
    const tag = try signature.tagFor(arena, named.digest);

    var layers: std.ArrayList(oci.Descriptor) = .empty;
    if (try registry.fetchManifestIfThere(tag)) |found| switch (try classify(arena, target.ref, found.bytes)) {
        .image => |m| try layers.appendSlice(arena, m.layers),
        .index => return fail("{s} in {f} isn't a signature, so it stays", .{ tag, target.ref }),
    };
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    for (layers.items) |layer| if (layer.annotations) |a| if (a.map.get(signature.signature_annotation)) |existing|
        if (std.mem.eql(u8, existing, trimmed)) {
            note("{s} has that signature already", .{tag});
            return;
        };

    var annotations: std.json.ArrayHashMap([]const u8) = .{};
    try annotations.map.put(arena, signature.signature_annotation, trimmed);
    var layer = try ctx.store.putBlob(arena, payload, signature.payload_media_type);
    layer.annotations = annotations;
    try uploadIfMissing(ctx, &registry, layer, try ctx.store.blobPath(arena, oci.digestHex(layer.digest).?), null);
    try layers.append(arena, layer);
    try pushSignatureManifest(ctx, &registry, tag, layers.items);
    note("signed {s}, as {s}", .{ named.digest, tag });
}

/// What `payload` names, having checked it's about the image `target` names.
fn payloadFor(ctx: *Context, target: Target, payload: []const u8) !signature.Payload {
    const named = signature.parsePayload(ctx.arena, payload) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.NotAPayload => return fail("that isn't what `zigsaw signature payload` prints", .{}),
    };
    const repository = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ target.ref.host, target.ref.repository });
    if (!std.ascii.eqlIgnoreCase(named.repository, repository))
        return fail("that payload is about {s}, not {s}", .{ named.repository, repository });
    if (oci.digestHex(named.digest) == null) return fail("that payload's digest isn't one: {s}", .{named.digest});
    return named;
}

/// Pushes a signature's manifest: `layers`, and a config as cosign writes one, which
/// names each layer, and that's all it does.
fn pushSignatureManifest(ctx: *Context, registry: *Registry, tag: []const u8, layers: []const oci.Descriptor) !void {
    const arena = ctx.arena;
    var diff_ids: std.ArrayList(u8) = .empty;
    for (layers, 0..) |l, i| try diff_ids.print(arena, "{s}\"{s}\"", .{ if (i == 0) "" else ",", l.digest });
    const config = try ctx.store.putBlob(arena, try std.fmt.allocPrint(arena,
        \\{{"architecture":"","config":{{}},"created":"0001-01-01T00:00:00Z","history":[{{"created":"0001-01-01T00:00:00Z"}}],"os":"","rootfs":{{"type":"layers","diff_ids":[{s}]}}}}
    , .{diff_ids.items}), "application/vnd.oci.image.config.v1+json");
    try uploadIfMissing(ctx, registry, config, try ctx.store.blobPath(arena, oci.digestHex(config.digest).?), null);
    const manifest: oci.Manifest = .{ .config = config, .layers = layers };
    try registry.pushManifest(tag, try oci.toJson(arena, manifest));
}

/// Puts a keyless signature of `payload`, a Sigstore bundle as `cosign sign-blob
/// --bundle` writes one, beside the image the payload names, under a tag of its own
/// (signature.bundleTagFor), keeping those already there. It's checked first, as
/// pull would check it: one that isn't good there would have every pull refuse the
/// image.
pub fn pushBundle(ctx: *Context, image_text: []const u8, payload_text: []const u8, bundle: []const u8) !void {
    const arena = ctx.arena;
    const target = try resolve(ctx, image_text);
    const payload = std.mem.trimEnd(u8, payload_text, "\r\n");
    const named = try payloadFor(ctx, target, payload);
    const repository = try std.fmt.allocPrint(arena, "{s}/{s}", .{ target.ref.host, target.ref.repository });
    // Pull checks a signature of exactly this, so that's what must have been signed.
    if (!std.mem.eql(u8, payload, try signature.makePayload(arena, repository, named.digest)))
        return fail("that isn't what `zigsaw signature payload` prints for {s}", .{repository});

    const roots = try sigstore.trustRoots(arena);
    var why: []const u8 = "nobody's keyless signature counts for it (`zigsaw trust add --keyless` gives one)";
    const by = for (try trust.forImage(ctx, repository)) |signer| switch (signer) {
        .key => {},
        .keyless => |identity| switch (try sigstore.verify(arena, roots, bundle, payload, identity)) {
            .good => break signer,
            .bad => |b| why = b,
        },
    } else return fail("that bundle isn't good for {s}: {s}. Nothing was pushed", .{ repository, why });

    var registry: Registry = undefined;
    try registry.init(ctx, target.ref, "pull,push");
    defer registry.deinit();
    const tag = try signature.bundleTagFor(arena, named.digest);

    var layers: std.ArrayList(oci.Descriptor) = .empty;
    if (try registry.fetchManifestIfThere(tag)) |found| switch (try classify(arena, target.ref, found.bytes)) {
        .image => |m| try layers.appendSlice(arena, m.layers),
        .index => return fail("{s} in {f} isn't a signature, so it stays", .{ tag, target.ref }),
    };
    var bundle_layer = try ctx.store.putBlob(arena, bundle, sigstore.bundle_media_type);
    for (layers.items) |layer| if (std.mem.eql(u8, layer.digest, bundle_layer.digest)) {
        note("{s} has that signature already", .{tag});
        return;
    };
    // The payload too, for whoever checks with cosign's verify-blob.
    const has_payload = for (layers.items) |layer| {
        if (std.mem.eql(u8, layer.mediaType, signature.payload_media_type)) break true;
    } else false;
    if (!has_payload) {
        const payload_layer = try ctx.store.putBlob(arena, payload, signature.payload_media_type);
        try uploadIfMissing(ctx, &registry, payload_layer, try ctx.store.blobPath(arena, oci.digestHex(payload_layer.digest).?), null);
        try layers.insert(arena, 0, payload_layer);
    }
    var annotations: std.json.ArrayHashMap([]const u8) = .{};
    try annotations.map.put(arena, "dev.zigsaw.signer", try std.fmt.allocPrint(arena, "{f}", .{by}));
    bundle_layer.annotations = annotations;
    try uploadIfMissing(ctx, &registry, bundle_layer, try ctx.store.blobPath(arena, oci.digestHex(bundle_layer.digest).?), null);
    try layers.append(arena, bundle_layer);
    try pushSignatureManifest(ctx, &registry, tag, layers.items);
    note("signed {s}, by {f}, as {s}", .{ named.digest, by, tag });
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
    var registry: Registry = undefined;
    const app = try fetchInfoOpen(ctx, image_text, &registry);
    registry.deinit();
    return app;
}

/// As `fetchInfo`, leaving `registry` open for reading the image's blobs;
/// the caller deinits it.
pub fn fetchInfoOpen(ctx: *Context, image_text: []const u8, registry_out: *Registry) !Info {
    return (try openInfo(ctx, image_text, registry_out, null)).?;
}

/// As `fetchInfo`, or null, having read only the manifest, if the image is
/// still the one with the digest `unless`: what `update --check` asks.
pub fn fetchInfoUnless(ctx: *Context, image_text: []const u8, unless: []const u8) !?Info {
    var registry: Registry = undefined;
    const app = try openInfo(ctx, image_text, &registry, unless);
    registry.deinit();
    return app;
}

/// Opens `registry_out`, which the caller deinits unless this fails.
fn openInfo(ctx: *Context, image_text: []const u8, registry_out: *Registry, unless: ?[]const u8) !?Info {
    const arena = ctx.arena;
    const target = try resolve(ctx, image_text);
    const registry = registry_out;
    try registry.init(ctx, target.ref, "pull");
    errdefer registry.deinit();
    const fetched = try resolveImage(registry, target.ref, unless) orelse return null;
    const manifest = fetched.manifest;
    if (!oci.isConfigType(manifest.config.mediaType))
        return fail("{f} is not a zigsaw app (its config type is {s}; it may be a container image)", .{ target.ref, manifest.config.mediaType });
    try downloadBlob(ctx, registry, manifest.config);
    const config = try oci.parseConfig(arena, target.text, manifest.config.mediaType, try ctx.store.readBlob(arena, manifest.config.digest));
    try oci.validateLayers(target.text, manifest, config);
    if (target.app_id) |id| if (!std.ascii.eqlIgnoreCase(id, config.id))
        return fail("{f} holds {s}, not {s}", .{ target.ref, config.id, id });
    return .{ .target = target, .manifest_digest = fetched.digest, .index = fetched.index, .manifest = manifest, .config = config };
}

/// What installing an image does to its app, as `agreeTo` tells and asks.
pub const Change = enum { install, update, rollback };

fn agree(ctx: *Context, manifest: oci.Manifest, cfg: oci.AppConfig, opts: FetchOptions) !void {
    try agreeTo(ctx, manifest, cfg, opts.installed, opts.consent, if (opts.installed != null) .update else .install);
}

/// Tells what an app about to be installed is and may reach, and asks
/// whether to go on; over an installed version (an update, a rollback), only
/// what it may reach beyond that one, if anything, and asks only then.
pub fn agreeTo(ctx: *Context, manifest: oci.Manifest, cfg: oci.AppConfig, installed: ?FetchOptions.Installed, consent: Consent, change: Change) !void {
    const arena = ctx.arena;
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    if (installed) |before| {
        const added = try oci.addedAccess(arena, before.access, try .of(arena, cfg));
        if (added.isEmpty()) {
            const permits = try oci.describePermissions(arena, cfg.permissions);
            const was = try oci.describePermissions(arena, before.access.permissions);
            if (!std.mem.eql(u8, permits, was)) note("{s} {s} now permits {s}; it permitted {s}", .{ cfg.id, cfg.version, permits, was });
            return;
        }
        try w.print("{s} {s} may reach more than {s}:\n", .{ cfg.id, cfg.version, before.version });
        try writeAddedAccess(arena, w, added);
    } else {
        try info.writeName(w, cfg);
        try info.writeContents(ctx, w, manifest, cfg);
    }
    Context.printStderr("{s}", .{out.written()});
    if (consent != .ask) return;

    const question = switch (change) {
        .install => "Install it?",
        .update => "Update it?",
        .rollback => "Go back to it?",
    };
    const answer = try prompt.askYesNo(ctx, question);
    if (answer == .yes) return;
    const why = if (answer == .none) ": nothing answered whether to go on. Run it at a console, or add --yes" else "";
    return switch (change) {
        .install => fail("{s} {s} wasn't installed{s}", .{ cfg.id, cfg.version, why }),
        .update => fail("{s} {s} wasn't updated{s}", .{ cfg.id, cfg.version, why }),
        .rollback => fail("{s} stays at {s}{s}", .{ cfg.id, installed.?.version, why }),
    };
}

/// What a new version may reach beyond the installed one, a line for each
/// kind of thing.
pub fn writeAddedAccess(arena: std.mem.Allocator, w: *Io.Writer, added: oci.Access) !void {
    if (added.permissions.sandbox != null or added.permissions.network or added.permissions.filesystem.len > 0)
        try info.writeLine(w, "permits", try oci.describePermissions(arena, added.permissions));
    if (added.uses.len > 0)
        try info.writeLine(w, "uses", try oci.describeUses(arena, added.uses));
    if (added.registry.len > 0)
        try info.writeLine(w, "keeps", try std.fmt.allocPrint(arena, "{s} with its data", .{try oci.describeRegistry(arena, added.registry)}));
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
    const start = ctx.now();
    if (try downloadByPlan(ctx, registry, desc)) {
        ctx.timed(start, "download {s}", .{desc.digest});
        return;
    }
    if (desc.size > 1 << 20) note("downloading {s} ({d} bytes)", .{ desc.digest, desc.size });
    const tmp = try ctx.store.tmpPath(arena, "pull");
    const hash = try registry.downloadBlob(desc, tmp);
    _ = try ctx.store.putBlobFile(arena, tmp, hash, desc.mediaType);
    ctx.timed(start, "download {s}", .{desc.digest});
}

/// Fetching less than this share of a blob's bytes (in tenths) isn't worth
/// building it from pieces.
pub const min_reuse_tenths = 1;

/// The store's indexed layers but one, each opened through its index from
/// the store's own blob: what a plan (`format.plan.make`) builds a new
/// layer's blob from, a plan's `source` being the index into these.
pub const Olds = struct {
    descs: []const oci.Descriptor,
    indexes: []*format.Index,
    blobs: []*RemoteBlob,

    pub fn deinit(o: Olds) void {
        for (o.indexes) |r| r.deinit();
        for (o.blobs) |b| b.close();
    }
};

/// The store's indexed layers but `except`, opened: null if it has none
/// whose index opens. RemoteBlob reads a blob the store has from its file,
/// so this sends the registry nothing.
pub fn openOlds(ctx: *Context, registry: *Registry, except: []const u8) !?Olds {
    const arena = ctx.arena;
    const pool = try indexedLayers(ctx, except);
    if (pool.len == 0) return null;
    var descs: std.ArrayList(oci.Descriptor) = .empty;
    var indexes: std.ArrayList(*format.Index) = .empty;
    var blobs: std.ArrayList(*RemoteBlob) = .empty;
    errdefer (Olds{ .descs = descs.items, .indexes = indexes.items, .blobs = blobs.items }).deinit();
    for (pool) |d| {
        const b = try RemoteBlob.open(ctx, registry, d);
        const r = format.openIndex(ctx.gpa, d, b.source()) catch |err| switch (err) {
            error.OutOfMemory => |e| {
                b.close();
                return e;
            },
            else => {
                b.close();
                continue;
            },
        };
        try descs.append(arena, d);
        try indexes.append(arena, r);
        try blobs.append(arena, b);
    }
    if (indexes.items.len == 0) return null;
    return .{ .descs = descs.items, .indexes = indexes.items, .blobs = blobs.items };
}

/// Builds an indexed layer's blob (see `format.Format.indexed`) from the
/// members that the store's blobs of other indexed layers have, as an
/// update's old version of the layer does, and fetches the rest by Range
/// requests. The blob built is checked against its digest, as a download
/// is. False, leaving it to a whole download, if there's nothing to build
/// from, too little, the registry sends blobs only whole, or the blob built
/// isn't the one its digest names.
fn downloadByPlan(ctx: *Context, registry: *Registry, desc: oci.Descriptor) !bool {
    const arena = ctx.arena;
    const gpa = ctx.gpa;
    const io = ctx.io;
    const short = oci.shortDigest(desc.digest);
    if (!(format.Format.ofDescriptor(desc) orelse return false).indexed()) return false;
    const olds = try openOlds(ctx, registry, desc.digest) orelse return false;
    defer olds.deinit();

    const new = try RemoteBlob.open(ctx, registry, desc);
    defer new.close();
    const index = format.openIndex(gpa, desc, new.source()) catch |err| switch (err) {
        error.RangeIgnored => return false,
        else => |e| return e,
    };
    defer index.deinit();
    var p = try format.plan.make(gpa, index, olds.indexes);
    defer p.deinit();
    try p.coalesce(.{ .have_from = new.tail_start });
    const copied = p.copied();
    if (copied * 10 < desc.size * min_reuse_tenths) {
        if (ctx.verbose) Context.note("  {s}: the store's layers have {d} of its {d} bytes; downloading it whole", .{ short, copied, desc.size });
        return false;
    }
    note("downloading {s}: {d} of {d} bytes, the rest from layers in the store", .{ desc.digest, desc.size - copied, desc.size });

    const tmp = try ctx.store.tmpPath(arena, "pull");
    var keep = false;
    defer if (!keep) Io.Dir.cwd().deleteFile(io, tmp) catch {};
    const hash = hash: {
        var file = try Io.Dir.cwd().createFile(io, tmp, .{});
        defer file.close(io);
        var file_buf: [64 * 1024]u8 = undefined;
        var file_writer = file.writer(io, &file_buf);
        var hash_buf: [64 * 1024]u8 = undefined;
        var hashed = file_writer.interface.hashed(std.crypto.hash.sha2.Sha256.init(.{}), &hash_buf);
        var copy_buf: [64 * 1024]u8 = undefined;
        var at: u64 = 0;
        for (p.pieces) |piece| {
            switch (piece) {
                .copy => |c| {
                    const src = olds.blobs[c.source].source();
                    var done: u64 = 0;
                    while (done < c.len) {
                        const n: usize = @intCast(@min(c.len - done, copy_buf.len));
                        try src.readAll(c.offset + done, copy_buf[0..n]);
                        try hashed.writer.writeAll(copy_buf[0..n]);
                        done += n;
                    }
                },
                .fetch => |f| new.fetchTo(f.offset, f.offset + f.len, &hashed.writer) catch |err| switch (err) {
                    error.RangeIgnored => return false,
                    else => |e| return e,
                },
            }
            at += piece.len();
        }
        try hashed.writer.flush();
        try file_writer.interface.flush();
        break :hash Store.FileHash{ .hex = std.fmt.bytesToHex(hashed.hasher.finalResult(), .lower), .size = at };
    };
    if (ctx.verbose) Context.note("  {s}: {d} bytes from the store's layers, {d} fetched in {d} request(s)", .{ short, copied, new.fetched, new.requests });
    if (hash.size != desc.size or !std.mem.eql(u8, &hash.hex, oci.digestHex(desc.digest).?)) {
        note("{s}, built from layers in the store, isn't the blob its digest names; downloading it whole", .{desc.digest});
        return false;
    }
    _ = try ctx.store.putBlobFile(arena, tmp, hash, desc.mediaType);
    keep = true;
    return true;
}

/// The indexed layers of the store's images (apps and builds' images) whose
/// blobs it has, but `except`.
fn indexedLayers(ctx: *Context, except: []const u8) ![]oci.Descriptor {
    const arena = ctx.arena;
    const store = ctx.store;
    var manifests: std.ArrayList([]const u8) = .empty;
    for (store.listRefs(arena) catch &.{}) |ref| try manifests.append(arena, ref.manifest);
    try manifests.appendSlice(arena, store.listBuildImages(arena) catch &.{});
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var found: std.ArrayList(oci.Descriptor) = .empty;
    for (manifests.items) |digest| {
        const manifest = store.readManifest(arena, digest) catch continue;
        for (manifest.layers) |l| {
            const f = format.Format.ofDescriptor(l) orelse continue;
            if (!f.indexed() or std.mem.eql(u8, l.digest, except)) continue;
            if ((try seen.getOrPut(arena, l.digest)).found_existing) continue;
            const hex = oci.digestHex(l.digest) orelse continue;
            if (try Store.exists(ctx.io, try store.blobPath(arena, hex))) try found.append(arena, l);
        }
    }
    return found.items;
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
    for (image.manifest.layers) |l| {
        const hex = oci.digestHex(l.digest).?;
        if (try lazy.isLazy(ctx.store, arena, hex) and !try Store.exists(ctx.io, try ctx.store.blobPath(arena, hex)))
            return fail("{s} is still being downloaded (`zigsaw list` says how far): push it once it's in", .{id});
    }
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
