//! Image format.
//!
//! A zigsaw image is a standard OCI image manifest whose config blob is a
//! zigsaw app config and whose layers are plain tar files. That keeps images
//! storable in any OCI registry without zigsaw-specific server support.
//!
//! The layers are the app's runtimes' own layers, in the order the config
//! lists the runtimes, then one layer of the app's own files. So pulling an
//! app brings everything it runs with, and each layer is unpacked once, shared
//! by every app that uses it.

const std = @import("std");
const Context = @import("Context.zig");
const fail = Context.fail;

pub const media_type = struct {
    pub const manifest = "application/vnd.oci.image.manifest.v1+json";
    /// A new type rather than new fields, so that zigsaw versions that don't
    /// know about runtimes refuse these images instead of running them without.
    pub const config = "application/vnd.zigsaw.app.config.v2+json";
    /// Images made before runtimes existed: no runtimes, one layer. Still read.
    pub const config_v1 = "application/vnd.zigsaw.app.config.v1+json";
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
    /// Executable to run: relative to the app root, or in a runtime, e.g.
    /// "${node}\\node.exe".
    command: []const u8,
    /// Arguments placed before the caller's. They may use placeholders, e.g.
    /// "${app}" to run a script that ships with the app.
    args: []const []const u8 = &.{},
};

/// What placeholders in a config stand for. They are expanded when the app
/// runs, so images stay the same on every machine:
///   ${app}      the app's (read-only) directory
///   ${data}     the app's data directory, or the fresh one of an --ephemeral run
///   ${cache}    a directory for caches that are safe to keep: <data>\cache in
///               runs, and one kept between builds when a build uses the app
///   ${<alias>}  the directory of the runtime the app calls <alias>
pub const Placeholders = struct {
    app: []const u8,
    data: []const u8,
    /// Null where caches don't apply; "${cache}" is then kept as is.
    cache: ?[]const u8 = null,
    runtimes: []const Dir = &.{},

    pub const Dir = struct { alias: []const u8, path: []const u8 };

    /// Replaces the placeholders in `template`. Any other text, including
    /// other "${...}", is kept as is.
    pub fn expand(p: Placeholders, arena: std.mem.Allocator, template: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < template.len) {
            if (placeholderAt(template[i..])) |name| if (p.lookup(name)) |value| {
                try out.appendSlice(arena, value);
                i += name.len + "${}".len;
                continue;
            };
            try out.append(arena, template[i]);
            i += 1;
        }
        return out.items;
    }

    fn lookup(p: Placeholders, name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "app")) return p.app;
        if (std.mem.eql(u8, name, "data")) return p.data;
        if (std.mem.eql(u8, name, "cache")) return p.cache;
        for (p.runtimes) |r| if (std.mem.eql(u8, r.alias, name)) return r.path;
        return null;
    }
};

/// Whether PATH entries and variables, an app's or a runtime's, use
/// ${cache}, so that whatever runs with them, a build included, needs a
/// cache directory.
pub fn usesCache(path: []const []const u8, env: std.json.ArrayHashMap([]const u8)) bool {
    for (path) |p| if (std.mem.indexOf(u8, p, "${cache}") != null) return true;
    for (env.map.values()) |v| if (std.mem.indexOf(u8, v, "${cache}") != null) return true;
    return false;
}

/// The name in a "${name}" at the start of `s`, if there is one.
fn placeholderAt(s: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, s, "${")) return null;
    const end = std.mem.indexOfScalarPos(u8, s, 2, '}') orelse return null;
    return s[2..end];
}

/// Whether a path starts with a placeholder, and so is an absolute path once
/// expanded, rather than relative to the app root.
pub fn isPlaceholderPath(entry: []const u8) bool {
    return placeholderAt(entry) != null;
}

/// The placeholders a path may start with, wherever paths are checked.
const Anchors = struct {
    app: bool = false,
    /// ${data}, and ${cache} inside it.
    data: bool = false,
    aliases: []const []const u8 = &.{},

    fn allows(a: Anchors, name: []const u8) bool {
        if (std.mem.eql(u8, name, "app")) return a.app;
        if (std.mem.eql(u8, name, "data") or std.mem.eql(u8, name, "cache")) return a.data;
        for (a.aliases) |alias| if (std.mem.eql(u8, alias, name)) return true;
        return false;
    }
};

/// A relative path inside the app, or one of `anchors` as a placeholder,
/// followed by a relative path inside it (or, if `bare`, by nothing).
fn isValidAnchoredPath(p: []const u8, anchors: Anchors, bare: bool) bool {
    const name = placeholderAt(p) orelse return isSafeRelPath(p);
    if (!anchors.allows(name)) return false;
    const rest = p[name.len + "${}".len ..];
    if (rest.len == 0) return bare;
    return (rest[0] == '\\' or rest[0] == '/') and isSafeRelPath(rest[1..]);
}

/// A PATH entry: a relative path inside the app, or ${app}, ${data}, ${cache}
/// or a runtime's alias, optionally followed by a relative path inside it.
pub fn isValidPathEntry(entry: []const u8, aliases: []const []const u8) bool {
    return isValidAnchoredPath(entry, .{ .app = true, .data = true, .aliases = aliases }, true);
}

/// A command: a file in the app, or in one of its runtimes.
pub fn isValidCommand(command: []const u8, aliases: []const []const u8) bool {
    return isValidAnchoredPath(command, .{ .app = true, .aliases = aliases }, false);
}

/// A runtime an app runs with. Its own layer is also one of the app's, and
/// the rest is copied from its config, so the app's image is all it takes to
/// run it.
pub const Runtime = struct {
    id: []const u8,
    version: []const u8,
    /// The runtime's image: its manifest digest.
    image: []const u8,
    /// The digest of the runtime's own layer.
    layer: []const u8,
    /// The runtime's PATH entries and variables, which every run of the app
    /// gets. In them, ${app} is the runtime's directory, and ${data} and
    /// ${cache} are the app's.
    path: []const []const u8 = &.{"."},
    env: std.json.ArrayHashMap([]const u8) = .{},
};

/// How an image was built, for anyone checking where it came from.
pub const Build = struct {
    /// The SDK images the build used, by alias: their manifest digests.
    sdk: std.json.ArrayHashMap([]const u8) = .{},
    /// The sha256 of each source, in recipe order.
    sources: []const []const u8 = &.{},
    /// What each module's vendor step made, by module name: its sha256.
    /// Absent unless a module has one.
    vendor: ?std.json.ArrayHashMap([]const u8) = null,
    /// Whether a build step had network access. Then the image depends on
    /// more than its pinned inputs.
    network: bool = false,
    /// The host toolchains the build used, by name: their versions. Images
    /// built with one aren't expected to reproduce on other machines.
    host: std.json.ArrayHashMap([]const u8) = .{},
};

/// The config blob of an image.
pub const AppConfig = struct {
    id: []const u8,
    version: []const u8,
    /// Executable to run: relative to the app root, or in a runtime.
    command: []const u8,
    /// Arguments placed before the caller's. They may use placeholders.
    args: []const []const u8 = &.{},
    /// Directories put on PATH ahead of the runtimes' and the system's:
    /// relative to the app root, or starting with a placeholder, e.g.
    /// "${data}\\npm".
    path: []const []const u8 = &.{"."},
    /// Values may use placeholders.
    env: std.json.ArrayHashMap([]const u8) = .{},
    permissions: Permissions = .{},
    /// Commands the app provides, by name.
    exports: std.json.ArrayHashMap(Export) = .{},
    /// Commands the image gives builds that use it as an SDK or runtime, by
    /// name: like exports, but on the build's PATH rather than the user's.
    /// zig's image makes `dlltool` run `zig dlltool`, for instance. Absent
    /// unless there are some.
    aliases: ?std.json.ArrayHashMap(Export) = null,
    /// The images the app runs with, by alias, in the order of their layers.
    runtimes: std.json.ArrayHashMap(Runtime) = .{},
    /// Null in images made before iteration 4.
    build: ?Build = null,
};

/// Parses a config blob of type `config_type`, and checks it. `what` names
/// the image in messages.
pub fn parseConfig(arena: std.mem.Allocator, what: []const u8, config_type: []const u8, bytes: []const u8) !AppConfig {
    if (!isConfigType(config_type))
        return fail("{s} is not a zigsaw app (its config type is {s}; it may be a container image)", .{ what, config_type });
    const c = std.json.parseFromSliceLeaky(AppConfig, arena, bytes, .{ .ignore_unknown_fields = true }) catch
        return fail("{s}: its app config can't be read", .{what});
    if (std.mem.eql(u8, config_type, media_type.config_v1) and c.runtimes.map.count() > 0)
        return fail("{s}: a v1 config can't have runtimes", .{what});
    try validateConfig(what, c);
    return c;
}

pub fn isConfigType(t: []const u8) bool {
    return std.mem.eql(u8, t, media_type.config) or std.mem.eql(u8, t, media_type.config_v1);
}

/// Checks that a manifest's layers are the ones its config accounts for:
/// each runtime's, in order, then the app's own.
pub fn validateLayers(what: []const u8, m: Manifest, c: AppConfig) error{Failed}!void {
    for (m.layers) |l| if (!std.mem.eql(u8, l.mediaType, media_type.layer_tar))
        return fail("{s} has a layer of type {s}, which zigsaw can't unpack", .{ what, l.mediaType });
    const runtimes = c.runtimes.map.values();
    if (m.layers.len != runtimes.len + 1)
        return fail("{s} has {d} layer(s), but its config accounts for {d}: one per runtime, and the app's own", .{ what, m.layers.len, runtimes.len + 1 });
    for (c.runtimes.map.keys(), runtimes, m.layers[0..runtimes.len]) |alias, r, l| if (!std.mem.eql(u8, r.layer, l.digest))
        return fail("{s}: runtime {s}'s layer {s} isn't in its manifest's place for it", .{ what, alias, r.layer });
}

/// The layer of the app's own files.
pub fn ownLayer(m: Manifest) Descriptor {
    return m.layers[m.layers.len - 1];
}

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
    try validateRuntimes(what, c.runtimes);
    try validateEntryPoints(what, c, c.runtimes.map.keys());
}

/// The checks that don't need the runtimes resolved: recipes run them before
/// building, with the aliases they declare.
pub fn validateEntryPoints(what: []const u8, c: AppConfig, aliases: []const []const u8) error{Failed}!void {
    if (!isValidId(c.id))
        return fail("{s}: id \"{s}\" must be 1-57 characters of letters, digits, '.', '-', '_'", .{ what, c.id });
    if (c.version.len == 0)
        return fail("{s}: version must not be empty", .{what});
    if (!isValidCommand(c.command, aliases))
        return fail("{s}: command \"{s}\" must be a relative path inside the app, or start with a runtime's ${{alias}}\\", .{ what, c.command });
    for (c.path) |p| if (!isValidPathEntry(p, aliases))
        return fail("{s}: path entry \"{s}\" must be a relative path inside the app, or start with ${{app}}, ${{data}}, ${{cache}} or a runtime's ${{alias}}", .{ what, p });
    for (c.permissions.filesystem) |spec| if (parseFsGrant(spec) == null)
        return fail("{s}: filesystem permission \"{s}\" must be \"cwd\" or an absolute path, optionally with \":ro\"", .{ what, spec });
    var it = c.exports.map.iterator();
    while (it.next()) |e| {
        if (!isValidExportName(e.key_ptr.*))
            return fail("{s}: export name \"{s}\" must be letters, digits, '.', '-', '_' (and not zigsaw's own)", .{ what, e.key_ptr.* });
        if (!isValidCommand(e.value_ptr.command, aliases))
            return fail("{s}: export {s} command \"{s}\" must be a relative path inside the app, or start with a runtime's ${{alias}}\\", .{ what, e.key_ptr.*, e.value_ptr.command });
    }
    // Builds run an image's aliases from the image itself, whose runtimes
    // they don't have.
    if (c.aliases) |a| {
        var it_aliases = a.map.iterator();
        while (it_aliases.next()) |e| {
            if (!isValidExportName(e.key_ptr.*))
                return fail("{s}: alias name \"{s}\" must be letters, digits, '.', '-', '_' (and not zigsaw's own)", .{ what, e.key_ptr.* });
            if (!isValidCommand(e.value_ptr.command, &.{}))
                return fail("{s}: alias {s} command \"{s}\" must be a relative path inside the app", .{ what, e.key_ptr.*, e.value_ptr.command });
        }
    }
}

fn validateRuntimes(what: []const u8, runtimes: std.json.ArrayHashMap(Runtime)) error{Failed}!void {
    const aliases = runtimes.map.keys();
    const values = runtimes.map.values();
    for (aliases, values, 0..) |alias, r, i| {
        if (!isValidAlias(alias))
            return fail("{s}: runtime alias \"{s}\" must be lowercase letters, digits, '-' or '_', start with a letter, and not be app, data or cache", .{ what, alias });
        if (!isValidId(r.id) or r.version.len == 0 or digestHex(r.image) == null or digestHex(r.layer) == null)
            return fail("{s}: runtime {s} needs a valid id, version, image digest and layer digest", .{ what, alias });
        for (r.path) |p| if (!isValidAnchoredPath(p, .{ .app = true, .data = true }, true))
            return fail("{s}: runtime {s}'s path entry \"{s}\" must be inside it, or start with ${{app}}, ${{data}} or ${{cache}}", .{ what, alias, p });
        for (aliases[0..i], values[0..i]) |earlier_alias, earlier| if (std.ascii.eqlIgnoreCase(earlier.id, r.id))
            return fail("{s}: runtimes {s} and {s} are both {s}", .{ what, earlier_alias, alias, r.id });
    }
}

/// Runtime and SDK aliases become placeholder names, so they are plain, and
/// can't be the built-in ones.
pub fn isValidAlias(name: []const u8) bool {
    if (name.len == 0 or name.len > 32 or !std.ascii.isLower(name[0])) return false;
    for (name) |c| switch (c) {
        'a'...'z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    for ([_][]const u8{ "app", "data", "cache" }) |reserved| {
        if (std.mem.eql(u8, name, reserved)) return false;
    }
    return true;
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
    const p: Placeholders = .{
        .app = "C:\\z\\deploy\\ab",
        .data = "C:\\z\\data\\x",
        .runtimes = &.{.{ .alias = "node", .path = "C:\\z\\deploy\\cd" }},
    };
    try std.testing.expectEqualStrings("C:\\z\\data\\x\\npm", try p.expand(arena, "${data}\\npm"));
    try std.testing.expectEqualStrings("C:\\z\\deploy\\ab;C:\\z\\data\\x", try p.expand(arena, "${app};${data}"));
    try std.testing.expectEqualStrings("C:\\z\\deploy\\cd\\node.exe", try p.expand(arena, "${node}\\node.exe"));
    try std.testing.expectEqualStrings("${HOME} $ ${app", try p.expand(arena, "${HOME} $ ${app"));
    try std.testing.expectEqualStrings("${python}\\x", try p.expand(arena, "${python}\\x"));
    try std.testing.expectEqualStrings("", try p.expand(arena, ""));
    // Without a cache directory, ${cache} stays as it is.
    try std.testing.expectEqualStrings("${cache}\\zig", try p.expand(arena, "${cache}\\zig"));
    var with_cache = p;
    with_cache.cache = "B:\\cache\\org.ziglang.zig";
    try std.testing.expectEqualStrings("B:\\cache\\org.ziglang.zig", try with_cache.expand(arena, "${cache}"));
}

test usesCache {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var env: std.json.ArrayHashMap([]const u8) = .{};
    try env.map.put(arena_state.allocator(), "NPM_CONFIG_PREFIX", "${data}\\npm");
    try std.testing.expect(!usesCache(&.{"."}, env));
    try std.testing.expect(usesCache(&.{ ".", "${cache}\\bin" }, env));
    try env.map.put(arena_state.allocator(), "ZIG_GLOBAL_CACHE_DIR", "${cache}");
    try std.testing.expect(usesCache(&.{"."}, env));
}

test isValidPathEntry {
    const none: []const []const u8 = &.{};
    try std.testing.expect(isValidPathEntry(".", none));
    try std.testing.expect(isValidPathEntry("bin", none));
    try std.testing.expect(isValidPathEntry("${data}", none));
    try std.testing.expect(isValidPathEntry("${data}\\npm", none));
    try std.testing.expect(isValidPathEntry("${app}/tools/bin", none));
    try std.testing.expect(isValidPathEntry("${cache}\\bin", none));
    try std.testing.expect(!isValidPathEntry("${data}npm", none));
    try std.testing.expect(!isValidPathEntry("${data}\\..\\other", none));
    try std.testing.expect(!isValidPathEntry("${data}\\", none));
    try std.testing.expect(!isValidPathEntry("C:\\Windows", none));
    try std.testing.expect(!isValidPathEntry("${node}\\bin", none));
    try std.testing.expect(isValidPathEntry("${node}\\bin", &.{"node"}));
    try std.testing.expect(isPlaceholderPath("${data}\\npm"));
    try std.testing.expect(!isPlaceholderPath("npm"));
}

test isValidCommand {
    const aliases: []const []const u8 = &.{"node"};
    try std.testing.expect(isValidCommand("bin/tool.exe", aliases));
    try std.testing.expect(isValidCommand("${node}\\node.exe", aliases));
    try std.testing.expect(isValidCommand("${app}\\tool.exe", aliases));
    try std.testing.expect(!isValidCommand("${node}", aliases));
    try std.testing.expect(!isValidCommand("${data}\\npm\\tsc.cmd", aliases));
    try std.testing.expect(!isValidCommand("${python}\\python.exe", aliases));
    try std.testing.expect(!isValidCommand("${node}\\..\\x.exe", aliases));
}

test isValidAlias {
    try std.testing.expect(isValidAlias("node"));
    try std.testing.expect(isValidAlias("py3_14-x"));
    try std.testing.expect(!isValidAlias("app"));
    try std.testing.expect(!isValidAlias("data"));
    try std.testing.expect(!isValidAlias("cache"));
    try std.testing.expect(!isValidAlias("Node"));
    try std.testing.expect(!isValidAlias("3d"));
    try std.testing.expect(!isValidAlias("a.b"));
    try std.testing.expect(!isValidAlias(""));
}

test "layers must match the runtimes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const digest = "sha256:" ++ "a" ** 64;
    const other = "sha256:" ++ "b" ** 64;
    const layer = struct {
        fn of(d: []const u8) Descriptor {
            return .{ .mediaType = media_type.layer_tar, .digest = d, .size = 1 };
        }
    }.of;
    var c: AppConfig = .{ .id = "x", .version = "1", .command = "${node}\\node.exe" };
    try c.runtimes.map.put(arena, "node", .{ .id = "org.nodejs.node", .version = "24", .image = other, .layer = digest });
    try validateConfig("test", c);

    const config: Descriptor = .{ .mediaType = media_type.config, .digest = other, .size = 1 };
    try validateLayers("test", .{ .config = config, .layers = &.{ layer(digest), layer(other) } }, c);
    try std.testing.expectError(error.Failed, validateLayers("test", .{ .config = config, .layers = &.{layer(other)} }, c));
    try std.testing.expectError(error.Failed, validateLayers("test", .{ .config = config, .layers = &.{ layer(other), layer(digest) } }, c));
    try std.testing.expectEqualStrings(other, ownLayer(.{ .config = config, .layers = &.{ layer(digest), layer(other) } }).digest);

    try c.runtimes.map.put(arena, "node2", .{ .id = "org.nodejs.NODE", .version = "22", .image = digest, .layer = other });
    try std.testing.expectError(error.Failed, validateConfig("test", c));
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
