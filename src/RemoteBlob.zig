//! A blob read where it is, as a layer index's source (see
//! `format.openIndex`): from the store's file if the store has the blob,
//! else from its registry by Range requests. The first read from the
//! registry fetches the blob's tail, where an index keeps its TOC and
//! footer, so opening one usually takes one request.
//!
//! Not for several threads at once.

const RemoteBlob = @This();

const std = @import("std");
const Io = std.Io;
const Context = @import("Context.zig");
const Registry = @import("Registry.zig");
const Store = @import("Store.zig");
const format = @import("format.zig");
const oci = @import("oci.zig");
const fail = Context.fail;

ctx: *Context,
registry: *Registry,
desc: oci.Descriptor,
/// The store's copy, if it has one.
file: ?Io.File = null,
local: format.Source.File = undefined,
/// The blob's last bytes, from `tail_start`, once fetched.
tail: ?[]u8 = null,
tail_start: u64 = 0,
/// Requests sent and bytes fetched, for -v.
requests: u32 = 0,
fetched: u64 = 0,

/// How much of a blob's end the first read fetches: enough for most TOCs
/// (some 60 bytes per file, compressed), little of a small blob.
pub fn tailLen(size: u64) u64 {
    return @min(size, std.math.clamp(size / 64, 16 << 10, 1 << 20));
}

pub fn open(ctx: *Context, registry: *Registry, desc: oci.Descriptor) !*RemoteBlob {
    const b = try ctx.arena.create(RemoteBlob);
    b.* = .{ .ctx = ctx, .registry = registry, .desc = desc };
    const path = try ctx.store.blobPath(ctx.arena, oci.digestHex(desc.digest).?);
    if (Io.Dir.cwd().openFile(ctx.io, path, .{})) |file| {
        b.file = file;
        b.local = .{ .io = ctx.io, .file = file };
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
    return b;
}

pub fn close(b: *RemoteBlob) void {
    if (b.file) |f| f.close(b.ctx.io);
}

pub fn source(b: *RemoteBlob) format.Source {
    if (b.file != null) return b.local.source(b.desc.size);
    return .{ .context = b, .readAtFn = readAt, .size = b.desc.size };
}

fn readAt(context: *const anyopaque, offset: u64, buffer: []u8) anyerror!usize {
    const b: *RemoteBlob = @ptrCast(@alignCast(@constCast(context)));
    const size = b.desc.size;
    if (offset >= size or buffer.len == 0) return 0;
    if (b.tail == null) {
        b.tail_start = size - tailLen(size);
        const tail = try b.ctx.arena.alloc(u8, @intCast(size - b.tail_start));
        try b.fetch(b.tail_start, tail);
        b.tail = tail;
    }
    if (offset >= b.tail_start) {
        const tail = b.tail.?[@intCast(offset - b.tail_start)..];
        const n = @min(buffer.len, tail.len);
        @memcpy(buffer[0..n], tail[0..n]);
        return n;
    }
    // Up to the tail, which the caller reads next from what it has.
    const n: usize = @intCast(@min(buffer.len, b.tail_start - offset));
    try b.fetch(offset, buffer[0..n]);
    return n;
}

/// Fetches `buffer.len` bytes of the blob from `offset`. error.RangeIgnored
/// if the registry sends blobs only whole.
fn fetch(b: *RemoteBlob, offset: u64, buffer: []u8) !void {
    var w: Io.Writer = .fixed(buffer);
    try b.fetchTo(offset, offset + buffer.len, &w);
}

/// Streams the blob's bytes from `start` to `end` into `out`: those in the
/// tail from it, the rest by one Range request.
pub fn fetchTo(b: *RemoteBlob, start: u64, end: u64, out: *Io.Writer) !void {
    const sent_end = if (b.tail != null) @min(end, b.tail_start) else end;
    if (start < sent_end) {
        b.requests += 1;
        if (!try b.registry.getBlob(b.desc.digest, .{ .start = start, .end = sent_end }, out))
            return fail("{f} doesn't have layer {s}", .{ b.registry.ref, b.desc.digest });
        b.fetched += sent_end - start;
    }
    if (end > sent_end) {
        const tail = b.tail.?;
        try out.writeAll(tail[@intCast(@max(start, b.tail_start) - b.tail_start)..@intCast(end - b.tail_start)]);
    }
}

/// The message for error.RangeIgnored.
pub fn wholeOnly(b: *RemoteBlob) error{Failed} {
    return fail("{f} sends blobs only whole, so layer {s} can't be read without pulling it", .{ b.registry.ref, oci.shortDigest(b.desc.digest) });
}
