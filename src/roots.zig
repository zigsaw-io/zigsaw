//! ${roots}: Windows' trusted roots in a PEM file, for the programs that only
//! take a file of them (Composer, Perl, PHP's curl, and libpq's
//! sslrootcert=system, all through SSL_CERT_FILE; docs/networking.md).
//!
//! zigsaw reads the stores as Python's ssl module does: the CA and ROOT
//! stores of each location, opened read-only, keeping what Windows trusts to
//! identify servers. It reads them itself, outside the run's sandbox, where
//! an AppContainer would see the machine's only. The file is
//! <root>\certs\roots-<hash>.pem, named by its contents like the relay's
//! copy, so a file a run reads is never replaced; `prune` deletes the
//! others. Like Python's and Java's reading of the store, it has the roots
//! Windows has: one it fetches only when its own programs check a chain
//! isn't there until then.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const win32 = @import("win32.zig");
const Context = @import("Context.zig");
const Store = @import("Store.zig");

/// The PEM file of Windows' roots as they are now, written if the store
/// hasn't it yet.
pub fn file(ctx: *Context) ![]const u8 {
    const io = ctx.io;
    const arena = ctx.arena;
    const pem = try exportPem(arena);
    const dest = try ctx.store.path(arena, &.{ "certs", try fileName(arena, pem) });
    if (try Store.exists(io, dest)) return dest;
    const tmp = try ctx.store.tmpPath(arena, "roots");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = pem });
    Io.Dir.rename(.cwd(), tmp, .cwd(), dest, io) catch |err| {
        // Another run put it there first.
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        if (!try Store.exists(io, dest)) return err;
    };
    return dest;
}

/// Deletes the store's files of roots but the one for Windows' roots as
/// they are now, as `prune` does. One a program has open stays.
pub fn prune(ctx: *Context) !void {
    const io = ctx.io;
    const arena = ctx.arena;
    const current = try fileName(arena, try exportPem(arena));
    var dir = try Io.Dir.cwd().openDir(io, try ctx.store.path(arena, &.{"certs"}), .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var stale: std.ArrayList([]const u8) = .empty;
    while (try it.next(io)) |e| {
        if (std.mem.eql(u8, e.name, current)) continue;
        try stale.append(arena, try arena.dupe(u8, e.name));
    }
    for (stale.items) |name| dir.deleteFile(io, name) catch {};
}

fn fileName(arena: Allocator, pem: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    Sha256.hash(pem, &hash, .{});
    return std.fmt.allocPrint(arena, "roots-{x}.pem", .{hash[0..8]});
}

/// The locations Python's ssl module reads (Modules/_ssl.c); one that can't
/// be opened is left out, as there.
const locations = [_]win32.DWORD{
    win32.CERT_SYSTEM_STORE_LOCAL_MACHINE_ID,
    win32.CERT_SYSTEM_STORE_LOCAL_MACHINE_ENTERPRISE_ID,
    win32.CERT_SYSTEM_STORE_LOCAL_MACHINE_GROUP_POLICY_ID,
    win32.CERT_SYSTEM_STORE_CURRENT_USER_ID,
    win32.CERT_SYSTEM_STORE_CURRENT_USER_GROUP_POLICY_ID,
    win32.CERT_SYSTEM_STORE_SERVICES_ID,
    win32.CERT_SYSTEM_STORE_USERS_ID,
};
/// The roots, and the intermediates Windows keeps, which help with a server
/// that doesn't send its whole chain.
const store_names = [_][:0]const u16{
    std.unicode.utf8ToUtf16LeStringLiteral("CA"),
    std.unicode.utf8ToUtf16LeStringLiteral("ROOT"),
};
const X509_ASN_ENCODING: win32.DWORD = 0x1;
const server_auth = "1.3.6.1.5.5.7.3.1";

const Cert = struct { hash: [32]u8, der: []const u8 };

/// Windows' certificates for servers, as PEM, in the order of their hashes:
/// the same certificates make the same file.
pub fn exportPem(arena: Allocator) ![]const u8 {
    var certs: std.ArrayList(Cert) = .empty;
    for (store_names) |name| for (locations) |location| {
        const flags = win32.CERT_STORE_READONLY_FLAG | win32.certSystemStore(location);
        const store = win32.CertOpenStore(win32.CERT_STORE_PROV_SYSTEM_W, 0, 0, flags, name.ptr) orelse continue;
        defer _ = win32.CertCloseStore(store, 0);
        var next = win32.CertEnumCertificatesInStore(store, null);
        while (next) |c| : (next = win32.CertEnumCertificatesInStore(store, c)) {
            if (c.encoding & X509_ASN_ENCODING == 0) continue;
            if (!allows(try purposes(arena, c), server_auth)) continue;
            const der = try arena.dupe(u8, c.encoded[0..c.encoded_len]);
            var hash: [32]u8 = undefined;
            Sha256.hash(der, &hash, .{});
            try certs.append(arena, .{ .hash = hash, .der = der });
        }
    };
    std.mem.sort(Cert, certs.items, {}, struct {
        fn lessThan(_: void, a: Cert, b: Cert) bool {
            return std.mem.lessThan(u8, &a.hash, &b.hash);
        }
    }.lessThan);
    var out: std.ArrayList(u8) = .empty;
    for (certs.items, 0..) |c, i| {
        if (i > 0 and std.mem.eql(u8, &certs.items[i - 1].hash, &c.hash)) continue;
        try appendPem(arena, &out, c.der);
    }
    return out.items;
}

/// One certificate in PEM, its base64 in lines of 64.
fn appendPem(arena: Allocator, out: *std.ArrayList(u8), der: []const u8) !void {
    const encoder = std.base64.standard.Encoder;
    const b64 = try arena.alloc(u8, encoder.calcSize(der.len));
    _ = encoder.encode(b64, der);
    try out.appendSlice(arena, "-----BEGIN CERTIFICATE-----\n");
    var rest = b64;
    while (rest.len > 0) {
        const n = @min(rest.len, 64);
        try out.appendSlice(arena, rest[0..n]);
        try out.append(arena, '\n');
        rest = rest[n..];
    }
    try out.appendSlice(arena, "-----END CERTIFICATE-----\n");
}

/// What a certificate is trusted for: any purpose, or those listed.
pub const Purposes = union(enum) { any, only: []const []const u8 };

pub fn allows(p: Purposes, purpose: []const u8) bool {
    return switch (p) {
        .any => true,
        .only => |oids| for (oids) |oid| {
            if (std.mem.eql(u8, oid, purpose)) break true;
        } else false,
    };
}

/// What Windows trusts a certificate for, as Python decides: the purposes
/// the store gives it, or, if the store allows it any, those its extension
/// names. A certificate Windows can't say this of is trusted for nothing.
fn purposes(arena: Allocator, cert: *const win32.CERT_CONTEXT) !Purposes {
    const property = try usage(arena, cert, win32.CERT_FIND_PROP_ONLY_ENHKEY_USAGE_FLAG);
    return switch (property) {
        .any => try usage(arena, cert, win32.CERT_FIND_EXT_ONLY_ENHKEY_USAGE_FLAG),
        .only => property,
    };
}

/// CertGetEnhancedKeyUsage: no usage found means any purpose.
fn usage(arena: Allocator, cert: *const win32.CERT_CONTEXT, flags: win32.DWORD) !Purposes {
    var size: win32.DWORD = 0;
    if (win32.CertGetEnhancedKeyUsage(cert, flags, null, &size) == 0) return noUsage();
    const buf = try arena.alignedAlloc(u8, .of(win32.CERT_ENHKEY_USAGE), size);
    const u: *win32.CERT_ENHKEY_USAGE = @ptrCast(buf.ptr);
    if (win32.CertGetEnhancedKeyUsage(cert, flags, u, &size) == 0) return noUsage();
    // None listed: any purpose if Windows found no usage, else none.
    if (u.count == 0) return noUsage();
    const oids = try arena.alloc([]const u8, u.count);
    for (oids, u.identifiers.?[0..u.count]) |*o, id| o.* = std.mem.span(id);
    return .{ .only = oids };
}

fn noUsage() Purposes {
    return if (win32.GetLastError() == win32.CRYPT_E_NOT_FOUND) .any else .{ .only = &.{} };
}

test "server authentication is allowed by any purpose, or by its own" {
    try std.testing.expect(allows(.any, server_auth));
    try std.testing.expect(allows(.{ .only = &.{ "1.3.6.1.5.5.7.3.2", server_auth } }, server_auth));
    try std.testing.expect(!allows(.{ .only = &.{"1.3.6.1.5.5.7.3.3"} }, server_auth));
    try std.testing.expect(!allows(.{ .only = &.{} }, server_auth));
}

test "Windows' roots export as PEM that zig's std reads back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pem = try exportPem(arena);
    try std.testing.expect(std.mem.startsWith(u8, pem, "-----BEGIN CERTIFICATE-----\n"));
    try std.testing.expect(std.mem.endsWith(u8, pem, "-----END CERTIFICATE-----\n"));
    // The same file each time.
    try std.testing.expectEqualStrings(pem, try exportPem(arena));
    // Each certificate parses, and they're all different.
    var count: usize = 0;
    var it = std.mem.splitSequence(u8, pem, "-----END CERTIFICATE-----\n");
    while (it.next()) |block| {
        if (block.len == 0) continue;
        const b64 = try std.mem.replaceOwned(u8, arena, block["-----BEGIN CERTIFICATE-----\n".len..], "\n", "");
        const der = try arena.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(b64));
        try std.base64.standard.Decoder.decode(der, b64);
        _ = try std.crypto.Certificate.parse(.{ .buffer = der, .index = 0 });
        count += 1;
    }
    try std.testing.expect(count > 0);
}
