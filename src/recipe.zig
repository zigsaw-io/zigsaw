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
    sources: []const Source,

    pub fn appConfig(r: Recipe) oci.AppConfig {
        return .{
            .id = r.id,
            .version = r.version,
            .command = r.command,
            .path = r.path,
            .env = r.env,
            .permissions = r.permissions,
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
    try validate(file_name, r);
    return r;
}

fn validate(file_name: []const u8, r: Recipe) error{Failed}!void {
    if (!oci.isValidId(r.id))
        return fail("{s}: id \"{s}\" must be 1-57 characters of letters, digits, '.', '-', '_'", .{ file_name, r.id });
    if (r.version.len == 0)
        return fail("{s}: version must not be empty", .{file_name});
    if (!oci.isSafeRelPath(r.command))
        return fail("{s}: command \"{s}\" must be a relative path inside the app", .{ file_name, r.command });
    for (r.path) |p| if (!oci.isSafeRelPath(p))
        return fail("{s}: path entry \"{s}\" must be a relative path inside the app", .{ file_name, p });
    for (r.permissions.filesystem) |spec| if (oci.parseFsGrant(spec) == null)
        return fail("{s}: filesystem permission \"{s}\" must be \"cwd\" or an absolute path, optionally with \":ro\"", .{ file_name, spec });
    if (r.sources.len == 0)
        return fail("{s}: at least one source is required", .{file_name});

    for (r.sources, 1..) |s, n| {
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
}

test "zip kind is inferred" {
    const s: Source = .{ .url = "https://example.com/node-v22-win-x64.ZIP" };
    try std.testing.expectEqual(Source.Kind.zip, s.kind());
}
