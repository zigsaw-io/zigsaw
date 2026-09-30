//! `zigsaw build`: assembles an app tree from a recipe's sources, packs it into
//! an image in the local store, and installs it.
//!
//! Sources are never unpacked to disk. The builder indexes the files each
//! source contributes, then streams them from the downloaded files and zip
//! archives straight into the layer. Only deploying the finished layer creates
//! the app's files, once. Unpacking and then reading everything back is slow on
//! Windows, where Defender scans each new file before it can be read.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const install = @import("install.zig");
const Fetcher = @import("fetch.zig");
const layer = @import("layer.zig");
const oci = @import("oci.zig");
const recipe = @import("recipe.zig");
const Store = @import("Store.zig");
const zipfile = @import("zipfile.zig");
const fail = Context.fail;
const note = Context.note;

pub fn build(ctx: *Context, recipe_path: []const u8) !void {
    const io = ctx.io;
    const arena = ctx.arena;

    const bytes = Io.Dir.cwd().readFileAlloc(io, recipe_path, arena, .limited(1 << 20)) catch |err|
        return fail("reading {s}: {t}", .{ recipe_path, err });
    const r = try recipe.parse(arena, recipe_path, bytes);

    var fetcher: Fetcher = .{ .ctx = ctx, .base_dir = std.fs.path.dirname(recipe_path) orelse "." };
    defer fetcher.deinit();
    var archives: std.ArrayList(*Archive) = .empty;
    defer for (archives.items) |a| a.close(io);

    var tree: Tree = .{};
    for (r.sources) |src| {
        var start = ctx.now();
        const file = try fetcher.fetch(src);
        ctx.timed(start, "fetch {s}", .{src.fileName()});
        start = ctx.now();
        addSource(io, arena, &tree, &archives, src, file) catch |err| switch (err) {
            error.PathConflict => return fail("{s}: {s} is a file in one source and a directory in another", .{ recipe_path, tree.conflict }),
            error.OutOfMemory => |e| return e,
            else => return fail("reading {s}: {t}", .{ src.fileName(), err }),
        };
        ctx.timed(start, "index {s}", .{src.fileName()});
    }

    if (!try tree.isFile(arena, r.command))
        return fail("command \"{s}\" is not a file in the app tree the sources produce", .{r.command});
    const config = try r.appConfig(arena);
    var exported = config.exports.map.iterator();
    while (exported.next()) |e| if (!try tree.isFile(arena, e.value_ptr.command))
        return fail("export {s} runs \"{s}\", which is not a file in the app tree", .{ e.key_ptr.*, e.value_ptr.command });

    const start = ctx.now();
    const layer_file = try writeLayerFile(ctx, &tree);
    ctx.timed(start, "write layer ({d} entries)", .{tree.nodes.count()});
    const layer_desc = try ctx.store.putBlobFile(arena, layer_file.path, layer_file.hash, oci.media_type.layer_tar);

    const config_desc = try ctx.store.putBlob(arena, try oci.toJson(arena, config), oci.media_type.config);
    var annotations: std.json.ArrayHashMap([]const u8) = .{};
    try annotations.map.put(arena, "org.opencontainers.image.title", r.id);
    try annotations.map.put(arena, "org.opencontainers.image.version", r.version);
    const manifest: oci.Manifest = .{
        .config = config_desc,
        .layers = &.{layer_desc},
        .annotations = annotations,
    };
    const manifest_desc = try ctx.store.putBlob(arena, try oci.toJson(arena, manifest), oci.media_type.manifest);

    try install.install(ctx, .{
        .manifest_digest = manifest_desc.digest,
        .manifest = manifest,
        .config = config,
        .source = try Io.Dir.cwd().realPathFileAlloc(io, recipe_path, arena),
    });
}

/// Adds the paths a source contributes to `tree`. `file` holds its bytes.
fn addSource(
    io: Io,
    arena: Allocator,
    tree: *Tree,
    archives: *std.ArrayList(*Archive),
    src: recipe.Source,
    file: []const u8,
) !void {
    switch (src.kind()) {
        .file => {
            const stat = try Io.Dir.cwd().statFile(io, file, .{});
            const dest = try normalizePath(arena, src.dest orelse src.fileName());
            try tree.addFile(arena, dest, .{ .file = .{ .path = file, .size = stat.size } });
        },
        .zip => {
            const archive = try Archive.open(io, arena, file);
            try archives.append(arena, archive);
            try addZipEntries(arena, tree, archive, try zipfile.list(arena, &archive.reader), src.dest orelse ".", src.strip);
        },
    }
}

fn addZipEntries(arena: Allocator, tree: *Tree, archive: *Archive, entries: []const zipfile.Entry, dest: []const u8, strip: u32) !void {
    const base = try normalizePath(arena, dest);
    for (entries) |e| {
        const rel = try normalizePath(arena, stripComponents(e.name, strip) orelse continue);
        if (rel.len == 0) continue;
        const p = if (base.len == 0) rel else try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, rel });
        if (e.is_dir) {
            try tree.addDir(arena, p);
        } else {
            try tree.addFile(arena, p, .{ .zip = .{ .archive = archive, .entry = e } });
        }
    }
}

const LayerFile = struct {
    path: []const u8,
    hash: Store.FileHash,
};

/// Writes the layer to a temporary file, hashing it on the way.
fn writeLayerFile(ctx: *Context, tree: *const Tree) !LayerFile {
    const io = ctx.io;
    const path = try ctx.store.tmpPath(ctx.arena, "layer");
    errdefer Io.Dir.cwd().deleteFile(io, path) catch {};
    // Read access too, so the handle can query the file's final length.
    var file = try Io.Dir.cwd().createFile(io, path, .{ .read = true });
    defer file.close(io);

    var file_buf: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &file_buf);
    var hash_buf: [64 * 1024]u8 = undefined;
    var hashed = file_writer.interface.hashed(std.crypto.hash.sha2.Sha256.init(.{}), &hash_buf);
    try writeLayer(io, ctx.arena, tree, &hashed.writer);
    try hashed.writer.flush();
    try file_writer.interface.flush();

    return .{
        .path = path,
        .hash = .{
            .hex = std.fmt.bytesToHex(hashed.hasher.finalResult(), .lower),
            .size = try file.length(io),
        },
    };
}

fn writeLayer(io: Io, arena: Allocator, tree: *const Tree, out: *Io.Writer) !void {
    var w: layer.Writer = .init(out);
    const content = try arena.create(zipfile.Content);
    var read_buf: [64 * 1024]u8 = undefined;
    for (try tree.sorted(arena)) |node| {
        switch (node.content) {
            .dir => try w.addDir(node.path),
            .file => |f| {
                var src = try Io.Dir.cwd().openFile(io, f.path, .{});
                defer src.close(io);
                var reader = src.reader(io, &read_buf);
                w.addFile(node.path, f.size, &reader.interface) catch |err|
                    return fail("adding {s} to the layer: {t}", .{ node.path, err });
            },
            .zip => |z| {
                const reader = try content.open(&z.archive.reader, z.entry);
                w.addFile(node.path, z.entry.size, reader) catch |err|
                    return fail("adding {s} to the layer: {t}", .{ node.path, err });
            },
        }
    }
    try w.finish();
}

const Archive = struct {
    file: Io.File,
    reader: Io.File.Reader,
    buffer: [64 * 1024]u8,

    fn open(io: Io, arena: Allocator, path: []const u8) !*Archive {
        const a = try arena.create(Archive);
        a.file = try Io.Dir.cwd().openFile(io, path, .{});
        a.reader = a.file.reader(io, &a.buffer);
        return a;
    }

    fn close(a: *Archive, io: Io) void {
        a.file.close(io);
    }
};

/// The app tree a recipe describes: every path in it, and where each file's
/// bytes come from. A file added at an existing path replaces it, so later
/// sources overlay earlier ones.
const Tree = struct {
    /// Keyed by lowercased path: Windows paths are case-insensitive, so paths
    /// that differ only in case are the same entry.
    nodes: std.StringArrayHashMapUnmanaged(Node) = .empty,
    /// The path involved when an add fails with `error.PathConflict`.
    conflict: []const u8 = "",

    const Node = struct {
        /// '/'-separated, spelled as first added (as NTFS keeps a name's
        /// original case when a file is overwritten).
        path: []const u8,
        content: Content,
    };

    const Content = union(enum) {
        dir,
        file: struct { path: []const u8, size: u64 },
        zip: struct { archive: *Archive, entry: zipfile.Entry },
    };

    fn addDir(t: *Tree, arena: Allocator, path: []const u8) !void {
        _ = try t.ensureDir(arena, path);
    }

    fn addFile(t: *Tree, arena: Allocator, path: []const u8, content: Content) !void {
        const parent = if (std.fs.path.dirnamePosix(path)) |p| try t.ensureDir(arena, p) else "";
        const base = std.fs.path.basenamePosix(path);
        const full = if (parent.len == 0) base else try std.fmt.allocPrint(arena, "{s}/{s}", .{ parent, base });
        const gop = try t.nodes.getOrPut(arena, try std.ascii.allocLowerString(arena, full));
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .path = full, .content = content };
        } else if (gop.value_ptr.content == .dir) {
            t.conflict = gop.value_ptr.path;
            return error.PathConflict;
        } else {
            gop.value_ptr.content = content;
        }
    }

    /// Adds `path` and its parents as directories, and returns how the tree
    /// spells it.
    fn ensureDir(t: *Tree, arena: Allocator, path: []const u8) ![]const u8 {
        var spelled: []const u8 = "";
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |part| {
            const candidate = if (spelled.len == 0) part else try std.fmt.allocPrint(arena, "{s}/{s}", .{ spelled, part });
            const gop = try t.nodes.getOrPut(arena, try std.ascii.allocLowerString(arena, candidate));
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .path = candidate, .content = .dir };
            } else if (gop.value_ptr.content != .dir) {
                t.conflict = gop.value_ptr.path;
                return error.PathConflict;
            }
            spelled = gop.value_ptr.path;
        }
        return spelled;
    }

    fn isFile(t: *const Tree, arena: Allocator, path: []const u8) !bool {
        const key = try std.ascii.allocLowerString(arena, try normalizePath(arena, path));
        const node = t.nodes.get(key) orelse return false;
        return node.content != .dir;
    }

    /// All nodes sorted by path, which puts parents before their children.
    fn sorted(t: *const Tree, arena: Allocator) ![]const Node {
        const nodes = try arena.dupe(Node, t.nodes.values());
        std.mem.sort(Node, nodes, {}, struct {
            fn lessThan(_: void, a: Node, b: Node) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lessThan);
        return nodes;
    }
};

/// '/'-separated, without empty or "." components. "." becomes "".
fn normalizePath(arena: Allocator, p: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, p, "/\\");
    while (it.next()) |part| {
        if (!std.mem.eql(u8, part, ".")) try parts.append(arena, part);
    }
    return std.mem.join(arena, "/", parts.items);
}

/// Drops the first `n` components of a '/'-separated path, like
/// `tar --strip-components`. Null if nothing is left.
fn stripComponents(path: []const u8, n: u32) ?[]const u8 {
    var rest = path;
    for (0..n) |_| {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        rest = rest[slash + 1 ..];
    }
    return if (rest.len == 0) null else rest;
}

test stripComponents {
    try std.testing.expectEqualStrings("bin/rg.exe", stripComponents("rg-15/bin/rg.exe", 1).?);
    try std.testing.expectEqualStrings("rg.exe", stripComponents("rg.exe", 0).?);
    try std.testing.expect(stripComponents("rg-15", 1) == null);
    try std.testing.expect(stripComponents("README", 1) == null);
}

test "later sources overlay earlier ones, case-insensitively" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tree: Tree = .{};
    try tree.addFile(arena, "Bin/tool.exe", .{ .file = .{ .path = "first", .size = 1 } });
    try tree.addFile(arena, "bin/TOOL.exe", .{ .file = .{ .path = "second", .size = 2 } });
    try tree.addFile(arena, "bin/lib/x.dll", .{ .file = .{ .path = "third", .size = 3 } });

    const nodes = try tree.sorted(arena);
    try std.testing.expectEqual(4, nodes.len);
    try std.testing.expectEqualStrings("Bin", nodes[0].path);
    try std.testing.expectEqualStrings("Bin/lib", nodes[1].path);
    try std.testing.expectEqualStrings("Bin/lib/x.dll", nodes[2].path);
    try std.testing.expectEqualStrings("Bin/tool.exe", nodes[3].path);
    try std.testing.expectEqualStrings("second", nodes[3].content.file.path);
    try std.testing.expect(try tree.isFile(arena, "bin\\tool.exe"));

    try std.testing.expectError(error.PathConflict, tree.addDir(arena, "bin/tool.exe/sub"));
    try std.testing.expectEqualStrings("Bin/tool.exe", tree.conflict);
    try std.testing.expectError(error.PathConflict, tree.addFile(arena, "BIN/LIB", .{ .file = .{ .path = "x", .size = 0 } }));
}

test "zip sources stream into a layer" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "sample.zip", .data = @embedFile("testdata/sample.zip") });
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    // sample.zip holds top/, top/a.txt and top/sub/b.txt (no entry for top/sub/).
    const archive = try Archive.open(io, arena, try std.fs.path.join(arena, &.{ base, "sample.zip" }));
    defer archive.close(io);
    var tree: Tree = .{};
    try addZipEntries(arena, &tree, archive, try zipfile.list(arena, &archive.reader), "app", 1);

    var out: Io.Writer.Allocating = .init(arena);
    try writeLayer(io, arena, &tree, &out.writer);
    try tmp.dir.writeFile(io, .{ .sub_path = "layer.tar", .data = out.written() });
    const dest = try std.fs.path.join(arena, &.{ base, "out" });
    try layer.extract(io, arena, try std.fs.path.join(arena, &.{ base, "layer.tar" }), dest);

    const read = struct {
        fn read(a: Allocator, dir: []const u8, sub: []const u8) ![]u8 {
            return Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(a, &.{ dir, sub }), a, .unlimited);
        }
    }.read;
    try std.testing.expectEqualStrings("deflated " ** 20, try read(arena, dest, "app/a.txt"));
    try std.testing.expectEqualStrings("stored\n", try read(arena, dest, "app/sub/b.txt"));
    try std.testing.expect(!try tree.isFile(arena, "top/a.txt"));
}
