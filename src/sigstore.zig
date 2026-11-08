//! Keyless signatures, as Sigstore makes them: a bundle, as `cosign sign-blob
//! --bundle` writes one, holds a signature of a file, the short-lived certificate
//! whose key made it, and the entry of that signature in Rekor's log, with the log's
//! promise of when it was entered. The certificate is Fulcio's, and names who signed:
//! for GitHub Actions, the workflow, at the branch or tag it ran on.
//!
//! What's checked, all offline, against a trusted root built in (sigstore-root.json,
//! as Sigstore's TUF repository hands it out):
//! - the log's promise is signed by a Rekor key the root has, and its time is one the
//!   key was good for;
//! - the certificate chains to a Fulcio authority the root has, at that time, which
//!   also says the certificate hadn't expired when the file was signed;
//! - the certificate names the workflow and issuer wanted, and is for code signing;
//! - its key signed the file, and the log's entry names the same file, signature and
//!   certificate.
//! Only Rekor v1's entries carry a promise with a time: an entry in a Rekor v2 log
//! needs a timestamp authority besides, which zigsaw doesn't check, so it isn't
//! taken.
//!
//! No files or network here: see remote.zig for images, upgrade.zig for releases, and
//! trust.zig for whose signatures count.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Certificate = std.crypto.Certificate;
const der = Certificate.der;
const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const signature = @import("signature.zig");
const options = @import("options");

/// What a bundle is, as an OCI layer.
pub const bundle_media_type = "application/vnd.dev.sigstore.bundle.v0.3+json";
/// A bundle is a certificate, a signature and a log entry: a few kilobytes.
pub const max_bundle_size = 64 * 1024;
/// Who vouches for a GitHub Actions workflow's certificate.
pub const github_issuer = "https://token.actions.githubusercontent.com";

/// Sigstore's own trusted root, and a test's if zigsaw was built with one.
const built_in_root = @embedFile("sigstore-root.json");

/// Who must have signed: the certificate's subject alternative name (a workflow's
/// URI, for GitHub Actions) and the issuer of the identity behind it.
pub const Identity = struct {
    issuer: []const u8,
    san: []const u8,
};

/// Whether a bundle is a good signature of a file by an identity, and if not, why
/// not, in words that finish "the signature isn't good: ...".
pub const Verdict = union(enum) {
    good,
    bad: []const u8,
};

/// When a key or an authority was good: seconds since 1970, the end open if none.
const Window = struct {
    start: i64,
    end: ?i64,

    fn contains(w: Window, t: i64) bool {
        return t >= w.start and (w.end == null or t <= w.end.?);
    }
};

const Log = struct {
    key: Ecdsa.PublicKey,
    /// SHA-256 of the key's DER: how an entry names its log.
    id: [32]u8,
    window: Window,
};

const Authority = struct {
    /// DER, from the one that issues certificates up to the root.
    chain: []const []const u8,
    window: Window,
};

pub const TrustRoot = struct {
    logs: []const Log,
    authorities: []const Authority,
};

/// The trusted roots zigsaw has: Sigstore's, and the one a test build adds.
pub fn trustRoots(arena: Allocator) ![]const TrustRoot {
    var roots: std.ArrayList(TrustRoot) = .empty;
    try roots.append(arena, parseTrustRoot(arena, built_in_root) catch unreachable); // A test sees to that.
    if (options.sigstore_test_root.len > 0)
        try roots.append(arena, parseTrustRoot(arena, options.sigstore_test_root) catch @panic("-Dsigstore-test-root isn't a trusted root"));
    return roots.items;
}

/// Reads a trusted root as Sigstore's TUF repository has it. Of its logs, only Rekor
/// v1's (ECDSA P-256) are kept; of its authorities, all.
pub fn parseTrustRoot(arena: Allocator, json: []const u8) error{ NotATrustRoot, OutOfMemory }!TrustRoot {
    const ValidFor = struct { start: []const u8, end: ?[]const u8 = null };
    const Raw = struct {
        tlogs: []const struct {
            publicKey: struct { rawBytes: []const u8, keyDetails: []const u8, validFor: ValidFor },
            logId: struct { keyId: []const u8 },
        } = &.{},
        certificateAuthorities: []const struct {
            certChain: struct { certificates: []const struct { rawBytes: []const u8 } },
            validFor: ValidFor,
        } = &.{},
    };
    const raw = std.json.parseFromSliceLeaky(Raw, arena, json, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.NotATrustRoot,
    };
    const window = struct {
        fn of(v: ValidFor) error{NotATrustRoot}!Window {
            return .{
                .start = parseTime(v.start) orelse return error.NotATrustRoot,
                .end = if (v.end) |e| parseTime(e) orelse return error.NotATrustRoot else null,
            };
        }
    }.of;

    var logs: std.ArrayList(Log) = .empty;
    for (raw.tlogs) |t| {
        if (!std.mem.eql(u8, t.publicKey.keyDetails, "PKIX_ECDSA_P256_SHA_256")) continue;
        const key_der = try decode(arena, t.publicKey.rawBytes) orelse return error.NotATrustRoot;
        if (key_der.len != signature.p256_prefix.len + 65 or !std.mem.startsWith(u8, key_der, &signature.p256_prefix)) return error.NotATrustRoot;
        var id: [32]u8 = undefined;
        Sha256.hash(key_der, &id, .{});
        const named = try decode(arena, t.logId.keyId) orelse return error.NotATrustRoot;
        if (!std.mem.eql(u8, named, &id)) return error.NotATrustRoot;
        try logs.append(arena, .{
            .key = Ecdsa.PublicKey.fromSec1(key_der[signature.p256_prefix.len..]) catch return error.NotATrustRoot,
            .id = id,
            .window = try window(t.publicKey.validFor),
        });
    }
    var authorities: std.ArrayList(Authority) = .empty;
    for (raw.certificateAuthorities) |a| {
        var chain: std.ArrayList([]const u8) = .empty;
        for (a.certChain.certificates) |c| try chain.append(arena, try decode(arena, c.rawBytes) orelse return error.NotATrustRoot);
        if (chain.items.len == 0) return error.NotATrustRoot;
        for (chain.items) |c| _ = Certificate.parse(.{ .buffer = c, .index = 0 }) catch return error.NotATrustRoot;
        try authorities.append(arena, .{ .chain = chain.items, .window = try window(a.validFor) });
    }
    return .{ .logs = logs.items, .authorities = authorities.items };
}

/// Whether `bundle` is a good signature of `blob` by `identity`, as one of `roots`
/// vouches for.
pub fn verify(arena: Allocator, roots: []const TrustRoot, bundle: []const u8, blob: []const u8, identity: Identity) Allocator.Error!Verdict {
    const Entry = struct {
        logIndex: std.json.Value,
        logId: struct { keyId: []const u8 },
        kindVersion: struct { kind: []const u8, version: []const u8 },
        integratedTime: std.json.Value = .null,
        inclusionPromise: ?struct { signedEntryTimestamp: []const u8 } = null,
        canonicalizedBody: []const u8,
    };
    const Raw = struct {
        mediaType: []const u8,
        verificationMaterial: struct {
            certificate: ?struct { rawBytes: []const u8 } = null,
            x509CertificateChain: ?struct { certificates: []const struct { rawBytes: []const u8 } } = null,
            tlogEntries: []const Entry = &.{},
        },
        messageSignature: ?struct {
            messageDigest: ?struct { algorithm: []const u8, digest: []const u8 } = null,
            signature: []const u8,
        } = null,
    };
    const raw = std.json.parseFromSliceLeaky(Raw, arena, bundle, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return bad("it isn't a Sigstore bundle"),
    };
    if (!std.mem.startsWith(u8, raw.mediaType, "application/vnd.dev.sigstore.bundle")) return bad("it isn't a Sigstore bundle");
    const message = raw.messageSignature orelse return bad("it signs an envelope, not the file itself");
    const sig_der = try decode(arena, message.signature) orelse return bad("its signature isn't base64");

    var digest: [32]u8 = undefined;
    Sha256.hash(blob, &digest, .{});
    if (message.messageDigest) |d| {
        const named = try decode(arena, d.digest) orelse return bad("its digest isn't base64");
        if (!std.mem.eql(u8, d.algorithm, "SHA2_256") or !std.mem.eql(u8, named, &digest)) return bad("it's a signature of another file");
    }

    const cert_text = if (raw.verificationMaterial.certificate) |c|
        c.rawBytes
    else if (raw.verificationMaterial.x509CertificateChain) |chain| (if (chain.certificates.len > 0) chain.certificates[0].rawBytes else return bad("it has no certificate")) else return bad("it has no certificate: it was signed with a key, not keyless");
    const leaf_der = try decode(arena, cert_text) orelse return bad("its certificate isn't base64");

    // The entry, in a log one of the roots has.
    var found: ?struct { entry: Entry, log: Log, root: TrustRoot } = null;
    var any_v2 = false;
    search: for (raw.verificationMaterial.tlogEntries) |entry| {
        if (!std.mem.eql(u8, entry.kindVersion.kind, "hashedrekord")) continue;
        if (!std.mem.eql(u8, entry.kindVersion.version, "0.0.1")) {
            any_v2 = true;
            continue;
        }
        const id = try decode(arena, entry.logId.keyId) orelse continue;
        for (roots) |root| for (root.logs) |log| if (std.mem.eql(u8, id, &log.id)) {
            found = .{ .entry = entry, .log = log, .root = root };
            break :search;
        };
    }
    const at = found orelse return bad(if (any_v2)
        "it's logged in a Rekor v2 log, whose entries zigsaw can't check yet"
    else if (raw.verificationMaterial.tlogEntries.len == 0)
        "it isn't logged in Rekor"
    else
        "it's logged in a log zigsaw doesn't know");
    const entry = at.entry;

    // The log's promise: that it entered this body, at this time.
    const time = jsonInt(entry.integratedTime) orelse return bad("its log entry has no time");
    const index = jsonInt(entry.logIndex) orelse return bad("its log entry has no index");
    if (!at.log.window.contains(time)) return bad("its log entry is from a time the log's key wasn't good for");
    const promise = entry.inclusionPromise orelse return bad("its log entry has no promise from the log");
    const promised = try std.fmt.allocPrint(arena, "{{\"body\":\"{s}\",\"integratedTime\":{d},\"logID\":\"{s}\",\"logIndex\":{d}}}", .{
        entry.canonicalizedBody, time, std.fmt.bytesToHex(at.log.id, .lower), index,
    });
    const promise_der = try decode(arena, promise.signedEntryTimestamp) orelse return bad("its log's promise isn't base64");
    if (!verifiesDer(promise_der, promised, at.log.key)) return bad("its log's promise isn't the log's");

    // What the log entered: this file, this signature, this certificate.
    const Body = struct {
        kind: []const u8,
        apiVersion: []const u8,
        spec: struct {
            data: struct { hash: struct { algorithm: []const u8, value: []const u8 } },
            signature: struct { content: []const u8, publicKey: struct { content: []const u8 } },
        },
    };
    const body_json = try decode(arena, entry.canonicalizedBody) orelse return bad("its log entry isn't base64");
    const body = std.json.parseFromSliceLeaky(Body, arena, body_json, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return bad("its log entry isn't a hashedrekord"),
    };
    if (!std.mem.eql(u8, body.kind, "hashedrekord") or !std.mem.eql(u8, body.apiVersion, "0.0.1")) return bad("its log entry isn't a hashedrekord");
    if (!std.mem.eql(u8, body.spec.data.hash.algorithm, "sha256") or
        !std.ascii.eqlIgnoreCase(body.spec.data.hash.value, &std.fmt.bytesToHex(digest, .lower)))
        return bad("it's a signature of another file");
    const logged_sig = try decode(arena, body.spec.signature.content) orelse return bad("its log entry's signature isn't base64");
    if (!std.mem.eql(u8, logged_sig, sig_der)) return bad("its log entry is of another signature");
    const logged_pem = try decode(arena, body.spec.signature.publicKey.content) orelse return bad("its log entry's certificate isn't base64");
    const logged_cert = try pemCertificate(arena, logged_pem) orelse return bad("its log entry's certificate isn't one");
    if (!std.mem.eql(u8, logged_cert, leaf_der)) return bad("its log entry is of another certificate");

    // The certificate: Fulcio's, then, for code signing, and whose.
    const leaf = Certificate.parse(.{ .buffer = leaf_der, .index = 0 }) catch return bad("its certificate isn't one zigsaw can read");
    const chained = for (at.root.authorities) |authority| {
        if (!authority.window.contains(time)) continue;
        if (chainVerifies(leaf, authority.chain, time)) break true;
    } else false;
    if (!chained) return bad("its certificate isn't from a Fulcio zigsaw knows, or wasn't good when it was signed");
    switch (leaf.pub_key_algo) {
        .X9_62_id_ecPublicKey => |curve| if (curve != .X9_62_prime256v1) return bad("its certificate's key isn't P-256"),
        else => return bad("its certificate's key isn't P-256"),
    }
    const leaf_key = Ecdsa.PublicKey.fromSec1(leaf.pubKey()) catch return bad("its certificate's key isn't P-256");
    if (!verifiesDer(sig_der, blob, leaf_key)) return bad("it's a signature of another file");

    const named = readExtensions(leaf_der) catch return bad("its certificate isn't one zigsaw can read");
    if (!named.code_signing) return bad("its certificate isn't for code signing");
    const san = named.san orelse return bad("its certificate names nobody");
    const issuer = named.issuer orelse return bad("its certificate doesn't say who vouched for its signer");
    if (!std.mem.eql(u8, issuer, identity.issuer))
        return bad(try std.fmt.allocPrint(arena, "it's vouched for by {s}, not {s}", .{ issuer, identity.issuer }));
    if (!std.mem.eql(u8, san, identity.san))
        return bad(try std.fmt.allocPrint(arena, "it's signed by {s}, not {s}", .{ san, identity.san }));
    return .good;
}

fn bad(why: []const u8) Verdict {
    return .{ .bad = why };
}

fn verifiesDer(sig_der: []const u8, message: []const u8, key: Ecdsa.PublicKey) bool {
    const parsed = Ecdsa.Signature.fromDer(sig_der) catch return false;
    parsed.verify(message, key) catch return false;
    return true;
}

/// Whether `leaf` was issued by the first of `chain`, each by the next, all at `time`.
/// The last is the root, trusted as it is.
fn chainVerifies(leaf: Certificate.Parsed, chain: []const []const u8, time: i64) bool {
    var subject = leaf;
    for (chain) |issuer_der| {
        const issuer = Certificate.parse(.{ .buffer = issuer_der, .index = 0 }) catch return false;
        subject.verify(issuer, time) catch return false;
        subject = issuer;
    }
    return true;
}

const Named = struct {
    san: ?[]const u8 = null,
    issuer: ?[]const u8 = null,
    code_signing: bool = false,
};

const oid_san = [_]u8{ 0x55, 0x1d, 0x11 };
const oid_eku = [_]u8{ 0x55, 0x1d, 0x25 };
const oid_code_signing = [_]u8{ 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x03 };
/// Fulcio's extensions are under 1.3.6.1.4.1.57264.1: .8 is the issuer as a DER
/// string, .1 the same as bare bytes, from before .8.
const oid_fulcio = [_]u8{ 0x2b, 0x06, 0x01, 0x04, 0x01, 0x83, 0xbf, 0x30, 0x01 };

/// The certificate's subject alternative name (a URI, or else an email address),
/// Fulcio's issuer extension, and whether it's for code signing. std's parser skips
/// all of these but the first, which it doesn't take apart.
fn readExtensions(bytes: []const u8) !Named {
    var named: Named = .{};
    const cert = try element(bytes, 0, bytes.len);
    const tbs = try element(bytes, cert.slice.start, cert.slice.end);
    var i: usize = tbs.slice.start;
    const extensions = while (i < tbs.slice.end) {
        const e = try element(bytes, i, tbs.slice.end);
        i = e.slice.end;
        if (e.identifier.class == .context_specific and @backingInt(e.identifier.tag) == 3) break e;
    } else return named;
    const list = try element(bytes, extensions.slice.start, extensions.slice.end);
    i = list.slice.start;
    while (i < list.slice.end) {
        const ext = try element(bytes, i, list.slice.end);
        i = ext.slice.end;
        const oid = try element(bytes, ext.slice.start, ext.slice.end);
        var next = try element(bytes, oid.slice.end, ext.slice.end);
        if (next.identifier.tag == .boolean) next = try element(bytes, next.slice.end, ext.slice.end);
        if (next.identifier.tag != .octetstring) return error.NotACertificate;
        const id = bytes[oid.slice.start..oid.slice.end];
        const value = bytes[next.slice.start..next.slice.end];
        if (std.mem.eql(u8, id, &oid_san)) {
            named.san = try readSan(value);
        } else if (std.mem.eql(u8, id, &oid_eku)) {
            const seq = try element(value, 0, value.len);
            var j: usize = seq.slice.start;
            while (j < seq.slice.end) {
                const purpose = try element(value, j, seq.slice.end);
                j = purpose.slice.end;
                if (std.mem.eql(u8, value[purpose.slice.start..purpose.slice.end], &oid_code_signing)) named.code_signing = true;
            }
        } else if (id.len == oid_fulcio.len + 1 and std.mem.startsWith(u8, id, &oid_fulcio)) {
            switch (id[oid_fulcio.len]) {
                8 => {
                    const s = try element(value, 0, value.len);
                    named.issuer = value[s.slice.start..s.slice.end];
                },
                1 => if (named.issuer == null) {
                    named.issuer = value;
                },
                else => {},
            }
        }
    }
    return named;
}

fn readSan(value: []const u8) !?[]const u8 {
    const names = try element(value, 0, value.len);
    var j: usize = names.slice.start;
    var email: ?[]const u8 = null;
    while (j < names.slice.end) {
        const name = try element(value, j, names.slice.end);
        j = name.slice.end;
        if (name.identifier.class != .context_specific) continue;
        switch (@backingInt(name.identifier.tag)) {
            6 => return value[name.slice.start..name.slice.end], // uniformResourceIdentifier
            1 => email = value[name.slice.start..name.slice.end], // rfc822Name
            else => {},
        }
    }
    return email;
}

/// A DER element at `i`, which must end by `end`: std's parser takes the length as
/// it comes, and this is a certificate from anyone.
fn element(bytes: []const u8, i: usize, end: usize) !der.Element {
    if (end > bytes.len or i + 2 > end) return error.NotACertificate;
    // A long form's length bytes, which std's parser reads without looking.
    if (bytes[i + 1] & 0x80 != 0 and i + 2 + (bytes[i + 1] & 0x7f) > end) return error.NotACertificate;
    const e = der.Element.parse(bytes[0..end], @intCast(i)) catch return error.NotACertificate;
    if (e.slice.start > end or e.slice.end > end or e.slice.end < e.slice.start) return error.NotACertificate;
    return e;
}

/// The DER of the one certificate in a PEM text.
fn pemCertificate(arena: Allocator, pem: []const u8) !?[]const u8 {
    const begin = "-----BEGIN CERTIFICATE-----";
    const end = "-----END CERTIFICATE-----";
    const trimmed = std.mem.trim(u8, pem, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, begin) or !std.mem.endsWith(u8, trimmed, end) or trimmed.len < begin.len + end.len) return null;
    var text: std.ArrayList(u8) = .empty;
    for (trimmed[begin.len .. trimmed.len - end.len]) |c| if (c != '\r' and c != '\n') try text.append(arena, c);
    return decode(arena, text.items);
}

fn decode(arena: Allocator, text: []const u8) !?[]const u8 {
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(text) catch return null;
    const buf = try arena.alloc(u8, size);
    decoder.decode(buf, text) catch return null;
    return buf;
}

/// A JSON integer, which a bundle may write as a string, as protobuf's JSON does
/// with 64-bit ones.
fn jsonInt(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |n| n,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// Seconds since 1970 of an RFC 3339 time in UTC, as a trusted root writes them:
/// 2021-01-12T11:53:27Z, or with fractions of a second, which are dropped.
fn parseTime(text: []const u8) ?i64 {
    if (text.len < 20 or text[4] != '-' or text[7] != '-' or text[10] != 'T' or text[13] != ':' or text[16] != ':' or text[text.len - 1] != 'Z') return null;
    if (text.len > 20 and text[19] != '.') return null;
    const n = struct {
        fn of(s: []const u8) ?i64 {
            return std.fmt.parseInt(i64, s, 10) catch null;
        }
    }.of;
    const y = n(text[0..4]) orelse return null;
    const m = n(text[5..7]) orelse return null;
    const d = n(text[8..10]) orelse return null;
    const hh = n(text[11..13]) orelse return null;
    const mm = n(text[14..16]) orelse return null;
    const ss = n(text[17..19]) orelse return null;
    if (m < 1 or m > 12 or d < 1 or d > 31 or hh > 23 or mm > 59 or ss > 60) return null;
    // Days from 1970-01-01 to the date (Howard Hinnant's days_from_civil).
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + hh * 3600 + mm * 60 + ss;
}

// --- Tests -------------------------------------------------------------------------

const testing = std.testing;
const fake_root = @embedFile("testdata/sigstore/fake/root.json");
const fake_blob = @embedFile("testdata/sigstore/fake/blob");
const fake_bundle = @embedFile("testdata/sigstore/fake/bundle.json");
const fake_late = @embedFile("testdata/sigstore/fake/late.json");
const fake_gitlab = @embedFile("testdata/sigstore/fake/gitlab.json");
const reproduce_main: Identity = .{
    .issuer = github_issuer,
    .san = "https://github.com/zigsaw-io/zigsaw/.github/workflows/reproduce.yml@refs/heads/main",
};

fn expectBad(verdict: Verdict, why: []const u8) !void {
    switch (verdict) {
        .good => return error.TestExpectedBad,
        .bad => |got| testing.expect(std.mem.indexOf(u8, got, why) != null) catch |err| {
            std.debug.print("expected \"{s}\" in \"{s}\"\n", .{ why, got });
            return err;
        },
    }
}

test "Sigstore's trusted root, as built in, has Rekor v1's key and Fulcio" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try parseTrustRoot(arena.allocator(), built_in_root);
    try testing.expect(root.logs.len >= 1);
    try testing.expect(root.authorities.len >= 1);
    // rekor.sigstore.dev's, since 2021.
    try testing.expectEqualStrings("c0d23d6ad406973f9559f3ba2d1ca01f84147d8ffc5b8445c224f98b9591801d", &std.fmt.bytesToHex(root.logs[0].id, .lower));
}

test "a bundle made as cosign makes one, by a fake Sigstore, is good" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const roots = &.{try parseTrustRoot(a, fake_root)};
    try testing.expectEqual(Verdict.good, try verify(a, roots, fake_bundle, fake_blob, reproduce_main));
}

test "a bundle isn't good for another file, workflow, branch or issuer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const roots = &.{try parseTrustRoot(a, fake_root)};
    try expectBad(try verify(a, roots, fake_bundle, "another file\n", reproduce_main), "another file");
    try expectBad(try verify(a, roots, fake_bundle, fake_blob, .{
        .issuer = github_issuer,
        .san = "https://github.com/zigsaw-io/zigsaw/.github/workflows/release.yml@refs/tags/v0.81.0",
    }), "it's signed by https://github.com/zigsaw-io/zigsaw/.github/workflows/reproduce.yml@refs/heads/main, not");
    try expectBad(try verify(a, roots, fake_bundle, fake_blob, .{
        .issuer = github_issuer,
        .san = "https://github.com/zigsaw-io/zigsaw/.github/workflows/reproduce.yml@refs/heads/other",
    }), "not https://github.com/zigsaw-io/zigsaw/.github/workflows/reproduce.yml@refs/heads/other");
    try expectBad(try verify(a, roots, fake_gitlab, fake_blob, reproduce_main), "vouched for by https://gitlab.com");
}

test "a bundle isn't good unless the root has its log and its authority" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Sigstore's root has neither the fake log nor the fake Fulcio.
    const sigstore = &.{try parseTrustRoot(a, built_in_root)};
    try expectBad(try verify(a, sigstore, fake_bundle, fake_blob, reproduce_main), "a log zigsaw doesn't know");
    // The fake log, with Sigstore's authorities.
    const fake = try parseTrustRoot(a, fake_root);
    const mixed = &.{TrustRoot{ .logs = fake.logs, .authorities = sigstore[0].authorities }};
    try expectBad(try verify(a, mixed, fake_bundle, fake_blob, reproduce_main), "isn't from a Fulcio zigsaw knows");
}

test "a bundle isn't good if its certificate had expired when it was logged" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const roots = &.{try parseTrustRoot(a, fake_root)};
    try expectBad(try verify(a, roots, fake_late, fake_blob, reproduce_main), "wasn't good when it was signed");
}

test "a bundle with anything changed isn't good" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const roots = &.{try parseTrustRoot(a, fake_root)};
    const Raw = struct {
        verificationMaterial: struct { tlogEntries: []const struct {
            integratedTime: []const u8,
            inclusionPromise: struct { signedEntryTimestamp: []const u8 },
            canonicalizedBody: []const u8,
        } },
        messageSignature: struct { signature: []const u8 },
    };
    const raw = try std.json.parseFromSliceLeaky(Raw, a, fake_bundle, .{ .ignore_unknown_fields = true });
    const entry = raw.verificationMaterial.tlogEntries[0];
    const cases = [_]struct { what: []const u8, why: []const u8 }{
        .{ .what = entry.inclusionPromise.signedEntryTimestamp, .why = "promise" },
        .{ .what = entry.canonicalizedBody, .why = "promise isn't the log's" },
        .{ .what = raw.messageSignature.signature, .why = "log entry is of another signature" },
    };
    for (cases) |case| {
        // The same text with one base64 character in its middle changed.
        const changed = try a.dupe(u8, case.what);
        const at = changed.len / 2;
        changed[at] = if (changed[at] == 'A') 'B' else 'A';
        const tampered = try std.mem.replaceOwned(u8, a, fake_bundle, case.what, changed);
        try expectBad(try verify(a, roots, tampered, fake_blob, reproduce_main), case.why);
    }
    // Another time: the promise was for the one it had.
    const later = try std.fmt.allocPrint(a, "\"integratedTime\":\"{d}\"", .{(std.fmt.parseInt(i64, entry.integratedTime, 10) catch unreachable) + 1});
    const moved = try std.mem.replaceOwned(u8, a, fake_bundle, try std.fmt.allocPrint(a, "\"integratedTime\":\"{s}\"", .{entry.integratedTime}), later);
    try expectBad(try verify(a, roots, moved, fake_blob, reproduce_main), "promise isn't the log's");
}

// Made by iteration 81's probe on a GitHub runner: `cosign sign-blob --yes --bundle`,
// keyless, cosign 3.1.4, against Sigstore's public instance, 2026-11-08; stock
// `cosign verify-blob` said "Verified OK" to both there.
const real_blob = @embedFile("testdata/sigstore/real/blob");
const real_blob_bundle = @embedFile("testdata/sigstore/real/blob.bundle.json");
const real_payload = @embedFile("testdata/sigstore/real/payload.json");
const real_payload_bundle = @embedFile("testdata/sigstore/real/payload.json.bundle.json");
const probe: Identity = .{
    .issuer = github_issuer,
    .san = "https://github.com/zigsaw-io/zigsaw/.github/workflows/sigstore-probe.yml@refs/heads/probe/sigstore",
};

test "real bundles from Sigstore's public instance are good, against the root built in" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const roots = &.{try parseTrustRoot(a, built_in_root)};
    try testing.expectEqual(Verdict.good, try verify(a, roots, real_blob_bundle, real_blob, probe));
    // An image's payload, as `zigsaw signature payload` printed it, with no newline.
    try testing.expectEqual(Verdict.good, try verify(a, roots, real_payload_bundle, real_payload, probe));
}

test "real bundles aren't good for anything else" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const roots = &.{try parseTrustRoot(a, built_in_root)};
    // The workflow that signs images, which isn't the probe.
    try expectBad(try verify(a, roots, real_payload_bundle, real_payload, reproduce_main), "it's signed by https://github.com/zigsaw-io/zigsaw/.github/workflows/sigstore-probe.yml@refs/heads/probe/sigstore, not");
    try expectBad(try verify(a, roots, real_blob_bundle, real_payload, probe), "another file");
    try expectBad(try verify(a, roots, real_payload_bundle, real_blob, probe), "another file");
    // Only a fake root: neither its log nor its authority.
    try expectBad(try verify(a, &.{try parseTrustRoot(a, fake_root)}, real_blob_bundle, real_blob, probe), "a log zigsaw doesn't know");
    // The log's promise, changed.
    const Raw = struct { verificationMaterial: struct { tlogEntries: []const struct { inclusionPromise: struct { signedEntryTimestamp: []const u8 } } } };
    const raw = try std.json.parseFromSliceLeaky(Raw, a, real_blob_bundle, .{ .ignore_unknown_fields = true });
    const set = raw.verificationMaterial.tlogEntries[0].inclusionPromise.signedEntryTimestamp;
    const changed = try a.dupe(u8, set);
    changed[changed.len / 2] = if (changed[changed.len / 2] == 'A') 'B' else 'A';
    try expectBad(try verify(a, roots, try std.mem.replaceOwned(u8, a, real_blob_bundle, set, changed), real_blob, probe), "promise isn't the log's");
}

test "a certificate's lengths that run past it are an error, not a crash" {
    // A sequence whose long-form length says 4 bytes follow, and only 1 does.
    try testing.expectError(error.NotACertificate, readExtensions(&.{ 0x30, 0x84, 0x01 }));
    // A length past the end.
    try testing.expectError(error.NotACertificate, readExtensions(&.{ 0x30, 0x05, 0x30, 0x00 }));
    try testing.expectError(error.NotACertificate, readExtensions(&.{0x30}));
    try testing.expectError(error.NotACertificate, readExtensions(""));
}

test "what isn't a bundle, or is one zigsaw can't check, says so" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const roots = &.{try parseTrustRoot(a, fake_root)};
    try expectBad(try verify(a, roots, "nope", fake_blob, reproduce_main), "isn't a Sigstore bundle");
    try expectBad(try verify(a, roots, "{\"mediaType\":\"x\",\"verificationMaterial\":{}}", fake_blob, reproduce_main), "isn't a Sigstore bundle");
    const v2 = try std.mem.replaceOwned(u8, a, fake_bundle, "\"version\":\"0.0.1\"", "\"version\":\"0.0.2\"");
    try expectBad(try verify(a, roots, v2, fake_blob, reproduce_main), "Rekor v2");
    const unlogged = try std.mem.replaceOwned(u8, a, fake_bundle, "\"kind\":\"hashedrekord\"", "\"kind\":\"dsse\"");
    try expectBad(try verify(a, roots, unlogged, fake_blob, reproduce_main), "a log zigsaw doesn't know");
}

test "times as a trusted root writes them" {
    try testing.expectEqual(@as(?i64, 0), parseTime("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(?i64, 1610452407), parseTime("2021-01-12T11:53:27Z"));
    try testing.expectEqual(@as(?i64, 1672531199), parseTime("2022-12-31T23:59:59.999Z"));
    try testing.expectEqual(@as(?i64, 1709210096), parseTime("2024-02-29T12:34:56Z"));
    try testing.expectEqual(@as(?i64, null), parseTime("2021-01-12 11:53:27Z"));
    try testing.expectEqual(@as(?i64, null), parseTime("2021-13-12T11:53:27Z"));
}
