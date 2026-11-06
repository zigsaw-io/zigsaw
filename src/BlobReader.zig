//! A layer's blob, read by many threads at once while it isn't in the store
//! yet: what a lazy pull's helper (LazyHelper.zig) serves files from. Bytes
//! come from, in this order:
//! - the blob's tail, as `zigsaw pull` fetched it, which holds the TOC;
//! - what the background download already has, in its file;
//! - the registry, by Range requests for whole blocks, which are kept: a
//!   registry's storage takes about as long for 4 KiB as for a megabyte, and
//!   files used together are often neighbours (docs/experiment-cloud-files.md).
//! Nothing here checks what it reads: the index checks each chunk against the
//! TOC, and the download checks the blob against its digest.

const BlobReader = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
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
/// The file with the blob's first `downloaded` bytes: the download's, then
/// the store's blob once it's complete. Read by opening it each time, so
/// that it can move under readers.
have_path: []const u8 = "",
have_lock: win32.SRWLOCK = .{},
downloaded: std.atomic.Value(u64) = .init(0),
block_size: u64 = 1 << 20,
slots: []Slot,
clients: []Client,
/// Requests sent and bytes fetched, for the log.
requests: std.atomic.Value(u64) = .init(0),
fetched: std.atomic.Value(u64) = .init(0),

const Slot = struct {
    lock: win32.SRWLOCK = .{},
    block: u64 = std.math.maxInt(u64),
    data: ?[]u8 = null,
};

/// A registry client, which one request at a time uses. Replaced, with its
/// arena, every so many requests: Registry allocates each request's strings
/// in its context's arena, and refreshes a token only once.
const Client = struct {
    busy: std.atomic.Value(bool) = .init(false),
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
    /// How many blocks are kept.
    slots: usize = 32,
};

pub fn init(gpa: Allocator, base: *Context, ref: Registry.Reference, digest: []const u8, size: u64, tail: []const u8, options: Options) !*BlobReader {
    const b = try gpa.create(BlobReader);
    errdefer gpa.destroy(b);
    const slots = try gpa.alloc(Slot, options.slots);
    errdefer gpa.free(slots);
    for (slots) |*s| s.* = .{};
    const clients = try gpa.alloc(Client, options.clients);
    for (clients) |*c| c.* = .{};
    b.* = .{
        .gpa = gpa,
        .base = base,
        .ref = ref,
        .digest = digest,
        .size = size,
        .tail = tail,
        .tail_start = size - tail.len,
        .slots = slots,
        .clients = clients,
    };
    return b;
}

pub fn deinit(b: *BlobReader) void {
    for (b.clients) |*c| if (c.ready) {
        c.registry.deinit();
        c.arena.deinit();
    };
    for (b.slots) |s| if (s.data) |d| b.gpa.free(d);
    b.gpa.free(b.slots);
    b.gpa.free(b.clients);
    b.gpa.destroy(b);
}

pub fn source(b: *BlobReader) format.Source {
    return .{ .context = b, .readAtFn = readAt, .size = b.size };
}

/// Says that `path` has the blob's first `downloaded` bytes.
pub fn setHave(b: *BlobReader, path: []const u8, downloaded: u64) void {
    win32.AcquireSRWLockExclusive(&b.have_lock);
    defer win32.ReleaseSRWLockExclusive(&b.have_lock);
    b.have_path = path;
    b.downloaded.store(downloaded, .release);
}

pub fn setDownloaded(b: *BlobReader, downloaded: u64) void {
    b.downloaded.store(downloaded, .release);
}

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
    const want: usize = @intCast(@min(buffer.len, b.tail_start - offset));
    if (offset + want <= b.downloaded.load(.acquire)) {
        if (try b.readHave(offset, buffer[0..want])) return want;
    }
    return b.readBlock(offset, buffer[0..want]);
}

/// Reads from the file that has the downloaded bytes; false if it moved
/// away in between, as the download's file does when it's complete.
fn readHave(b: *BlobReader, offset: u64, buffer: []u8) !bool {
    const io = b.base.io;
    win32.AcquireSRWLockExclusive(&b.have_lock);
    const path = b.have_path;
    win32.ReleaseSRWLockExclusive(&b.have_lock);
    if (path.len == 0) return false;
    var file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    defer file.close(io);
    var done: usize = 0;
    while (done < buffer.len) {
        const n = try file.readPositional(io, &.{buffer[done..]}, offset + done);
        if (n == 0) return error.EndOfStream;
        done += n;
    }
    return true;
}

fn readBlock(b: *BlobReader, offset: u64, buffer: []u8) !usize {
    const block = offset / b.block_size;
    const slot = &b.slots[block % b.slots.len];
    win32.AcquireSRWLockExclusive(&slot.lock);
    defer win32.ReleaseSRWLockExclusive(&slot.lock);
    const start = block * b.block_size;
    const end = @min(start + b.block_size, b.tail_start);
    if (slot.block != block) {
        const data = slot.data orelse try b.gpa.alloc(u8, @intCast(b.block_size));
        slot.data = data;
        slot.block = std.math.maxInt(u64);
        try b.fetch(start, data[0..@intCast(end - start)]);
        slot.block = block;
    }
    const within: usize = @intCast(offset - start);
    const n = @min(buffer.len, @as(usize, @intCast(end - start)) - within);
    @memcpy(buffer[0..n], slot.data.?[within..][0..n]);
    return n;
}

/// Fetches `buffer.len` bytes of the blob from `offset` from the registry.
pub fn fetch(b: *BlobReader, offset: u64, buffer: []u8) !void {
    const c = try b.acquire();
    defer b.release(c);
    var w: Io.Writer = .fixed(buffer);
    _ = b.requests.fetchAdd(1, .monotonic);
    const found = c.registry.getBlob(b.digest, .{ .start = offset, .end = offset + buffer.len }, &w) catch |err| {
        // A client that failed may be in any state: the next one starts afresh.
        c.uses = Client.max_uses;
        return err;
    };
    if (!found) return error.BlobNotFound;
    _ = b.fetched.fetchAdd(buffer.len, .monotonic);
}

fn acquire(b: *BlobReader) !*Client {
    while (true) {
        for (b.clients) |*c| {
            if (c.busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) continue;
            if (!c.ready) {
                c.arena = .init(b.gpa);
                c.ctx = b.base.*;
                c.ctx.arena = c.arena.allocator();
                c.registry.init(&c.ctx, b.ref, "pull") catch |err| {
                    c.arena.deinit();
                    c.busy.store(false, .release);
                    return err;
                };
                c.ready = true;
                c.uses = 0;
            }
            return c;
        }
        win32.Sleep(5);
    }
}

fn release(b: *BlobReader, c: *Client) void {
    _ = b;
    c.uses += 1;
    if (c.uses >= Client.max_uses) {
        c.registry.deinit();
        c.arena.deinit();
        c.ready = false;
    }
    c.busy.store(false, .release);
}
