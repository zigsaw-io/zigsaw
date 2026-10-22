//! A Docker credential helper for tests/registry.sh: `get` answers with the
//! login in ZIGSAW_TEST_HELPER_USER and ZIGSAW_TEST_HELPER_SECRET, for the
//! registry ZIGSAW_TEST_HELPER_SERVER names, as Docker's helpers do; for
//! another, or without them, it says it has none. It writes the registry it
//! was asked for to ZIGSAW_TEST_HELPER_ASKED, if set. Built by
//! `zig build cred-helper` as zig-out\test\docker-credential-zigsaw-test.exe.

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2 or !std.mem.eql(u8, args[1], "get")) return 2;

    var in_buf: [1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(init.io, &in_buf);
    const server = std.mem.trim(u8, try stdin.interface.allocRemaining(arena, .limited(4096)), " \r\n");
    if (init.environ_map.get("ZIGSAW_TEST_HELPER_ASKED")) |p|
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = p, .data = server });

    var out_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    const w = &stdout.interface;
    const env = init.environ_map;
    const known = env.get("ZIGSAW_TEST_HELPER_SERVER") orelse "";
    if (std.mem.eql(u8, server, known)) if (env.get("ZIGSAW_TEST_HELPER_USER")) |user| {
        try std.json.Stringify.value(.{ .ServerURL = server, .Username = user, .Secret = env.get("ZIGSAW_TEST_HELPER_SECRET") orelse "" }, .{}, w);
        try w.flush();
        return 0;
    };
    try w.writeAll("credentials not found in native keychain\n");
    try w.flush();
    return 1;
}
