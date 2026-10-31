//! Layer formats: how a layer's tar is kept in its blob. The rest of zigsaw
//! writes and deploys layers through here, and never names a format: adding
//! one adds a case here (see docs/layer-formats.md).
//!
//! - tar: plain, as images built before iteration 7 have, and as vendor
//!   steps keep what they made.
//! - gzip: the tar, gzip-compressed, as builds make it unless a recipe asks
//!   for another format.
//! - estargz: gzip whose members start at each file's bytes, with a table of
//!   contents (TOC) at the end (see stargazer), so that files can be read
//!   where they are. Read as plain gzip, it's the same tar with the TOC and a
//!   landmark file as two more entries, which no path here deploys.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const estargz = @import("stargazer").estargz;
const stargazer_source = @import("stargazer").Source;
const Context = @import("Context.zig");
const layer = @import("layer.zig");
const oci = @import("oci.zig");
const Store = @import("Store.zig");
const fail = Context.fail;

pub const Format = enum {
    tar,
    gzip,
    estargz,

    /// The format of the layer `desc` describes; null if zigsaw can't
    /// unpack it. An eStargz layer has gzip's media type, and is told apart
    /// by its TOC's digest on the descriptor.
    pub fn ofDescriptor(desc: oci.Descriptor) ?Format {
        if (std.mem.eql(u8, desc.mediaType, oci.media_type.layer_tar)) return .tar;
        if (!std.mem.eql(u8, desc.mediaType, oci.media_type.layer_tar_gzip)) return null;
        const annotations = desc.annotations orelse return .gzip;
        return if (annotations.map.contains(estargz.toc_digest_annotation)) .estargz else .gzip;
    }

    /// As `zigsaw info` shows it.
    pub fn label(f: Format) []const u8 {
        return switch (f) {
            .tar => "plain tar",
            .gzip => "gzip",
            .estargz => "eStargz",
        };
    }

    pub fn mediaType(f: Format) []const u8 {
        return switch (f) {
            .tar => oci.media_type.layer_tar,
            .gzip, .estargz => oci.media_type.layer_tar_gzip,
        };
    }
};

/// A layer written to a temporary file in the store, to move in as a blob.
pub const Blob = struct {
    path: []const u8,
    hash: Store.FileHash,
    media_type: []const u8,
    /// What the layer's descriptor carries: eStargz's TOC digest and size.
    annotations: ?std.json.ArrayHashMap([]const u8) = null,

    pub fn descriptor(b: Blob, desc: oci.Descriptor) oci.Descriptor {
        var d = desc;
        d.annotations = b.annotations;
        return d;
    }
};

/// Writes a layer in format `f` to a temporary file, hashing it on the way.
/// `source.writeTar(io, arena, out)` writes the layer's plain tar.
pub fn write(ctx: *Context, f: Format, source: anytype) !Blob {
    const io = ctx.io;
    const arena = ctx.arena;
    const path = try ctx.store.tmpPath(arena, "layer");
    errdefer Io.Dir.cwd().deleteFile(io, path) catch {};
    // Read access too, so the handle can query the file's final length.
    var file = try Io.Dir.cwd().createFile(io, path, .{ .read = true });
    defer file.close(io);

    var file_buf: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &file_buf);
    var hash_buf: [64 * 1024]u8 = undefined;
    var hashed = file_writer.interface.hashed(std.crypto.hash.sha2.Sha256.init(.{}), &hash_buf);
    var annotations: ?std.json.ArrayHashMap([]const u8) = null;
    switch (f) {
        .tar => try source.writeTar(io, arena, &hashed.writer),
        .gzip => {
            const gz = try layer.gzip(arena, &hashed.writer);
            try source.writeTar(io, arena, &gz.writer);
            try gz.finish();
        },
        .estargz => {
            // stargazer converts a tar stream, so the tar goes to a file
            // first: the layer is then exactly what `stargazer convert`
            // makes of it.
            const tar_path = try ctx.store.tmpPath(arena, "layer-tar");
            defer Io.Dir.cwd().deleteFile(io, tar_path) catch {};
            {
                var tar_file = try Io.Dir.cwd().createFile(io, tar_path, .{});
                defer tar_file.close(io);
                var buf: [64 * 1024]u8 = undefined;
                var w = tar_file.writer(io, &buf);
                try source.writeTar(io, arena, &w.interface);
                try w.interface.flush();
            }
            var tar_file = try Io.Dir.cwd().openFile(io, tar_path, .{});
            defer tar_file.close(io);
            var buf: [64 * 1024]u8 = undefined;
            var r = tar_file.reader(io, &buf);
            annotations = try toEstargz(ctx.gpa, arena, &r.interface, &hashed.writer);
        },
    }
    try hashed.writer.flush();
    try file_writer.interface.flush();

    return .{
        .path = path,
        .hash = .{
            .hex = std.fmt.bytesToHex(hashed.hasher.finalResult(), .lower),
            .size = try file.length(io),
        },
        .media_type = f.mediaType(),
        .annotations = annotations,
    };
}

/// Writes the plain tar `in` to `out` as eStargz, with stargazer's
/// defaults (members every 4 MiB, deflate level 6, as gzip layers have),
/// and returns the annotations the layer's descriptor gets.
fn toEstargz(gpa: Allocator, arena: Allocator, in: *Io.Reader, out: *Io.Writer) !std.json.ArrayHashMap([]const u8) {
    const result = estargz.convert(gpa, in, out, .{}) catch |err| switch (err) {
        error.EstargzReservedName => return fail("an eStargz layer can't have {s}, {s} or {s} at its top: eStargz keeps those names for itself", .{
            estargz.toc_name, estargz.no_prefetch_landmark, estargz.prefetch_landmark,
        }),
        else => |e| return e,
    };
    var annotations: std.json.ArrayHashMap([]const u8) = .{};
    try annotations.map.put(arena, estargz.toc_digest_annotation, try std.fmt.allocPrint(arena, "sha256:{s}", .{&std.fmt.bytesToHex(result.toc_digest, .lower)}));
    try annotations.map.put(arena, estargz.uncompressed_size_annotation, try std.fmt.allocPrint(arena, "{d}", .{result.uncompressed_size}));
    return annotations;
}

/// Unpacks the layer `desc`, whose blob is the file at `blob`, into
/// `dest`, which mustn't exist yet. `work` is a directory to use on the way.
/// `gpa` must be thread-safe.
pub fn deploy(io: Io, gpa: Allocator, arena: Allocator, verbose: bool, desc: oci.Descriptor, blob: []const u8, work: []const u8, dest: []const u8) !void {
    const f = Format.ofDescriptor(desc) orelse
        return fail("layer type {s} is not supported", .{desc.mediaType});
    var start = Io.Timestamp.now(io, .awake);
    switch (f) {
        .tar => try layer.extract(io, arena, blob, dest),
        .gzip => {
            // Extracting reads files' bytes from their places in a plain
            // tar, in parallel, so the layer is decompressed first.
            const tar = try std.fs.path.join(arena, &.{ work, "layer.tar" });
            try layer.inflate(io, blob, tar);
            Context.reportTime(io, verbose, start, "  inflate {s}", .{oci.shortDigest(desc.digest)});
            start = Io.Timestamp.now(io, .awake);
            try layer.extract(io, arena, tar, dest);
        },
        // Each file's members are decompressed from the blob straight into
        // the deployment, so nothing is inflated first.
        .estargz => try deployEstargz(io, gpa, desc, blob, dest),
    }
    Context.reportTime(io, verbose, start, "  unpack {s}", .{oci.shortDigest(desc.digest)});
}

fn deployEstargz(io: Io, gpa: Allocator, desc: oci.Descriptor, blob: []const u8, dest: []const u8) !void {
    const short = oci.shortDigest(desc.digest);
    var file = try Io.Dir.cwd().openFile(io, blob, .{});
    defer file.close(io);
    const src: stargazer_source.File = .{ .io = io, .file = file };
    const r = estargz.Reader.open(gpa, src.source(try file.length(io)), .{}) catch |err|
        return fail("layer {s} can't be read as eStargz: {t}", .{ short, err });
    defer r.deinit();
    const want = desc.annotations.?.map.get(estargz.toc_digest_annotation).?;
    const got = std.fmt.bytesToHex(r.toc_digest, .lower);
    if (!std.mem.startsWith(u8, want, "sha256:") or !std.mem.eql(u8, want["sha256:".len..], &got))
        return fail("layer {s}: its TOC isn't the one its descriptor names ({s})", .{ short, want });
    // The names a tar layer may have, checked by zigsaw's rules, as there.
    for (r.files) |f| {
        if (f.name.len == 0 or estargz.isReserved(f.name)) continue;
        if (!oci.isSafeRelPath(std.mem.trimEnd(u8, f.entry.name, "/")))
            return fail("layer {s} has a file outside it: {s}", .{ short, f.entry.name });
        if (f.entry.type != .dir and f.entry.type != .reg)
            return fail("layer {s} has {s}, which isn't a file or directory", .{ short, f.entry.name });
    }
    r.extract(io, gpa, dest, .{ .jobs = layer.max_extract_workers }) catch |err|
        return fail("unpacking layer {s}: {t}", .{ short, err });
}

// ---------------------------------------------------------------------------
// Tests

const repeat = @import("testing.zig").repeat;

/// A small tree, as a source for `write`, with a file over stargazer's
/// 4 MiB chunk size so that eStargz splits one.
const TestTree = struct {
    /// Extra entries, '/'-separated, each a file holding its name.
    extra: []const []const u8 = &.{},

    pub fn writeTar(t: TestTree, io: Io, arena: Allocator, out: *Io.Writer) !void {
        _ = io;
        var w: layer.Writer = .init(out);
        try w.addDir("bin");
        const tool = "MZ " ++ repeat("fake ", 1000);
        var tool_reader: Io.Reader = .fixed(tool);
        try w.addFile("bin/tool.exe", tool.len, &tool_reader);
        var empty: Io.Reader = .fixed("");
        try w.addFile("empty.txt", 0, &empty);
        try w.addDir("share");
        const big = try arena.alloc(u8, 5 << 20);
        for (big, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 13);
        var big_reader: Io.Reader = .fixed(big);
        try w.addFile("share/big.dat", big.len, &big_reader);
        for (t.extra) |name| {
            var r: Io.Reader = .fixed(name);
            try w.addFile(name, name.len, &r);
        }
        try w.finish();
    }
};

/// `tree` as a layer of format `f`, its bytes and descriptor.
fn testBlob(arena: Allocator, f: Format, tree: TestTree) !struct { []const u8, oci.Descriptor } {
    const io = std.testing.io;
    var tar: Io.Writer.Allocating = .init(arena);
    try tree.writeTar(io, arena, &tar.writer);
    var out: Io.Writer.Allocating = try .initCapacity(arena, 64 * 1024);
    var annotations: ?std.json.ArrayHashMap([]const u8) = null;
    switch (f) {
        .tar => try out.writer.writeAll(tar.written()),
        .gzip => {
            const gz = try layer.gzip(arena, &out.writer);
            try gz.writer.writeAll(tar.written());
            try gz.finish();
        },
        .estargz => {
            var in: Io.Reader = .fixed(tar.written());
            annotations = try toEstargz(std.testing.allocator, arena, &in, &out.writer);
            try out.writer.flush();
        },
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(out.written(), &digest, .{});
    return .{ out.written(), .{
        .mediaType = f.mediaType(),
        .digest = try std.fmt.allocPrint(arena, "sha256:{s}", .{&std.fmt.bytesToHex(digest, .lower)}),
        .size = out.written().len,
        .annotations = annotations,
    } };
}

/// Deploys `bytes` as the layer `desc` in `tmp`, under `name`, and returns
/// the deployment's path.
fn testDeploy(arena: Allocator, tmp: std.testing.TmpDir, name: []const u8, bytes: []const u8, desc: oci.Descriptor) ![]const u8 {
    const io = std.testing.io;
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const work = try std.fs.path.join(arena, &.{ base, try std.fmt.allocPrint(arena, "{s}.work", .{name}) });
    try Io.Dir.cwd().createDirPath(io, work);
    const blob = try std.fs.path.join(arena, &.{ work, "blob" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = blob, .data = bytes });
    const dest = try std.fs.path.join(arena, &.{ base, name });
    try deploy(io, std.testing.allocator, arena, false, desc, blob, work, dest);
    return dest;
}

/// Every path below `root`, sorted, each with its contents ("/" for a
/// directory).
fn listTree(arena: Allocator, root: []const u8) ![]const [2][]const u8 {
    const io = std.testing.io;
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    var out: std.ArrayList([2][]const u8) = .empty;
    while (try walker.next(io)) |e| {
        const contents = if (e.kind == .directory) "/" else try dir.readFileAlloc(io, e.path, arena, .unlimited);
        try out.append(arena, .{ try arena.dupe(u8, e.path), contents });
    }
    std.mem.sort([2][]const u8, out.items, {}, struct {
        fn lessThan(_: void, a: [2][]const u8, b: [2][]const u8) bool {
            return std.mem.lessThan(u8, a[0], b[0]);
        }
    }.lessThan);
    return out.items;
}

test "formats by descriptor: eStargz is gzip with a TOC digest" {
    const d = "sha256:" ++ repeat("a", 64);
    try std.testing.expectEqual(.tar, Format.ofDescriptor(.{ .mediaType = oci.media_type.layer_tar, .digest = d, .size = 1 }).?);
    try std.testing.expectEqual(.gzip, Format.ofDescriptor(.{ .mediaType = oci.media_type.layer_tar_gzip, .digest = d, .size = 1 }).?);
    var other: std.json.ArrayHashMap([]const u8) = .{};
    defer other.map.deinit(std.testing.allocator);
    try other.map.put(std.testing.allocator, estargz.uncompressed_size_annotation, "1");
    try std.testing.expectEqual(.gzip, Format.ofDescriptor(.{ .mediaType = oci.media_type.layer_tar_gzip, .digest = d, .size = 1, .annotations = other }).?);
    try other.map.put(std.testing.allocator, estargz.toc_digest_annotation, d);
    try std.testing.expectEqual(.estargz, Format.ofDescriptor(.{ .mediaType = oci.media_type.layer_tar_gzip, .digest = d, .size = 1, .annotations = other }).?);
    // zstd:chunked has a media type of its own, refused by name.
    try std.testing.expectEqual(null, Format.ofDescriptor(.{ .mediaType = "application/vnd.oci.image.layer.v1.tar+zstd", .digest = d, .size = 1, .annotations = other }));
}

test "eStargz layers: the same bytes every time" {
    // As for gzip (see layer.zig): every eStargz image's digest is what
    // stargazer, and this Zig's deflate, make of its layer.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes, const desc = try testBlob(arena, .estargz, .{});
    try std.testing.expectEqualStrings("sha256:3d312495c781a505f5dbc711d914db80935968353e4db2b694b24abcae6694fc", desc.digest);
    try std.testing.expectEqualSlices(u8, bytes, (try testBlob(arena, .estargz, .{}))[0]);
    try std.testing.expectEqualStrings("sha256:be64a60c2fef47532b6fc53215a937712ccbfa5a04e17b5f45e0ef90acb43d61", desc.annotations.?.map.get(estargz.toc_digest_annotation).?);
    try std.testing.expectEqualStrings("5254656", desc.annotations.?.map.get(estargz.uncompressed_size_annotation).?);
}

test "eStargz layers deploy the same tree as gzip, without the TOC or landmark" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const gz, const gz_desc = try testBlob(arena, .gzip, .{});
    const sg, const sg_desc = try testBlob(arena, .estargz, .{});
    const from_gzip = try listTree(arena, try testDeploy(arena, tmp, "gzip", gz, gz_desc));
    const from_estargz = try listTree(arena, try testDeploy(arena, tmp, "estargz", sg, sg_desc));
    try std.testing.expectEqual(from_gzip.len, from_estargz.len);
    for (from_gzip, from_estargz) |a, b| {
        try std.testing.expectEqualStrings(a[0], b[0]);
        try std.testing.expectEqualSlices(u8, a[1], b[1]);
    }
    try std.testing.expectEqual(5, from_gzip.len);

    // Read as plain gzip, it has the TOC and the landmark too: what a zigsaw
    // that doesn't know eStargz, but reads every member, deploys.
    var plain = sg_desc;
    plain.annotations = null;
    const as_gzip = try listTree(arena, try testDeploy(arena, tmp, "as-gzip", sg, plain));
    try std.testing.expectEqual(from_gzip.len + 2, as_gzip.len);
}

test "eStargz layers: the TOC must be the descriptor's, and names zigsaw's" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sg, var desc = try testBlob(arena, .estargz, .{});
    var wrong: std.json.ArrayHashMap([]const u8) = .{};
    try wrong.map.put(arena, estargz.toc_digest_annotation, "sha256:" ++ repeat("0", 64));
    desc.annotations = wrong;
    try std.testing.expectError(error.Failed, testDeploy(arena, tmp, "wrong-toc", sg, desc));

    // stargazer refuses a backslash itself; a name with ".." it would clean
    // up, where the tar path refuses it.
    for ([_][]const u8{ "a\\b.txt", "share/../../up.txt" }, 0..) |name, i| {
        const bad, const bad_desc = try testBlob(arena, .estargz, .{ .extra = &.{name} });
        try std.testing.expectError(error.Failed, testDeploy(arena, tmp, try std.fmt.allocPrint(arena, "bad{d}", .{i}), bad, bad_desc));
    }

    // The names eStargz keeps for itself can't be in a layer written as one.
    try std.testing.expectError(error.Failed, testBlob(arena, .estargz, .{ .extra = &.{estargz.toc_name} }));
}
