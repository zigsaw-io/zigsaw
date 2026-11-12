//! A folder as a tar file, and a tar file as a folder: what `zigsaw volume
//! export` writes and `zigsaw volume import` reads (volumes.zig).
//!
//! The file is one other tools read: a POSIX tar of the folder's contents,
//! paths relative to it, sorted, a folder before what's in it. Layers are
//! written with Zig's std.tar (layer.zig), which is enough for an app's
//! files but not for someone's data: its writer stops at paths of 255 bytes
//! and files of 8 GiB, and its reader drops the times. So this has its own
//! of both, with pax extended headers (POSIX.1-2001) where the old header
//! falls short:
//! - `path`, for one that doesn't fit in it, or isn't ASCII (bsdtar reads
//!   the old header's name in the machine's code page);
//! - `size`, from 8 GiB;
//! - `mtime`, for the fraction of a second NTFS keeps.
//! A global pax header comes first, with what the archive is of
//! (`ZIGSAW.volume` and so on), which other tools pass over.
//!
//! Kept: files, folders (empty ones too), each file's time of last change,
//! and whether it's read-only. Not kept: ACLs, other attributes, alternate
//! streams, the times of folders. A link, to a file or a directory, is
//! neither followed nor written: a volume mounted in an app's data is a
//! junction there, and has an archive of its own.
//!
//! Reading takes what GNU tar and bsdtar write as well: GNU's long names
//! ('L'), sizes in base 256, "./" before every path. Links and devices in
//! an archive are passed over and counted. Every name is checked before
//! anything is made of it: an archive is a file from anywhere.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");
const oci = @import("oci.zig");
const snapshot = @import("snapshot.zig");
const volumes = @import("volumes.zig");
const Context = @import("Context.zig");
const fail = Context.fail;

const block_len = 512;
/// The largest number the old header's 11 octal digits hold: a size up to
/// 8 GiB, a time up to the year 2242.
const max_octal = 0o77777777777;
/// More than any pax header zigsaw or another tool writes for one file.
const max_pax_len = 1 << 20;
const ns_per_s = std.time.ns_per_s;

/// How many files a folder or an archive has, and their size.
pub const Tally = struct {
    files: u64 = 0,
    bytes: u64 = 0,
    dirs: u64 = 0,
    /// What was passed over: links in a folder, and in an archive links,
    /// devices and the like.
    links: u64 = 0,
};

/// A pax record: "path", "ZIGSAW.volume".
pub const Record = struct { key: []const u8, value: []const u8 };

// ---------------------------------------------------------------------------
// Writing

pub const Meta = struct {
    size: u64,
    /// Since 1970, as Io.Timestamp has it.
    mtime_ns: i96 = 0,
    read_only: bool = false,
};

pub const Writer = struct {
    out: *Io.Writer,

    /// What the archive is of, for whoever reads it: once, first.
    pub fn global(w: *Writer, arena: Allocator, records: []const Record) !void {
        if (records.len > 0) try w.pax(arena, 'g', "pax_global_header", records);
    }

    /// `path` has '/' between its parts, and none at its end.
    pub fn dir(w: *Writer, arena: Allocator, path: []const u8, mtime_ns: i96) !void {
        const name = try std.mem.concat(arena, u8, &.{ path, "/" });
        if (!fitsHeader(name)) try w.pax(arena, 'x', path, &.{.{ .key = "path", .value = name }});
        try w.header('5', name, 0, mtime_ns, 0o755);
    }

    /// Streams exactly `meta.size` bytes of `content` into the archive.
    pub fn file(w: *Writer, arena: Allocator, path: []const u8, meta: Meta, content: *Io.Reader) !void {
        try w.fileHeader(arena, path, meta);
        try content.streamExact64(w.out, meta.size);
        try w.out.splatByteAll(0, padding(meta.size));
    }

    fn fileHeader(w: *Writer, arena: Allocator, path: []const u8, meta: Meta) !void {
        var records: std.ArrayList(Record) = .empty;
        if (!fitsHeader(path)) try records.append(arena, .{ .key = "path", .value = path });
        if (meta.size > max_octal)
            try records.append(arena, .{ .key = "size", .value = try std.fmt.allocPrint(arena, "{d}", .{meta.size}) });
        if (meta.mtime_ns > 0 and @mod(meta.mtime_ns, ns_per_s) != 0) try records.append(arena, .{
            .key = "mtime",
            .value = try std.fmt.allocPrint(arena, "{d}.{d:0>9}", .{ @divFloor(meta.mtime_ns, ns_per_s), @as(u32, @intCast(@mod(meta.mtime_ns, ns_per_s))) }),
        });
        if (records.items.len > 0) try w.pax(arena, 'x', path, records.items);
        try w.header('0', path, meta.size, meta.mtime_ns, if (meta.read_only) 0o444 else 0o644);
    }

    /// The two empty blocks a tar ends with: a reader that finds none takes
    /// the archive for one cut short.
    pub fn finish(w: *Writer) !void {
        try w.out.splatByteAll(0, 2 * block_len);
    }

    /// A pax header: records for the entry that follows ('x'), or for the
    /// whole archive ('g').
    fn pax(w: *Writer, arena: Allocator, kind: u8, of: []const u8, records: []const Record) !void {
        var body: std.ArrayList(u8) = .empty;
        for (records) |r| {
            // "<length> <key>=<value>\n", the length counting its own digits.
            const rest = r.key.len + r.value.len + 3;
            var len = rest + 1;
            while (digits(len) + rest != len) len = digits(len) + rest;
            try body.print(arena, "{d} {s}={s}\n", .{ len, r.key, r.value });
        }
        // A name for readers that don't know pax, which then see a file.
        var name_buf: [100]u8 = undefined;
        const name = if (kind == 'g') of else name: {
            const base = of[if (std.mem.lastIndexOfScalar(u8, of, '/')) |i| i + 1 else 0..];
            const prefix = "PaxHeaders/";
            @memcpy(name_buf[0..prefix.len], prefix);
            const n = @min(base.len, name_buf.len - prefix.len);
            for (name_buf[prefix.len..][0..n], base[0..n]) |*to, c| to.* = if (std.ascii.isPrint(c)) c else '_';
            break :name name_buf[0 .. prefix.len + n];
        };
        try w.header(kind, name, body.items.len, 0, 0o644);
        try w.out.writeAll(body.items);
        try w.out.splatByteAll(0, padding(body.items.len));
    }

    fn header(w: *Writer, kind: u8, path: []const u8, size: u64, mtime_ns: i96, mode: u32) !void {
        var h: [block_len]u8 = @splat(0);
        if (splitPath(path)) |s| {
            @memcpy(h[0..s.name.len], s.name);
            @memcpy(h[345..][0..s.prefix.len], s.prefix);
        } else {
            // A pax `path` has it whole.
            @memcpy(h[0..100], path[0..100]);
        }
        octal(h[100..108], mode);
        octal(h[108..116], 0);
        octal(h[116..124], 0);
        if (size <= max_octal) octal(h[124..136], size) else base256(h[124..136], size);
        octal(h[136..148], @intCast(std.math.clamp(@divFloor(mtime_ns, ns_per_s), 0, max_octal)));
        h[156] = kind;
        @memcpy(h[257..263], "ustar\x00");
        @memcpy(h[263..265], "00");
        // The checksum counts its own field as blanks.
        @memset(h[148..156], ' ');
        var sum: u32 = 0;
        for (h) |b| sum += b;
        octal(h[148..155], sum);
        try w.out.writeAll(&h);
    }
};

fn digits(n: usize) usize {
    return std.fmt.count("{d}", .{n});
}

/// How many bytes fill a block after `size` of them.
fn padding(size: u64) usize {
    return @intCast((block_len - size % block_len) % block_len);
}

/// Whether the old header holds the path, as every reader takes it.
fn fitsHeader(path: []const u8) bool {
    for (path) |c| if (c >= 0x80) return false;
    return splitPath(path) != null;
}

/// The path as the old header holds it: a name of up to 100 bytes, and what's
/// before a '/' as a prefix of up to 155.
fn splitPath(path: []const u8) ?struct { prefix: []const u8, name: []const u8 } {
    if (path.len <= 100) return .{ .prefix = "", .name = path };
    var i = @min(path.len - 1, 155);
    while (i > 0) : (i -= 1) {
        const rest = path.len - i - 1;
        if (path[i] == '/' and rest >= 1 and rest <= 100) return .{ .prefix = path[0..i], .name = path[i + 1 ..] };
    }
    return null;
}

/// A number as tar has it: octal digits, then a NUL.
fn octal(field: []u8, value: u64) void {
    var v = value;
    var i = field.len - 1;
    field[i] = 0;
    while (i > 0) {
        i -= 1;
        field[i] = '0' + @as(u8, @intCast(v & 7));
        v >>= 3;
    }
    std.debug.assert(v == 0);
}

/// A number too large for the digits, as GNU tar and bsdtar write it: the
/// first byte's high bit, then the number, most significant byte first.
fn base256(field: []u8, value: u64) void {
    @memset(field, 0);
    field[0] = 0x80;
    std.mem.writeInt(u64, field[field.len - 8 ..][0..8], value, .big);
}

// ---------------------------------------------------------------------------
// Reading

pub const Entry = struct {
    /// '/' between its parts, none before or after.
    name: []const u8,
    kind: enum { dir, file },
    size: u64 = 0,
    mtime_ns: ?i96 = null,
    read_only: bool = false,
};

pub const Reader = struct {
    in: *Io.Reader,
    /// What the archive says it is of: the `ZIGSAW.` records of its global
    /// headers, kept in `arena`.
    global: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    arena: Allocator,
    /// An entry's name, until the next one.
    scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    /// The bytes of the file `next` returned that `stream` hasn't read, and
    /// what fills its last block.
    left: u64 = 0,
    pad: usize = 0,
    /// Links, devices and the like, passed over.
    skipped: u64 = 0,
    ended: bool = false,

    pub fn deinit(r: *Reader) void {
        r.scratch.deinit();
    }

    /// The next folder or file, or null at the archive's end. Fails with
    /// error.EndOfStream if the archive stops before that: one cut short.
    pub fn next(r: *Reader) !?Entry {
        if (r.ended) return null;
        try r.in.discardAll64(r.left + r.pad);
        r.left = 0;
        r.pad = 0;
        _ = r.scratch.reset(.retain_capacity);
        const scratch = r.scratch.allocator();
        var over: struct { path: ?[]const u8 = null, size: ?u64 = null, mtime_ns: ?i96 = null } = .{};
        while (true) {
            const h = try r.in.takeArray(block_len);
            if (std.mem.allEqual(u8, h, 0)) {
                r.ended = true;
                return null;
            }
            if (!checksumOk(h)) return error.NotTar;
            const kind = h[156];
            const field_size = try number(h[124..136]);
            switch (kind) {
                'x', 'g' => {
                    var it: PaxIterator = .{ .rest = try r.body(scratch, field_size, max_pax_len) };
                    while (try it.next()) |rec| {
                        if (kind == 'g') {
                            if (std.mem.startsWith(u8, rec.key, "ZIGSAW."))
                                try r.global.put(r.arena, try r.arena.dupe(u8, rec.key), try r.arena.dupe(u8, rec.value));
                        } else if (std.mem.eql(u8, rec.key, "path")) {
                            over.path = rec.value;
                        } else if (std.mem.eql(u8, rec.key, "size")) {
                            over.size = std.fmt.parseInt(u64, rec.value, 10) catch return error.BadHeader;
                        } else if (std.mem.eql(u8, rec.key, "mtime")) {
                            over.mtime_ns = parseTime(rec.value);
                        }
                    }
                    continue;
                },
                // GNU tar's name for the entry that follows.
                'L' => {
                    over.path = std.mem.sliceTo(try r.body(scratch, field_size, max_pax_len), 0);
                    continue;
                },
                // And its link's, which no entry kept here has.
                'K' => {
                    try r.in.discardAll64(field_size + padding(field_size));
                    continue;
                },
                else => {},
            }
            // All of the header is read before anything more of the archive:
            // `h` is the reader's own memory.
            const raw = over.path orelse try headerName(scratch, h);
            const size = over.size orelse field_size;
            const mode = number(h[100..108]) catch 0;
            const mtime_ns = over.mtime_ns orelse @as(i96, number(h[136..148]) catch 0) * ns_per_s;
            over = .{};
            const plain = kind == '0' or kind == 0 or kind == '7';
            const is_dir = kind == '5' or (plain and std.mem.endsWith(u8, raw, "/"));
            if (!plain and !is_dir) {
                // Links and devices have no bytes, whatever their size says.
                r.skipped += 1;
                if (kind < '1' or kind > '6') try r.in.discardAll64(size + padding(size));
                continue;
            }
            const name = clean(raw);
            if (is_dir) {
                // "./" is the folder itself.
                if (name.len == 0) continue;
                return .{ .name = name, .kind = .dir, .mtime_ns = mtime_ns };
            }
            if (name.len == 0) return error.BadHeader;
            r.left = size;
            r.pad = padding(size);
            return .{ .name = name, .kind = .file, .size = size, .mtime_ns = mtime_ns, .read_only = mode != 0 and mode & 0o200 == 0 };
        }
    }

    /// Writes the bytes of the file `next` returned to `out`.
    pub fn stream(r: *Reader, out: *Io.Writer) !void {
        const n = r.left;
        r.left = 0;
        // Whatever stops it, the rest isn't this file's to skip any more.
        errdefer r.pad = 0;
        try r.in.streamExact64(out, n);
    }

    /// The bytes after a header that are more of the header.
    fn body(r: *Reader, scratch: Allocator, size: u64, limit: usize) ![]u8 {
        if (size > limit) return error.BadHeader;
        const buf = try scratch.alloc(u8, @intCast(size));
        try r.in.readSliceAll(buf);
        try r.in.discardAll(padding(size));
        return buf;
    }
};

fn checksumOk(h: *const [block_len]u8) bool {
    const want = number(h[148..156]) catch return false;
    var sum: u64 = 0;
    for (h, 0..) |b, i| sum += if (i >= 148 and i < 156) ' ' else b;
    return sum == want;
}

/// A number in a header: octal digits among blanks and NULs, or in base 256.
fn number(field: []const u8) !u64 {
    if (field[0] & 0x80 != 0) {
        var v: u64 = field[0] & 0x7f;
        for (field[1..]) |b| {
            if (v >> 56 != 0) return error.BadHeader;
            v = v << 8 | b;
        }
        return v;
    }
    const text = std.mem.trim(u8, field, " \x00");
    if (text.len == 0) return 0;
    return std.fmt.parseInt(u64, text, 8) catch error.BadHeader;
}

/// The name in the old header, with its prefix if it's a POSIX one: GNU's
/// older format keeps other things there.
fn headerName(arena: Allocator, h: *const [block_len]u8) ![]const u8 {
    const name = std.mem.sliceTo(h[0..100], 0);
    const prefix = std.mem.sliceTo(h[345..500], 0);
    if (prefix.len == 0 or !std.mem.eql(u8, h[257..263], "ustar\x00")) return arena.dupe(u8, name);
    return std.mem.concat(arena, u8, &.{ prefix, "/", name });
}

/// Without the "./" tar puts before paths, and the '/' after a folder's.
fn clean(raw: []const u8) []const u8 {
    var name = raw;
    while (std.mem.startsWith(u8, name, "./")) name = std.mem.trimStart(u8, name[2..], "/");
    name = std.mem.trimEnd(u8, name, "/");
    return if (std.mem.eql(u8, name, ".")) "" else name;
}

const PaxIterator = struct {
    rest: []const u8,

    fn next(it: *PaxIterator) !?Record {
        if (it.rest.len == 0) return null;
        const space = std.mem.indexOfScalar(u8, it.rest, ' ') orelse return error.BadHeader;
        const len = std.fmt.parseInt(usize, it.rest[0..space], 10) catch return error.BadHeader;
        if (len < space + 3 or len > it.rest.len or it.rest[len - 1] != '\n') return error.BadHeader;
        const pair = it.rest[space + 1 .. len - 1];
        it.rest = it.rest[len..];
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.BadHeader;
        return .{ .key = pair[0..eq], .value = pair[eq + 1 ..] };
    }
};

/// "1731400000.123456789" as nanoseconds; null for what isn't a time after
/// 1970, which then stays as the old header has it.
fn parseTime(text: []const u8) ?i96 {
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse text.len;
    const seconds = std.fmt.parseInt(u64, text[0..dot], 10) catch return null;
    var ns: u32 = 0;
    if (dot < text.len) {
        const frac = text[dot + 1 ..][0..@min(9, text.len - dot - 1)];
        ns = std.fmt.parseInt(u32, frac, 10) catch return null;
        for (frac.len..9) |_| ns *= 10;
    }
    return @as(i96, seconds) * ns_per_s + ns;
}

// ---------------------------------------------------------------------------
// A folder to an archive

pub const PackOptions = struct {
    global: []const Record = &.{},
    /// Paths in the folder that are left out, their parts separated by '\'.
    left_out: []const []const u8 = &.{},
    /// What's in the folder itself under a name that starts so is left out.
    left_out_prefix: ?[]const u8 = null,
};

/// Writes the folder's files and folders to `out` as a tar. Fails, saying
/// why, on a file it can't read; error.WriteFailed is `out`'s to explain.
pub fn pack(io: Io, arena: Allocator, folder: []const u8, out: *Io.Writer, options: PackOptions) !Tally {
    var p: Packing = .{ .io = io, .w = .{ .out = out }, .options = options, .buf = try arena.alloc(u8, 64 * 1024) };
    try p.w.global(arena, options.global);
    try p.dir(try snapshot.absolute(io, arena, folder), "");
    try p.w.finish();
    return p.tally;
}

const Packing = struct {
    io: Io,
    w: Writer,
    options: PackOptions,
    buf: []u8,
    tally: Tally = .{},

    const Item = struct {
        name: []const u8,
        kind: Io.File.Kind,

        fn lessThan(_: void, a: Item, b: Item) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    };

    fn dir(p: *Packing, abs: []const u8, rel: []const u8) !void {
        // Its own memory, freed as it ends: a large tree has many paths.
        var scratch_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        var items: std.ArrayList(Item) = .empty;
        {
            var d = Io.Dir.cwd().openDir(p.io, abs, .{ .iterate = true }) catch |err| return fail("reading {s}: {t}", .{ abs, err });
            defer d.close(p.io);
            var it = d.iterate();
            while (it.next(p.io) catch |err| return fail("reading {s}: {t}", .{ abs, err })) |entry|
                try items.append(scratch, .{ .name = try scratch.dupe(u8, entry.name), .kind = entry.kind });
        }
        // The same archive from the same files, in whatever order Windows
        // lists them.
        std.mem.sort(Item, items.items, {}, Item.lessThan);
        for (items.items) |item| {
            if (rel.len == 0) if (p.options.left_out_prefix) |prefix| if (std.ascii.startsWithIgnoreCase(item.name, prefix)) continue;
            const child_rel = if (rel.len == 0) item.name else try std.mem.concat(scratch, u8, &.{ rel, "\\", item.name });
            if (p.isLeftOut(child_rel)) continue;
            const child = try std.mem.concat(scratch, u8, &.{ abs, "\\", item.name });
            var data: win32.WIN32_FILE_ATTRIBUTE_DATA = undefined;
            if (win32.GetFileAttributesExW(try snapshot.long(scratch, child), win32.GetFileExInfoStandard, &data) == 0)
                return fail("reading {s}: error {d} ({s})", .{ child, win32.GetLastError(), win32.errorName(win32.GetLastError()) });
            // However it shows: what a link leads to isn't the folder's.
            if (data.dwFileAttributes & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0) {
                p.tally.links += 1;
                continue;
            }
            const path = try scratch.dupe(u8, child_rel);
            std.mem.replaceScalar(u8, path, '\\', '/');
            switch (item.kind) {
                .directory => {
                    try p.w.dir(scratch, path, fileTimeNs(data.ftLastWriteTime));
                    p.tally.dirs += 1;
                    try p.dir(child, child_rel);
                },
                .file => try p.file(scratch, child, path, data.dwFileAttributes & win32.FILE_ATTRIBUTE_READONLY != 0),
                else => p.tally.links += 1,
            }
        }
    }

    fn file(p: *Packing, scratch: Allocator, abs: []const u8, path: []const u8, read_only: bool) !void {
        const hint = "; if a program has it open, close that first";
        var f = Io.Dir.cwd().openFile(p.io, abs, .{}) catch |err| return fail("reading {s}: {t}{s}", .{ abs, err, hint });
        defer f.close(p.io);
        // The size the header says is the one read, whatever a listing said.
        const stat = f.stat(p.io) catch |err| return fail("reading {s}: {t}", .{ abs, err });
        var reader = f.reader(p.io, p.buf);
        p.w.file(scratch, path, .{ .size = stat.size, .mtime_ns = stat.mtime.nanoseconds, .read_only = read_only }, &reader.interface) catch |err| switch (err) {
            error.EndOfStream => return fail("{s} got shorter while it was read: something still writes there", .{abs}),
            error.ReadFailed => return fail("reading {s}: {t}{s}", .{ abs, reader.err orelse error.Unexpected, hint }),
            else => |e| return e,
        };
        p.tally.files += 1;
        p.tally.bytes += stat.size;
    }

    fn isLeftOut(p: *const Packing, rel: []const u8) bool {
        for (p.options.left_out) |l| if (std.os.windows.eqlIgnoreCaseWtf8(l, rel)) return true;
        return false;
    }
};

/// A FILETIME, 100 ns since 1601, as nanoseconds since 1970.
fn fileTimeNs(ft: [2]win32.DWORD) i96 {
    const ticks = @as(i96, ft[1]) << 32 | ft[0];
    return (ticks - 116_444_736_000_000_000) * 100;
}

// ---------------------------------------------------------------------------
// An archive to a folder

pub const Unpacked = struct {
    tally: Tally,
    /// The archive's `ZIGSAW.` records, in the arena given.
    global: std.StringArrayHashMapUnmanaged([]const u8),

    pub fn get(u: Unpacked, key: []const u8) ?[]const u8 {
        return u.global.get(key);
    }
};

/// Makes the archive's folders and files in the folder `dest_path`, which is
/// there, and reads `in` to its end. Fails, saying why, on what the archive
/// has wrong and on a file it can't make; error.ReadFailed is `in`'s to
/// explain. What it made by then stays: the caller deletes it.
///
/// One file after another. Writing them several at once, as a rollback's
/// copy does (snapshot.zig), was tried and gained nothing: a file made by a
/// program Defender doesn't know costs about a millisecond here, however
/// many threads make them (docs/findings.md).
pub fn unpack(io: Io, arena: Allocator, in: *Io.Reader, dest_path: []const u8) !Unpacked {
    const dest_abs = try snapshot.absolute(io, arena, dest_path);
    var dest = try Io.Dir.cwd().openDir(io, dest_abs, .{});
    defer dest.close(io);
    var r: Reader = .{ .in = in, .arena = arena };
    defer r.deinit();
    var tally: Tally = .{};
    var made: std.StringHashMapUnmanaged(void) = .empty;
    const buf = try arena.alloc(u8, 64 * 1024);
    var scratch_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    while (r.next() catch |err| return readProblem(err)) |entry| {
        _ = scratch_state.reset(.retain_capacity);
        if (nameProblem(entry.name)) |why|
            return fail("the archive has an entry \"{f}\", {s}", .{ std.zig.fmtString(entry.name[0..@min(entry.name.len, 200)]), why });
        const rel = try scratch.dupe(u8, entry.name);
        std.mem.replaceScalar(u8, rel, '/', '\\');
        if (entry.kind == .dir) {
            try makeDir(io, arena, dest, &made, rel);
            tally.dirs += 1;
            continue;
        }
        if (std.fs.path.dirnameWindows(rel)) |parent| try makeDir(io, arena, dest, &made, parent);
        var out = dest.createFile(io, rel, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => return fail("the archive has {s} twice, or under names that differ only by case, which Windows takes for one", .{rel}),
            else => return fail("making {s}\\{s}: {t}", .{ dest_abs, rel, err }),
        };
        {
            defer out.close(io);
            var writer = out.writer(io, buf);
            r.stream(&writer.interface) catch |err| switch (err) {
                error.WriteFailed => return fail("writing {s}\\{s}: {t}", .{ dest_abs, rel, writer.err orelse error.Unexpected }),
                else => |e| return readProblem(e),
            };
            writer.interface.flush() catch return fail("writing {s}\\{s}: {t}", .{ dest_abs, rel, writer.err orelse error.Unexpected });
            if (entry.mtime_ns) |ns| out.setTimestamps(io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(ns) } }) catch {};
        }
        if (entry.read_only) {
            const full = try std.mem.concat(scratch, u8, &.{ dest_abs, "\\", rel });
            _ = win32.SetFileAttributesW(try snapshot.long(scratch, full), win32.FILE_ATTRIBUTE_READONLY);
        }
        tally.files += 1;
        tally.bytes += entry.size;
    }
    // What tar fills its last record with, so that whoever writes into a
    // pipe isn't left with bytes nobody reads.
    _ = in.discardRemaining() catch |err| switch (err) {
        error.ReadFailed => {},
    };
    tally.links = r.skipped;
    return .{ .tally = tally, .global = r.global };
}

fn readProblem(err: anyerror) anyerror {
    return switch (err) {
        error.EndOfStream => fail("the archive stops before its end: it was cut short, or isn't a whole tar file", .{}),
        error.NotTar => fail("it isn't a tar archive, plain or gzip-compressed: a header's checksum is wrong", .{}),
        error.BadHeader => fail("the archive has a header that can't be read", .{}),
        else => err,
    };
}

fn makeDir(io: Io, arena: Allocator, dest: Io.Dir, made: *std.StringHashMapUnmanaged(void), rel: []const u8) !void {
    if (made.contains(rel)) return;
    dest.createDirPath(io, rel) catch |err| return fail("making the folder {s}: {t}", .{ rel, err });
    try made.put(arena, try arena.dupe(u8, rel), {});
}

/// Why a name in an archive can't be a path in the folder, if it can't.
pub fn nameProblem(name: []const u8) ?[]const u8 {
    if (!oci.isSafeRelPath(name)) return "which isn't a path inside the volume";
    var it = std.mem.tokenizeAny(u8, name, "/\\");
    while (it.next()) |part| if (!volumes.isValidPart(part)) return "a part of which Windows can't have as a file's name";
    return null;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const repeat = @import("testing.zig").repeat;

fn testArena() std.heap.ArenaAllocator {
    return .init(testing.allocator);
}

test "a folder packed and unpacked: files, empty folders, long and non-ASCII paths, times, read-only" {
    const io = testing.io;
    var arena_state = testArena();
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const src = try std.fs.path.join(arena, &.{ base, "src" });
    const dst = try std.fs.path.join(arena, &.{ base, "dst" });

    // A path of more than 255 bytes in the archive: beyond the old header.
    const deep = "home\\" ++ repeat("0123456789abcdef0123456789abcdef0123456789abcdef\\", 5) ++ "deep.txt";
    try std.testing.expect(deep.len > 255);
    try tmp.dir.createDirPath(io, "src\\empty\\inner");
    try tmp.dir.createDirPath(io, "src\\cache");
    try tmp.dir.createDirPath(io, "src\\.zigsaw-import-1");
    try tmp.dir.createDirPath(io, std.fs.path.dirnameWindows("src\\" ++ deep).?);
    try tmp.dir.writeFile(io, .{ .sub_path = "src\\a.txt", .data = "alpha" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src\\" ++ deep, .data = "deep" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src\\caf\xc3\xa9 \xe6\x97\xa5.txt", .data = "names" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src\\cache\\gone", .data = "left out" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src\\.zigsaw-import-1\\x", .data = "left out" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src\\ro.bin", .data = repeat("\x00", 513) });
    const when: Io.Timestamp = .fromNanoseconds(1_700_000_000 * ns_per_s + 123_456_700);
    {
        var f = try tmp.dir.openFile(io, "src\\a.txt", .{ .mode = .read_write });
        defer f.close(io);
        try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = when } });
    }
    const ro = try win32.wide(arena, try std.fs.path.join(arena, &.{ src, "ro.bin" }));
    try testing.expect(win32.SetFileAttributesW(ro, win32.FILE_ATTRIBUTE_READONLY) != 0);
    defer _ = win32.SetFileAttributesW(ro, 0x80);
    // A link, which is passed over, and what it leads to with it.
    const junction = @import("junction.zig");
    try tmp.dir.createDirPath(io, "elsewhere");
    try tmp.dir.writeFile(io, .{ .sub_path = "elsewhere\\theirs", .data = "not mine" });
    const linked = try std.fs.path.join(arena, &.{ src, "mounted" });
    try testing.expectEqual(junction.Linked.made, try junction.link(io, arena, linked, try std.fs.path.join(arena, &.{ base, "elsewhere" })));
    defer _ = junction.unlink(io, arena, linked) catch {};

    var out: Io.Writer.Allocating = .init(arena);
    const options: PackOptions = .{
        .global = &.{.{ .key = "ZIGSAW.volume", .value = "pg" }},
        .left_out = &.{"Cache"},
        .left_out_prefix = ".zigsaw-",
    };
    const packed_tally = try pack(io, arena, src, &out.writer, options);
    try testing.expectEqual(4, packed_tally.files);
    try testing.expectEqual(1, packed_tally.links);
    try testing.expectEqual(5 + 4 + 5 + 513, packed_tally.bytes);
    // The same bytes from the same folder.
    var again: Io.Writer.Allocating = .init(arena);
    _ = try pack(io, arena, src, &again.writer, options);
    try testing.expectEqualSlices(u8, out.written(), again.written());
    try testing.expectEqual(0, out.written().len % block_len);

    try tmp.dir.createDirPath(io, "dst");
    var in: Io.Reader = .fixed(out.written());
    const got = try unpack(io, arena, &in, dst);
    try testing.expectEqual(4, got.tally.files);
    try testing.expectEqual(packed_tally.bytes, got.tally.bytes);
    try testing.expectEqualStrings("pg", got.get("ZIGSAW.volume").?);
    try testing.expectEqualStrings("alpha", try tmp.dir.readFileAlloc(io, "dst\\a.txt", arena, .unlimited));
    try testing.expectEqualStrings("deep", try tmp.dir.readFileAlloc(io, "dst\\" ++ deep, arena, .unlimited));
    try testing.expectEqualStrings("names", try tmp.dir.readFileAlloc(io, "dst\\caf\xc3\xa9 \xe6\x97\xa5.txt", arena, .unlimited));
    try testing.expectEqual(.directory, (try tmp.dir.statFile(io, "dst\\empty\\inner", .{})).kind);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "dst\\cache", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "dst\\mounted", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "dst\\.zigsaw-import-1", .{}));
    try testing.expectEqual(when.nanoseconds, (try tmp.dir.statFile(io, "dst\\a.txt", .{})).mtime.nanoseconds);
    const ro_out = try win32.wide(arena, try std.fs.path.join(arena, &.{ dst, "ro.bin" }));
    try testing.expect(win32.GetFileAttributesW(ro_out) & win32.FILE_ATTRIBUTE_READONLY != 0);
    _ = win32.SetFileAttributesW(ro_out, 0x80);
    try testing.expect(win32.GetFileAttributesW(try win32.wide(arena, try std.fs.path.join(arena, &.{ dst, "a.txt" }))) & win32.FILE_ATTRIBUTE_READONLY == 0);
}

/// The entries of an archive in memory, as "name" or "name/", and how many
/// it passed over.
fn listOf(arena: Allocator, bytes: []const u8) !struct { names: []const []const u8, skipped: u64 } {
    var in: Io.Reader = .fixed(bytes);
    var r: Reader = .{ .in = &in, .arena = arena };
    defer r.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    while (try r.next()) |e| try names.append(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ e.name, if (e.kind == .dir) "/" else "" }));
    return .{ .names = names.items, .skipped = r.skipped };
}

test "a size beyond the old header's digits" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: Io.Writer.Allocating = .init(arena);
    var w: Writer = .{ .out = &out.writer };
    const big = 9 << 30;
    try w.fileHeader(arena, "big.img", .{ .size = big, .mtime_ns = 5 * ns_per_s });
    var in: Io.Reader = .fixed(out.written());
    var r: Reader = .{ .in = &in, .arena = arena };
    defer r.deinit();
    const e = (try r.next()).?;
    try testing.expectEqual(big, e.size);
    try testing.expectEqual(5 * ns_per_s, e.mtime_ns.?);
    // Without the pax record too, as GNU tar writes it.
    try testing.expectEqual(big, try number(out.written()[block_len * 2 ..][124..136]));
}

test "what other tars write: ./ before paths, GNU long names, links, old headers" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: Io.Writer.Allocating = .init(arena);
    var w: Writer = .{ .out = &out.writer };
    try w.header('5', "./", 0, 0, 0o755);
    try w.header('5', "./sub/", 0, 0, 0o755);
    try w.header('0', "./sub/file", 0, 0, 0o644);
    const long_name = "sub/" ++ repeat("n", 300);
    try w.header('L', "././@LongLink", long_name.len + 1, 0, 0);
    try out.writer.writeAll(long_name ++ "\x00");
    try out.writer.splatByteAll(0, padding(long_name.len + 1));
    try w.header('0', long_name[0..100], 3, 0, 0o444);
    try out.writer.writeAll("abc");
    try out.writer.splatByteAll(0, padding(3));
    try w.header('2', "sub/link", 0, 0, 0o777);
    // A hard link's size is its target's, with no bytes after it.
    try w.header('1', "sub/hard", 3, 0, 0o644);
    try w.header('0', "old-style-dir/", 0, 0, 0);
    try w.header('0', "last", 0, 0, 0);
    try w.finish();

    const got = try listOf(arena, out.written());
    try testing.expectEqual(2, got.skipped);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "sub/", "sub/file", long_name, "old-style-dir/", "last" }), got.names);

    // Cut short: with no end, even at a header.
    try testing.expectError(error.EndOfStream, listOf(arena, out.written()[0 .. out.written().len - 2 * block_len]));
    try testing.expectError(error.EndOfStream, listOf(arena, out.written()[0 .. block_len * 3 + 100]));
    // And what isn't a tar.
    try testing.expectError(error.NotTar, listOf(arena, "MZ" ++ repeat("\x90", 600)));
}

test nameProblem {
    for ([_][]const u8{ "a", "a/b.txt", "home/AppData/Roaming/x y/z", "a\\b", ".git/config", "caf\xc3\xa9" }) |ok|
        try testing.expectEqual(null, nameProblem(ok));
    for ([_][]const u8{
        "",        "/etc/passwd", "..",    "../x",    "a/../../x", "C:/x", "C:x",  "a:stream",
        "\\\\srv", "a/./b",       "a/nul", "nul.txt", "COM1",      "a/b.", "a/b ", "a/b?",
        "a*",      "a/\x01",      "a|b",   "a/<b>",
    }) |bad| try testing.expect(nameProblem(bad) != null);
}

test "pax records and times" {
    var it: PaxIterator = .{ .rest = "12 path=a/b\n20 mtime=12.5000001\n" };
    const first = (try it.next()).?;
    try testing.expectEqualStrings("path", first.key);
    try testing.expectEqualStrings("a/b", first.value);
    try testing.expectEqual(12 * ns_per_s + 500_000_100, parseTime((try it.next()).?.value).?);
    try testing.expectEqual(null, try it.next());
    var bad: PaxIterator = .{ .rest = "99 path=a\n" };
    try testing.expectError(error.BadHeader, bad.next());
    try testing.expectEqual(7 * ns_per_s, parseTime("7").?);
    try testing.expectEqual(null, parseTime("-1.5"));
    try testing.expectEqualStrings("a/b", clean("././a/b/"));
    try testing.expectEqualStrings("", clean("./"));
    try testing.expectEqual(8, try number("0000010\x00"));
    try testing.expectEqual(0, try number("        "));
    try testing.expect(fitsHeader("a/" ++ repeat("b", 100)));
    try testing.expect(!fitsHeader(repeat("b", 101)));
    try testing.expect(!fitsHeader("caf\xc3\xa9"));
}
