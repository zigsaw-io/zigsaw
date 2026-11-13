//! A layer's blob, read by many threads at once while it isn't in the store
//! yet: what a lazy pull's helper (LazyHelper.zig) serves files from, and what
//! its download fills.
//!
//! With a backing file (the helper's, `attach`), every byte fetched goes into
//! it: a sparse file the size of the blob, with a map of its 1 MiB blocks
//! beside it that says which it has, so that the next helper goes on from
//! there and the download skips what runs fetched. A read asks for the
//! blocks of its whole span that nobody has asked for yet, which go out as
//! one Range request per run of them (at most `demand_piece`), on a few
//! threads with a registry client each: what a run waits for first, then
//! what was asked for ahead of any run (`prefetchAhead`: the files runs read
//! of the layer before this one), then the download's; neither of those ever
//! takes the last thread. It then waits for its blocks and reads them from
//! the file. Once the blob is complete (`finish`),
//! reads come from the store's blob.
//!
//! The pull's own (`attachMemory`), which reads its programs' headers, keeps
//! the blocks in memory instead, and asks for all the headers at once. With
//! neither, a read is one Range request for its span.
//!
//! What the store's other blobs have of it, as an update's previous version
//! does, is copied from them rather than fetched (`claim`, `writeAt`,
//! `settle`): a helper with a plan, which has blocks of 64 KiB, so that what
//! lies between two copies fetches little.
//!
//! Nothing here checks what it reads: the index checks each chunk against
//! the TOC (and `invalidate`s what fails, to fetch it again), and the
//! download checks the blob against its digest.

const BlobReader = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Context = @import("Context.zig");
const Registry = @import("Registry.zig");
const format = @import("format.zig");
const win32 = @import("win32.zig");

gpa: Allocator,
base: *Context,
ref: Registry.Reference,
digest: []const u8,
size: u64,
tail: []const u8,
tail_start: u64,
block_size: u64 = 1 << 20,

/// Guards everything below but the counters, and the file's lifetime is
/// `file_lock`'s.
lock: win32.SRWLOCK = .{},
cond: win32.CONDITION_VARIABLE = .{},
/// One per block of the blob below its tail; none without a backing file.
blocks: []State = &.{},
have_blocks: usize = 0,
have_bytes: u64 = 0,
demand: std.ArrayList(Piece) = .empty,
ahead: std.ArrayList(Piece) = .empty,
background: std.ArrayList(Piece) = .empty,
/// The download's pieces queued, and those being fetched.
background_out: usize = 0,
background_busy: usize = 0,
/// Pieces asked for ahead of use being fetched.
ahead_busy: usize = 0,
/// Runs' pieces being fetched, and when the last one ended (GetTickCount64).
demand_busy: usize = 0,
demand_done_at: u64 = 0,
/// Why the download's last piece failed, until `downloadAll` says so.
background_failed: ?anyerror = null,
/// Why the last piece failed, for a reader whose blocks it had.
last_error: ?anyerror = null,
stopping: bool = false,
workers: []std.Thread = &.{},
clients: []Client,
free_clients: usize,

file_lock: win32.SRWLOCK = .{},
file: ?Io.File = null,
/// Without a file (`attachMemory`): each had block's bytes.
mem: []?[]u8 = &.{},
map: ?Io.File = null,
data_path: []const u8 = "",
map_path: []const u8 = "",
/// Once complete: the store's blob, opened for each read so that it can move.
done_path: []const u8 = "",

/// Requests sent; bytes fetched for reads, ahead of them, and for the
/// download; bytes an earlier helper had fetched.
requests: std.atomic.Value(u64) = .init(0),
on_demand: std.atomic.Value(u64) = .init(0),
ahead_bytes: std.atomic.Value(u64) = .init(0),
downloaded: std.atomic.Value(u64) = .init(0),
earlier: u64 = 0,
/// Bytes copied from other blobs in the store, rather than fetched.
copied: std.atomic.Value(u64) = .init(0),
/// What each thread is fetching, and how much of it has come so far: what
/// `received` counts, for a helper to tell Windows a slow fetch goes on.
inflight: []Inflight = &.{},
/// Tests' hook (ZIGSAW_TEST_LAZY_SLOW): at most this many bytes a second
/// for each request. 0: as fast as they come.
throttle: u64 = 0,
/// Tests' hook (ZIGSAW_TEST_LAZY_WAIT): each request waits this long before
/// it goes, as one behind others would.
wait_ms: u32 = 0,
/// Tests' fetch, in place of the registry's: `len` bytes from `offset`,
/// written to `w`.
test_fetch: ?*const fn (b: *BlobReader, offset: u64, len: usize, w: *Io.Writer) anyerror!void = null,

/// The most a run's request asks for at once: a chunk of 4 MiB fits, and
/// the download's pieces queue behind it.
pub const demand_piece: u64 = 4 << 20;
/// The download's requests: big enough that latency is little of their time,
/// small enough that what a run asks for next isn't long behind one.
pub const background_piece: u64 = 8 << 20;
/// How long after a run's last fetch the download waits to go on.
const quiet_ms = 1000;

/// `copying`: claimed by whoever copies it from another blob, until it
/// `settle`s it.
const State = enum(u8) { missing, queued_background, queued_ahead, queued_demand, fetching, copying, have };

const Inflight = struct {
    busy: bool = false,
    start: u64 = 0,
    end: u64 = 0,
    got: std.atomic.Value(u64) = .init(0),
};

pub const Piece = struct { start: u64, end: u64 };

/// A registry client, which one request at a time uses. Replaced, with its
/// arena, every so many requests: Registry allocates each request's strings
/// in its context's arena, and refreshes a token only once.
const Client = struct {
    busy: bool = false,
    ready: bool = false,
    uses: u32 = 0,
    arena: std.heap.ArenaAllocator = undefined,
    ctx: Context = undefined,
    registry: Registry = undefined,

    const max_uses = 64;
};

pub const Options = struct {
    /// How many requests at once.
    clients: usize = 4,
    /// The blocks the map counts. A map already there keeps its own.
    block_size: u64 = 1 << 20,
};

/// The block size of a helper whose blob is copied in part from others: what
/// lies between two copies is fetched in whole blocks.
pub const copy_block_size: u64 = 64 << 10;

pub fn init(gpa: Allocator, base: *Context, ref: Registry.Reference, digest: []const u8, size: u64, tail: []const u8, options: Options) !*BlobReader {
    const b = try gpa.create(BlobReader);
    errdefer gpa.destroy(b);
    const clients = try gpa.alloc(Client, @max(options.clients, 1));
    for (clients) |*c| c.* = .{};
    b.* = .{
        .gpa = gpa,
        .base = base,
        .ref = ref,
        .digest = digest,
        .size = size,
        .tail = tail,
        .tail_start = size - tail.len,
        .block_size = options.block_size,
        .clients = clients,
        .free_clients = clients.len,
    };
    return b;
}

pub fn deinit(b: *BlobReader) void {
    b.stop();
    for (b.workers) |t| t.join();
    b.gpa.free(b.workers);
    for (b.clients) |*c| if (c.ready) {
        c.registry.deinit();
        c.arena.deinit();
    };
    b.gpa.free(b.clients);
    b.gpa.free(b.inflight);
    b.demand.deinit(b.gpa);
    b.ahead.deinit(b.gpa);
    b.background.deinit(b.gpa);
    b.closeFiles();
    for (b.mem) |m| if (m) |block| b.gpa.free(block);
    b.gpa.free(b.mem);
    b.gpa.free(b.blocks);
    b.gpa.destroy(b);
}

/// Ends the threads' work: what waits gets error.Stopped.
pub fn stop(b: *BlobReader) void {
    win32.AcquireSRWLockExclusive(&b.lock);
    b.stopping = true;
    win32.ReleaseSRWLockExclusive(&b.lock);
    win32.WakeAllConditionVariable(&b.cond);
}

pub fn source(b: *BlobReader) format.Source {
    return .{ .context = b, .readAtFn = readAt, .size = b.size };
}

fn blockCount(b: *const BlobReader) usize {
    return @intCast(std.math.divCeil(u64, b.tail_start, b.block_size) catch unreachable);
}

fn blockEnd(b: *const BlobReader, i: usize) u64 {
    return @min(@as(u64, i + 1) * b.block_size, b.tail_start);
}

fn blockLen(b: *const BlobReader, i: usize) u64 {
    return b.blockEnd(i) - @as(u64, i) * b.block_size;
}

// ---------------------------------------------------------------------------
// The backing file and its map

const map_magic = "ZSHAVE01";

/// Backs reads with the file at `data_path`, made sparse, and its map at
/// `map_path`, whatever of them an earlier helper left: its blocks the map
/// says it has are kept. A `legacy_path` (0.77's download, the blob's first
/// bytes) is taken over, its whole blocks as had. Starts `workers` threads.
/// Returns how many bytes there were already.
pub fn attach(b: *BlobReader, data_path: []const u8, map_path: []const u8, legacy_path: ?[]const u8) !u64 {
    const io = b.base.io;
    if (mapBlockSize(io, map_path, b.size)) |size| b.block_size = size;
    const n = b.blockCount();
    b.blocks = try b.gpa.alloc(State, n);
    @memset(b.blocks, .missing);
    b.data_path = data_path;
    b.map_path = map_path;

    var legacy_len: u64 = 0;
    if (legacy_path) |legacy| legacy: {
        if (try exists(io, data_path)) break :legacy;
        var f = Io.Dir.cwd().openFile(io, legacy, .{}) catch |err| switch (err) {
            error.FileNotFound => break :legacy,
            else => |e| return e,
        };
        legacy_len = f.length(io) catch 0;
        f.close(io);
        try Io.Dir.rename(.cwd(), legacy, .cwd(), data_path, io);
    }

    var file = try Io.Dir.cwd().createFile(io, data_path, .{ .truncate = false, .read = true });
    errdefer file.close(io);
    try setSparse(file, true);
    if (try file.length(io) != b.size) try file.setLength(io, b.size);
    // The tail is the blob's: the file is the whole blob once the blocks are in.
    try file.writePositionalAll(io, b.tail, b.tail_start);
    var map = try Io.Dir.cwd().createFile(io, map_path, .{ .truncate = false, .read = true });
    errdefer map.close(io);

    if (legacy_len > 0) {
        const whole: usize = @intCast(@min(legacy_len, b.tail_start) / b.block_size);
        for (b.blocks[0..whole]) |*s| s.* = .have;
    } else {
        b.loadMap(map);
    }
    for (b.blocks, 0..) |s, i| if (s == .have) {
        b.have_blocks += 1;
        b.have_bytes += b.blockLen(i);
    };
    b.earlier = b.have_bytes;
    b.file = file;
    b.map = map;
    b.writeMap();

    try b.startWorkers();
    return b.have_bytes;
}

fn startWorkers(b: *BlobReader) !void {
    b.inflight = try b.gpa.alloc(Inflight, b.clients.len);
    for (b.inflight) |*f| f.* = .{};
    b.workers = try b.gpa.alloc(std.Thread, b.clients.len);
    var started: usize = 0;
    errdefer {
        b.stop();
        for (b.workers[0..started]) |t| t.join();
        b.gpa.free(b.workers);
        b.workers = &.{};
    }
    for (b.workers, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, work, .{ b, &b.inflight[i] });
        started += 1;
    }
}

/// The block size of the map at `path`, if it's a map of a blob this size
/// with a size of block this reads: 0.78's 1 MiB, or `copy_block_size`.
fn mapBlockSize(io: Io, path: []const u8, size: u64) ?u64 {
    var map = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer map.close(io);
    var header: [24]u8 = undefined;
    const got = map.readPositional(io, &.{&header}, 0) catch return null;
    if (got != header.len or !std.mem.eql(u8, header[0..8], map_magic)) return null;
    if (std.mem.readInt(u64, header[16..24], .little) != size) return null;
    const block = std.mem.readInt(u64, header[8..16], .little);
    if (block != 1 << 20 and block != copy_block_size) return null;
    return block;
}

/// Backs reads with blocks kept in memory, for a process that reads a few
/// files' first chunks (the pull's program headers): neighbours share blocks,
/// and what `prefetch` asks for comes in parallel. Starts the threads.
pub fn attachMemory(b: *BlobReader) !void {
    const n = b.blockCount();
    b.blocks = try b.gpa.alloc(State, n);
    @memset(b.blocks, .missing);
    b.mem = try b.gpa.alloc(?[]u8, n);
    @memset(b.mem, null);
    try b.startWorkers();
}

/// The map's blocks, if it's this blob's: a map of another size, or none,
/// says nothing is had.
fn loadMap(b: *BlobReader, map: Io.File) void {
    const io = b.base.io;
    const n = b.blocks.len;
    const bytes = b.gpa.alloc(u8, 24 + (n + 7) / 8) catch return;
    defer b.gpa.free(bytes);
    const got = map.readPositional(io, &.{bytes}, 0) catch return;
    if (got != bytes.len or !std.mem.eql(u8, bytes[0..8], map_magic)) return;
    if (std.mem.readInt(u64, bytes[8..16], .little) != b.block_size) return;
    if (std.mem.readInt(u64, bytes[16..24], .little) != b.size) return;
    for (0..n) |i| if (bytes[24 + i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0) {
        b.blocks[i] = .have;
    };
}

/// Writes the map, with the lock held.
fn writeMap(b: *BlobReader) void {
    const map = b.map orelse return;
    var buf: [24 + 512]u8 = undefined;
    @memcpy(buf[0..8], map_magic);
    std.mem.writeInt(u64, buf[8..16], b.block_size, .little);
    std.mem.writeInt(u64, buf[16..24], b.size, .little);
    // In pieces of 4096 blocks, so that a map of any size needs no allocation.
    var first: usize = 0;
    var at: u64 = 0;
    while (true) {
        const count = @min(b.blocks.len - first, 4096);
        const header: usize = if (first == 0) 24 else 0;
        const bits = buf[header..][0 .. (count + 7) / 8];
        @memset(bits, 0);
        for (b.blocks[first..][0..count], 0..) |s, i| if (s == .have) {
            bits[i / 8] |= @as(u8, 1) << @intCast(i % 8);
        };
        map.writePositionalAll(b.base.io, buf[0 .. header + bits.len], at) catch return;
        at += header + bits.len;
        first += count;
        if (first >= b.blocks.len) break;
    }
}

fn setSparse(file: Io.File, sparse: bool) !void {
    const in: win32.FILE_SET_SPARSE_BUFFER = .{ .SetSparse = @intFromBool(sparse) };
    var returned: win32.DWORD = 0;
    if (win32.DeviceIoControl(file.handle, win32.FSCTL_SET_SPARSE, &in, @sizeOf(win32.FILE_SET_SPARSE_BUFFER), null, 0, &returned, null) == 0) {
        // FAT and some shares have no sparse files: then it's a plain one.
        if (sparse) return;
        return win32.lastErrorFail("FSCTL_SET_SPARSE");
    }
}

fn closeFiles(b: *BlobReader) void {
    const io = b.base.io;
    win32.AcquireSRWLockExclusive(&b.file_lock);
    defer win32.ReleaseSRWLockExclusive(&b.file_lock);
    if (b.file) |f| f.close(io);
    if (b.map) |m| m.close(io);
    b.file = null;
    b.map = null;
}

/// As Store.exists.
fn exists(io: Io, path: []const u8) !bool {
    Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

/// Bytes the file has, the tail's among them.
pub fn haveBytes(b: *BlobReader) u64 {
    win32.AcquireSRWLockExclusive(&b.lock);
    defer win32.ReleaseSRWLockExclusive(&b.lock);
    if (b.done_path.len > 0) return b.size;
    return b.have_bytes + b.tail.len;
}

/// Says that the blob is complete at `path`, the store's: reads come from it.
pub fn setDone(b: *BlobReader, path: []const u8) void {
    win32.AcquireSRWLockExclusive(&b.file_lock);
    defer win32.ReleaseSRWLockExclusive(&b.file_lock);
    win32.AcquireSRWLockExclusive(&b.lock);
    defer win32.ReleaseSRWLockExclusive(&b.lock);
    b.done_path = path;
}

// ---------------------------------------------------------------------------
// Reading

fn readAt(context: *const anyopaque, offset: u64, buffer: []u8) anyerror!usize {
    const b: *BlobReader = @ptrCast(@alignCast(@constCast(context)));
    if (offset >= b.size or buffer.len == 0) return 0;
    if (offset >= b.tail_start) {
        const tail = b.tail[@intCast(offset - b.tail_start)..];
        const n = @min(buffer.len, tail.len);
        @memcpy(buffer[0..n], tail[0..n]);
        return n;
    }
    // Up to the tail, which the caller reads next from what it has.
    const want = buffer[0..@intCast(@min(buffer.len, b.tail_start - offset))];
    if (try b.readDone(offset, want)) return want.len;
    if (b.blocks.len == 0) {
        try b.fetchRange(offset, want, null);
        _ = b.on_demand.fetchAdd(want.len, .monotonic);
        return want.len;
    }
    try b.request(offset, offset + want.len, .demand);
    _ = try b.waitFor(offset, offset + want.len, null);
    if (b.mem.len > 0) {
        // Had blocks don't change, so no lock is needed to read them.
        var at = offset;
        while (at < offset + want.len) {
            const i: usize = @intCast(at / b.block_size);
            const block = b.mem[i].?;
            const within: usize = @intCast(at - @as(u64, i) * b.block_size);
            const n = @min(block.len - within, @as(usize, @intCast(offset + want.len - at)));
            @memcpy(want[@intCast(at - offset)..][0..n], block[within..][0..n]);
            at += n;
        }
        return want.len;
    }
    {
        win32.AcquireSRWLockShared(&b.file_lock);
        defer win32.ReleaseSRWLockShared(&b.file_lock);
        if (b.file) |file| {
            try readAllAt(b.base.io, file, offset, want);
            return want.len;
        }
    }
    // Complete meanwhile.
    if (try b.readDone(offset, want)) return want.len;
    return error.BlobMoved;
}

/// Reads from the store's blob, once there is one; false before.
fn readDone(b: *BlobReader, offset: u64, buffer: []u8) !bool {
    const io = b.base.io;
    win32.AcquireSRWLockShared(&b.file_lock);
    const path = b.done_path;
    win32.ReleaseSRWLockShared(&b.file_lock);
    if (path.len == 0) return false;
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    try readAllAt(io, file, offset, buffer);
    return true;
}

fn readAllAt(io: Io, file: Io.File, offset: u64, buffer: []u8) !void {
    var done: usize = 0;
    while (done < buffer.len) {
        const n = try file.readPositional(io, &.{buffer[done..]}, offset + done);
        if (n == 0) return error.EndOfStream;
        done += n;
    }
}

/// `ahead`: what nothing waits for yet, but a run is expected to read.
const Priority = enum { demand, ahead, background };

/// Asks for the blocks from `start` to `end` without waiting for them: what
/// a fetch of several chunks wants, so that they come in parallel.
pub fn prefetch(b: *BlobReader, start: u64, end: u64) void {
    if (b.blocks.len == 0) return;
    b.request(start, @min(end, b.tail_start), .demand) catch {};
}

/// Asks for the blocks from `start` to `end` ahead of any read of them:
/// behind what runs wait for, before the download, and counted apart
/// (`ahead_bytes`). A read that gets to one first has it moved up.
pub fn prefetchAhead(b: *BlobReader, start: u64, end: u64) void {
    if (b.blocks.len == 0) return;
    b.request(start, @min(end, b.tail_start), .ahead) catch {};
}

/// Waits until the blocks from `start` to `end` are in, asking for those
/// nobody has; fails if a fetch of one did.
pub fn ensure(b: *BlobReader, start: u64, end: u64) !void {
    if (b.blocks.len == 0) return;
    const last = @min(end, b.tail_start);
    if (start >= last) return;
    try b.request(start, last, .demand);
    _ = try b.waitFor(start, last, null);
}

/// As `ensure`, but waits at most `ms`: false if the blocks aren't all in
/// by then, when they're still on their way.
pub fn ensureFor(b: *BlobReader, start: u64, end: u64, ms: u32) !bool {
    if (b.blocks.len == 0) return true;
    const last = @min(end, b.tail_start);
    if (start >= last) return true;
    try b.request(start, last, .demand);
    return b.waitFor(start, last, win32.GetTickCount64() + ms);
}

/// How many of the bytes from `start` to `end` are in: those of had blocks,
/// and what's come so far of the requests now going.
pub fn received(b: *BlobReader, start: u64, end: u64) u64 {
    if (b.blocks.len == 0) return 0;
    const last = @min(end, b.tail_start);
    if (start >= last) return end - start;
    win32.AcquireSRWLockExclusive(&b.lock);
    defer win32.ReleaseSRWLockExclusive(&b.lock);
    if (b.done_path.len > 0) return end - start;
    var n: u64 = 0;
    const first: usize = @intCast(start / b.block_size);
    const stop_at: usize = @intCast(std.math.divCeil(u64, last, b.block_size) catch unreachable);
    for (b.blocks[first..stop_at], first..) |s, i| if (s == .have) {
        n += overlap(@as(u64, i) * b.block_size, b.blockEnd(i), start, last);
    };
    for (b.inflight) |*f| if (f.busy) {
        n += overlap(f.start, f.start + f.got.load(.monotonic), start, last);
    };
    return @min(n, last - start);
}

fn overlap(a: u64, a_end: u64, c: u64, c_end: u64) u64 {
    const lo = @max(a, c);
    const hi = @min(a_end, c_end);
    return if (hi > lo) hi - lo else 0;
}

fn request(b: *BlobReader, start: u64, end: u64, priority: Priority) !void {
    win32.AcquireSRWLockExclusive(&b.lock);
    defer win32.ReleaseSRWLockExclusive(&b.lock);
    if (b.done_path.len > 0 or start >= end) return;
    try b.requestLocked(start, end, priority);
    win32.WakeAllConditionVariable(&b.cond);
}

fn requestLocked(b: *BlobReader, start: u64, end: u64, priority: Priority) !void {
    const first: usize = @intCast(start / b.block_size);
    const last: usize = @intCast(std.math.divCeil(u64, @min(end, b.tail_start), b.block_size) catch unreachable);
    const max_blocks: usize = @intCast((if (priority == .background) background_piece else demand_piece) / b.block_size);
    const queued: State = switch (priority) {
        .demand => .queued_demand,
        .ahead => .queued_ahead,
        .background => .queued_background,
    };
    var i = first;
    while (i < last) {
        switch (b.blocks[i]) {
            .missing => {
                var j = i;
                while (j < last and j - i < max_blocks and b.blocks[j] == .missing) : (j += 1) {
                    b.blocks[j] = queued;
                }
                const piece: Piece = .{ .start = @as(u64, i) * b.block_size, .end = b.blockEnd(j - 1) };
                switch (priority) {
                    .demand => try b.demand.append(b.gpa, piece),
                    .ahead => try b.ahead.append(b.gpa, piece),
                    .background => {
                        try b.background.append(b.gpa, piece);
                        b.background_out += 1;
                    },
                }
                i = j;
            },
            .queued_background => {
                if (priority != .background) b.promote(i, priority);
                i += 1;
            },
            .queued_ahead => {
                if (priority == .demand) b.promote(i, .demand);
                i += 1;
            },
            else => i += 1,
        }
    }
}

/// Moves the queued piece with block `i`, the download's or one asked for
/// ahead, up: to the front of what runs wait for, or behind what else was
/// asked for ahead.
fn promote(b: *BlobReader, i: usize, to: Priority) void {
    const at = @as(u64, i) * b.block_size;
    const from_background = b.blocks[i] == .queued_background;
    const from = if (from_background) &b.background else &b.ahead;
    for (from.items, 0..) |p, k| {
        if (at < p.start or at >= p.end) continue;
        // No room: it stays where it is.
        if (to == .demand) {
            b.demand.insert(b.gpa, 0, p) catch return;
        } else {
            b.ahead.append(b.gpa, p) catch return;
        }
        _ = from.orderedRemove(k);
        if (from_background) b.background_out -= 1;
        var j: usize = @intCast(p.start / b.block_size);
        while (@as(u64, j) * b.block_size < p.end) : (j += 1) b.blocks[j] = if (to == .demand) .queued_demand else .queued_ahead;
        return;
    }
}

/// Waits until the blocks from `start` to `end` are in the file; fails if a
/// fetch of one of them did. With a `deadline` (GetTickCount64), false if
/// they aren't by then.
fn waitFor(b: *BlobReader, start: u64, end: u64, deadline: ?u64) !bool {
    const first: usize = @intCast(start / b.block_size);
    const last: usize = @intCast(std.math.divCeil(u64, @min(end, b.tail_start), b.block_size) catch unreachable);
    win32.AcquireSRWLockExclusive(&b.lock);
    defer win32.ReleaseSRWLockExclusive(&b.lock);
    while (true) {
        if (b.done_path.len > 0) return true;
        if (b.stopping) return error.Stopped;
        var ready = true;
        for (b.blocks[first..last]) |s| switch (s) {
            .have => {},
            .missing => return b.last_error orelse error.Failed,
            else => ready = false,
        };
        if (ready) return true;
        var ms: u32 = 1000;
        if (deadline) |d| {
            const now = win32.GetTickCount64();
            if (now >= d) return false;
            ms = @intCast(@min(d - now, 1000));
        }
        _ = win32.SleepConditionVariableSRW(&b.cond, &b.lock, ms, 0);
    }
}

// ---------------------------------------------------------------------------
// Copies from other blobs

/// Claims the blocks wholly within `start` to `end` that nobody has or has
/// asked for, for the caller to copy (`writeAt`) and `settle`: reads wait
/// for them meanwhile, and the download passes them over. Appends the runs
/// of blocks it claimed, as byte ranges, to `out`.
pub fn claim(b: *BlobReader, start: u64, end: u64, out: *std.ArrayList(Piece)) !void {
    if (b.blocks.len == 0) return;
    const last_byte = @min(end, b.tail_start);
    const first: usize = @intCast(std.math.divCeil(u64, start, b.block_size) catch unreachable);
    // The last block, short, ends at the tail: wholly within if `end` does.
    const last: usize = if (last_byte == b.tail_start) b.blocks.len else @intCast(last_byte / b.block_size);
    if (first >= last) return;
    win32.AcquireSRWLockExclusive(&b.lock);
    defer win32.ReleaseSRWLockExclusive(&b.lock);
    var i = first;
    while (i < last) {
        if (b.blocks[i] != .missing) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < last and b.blocks[j] == .missing) : (j += 1) b.blocks[j] = .copying;
        try out.append(b.gpa, .{ .start = @as(u64, i) * b.block_size, .end = b.blockEnd(j - 1) });
        i = j;
    }
}

/// Writes bytes copied from another blob into the file, at `offset`.
pub fn writeAt(b: *BlobReader, offset: u64, bytes: []const u8) !void {
    win32.AcquireSRWLockShared(&b.file_lock);
    defer win32.ReleaseSRWLockShared(&b.file_lock);
    const file = b.file orelse return error.Stopped;
    try file.writePositionalAll(b.base.io, bytes, offset);
    _ = b.copied.fetchAdd(bytes.len, .monotonic);
}

/// Ends a claim on the blocks from `start` to `end`, a run `claim` gave or a
/// part of one, from a block's start: had, once `writeAt` has written them,
/// or, if the copy failed, asked for as a read would, so that whoever waits
/// gets them.
pub fn settle(b: *BlobReader, start: u64, end: u64, ok: bool) void {
    if (b.blocks.len == 0) return;
    win32.AcquireSRWLockExclusive(&b.lock);
    defer win32.ReleaseSRWLockExclusive(&b.lock);
    defer win32.WakeAllConditionVariable(&b.cond);
    const first: usize = @intCast(start / b.block_size);
    const last: usize = @intCast(std.math.divCeil(u64, @min(end, b.tail_start), b.block_size) catch unreachable);
    if (first >= last) return;
    for (first..last) |i| if (b.blocks[i] == .copying) {
        if (ok) {
            b.blocks[i] = .have;
            b.have_blocks += 1;
            b.have_bytes += b.blockLen(i);
        } else {
            b.blocks[i] = .missing;
        }
    };
    if (ok) {
        b.writeMap();
    } else {
        b.requestLocked(@as(u64, first) * b.block_size, b.blockEnd(last - 1), .demand) catch {};
    }
}

/// Marks the blocks from `start` to `end` missing: what's in the file there
/// failed its TOC digest (a write cut short), so the next read fetches it.
pub fn invalidate(b: *BlobReader, start: u64, end: u64) void {
    if (b.blocks.len == 0) return;
    const first: usize = @intCast(start / b.block_size);
    const last: usize = @intCast(std.math.divCeil(u64, @min(end, b.tail_start), b.block_size) catch unreachable);
    win32.AcquireSRWLockExclusive(&b.lock);
    defer win32.ReleaseSRWLockExclusive(&b.lock);
    for (b.blocks[first..last], first..) |*s, i| if (s.* == .have) {
        s.* = .missing;
        b.have_blocks -= 1;
        b.have_bytes -= b.blockLen(i);
    };
    b.writeMap();
}

// ---------------------------------------------------------------------------
// The threads that fetch

fn work(b: *BlobReader, slot: *Inflight) void {
    const buf = b.gpa.alloc(u8, @intCast(@max(demand_piece, background_piece))) catch return;
    defer b.gpa.free(buf);
    win32.AcquireSRWLockExclusive(&b.lock);
    defer win32.ReleaseSRWLockExclusive(&b.lock);
    while (!b.stopping) {
        var piece: Piece = undefined;
        var kind: Priority = .demand;
        // A run's fetches have the network to themselves: the download
        // starts nothing while one is queued or going, or for a second after,
        // as a run's next is often right behind.
        const quiet = b.demand_busy == 0 and win32.GetTickCount64() -% b.demand_done_at >= quiet_ms;
        // One thread is always left for what a run waits for.
        const spare = b.background_busy + b.ahead_busy + 1 < @max(b.workers.len, 2);
        if (b.demand.items.len > 0) {
            piece = b.demand.orderedRemove(0);
            b.demand_busy += 1;
        } else if (spare and b.ahead.items.len > 0) {
            // Beside a run's fetches, not after them: it's what the run is
            // expected to ask for next.
            piece = b.ahead.orderedRemove(0);
            kind = .ahead;
            b.ahead_busy += 1;
        } else if (quiet and spare and b.ahead_busy == 0 and b.background.items.len > 0) {
            piece = b.background.orderedRemove(0);
            kind = .background;
            b.background_busy += 1;
        } else {
            _ = win32.SleepConditionVariableSRW(&b.cond, &b.lock, if (quiet) 1000 else 100, 0);
            continue;
        }
        b.mark(piece, .fetching);
        slot.* = .{ .busy = true, .start = piece.start, .end = piece.end };
        win32.ReleaseSRWLockExclusive(&b.lock);
        const len: usize = @intCast(piece.end - piece.start);
        const result = b.fetchInto(piece.start, buf[0..len], &slot.got);
        win32.AcquireSRWLockExclusive(&b.lock);
        slot.busy = false;
        switch (kind) {
            .background => {
                b.background_busy -= 1;
                b.background_out -= 1;
            },
            .ahead => b.ahead_busy -= 1,
            .demand => {
                b.demand_busy -= 1;
                b.demand_done_at = win32.GetTickCount64();
            },
        }
        if (result) |_| {
            b.mark(piece, .have);
            const counter = switch (kind) {
                .background => &b.downloaded,
                .ahead => &b.ahead_bytes,
                .demand => &b.on_demand,
            };
            _ = counter.fetchAdd(len, .monotonic);
            b.writeMap();
        } else |err| {
            b.mark(piece, .missing);
            b.last_error = err;
            if (kind == .background) b.background_failed = err;
        }
        win32.WakeAllConditionVariable(&b.cond);
    }
}

/// Sets a piece's blocks' state, with the lock held, and counts what's had.
fn mark(b: *BlobReader, piece: Piece, state: State) void {
    var i: usize = @intCast(piece.start / b.block_size);
    while (@as(u64, i) * b.block_size < piece.end) : (i += 1) {
        if (b.blocks[i] == .have and state != .have) {
            b.have_blocks -= 1;
            b.have_bytes -= b.blockLen(i);
        } else if (b.blocks[i] != .have and state == .have) {
            b.have_blocks += 1;
            b.have_bytes += b.blockLen(i);
        }
        b.blocks[i] = state;
    }
}

/// Fetches a piece and writes it into the file.
fn fetchInto(b: *BlobReader, offset: u64, buffer: []u8, got: *std.atomic.Value(u64)) !void {
    try b.fetchRange(offset, buffer, got);
    if (b.mem.len > 0) {
        // A piece is whole blocks, from one's start.
        var at: usize = 0;
        var i: usize = @intCast(offset / b.block_size);
        while (at < buffer.len) : (i += 1) {
            const n: usize = @intCast(b.blockLen(i));
            const block = try b.gpa.dupe(u8, buffer[at..][0..n]);
            win32.AcquireSRWLockExclusive(&b.lock);
            if (b.mem[i]) |old| b.gpa.free(old);
            b.mem[i] = block;
            win32.ReleaseSRWLockExclusive(&b.lock);
            at += n;
        }
        return;
    }
    win32.AcquireSRWLockShared(&b.file_lock);
    defer win32.ReleaseSRWLockShared(&b.file_lock);
    const file = b.file orelse return error.Stopped;
    try file.writePositionalAll(b.base.io, buffer, offset);
}

/// Fetches `buffer.len` bytes of the blob from `offset` from the registry,
/// counting in `got` what's come so far.
fn fetchRange(b: *BlobReader, offset: u64, buffer: []u8, got: ?*std.atomic.Value(u64)) !void {
    _ = b.requests.fetchAdd(1, .monotonic);
    if (b.wait_ms > 0) win32.Sleep(b.wait_ms);
    var w: Io.Writer = .fixed(buffer);
    // Unbuffered, so that it counts each write as it comes.
    var counted = w.hashed(Counter{ .got = got, .throttle = b.throttle }, &.{});
    if (b.test_fetch) |f| {
        try f(b, offset, buffer.len, &counted.writer);
    } else {
        const c = try b.acquire();
        defer b.release(c);
        const found = c.registry.getBlob(b.digest, .{ .start = offset, .end = offset + buffer.len }, &counted.writer) catch |err| {
            // A client that failed may be in any state: the next one starts afresh.
            c.uses = Client.max_uses;
            return err;
        };
        if (!found) return error.BlobNotFound;
    }
    try counted.writer.flush();
    if (w.end != buffer.len) return error.EndOfStream;
}

/// What `fetchRange`'s writer tells of each write: counts it, and, for the
/// tests' throttle, takes as long as it would at that rate.
const Counter = struct {
    got: ?*std.atomic.Value(u64),
    throttle: u64,

    pub fn update(c: *Counter, bytes: []const u8) void {
        if (c.got) |g| _ = g.fetchAdd(bytes.len, .monotonic);
        if (c.throttle > 0) win32.Sleep(@intCast(bytes.len * 1000 / c.throttle));
    }
};

fn acquire(b: *BlobReader) !*Client {
    win32.AcquireSRWLockExclusive(&b.lock);
    const c: *Client = found: while (true) {
        if (b.free_clients > 0) {
            for (b.clients) |*free| if (!free.busy) {
                free.busy = true;
                b.free_clients -= 1;
                break :found free;
            };
        }
        _ = win32.SleepConditionVariableSRW(&b.cond, &b.lock, 1000, 0);
    };
    win32.ReleaseSRWLockExclusive(&b.lock);
    if (!c.ready) {
        c.arena = .init(b.gpa);
        c.ctx = b.base.*;
        c.ctx.arena = c.arena.allocator();
        c.registry.init(&c.ctx, b.ref, "pull") catch |err| {
            c.arena.deinit();
            b.giveBack(c);
            return err;
        };
        c.ready = true;
        c.uses = 0;
    }
    return c;
}

fn release(b: *BlobReader, c: *Client) void {
    c.uses += 1;
    if (c.uses >= Client.max_uses) {
        c.registry.deinit();
        c.arena.deinit();
        c.ready = false;
    }
    b.giveBack(c);
}

fn giveBack(b: *BlobReader, c: *Client) void {
    win32.AcquireSRWLockExclusive(&b.lock);
    c.busy = false;
    b.free_clients += 1;
    win32.ReleaseSRWLockExclusive(&b.lock);
    win32.WakeAllConditionVariable(&b.cond);
}

// ---------------------------------------------------------------------------
// The download

/// Whether the download is to wait a while: tests' gate.
pub const Hold = struct {
    context: *anyopaque,
    holdFn: *const fn (context: *anyopaque) bool,
};

/// Fetches every block the file hasn't, in order, a few pieces at a time,
/// behind what runs ask for. Returns once the file has them all; fails with
/// why a piece of its failed, or error.Stopped.
pub fn downloadAll(b: *BlobReader, hold: ?Hold) !void {
    const n = b.blocks.len;
    const window: usize = @intCast(background_piece / b.block_size);
    // Enough queued that the threads it may use never wait for it.
    const max_out = b.workers.len * 2;
    var cursor: usize = 0;
    // Held even when reads have fetched it all: tests' gate is on the
    // download's end too, the swap's start.
    if (hold) |h| while (h.holdFn(h.context)) win32.Sleep(100);
    win32.AcquireSRWLockExclusive(&b.lock);
    defer win32.ReleaseSRWLockExclusive(&b.lock);
    b.background_failed = null;
    while (b.have_blocks < n) {
        if (b.stopping) return error.Stopped;
        if (b.background_failed) |err| {
            b.background_failed = null;
            return err;
        }
        const next = if (b.background_out < max_out) b.nextMissing(cursor) else null;
        const i = next orelse {
            _ = win32.SleepConditionVariableSRW(&b.cond, &b.lock, 1000, 0);
            continue;
        };
        try b.requestLocked(@as(u64, i) * b.block_size, b.blockEnd(@min(i + window, n) - 1), .background);
        win32.WakeAllConditionVariable(&b.cond);
        cursor = i + window;
    }
}

/// The first missing block from `cursor`, then from the start.
fn nextMissing(b: *const BlobReader, cursor: usize) ?usize {
    const n = b.blocks.len;
    for (0..n) |k| {
        const i = (@min(cursor, n) + k) % n;
        if (b.blocks[i] == .missing) return i;
    }
    return null;
}

/// The file's sha-256, once it has every block.
pub fn hashFile(b: *BlobReader) ![64]u8 {
    const io = b.base.io;
    const buf = try b.gpa.alloc(u8, 8 << 20);
    defer b.gpa.free(buf);
    win32.AcquireSRWLockShared(&b.file_lock);
    defer win32.ReleaseSRWLockShared(&b.file_lock);
    const file = b.file orelse return error.Stopped;
    var hasher = Sha256.init(.{});
    var pos: u64 = 0;
    while (pos < b.size) {
        const want: usize = @intCast(@min(buf.len, b.size - pos));
        try readAllAt(io, file, pos, buf[0..want]);
        hasher.update(buf[0..want]);
        pos += want;
    }
    return std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

/// Starts again from nothing: the file's blocks didn't make the blob.
pub fn reset(b: *BlobReader) !void {
    win32.AcquireSRWLockExclusive(&b.lock);
    defer win32.ReleaseSRWLockExclusive(&b.lock);
    for (b.blocks) |*s| if (s.* == .have) {
        s.* = .missing;
    };
    b.have_blocks = 0;
    b.have_bytes = 0;
    b.writeMap();
}

/// Moves the complete file to `dest`, the store's blob, unless it's there
/// already, and reads from there on. The file stops being sparse first:
/// nothing in it is unwritten.
pub fn finish(b: *BlobReader, dest: []const u8) !void {
    const io = b.base.io;
    win32.AcquireSRWLockExclusive(&b.file_lock);
    defer win32.ReleaseSRWLockExclusive(&b.file_lock);
    if (b.file) |f| {
        setSparse(f, false) catch {};
        f.close(io);
        b.file = null;
    }
    if (b.map) |m| m.close(io);
    b.map = null;
    if (try exists(io, dest)) {
        try Io.Dir.cwd().deleteFile(io, b.data_path);
    } else {
        try Io.Dir.rename(.cwd(), b.data_path, .cwd(), dest, io);
    }
    Io.Dir.cwd().deleteFile(io, b.map_path) catch {};
    win32.AcquireSRWLockExclusive(&b.lock);
    b.done_path = dest;
    win32.ReleaseSRWLockExclusive(&b.lock);
    win32.WakeAllConditionVariable(&b.cond);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// A blob of `size` bytes, each its offset's low byte, served by a fetch
/// that counts what it's asked for.
const Fake = struct {
    var calls: std.atomic.Value(u32) = .init(0);
    var fetched: std.atomic.Value(u64) = .init(0);
    var fail_at: ?u64 = null;

    fn fetch(b: *BlobReader, offset: u64, len: usize, w: *Io.Writer) anyerror!void {
        _ = b;
        _ = calls.fetchAdd(1, .monotonic);
        _ = fetched.fetchAdd(len, .monotonic);
        if (fail_at) |at| if (at >= offset and at < offset + len) return error.TestFailure;
        win32.Sleep(5);
        try writePattern(w, offset, len);
    }

    /// Each byte its offset's low one.
    fn writePattern(w: *Io.Writer, offset: u64, len: usize) !void {
        var buf: [4096]u8 = undefined;
        var done: usize = 0;
        while (done < len) {
            const n = @min(buf.len, len - done);
            for (buf[0..n], 0..) |*x, i| x.* = @truncate(offset + done + i);
            try w.writeAll(buf[0..n]);
            done += n;
        }
    }

    fn reset() void {
        calls.store(0, .monotonic);
        fetched.store(0, .monotonic);
        fail_at = null;
    }
};

fn testReader(ctx: *Context, tail: []const u8, size: u64, dir: []const u8) !*BlobReader {
    return testReaderOf(ctx, tail, size, dir, .{}, Fake.fetch);
}

fn testReaderOf(
    ctx: *Context,
    tail: []const u8,
    size: u64,
    dir: []const u8,
    options: Options,
    fetch: *const fn (b: *BlobReader, offset: u64, len: usize, w: *Io.Writer) anyerror!void,
) !*BlobReader {
    const b = try BlobReader.init(testing.allocator, ctx, .{ .host = "test", .repository = "test" }, "sha256:00", size, tail, options);
    b.test_fetch = fetch;
    const data = try std.fs.path.join(testing.allocator, &.{ dir, "blob.sparse" });
    defer testing.allocator.free(data);
    const map = try std.fs.path.join(testing.allocator, &.{ dir, "have" });
    defer testing.allocator.free(map);
    // attach keeps the paths: they live in the test's arena.
    _ = try b.attach(try ctx.arena.dupe(u8, data), try ctx.arena.dupe(u8, map), null);
    return b;
}

fn testContext(arena: Allocator) Context {
    return .{ .io = testing.io, .gpa = testing.allocator, .arena = arena, .env = undefined, .store = undefined };
}

fn tmpPath(arena: Allocator, tmp: *testing.TmpDir) ![]const u8 {
    return std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });
}

test "reads ask for each block once, however many threads read it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ctx = testContext(arena.allocator());
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    Fake.reset();
    const size: u64 = 10 << 20;
    var tail: [100]u8 = undefined;
    for (&tail, 0..) |*x, i| x.* = @truncate(size - tail.len + i);
    const b = try testReader(&ctx, &tail, size, try tmpPath(arena.allocator(), &tmp));
    defer b.deinit();

    const Reader = struct {
        fn run(r: *BlobReader, offset: u64, ok: *bool) void {
            var buf: [3 << 20]u8 = undefined;
            r.source().readAll(offset, &buf) catch return;
            for (buf, 0..) |x, i| if (x != @as(u8, @truncate(offset + i))) return;
            ok.* = true;
        }
    };
    var oks: [4]bool = @splat(false);
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Reader.run, .{ b, 1 << 20, &oks[i] });
    for (threads) |t| t.join();
    for (oks) |ok| try testing.expect(ok);
    // Blocks 1 to 3, each once, in one request: four readers, the same span.
    try testing.expectEqual(@as(u64, 3 << 20), Fake.fetched.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), Fake.calls.load(.monotonic));

    // The tail comes from memory, and the file has it.
    var end: [100]u8 = undefined;
    try b.source().readAll(size - 100, &end);
    try testing.expectEqualSlices(u8, &tail, &end);
}

test "the download fetches only what reads didn't, and the file is the blob" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ctx = testContext(arena.allocator());
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    Fake.reset();
    const size: u64 = (20 << 20) + 12345;
    var tail: [4096]u8 = undefined;
    for (&tail, 0..) |*x, i| x.* = @truncate(size - tail.len + i);
    const b = try testReader(&ctx, &tail, size, try tmpPath(arena.allocator(), &tmp));
    defer b.deinit();

    var buf: [100]u8 = undefined;
    try b.source().readAll(5 << 20, &buf);
    try b.downloadAll(null);
    // Twenty-one blocks, the last short of the tail; the read's block once.
    try testing.expectEqual(size - tail.len, Fake.fetched.load(.monotonic));
    try testing.expectEqual(size, b.haveBytes());

    // Each byte its offset's low one: the same 256 bytes over and over.
    var pattern: [256]u8 = undefined;
    for (&pattern, 0..) |*x, i| x.* = @intCast(i);
    var expected = Sha256.init(.{});
    var pos: u64 = 0;
    while (pos < size) {
        const n: usize = @intCast(@min(256, size - pos));
        expected.update(pattern[0..n]);
        pos += n;
    }
    const want = std.fmt.bytesToHex(expected.finalResult(), .lower);
    try testing.expectEqualStrings(&want, &(try b.hashFile()));
}

test "a failed fetch fails its readers, and the next read asks again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ctx = testContext(arena.allocator());
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    Fake.reset();
    const b = try testReader(&ctx, "tail", 4 << 20, try tmpPath(arena.allocator(), &tmp));
    defer b.deinit();

    var buf: [10]u8 = undefined;
    Fake.fail_at = 2 << 20;
    try testing.expectError(error.TestFailure, b.source().readAll(2 << 20, &buf));
    Fake.fail_at = null;
    try b.source().readAll(2 << 20, &buf);
    try testing.expectEqual(@as(u8, 0), buf[0]);
    try testing.expectEqual(@as(u32, 2), Fake.calls.load(.monotonic));
}

test "a second reader goes on from the map, and an invalidated block is fetched again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ctx = testContext(arena.allocator());
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    Fake.reset();
    const dir = try tmpPath(arena.allocator(), &tmp);
    const size: u64 = 8 << 20;
    {
        const b = try testReader(&ctx, "tail", size, dir);
        defer b.deinit();
        var buf: [10]u8 = undefined;
        try b.source().readAll(3 << 20, &buf);
        try b.source().readAll(6 << 20, &buf);
    }
    Fake.reset();
    const b = try testReader(&ctx, "tail", size, dir);
    defer b.deinit();
    try testing.expectEqual(@as(u64, 2 << 20), b.earlier);
    var buf: [10]u8 = undefined;
    try b.source().readAll(3 << 20, &buf);
    try testing.expectEqual(@as(u32, 0), Fake.calls.load(.monotonic));
    b.invalidate(3 << 20, (3 << 20) + 10);
    try b.source().readAll(3 << 20, &buf);
    try testing.expectEqual(@as(u32, 1), Fake.calls.load(.monotonic));
    try testing.expectEqual(@as(u8, 0), buf[0]);
}

test "a map of another blob says nothing is had" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ctx = testContext(arena.allocator());
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    Fake.reset();
    const dir = try tmpPath(arena.allocator(), &tmp);
    {
        const b = try testReader(&ctx, "tail", 8 << 20, dir);
        defer b.deinit();
        var buf: [10]u8 = undefined;
        try b.source().readAll(0, &buf);
    }
    const b = try testReader(&ctx, "tail", 9 << 20, dir);
    defer b.deinit();
    try testing.expectEqual(@as(u64, 0), b.earlier);
}

/// The pattern's bytes from `offset`, as a copy from another blob would
/// have them.
fn testCopy(b: *BlobReader, start: u64, end: u64) !void {
    const bytes = try testing.allocator.alloc(u8, @intCast(end - start));
    defer testing.allocator.free(bytes);
    for (bytes, 0..) |*x, i| x.* = @truncate(start + i);
    try b.writeAt(start, bytes);
}

test "claimed blocks wait for their copy, and the download fetches only the rest" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ctx = testContext(arena.allocator());
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    Fake.reset();
    const dir = try tmpPath(arena.allocator(), &tmp);
    const size: u64 = 8 << 20;
    {
        const b = try testReaderOf(&ctx, "tail", size, dir, .{ .block_size = copy_block_size }, Fake.fetch);
        defer b.deinit();
        var runs: std.ArrayList(Piece) = .empty;
        defer runs.deinit(testing.allocator);
        // Its whole blocks only: from the next 64 KiB on.
        try b.claim((1 << 20) + 100, 5 << 20, &runs);
        try testing.expectEqual(@as(usize, 1), runs.items.len);
        try testing.expectEqual(@as(u64, (1 << 20) + (64 << 10)), runs.items[0].start);
        try testing.expectEqual(@as(u64, 5 << 20), runs.items[0].end);

        const Reader = struct {
            fn run(r: *BlobReader, ok: *bool) void {
                var buf: [10]u8 = undefined;
                r.source().readAll(2 << 20, &buf) catch return;
                for (buf, 0..) |x, i| if (x != @as(u8, @truncate((2 << 20) + i))) return;
                ok.* = true;
            }
        };
        var ok = false;
        const t = try std.Thread.spawn(.{}, Reader.run, .{ b, &ok });
        win32.Sleep(100);
        // It waits for the copy, and nothing is fetched for it.
        try testing.expect(!ok);
        try testCopy(b, runs.items[0].start, runs.items[0].end);
        b.settle(runs.items[0].start, runs.items[0].end, true);
        t.join();
        try testing.expect(ok);
        try testing.expectEqual(@as(u32, 0), Fake.calls.load(.monotonic));

        try b.downloadAll(null);
        try testing.expectEqual(size - 4 - (runs.items[0].end - runs.items[0].start), Fake.fetched.load(.monotonic));
        var buf: [100]u8 = undefined;
        try b.source().readAll(3 << 20, &buf);
        for (buf, 0..) |x, i| try testing.expectEqual(@as(u8, @truncate((3 << 20) + i)), x);
    }
    // A helper started again keeps the map's blocks, whatever it asks for.
    const b = try testReader(&ctx, "tail", size, dir);
    defer b.deinit();
    try testing.expectEqual(copy_block_size, b.block_size);
    try testing.expectEqual(size - 4, b.earlier);
}

test "a copy that fails is fetched, for whoever waits for it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ctx = testContext(arena.allocator());
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    Fake.reset();
    const b = try testReaderOf(&ctx, "tail", 4 << 20, try tmpPath(arena.allocator(), &tmp), .{ .block_size = copy_block_size }, Fake.fetch);
    defer b.deinit();
    var runs: std.ArrayList(Piece) = .empty;
    defer runs.deinit(testing.allocator);
    try b.claim(0, 2 << 20, &runs);
    const Reader = struct {
        fn run(r: *BlobReader, ok: *bool) void {
            var buf: [10]u8 = undefined;
            r.source().readAll(1 << 20, &buf) catch return;
            if (buf[0] != 0) return;
            ok.* = true;
        }
    };
    var ok = false;
    const t = try std.Thread.spawn(.{}, Reader.run, .{ b, &ok });
    win32.Sleep(100);
    b.settle(0, 2 << 20, false);
    t.join();
    try testing.expect(ok);
    try testing.expect(Fake.calls.load(.monotonic) >= 1);
}

/// A fetch that writes half its bytes, then waits until `go`.
const Halting = struct {
    var halfway: std.atomic.Value(bool) = .init(false);
    var go: std.atomic.Value(bool) = .init(false);

    fn fetch(b: *BlobReader, offset: u64, len: usize, w: *Io.Writer) anyerror!void {
        _ = b;
        try Fake.writePattern(w, offset, len / 2);
        halfway.store(true, .release);
        while (!go.load(.acquire)) win32.Sleep(5);
        try Fake.writePattern(w, offset + len / 2, len - len / 2);
    }
};

test "received counts what's come of a fetch while it comes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ctx = testContext(arena.allocator());
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    Halting.halfway.store(false, .monotonic);
    Halting.go.store(false, .monotonic);
    const b = try testReaderOf(&ctx, "tail", 4 << 20, try tmpPath(arena.allocator(), &tmp), .{}, Halting.fetch);
    defer b.deinit();
    try testing.expectEqual(@as(u64, 0), b.received(0, 1 << 20));
    // Not in within 50 ms: it's waiting for the rest.
    try testing.expect(!try b.ensureFor(0, 1 << 20, 50));
    while (!Halting.halfway.load(.acquire)) win32.Sleep(5);
    try testing.expectEqual(@as(u64, 512 << 10), b.received(0, 1 << 20));
    Halting.go.store(true, .release);
    try testing.expect(try b.ensureFor(0, 1 << 20, 10_000));
    try testing.expectEqual(@as(u64, 1 << 20), b.received(0, 1 << 20));
}

/// A fetch that says what it was asked for, in the order it was, and waits
/// for `go`.
const Gated = struct {
    var lock: win32.SRWLOCK = .{};
    var order: [64]u64 = undefined;
    var count: usize = 0;
    var go: std.atomic.Value(bool) = .init(false);

    fn fetch(b: *BlobReader, offset: u64, len: usize, w: *Io.Writer) anyerror!void {
        _ = b;
        win32.AcquireSRWLockExclusive(&lock);
        if (count < order.len) order[count] = offset;
        count += 1;
        win32.ReleaseSRWLockExclusive(&lock);
        while (!go.load(.acquire)) win32.Sleep(2);
        try Fake.writePattern(w, offset, len);
    }

    fn started() usize {
        win32.AcquireSRWLockExclusive(&lock);
        defer win32.ReleaseSRWLockExclusive(&lock);
        return count;
    }

    /// Which request, from 0, was the one for the piece at `offset`.
    fn position(offset: u64) ?usize {
        win32.AcquireSRWLockExclusive(&lock);
        defer win32.ReleaseSRWLockExclusive(&lock);
        for (order[0..@min(count, order.len)], 0..) |o, i| if (o == offset) return i;
        return null;
    }
};

test "what's asked for ahead comes beside a read and before the download, and a read moves it up" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ctx = testContext(arena.allocator());
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    Gated.count = 0;
    Gated.go.store(false, .monotonic);
    const size: u64 = 48 << 20;
    const b = try testReaderOf(&ctx, "tail", size, try tmpPath(arena.allocator(), &tmp), .{}, Gated.fetch);
    defer b.deinit();
    // Whatever fails below, the threads end.
    defer Gated.go.store(true, .release);

    const Reader = struct {
        fn run(r: *BlobReader, offset: u64, ok: *bool) void {
            var buf: [10]u8 = undefined;
            r.source().readAll(offset, &buf) catch return;
            ok.* = buf[0] == @as(u8, @truncate(offset));
        }
    };
    // Six pieces of 4 MiB, then a read elsewhere: three threads have a piece
    // asked for ahead each, and the fourth, kept for reads, the read's.
    b.prefetchAhead(8 << 20, 32 << 20);
    var ok1 = false;
    const t1 = try std.Thread.spawn(.{}, Reader.run, .{ b, 40 << 20, &ok1 });
    while (Gated.started() < 4) win32.Sleep(2);
    win32.Sleep(50);
    try testing.expectEqual(@as(usize, 4), Gated.started());
    try testing.expect(Gated.position(40 << 20) != null);
    for ([_]u64{ 8, 12, 16 }) |mib| try testing.expect(Gated.position(mib << 20) != null);

    // A read of the last piece asked for ahead: it's the next to go.
    var ok2 = false;
    const t2 = try std.Thread.spawn(.{}, Reader.run, .{ b, 28 << 20, &ok2 });
    while (true) {
        win32.AcquireSRWLockExclusive(&b.lock);
        const waiting = b.demand.items.len;
        win32.ReleaseSRWLockExclusive(&b.lock);
        if (waiting == 1) break;
        win32.Sleep(2);
    }
    Gated.go.store(true, .release);
    t1.join();
    t2.join();
    try testing.expect(ok1 and ok2);
    try testing.expectEqual(@as(?usize, 4), Gated.position(28 << 20));

    try b.downloadAll(null);
    // The download's first piece went after the last one asked for ahead.
    try testing.expect(Gated.position(0).? > Gated.position(24 << 20).?);
    try testing.expectEqual(size, b.haveBytes());
    // Five pieces ahead; the read's block and the piece a read moved up.
    try testing.expectEqual(@as(u64, 20 << 20), b.ahead_bytes.load(.monotonic));
    try testing.expectEqual(@as(u64, 5 << 20), b.on_demand.load(.monotonic));
    try testing.expectEqual(size - 4 - (25 << 20), b.downloaded.load(.monotonic));
}
