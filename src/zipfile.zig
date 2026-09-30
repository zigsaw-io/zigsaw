//! Reads zip archives entry by entry, so build sources can be streamed into a
//! layer without unpacking them to disk first.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zip = std.zip;
const flate = std.compress.flate;
const oci = @import("oci.zig");

pub const Entry = struct {
    /// Path inside the archive: '/'-separated, no trailing slash.
    name: []const u8,
    is_dir: bool,
    method: zip.CompressionMethod,
    /// Uncompressed size.
    size: u64,
    /// Where the entry's (compressed) data starts in the archive.
    data_offset: u64,
};

/// Lists an archive's entries in central-directory order.
pub fn list(arena: Allocator, reader: *Io.File.Reader) ![]Entry {
    var it = try zip.Iterator.init(reader);
    var entries: std.ArrayList(Entry) = .empty;
    while (try it.next()) |e| {
        switch (e.compression_method) {
            .store, .deflate => {},
            else => return error.UnsupportedCompressionMethod,
        }

        const raw_name = try arena.alloc(u8, e.filename_len);
        try reader.seekTo(e.header_zip_offset + @sizeOf(zip.CentralDirectoryFileHeader));
        try reader.interface.readSliceAll(raw_name);
        std.mem.replaceScalar(u8, raw_name, '\\', '/');
        const is_dir = std.mem.endsWith(u8, raw_name, "/");
        const name = if (is_dir) raw_name[0 .. raw_name.len - 1] else raw_name;
        if (!oci.isSafeRelPath(name)) return error.ZipBadFilename;
        if (is_dir and e.uncompressed_size != 0) return error.ZipBadDirectorySize;

        // The local header's name and extra field can differ in length from
        // the central directory's, so read it to find where the data starts.
        try reader.seekTo(e.file_offset);
        const local = try reader.interface.takeStruct(zip.LocalFileHeader, .little);
        if (!std.mem.eql(u8, &local.signature, &zip.local_file_header_sig)) return error.ZipBadFileOffset;

        try entries.append(arena, .{
            .name = name,
            .is_dir = is_dir,
            .method = e.compression_method,
            .size = e.uncompressed_size,
            .data_offset = e.file_offset + @sizeOf(zip.LocalFileHeader) + local.filename_len + local.extra_len,
        });
    }
    return entries.items;
}

/// Reads one entry's uncompressed bytes. Only one `Content` per archive
/// reader may be in use at a time, since they share its read position.
pub const Content = struct {
    decompress: flate.Decompress,
    window: [flate.max_window_len]u8,

    /// Positions `archive` at `entry`'s data and returns a reader of its
    /// uncompressed bytes, valid until `open` is called again.
    pub fn open(c: *Content, archive: *Io.File.Reader, entry: Entry) !*Io.Reader {
        try archive.seekTo(entry.data_offset);
        switch (entry.method) {
            .store => return &archive.interface,
            .deflate => {
                c.decompress = .init(&archive.interface, .raw, &c.window);
                return &c.decompress.reader;
            },
            else => unreachable, // Rejected by `list`.
        }
    }
};

test "list and read entries" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "sample.zip", .data = @embedFile("testdata/sample.zip") });
    var file = try tmp.dir.openFile(io, "sample.zip", .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    const entries = try list(arena, &reader);
    var names: std.ArrayList([]const u8) = .empty;
    for (entries) |e| try names.append(arena, e.name);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "top", "top/a.txt", "top/sub/b.txt" }), names.items);
    try std.testing.expect(entries[0].is_dir);

    var content: Content = undefined;
    for (entries[1..], [_][]const u8{ "deflated " ** 20, "stored\n" }) |e, want| {
        const r = try content.open(&reader, e);
        const got = try r.readAlloc(arena, @intCast(e.size));
        try std.testing.expectEqualStrings(want, got);
    }
}
