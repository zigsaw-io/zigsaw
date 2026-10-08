//! zigsaw-imports FILE...: checks that the loader binds every import of
//! each PE file. A slot in the import address table that no import
//! descriptor's list reaches keeps what the linker put there (the import's
//! hint/name RVA), and the program crashes when it calls through it. GNU ld
//! lays out llvm-dlltool's import libraries that way (docs/iteration-12.md).
//!
//! Prints "<file>: <n> imports, <m> unbound" for each, and exits 1 if any
//! file has unbound imports, or is a PE file it can't read. Files that
//! aren't PE files are skipped. See tests/build.sh, tests/published.sh and
//! tests/gtk.sh.

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    if (args.len < 2) {
        try out.print("usage: zigsaw-imports FILE...\n", .{});
        try out.flush();
        return 2;
    }
    var failed = false;
    for (args[1..]) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(1 << 30)) catch |err| {
            try out.print("{s}: {t}\n", .{ path, err });
            failed = true;
            continue;
        };
        // Such as an import library named like a DLL (libpng's lib\libpng.dll).
        if (!std.mem.startsWith(u8, bytes, "MZ")) {
            try out.print("{s}: not a PE file, skipped\n", .{path});
            continue;
        }
        const c = count(bytes) catch |err| {
            try out.print("{s}: not a PE file with imports we can read ({t})\n", .{ path, err });
            failed = true;
            continue;
        };
        try out.print("{s}: {d} imports, {d} unbound\n", .{ path, c.bound, c.unbound });
        if (c.unbound > 0) failed = true;
    }
    try out.flush();
    return @intFromBool(failed);
}

const Counts = struct { bound: usize, unbound: usize };

const Image = struct {
    bytes: []const u8,
    sections: []const u8,
    section_count: u16,
    /// 8 in PE32+, 4 in PE32.
    thunk: u32,

    fn u(img: Image, comptime T: type, offset: usize) !T {
        if (offset + @sizeOf(T) > img.bytes.len) return error.Truncated;
        return std.mem.readInt(T, img.bytes[offset..][0..@sizeOf(T)], .little);
    }

    /// The file offset of an RVA, through the section that holds it.
    fn offsetOf(img: Image, rva: u32) !usize {
        var i: usize = 0;
        while (i < img.section_count) : (i += 1) {
            const s = img.sections[i * 40 ..][0..40];
            const size = @max(std.mem.readInt(u32, s[8..12], .little), std.mem.readInt(u32, s[16..20], .little));
            const va = std.mem.readInt(u32, s[12..16], .little);
            if (rva >= va and rva < va + size) return std.mem.readInt(u32, s[20..24], .little) + (rva - va);
        }
        return error.RvaOutsideSections;
    }

    fn slot(img: Image, rva: u32) !u64 {
        const off = try img.offsetOf(rva);
        return if (img.thunk == 8) img.u(u64, off) else try img.u(u32, off);
    }
};

fn count(bytes: []const u8) !Counts {
    if (bytes.len < 64 or !std.mem.eql(u8, bytes[0..2], "MZ")) return error.NotPe;
    const nt = std.mem.readInt(u32, bytes[0x3c..0x40], .little);
    if (nt + 24 > bytes.len or !std.mem.eql(u8, bytes[nt..][0..4], "PE\x00\x00")) return error.NotPe;
    const file_header = nt + 4;
    const section_count = std.mem.readInt(u16, bytes[file_header + 2 ..][0..2], .little);
    const optional_size = std.mem.readInt(u16, bytes[file_header + 16 ..][0..2], .little);
    const optional = file_header + 20;
    const sections_at = optional + optional_size;
    if (sections_at + @as(usize, section_count) * 40 > bytes.len) return error.Truncated;
    const magic = std.mem.readInt(u16, bytes[optional..][0..2], .little);
    const directories: usize = switch (magic) {
        0x20b => optional + 112,
        0x10b => optional + 96,
        else => return error.NotPe,
    };
    const img: Image = .{
        .bytes = bytes,
        .sections = bytes[sections_at..],
        .section_count = section_count,
        .thunk = if (magic == 0x20b) 8 else 4,
    };
    const import_rva = try img.u(u32, directories + 1 * 8);
    const iat_rva = try img.u(u32, directories + 12 * 8);
    const iat_size = try img.u(u32, directories + 12 * 8 + 4);
    if (import_rva == 0) return .{ .bound = 0, .unbound = 0 };
    if (iat_rva == 0) return error.NoImportAddressTable;

    // The slots each descriptor's list reaches, up to its terminator.
    const reached = try std.heap.page_allocator.alloc(bool, iat_size / img.thunk);
    defer std.heap.page_allocator.free(reached);
    @memset(reached, false);
    var bound: usize = 0;
    var d = try img.offsetOf(import_rva);
    while (true) : (d += 20) {
        const first_thunk = try img.u(u32, d + 16);
        const name = try img.u(u32, d + 12);
        if (first_thunk == 0 and name == 0) break;
        var rva = first_thunk;
        while (try img.slot(rva) != 0) : (rva += img.thunk) {
            bound += 1;
            if (rva >= iat_rva and rva < iat_rva + iat_size) reached[(rva - iat_rva) / img.thunk] = true;
        }
    }
    var unbound: usize = 0;
    for (reached, 0..) |r, i| {
        if (!r and try img.slot(iat_rva + @as(u32, @intCast(i)) * img.thunk) != 0) unbound += 1;
    }
    return .{ .bound = bound, .unbound = unbound };
}
