//! Layers are plain tar files. They are written deterministically (sorted
//! entries, zero timestamps, fixed modes) so the same app tree always produces
//! the same bytes, and therefore the same digest.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const oci = @import("oci.zig");

/// Writes layer entries with canonical metadata. Callers must add entries in
/// sorted path order, parents before children; with the fixed metadata, that
/// makes the output depend only on the tree.
pub const Writer = struct {
    tar: std.tar.Writer,

    pub fn init(out: *Io.Writer) Writer {
        return .{ .tar = .{ .underlying_writer = out } };
    }

    /// `path` is '/'-separated and relative.
    pub fn addDir(w: *Writer, path: []const u8) !void {
        try w.tar.writeDir(path, .{ .mode = 0o755 });
    }

    /// Streams exactly `size` bytes from `content` into the layer.
    pub fn addFile(w: *Writer, path: []const u8, size: u64, content: *Io.Reader) !void {
        try w.tar.writeFileStream(path, size, content, .{});
    }

    /// Zig's tar reader doesn't need the end-of-archive blocks, but other
    /// readers expect them.
    pub fn finish(w: *Writer) !void {
        try w.tar.finishPedantically();
    }
};

/// Extracts the tar file at `tar_path` into `dest_path`, creating it if needed.
///
/// One pass creates the directories and notes where each file's bytes are;
/// then several workers create the files in parallel. Creating a file is slow
/// on Windows, where Defender scans each one, and that time overlaps well.
pub fn extract(io: Io, arena: Allocator, tar_path: []const u8, dest_path: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, dest_path);
    var dest = try Io.Dir.cwd().openDir(io, dest_path, .{});
    defer dest.close(io);

    const files = try indexAndCreateDirs(io, arena, tar_path, dest);
    if (files.len == 0) return;

    const cpus = std.Thread.getCpuCount() catch 4;
    const workers = try arena.alloc(ExtractWorker, @min(files.len, cpus, max_extract_workers));
    var next: std.atomic.Value(usize) = .init(0);
    for (workers) |*w| w.* = .{
        .io = io,
        .tar_path = tar_path,
        .dest = dest,
        .files = files,
        .next = &next,
        .read_buf = try arena.alloc(u8, 64 * 1024),
        .write_buf = try arena.alloc(u8, 64 * 1024),
    };

    var group: Io.Group = .init;
    for (workers) |*w| group.concurrent(io, ExtractWorker.run, .{w}) catch w.run();
    group.await(io) catch |err| return err;
    for (workers) |w| if (w.err) |err| return err;
}

/// Measured on zig's 19.5k files: 1 worker 14 s, 4 workers 8 s, and no real
/// gain beyond that, since Defender's scanning becomes the bottleneck.
const max_extract_workers = 4;

const FileEntry = struct {
    /// '/'-separated, relative to the destination.
    name: []const u8,
    /// Where the file's bytes start in the tar.
    offset: u64,
    size: u64,
};

fn indexAndCreateDirs(io: Io, arena: Allocator, tar_path: []const u8, dest: Io.Dir) ![]const FileEntry {
    var file = try Io.Dir.cwd().openFile(io, tar_path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buf);
    var name_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var link_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&reader.interface, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });

    var files: std.ArrayList(FileEntry) = .empty;
    var dirs: std.StringHashMapUnmanaged(void) = .empty;
    while (try it.next()) |entry| {
        const name = std.mem.trimEnd(u8, entry.name, "/");
        if (!oci.isSafeRelPath(name)) return error.TarBadPath;
        switch (entry.kind) {
            .directory => try createDirOnce(io, arena, dest, &dirs, name),
            .file => {
                if (std.fs.path.dirnamePosix(name)) |parent| try createDirOnce(io, arena, dest, &dirs, parent);
                // The iterator skips the file's bytes on the next call; the
                // workers read them later from this offset.
                try files.append(arena, .{ .name = try arena.dupe(u8, name), .offset = reader.logicalPos(), .size = entry.size });
            },
            .sym_link => return error.TarSymlinkUnsupported,
        }
    }
    return files.items;
}

fn createDirOnce(io: Io, arena: Allocator, dest: Io.Dir, created: *std.StringHashMapUnmanaged(void), name: []const u8) !void {
    const gop = try created.getOrPut(arena, name);
    if (gop.found_existing) return;
    gop.key_ptr.* = try arena.dupe(u8, name);
    try dest.createDirPath(io, name);
}

const ExtractWorker = struct {
    io: Io,
    tar_path: []const u8,
    dest: Io.Dir,
    files: []const FileEntry,
    /// Index of the next file to take, shared by all workers.
    next: *std.atomic.Value(usize),
    read_buf: []u8,
    write_buf: []u8,
    err: ?anyerror = null,

    fn run(w: *ExtractWorker) void {
        w.extractFiles() catch |err| {
            w.err = err;
            // Make the other workers stop early.
            _ = w.next.swap(w.files.len, .monotonic);
        };
    }

    fn extractFiles(w: *ExtractWorker) !void {
        const io = w.io;
        var tar = try Io.Dir.cwd().openFile(io, w.tar_path, .{});
        defer tar.close(io);
        var reader = tar.reader(io, w.read_buf);
        while (true) {
            const i = w.next.fetchAdd(1, .monotonic);
            if (i >= w.files.len) return;
            const entry = w.files[i];
            try reader.seekTo(entry.offset);
            var out = try w.dest.createFile(io, entry.name, .{ .exclusive = true });
            defer out.close(io);
            var writer = out.writer(io, w.write_buf);
            try reader.interface.streamExact64(&writer.interface, entry.size);
            try writer.interface.flush();
        }
    }
};

test "layers round-trip" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: Io.Writer.Allocating = .init(arena);
    var w: Writer = .init(&out.writer);
    try w.addDir("bin");
    var content: Io.Reader = .fixed("MZ fake");
    try w.addFile("bin/tool.exe", 7, &content);
    try w.finish();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "layer.tar", .data = out.written() });
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const tar_path = try std.fs.path.join(arena, &.{ base, "layer.tar" });
    const dest = try std.fs.path.join(arena, &.{ base, "out" });
    try extract(io, arena, tar_path, dest);
    const got = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ dest, "bin", "tool.exe" }), arena, .unlimited);
    try std.testing.expectEqualStrings("MZ fake", got);
}
