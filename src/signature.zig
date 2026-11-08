//! Signatures as cosign makes them with a key pair: ECDSA P-256 over SHA-256, in DER,
//! in base64. zigsaw only checks them. Nothing here or anywhere in zigsaw handles a
//! private key: `cosign sign-blob` makes them, on the publisher's machine.
//!
//! For an image, what's signed is cosign's simple-signing payload, naming the image
//! by digest and its repository, and the signature sits beside the image under a tag
//! named after that digest, in cosign's classic layout: stock `cosign verify --key`
//! reads it. For a release, what's signed is the file SHA256SUMS.
//!
//! No files or network here: see remote.zig for images, upgrade.zig for releases, and
//! trust.zig for which keys count.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;

pub const payload_media_type = "application/vnd.dev.cosign.simplesigning.v1+json";
pub const signature_annotation = "dev.cosignproject.cosign/signature";
const payload_type = "cosign container image signature";

/// A payload is a line of JSON naming a digest and a repository.
pub const max_payload_size = 64 * 1024;

/// How a P-256 public key starts in PKIX form, which is what `cosign.pub` holds: the
/// algorithm's identifiers, then the 65-byte point.
pub const p256_prefix = [_]u8{ 0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00 };
const point_size = 65;

pub const Key = struct {
    public: Ecdsa.PublicKey,
    /// The start of the SHA-256 of the key's DER, in hex: what's shown for a key.
    fingerprint: [16]u8,

    /// Reads a PEM public key. Only P-256, which is what `cosign generate-key-pair`
    /// makes: an RSA or Ed25519 key isn't one this can check with, and says so here
    /// rather than at the first image.
    pub fn parse(pem: []const u8) error{NotAKey}!Key {
        const begin = "-----BEGIN PUBLIC KEY-----";
        const end = "-----END PUBLIC KEY-----";
        const trimmed = std.mem.trim(u8, pem, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, begin) or !std.mem.endsWith(u8, trimmed, end) or trimmed.len < begin.len + end.len) return error.NotAKey;

        var text_buf: [256]u8 = undefined;
        var text_len: usize = 0;
        for (trimmed[begin.len .. trimmed.len - end.len]) |c| {
            if (c == '\r' or c == '\n') continue;
            if (text_len == text_buf.len) return error.NotAKey;
            text_buf[text_len] = c;
            text_len += 1;
        }
        var der_buf: [p256_prefix.len + point_size]u8 = undefined;
        const der = decodeBase64(&der_buf, text_buf[0..text_len]) orelse return error.NotAKey;
        if (der.len != der_buf.len or !std.mem.startsWith(u8, der, &p256_prefix)) return error.NotAKey;

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(der, &hash, .{});
        const hex = std.fmt.bytesToHex(hash, .lower);
        return .{
            .public = Ecdsa.PublicKey.fromSec1(der[p256_prefix.len..]) catch return error.NotAKey,
            .fingerprint = hex[0..16].*,
        };
    }

    /// Whether `signature`, in base64 as cosign writes it, is this key's over `message`.
    pub fn verifies(key: Key, message: []const u8, signature: []const u8) bool {
        var buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
        const der = decodeBase64(&buf, std.mem.trim(u8, signature, " \t\r\n")) orelse return false;
        const parsed = Ecdsa.Signature.fromDer(der) catch return false;
        parsed.verify(message, key.public) catch return false;
        return true;
    }
};

fn decodeBase64(buf: []u8, text: []const u8) ?[]const u8 {
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(text) catch return null;
    if (size > buf.len) return null;
    decoder.decode(buf[0..size], text) catch return null;
    return buf[0..size];
}

/// The tag a signature of the image with this digest goes under, beside it.
pub fn tagFor(arena: Allocator, digest: []const u8) ![]const u8 {
    const colon = std.mem.indexOfScalar(u8, digest, ':') orelse return error.InvalidDigest;
    return std.fmt.allocPrint(arena, "{s}-{s}.sig", .{ digest[0..colon], digest[colon + 1 ..] });
}

/// The tag a keyless signature of the image with this digest goes under: a tag of its
/// own, as zigsaws before 0.81 refuse what they can't check under the classic one.
pub fn bundleTagFor(arena: Allocator, digest: []const u8) ![]const u8 {
    const colon = std.mem.indexOfScalar(u8, digest, ':') orelse return error.InvalidDigest;
    return std.fmt.allocPrint(arena, "{s}-{s}.sigstore", .{ digest[0..colon], digest[colon + 1 ..] });
}

/// What a signature of this image says, as cosign would write it.
pub fn makePayload(arena: Allocator, repository: []const u8, digest: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"critical\":{{\"identity\":{{\"docker-reference\":\"{s}\"}},\"image\":{{\"docker-manifest-digest\":\"{s}\"}},\"type\":\"{s}\"}},\"optional\":null}}", .{ repository, digest, payload_type });
}

pub const Payload = struct {
    /// `<host>/<repository>`, with no tag.
    repository: []const u8,
    digest: []const u8,
};

/// What a payload names. Anything else in it is ignored, as what cosign's `-a` adds
/// goes there.
pub fn parsePayload(arena: Allocator, bytes: []const u8) error{ NotAPayload, OutOfMemory }!Payload {
    const Parsed = struct {
        critical: struct {
            identity: struct { @"docker-reference": []const u8 },
            image: struct { @"docker-manifest-digest": []const u8 },
            type: []const u8,
        },
    };
    const parsed = std.json.parseFromSliceLeaky(Parsed, arena, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.NotAPayload,
    };
    if (!std.mem.eql(u8, parsed.critical.type, payload_type)) return error.NotAPayload;
    return .{ .repository = parsed.critical.identity.@"docker-reference", .digest = parsed.critical.image.@"docker-manifest-digest" };
}

pub const PayloadError = error{ NotAPayload, OtherImage, OtherRepository, OutOfMemory };

/// Whether a payload, whose signature has been checked, is about this image in this
/// repository. Without the digest, any signature would do for any image; without the
/// repository, a signed image could be served under the name of another app.
pub fn checkPayload(arena: Allocator, bytes: []const u8, repository: []const u8, digest: []const u8) PayloadError!void {
    const payload = try parsePayload(arena, bytes);
    if (!std.mem.eql(u8, payload.digest, digest)) return error.OtherImage;
    if (!std.ascii.eqlIgnoreCase(payload.repository, repository)) return error.OtherRepository;
}

// Made by cosign 3.1.4: `generate-key-pair`, then `sign-blob --key cosign.key
// --new-bundle-format=false --use-signing-config=false --tlog-upload=false
// --output-signature payload.sig payload.json`. Its private key is gone.
const golden_key = @embedFile("testdata/cosign/cosign.pub");
const golden_payload = @embedFile("testdata/cosign/payload.json");
const golden_signature = @embedFile("testdata/cosign/payload.sig");
const golden_repository = "localhost:5000/gate/app";
const golden_digest = "sha256:58214bd6d7325459615fb1b8d6cac46e935cd890832e0b7573da78b80d9b155b";

test "a signature cosign made verifies, and its payload says what it should" {
    const key = try Key.parse(golden_key);
    try std.testing.expect(key.verifies(golden_payload, golden_signature));

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try checkPayload(arena, golden_payload, golden_repository, golden_digest);
    // The same bytes as cosign's, as stock `cosign verify` reads what zigsaw pushes.
    try std.testing.expectEqualStrings(golden_payload, try makePayload(arena, golden_repository, golden_digest));
}

test "any change to what's signed, or the signature, fails" {
    const key = try Key.parse(golden_key);
    var message = golden_payload.*;
    // Some of them: a check takes a while in a debug build.
    var i: usize = 0;
    while (i < message.len) : (i += 37) {
        message[i] ^= 1;
        try std.testing.expect(!key.verifies(&message, golden_signature));
        message[i] ^= 1;
    }

    var buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der = decodeBase64(&buf, std.mem.trim(u8, golden_signature, " \r\n")).?;
    const encoder = std.base64.standard.Encoder;
    var text_buf: [128]u8 = undefined;
    i = 0;
    while (i < der.len) : (i += 7) {
        var changed = buf;
        changed[i] ^= 1;
        try std.testing.expect(!key.verifies(golden_payload, encoder.encode(&text_buf, changed[0..der.len])));
    }

    // Bytes after the DER, and a truncated one.
    var longer: [Ecdsa.Signature.der_encoded_length_max + 1]u8 = undefined;
    @memcpy(longer[0..der.len], der);
    longer[der.len] = 0;
    try std.testing.expect(!key.verifies(golden_payload, encoder.encode(&text_buf, longer[0 .. der.len + 1])));
    try std.testing.expect(!key.verifies(golden_payload, encoder.encode(&text_buf, der[0 .. der.len - 1])));

    try std.testing.expect(!key.verifies(golden_payload, ""));
    try std.testing.expect(!key.verifies(golden_payload, "not base64!"));
}

test "another key's signature doesn't verify" {
    // From `cosign generate-key-pair`, another time.
    const other = try Key.parse(
        \\-----BEGIN PUBLIC KEY-----
        \\MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEXThf29L0MZDKJ0XmGZOnsa9bTfnm
        \\GwTc6JcpcVqMxsROLSOmJYvylIJpsGBkl2Vq9GfVSO/1BQ3E0/+r5f69cA==
        \\-----END PUBLIC KEY-----
    );
    try std.testing.expect(!other.verifies(golden_payload, golden_signature));
    try std.testing.expect(!std.mem.eql(u8, &other.fingerprint, &(try Key.parse(golden_key)).fingerprint));
}

test "a payload is about one image in one repository" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const other_digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectError(error.OtherImage, checkPayload(arena, golden_payload, golden_repository, other_digest));
    try std.testing.expectError(error.OtherRepository, checkPayload(arena, golden_payload, "localhost:5000/gate/another", golden_digest));
    // Host names don't care about case; repositories can't have upper case at all.
    try checkPayload(arena, golden_payload, "LOCALHOST:5000/gate/app", golden_digest);

    try std.testing.expectError(error.NotAPayload, checkPayload(arena, "", golden_repository, golden_digest));
    try std.testing.expectError(error.NotAPayload, checkPayload(arena, "{}", golden_repository, golden_digest));
    try std.testing.expectError(error.NotAPayload, checkPayload(arena,
        \\{"critical":{"identity":{"docker-reference":"r"},"image":{"docker-manifest-digest":"d"},"type":"something else"}}
    , "r", "d"));
    // A field given twice mustn't let one reader see one and another the other.
    try std.testing.expectError(error.NotAPayload, checkPayload(arena,
        \\{"critical":{"identity":{"docker-reference":"r"},"image":{"docker-manifest-digest":"d","docker-manifest-digest":"e"},"type":"cosign container image signature"}}
    , "r", "e"));
}

test "keys it can't use are refused when read" {
    try std.testing.expectError(error.NotAKey, Key.parse(""));
    try std.testing.expectError(error.NotAKey, Key.parse("-----BEGIN PUBLIC KEY-----\n-----END PUBLIC KEY-----"));
    // A private key, which someone may well give it by mistake.
    try std.testing.expectError(error.NotAKey, Key.parse("-----BEGIN ENCRYPTED SIGSTORE PRIVATE KEY-----\nabcd\n-----END ENCRYPTED SIGSTORE PRIVATE KEY-----"));
    // Ed25519 in PKIX form.
    try std.testing.expectError(error.NotAKey, Key.parse(
        \\-----BEGIN PUBLIC KEY-----
        \\MCowBQYDK2VwAyEAGb9ECWmEzf6FQbrBZ9w7lshQhqowtrbLDFw4rXAxZuE=
        \\-----END PUBLIC KEY-----
    ));
    // The right form, with a point not on the curve.
    var bad = golden_key.*;
    const at = std.mem.indexOf(u8, &bad, "\n").? + 60;
    bad[at] = if (bad[at] == 'A') 'B' else 'A';
    try std.testing.expectError(error.NotAKey, Key.parse(&bad));
}

test "its tag names the digest" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings(
        "sha256-58214bd6d7325459615fb1b8d6cac46e935cd890832e0b7573da78b80d9b155b.sig",
        try tagFor(arena_state.allocator(), golden_digest),
    );
}
