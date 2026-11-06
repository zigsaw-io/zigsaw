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
//! the download's, which never takes the last thread. It then waits for its
//! blocks and reads them from the file. Once the blob is complete (`finish`),
//! reads come from the store's blob.
//!
//! The pull's own (`attachMemory`), which reads its programs' headers, keeps
//! the blocks in memory instead, and asks for all the headers at once. With
//! neither, a read is one Range request for its span.
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
background: std.ArrayList(Piece) = .empty,
/// The download's pieces queued, and those being fetched.
background_out: usize = 0,
background_busy: usize = 0,
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

/// Requests sent; bytes fetched for reads and for the download; bytes an
/// earlier helper had fetched.
requests: std.atomic.Value(u64) = .init(0),
on_demand: std.atomic.Value(u64) = .init(0),
downloaded: std.atomic.Value(u64) = .init(0),
earlier: u64 = 0,
/// Tests' fetch, in place of the registry's.
test_fetch: ?*const fn (b: *BlobReader, offset: u64, buffer: []u8) anyerror!void = null,

/// The most a run's request asks for at once: a chunk of 4 MiB fits, and
/// the download's pieces queue behind it.
pub const demand_piece: u64 = 4 << 20;
/// The download's requests: big enough that latency is little of their time,
/// small enough that what a run asks for next isn't long behind one.
pub const background_piece: u64 = 8 << 20;
/// How long after a run's last fetch the download waits to go on.
const quiet_ms = 1000;

const State = enum(u8) { missing, queued_background, queued_demand, fetching, have };

const Piece = struct { start: u64, end: u64 };

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
};

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
    b.demand.deinit(b.gpa);
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

    b.workers = try b.gpa.alloc(std.Thread, b.clients.len);
    var started: usize = 0;
    errdefer {
        b.stop();
        for (b.workers[0..started]) |t| t.join();
        b.gpa.free(b.workers);
        b.workers = &.{};
    }
    for (b.workers) |*t| {
        t.* = try std.Thread.spawn(.{}, work, .{b});
        started += 1;
    }
    return b.have_bytes;
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
    b.workers = try b.gpa.alloc(std.Thread, b.clients.len);
    var started: usize = 0;
    errdefer {
        b.stop();
        for (b.workers[0..started]) |t| t.join();
        b.gpa.free(b.workers);
        b.workers = &.{};
    }
    for (b.workers) |*t| {
        t.* = try std.Thread.spawn(.{}, work, .{b});
        started += 1;
    }
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
        try b.fetchRange(offset, want);
        _ = b.on_demand.fetchAdd(want.len, .monotonic);
        return want.len;
    }
    try b.request(offset, offset + want.len, .demand);
    try b.waitFor(offset, offset + want.len);
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

const Priority = enum { demand, background };

/// Asks for the blocks from `start` to `end` without waiting for them: what
/// a fetch of several chunks wants, so that they come in parallel.
pub fn prefetch(b: *BlobReader, start: u64, end: u64) void {
    if (b.blocks.len == 0) return;
    b.request(start, @min(end, b.tail_start), .demand) catch {};
}

/// Waits until the blocks from `start` to `end` are in, asking for those
/// nobody has; fails if a fetch of one did.
pub fn ensure(b: *BlobReader, start: u64, end: u64) !void {
    if (b.blocks.len == 0) return;
    const last = @min(end, b.tail_start);
    if (start >= last) return;
    try b.request(start, last, .demand);
    try b.waitFor(start, last);
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
    const max_blocks: usize = @intCast((if (priority == .demand) demand_piece else background_piece) / b.block_size);
    var i = first;
    while (i < last) {
        switch (b.blocks[i]) {
            .missing => {
                var j = i;
                while (j < last and j - i < max_blocks and b.blocks[j] == .missing) : (j += 1) {
                    b.blocks[j] = if (priority == .demand) .queued_demand else .queued_background;
                }
                const piece: Piece = .{ .start = @as(u64, i) * b.block_size, .end = b.blockEnd(j - 1) };
                switch (priority) {
                    .demand => try b.demand.append(b.gpa, piece),
                    .background => {
                        try b.background.append(b.gpa, piece);
                        b.background_out += 1;
                    },
                }
                i = j;
            },
            .queued_background => {
                if (priority == .demand) b.promote(i);
                i += 1;
            },
            else => i += 1,
        }
    }
}

/// Moves the download's queued piece with block `i` to the front of what
/// runs wait for.
fn promote(b: *BlobReader, i: usize) void {
    const at = @as(u64, i) * b.block_size;
    for (b.background.items, 0..) |p, k| {
        if (at < p.start or at >= p.end) continue;
        _ = b.background.orderedRemove(k);
        b.background_out -= 1;
        b.demand.insert(b.gpa, 0, p) catch {
            // No room: it stays the download's.
            b.background.insert(b.gpa, k, p) catch unreachable;
            b.background_out += 1;
            return;
        };
        var j: usize = @intCast(p.start / b.block_size);
        while (@as(u64, j) * b.block_size < p.end) : (j += 1) b.blocks[j] = .queued_demand;
        return;
    }
}

/// Waits until the blocks from `start` to `end` are in the file; fails if a
/// fetch of one of them did.
fn waitFor(b: *BlobReader, start: u64, end: u64) !void {
    const first: usize = @intCast(start / b.block_size);
    const last: usize = @intCast(std.math.divCeil(u64, @min(end, b.tail_start), b.block_size) catch unreachable);
    win32.AcquireSRWLockExclusive(&b.lock);
    defer win32.ReleaseSRWLockExclusive(&b.lock);
    while (true) {
        if (b.done_path.len > 0) return;
        if (b.stopping) return error.Stopped;
        var ready = true;
        for (b.blocks[first..last]) |s| switch (s) {
            .have => {},
            .missing => return b.last_error orelse error.Failed,
            else => ready = false,
        };
        if (ready) return;
        _ = win32.SleepConditionVariableSRW(&b.cond, &b.lock, 1000, 0);
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

fn work(b: *BlobReader) void {
    const buf = b.gpa.alloc(u8, @intCast(@max(demand_piece, background_piece))) catch return;
    defer b.gpa.free(buf);
    win32.AcquireSRWLockExclusive(&b.lock);
    defer win32.ReleaseSRWLockExclusive(&b.lock);
    while (!b.stopping) {
        var piece: Piece = undefined;
        var background = false;
        // A run's fetches have the network to themselves: the download
        // starts nothing while one is queued or going, or for a second after,
        // as a run's next is often right behind.
        const quiet = b.demand_busy == 0 and win32.GetTickCount64() -% b.demand_done_at >= quiet_ms;
        if (b.demand.items.len > 0) {
            piece = b.demand.orderedRemove(0);
            b.demand_busy += 1;
        } else if (quiet and b.background.items.len > 0 and b.background_busy + 1 < @max(b.workers.len, 2)) {
            // One thread is always left for what a run waits for.
            piece = b.background.orderedRemove(0);
            background = true;
            b.background_busy += 1;
        } else {
            _ = win32.SleepConditionVariableSRW(&b.cond, &b.lock, if (quiet) 1000 else 100, 0);
            continue;
        }
        b.mark(piece, .fetching);
        win32.ReleaseSRWLockExclusive(&b.lock);
        const len: usize = @intCast(piece.end - piece.start);
        const result = b.fetchInto(piece.start, buf[0..len]);
        win32.AcquireSRWLockExclusive(&b.lock);
        if (background) {
            b.background_busy -= 1;
            b.background_out -= 1;
        } else {
            b.demand_busy -= 1;
            b.demand_done_at = win32.GetTickCount64();
        }
        if (result) |_| {
            b.mark(piece, .have);
            const counter = if (background) &b.downloaded else &b.on_demand;
            _ = counter.fetchAdd(len, .monotonic);
            b.writeMap();
        } else |err| {
            b.mark(piece, .missing);
            b.last_error = err;
            if (background) b.background_failed = err;
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
fn fetchInto(b: *BlobReader, offset: u64, buffer: []u8) !void {
    try b.fetchRange(offset, buffer);
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

/// Fetches `buffer.len` bytes of the blob from `offset` from the registry.
fn fetchRange(b: *BlobReader, offset: u64, buffer: []u8) !void {
    _ = b.requests.fetchAdd(1, .monotonic);
    if (b.test_fetch) |f| return f(b, offset, buffer);
    const c = try b.acquire();
    defer b.release(c);
    var w: Io.Writer = .fixed(buffer);
    const found = c.registry.getBlob(b.digest, .{ .start = offset, .end = offset + buffer.len }, &w) catch |err| {
        // A client that failed may be in any state: the next one starts afresh.
        c.uses = Client.max_uses;
        return err;
    };
    if (!found) return error.BlobNotFound;
    if (w.end != buffer.len) return error.EndOfStream;
}

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

    fn fetch(b: *BlobReader, offset: u64, buffer: []u8) anyerror!void {
        _ = b;
        _ = calls.fetchAdd(1, .monotonic);
        _ = fetched.fetchAdd(buffer.len, .monotonic);
        if (fail_at) |at| if (at >= offset and at < offset + buffer.len) return error.TestFailure;
        win32.Sleep(5);
        for (buffer, 0..) |*x, i| x.* = @truncate(offset + i);
    }

    fn reset() void {
        calls.store(0, .monotonic);
        fetched.store(0, .monotonic);
        fail_at = null;
    }
};

fn testReader(ctx: *Context, tail: []const u8, size: u64, dir: []const u8) !*BlobReader {
    const b = try BlobReader.init(testing.allocator, ctx, .{ .host = "test", .repository = "test" }, "sha256:00", size, tail, .{});
    b.test_fetch = Fake.fetch;
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
