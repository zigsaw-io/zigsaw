//! Signs as `cosign sign-blob` does, with a key made from a word: what tests of
//! signatures use, so that they need no cosign and no key file. Nothing in zigsaw
//! signs anything; see src/signature.zig. tests/oci.sh checks the real thing.
//!
//!   zigsaw-p256sign key <word> <file>    writes the word's public key to a file, as
//!                                        cosign.pub is
//!   zigsaw-p256sign sign <word> <file>   prints a signature of the file, in base64

const std = @import("std");
const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;

const p256_prefix = [_]u8{ 0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00 };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.log.err("usage: zigsaw-p256sign key|sign <word> <file>", .{});
        std.process.exit(2);
    }
    var seed: [Ecdsa.KeyPair.seed_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(args[2], &seed, .{});
    const pair = try Ecdsa.KeyPair.generateDeterministic(seed);
    const encoder = std.base64.standard.Encoder;

    if (std.mem.eql(u8, args[1], "key")) {
        const point = pair.public_key.toUncompressedSec1();
        const der = p256_prefix ++ point;
        var text: [encoder.calcSize(der.len)]u8 = undefined;
        const pem = try std.fmt.allocPrint(arena, "-----BEGIN PUBLIC KEY-----\n{s}\n-----END PUBLIC KEY-----\n", .{encoder.encode(&text, &der)});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[3], .data = pem });
        return;
    }
    if (std.mem.eql(u8, args[1], "sign")) {
        const message = try std.Io.Dir.cwd().readFileAlloc(io, args[3], arena, .limited(1 << 20));
        const signature = try pair.sign(message, null);
        var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
        const der = signature.toDer(&der_buf);
        const text = try arena.alloc(u8, encoder.calcSize(der.len));
        var buf: [256]u8 = undefined;
        var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
        try stdout.interface.writeAll(encoder.encode(text, der));
        try stdout.interface.flush();
        return;
    }
    std.log.err("usage: zigsaw-p256sign key|sign <word> <file>", .{});
    std.process.exit(2);
}
