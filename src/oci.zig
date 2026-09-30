//! Image format.
//!
//! A zigsaw image is a standard OCI image manifest whose config blob is a
//! zigsaw app config and whose layers are plain tar files. That keeps images
//! storable in any OCI registry without zigsaw-specific server support.

const std = @import("std");
const Context = @import("Context.zig");
const fail = Context.fail;

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

/// A command an app provides, which `zigsaw build` puts on the user's PATH as
/// a shim.
pub const Export = struct {
    /// Executable to run, relative to the app root.
    command: []const u8,
    /// Arguments placed before the caller's. They may use placeholders, e.g.
    /// "${app}" to run a script that ships with the app.
    args: []const []const u8 = &.{},
};

/// What placeholders in a config stand for. They are expanded when the app
/// runs, so images stay the same on every machine:
///   ${app}   the app's (read-only) directory
///   ${data}  the app's data directory, or the fresh one of an --ephemeral run
pub const Placeholders = struct {
    app: []const u8,
    data: []const u8,

    const names = [_][]const u8{ "${app}", "${data}" };

    /// Replaces the placeholders in `template`. Any other text, including
    /// other "${...}", is kept as is.
    pub fn expand(p: Placeholders, arena: std.mem.Allocator, template: []const u8) ![]u8 {
        const values = [names.len][]const u8{ p.app, p.data };
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        next: while (i < template.len) {
            for (names, values) |name, value| if (std.mem.startsWith(u8, template[i..], name)) {
                try out.appendSlice(arena, value);
                i += name.len;
                continue :next;
            };
            try out.append(arena, template[i]);
            i += 1;
        }
        return out.items;
    }

    /// The part of a path entry after a leading placeholder, or null if it
    /// doesn't start with one.
    fn afterPrefix(entry: []const u8) ?[]const u8 {
        for (names) |name| if (std.mem.startsWith(u8, entry, name)) return entry[name.len..];
        return null;
    }
};

/// Whether a PATH entry starts with a placeholder, and so is an absolute path
/// once expanded, rather than relative to the app root.
pub fn isPlaceholderPath(entry: []const u8) bool {
    return Placeholders.afterPrefix(entry) != null;
}

/// A PATH entry: a relative path inside the app, or a placeholder optionally
/// followed by a relative path inside it.
pub fn isValidPathEntry(entry: []const u8) bool {
    const rest = Placeholders.afterPrefix(entry) orelse return isSafeRelPath(entry);
    if (rest.len == 0) return true;
    return (rest[0] == '\\' or rest[0] == '/') and isSafeRelPath(rest[1..]);
}

/// The config blob of an image.
pub const AppConfig = struct {
    id: []const u8,
    version: []const u8,
    /// Executable to run, relative to the app root.
    command: []const u8,
    /// Directories put on PATH ahead of the system directories: relative to
    /// the app root, or starting with a placeholder, e.g. "${data}\\npm".
    path: []const []const u8 = &.{"."},
    /// Values may use placeholders.
    env: std.json.ArrayHashMap([]const u8) = .{},
    permissions: Permissions = .{},
    /// Commands the app provides, by name.
    exports: std.json.ArrayHashMap(Export) = .{},
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

/// "sha256:" and the first 12 hex digits, enough to tell images apart.
pub fn shortDigest(digest: []const u8) []const u8 {
    return digest[0..@min(digest.len, "sha256:".len + 12)];
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

/// Checks what zigsaw relies on in an app config: names that become paths
/// stay plain, and commands stay inside the app. Configs come from recipes and
/// from registries, so this runs on both. `what` names the source in messages.
pub fn validateConfig(what: []const u8, c: AppConfig) error{Failed}!void {
    if (!isValidId(c.id))
        return fail("{s}: id \"{s}\" must be 1-57 characters of letters, digits, '.', '-', '_'", .{ what, c.id });
    if (c.version.len == 0)
        return fail("{s}: version must not be empty", .{what});
    if (!isSafeRelPath(c.command))
        return fail("{s}: command \"{s}\" must be a relative path inside the app", .{ what, c.command });
    for (c.path) |p| if (!isValidPathEntry(p))
        return fail("{s}: path entry \"{s}\" must be a relative path inside the app, or start with ${{app}} or ${{data}}", .{ what, p });
    for (c.permissions.filesystem) |spec| if (parseFsGrant(spec) == null)
        return fail("{s}: filesystem permission \"{s}\" must be \"cwd\" or an absolute path, optionally with \":ro\"", .{ what, spec });
    var it = c.exports.map.iterator();
    while (it.next()) |e| {
        if (!isValidExportName(e.key_ptr.*))
            return fail("{s}: export name \"{s}\" must be letters, digits, '.', '-', '_' (and not zigsaw's own)", .{ what, e.key_ptr.* });
        if (!isSafeRelPath(e.value_ptr.command))
            return fail("{s}: export {s} command \"{s}\" must be a relative path inside the app", .{ what, e.key_ptr.*, e.value_ptr.command });
    }
}

/// Export names become file names in the shim directory, so they are plain
/// and can't shadow zigsaw's own executables.
pub fn isValidExportName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '.') return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => {},
        else => return false,
    };
    for ([_][]const u8{ "zigsaw", "zigsaw-shim" }) |reserved| {
        if (std.ascii.eqlIgnoreCase(name, reserved)) return false;
    }
    return true;
}

/// The default export name for a command: its file name without extension.
pub fn commandStem(command: []const u8) []const u8 {
    const base = command[if (std.mem.lastIndexOfAny(u8, command, "/\\")) |i| i + 1 else 0..];
    return base[0 .. std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len];
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

test isValidExportName {
    try std.testing.expect(isValidExportName("node"));
    try std.testing.expect(isValidExportName("python3.14"));
    try std.testing.expect(!isValidExportName("Zigsaw"));
    try std.testing.expect(!isValidExportName("a/b"));
    try std.testing.expect(!isValidExportName(".hidden"));
    try std.testing.expect(!isValidExportName(""));
}

test commandStem {
    try std.testing.expectEqualStrings("git", commandStem("cmd/git.exe"));
    try std.testing.expectEqualStrings("rg", commandStem("rg.exe"));
    try std.testing.expectEqualStrings("tool", commandStem("bin\\tool"));
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

test "Placeholders.expand" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p: Placeholders = .{ .app = "C:\\z\\deploy\\ab", .data = "C:\\z\\data\\x" };
    try std.testing.expectEqualStrings("C:\\z\\data\\x\\npm", try p.expand(arena, "${data}\\npm"));
    try std.testing.expectEqualStrings("C:\\z\\deploy\\ab;C:\\z\\data\\x", try p.expand(arena, "${app};${data}"));
    try std.testing.expectEqualStrings("${HOME} $ ${app", try p.expand(arena, "${HOME} $ ${app"));
    try std.testing.expectEqualStrings("", try p.expand(arena, ""));
}

test isValidPathEntry {
    try std.testing.expect(isValidPathEntry("."));
    try std.testing.expect(isValidPathEntry("bin"));
    try std.testing.expect(isValidPathEntry("${data}"));
    try std.testing.expect(isValidPathEntry("${data}\\npm"));
    try std.testing.expect(isValidPathEntry("${app}/tools/bin"));
    try std.testing.expect(!isValidPathEntry("${data}npm"));
    try std.testing.expect(!isValidPathEntry("${data}\\..\\other"));
    try std.testing.expect(!isValidPathEntry("${data}\\"));
    try std.testing.expect(!isValidPathEntry("C:\\Windows"));
    try std.testing.expect(isPlaceholderPath("${data}\\npm"));
    try std.testing.expect(!isPlaceholderPath("npm"));
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
