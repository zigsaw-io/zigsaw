//! A transparency log's proof that it holds an entry: the entry's place in a Merkle
//! tree (RFC 9162, as Rekor's logs are), and a checkpoint, the log's signed word for
//! that tree's size and root, in the signed-note form (c2sp.org/signed-note) both
//! Rekor v1 and v2 write.
//!
//! No keys here: a checkpoint's signatures are handed back, and sigstore.zig checks
//! the one by the log it trusts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Hash = [32]u8;

pub fn leafHash(entry: []const u8) Hash {
    var h = Sha256.init(.{});
    h.update(&.{0x00});
    h.update(entry);
    return h.finalResult();
}

fn nodeHash(left: Hash, right: Hash) Hash {
    var h = Sha256.init(.{});
    h.update(&.{0x01});
    h.update(&left);
    h.update(&right);
    return h.finalResult();
}

/// The root a tree of `size` leaves has if the leaf at `index` is `leaf` and
/// `path` is its audit path, or null if the path can't be one for that place
/// (RFC 9162, 2.1.3.2).
pub fn rootFromPath(leaf: Hash, index: u64, size: u64, path: []const Hash) ?Hash {
    if (index >= size) return null;
    var fn_ = index;
    var sn = size - 1;
    var r = leaf;
    for (path) |p| {
        if (sn == 0) return null;
        if (fn_ & 1 == 1 or fn_ == sn) {
            r = nodeHash(p, r);
            if (fn_ & 1 == 0) {
                while (fn_ & 1 == 0 and fn_ != 0) {
                    fn_ >>= 1;
                    sn >>= 1;
                }
            }
        } else {
            r = nodeHash(r, p);
        }
        fn_ >>= 1;
        sn >>= 1;
    }
    if (sn != 0) return null;
    return r;
}

/// A checkpoint: what its signatures cover, and the signatures.
pub const Checkpoint = struct {
    /// The note's text up to the blank line, newline included: what's signed.
    body: []const u8,
    origin: []const u8,
    size: u64,
    root: Hash,
    signatures: []const Signature,

    pub const Signature = struct {
        name: []const u8,
        /// The first 4 bytes of the key's id, by which a reader finds its key.
        hint: [4]u8,
        bytes: []const u8,
    };
};

/// Reads a checkpoint, or null if it isn't one.
pub fn parseCheckpoint(arena: Allocator, text: []const u8) Allocator.Error!?Checkpoint {
    const split = std.mem.indexOf(u8, text, "\n\n") orelse return null;
    const body = text[0 .. split + 1];
    var lines = std.mem.splitScalar(u8, body[0 .. body.len - 1], '\n');
    const origin = lines.next() orelse return null;
    const size_text = lines.next() orelse return null;
    const root_text = lines.next() orelse return null;
    if (origin.len == 0) return null;
    const size = std.fmt.parseInt(u64, size_text, 10) catch return null;
    var root: Hash = undefined;
    const decoder = std.base64.standard.Decoder;
    if ((decoder.calcSizeForSlice(root_text) catch return null) != root.len) return null;
    decoder.decode(&root, root_text) catch return null;

    var signatures: std.ArrayList(Checkpoint.Signature) = .empty;
    var rest = std.mem.splitScalar(u8, text[split + 2 ..], '\n');
    while (rest.next()) |line| {
        if (line.len == 0) continue;
        // "— <name> <base64 of hint and signature>", the dash being U+2014.
        const dash = "\u{2014} ";
        if (!std.mem.startsWith(u8, line, dash)) return null;
        const after = line[dash.len..];
        const space = std.mem.lastIndexOfScalar(u8, after, ' ') orelse return null;
        const name = after[0..space];
        const encoded = after[space + 1 ..];
        const len = decoder.calcSizeForSlice(encoded) catch return null;
        if (name.len == 0 or len < 5) return null;
        const raw = try arena.alloc(u8, len);
        decoder.decode(raw, encoded) catch return null;
        try signatures.append(arena, .{ .name = name, .hint = raw[0..4].*, .bytes = raw[4..] });
    }
    if (signatures.items.len == 0) return null;
    return .{ .body = body, .origin = origin, .size = size, .root = root, .signatures = signatures.items };
}

const testing = std.testing;

/// A tree's root, the plain way, to check paths against.
fn rootOf(leaves: []const Hash) Hash {
    if (leaves.len == 1) return leaves[0];
    var k: usize = 1;
    while (k * 2 < leaves.len) k *= 2;
    return nodeHash(rootOf(leaves[0..k]), rootOf(leaves[k..]));
}

/// The audit path of leaf `m`, the plain way (RFC 9162, 2.1.3.1).
fn pathOf(arena: Allocator, leaves: []const Hash, m: usize) ![]const Hash {
    if (leaves.len == 1) return &.{};
    var k: usize = 1;
    while (k * 2 < leaves.len) k *= 2;
    var path: std.ArrayList(Hash) = .empty;
    if (m < k) {
        try path.appendSlice(arena, try pathOf(arena, leaves[0..k], m));
        try path.append(arena, rootOf(leaves[k..]));
    } else {
        try path.appendSlice(arena, try pathOf(arena, leaves[k..], m - k));
        try path.append(arena, rootOf(leaves[0..k]));
    }
    return path.items;
}

test "every leaf's path leads to its tree's root, in trees of 1 to 20 leaves" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var leaves: [20]Hash = undefined;
    for (&leaves, 0..) |*l, i| l.* = leafHash(&.{@intCast(i)});
    for (1..leaves.len + 1) |size| {
        const tree = leaves[0..size];
        const root = rootOf(tree);
        for (0..size) |m| {
            const path = try pathOf(a, tree, m);
            try testing.expectEqual(@as(?Hash, root), rootFromPath(tree[m], m, size, path));
            // Elsewhere in the tree, it isn't. (In a tree of another size it may be:
            // a path doesn't pin the size, which is why the checkpoint signs it.)
            if (size > 1) try testing.expect(!std.meta.eql(@as(?Hash, root), rootFromPath(tree[m], (m + 1) % size, size, path)));
            // Nor with a step of its path changed, or one too few or too many.
            if (path.len > 0) {
                const changed = try a.dupe(Hash, path);
                changed[0][0] ^= 1;
                try testing.expect(!std.meta.eql(@as(?Hash, root), rootFromPath(tree[m], m, size, changed)));
                try testing.expectEqual(@as(?Hash, null), rootFromPath(tree[m], m, size, path[0 .. path.len - 1]));
            }
            const longer = try std.mem.concat(a, Hash, &.{ path, &.{leaves[0]} });
            try testing.expectEqual(@as(?Hash, null), rootFromPath(tree[m], m, size, longer));
        }
    }
    try testing.expectEqual(@as(?Hash, null), rootFromPath(leaves[0], 3, 3, &.{}));
}

test "a checkpoint as Rekor v1 writes one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // From iteration 81's real bundle.
    const text = "rekor.sigstore.dev - 1193050959916656506\n3636655104\nJ1jkHujWJiILjuXSROIqVZp70pMD5X97oIv9KzHAPK0=\n\n\u{2014} rekor.sigstore.dev wNI9ajBGAiEAv7lSA5mosdvhA4yE+xRom/mDFdCQhRthpLXM3dzhYuECIQDUT+Acc27r45lEyJGHny7PtAGqAAQ59ven7EFEQJZGHA==\n";
    const c = (try parseCheckpoint(arena.allocator(), text)).?;
    try testing.expectEqualStrings("rekor.sigstore.dev - 1193050959916656506", c.origin);
    try testing.expectEqual(@as(u64, 3636655104), c.size);
    try testing.expectEqualStrings("rekor.sigstore.dev - 1193050959916656506\n3636655104\nJ1jkHujWJiILjuXSROIqVZp70pMD5X97oIv9KzHAPK0=\n", c.body);
    try testing.expectEqual(@as(usize, 1), c.signatures.len);
    try testing.expectEqualStrings("rekor.sigstore.dev", c.signatures[0].name);
    try testing.expectEqualSlices(u8, &.{ 0xc0, 0xd2, 0x3d, 0x6a }, &c.signatures[0].hint);
    try testing.expectEqual(@as(u8, 0x30), c.signatures[0].bytes[0]); // An ECDSA signature's DER.

    const not = [_][]const u8{
        "",
        "origin\n12\nJ1jkHujWJiILjuXSROIqVZp70pMD5X97oIv9KzHAPK0=\n", // no signatures
        "origin\n12\nJ1jkHujWJiILjuXSROIqVZp70pMD5X97oIv9KzHAPK0=\n\n- name wNI9ajBG\n", // not U+2014
        "origin\ntwelve\nJ1jkHujWJiILjuXSROIqVZp70pMD5X97oIv9KzHAPK0=\n\n\u{2014} name wNI9ajBG\n",
        "origin\n12\nJ1jk\n\n\u{2014} name wNI9ajBG\n", // a root that isn't 32 bytes
        "origin\n12\nJ1jkHujWJiILjuXSROIqVZp70pMD5X97oIv9KzHAPK0=\n\n\u{2014} name wNI9\n", // only a hint
    };
    for (not) |t| try testing.expectEqual(@as(?Checkpoint, null), try parseCheckpoint(arena.allocator(), t));
}
