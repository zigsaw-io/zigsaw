//! Build recipes: JSON files describing how to assemble an app from pinned
//! sources, the zigsaw equivalent of a flatpak-builder manifest.

const std = @import("std");
const oci = @import("oci.zig");
const Context = @import("Context.zig");
const fail = Context.fail;

pub const Source = struct {
    url: ?[]const u8 = null,
    /// Local file, relative to the recipe.
    path: ?[]const u8 = null,
    /// Required for URLs. A URL without one fails the build and reports the hash to pin.
    sha256: ?[]const u8 = null,
    /// Inferred from the file name when omitted.
    type: ?Kind = null,
    /// For `file`: destination path in the app tree (default: the source's file name).
    /// For `zip`: directory to extract into (default: the app root).
    dest: ?[]const u8 = null,
    /// For `zip`: leading directory levels to drop, like `tar --strip-components`.
    strip: u32 = 0,

    pub const Kind = enum { file, zip };

    pub fn location(s: Source) []const u8 {
        return s.url orelse s.path.?;
    }

    /// File name at the end of the URL or path, ignoring any query string.
    pub fn fileName(s: Source) []const u8 {
        const loc = s.location();
        const end = std.mem.indexOfAny(u8, loc, "?#") orelse loc.len;
        const trimmed = loc[0..end];
        const start = if (std.mem.lastIndexOfAny(u8, trimmed, "/\\")) |i| i + 1 else 0;
        return trimmed[start..];
    }

    pub fn kind(s: Source) Kind {
        if (s.type) |k| return k;
        return if (std.ascii.endsWithIgnoreCase(s.fileName(), ".zip")) .zip else .file;
    }
};

pub const Recipe = struct {
    id: []const u8,
    version: []const u8,
    command: []const u8,
    path: []const []const u8 = &.{"."},
    env: std.json.ArrayHashMap([]const u8) = .{},
    permissions: oci.Permissions = .{},
    /// Commands to put on PATH. Without this, the app exports its command
    /// under its file name (e.g. "rg" for rg.exe); `{}` exports nothing.
    exports: ?std.json.ArrayHashMap(oci.Export) = null,
    sources: []const Source,

    pub fn appConfig(r: Recipe, arena: std.mem.Allocator) !oci.AppConfig {
        var exports: std.json.ArrayHashMap(oci.Export) = .{};
        if (r.exports) |e| {
            exports = e;
        } else {
            try exports.map.put(arena, oci.commandStem(r.command), .{ .command = r.command });
        }
        return .{
            .id = r.id,
            .version = r.version,
            .command = r.command,
            .path = r.path,
            .env = r.env,
            .permissions = r.permissions,
            .exports = exports,
        };
    }
};

/// Parses and validates a recipe. `file_name` is only used in messages.
pub fn parse(arena: std.mem.Allocator, file_name: []const u8, bytes: []const u8) !Recipe {
    var scanner: std.json.Scanner = .initCompleteInput(arena, bytes);
    var diagnostics: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diagnostics);
    const r = std.json.parseFromTokenSourceLeaky(Recipe, arena, &scanner, .{}) catch |err| {
        return fail("{s}:{d}:{d}: {t}", .{ file_name, diagnostics.getLine(), diagnostics.getColumn(), err });
    };
    // The same checks an image pulled from a registry gets.
    try oci.validateConfig(file_name, try r.appConfig(arena));
    try validateSources(file_name, r.sources);
    return r;
}

fn validateSources(file_name: []const u8, sources: []const Source) error{Failed}!void {
    if (sources.len == 0)
        return fail("{s}: at least one source is required", .{file_name});
    for (sources, 1..) |s, n| {
        if ((s.url == null) == (s.path == null))
            return fail("{s}: source {d} needs exactly one of \"url\" or \"path\"", .{ file_name, n });
        if (s.sha256) |h| if (!oci.isSha256Hex(h))
            return fail("{s}: source {d} sha256 must be 64 lowercase hex characters", .{ file_name, n });
        if (s.dest) |d| if (!oci.isSafeRelPath(d))
            return fail("{s}: source {d} dest \"{s}\" must be a relative path inside the app", .{ file_name, n, d });
        if (s.strip != 0 and s.kind() != .zip)
            return fail("{s}: source {d} uses \"strip\", which only applies to zip sources", .{ file_name, n });
        if (s.kind() == .file and s.dest == null and s.fileName().len == 0)
            return fail("{s}: source {d} has no file name; set \"dest\"", .{ file_name, n });
    }
}

test "parse minimal recipe" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const r = try parse(arena_state.allocator(), "test.json",
        \\{
        \\  "id": "net.frippery.busybox",
        \\  "version": "1",
        \\  "command": "busybox.exe",
        \\  "sources": [{ "url": "https://example.com/bb.exe?x=1", "dest": "busybox.exe" }]
        \\}
    );
    try std.testing.expectEqualStrings("busybox.exe", r.command);
    try std.testing.expectEqual(Source.Kind.file, r.sources[0].kind());
    try std.testing.expectEqualStrings("bb.exe", r.sources[0].fileName());
    try std.testing.expectEqual(false, r.permissions.network);

    const cfg = try r.appConfig(arena_state.allocator());
    try std.testing.expectEqual(1, cfg.exports.map.count());
    try std.testing.expectEqualStrings("busybox.exe", cfg.exports.map.get("busybox").?.command);
}

test "zip kind is inferred" {
    const s: Source = .{ .url = "https://example.com/node-v22-win-x64.ZIP" };
    try std.testing.expectEqual(Source.Kind.zip, s.kind());
}
