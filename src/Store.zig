//! The local image store.
//!
//!   <root>\blobs\sha256\<hex>     OCI blobs: manifests, configs, layers
//!   <root>\refs\<id>.json         installed app -> manifest digest
//!   <root>\deploy\<hex>\          an unpacked layer, by layer digest: an app's own
//!                                 files, or a runtime's, shared by the apps using it
//!   <root>\data\<id>\             per-app writable state, kept across runs
//!   <root>\grants\<id>.txt        host paths whose ACLs name the app's AppContainer
//!   <root>\overrides\<id>.json    run options saved for the app (see override.zig)
//!   <root>\bin\                   command shims for exported commands (see exports.zig)
//!   <root>\cache\downloads\<hex>  fetched build sources, by sha256
//!   <root>\cache\images\<hex>     marks a manifest that builds use (see deps.zig)
//!   <root>\cache\builds\<hex>     the manifest a build with these inputs made (see builder.zig)
//!   <root>\cache\tools\<id>\      the caches of a build tool whose config uses ${cache},
//!                                 kept between builds (see builder.zig)
//!   <root>\tmp\                   staging area
//!   <root>\lock                   see "Locks" below
//!
//! <root> is %ZIGSAW_HOME% if set, otherwise %LOCALAPPDATA%\zigsaw.

const Store = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const acl = @import("acl.zig");
const win32 = @import("win32.zig");
const oci = @import("oci.zig");
const layer = @import("layer.zig");
const Context = @import("Context.zig");
const fail = Context.fail;
const note = Context.note;

io: Io,
root: []const u8,
/// Report step timings, as `zigsaw -v` asks for.
verbose: bool = false,

const subdirs = [_][]const u8{ "blobs\\sha256", "refs", "deploy", "data", "grants", "overrides", "bin", "cache\\downloads", "cache\\images", "cache\\builds", "cache\\tools", "tmp" };

pub fn open(io: Io, arena: Allocator, env: *const std.process.Environ.Map) !Store {
    const root = if (env.get("ZIGSAW_HOME")) |home|
        try arena.dupe(u8, home)
    else if (env.get("LOCALAPPDATA")) |local|
        try std.fs.path.join(arena, &.{ local, "zigsaw" })
    else
        return fail("neither ZIGSAW_HOME nor LOCALAPPDATA is set", .{});

    const store: Store = .{ .io = io, .root = root };
    for (subdirs) |sub| try Io.Dir.cwd().createDirPath(io, try store.path(arena, &.{sub}));
    return store;
}

pub fn path(s: Store, arena: Allocator, parts: []const []const u8) ![]u8 {
    var all: std.ArrayList([]const u8) = .empty;
    try all.append(arena, s.root);
    try all.appendSlice(arena, parts);
    return std.fs.path.join(arena, all.items);
}

/// Creates a uniquely named directory under tmp\ and returns its path.
pub fn makeTmpDir(s: Store, arena: Allocator, prefix: []const u8) ![]u8 {
    const dir = try s.tmpPath(arena, prefix);
    try Io.Dir.cwd().createDirPath(s.io, dir);
    return dir;
}

/// Returns a unique, not-yet-existing path under tmp\.
pub fn tmpPath(s: Store, arena: Allocator, prefix: []const u8) ![]u8 {
    var random: [8]u8 = undefined;
    s.io.random(&random);
    const name = try std.fmt.allocPrint(arena, "{s}-{s}", .{ prefix, &std.fmt.bytesToHex(random, .lower) });
    return s.path(arena, &.{ "tmp", name });
}

/// A data directory for one `--ephemeral` run, under tmp\. It is locked as in
/// use, so `prune` leaves it alone until the run ends.
pub const RunDir = struct {
    path: []const u8,
    lock: Lock,

    /// Deletes the directory and its lock.
    pub fn delete(d: RunDir, s: Store, arena: Allocator) void {
        deleteTree(s.io, arena, d.path) catch {};
        d.lock.release(s.io);
        Io.Dir.cwd().deleteFile(s.io, lockPathFor(arena, d.path) catch return) catch {};
    }
};

pub fn makeRunDir(s: Store, arena: Allocator) !RunDir {
    const dir = try s.tmpPath(arena, "run");
    // The lock first: a run directory without a lock is a leftover to `prune`.
    const in_use = try openLock(s.io, try lockPathFor(arena, dir), .exclusive, .wait);
    try Io.Dir.cwd().createDirPath(s.io, dir);
    return .{ .path = dir, .lock = in_use };
}

/// Moves `p` into tmp\ and deletes it there. Moving is atomic, so what was at
/// `p` is either all there or gone. If deleting fails part-way (a file in it
/// is open elsewhere), the rest stays in tmp\ for `prune`.
fn discard(s: Store, arena: Allocator, p: []const u8) !void {
    const trash = try s.tmpPath(arena, "trash");
    try Io.Dir.rename(.cwd(), p, .cwd(), trash, s.io);
    deleteTree(s.io, arena, trash) catch |err|
        note("warning: couldn't delete all of {s} ({t}); `zigsaw prune` will retry", .{ trash, err });
}

// ---------------------------------------------------------------------------
// Locks
//
// Advisory file locks let zigsaw processes share a store safely:
// - <root>\lock is held shared by every command that changes the store or
//   reads blobs, and exclusively by `prune`. Prune deletes what no app refers to, so it must
//   not run while a build or pull has blobs whose ref isn't written yet.
//   `run` holds it only while it prepares the app, not while the app runs.
// - deploy\<hex>.lock is held shared by each run of that deployment, for as
//   long as the app runs. A deployment is only deleted under an exclusive
//   lock, so never while in use.
// - tmp\run-<hex>.lock is held by an --ephemeral run for its data directory.
// - bin.lock is held exclusively while an app's command shims change: as it
//   is installed or removed, and after its runs (see exports.zig).
//
// Locks end when zigsaw exits, however it exits.

pub const Lock = struct {
    file: Io.File,

    pub fn release(l: Lock, io: Io) void {
        l.file.close(io);
    }
};

const Wait = enum { wait, no_wait };

/// Opens (creating if needed) and locks the lock file at `p`. With `.no_wait`,
/// fails with `error.WouldBlock` if another process holds a conflicting lock.
fn openLock(io: Io, p: []const u8, mode: Io.File.Lock, wait: Wait) !Lock {
    const file = try Io.Dir.cwd().createFile(io, p, .{ .truncate = false, .lock = mode, .lock_nonblocking = wait == .no_wait });
    return .{ .file = file };
}

/// Locks `p` without waiting; null if another process holds a conflicting lock.
fn tryLock(io: Io, p: []const u8, mode: Io.File.Lock) !?Lock {
    return openLock(io, p, mode, .no_wait) catch |err| switch (err) {
        error.WouldBlock => null,
        else => |e| e,
    };
}

pub fn lockPathFor(arena: Allocator, p: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}.lock", .{p});
}

/// Takes the store lock, saying so if it has to wait for another zigsaw.
pub fn lock(s: Store, arena: Allocator, mode: Io.File.Lock) !Lock {
    const p = try s.path(arena, &.{"lock"});
    if (try tryLock(s.io, p, mode)) |l| return l;
    note("waiting for another zigsaw command to finish...", .{});
    return openLock(s.io, p, mode, .wait);
}

/// Takes bin.lock, waiting for whoever has it. A process holding it can't
/// take it again.
pub fn lockShims(s: Store, arena: Allocator) !Lock {
    return openLock(s.io, try s.path(arena, &.{"bin.lock"}), .exclusive, .wait);
}

/// Whether the lock file at `p`, if there is one, is held by a running zigsaw.
pub fn isLocked(io: Io, p: []const u8) !bool {
    if (!try exists(io, p)) return false;
    const l = try tryLock(io, p, .exclusive) orelse return true;
    l.release(io);
    return false;
}

// ---------------------------------------------------------------------------
// Blobs

pub fn blobPath(s: Store, arena: Allocator, hex: []const u8) ![]u8 {
    return s.path(arena, &.{ "blobs", "sha256", hex });
}

/// Stores `bytes` as a blob and returns its descriptor.
pub fn putBlob(s: Store, arena: Allocator, bytes: []const u8, media_type: []const u8) !oci.Descriptor {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const dest = try s.blobPath(arena, &hex);
    if (!try exists(s.io, dest)) {
        const tmp = try s.tmpPath(arena, "blob");
        try Io.Dir.cwd().writeFile(s.io, .{ .sub_path = tmp, .data = bytes });
        try Io.Dir.rename(.cwd(), tmp, .cwd(), dest, s.io);
    }
    return .{
        .mediaType = media_type,
        .digest = try std.fmt.allocPrint(arena, "sha256:{s}", .{&hex}),
        .size = bytes.len,
    };
}

/// Moves the file at `src`, whose contents hash to `hash`, into the blob
/// store and returns its descriptor.
pub fn putBlobFile(s: Store, arena: Allocator, src: []const u8, hash: FileHash, media_type: []const u8) !oci.Descriptor {
    const dest = try s.blobPath(arena, &hash.hex);
    if (try exists(s.io, dest)) {
        try Io.Dir.cwd().deleteFile(s.io, src);
    } else {
        try Io.Dir.rename(.cwd(), src, .cwd(), dest, s.io);
    }
    return .{
        .mediaType = media_type,
        .digest = try std.fmt.allocPrint(arena, "sha256:{s}", .{&hash.hex}),
        .size = hash.size,
    };
}

/// Reads a blob and checks it against its digest.
pub fn readBlob(s: Store, arena: Allocator, digest: []const u8) ![]u8 {
    const hex = oci.digestHex(digest) orelse return fail("malformed digest \"{s}\"", .{digest});
    const bytes = Io.Dir.cwd().readFileAlloc(s.io, try s.blobPath(arena, hex), arena, .limited(16 << 20)) catch |err| switch (err) {
        error.FileNotFound => return fail("blob {s} is missing from the store", .{digest}),
        else => |e| return e,
    };
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(actual, .lower), hex))
        return fail("blob {s} is corrupt", .{digest});
    return bytes;
}

// ---------------------------------------------------------------------------
// Refs: which manifest an installed app id points at

pub const Ref = struct {
    id: []const u8,
    version: []const u8,
    manifest: []const u8,
    /// Where the installed image came from: a recipe path or a registry reference.
    source: ?[]const u8 = null,
};

fn refPath(s: Store, arena: Allocator, id: []const u8) ![]u8 {
    return s.path(arena, &.{ "refs", try std.fmt.allocPrint(arena, "{s}.json", .{id}) });
}

pub fn readRef(s: Store, arena: Allocator, id: []const u8) !?Ref {
    if (!oci.isValidId(id)) return null;
    const bytes = Io.Dir.cwd().readFileAlloc(s.io, try s.refPath(arena, id), arena, .limited(64 << 10)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    return try std.json.parseFromSliceLeaky(Ref, arena, bytes, .{});
}

pub fn writeRef(s: Store, arena: Allocator, ref: Ref) !void {
    const tmp = try s.tmpPath(arena, "ref");
    try Io.Dir.cwd().writeFile(s.io, .{ .sub_path = tmp, .data = try oci.toJson(arena, ref) });
    try Io.Dir.rename(.cwd(), tmp, .cwd(), try s.refPath(arena, ref.id), s.io);
}

pub fn deleteRef(s: Store, arena: Allocator, id: []const u8) !void {
    try Io.Dir.cwd().deleteFile(s.io, try s.refPath(arena, id));
}

/// All installed apps, sorted by id.
pub fn listRefs(s: Store, arena: Allocator) ![]Ref {
    var dir = try Io.Dir.cwd().openDir(s.io, try s.path(arena, &.{"refs"}), .{ .iterate = true });
    defer dir.close(s.io);
    var refs: std.ArrayList(Ref) = .empty;
    var it = dir.iterate();
    while (try it.next(s.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const id = entry.name[0 .. entry.name.len - ".json".len];
        if (try s.readRef(arena, id)) |ref| try refs.append(arena, ref);
    }
    std.mem.sort(Ref, refs.items, {}, struct {
        fn lessThan(_: void, a: Ref, b: Ref) bool {
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.lessThan);
    return refs.items;
}

// ---------------------------------------------------------------------------
// Images and deployments

/// An image's manifest and config, read from the store and checked.
pub const Loaded = struct {
    manifest: oci.Manifest,
    config: oci.AppConfig,
};

/// Reads the image with this manifest digest. `what` names it in messages.
pub fn readImage(s: Store, arena: Allocator, what: []const u8, manifest_digest: []const u8) !Loaded {
    const manifest = try s.readManifest(arena, manifest_digest);
    const config = try oci.parseConfig(arena, what, manifest.config.mediaType, try s.readBlob(arena, manifest.config.digest));
    try oci.validateLayers(what, manifest, config);
    return .{ .manifest = manifest, .config = config };
}

/// The image with this manifest digest if the store has all of it: its
/// manifest, config and layers. Null if any is missing.
pub fn readCompleteImage(s: Store, arena: Allocator, manifest_digest: []const u8) !?Loaded {
    const hex = oci.digestHex(manifest_digest) orelse return null;
    if (!try exists(s.io, try s.blobPath(arena, hex))) return null;
    const manifest = try s.readManifest(arena, manifest_digest);
    for ([_][]const oci.Descriptor{ &.{manifest.config}, manifest.layers }) |descs| for (descs) |d| {
        const h = oci.digestHex(d.digest) orelse return null;
        if (!try exists(s.io, try s.blobPath(arena, h))) return null;
    };
    return try s.readImage(arena, manifest_digest, manifest_digest);
}

pub fn readManifest(s: Store, arena: Allocator, manifest_digest: []const u8) !oci.Manifest {
    return std.json.parseFromSliceLeaky(oci.Manifest, arena, try s.readBlob(arena, manifest_digest), .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => |e| e,
        else => fail("manifest {s} in the store can't be read", .{manifest_digest}),
    };
}

pub const Image = struct {
    ref: Ref,
    manifest: oci.Manifest,
    config: oci.AppConfig,
    /// Absolute path of the app's own files: its layer's shared, read-only
    /// deployment.
    deploy_dir: []const u8,
    /// The deployments of its runtimes, in the order of `config.runtimes`.
    runtime_dirs: []const []const u8,
};

/// Loads an installed app to run it: locks the deployments of its layers as
/// in use, and unpacks any that are missing.
pub fn loadImage(s: Store, arena: Allocator, id: []const u8) !Image {
    const ref = try s.readRef(arena, id) orelse
        return fail("{s} is not installed (see `zigsaw list`)", .{id});
    const image = try s.readImage(arena, id, ref.manifest);
    const dirs = try s.useLayers(arena, image.manifest.layers);
    return .{
        .ref = ref,
        .manifest = image.manifest,
        .config = image.config,
        .deploy_dir = dirs[dirs.len - 1],
        .runtime_dirs = dirs[0 .. dirs.len - 1],
    };
}

/// Locks each layer's deployment as in use until zigsaw exits, unpacking it
/// first if it's missing, and returns their paths.
pub fn useLayers(s: Store, arena: Allocator, layers: []const oci.Descriptor) ![]const []const u8 {
    const dirs = try arena.alloc([]const u8, layers.len);
    for (layers, dirs) |l, *dir| {
        // Lock before deploying: if the deployment is being deleted, this
        // waits, and `deploy` then unpacks it again.
        _ = try openLock(s.io, try lockPathFor(arena, try s.deployPath(arena, l.digest)), .shared, .wait);
        dir.* = try s.deploy(arena, l);
    }
    return dirs;
}

pub fn deployPath(s: Store, arena: Allocator, layer_digest: []const u8) ![]u8 {
    const hex = oci.digestHex(layer_digest) orelse return fail("malformed digest \"{s}\"", .{layer_digest});
    return s.path(arena, &.{ "deploy", hex });
}

pub const Deletion = enum {
    deleted,
    /// A run is using it, or a file in it is open.
    in_use,
};

/// Deletes a deployment, unless it is in use. A deployment that doesn't exist
/// counts as deleted.
pub fn deleteDeployment(s: Store, arena: Allocator, layer_digest: []const u8) !Deletion {
    const dest = try s.deployPath(arena, layer_digest);
    if (!try exists(s.io, dest)) return .deleted;
    // The lock file stays: a run may be waiting on it, and `prune` removes it
    // once no deployment goes with it.
    const exclusive = try tryLock(s.io, try lockPathFor(arena, dest), .exclusive) orelse return .in_use;
    defer exclusive.release(s.io);
    try acl.unprotect(arena, dest);
    s.discard(arena, dest) catch |err| switch (err) {
        // Windows refuses to move a directory while a file in it is open.
        error.AccessDenied => {
            try acl.protect(arena, dest);
            return .in_use;
        },
        else => |e| return e,
    };
    return .deleted;
}

/// Whether a run is using a deployment.
pub fn deploymentInUse(s: Store, arena: Allocator, layer_digest: []const u8) !bool {
    return isLocked(s.io, try lockPathFor(arena, try s.deployPath(arena, layer_digest)));
}

/// Deletes the deployments of a manifest's layers that nothing uses any more
/// (see `usedLayers`). Returns whether any had to be kept because a run is
/// using it.
pub fn deleteUnusedDeployments(s: Store, arena: Allocator, manifest_digest: []const u8) !bool {
    const used = try s.usedLayers(arena, .{ .build_images = true });
    var kept = false;
    for ((try s.readManifest(arena, manifest_digest)).layers) |l| {
        const hex = oci.digestHex(l.digest) orelse continue;
        if (used.contains(hex)) continue;
        if (try s.deleteDeployment(arena, l.digest) == .in_use) kept = true;
    }
    return kept;
}

pub const UsedOptions = struct {
    /// Count the images that builds use (see `markBuildImage`) as used.
    build_images: bool,
};

/// The hex digests of the layers that installed apps use, their runtimes'
/// included, and optionally those of the images builds use.
pub fn usedLayers(s: Store, arena: Allocator, opts: UsedOptions) !std.StringHashMapUnmanaged(void) {
    var used: std.StringHashMapUnmanaged(void) = .empty;
    var manifests: std.ArrayList([]const u8) = .empty;
    for (try s.listRefs(arena)) |ref| try manifests.append(arena, ref.manifest);
    if (opts.build_images) try manifests.appendSlice(arena, try s.listBuildImages(arena));
    for (manifests.items) |digest| {
        for ((try s.readManifest(arena, digest)).layers) |l| {
            try used.put(arena, oci.digestHex(l.digest) orelse continue, {});
        }
    }
    return used;
}

/// Unpacks a layer as its deployment, unless that already exists. Deployments
/// are shared by every run, and by every app with the layer, so they are
/// protected from changes.
pub fn deploy(s: Store, arena: Allocator, desc: oci.Descriptor) ![]u8 {
    const compression = oci.layerCompression(desc.mediaType) orelse
        return fail("layer type {s} is not supported", .{desc.mediaType});
    const dest = try s.deployPath(arena, desc.digest);
    if (try exists(s.io, dest)) {
        // Cheap when already protected; covers deployments made before protection existed.
        try acl.protect(arena, dest);
        return dest;
    }

    const work = try s.makeTmpDir(arena, "deploy");
    defer Io.Dir.cwd().deleteTree(s.io, work) catch {};
    const tree = try std.fs.path.join(arena, &.{ work, "app" });
    const blob = try s.blobPath(arena, oci.digestHex(desc.digest).?);
    var start = Io.Timestamp.now(s.io, .awake);
    // Extracting reads files' bytes from their places in a plain tar, in
    // parallel, so a gzip layer is decompressed first, next to the tree.
    const tar = switch (compression) {
        .none => blob,
        .gzip => tar: {
            const p = try std.fs.path.join(arena, &.{ work, "layer.tar" });
            try layer.inflate(s.io, blob, p);
            Context.reportTime(s.io, s.verbose, start, "  inflate {s}", .{oci.shortDigest(desc.digest)});
            start = Io.Timestamp.now(s.io, .awake);
            break :tar p;
        },
    };
    try layer.extract(s.io, arena, tar, tree);
    Context.reportTime(s.io, s.verbose, start, "  unpack {s}", .{oci.shortDigest(desc.digest)});
    try Io.Dir.rename(.cwd(), tree, .cwd(), dest, s.io);
    start = Io.Timestamp.now(s.io, .awake);
    try acl.protect(arena, dest);
    Context.reportTime(s.io, s.verbose, start, "  protect", .{});
    return dest;
}

// ---------------------------------------------------------------------------
// The build cache: which image a build with given inputs made, by a hash of
// the inputs (see builder.zig).

fn buildCachePath(s: Store, arena: Allocator, inputs_hex: []const u8) ![]u8 {
    return s.path(arena, &.{ "cache", "builds", inputs_hex });
}

/// The manifest digest of an earlier build with these inputs, if any.
pub fn readBuildCache(s: Store, arena: Allocator, inputs_hex: []const u8) !?[]const u8 {
    const bytes = Io.Dir.cwd().readFileAlloc(s.io, try s.buildCachePath(arena, inputs_hex), arena, .limited(1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    const digest = std.mem.trim(u8, bytes, " \r\n");
    return if (oci.digestHex(digest) != null) digest else null;
}

pub fn writeBuildCache(s: Store, arena: Allocator, inputs_hex: []const u8, manifest_digest: []const u8) !void {
    const tmp = try s.tmpPath(arena, "build-cache");
    try Io.Dir.cwd().writeFile(s.io, .{ .sub_path = tmp, .data = manifest_digest });
    try Io.Dir.rename(.cwd(), tmp, .cwd(), try s.buildCachePath(arena, inputs_hex), s.io);
}

// ---------------------------------------------------------------------------
// Images that builds use: runtimes and SDKs that aren't installed as apps.
// Marking them keeps them, like cached downloads, until `prune --downloads`.

pub fn markBuildImage(s: Store, arena: Allocator, manifest_digest: []const u8) !void {
    const hex = oci.digestHex(manifest_digest) orelse return fail("malformed digest \"{s}\"", .{manifest_digest});
    try Io.Dir.cwd().writeFile(s.io, .{ .sub_path = try s.path(arena, &.{ "cache", "images", hex }), .data = "" });
}

/// The manifest digests of the marked images that are still in the store.
pub fn listBuildImages(s: Store, arena: Allocator) ![]const []const u8 {
    var dir = try Io.Dir.cwd().openDir(s.io, try s.path(arena, &.{ "cache", "images" }), .{ .iterate = true });
    defer dir.close(s.io);
    var digests: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(s.io)) |entry| {
        if (entry.kind != .file or !oci.isSha256Hex(entry.name)) continue;
        if (!try exists(s.io, try s.blobPath(arena, entry.name))) continue;
        try digests.append(arena, try std.fmt.allocPrint(arena, "sha256:{s}", .{entry.name}));
    }
    return digests.items;
}

// ---------------------------------------------------------------------------
// AppContainer grant tracking, so `zigsaw rm` can undo ACL changes on host paths

fn grantsPath(s: Store, arena: Allocator, id: []const u8) ![]u8 {
    return s.path(arena, &.{ "grants", try std.fmt.allocPrint(arena, "{s}.txt", .{id}) });
}

pub fn readGrants(s: Store, arena: Allocator, id: []const u8) ![]const []const u8 {
    const bytes = Io.Dir.cwd().readFileAlloc(s.io, try s.grantsPath(arena, id), arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => |e| return e,
    };
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, bytes, "\r\n");
    while (it.next()) |line| try list.append(arena, line);
    return list.items;
}

pub fn recordGrant(s: Store, arena: Allocator, id: []const u8, host_path: []const u8) !void {
    const existing = try s.readGrants(arena, id);
    for (existing) |p| if (std.os.windows.eqlIgnoreCaseWtf8(p, host_path)) return;
    var out: std.ArrayList(u8) = .empty;
    for (existing) |p| try out.print(arena, "{s}\n", .{p});
    try out.print(arena, "{s}\n", .{host_path});
    try Io.Dir.cwd().writeFile(s.io, .{ .sub_path = try s.grantsPath(arena, id), .data = out.items });
}

pub fn deleteGrants(s: Store, arena: Allocator, id: []const u8) !void {
    Io.Dir.cwd().deleteFile(s.io, try s.grantsPath(arena, id)) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
}

// ---------------------------------------------------------------------------
// Helpers

/// Deletes a directory tree that apps or build tools have written to. Unlike
/// Zig 0.16's deleteTree, it copes with the directory links Windows
/// components leave in a profile, such as WinINet's
/// INetCache\Content.IE5: it removes those links themselves (never what
/// they point to), then the rest.
pub fn deleteTree(io: Io, arena: Allocator, p: []const u8) !void {
    Io.Dir.cwd().deleteTree(io, p) catch |err| switch (err) {
        error.AccessDenied => {
            try removeDirLinks(io, arena, p);
            try Io.Dir.cwd().deleteTree(io, p);
        },
        else => |e| return e,
    };
}

fn removeDirLinks(io: Io, arena: Allocator, p: []const u8) !void {
    var dir = try Io.Dir.cwd().openDir(io, p, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var links: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .sym_link) try links.append(arena, try std.fs.path.join(arena, &.{ p, entry.path }));
    }
    // A link to a file isn't a directory, and deleteTree deletes those itself.
    for (links.items) |link| _ = win32.RemoveDirectoryW(try win32.wide(arena, link));
}

pub fn exists(io: Io, p: []const u8) !bool {
    Io.Dir.cwd().access(io, p, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

test "locks: shared locks coexist, an exclusive one excludes" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const p = try std.fs.path.join(arena, &.{ try tmp.dir.realPathFileAlloc(io, ".", arena), "x.lock" });

    try std.testing.expect(!try isLocked(io, p));
    const run_a = try openLock(io, p, .shared, .no_wait);
    const run_b = try openLock(io, p, .shared, .no_wait);
    try std.testing.expect(try isLocked(io, p));
    try std.testing.expectEqual(null, try tryLock(io, p, .exclusive));
    run_a.release(io);
    try std.testing.expect(try isLocked(io, p));
    run_b.release(io);
    const exclusive = (try tryLock(io, p, .exclusive)).?;
    try std.testing.expectEqual(null, try tryLock(io, p, .shared));
    exclusive.release(io);
    try std.testing.expect(!try isLocked(io, p));
}

pub const FileHash = struct {
    hex: [64]u8,
    size: u64,
};

pub fn sha256File(io: Io, file_path: []const u8) !FileHash {
    var file = try Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buf);
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    var size: u64 = 0;
    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        hasher.update(chunk);
        size += chunk.len;
        reader.interface.toss(chunk.len);
    }
    return .{ .hex = std.fmt.bytesToHex(hasher.finalResult(), .lower), .size = size };
}
