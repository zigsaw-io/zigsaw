//! The local image store.
//!
//!   <root>\blobs\sha256\<hex>     OCI blobs: manifests, configs, layers
//!   <root>\refs\<id>.json         installed app -> manifest digest
//!   <root>\deploy\<hex>\          unpacked app tree, one per manifest digest
//!   <root>\data\<id>\             per-app writable state, kept across runs
//!   <root>\grants\<id>.txt        host paths whose ACLs name the app's AppContainer
//!   <root>\cache\downloads\<hex>  fetched build sources, by sha256
//!   <root>\tmp\                   staging area
//!
//! <root> is %ZIGSAW_HOME% if set, otherwise %LOCALAPPDATA%\zigsaw.

const Store = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const oci = @import("oci.zig");
const layer = @import("layer.zig");
const Context = @import("Context.zig");
const fail = Context.fail;

io: Io,
root: []const u8,

const subdirs = [_][]const u8{ "blobs\\sha256", "refs", "deploy", "data", "grants", "cache\\downloads", "tmp" };

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

/// Moves the file at `src` into the blob store and returns its descriptor.
pub fn putBlobFile(s: Store, arena: Allocator, src: []const u8, media_type: []const u8) !oci.Descriptor {
    const hash = try sha256File(s.io, src);
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
};

/// Loads an installed app, unpacking it first if its deployment is missing.
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
    return .{
        .ref = ref,
        .manifest = manifest,
        .config = config,
        .deploy_dir = try s.ensureDeployed(arena, ref.manifest, manifest),
    };
}

pub fn deployPath(s: Store, arena: Allocator, manifest_digest: []const u8) ![]u8 {
    const hex = oci.digestHex(manifest_digest) orelse return fail("malformed digest \"{s}\"", .{manifest_digest});
    return s.path(arena, &.{ "deploy", hex });
}

/// Moves an already-assembled app tree into place as the deployment of
/// `manifest_digest`. If that deployment exists, it has the same contents, so
/// `tree` is discarded instead.
pub fn adoptDeployment(s: Store, arena: Allocator, manifest_digest: []const u8, tree: []const u8) ![]u8 {
    const dest = try s.deployPath(arena, manifest_digest);
    if (try exists(s.io, dest)) {
        try Io.Dir.cwd().deleteTree(s.io, tree);
    } else {
        try Io.Dir.rename(.cwd(), tree, .cwd(), dest, s.io);
    }
    return dest;
}

fn ensureDeployed(s: Store, arena: Allocator, manifest_digest: []const u8, manifest: oci.Manifest) ![]u8 {
    const dest = try s.deployPath(arena, manifest_digest);
    if (try exists(s.io, dest)) return dest;

    const work = try s.makeTmpDir(arena, "deploy");
    defer Io.Dir.cwd().deleteTree(s.io, work) catch {};
    const tree = try std.fs.path.join(arena, &.{ work, "app" });
    for (manifest.layers) |desc| {
        if (!std.mem.eql(u8, desc.mediaType, oci.media_type.layer_tar))
            return fail("layer type {s} is not supported", .{desc.mediaType});
        const hex = oci.digestHex(desc.digest) orelse return fail("malformed digest \"{s}\"", .{desc.digest});
        try layer.extract(s.io, try s.blobPath(arena, hex), tree);
    }
    try Io.Dir.rename(.cwd(), tree, .cwd(), dest, s.io);
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
