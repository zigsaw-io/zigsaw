//! Image format.
//!
//! A zigsaw image is a standard OCI image manifest whose config blob is a
//! zigsaw app config and whose layers are plain tar files. That keeps images
//! storable in any OCI registry without zigsaw-specific server support.

const std = @import("std");

pub const media_type = struct {
    pub const manifest = "application/vnd.oci.image.manifest.v1+json";
    pub const config = "application/vnd.zigsaw.app.config.v1+json";
    pub const layer_tar = "application/vnd.oci.image.layer.v1.tar";
};

pub const Descriptor = struct {
    mediaType: []const u8,
    digest: []const u8,
    size: u64,
};

pub const Manifest = struct {
    schemaVersion: u32 = 2,
    mediaType: []const u8 = media_type.manifest,
    config: Descriptor,
    layers: []const Descriptor,
    annotations: ?std.json.ArrayHashMap([]const u8) = null,
};

/// What an app may reach outside its own files, like Flatpak's finish-args.
pub const Permissions = struct {
    /// Outbound network access.
    network: bool = false,
    /// Host locations the app may use: "cwd" or an absolute path, either
    /// optionally suffixed with ":ro". Anything not listed is off limits.
    filesystem: []const []const u8 = &.{},
};

/// The config blob of an image.
pub const AppConfig = struct {
    id: []const u8,
    version: []const u8,
    /// Executable to run, relative to the app root.
    command: []const u8,
    /// Directories, relative to the app root, put on PATH ahead of the system directories.
    path: []const []const u8 = &.{"."},
    env: std.json.ArrayHashMap([]const u8) = .{},
    permissions: Permissions = .{},
};

pub fn toJson(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, value, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
}

/// Returns the hex part of a "sha256:<hex>" digest, or null if malformed.
pub fn digestHex(digest: []const u8) ?[]const u8 {
    const prefix = "sha256:";
    if (!std.mem.startsWith(u8, digest, prefix)) return null;
    const hex = digest[prefix.len..];
    return if (isSha256Hex(hex)) hex else null;
}

pub fn isSha256Hex(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// App ids name directories and the AppContainer profile ("zigsaw.<id>",
/// which Windows caps at 64 characters), so they are short, reverse-DNS style.
pub fn isValidId(id: []const u8) bool {
    if (id.len == 0 or id.len > 57 or id[0] == '.') return false;
    for (id) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// A path inside the app tree: relative, no "..", no drive or stream syntax.
pub fn isSafeRelPath(p: []const u8) bool {
    if (p.len == 0 or p[0] == '/' or p[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, p, ':') != null) return false;
    var it = std.mem.tokenizeAny(u8, p, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

pub const FsGrant = struct {
    /// Null means the working directory zigsaw was started from.
    path: ?[]const u8,
    read_only: bool,
};

/// Parses a filesystem permission: "cwd" or an absolute path, optionally
/// followed by ":ro" or ":rw".
pub fn parseFsGrant(spec: []const u8) ?FsGrant {
    var s = spec;
    var read_only = false;
    if (std.mem.endsWith(u8, s, ":ro")) {
        read_only = true;
        s = s[0 .. s.len - 3];
    } else if (std.mem.endsWith(u8, s, ":rw")) {
        s = s[0 .. s.len - 3];
    }
    if (std.mem.eql(u8, s, "cwd")) return .{ .path = null, .read_only = read_only };
    if (std.fs.path.isAbsoluteWindows(s) and s.len > 2) return .{ .path = s, .read_only = read_only };
    return null;
}

test isValidId {
    try std.testing.expect(isValidId("org.nodejs.node"));
    try std.testing.expect(isValidId("net.frippery.busybox"));
    try std.testing.expect(!isValidId(""));
    try std.testing.expect(!isValidId(".hidden"));
    try std.testing.expect(!isValidId("has space"));
    try std.testing.expect(!isValidId("a/b"));
    try std.testing.expect(!isValidId("x" ** 58));
}

test isSafeRelPath {
    try std.testing.expect(isSafeRelPath("busybox.exe"));
    try std.testing.expect(isSafeRelPath("bin/node.exe"));
    try std.testing.expect(isSafeRelPath("."));
    try std.testing.expect(!isSafeRelPath("../evil.exe"));
    try std.testing.expect(!isSafeRelPath("bin\\..\\..\\evil.exe"));
    try std.testing.expect(!isSafeRelPath("C:\\Windows"));
    try std.testing.expect(!isSafeRelPath("/etc"));
    try std.testing.expect(!isSafeRelPath("file.txt:stream"));
}

test parseFsGrant {
    try std.testing.expectEqual(@as(?[]const u8, null), parseFsGrant("cwd").?.path);
    try std.testing.expect(parseFsGrant("cwd:ro").?.read_only);
    try std.testing.expectEqualStrings("D:\\src", parseFsGrant("D:\\src:ro").?.path.?);
    try std.testing.expect(!parseFsGrant("D:\\src").?.read_only);
    try std.testing.expect(parseFsGrant("relative\\dir") == null);
    try std.testing.expect(parseFsGrant("home") == null);
}

test digestHex {
    const hex = "07bb1e5b095b00d68a695481f9240879f33c5724b40aa2308f999d54ed78f075";
    try std.testing.expectEqualStrings(hex, digestHex("sha256:" ++ hex).?);
    try std.testing.expect(digestHex(hex) == null);
    try std.testing.expect(digestHex("sha256:ABC") == null);
}
