//! RFC 3161 timestamps, as a timestamp authority (Sigstore's, for one) gives them: a
//! CMS SignedData whose content is a TSTInfo, which says when the authority saw a
//! hash. A bundle logged in Rekor v2 carries one over its signature, and that's the
//! only time it has.
//!
//! What's read here is from anyone. `parse` takes it apart and checks that it holds
//! together (the signed attributes name this TSTInfo); `signedBy` checks the
//! authority's signature with a certificate the caller trusts. Which certificates
//! those are, and whether they were good then, is sigstore.zig's.
//!
//! Only what Sigstore's authority and a test's make: ECDSA on P-256 or P-384, with
//! SHA-256 or SHA-384.

const std = @import("std");
const Certificate = std.crypto.Certificate;
const ecdsa = std.crypto.sign.ecdsa;
const der = @import("der.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha384 = std.crypto.hash.sha2.Sha384;

pub const HashAlgorithm = enum { sha256, sha384 };

pub const Token = struct {
    /// When the authority says it saw the hash, seconds since 1970.
    time: i64,
    /// What it saw: a hash of the thing timestamped.
    imprint: Imprint,
    /// The TSTInfo, which `time` and `imprint` are read from, as signed.
    content: []const u8,
    /// The signed attributes as written, tagged [0]. Their signature covers them
    /// tagged as a SET (RFC 5652, 5.4).
    signed_attributes: []const u8,
    signature_hash: HashAlgorithm,
    signature: []const u8,

    pub const Imprint = struct {
        algorithm: HashAlgorithm,
        hash: []const u8,

        /// Whether it's a hash of `bytes`.
        pub fn of(i: Imprint, bytes: []const u8) bool {
            return switch (i.algorithm) {
                .sha256 => std.mem.eql(u8, i.hash, &digest(Sha256, bytes)),
                .sha384 => std.mem.eql(u8, i.hash, &digest(Sha384, bytes)),
            };
        }
    };

    /// Whether the token's signature is by the key of `cert`.
    pub fn signedBy(t: Token, cert: Certificate.Parsed) bool {
        const curve = switch (cert.pub_key_algo) {
            .X9_62_id_ecPublicKey => |c| c,
            else => return false,
        };
        return switch (curve) {
            .X9_62_prime256v1 => switch (t.signature_hash) {
                .sha256 => verifies(ecdsa.Ecdsa(std.crypto.ecc.P256, Sha256), t, cert),
                .sha384 => verifies(ecdsa.Ecdsa(std.crypto.ecc.P256, Sha384), t, cert),
            },
            .secp384r1 => switch (t.signature_hash) {
                .sha256 => verifies(ecdsa.Ecdsa(std.crypto.ecc.P384, Sha256), t, cert),
                .sha384 => verifies(ecdsa.Ecdsa(std.crypto.ecc.P384, Sha384), t, cert),
            },
            else => false,
        };
    }

    fn verifies(comptime Scheme: type, t: Token, cert: Certificate.Parsed) bool {
        const key = Scheme.PublicKey.fromSec1(cert.pubKey()) catch return false;
        const sig = Scheme.Signature.fromDer(t.signature) catch return false;
        var v = sig.verifier(key) catch return false;
        v.update(&.{0x31}); // SET, for the [0] written
        v.update(t.signed_attributes[1..]);
        v.verify() catch return false;
        return true;
    }
};

fn digest(comptime H: type, bytes: []const u8) [H.digest_length]u8 {
    var out: [H.digest_length]u8 = undefined;
    H.hash(bytes, &out, .{});
    return out;
}

// OIDs, as their DER contents.
const oid_signed_data = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02 };
const oid_tst_info = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x10, 0x01, 0x04 };
const oid_content_type = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x03 };
const oid_message_digest = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x04 };
const oid_sha256 = [_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01 };
const oid_sha384 = [_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02 };
const oid_ecdsa_sha256 = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02 };
const oid_ecdsa_sha384 = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x03 };

pub const Error = error{
    /// Not DER, or not shaped as a timestamp.
    Malformed,
    /// The authority didn't grant it.
    NotGranted,
    /// Its signed attributes don't name its TSTInfo.
    Inconsistent,
    /// An algorithm this doesn't do.
    Unsupported,
};

/// Takes a TimeStampResp, or the bare token inside one, apart.
pub fn parse(bytes: []const u8) Error!Token {
    const outer = try der.element(bytes, 0, bytes.len);
    if (outer.slice.end != bytes.len or !der.isTag(outer, .sequence)) return error.Malformed;
    var top: der.Children = .of(bytes, outer);
    const first = try top.need();
    const content_info = if (der.isTag(first, .sequence)) blk: {
        // A response: its status first (granted, or granted with changes).
        var status: der.Children = .of(bytes, first);
        const code = try status.need();
        if (!der.isTag(code, .integer)) return error.Malformed;
        const value = der.content(bytes, code);
        if (value.len != 1 or value[0] > 1) return error.NotGranted;
        break :blk try top.need();
    } else outer;
    return parseToken(bytes, content_info);
}

fn parseToken(bytes: []const u8, content_info: der.Element) Error!Token {
    if (!der.isTag(content_info, .sequence)) return error.Malformed;
    var ci: der.Children = .of(bytes, content_info);
    const type_ = try ci.need();
    if (!der.isTag(type_, .object_identifier) or !std.mem.eql(u8, der.content(bytes, type_), &oid_signed_data)) return error.Malformed;
    const explicit = try ci.need();
    if (!der.isContext(explicit, 0)) return error.Malformed;
    var ex: der.Children = .of(bytes, explicit);
    const signed_data = try ex.need();
    if (!der.isTag(signed_data, .sequence)) return error.Malformed;

    var sd: der.Children = .of(bytes, signed_data);
    _ = try sd.need(); // version
    const digest_algorithms = try sd.need();
    if (!der.isTag(digest_algorithms, .set)) return error.Malformed;
    const encap = try sd.need();
    if (!der.isTag(encap, .sequence)) return error.Malformed;
    var en: der.Children = .of(bytes, encap);
    const econtent_type = try en.need();
    if (!der.isTag(econtent_type, .object_identifier) or !std.mem.eql(u8, der.content(bytes, econtent_type), &oid_tst_info)) return error.Malformed;
    const econtent_explicit = try en.need();
    if (!der.isContext(econtent_explicit, 0)) return error.Malformed;
    var ece: der.Children = .of(bytes, econtent_explicit);
    const econtent = try ece.need();
    if (!der.isTag(econtent, .octetstring)) return error.Malformed;
    const tst_der = der.content(bytes, econtent);

    // Certificates and CRLs may follow; what's trusted is the caller's, so they're
    // passed over. Then the signer infos: one is all an authority writes.
    const signer_infos = while (try sd.next()) |e| {
        if (der.isTag(e, .set)) break e;
    } else return error.Malformed;
    var sis: der.Children = .of(bytes, signer_infos);
    const signer_info = try sis.need();
    if (try sis.next() != null) return error.Unsupported;
    if (!der.isTag(signer_info, .sequence)) return error.Malformed;

    var si: der.Children = .of(bytes, signer_info);
    _ = try si.need(); // version
    _ = try si.need(); // who signed: issuer and serial, or a key id
    const digest_algorithm = try hashOfAlgorithm(bytes, try si.need());
    const signed_attrs_start = si.at;
    const signed_attrs = try si.need();
    if (!der.isContext(signed_attrs, 0) or signed_attrs.identifier.pc != .constructed) return error.Malformed;
    const sig_alg_e = try si.need();
    if (!der.isTag(sig_alg_e, .sequence)) return error.Malformed;
    var sa: der.Children = .of(bytes, sig_alg_e);
    const sig_oid = try sa.need();
    if (!der.isTag(sig_oid, .object_identifier)) return error.Malformed;
    const signature_hash: HashAlgorithm = if (std.mem.eql(u8, der.content(bytes, sig_oid), &oid_ecdsa_sha256))
        .sha256
    else if (std.mem.eql(u8, der.content(bytes, sig_oid), &oid_ecdsa_sha384))
        .sha384
    else
        return error.Unsupported;
    const sig_e = try si.need();
    if (!der.isTag(sig_e, .octetstring)) return error.Malformed;

    // The signed attributes: the content's type, and its hash.
    var content_type_ok = false;
    var message_digest_ok = false;
    var attrs: der.Children = .of(bytes, signed_attrs);
    while (try attrs.next()) |attr| {
        if (!der.isTag(attr, .sequence)) return error.Malformed;
        var at: der.Children = .of(bytes, attr);
        const oid = try at.need();
        const values = try at.need();
        if (!der.isTag(oid, .object_identifier) or !der.isTag(values, .set)) return error.Malformed;
        var vs: der.Children = .of(bytes, values);
        const value = try vs.need();
        if (try vs.next() != null) return error.Malformed;
        if (std.mem.eql(u8, der.content(bytes, oid), &oid_content_type)) {
            if (!der.isTag(value, .object_identifier) or !std.mem.eql(u8, der.content(bytes, value), &oid_tst_info)) return error.Inconsistent;
            content_type_ok = true;
        } else if (std.mem.eql(u8, der.content(bytes, oid), &oid_message_digest)) {
            if (!der.isTag(value, .octetstring)) return error.Malformed;
            const imprint: Token.Imprint = .{ .algorithm = digest_algorithm, .hash = der.content(bytes, value) };
            if (!imprint.of(tst_der)) return error.Inconsistent;
            message_digest_ok = true;
        }
    }
    if (!content_type_ok or !message_digest_ok) return error.Inconsistent;

    const tst = try parseTstInfo(tst_der);
    return .{
        .time = tst.time,
        .imprint = tst.imprint,
        .content = tst_der,
        .signed_attributes = der.whole(bytes, signed_attrs_start, signed_attrs),
        .signature_hash = signature_hash,
        .signature = der.content(bytes, sig_e),
    };
}

fn hashOfAlgorithm(bytes: []const u8, e: der.Element) Error!HashAlgorithm {
    if (!der.isTag(e, .sequence)) return error.Malformed;
    var c: der.Children = .of(bytes, e);
    const oid = try c.need();
    if (!der.isTag(oid, .object_identifier)) return error.Malformed;
    if (std.mem.eql(u8, der.content(bytes, oid), &oid_sha256)) return .sha256;
    if (std.mem.eql(u8, der.content(bytes, oid), &oid_sha384)) return .sha384;
    return error.Unsupported;
}

fn parseTstInfo(bytes: []const u8) Error!struct { time: i64, imprint: Token.Imprint } {
    const outer = try der.element(bytes, 0, bytes.len);
    if (outer.slice.end != bytes.len or !der.isTag(outer, .sequence)) return error.Malformed;
    var c: der.Children = .of(bytes, outer);
    _ = try c.need(); // version
    _ = try c.need(); // policy
    const mi = try c.need();
    if (!der.isTag(mi, .sequence)) return error.Malformed;
    var m: der.Children = .of(bytes, mi);
    const algorithm = try hashOfAlgorithm(bytes, try m.need());
    const hashed = try m.need();
    if (!der.isTag(hashed, .octetstring)) return error.Malformed;
    _ = try c.need(); // serial number
    const gen_time = try c.need();
    if (!der.isTag(gen_time, .generalized_time)) return error.Malformed;
    return .{
        .time = der.generalizedTime(der.content(bytes, gen_time)) orelse return error.Malformed,
        .imprint = .{ .algorithm = algorithm, .hash = der.content(bytes, hashed) },
    };
}

const testing = std.testing;

/// The real bundle of iteration 81's probe, its signature and timestamp, and the
/// authority's certificates as Sigstore's trusted root has them.
const Real = struct {
    signature: []const u8,
    timestamp: []const u8,
    leaf: []const u8,
    root: []const u8,

    fn load(a: std.mem.Allocator) !Real {
        const B = struct {
            verificationMaterial: struct { timestampVerificationData: struct { rfc3161Timestamps: []const struct { signedTimestamp: []const u8 } } },
            messageSignature: struct { signature: []const u8 },
        };
        const R = struct { timestampAuthorities: []const struct { certChain: struct { certificates: []const struct { rawBytes: []const u8 } } } };
        const b = try std.json.parseFromSliceLeaky(B, a, @embedFile("testdata/sigstore/real/payload.json.bundle.json"), .{ .ignore_unknown_fields = true });
        const r = try std.json.parseFromSliceLeaky(R, a, @embedFile("sigstore-root.json"), .{ .ignore_unknown_fields = true });
        const chain = r.timestampAuthorities[0].certChain.certificates;
        return .{
            .signature = try decode(a, b.messageSignature.signature),
            .timestamp = try decode(a, b.verificationMaterial.timestampVerificationData.rfc3161Timestamps[0].signedTimestamp),
            .leaf = try decode(a, chain[0].rawBytes),
            .root = try decode(a, chain[1].rawBytes),
        };
    }

    fn decode(a: std.mem.Allocator, text: []const u8) ![]const u8 {
        const d = std.base64.standard.Decoder;
        const out = try a.alloc(u8, try d.calcSizeForSlice(text));
        try d.decode(out, text);
        return out;
    }
};

test "a real timestamp from Sigstore's authority: when, of what, and by whom" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const real = try Real.load(arena.allocator());
    const t = try parse(real.timestamp);
    // The log's integratedTime in the same bundle is 1794163745.
    try testing.expectEqual(@as(i64, 1794163745), t.time);
    try testing.expect(t.imprint.of(real.signature));
    try testing.expect(!t.imprint.of("another signature"));
    const leaf = try Certificate.parse(.{ .buffer = real.leaf, .index = 0 });
    const root = try Certificate.parse(.{ .buffer = real.root, .index = 0 });
    try testing.expect(t.signedBy(leaf));
    try testing.expect(!t.signedBy(root));
    try leaf.verify(root, t.time);
}

test "a timestamp with anything changed is refused or isn't the authority's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const real = try Real.load(a);
    const leaf = try Certificate.parse(.{ .buffer = real.leaf, .index = 0 });
    const good = try parse(real.timestamp);
    // What the signature covers: the signed attributes, and through their hash of
    // it, the TSTInfo.
    const covered = [_][]const u8{ good.content, good.signed_attributes };
    // Every byte, flipped in turn: never a crash, and never still good where it's
    // covered. Elsewhere (the version, who signed, the status's "with changes") a
    // flip may pass unnoticed, as nothing reads it.
    var still_good: usize = 0;
    for (0..real.timestamp.len) |i| {
        const changed = try a.dupe(u8, real.timestamp);
        changed[i] ^= 0x01;
        const t = parse(changed) catch continue;
        if (!t.signedBy(leaf) or !t.imprint.of(real.signature) or t.time != good.time) continue;
        still_good += 1;
        const at = @intFromPtr(real.timestamp.ptr) + i;
        if (for (covered) |c| {
            if (at >= @intFromPtr(c.ptr) and at < @intFromPtr(c.ptr) + c.len) break true;
        } else false) {
            std.debug.print("a flip at byte {d} of {d}, inside what's signed, still verified\n", .{ i, real.timestamp.len });
            return error.TestUnexpectedResult;
        }
    }
    // Most of the bytes that aren't covered are the signer's issuer name and serial
    // (which certificate it is, as the root's chain decides instead).
    try testing.expect(still_good < real.timestamp.len / 4);
    // Cut short anywhere: an error, not a crash.
    for (0..real.timestamp.len) |n| _ = parse(real.timestamp[0..n]) catch {};
    // Not granted: a status of 2.
    try testing.expectError(error.NotGranted, parse(&.{ 0x30, 0x05, 0x30, 0x03, 0x02, 0x01, 0x02 }));
    try testing.expectError(error.Malformed, parse(&.{ 0x30, 0x00 }));
}
