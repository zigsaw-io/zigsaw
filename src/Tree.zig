//! An app tree: every path in a layer to be, and where each file's bytes come
//! from: a downloaded file, an entry in a zip or tar archive, or a file a
//! build step wrote. A file added at an existing path replaces it, so later
//! sources overlay earlier ones.
//!
//! Sources aren't unpacked to disk to make a layer. Their entries are indexed
//! here, then streamed from the archives straight into the layer. Only
//! deploying the finished layer creates the app's files, once. Unpacking and
//! then reading everything back is slow on Windows, where Defender scans each
//! new file before it can be read.

const Tree = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const layer = @import("layer.zig");
const oci = @import("oci.zig");
const recipe = @import("recipe.zig");
const Store = @import("Store.zig");
const zipfile = @import("zipfile.zig");
const fail = Context.fail;

/// Keyed by lowercased path: Windows paths are case-insensitive, so paths
/// that differ only in case are the same entry.
nodes: std.StringArrayHashMapUnmanaged(Node) = .empty,
/// The path involved when an add fails with `error.PathConflict`.
conflict: []const u8 = "",

pub const Node = struct {
    /// '/'-separated, spelled as first added (as NTFS keeps a name's
    /// original case when a file is overwritten).
    path: []const u8,
    content: Content,
};

pub const Content = union(enum) {
    dir,
    file: struct { path: []const u8, size: u64 },
    zip: struct { archive: *Archive, entry: zipfile.Entry },
    /// `size` bytes at `offset` in a plain tar.
    tar: struct { archive: *Archive, offset: u64, size: u64 },
};

pub fn addDir(t: *Tree, arena: Allocator, path: []const u8) !void {
    _ = try t.ensureDir(arena, path);
}

pub fn addFile(t: *Tree, arena: Allocator, path: []const u8, content: Content) !void {
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

pub fn isFile(t: *const Tree, arena: Allocator, path: []const u8) !bool {
    const key = try std.ascii.allocLowerString(arena, try normalizePath(arena, path));
    const node = t.nodes.get(key) orelse return false;
    return node.content != .dir;
}

/// Removes what a recipe's `cleanup` patterns match, and everything below a
/// directory they match.
pub fn cleanup(t: *Tree, patterns: []const []const u8) void {
    if (patterns.len == 0) return;
    var i: usize = 0;
    while (i < t.nodes.count()) {
        if (recipe.cleanupMatches(patterns, t.nodes.values()[i].path)) {
            t.nodes.swapRemoveAt(i);
        } else i += 1;
    }
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

// ---------------------------------------------------------------------------
// From sources

/// Adds the paths a source contributes, under `base` ('/'-separated, "" for
/// the top). `file` holds its bytes, and `hash` is their sha256. Archives
/// stay open in `archives` while the tree is in use.
pub fn addSource(
    t: *Tree,
    ctx: *Context,
    archives: *std.ArrayList(*Archive),
    src: recipe.Source,
    file: []const u8,
    hash: []const u8,
) !void {
    const io = ctx.io;
    const arena = ctx.arena;
    switch (src.kind()) {
        .file => {
            const stat = try Io.Dir.cwd().statFile(io, file, .{});
            const dest = try normalizePath(arena, src.dest orelse src.fileName());
            try t.addFile(arena, dest, .{ .file = .{ .path = file, .size = stat.size } });
        },
        .zip => {
            const archive = try Archive.open(io, arena, file);
            try archives.append(arena, archive);
            try t.addZipEntries(arena, archive, try zipfile.list(arena, &archive.reader), src.dest orelse ".", src.strip);
        },
        .tar, .@"tar.gz", .@"tar.xz" => {
            const archive = try Archive.open(io, arena, try plainTar(ctx, file, src.kind(), hash));
            try archives.append(arena, archive);
            try t.addTarEntries(arena, archive, try listTar(arena, archive), src.dest orelse ".", src.strip);
        },
    }
}

fn addZipEntries(t: *Tree, arena: Allocator, archive: *Archive, entries: []const zipfile.Entry, dest: []const u8, strip: u32) !void {
    const base = try normalizePath(arena, dest);
    for (entries) |e| {
        const p = try entryPath(arena, base, e.name, strip) orelse continue;
        if (e.is_dir) {
            try t.addDir(arena, p);
        } else {
            try t.addFile(arena, p, .{ .zip = .{ .archive = archive, .entry = e } });
        }
    }
}

fn addTarEntries(t: *Tree, arena: Allocator, archive: *Archive, entries: []const TarEntry, dest: []const u8, strip: u32) !void {
    const base = try normalizePath(arena, dest);
    for (entries) |e| {
        const p = try entryPath(arena, base, e.name, strip) orelse continue;
        if (e.is_dir) {
            try t.addDir(arena, p);
        } else {
            try t.addFile(arena, p, .{ .tar = .{ .archive = archive, .offset = e.offset, .size = e.size } });
        }
    }
}

/// Where an archive entry goes in the tree: under `base`, after dropping
/// `strip` leading components. Null if nothing is left of it.
fn entryPath(arena: Allocator, base: []const u8, name: []const u8, strip: u32) !?[]const u8 {
    const rel = try normalizePath(arena, stripComponents(try normalizePath(arena, name), strip) orelse return null);
    if (rel.len == 0) return null;
    return if (base.len == 0) rel else try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, rel });
}

pub const Archive = struct {
    file: Io.File,
    reader: Io.File.Reader,
    buffer: [64 * 1024]u8,

    pub fn open(io: Io, arena: Allocator, path: []const u8) !*Archive {
        const a = try arena.create(Archive);
        a.file = try Io.Dir.cwd().openFile(io, path, .{});
        a.reader = a.file.reader(io, &a.buffer);
        return a;
    }

    pub fn close(a: *Archive, io: Io) void {
        a.file.close(io);
    }
};

const TarEntry = struct {
    /// '/'-separated, as in the archive.
    name: []const u8,
    is_dir: bool,
    /// Where the entry's bytes start in the (plain) tar.
    offset: u64,
    size: u64,
};

const TarLink = struct {
    name: []const u8,
    /// What the link points to, relative to its directory.
    target: []const u8,
};

/// Lists a tar's files and directories. A link to a file in the archive
/// becomes a copy of that file, as links can't go into layers; a link to
/// anything else fails.
fn listTar(arena: Allocator, archive: *Archive) ![]TarEntry {
    try archive.reader.seekTo(0);
    var name_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var link_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&archive.reader.interface, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var entries: std.ArrayList(TarEntry) = .empty;
    var links: std.ArrayList(TarLink) = .empty;
    while (try it.next()) |e| {
        const name = std.mem.trimEnd(u8, e.name, "/");
        if (!oci.isSafeRelPath(name)) return error.TarBadPath;
        if (e.kind == .sym_link) {
            // Resolved once all entries are known: the target may come later.
            try links.append(arena, .{ .name = try arena.dupe(u8, name), .target = try arena.dupe(u8, e.link_name) });
            continue;
        }
        try entries.append(arena, .{
            .name = try arena.dupe(u8, name),
            .is_dir = e.kind == .directory,
            // The iterator skips the file's bytes on the next call; they're
            // read later from here.
            .offset = archive.reader.logicalPos(),
            .size = e.size,
        });
    }
    if (links.items.len == 0) return entries.items;

    var by_name: std.StringHashMapUnmanaged(Resolved) = .empty;
    for (entries.items) |e| try by_name.put(arena, try normalizePath(arena, e.name), if (e.is_dir) .dir else .{ .file = e });
    for (links.items) |l| try by_name.put(arena, try normalizePath(arena, l.name), .{ .link = l });
    for (links.items) |l| {
        const target = try resolveLink(arena, by_name, l) orelse return error.TarLinkNotToAFile;
        try entries.append(arena, .{ .name = l.name, .is_dir = false, .offset = target.offset, .size = target.size });
    }
    return entries.items;
}

const Resolved = union(enum) { file: TarEntry, dir, link: TarLink };

/// The file a link in a tar points to, through links to links. Null if it
/// points to a directory, outside the archive, or to nothing in it.
fn resolveLink(arena: Allocator, by_name: std.StringHashMapUnmanaged(Resolved), link: TarLink) !?TarEntry {
    var current = link;
    // As many links as Windows follows in one path.
    for (0..63) |_| {
        const path = try linkTargetPath(arena, current.name, current.target) orelse return null;
        switch (by_name.get(path) orelse return null) {
            .file => |e| return e,
            .dir => return null,
            .link => |l| current = l,
        }
    }
    return null;
}

/// A link's target as a path in the archive, normalized: the target is
/// relative to the link's directory. Null if it's absolute, or leads out of
/// the archive.
fn linkTargetPath(arena: Allocator, link_name: []const u8, target: []const u8) !?[]const u8 {
    if (target.len == 0 or target[0] == '/' or target[0] == '\\' or std.mem.indexOfScalar(u8, target, ':') != null) return null;
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, try normalizePath(arena, link_name), "/");
    while (it.next()) |part| try parts.append(arena, part);
    _ = parts.pop();
    var target_it = std.mem.tokenizeAny(u8, target, "/\\");
    while (target_it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            _ = parts.pop() orelse return null;
            continue;
        }
        try parts.append(arena, part);
    }
    return try std.mem.join(arena, "/", parts.items);
}

test linkTargetPath {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("z/bin/zstd", (try linkTargetPath(arena, "z/bin/unzstd", "zstd")).?);
    try std.testing.expectEqualStrings("z/LICENSE", (try linkTargetPath(arena, "./z/doc/COPYING", "../LICENSE")).?);
    try std.testing.expectEqualStrings("z/a/b", (try linkTargetPath(arena, "z/l", "./a/./b")).?);
    try std.testing.expect(try linkTargetPath(arena, "z/l", "../../etc/passwd") == null);
    try std.testing.expect(try linkTargetPath(arena, "z/l", "/etc/passwd") == null);
    try std.testing.expect(try linkTargetPath(arena, "z/l", "C:\\x") == null);
}

/// A tar source as a plain tar: the file itself, or a decompressed copy kept
/// in the download cache next to it, named by the source's hash.
fn plainTar(ctx: *Context, file: []const u8, kind: recipe.Source.Kind, hash: []const u8) ![]const u8 {
    const io = ctx.io;
    const arena = ctx.arena;
    if (kind == .tar) return file;
    const dest = try ctx.store.path(arena, &.{ "cache", "downloads", try std.fmt.allocPrint(arena, "{s}.tar", .{hash}) });
    if (try Store.exists(io, dest)) return dest;

    const tmp = try ctx.store.tmpPath(arena, "untar");
    errdefer Io.Dir.cwd().deleteFile(io, tmp) catch {};
    {
        var in = try Io.Dir.cwd().openFile(io, file, .{});
        defer in.close(io);
        var in_buf: [64 * 1024]u8 = undefined;
        var reader = in.reader(io, &in_buf);
        var out = try Io.Dir.cwd().createFile(io, tmp, .{});
        defer out.close(io);
        var out_buf: [64 * 1024]u8 = undefined;
        var writer = out.writer(io, &out_buf);
        try decompress(ctx.gpa, kind, &reader.interface, &writer.interface);
        try writer.interface.flush();
    }
    try Io.Dir.rename(.cwd(), tmp, .cwd(), dest, io);
    return dest;
}

fn decompress(gpa: Allocator, kind: recipe.Source.Kind, in: *Io.Reader, out: *Io.Writer) !void {
    switch (kind) {
        .@"tar.gz" => try layer.gunzip(in, out),
        .@"tar.xz" => {
            var d = try std.compress.xz.Decompress.init(in, gpa, try gpa.alloc(u8, 64 * 1024));
            defer d.deinit();
            _ = try d.reader.streamRemaining(out);
        },
        else => unreachable,
    }
}

// ---------------------------------------------------------------------------
// From and to disk

/// The tree of the files and directories below `dir`, as a build step left
/// them. Links and other reparse points are refused: a layer can't hold them.
pub fn fromDir(io: Io, arena: Allocator, dir_path: []const u8) !Tree {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var t: Tree = .{};
    while (try walker.next(io)) |entry| {
        const rel = try arena.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, rel, '\\', '/');
        switch (entry.kind) {
            .directory => try t.addDir(arena, rel),
            .file => {
                const stat = try entry.dir.statFile(io, entry.basename, .{});
                const full = try std.fs.path.join(arena, &.{ dir_path, rel });
                try t.addFile(arena, rel, .{ .file = .{ .path = full, .size = stat.size } });
            },
            else => return fail("{s}\\{s} is a {t}; an app's files can only be files and directories", .{ dir_path, entry.path, entry.kind }),
        }
    }
    return t;
}

/// Creates the tree's files and directories below `dest_path`, which must
/// exist. Files already there at the same paths are replaced, as later
/// modules overlay earlier ones.
pub fn writeFiles(t: *const Tree, io: Io, arena: Allocator, dest_path: []const u8) !void {
    var dest = try Io.Dir.cwd().openDir(io, dest_path, .{});
    defer dest.close(io);
    const zip = try arena.create(zipfile.Content);
    var read_buf: [64 * 1024]u8 = undefined;
    var write_buf: [64 * 1024]u8 = undefined;
    for (try t.sorted(arena)) |node| {
        if (node.content == .dir) {
            try dest.createDirPath(io, node.path);
            continue;
        }
        var file_reader: Io.File.Reader = undefined;
        const src = try openContent(io, node.content, zip, &file_reader, &read_buf);
        defer if (src.file) |f| f.close(io);
        var out = try dest.createFile(io, node.path, .{});
        defer out.close(io);
        var writer = out.writer(io, &write_buf);
        try src.reader.streamExact64(&writer.interface, src.size);
        try writer.interface.flush();
    }
}

// ---------------------------------------------------------------------------
// To a layer

pub const LayerFile = struct {
    path: []const u8,
    hash: Store.FileHash,
};

/// Writes the layer to a temporary file, compressed as asked, hashing what's
/// written on the way. Images' layers are gzip-compressed; what vendor steps
/// make is kept as a plain tar, as its hash is pinned.
pub fn writeLayerFile(t: *const Tree, ctx: *Context, compression: oci.Compression) !LayerFile {
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
    switch (compression) {
        .none => try t.writeLayer(io, ctx.arena, &hashed.writer),
        .gzip => {
            const gz = try layer.gzip(ctx.arena, &hashed.writer);
            try t.writeLayer(io, ctx.arena, &gz.writer);
            try gz.finish();
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
    };
}

fn writeLayer(t: *const Tree, io: Io, arena: Allocator, out: *Io.Writer) !void {
    var w: layer.Writer = .init(out);
    const zip = try arena.create(zipfile.Content);
    var read_buf: [64 * 1024]u8 = undefined;
    for (try t.sorted(arena)) |node| {
        if (node.content == .dir) {
            try w.addDir(node.path);
            continue;
        }
        var file_reader: Io.File.Reader = undefined;
        const src = try openContent(io, node.content, zip, &file_reader, &read_buf);
        defer if (src.file) |f| f.close(io);
        w.addFile(node.path, src.size, src.reader) catch |err|
            return fail("adding {s} to the layer: {t}", .{ node.path, err });
    }
    try w.finish();
}

const Opened = struct {
    reader: *Io.Reader,
    size: u64,
    /// To close after reading, for a file on disk.
    file: ?Io.File = null,
};

/// Opens a file node's bytes for reading. Only one at a time per archive, as
/// they share its read position, and per `zip` and `file_reader`.
fn openContent(io: Io, content: Content, zip: *zipfile.Content, file_reader: *Io.File.Reader, buf: []u8) !Opened {
    switch (content) {
        .dir => unreachable,
        .file => |f| {
            const file = try Io.Dir.cwd().openFile(io, f.path, .{});
            file_reader.* = file.reader(io, buf);
            return .{ .reader = &file_reader.interface, .size = f.size, .file = file };
        },
        .zip => |z| return .{ .reader = try zip.open(&z.archive.reader, z.entry), .size = z.entry.size },
        .tar => |t| {
            try t.archive.reader.seekTo(t.offset);
            return .{ .reader = &t.archive.reader.interface, .size = t.size };
        },
    }
}

// ---------------------------------------------------------------------------
// Paths

/// '/'-separated, without empty or "." components. "." becomes "".
pub fn normalizePath(arena: Allocator, p: []const u8) ![]const u8 {
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

fn readTestFile(a: Allocator, dir: []const u8, sub: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(a, &.{ dir, sub }), a, .unlimited);
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
    try tree.addZipEntries(arena, archive, try zipfile.list(arena, &archive.reader), "app", 1);

    var out: Io.Writer.Allocating = .init(arena);
    try tree.writeLayer(io, arena, &out.writer);
    try tmp.dir.writeFile(io, .{ .sub_path = "layer.tar", .data = out.written() });
    const dest = try std.fs.path.join(arena, &.{ base, "out" });
    try layer.extract(io, arena, try std.fs.path.join(arena, &.{ base, "layer.tar" }), dest);

    try std.testing.expectEqualStrings("deflated " ** 20, try readTestFile(arena, dest, "app/a.txt"));
    try std.testing.expectEqualStrings("stored\n", try readTestFile(arena, dest, "app/sub/b.txt"));
    try std.testing.expect(!try tree.isFile(arena, "top/a.txt"));
}

test "tar sources stream into a layer" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    // Both hold the tree of sample.zip; the .xz one's names start with "./".
    const samples = [_]struct { []const u8, recipe.Source.Kind, []const u8 }{
        .{ "sample.tar.gz", .@"tar.gz", @embedFile("testdata/sample.tar.gz") },
        .{ "sample.tar.xz", .@"tar.xz", @embedFile("testdata/sample.tar.xz") },
    };
    for (samples) |sample| {
        const name, const kind, const bytes = sample;
        var in: Io.Reader = .fixed(bytes);
        var plain: Io.Writer.Allocating = .init(arena);
        try decompress(std.testing.allocator, kind, &in, &plain.writer);
        const tar_name = try std.fmt.allocPrint(arena, "{s}.plain", .{name});
        try tmp.dir.writeFile(io, .{ .sub_path = tar_name, .data = plain.written() });

        const archive = try Archive.open(io, arena, try std.fs.path.join(arena, &.{ base, tar_name }));
        defer archive.close(io);
        var tree: Tree = .{};
        try tree.addTarEntries(arena, archive, try listTar(arena, archive), "lib/x", 1);
        tree.cleanup(&.{"sub"});

        var out: Io.Writer.Allocating = .init(arena);
        try tree.writeLayer(io, arena, &out.writer);
        const layer_name = try std.fmt.allocPrint(arena, "{s}.layer", .{name});
        try tmp.dir.writeFile(io, .{ .sub_path = layer_name, .data = out.written() });
        const dest = try std.fs.path.join(arena, &.{ base, try std.fmt.allocPrint(arena, "{s}.out", .{name}) });
        try layer.extract(io, arena, try std.fs.path.join(arena, &.{ base, layer_name }), dest);

        try std.testing.expectEqualStrings("deflated " ** 20, try readTestFile(arena, dest, "lib/x/a.txt"));
        try std.testing.expect(!try tree.isFile(arena, "lib/x/sub/b.txt"));
        try std.testing.expect(!try Store.exists(io, try std.fs.path.join(arena, &.{ dest, "lib", "x", "sub" })));
    }
}

/// A tar of top/a.txt, with links top/sub/l -> ../a.txt, and top/l2 ->
/// `second_target`, which comes before what it points to.
fn writeLinkTestTar(io: Io, dir: Io.Dir, name: []const u8, second_target: []const u8) !void {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var tar: std.tar.Writer = .{ .underlying_writer = &out.writer };
    try tar.writeDir("top", .{ .mtime = 1 });
    try tar.writeLink("top/l2", second_target, .{ .mtime = 1 });
    try tar.writeDir("top/sub", .{ .mtime = 1 });
    try tar.writeLink("top/sub/l", "../a.txt", .{ .mtime = 1 });
    try tar.writeFileBytes("top/a.txt", "the file", .{ .mtime = 1 });
    try tar.finishPedantically();
    try dir.writeFile(io, .{ .sub_path = name, .data = out.written() });
}

test "links in tar sources become copies of the files they point to" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    try writeLinkTestTar(io, tmp.dir, "good.tar", "sub/l");
    const archive = try Archive.open(io, arena, try std.fs.path.join(arena, &.{ base, "good.tar" }));
    defer archive.close(io);
    var tree: Tree = .{};
    try tree.addTarEntries(arena, archive, try listTar(arena, archive), ".", 1);
    var out: Io.Writer.Allocating = .init(arena);
    try tree.writeLayer(io, arena, &out.writer);
    try tmp.dir.writeFile(io, .{ .sub_path = "good.layer", .data = out.written() });
    const dest = try std.fs.path.join(arena, &.{ base, "good.out" });
    try layer.extract(io, arena, try std.fs.path.join(arena, &.{ base, "good.layer" }), dest);
    try std.testing.expectEqualStrings("the file", try readTestFile(arena, dest, "sub/l"));
    try std.testing.expectEqualStrings("the file", try readTestFile(arena, dest, "l2"));

    // To a directory, to nothing, out of the archive.
    for ([_][]const u8{ "sub", "missing.txt", "../../x", "/etc/passwd" }) |target| {
        try writeLinkTestTar(io, tmp.dir, "bad.tar", target);
        const bad = try Archive.open(io, arena, try std.fs.path.join(arena, &.{ base, "bad.tar" }));
        defer bad.close(io);
        try std.testing.expectError(error.TarLinkNotToAFile, listTar(arena, bad));
    }
}

test "trees go to disk and back" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "sample.zip", .data = @embedFile("testdata/sample.zip") });
    try tmp.dir.writeFile(io, .{ .sub_path = "new-a.txt", .data = "replaced" });
    try tmp.dir.createDirPath(io, "prefix");
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const prefix = try std.fs.path.join(arena, &.{ base, "prefix" });

    const archive = try Archive.open(io, arena, try std.fs.path.join(arena, &.{ base, "sample.zip" }));
    defer archive.close(io);
    var first: Tree = .{};
    try first.addZipEntries(arena, archive, try zipfile.list(arena, &archive.reader), ".", 1);
    try first.writeFiles(io, arena, prefix);
    // A later module's file replaces an earlier one's.
    var second: Tree = .{};
    try second.addFile(arena, "a.txt", .{ .file = .{ .path = try std.fs.path.join(arena, &.{ base, "new-a.txt" }), .size = "replaced".len } });
    try second.writeFiles(io, arena, prefix);

    var back = try fromDir(io, arena, prefix);
    try std.testing.expect(try back.isFile(arena, "a.txt"));
    try std.testing.expect(try back.isFile(arena, "sub/b.txt"));
    try std.testing.expectEqual(3, back.nodes.count());
    try std.testing.expectEqualStrings("replaced", try readTestFile(arena, prefix, "a.txt"));
}
