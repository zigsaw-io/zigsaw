//! The local image store.
//!
//!   <root>\blobs\sha256\<hex>     OCI blobs: manifests, configs, layers
//!   <root>\refs\<id>.json         installed app -> manifest digest
//!   <root>\deploy\<hex>\          unpacked app tree, one per manifest digest
//!   <root>\data\<id>\             per-app writable state, kept across runs
//!   <root>\grants\<id>.txt        host paths whose ACLs name the app's AppContainer
//!   <root>\overrides\<id>.json    run options saved for the app (see override.zig)
//!   <root>\bin\                   command shims for exported commands (see exports.zig)
//!   <root>\cache\downloads\<hex>  fetched build sources, by sha256
//!   <root>\tmp\                   staging area
//!   <root>\lock                   see "Locks" below
//!
//! <root> is %ZIGSAW_HOME% if set, otherwise %LOCALAPPDATA%\zigsaw.

const Store = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const acl = @import("acl.zig");
const oci = @import("oci.zig");
const layer = @import("layer.zig");
const Context = @import("Context.zig");
const fail = Context.fail;
const note = Context.note;

io: Io,
root: []const u8,
/// Report step timings, as `zigsaw -v` asks for.
verbose: bool = false,

const subdirs = [_][]const u8{ "blobs\\sha256", "refs", "deploy", "data", "grants", "overrides", "bin", "cache\\downloads", "tmp" };

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
        Io.Dir.cwd().deleteTree(s.io, d.path) catch {};
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
    Io.Dir.cwd().deleteTree(s.io, trash) catch |err|
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

pub const Image = struct {
    ref: Ref,
    manifest: oci.Manifest,
    config: oci.AppConfig,
    /// Absolute path of the unpacked, shared, read-only app tree.
    deploy_dir: []const u8,
    /// Marks the deployment as in use until released, or until zigsaw exits.
    in_use: Lock,
};

/// Loads an installed app to run it: locks its deployment as in use, and
/// unpacks it first if it's missing.
pub fn loadImage(s: Store, arena: Allocator, id: []const u8) !Image {
    const ref = try s.readRef(arena, id) orelse
        return fail("{s} is not installed (see `zigsaw list`)", .{id});
    const manifest = try std.json.parseFromSliceLeaky(oci.Manifest, arena, try s.readBlob(arena, ref.manifest), .{
        .ignore_unknown_fields = true,
    });
    if (!std.mem.eql(u8, manifest.config.mediaType, oci.media_type.config))
        return fail("{s}: config type {s} is not a zigsaw app", .{ id, manifest.config.mediaType });
    const config = try std.json.parseFromSliceLeaky(oci.AppConfig, arena, try s.readBlob(arena, manifest.config.digest), .{
        .ignore_unknown_fields = true,
    });
    // Lock before deploying: if the deployment is being deleted, this waits,
    // and `deploy` then unpacks it again.
    const in_use = try openLock(s.io, try lockPathFor(arena, try s.deployPath(arena, ref.manifest)), .shared, .wait);
    return .{
        .ref = ref,
        .manifest = manifest,
        .config = config,
        .deploy_dir = try s.deploy(arena, ref.manifest, manifest),
        .in_use = in_use,
    };
}

pub fn deployPath(s: Store, arena: Allocator, manifest_digest: []const u8) ![]u8 {
    const hex = oci.digestHex(manifest_digest) orelse return fail("malformed digest \"{s}\"", .{manifest_digest});
    return s.path(arena, &.{ "deploy", hex });
}

pub const Deletion = enum {
    deleted,
    /// A run is using it, or a file in it is open.
    in_use,
};

/// Deletes a deployment, unless it is in use. A deployment that doesn't exist
/// counts as deleted.
pub fn deleteDeployment(s: Store, arena: Allocator, manifest_digest: []const u8) !Deletion {
    const dest = try s.deployPath(arena, manifest_digest);
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
pub fn deploymentInUse(s: Store, arena: Allocator, manifest_digest: []const u8) !bool {
    return isLocked(s.io, try lockPathFor(arena, try s.deployPath(arena, manifest_digest)));
}

/// Deletes the deployment of a manifest no installed app points at any more.
/// Deployments are shared by apps built from identical inputs.
pub fn deleteDeploymentIfUnused(s: Store, arena: Allocator, manifest_digest: []const u8) !?Deletion {
    for (try s.listRefs(arena)) |ref| {
        if (std.mem.eql(u8, ref.manifest, manifest_digest)) return null;
    }
    return try s.deleteDeployment(arena, manifest_digest);
}

/// Unpacks an image's layers as its deployment, unless that already exists.
/// Deployments are shared by every run, so they are protected from changes.
pub fn deploy(s: Store, arena: Allocator, manifest_digest: []const u8, manifest: oci.Manifest) ![]u8 {
    const dest = try s.deployPath(arena, manifest_digest);
    if (try exists(s.io, dest)) {
        // Cheap when already protected; covers deployments made before protection existed.
        try acl.protect(arena, dest);
        return dest;
    }

    const work = try s.makeTmpDir(arena, "deploy");
    defer Io.Dir.cwd().deleteTree(s.io, work) catch {};
    const tree = try std.fs.path.join(arena, &.{ work, "app" });
    var start = Io.Timestamp.now(s.io, .awake);
    for (manifest.layers) |desc| {
        if (!std.mem.eql(u8, desc.mediaType, oci.media_type.layer_tar))
            return fail("layer type {s} is not supported", .{desc.mediaType});
        const hex = oci.digestHex(desc.digest) orelse return fail("malformed digest \"{s}\"", .{desc.digest});
        try layer.extract(s.io, arena, try s.blobPath(arena, hex), tree);
    }
    Context.reportTime(s.io, s.verbose, start, "  unpack layers", .{});
    try Io.Dir.rename(.cwd(), tree, .cwd(), dest, s.io);
    start = Io.Timestamp.now(s.io, .awake);
    try acl.protect(arena, dest);
    Context.reportTime(s.io, s.verbose, start, "  protect", .{});
    return dest;
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
