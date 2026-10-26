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
    /// Layers of images built before iteration 7. Still read.
    pub const layer_tar = "application/vnd.oci.image.layer.v1.tar";
    /// Layers as builds make them: the same tar, gzip-compressed.
    pub const layer_tar_gzip = "application/vnd.oci.image.layer.v1.tar+gzip";
    /// The config of the manifest that keeps an image's sources next to it
    /// in its repository (see remote.zig), and each of those files.
    pub const sources_config = "application/vnd.zigsaw.sources.v1+json";
    pub const source = "application/vnd.zigsaw.source.v1";
};

/// The config of an image's sources manifest: which image they were built
/// into.
pub const SourcesConfig = struct {
    id: []const u8,
    version: []const u8,
    /// The image's manifest digest.
    image: []const u8,
};

/// The tag of the manifest that keeps the sources of the image with this
/// manifest digest, in the image's repository: "sha256-<hex>.sources", as
/// cosign tags what it attaches to an image.
pub fn sourcesTag(arena: std.mem.Allocator, image_digest: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "sha256-{s}.sources", .{digestHex(image_digest).?});
}

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
    /// Host locations the app may use: "cwd", one of the user's folders
    /// ("documents"; see `UserFolder`) or an absolute path, each optionally
    /// suffixed with ":ro". Anything not listed is off limits.
    filesystem: []const []const u8 = &.{},
    /// What the app serves to other programs on this machine, which zigsaw
    /// publishes in every sandbox (see services.zig). Absent unless there
    /// are some.
    services: ?[]const Service = null,
    /// Ports on this machine the app connects to, which it reaches in every
    /// sandbox, with the network or without (see services.zig). Absent
    /// unless there are some.
    uses: ?[]const Use = null,
};

/// A port an app listens on for other programs on this machine. Its config
/// says ${listen:<name>} where the app should listen, which is where its own
/// runs connect too, and ${port:<name>} where other programs reach it.
pub const Service = struct {
    /// Lowercase letters, digits and '-', for --port=<name>=<port>.
    name: []const u8,
    /// Where other programs reach it, unless --port moves it.
    port: u16,
    /// The export whose runs serve it; without one, the app's own command.
    command: ?[]const u8 = null,
};

/// A port on this machine an app connects to: another app's service, or a
/// program of yours, such as a debugger's client in an IDE. Its config says
/// ${uses:<name>} where the app should connect, which isn't always the port
/// itself (see services.zig).
pub const Use = struct {
    /// Lowercase letters, digits and '-', for --port=<name>=<port>. Services
    /// and uses share the names of a run.
    name: []const u8,
    /// Where it's reached, unless --port moves it.
    port: u16,
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
    /// Aliases only: the caller's arguments to leave out, by value. zig's
    /// `as` alias drops the `--64` that GNU dlltool passes its assembler,
    /// which zig's cc doesn't take. Absent unless there are some.
    drop: ?[]const []const u8 = null,
};

/// A Start menu shortcut, like a Flatpak's .desktop file. It runs one of the
/// app's exports, through its shim.
pub const Shortcut = struct {
    /// The export it runs.
    command: []const u8,
    /// The shortcut's tooltip.
    description: ?[]const u8 = null,
    /// A file with the icon, in the app or a runtime: an .ico, or an .exe or
    /// .dll that has one. Without it, the export's executable.
    icon: ?[]const u8 = null,
};

/// A kind of file the app opens, by extension, like a MimeType in a Flatpak's
/// .desktop file. Windows then offers the app for such files; opening one
/// runs the export with the file, which the app is granted.
pub const Association = struct {
    /// The export that opens the file, given as its argument.
    command: []const u8,
    /// What Explorer calls such a file, e.g. "Rnote document".
    description: ?[]const u8 = null,
    /// A file with the icon such files show, as a shortcut's. Without it,
    /// the export's executable.
    icon: ?[]const u8 = null,
};

/// What placeholders in a config stand for. They are expanded when the app
/// runs, so images stay the same on every machine:
///   ${app}      the app's (read-only) directory
///   ${data}     the app's data directory, or the fresh one of an --ephemeral run
///   ${cache}    a directory for caches that are safe to keep: <data>\cache in
///               runs, and one kept between builds when a build uses the app
///   ${<alias>}  the directory of the runtime the app calls <alias>
///   ${listen:<name>}  the port the app listens on for its service <name>,
///               where its own runs connect too (see services.zig)
///   ${port:<name>}    the port other programs reach that service on
///   ${uses:<name>}    the port the app connects to for a port it uses
pub const Placeholders = struct {
    app: []const u8,
    data: []const u8,
    /// Null where caches don't apply; "${cache}" is then kept as is.
    cache: ?[]const u8 = null,
    runtimes: []const Dir = &.{},
    /// The app's services, in its own runs only; elsewhere their
    /// placeholders are kept as they are.
    services: []const ServicePorts = &.{},
    /// The ports a run uses, the app's, its runtimes' and its extensions',
    /// in all their entries; elsewhere their placeholders are kept as they
    /// are.
    uses: []const UsedPort = &.{},

    pub const Dir = struct { alias: []const u8, path: []const u8 };
    /// A service's ports, in decimal.
    pub const ServicePorts = struct { name: []const u8, listen: []const u8, port: []const u8 };
    /// Where a run connects for a port it uses, in decimal.
    pub const UsedPort = struct { name: []const u8, port: []const u8 };

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

    /// The file a command names: relative to the app's directory, or
    /// starting with a placeholder.
    pub fn commandPath(p: Placeholders, arena: std.mem.Allocator, command: []const u8) ![]u8 {
        const path = if (isPlaceholderPath(command))
            try p.expand(arena, command)
        else
            try std.fs.path.join(arena, &.{ p.app, command });
        std.mem.replaceScalar(u8, path, '/', '\\');
        return path;
    }

    fn lookup(p: Placeholders, name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "app")) return p.app;
        if (std.mem.eql(u8, name, "data")) return p.data;
        if (std.mem.eql(u8, name, "cache")) return p.cache;
        for (p.runtimes) |r| if (std.mem.eql(u8, r.alias, name)) return r.path;
        if (servicePlaceholder(name)) |s| for (p.services) |ports| if (std.mem.eql(u8, ports.name, s.service))
            return if (s.listen) ports.listen else ports.port;
        if (usePlaceholder(name)) |u| for (p.uses) |used| if (std.mem.eql(u8, used.name, u))
            return used.port;
        return null;
    }
};

/// The used port a "uses:<name>" placeholder names.
fn usePlaceholder(name: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, name, "uses:")) name["uses:".len..] else null;
}

/// The used ports an image's entries may name: its own, and an app's
/// runtimes'.
const UseScope = struct {
    own: []const Use,
    runtimes: []const Runtime = &.{},

    fn has(s: UseScope, name: []const u8) bool {
        for (s.own) |u| if (std.mem.eql(u8, u.name, name)) return true;
        for (s.runtimes) |r| for (r.uses orelse &.{}) |u| if (std.mem.eql(u8, u.name, name)) return true;
        return false;
    }
};

/// The first ${uses:x} in `template` whose x isn't in `scope`.
fn undeclaredUse(template: []const u8, scope: UseScope) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, template, i, "${")) |at| {
        i = at + 2;
        const name = placeholderAt(template[at..]) orelse return null;
        const u = usePlaceholder(name) orelse continue;
        if (!scope.has(u)) return name;
    }
    return null;
}

/// The service a "listen:<name>" or "port:<name>" placeholder names.
fn servicePlaceholder(name: []const u8) ?struct { service: []const u8, listen: bool } {
    if (std.mem.startsWith(u8, name, "listen:")) return .{ .service = name["listen:".len..], .listen = true };
    if (std.mem.startsWith(u8, name, "port:")) return .{ .service = name["port:".len..], .listen = false };
    return null;
}

/// The first ${listen:x} or ${port:x} in `template` whose service isn't one
/// of `services`.
fn undeclaredService(template: []const u8, services: []const Service) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, template, i, "${")) |at| {
        i = at + 2;
        const name = placeholderAt(template[at..]) orelse return null;
        const s = servicePlaceholder(name) orelse continue;
        for (services) |declared| {
            if (std.mem.eql(u8, declared.name, s.service)) break;
        } else return name;
    }
    return null;
}

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
    /// The runtime's aliases, which runs of the app get too. In them, ${app}
    /// is the runtime's directory. Absent unless it has some.
    aliases: ?std.json.ArrayHashMap(Export) = null,
    /// The runtime's extension points, which runs of the app have too.
    /// Absent unless it has some.
    extensions: ?std.json.ArrayHashMap(ExtensionPoint) = null,
    /// The ports the runtime uses (its `permissions.uses`), which runs of the
    /// app reach too. Absent unless it has some.
    uses: ?[]const Use = null,
};

/// Where images that extend an app or runtime plug in, like a Flatpak
/// runtime's extension points (see extensions.zig): an image whose `extends`
/// names the point, installed, joins every run of whatever has the point,
/// itself or as a runtime. PHP's runtime has one for PHP's extensions.
pub const ExtensionPoint = struct {
    /// What an extension must have been built for: it joins runs only if its
    /// own `extends.version` is the same. PHP's is its build id, as PHP
    /// checks extensions against it ("API20250925,NTS,VS17").
    version: []const u8,
    /// Variables each extension adds to, rather than sets: their entries,
    /// separated by ';', go after those already there. The app's own and its
    /// runtimes' values for them add up the same way.
    join: []const []const u8 = &.{},
};

/// What an extension image plugs into (see `ExtensionPoint`).
pub const Extends = struct {
    /// The extension point's name.
    point: []const u8,
    /// The point's version the extension was built for.
    version: []const u8,
    /// Extensions of the same point that must join a run before this one,
    /// by id, as one PHP extension that links with another's DLL. Without
    /// them, it doesn't join. Absent unless there are some.
    needs: ?[]const []const u8 = null,
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
    /// The manifest digests of the images whose files sources took, in
    /// recipe order. Absent unless a source is an image.
    images: ?[]const []const u8 = null,
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
    /// What people call the app ("VLC media player"), for `search` and
    /// `info`. Absent unless its recipe gives one, as are the three below.
    name: ?[]const u8 = null,
    /// What the app is, in a line.
    summary: ?[]const u8 = null,
    /// Where to read about it: an https URL.
    homepage: ?[]const u8 = null,
    /// Its licence, as an SPDX expression ("GPL-2.0-or-later").
    license: ?[]const u8 = null,
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
    /// Commands on the PATH of whatever runs with the image, by name: builds
    /// that use it as an SDK or runtime, its own runs, and runs of apps that
    /// have it as a runtime. Like exports, but not on the user's PATH. zig's
    /// image makes `cc` run `zig cc`, for instance. Absent unless there are
    /// some.
    aliases: ?std.json.ArrayHashMap(Export) = null,
    /// Start menu shortcuts, by the name they show. Absent unless there are
    /// some.
    shortcuts: ?std.json.ArrayHashMap(Shortcut) = null,
    /// The kinds of file the app opens, by extension (".rnote"). Absent
    /// unless there are some.
    associations: ?std.json.ArrayHashMap(Association) = null,
    /// Keys in HKEY_CURRENT_USER where the app keeps its settings, such as
    /// "Software\\7-Zip". zigsaw keeps them with the app's data, and puts
    /// them in the registry for its runs (see hkcu.zig). Absent unless there
    /// are some.
    registry: ?[]const []const u8 = null,
    /// The images the app runs with, by alias, in the order of their layers.
    runtimes: std.json.ArrayHashMap(Runtime) = .{},
    /// Extension points, by name: where installed images that extend this
    /// one plug in, in its own runs and those of apps that have it as a
    /// runtime. Absent unless it has some.
    extensions: ?std.json.ArrayHashMap(ExtensionPoint) = null,
    /// The extension point this image plugs into, if it's an extension.
    extends: ?Extends = null,
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
    for (m.layers) |l| if (layerCompression(l.mediaType) == null)
        return fail("{s} has a layer of type {s}, which zigsaw can't unpack", .{ what, l.mediaType });
    const runtimes = c.runtimes.map.values();
    if (m.layers.len != runtimes.len + 1)
        return fail("{s} has {d} layer(s), but its config accounts for {d}: one per runtime, and the app's own", .{ what, m.layers.len, runtimes.len + 1 });
    for (c.runtimes.map.keys(), runtimes, m.layers[0..runtimes.len]) |alias, r, l| if (!std.mem.eql(u8, r.layer, l.digest))
        return fail("{s}: runtime {s}'s layer {s} isn't in its manifest's place for it", .{ what, alias, r.layer });
}

pub const Compression = enum { none, gzip };

/// How a layer of this media type is compressed; null if it isn't a layer
/// type zigsaw can unpack.
pub fn layerCompression(layer_type: []const u8) ?Compression {
    if (std.mem.eql(u8, layer_type, media_type.layer_tar)) return .none;
    if (std.mem.eql(u8, layer_type, media_type.layer_tar_gzip)) return .gzip;
    return null;
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
    if (c.extends != null and c.runtimes.map.count() > 0)
        return fail("{s} extends {s}, so it can't have runtimes: the runs it joins wouldn't have them", .{ what, c.extends.?.point });
    // Its runtimes are known here, and an app's entries may name the ports
    // they use.
    const scope: UseScope = .{ .own = c.permissions.uses orelse &.{}, .runtimes = c.runtimes.map.values() };
    const where = "the app's arguments, variables and exports' arguments";
    for (c.args) |a| if (undeclaredUse(a, scope)) |name|
        return fail("{s}: ${{{s}}} names a port neither the app nor its runtimes use ({s} may name those)", .{ what, name, where });
    for (c.env.map.values()) |v| if (undeclaredUse(v, scope)) |name|
        return fail("{s}: ${{{s}}} names a port neither the app nor its runtimes use ({s} may name those)", .{ what, name, where });
    for (c.exports.map.values()) |e| for (e.args) |a| if (undeclaredUse(a, scope)) |name|
        return fail("{s}: ${{{s}}} names a port neither the app nor its runtimes use ({s} may name those)", .{ what, name, where });
}

/// The checks that don't need the runtimes resolved: recipes run them before
/// building, with the aliases they declare.
pub fn validateEntryPoints(what: []const u8, c: AppConfig, aliases: []const []const u8) error{Failed}!void {
    if (!isValidId(c.id))
        return fail("{s}: id \"{s}\" must be 1-57 characters of letters, digits, '.', '-', '_'", .{ what, c.id });
    // The registry's catalog of apps is <registry>/catalog (see catalog.zig).
    if (std.ascii.eqlIgnoreCase(c.id, "catalog"))
        return fail("{s}: the id \"catalog\" is the name of a registry's catalog of apps", .{what});
    if (c.version.len == 0)
        return fail("{s}: version must not be empty", .{what});
    if (c.name) |n| if (!isOneLine(n, 64))
        return fail("{s}: name must be 1-64 bytes on one line", .{what});
    if (c.summary) |s| if (!isOneLine(s, 160))
        return fail("{s}: summary must be 1-160 bytes on one line", .{what});
    if (c.homepage) |h| if (!isValidHomepage(h))
        return fail("{s}: homepage \"{s}\" must be an https:// URL of up to 256 bytes, without spaces", .{ what, h });
    if (c.license) |l| if (!isValidLicense(l))
        return fail("{s}: license \"{s}\" must be an SPDX expression, such as \"GPL-2.0-or-later\" or \"MIT OR Apache-2.0\"", .{ what, l });
    if (!isValidCommand(c.command, aliases))
        return fail("{s}: command \"{s}\" must be a relative path inside the app, or start with a runtime's ${{alias}}\\", .{ what, c.command });
    for (c.path) |p| if (!isValidPathEntry(p, aliases))
        return fail("{s}: path entry \"{s}\" must be a relative path inside the app, or start with ${{app}}, ${{data}}, ${{cache}} or a runtime's ${{alias}}", .{ what, p });
    // A name this zigsaw doesn't know passes: a later zigsaw's permission,
    // which a run leaves out.
    for (c.permissions.filesystem) |spec| if (parseFsGrant(spec) == null)
        return fail("{s}: filesystem permission \"{s}\" must be \"cwd\", one of the user's folders ({s}) or an absolute path, optionally with \":ro\"", .{ what, spec, UserFolder.list });
    try validateServices(what, c);
    try validateUses(what, "", c.permissions.uses, c.permissions.services orelse &.{});
    var it = c.exports.map.iterator();
    while (it.next()) |e| {
        if (!isValidExportName(e.key_ptr.*))
            return fail("{s}: export name \"{s}\" must be letters, digits, '.', '-', '_', '+' (and not zigsaw's own)", .{ what, e.key_ptr.* });
        if (!isValidCommand(e.value_ptr.command, aliases))
            return fail("{s}: export {s} command \"{s}\" must be a relative path inside the app, or start with a runtime's ${{alias}}\\", .{ what, e.key_ptr.*, e.value_ptr.command });
        if (e.value_ptr.drop != null)
            return fail("{s}: export {s} has \"drop\", which only aliases may have", .{ what, e.key_ptr.* });
    }
    if (c.aliases) |a| try validateAliases(what, "", a, aliases);
    if (c.shortcuts) |s| {
        const names = s.map.keys();
        for (names, s.map.values(), 0..) |name, shortcut, i| {
            if (!isValidShortcutName(name))
                return fail("{s}: shortcut name \"{s}\" must be 1-64 bytes without control characters or any of <>:\"/\\|?*, not start or end with a space or '.', and not be a device name such as CON", .{ what, name });
            for (names[0..i]) |earlier| if (std.ascii.eqlIgnoreCase(earlier, name))
                return fail("{s}: shortcuts \"{s}\" and \"{s}\" would be the same file", .{ what, earlier, name });
            if (!c.exports.map.contains(shortcut.command))
                return fail("{s}: shortcut \"{s}\" runs \"{s}\", which isn't one of the app's exports", .{ what, name, shortcut.command });
            if (shortcut.icon) |icon| if (!isValidCommand(icon, aliases))
                return fail("{s}: shortcut \"{s}\" icon \"{s}\" must be a relative path inside the app, or start with a runtime's ${{alias}}\\", .{ what, name, icon });
            if (shortcut.description) |d| if (d.len > 256)
                return fail("{s}: shortcut \"{s}\" description is longer than 256 bytes", .{ what, name });
        }
    }
    if (c.associations) |a| {
        const extensions = a.map.keys();
        for (extensions, a.map.values(), 0..) |ext, association, i| {
            if (!isValidExtension(ext))
                return fail("{s}: association \"{s}\" must be a file extension: a '.', then 1-32 letters, digits, '-', '_' or '+'", .{ what, ext });
            for (extensions[0..i]) |earlier| if (std.ascii.eqlIgnoreCase(earlier, ext))
                return fail("{s}: associations \"{s}\" and \"{s}\" are the same extension", .{ what, earlier, ext });
            if (!c.exports.map.contains(association.command))
                return fail("{s}: association \"{s}\" opens with \"{s}\", which isn't one of the app's exports", .{ what, ext, association.command });
            if (association.icon) |icon| if (!isValidCommand(icon, aliases))
                return fail("{s}: association \"{s}\" icon \"{s}\" must be a relative path inside the app, or start with a runtime's ${{alias}}\\", .{ what, ext, icon });
            if (association.description) |d| if (d.len == 0 or d.len > 256 or std.mem.indexOfAny(u8, d, "\r\n") != null)
                return fail("{s}: association \"{s}\" description must be 1-256 bytes on one line", .{ what, ext });
        }
    }
    if (c.registry) |keys| for (keys, 0..) |key, i| {
        if (!isValidRegistryKey(key))
            return fail("{s}: registry key \"{s}\" must be a key of the app's own in HKEY_CURRENT_USER\\Software, such as \"Software\\\\7-Zip\": no other root, not Software itself, nor Classes, Microsoft, Policies, Wow6432Node, AppDataLow or zigsaw in it", .{ what, key });
        for (keys[0..i]) |earlier| if (registryKeyWithin(earlier, key) or registryKeyWithin(key, earlier))
            return fail("{s}: registry keys \"{s}\" and \"{s}\" overlap", .{ what, earlier, key });
    };
    if (c.extensions) |e| try validateExtensionPoints(what, "", e);
    if (c.extends) |x| {
        if (!isValidId(x.point))
            return fail("{s}: extends point \"{s}\" must be an extension point's name: 1-57 characters of letters, digits, '.', '-', '_'", .{ what, x.point });
        if (!isOneLine(x.version, 64))
            return fail("{s}: extends version must be 1-64 bytes on one line", .{what});
        if (x.needs) |needs| for (needs) |id| if (!isValidId(id) or std.ascii.eqlIgnoreCase(id, c.id))
            return fail("{s}: extends needs \"{s}\", which must be another extension's id", .{ what, id });
    }
}

/// Checks the app's services, and that the placeholders of its own entries
/// name only services it has.
fn validateServices(what: []const u8, c: AppConfig) error{Failed}!void {
    const services = c.permissions.services orelse &.{};
    if (c.permissions.services != null and services.len == 0)
        return fail("{s}: services must list at least one, or be left out", .{what});
    for (services, 0..) |s, i| {
        if (!isValidServiceName(s.name))
            return fail("{s}: service name \"{s}\" must be 1-32 lowercase letters, digits and '-'", .{ what, s.name });
        for (services[0..i]) |earlier| if (std.mem.eql(u8, earlier.name, s.name))
            return fail("{s}: two services are called \"{s}\"", .{ what, s.name });
        if (s.port == 0) return fail("{s}: service {s} must have a port from 1 to 65535", .{ what, s.name });
        for (services[0..i]) |earlier| if (earlier.port == s.port)
            return fail("{s}: services {s} and {s} both have port {d}", .{ what, earlier.name, s.name, s.port });
        if (s.command) |command| if (!c.exports.map.contains(command))
            return fail("{s}: service {s} is served by \"{s}\", which isn't one of the app's exports", .{ what, s.name, command });
    }
    const where = "the app's arguments, variables and exports' arguments";
    for (c.args) |a| if (undeclaredService(a, services)) |name|
        return fail("{s}: ${{{s}}} names a service the app doesn't have ({s} may name its own)", .{ what, name, where });
    for (c.env.map.values()) |v| if (undeclaredService(v, services)) |name|
        return fail("{s}: ${{{s}}} names a service the app doesn't have ({s} may name its own)", .{ what, name, where });
    for (c.exports.map.values()) |e| for (e.args) |a| if (undeclaredService(a, services)) |name|
        return fail("{s}: ${{{s}}} names a service the app doesn't have ({s} may name its own)", .{ what, name, where });
}

/// Checks the ports an image uses, or (`owner` "runtime x's ") those an
/// app's config copied from a runtime. Their names are those of services
/// too, for --port, so none is a service's.
fn validateUses(what: []const u8, owner: []const u8, uses: ?[]const Use, services: []const Service) error{Failed}!void {
    const list = uses orelse return;
    if (list.len == 0) return fail("{s}: {s}uses must list at least one port, or be left out", .{ what, owner });
    for (list, 0..) |u, i| {
        if (!isValidServiceName(u.name))
            return fail("{s}: {s}used port name \"{s}\" must be 1-32 lowercase letters, digits and '-'", .{ what, owner, u.name });
        for (list[0..i]) |earlier| if (std.mem.eql(u8, earlier.name, u.name))
            return fail("{s}: {s}uses two ports called \"{s}\"", .{ what, owner, u.name });
        for (services) |s| if (std.mem.eql(u8, s.name, u.name))
            return fail("{s}: \"{s}\" is the name of both a service and a port the app uses", .{ what, u.name });
        if (u.port == 0) return fail("{s}: {s}used port {s} must be from 1 to 65535", .{ what, owner, u.name });
        for (list[0..i]) |earlier| if (earlier.port == u.port)
            return fail("{s}: {s}uses port {d} as both {s} and {s}", .{ what, owner, u.port, earlier.name, u.name });
    }
}

/// "localhost:9003 (dbgp)", for `info` and what `pull` shows.
pub fn describeUses(arena: std.mem.Allocator, uses: []const Use) ![]const u8 {
    const parts = try arena.alloc([]const u8, uses.len);
    for (parts, uses) |*p, u| p.* = try std.fmt.allocPrint(arena, "localhost:{d} ({s})", .{ u.port, u.name });
    return joinAnd(arena, parts);
}

fn isValidServiceName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    for (name) |ch| switch (ch) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

/// "postgresql on localhost:5432", for `info` and what `pull` shows.
pub fn describeServices(arena: std.mem.Allocator, services: []const Service) ![]const u8 {
    const parts = try arena.alloc([]const u8, services.len);
    for (parts, services) |*p, s| p.* = try std.fmt.allocPrint(arena, "{s} on localhost:{d}", .{ s.name, s.port });
    return joinAnd(arena, parts);
}

/// Checks an image's extension points, or (`owner` "runtime x's ") those an
/// app's config copied from a runtime.
fn validateExtensionPoints(what: []const u8, owner: []const u8, points: std.json.ArrayHashMap(ExtensionPoint)) error{Failed}!void {
    for (points.map.keys(), points.map.values()) |name, p| {
        if (!isValidId(name))
            return fail("{s}: {s}extension point \"{s}\" must be 1-57 characters of letters, digits, '.', '-', '_'", .{ what, owner, name });
        if (!isOneLine(p.version, 64))
            return fail("{s}: {s}extension point {s}'s version must be 1-64 bytes on one line", .{ what, owner, name });
        for (p.join) |v| if (!isValidJoinName(v))
            return fail("{s}: {s}extension point {s} joins \"{s}\", which must be a variable's name, not PATH (extensions' path entries go on PATH anyway)", .{ what, owner, name, v });
    }
}

/// A variable extensions add to: a plain name, and not PATH, which zigsaw
/// makes itself.
fn isValidJoinName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or std.ascii.eqlIgnoreCase(name, "PATH")) return false;
    for (name) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '(', ')' => {},
        else => return false,
    };
    return true;
}

test "extension points and extends" {
    const ok: AppConfig = .{ .id = "rt", .version = "1", .command = "x.exe" };
    var points: std.json.ArrayHashMap(ExtensionPoint) = .{};
    defer points.map.deinit(std.testing.allocator);
    try points.map.put(std.testing.allocator, "rt.ext", .{ .version = "API1,NTS", .join = &.{"PHP_INI_SCAN_DIR"} });
    var c = ok;
    c.extensions = points;
    try validateConfig("t", c);
    c.extends = .{ .point = "other", .version = "1", .needs = &.{"rt.ext.a"} };
    try validateConfig("t", c);

    var bad: std.json.ArrayHashMap(ExtensionPoint) = .{};
    defer bad.map.deinit(std.testing.allocator);
    try bad.map.put(std.testing.allocator, "rt.ext", .{ .version = "1", .join = &.{"Path"} });
    c = ok;
    c.extensions = bad;
    try std.testing.expectError(error.Failed, validateConfig("t", c));
    bad.map.values()[0].join = &.{"A=B"};
    try std.testing.expectError(error.Failed, validateConfig("t", c));
    bad.map.values()[0] = .{ .version = "" };
    try std.testing.expectError(error.Failed, validateConfig("t", c));

    c = ok;
    c.extends = .{ .point = "a b", .version = "1" };
    try std.testing.expectError(error.Failed, validateConfig("t", c));
    c.extends = .{ .point = "p", .version = "1", .needs = &.{"rt"} };
    try std.testing.expectError(error.Failed, validateConfig("t", c));

    // Runs that an extension joins wouldn't have its runtimes.
    c = ok;
    c.extends = .{ .point = "p", .version = "1" };
    const digest = "sha256:" ++ "a" ** 64;
    try c.runtimes.map.put(std.testing.allocator, "r", .{ .id = "r", .version = "1", .image = digest, .layer = digest });
    defer c.runtimes.map.deinit(std.testing.allocator);
    try std.testing.expectError(error.Failed, validateConfig("t", c));
}

/// 1 to `max` bytes, without control characters.
fn isOneLine(s: []const u8, max: usize) bool {
    if (s.len == 0 or s.len > max) return false;
    for (s) |ch| if (ch < 0x20 or ch == 0x7f) return false;
    return true;
}

fn isValidHomepage(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "https://") or url.len <= "https://".len or url.len > 256) return false;
    for (url) |ch| if (ch <= 0x20 or ch == 0x7f) return false;
    return true;
}

/// SPDX license expressions: identifiers ("LicenseRef-..." included), "WITH",
/// "AND", "OR" and parentheses.
fn isValidLicense(l: []const u8) bool {
    if (l.len == 0 or l.len > 128) return false;
    for (l) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '+', ' ', '(', ')', ':' => {},
        else => return false,
    };
    return true;
}

/// What `p` lets an app reach, in words, for `pull`, `update` and `info`:
/// "the network; the directory you run it from; your Documents and
/// Downloads; C:\data (read-only)".
pub fn describePermissions(arena: std.mem.Allocator, p: Permissions) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    if (p.network) try parts.append(arena, "the network");
    var folders: [2]std.ArrayList([]const u8) = .{ .empty, .empty };
    for (p.filesystem) |spec| {
        const g = parseFsGrant(spec) orelse continue;
        const access = if (g.read_only) " (read-only)" else "";
        switch (g.where) {
            .cwd => try parts.append(arena, try std.fmt.allocPrint(arena, "the directory you run it from{s}", .{access})),
            .path => |path| try parts.append(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ path, access })),
            .folder => |f| {
                const name = try arena.dupe(u8, @tagName(f));
                name[0] = std.ascii.toUpper(name[0]);
                try folders[@intFromBool(g.read_only)].append(arena, name);
            },
            .unknown => |name| try parts.append(arena, try std.fmt.allocPrint(arena, "\"{s}\", which this zigsaw doesn't know", .{name})),
        }
    }
    for (folders, [_][]const u8{ "", " (read-only)" }) |list, access| if (list.items.len > 0)
        try parts.append(arena, try std.fmt.allocPrint(arena, "your {s}{s}", .{ try joinAnd(arena, list.items), access }));
    if (parts.items.len == 0) return "nothing outside its own files";
    return std.mem.join(arena, "; ", parts.items);
}

/// The keys an app keeps (see `AppConfig.registry`) in full, for messages:
/// "HKCU\Software\7-Zip".
pub fn describeRegistry(arena: std.mem.Allocator, keys: []const []const u8) ![]const u8 {
    const full = try arena.alloc([]const u8, keys.len);
    for (full, keys) |*f, k| f.* = try std.fmt.allocPrint(arena, "HKCU\\{s}", .{k});
    return joinAnd(arena, full);
}

/// "a", "a and b", "a, b and c".
pub fn joinAnd(arena: std.mem.Allocator, items: []const []const u8) ![]const u8 {
    if (items.len <= 1) return if (items.len == 1) items[0] else "";
    return std.fmt.allocPrint(arena, "{s} and {s}", .{ try std.mem.join(arena, ", ", items[0 .. items.len - 1]), items[items.len - 1] });
}

/// What an app reaches outside its own files: its permissions, the ports it
/// and its runtimes use, and the HKCU keys it keeps, which its runs write
/// into the user's registry.
pub const Access = struct {
    permissions: Permissions = .{},
    /// The app's, then its runtimes' not of a name already there, as runs
    /// have them.
    uses: []const Use = &.{},
    registry: []const []const u8 = &.{},

    pub fn of(arena: std.mem.Allocator, cfg: AppConfig) !Access {
        var uses: std.ArrayList(Use) = .empty;
        try addUses(arena, &uses, cfg.permissions.uses orelse &.{});
        for (cfg.runtimes.map.values()) |r| try addUses(arena, &uses, r.uses orelse &.{});
        return .{ .permissions = cfg.permissions, .uses = uses.items, .registry = cfg.registry orelse &.{} };
    }

    pub fn isEmpty(a: Access) bool {
        return !a.permissions.network and a.permissions.filesystem.len == 0 and a.uses.len == 0 and a.registry.len == 0;
    }
};

/// Adds the used ports of `more` whose names `list` doesn't have yet: the
/// first image to use a name has it.
pub fn addUses(arena: std.mem.Allocator, list: *std.ArrayList(Use), more: []const Use) !void {
    for (more) |u| {
        for (list.items) |had| {
            if (std.mem.eql(u8, had.name, u.name)) break;
        } else try list.append(arena, u);
    }
}

/// What `after` lets an app reach that `before` didn't, which an update asks
/// about: the network, a location it couldn't use, or could only read, a
/// port it didn't use, and a key it didn't keep. A location or key inside
/// one it had counts as had.
pub fn addedAccess(arena: std.mem.Allocator, before: Access, after: Access) !Access {
    var uses: std.ArrayList(Use) = .empty;
    for (after.uses) |u| {
        for (before.uses) |had| {
            if (had.port == u.port) break;
        } else try uses.append(arena, u);
    }
    var filesystem: std.ArrayList([]const u8) = .empty;
    for (after.permissions.filesystem) |spec| {
        const want = parseFsGrant(spec) orelse continue;
        const had = for (before.permissions.filesystem) |b| {
            const g = parseFsGrant(b) orelse continue;
            if ((want.read_only or !g.read_only) and covers(g.where, want.where)) break true;
        } else false;
        if (!had) try filesystem.append(arena, spec);
    }
    var keys: std.ArrayList([]const u8) = .empty;
    for (after.registry) |key| {
        const had = for (before.registry) |b| {
            if (isWithin(key, b)) break true;
        } else false;
        if (!had) try keys.append(arena, key);
    }
    return .{
        .permissions = .{ .network = after.permissions.network and !before.permissions.network, .filesystem = filesystem.items },
        .uses = uses.items,
        .registry = keys.items,
    };
}

fn covers(had: FsGrant.Where, want: FsGrant.Where) bool {
    return switch (want) {
        .cwd => had == .cwd,
        .folder => |f| had == .folder and had.folder == f,
        .path => |p| had == .path and isWithin(p, had.path),
        .unknown => |name| had == .unknown and std.mem.eql(u8, had.unknown, name),
    };
}

/// Whether `path` is `dir` or inside it, ignoring case and a trailing
/// separator. For paths and registry keys.
fn isWithin(path: []const u8, dir: []const u8) bool {
    const p = std.mem.trimEnd(u8, path, "\\/");
    const d = std.mem.trimEnd(u8, dir, "\\/");
    if (p.len < d.len or !std.ascii.eqlIgnoreCase(p[0..d.len], d)) return false;
    return p.len == d.len or p[d.len] == '\\' or p[d.len] == '/';
}

test addedAccess {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before: Access = .{
        .permissions = .{ .filesystem = &.{ "cwd", "documents:ro", "C:\\Data\\", "C:\\Logs:ro" } },
        .registry = &.{"Software\\7-Zip"},
    };
    // The same, in another order and spelling, and less: nothing added.
    try std.testing.expect((try addedAccess(arena, before, .{
        .permissions = .{ .filesystem = &.{ "c:\\data\\sub", "documents:ro", "cwd:rw" } },
        .registry = &.{"software\\7-zip\\FM"},
    })).isEmpty());
    try std.testing.expect((try addedAccess(arena, before, .{})).isEmpty());

    const added = try addedAccess(arena, before, .{
        .permissions = .{ .network = true, .filesystem = &.{ "cwd", "documents", "downloads:ro", "C:\\Logs", "C:\\Database" } },
        .registry = &.{ "Software\\7-Zip", "Software\\Other" },
    });
    try std.testing.expect(added.permissions.network);
    try std.testing.expectEqual(4, added.permissions.filesystem.len);
    try std.testing.expectEqualStrings("documents", added.permissions.filesystem[0]);
    try std.testing.expectEqualStrings("downloads:ro", added.permissions.filesystem[1]);
    try std.testing.expectEqualStrings("C:\\Logs", added.permissions.filesystem[2]);
    try std.testing.expectEqualStrings("C:\\Database", added.permissions.filesystem[3]);
    try std.testing.expectEqual(1, added.registry.len);
    try std.testing.expectEqualStrings("Software\\Other", added.registry[0]);
}

test describePermissions {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("nothing outside its own files", try describePermissions(arena, .{}));
    try std.testing.expectEqualStrings(
        "the network; the directory you run it from; C:\\data (read-only); \"xdg-later\", which this zigsaw doesn't know; your Desktop, Downloads and Videos; your Music (read-only)",
        try describePermissions(arena, .{ .network = true, .filesystem = &.{ "cwd", "desktop", "C:\\data:ro", "downloads:rw", "music:ro", "videos", "xdg-later" } }),
    );
}

test "app metadata" {
    try std.testing.expect(isValidLicense("MIT OR Apache-2.0"));
    try std.testing.expect(isValidLicense("LGPL-2.1-or-later AND (BSD-3-Clause OR LicenseRef-unRAR)"));
    try std.testing.expect(!isValidLicense("MIT; rm -rf"));
    try std.testing.expect(isValidHomepage("https://www.videolan.org/vlc/"));
    try std.testing.expect(!isValidHomepage("http://example.com"));
    try std.testing.expect(!isValidHomepage("https://a b"));
    try std.testing.expect(isOneLine("VLC media player", 64));
    try std.testing.expect(!isOneLine("two\nlines", 64));
}

/// A key the app keeps (see `AppConfig.registry`): a path relative to
/// HKEY_CURRENT_USER, below Software and its own there. Not the keys Windows
/// and zigsaw keep for everyone (Classes, Microsoft...), which a run moving
/// aside would break. Parts are plain names, without '/', which zigsaw's own
/// record of a key uses instead of '\'.
pub fn isValidRegistryKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 255) return false;
    var parts = std.mem.splitScalar(u8, key, '\\');
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        for (part) |ch| if (ch < 0x20 or ch == 0x7f or ch == '/') return false;
        if (count == 0 and !std.ascii.eqlIgnoreCase(part, "Software")) return false;
        if (count == 1) for ([_][]const u8{ "Classes", "Microsoft", "Policies", "Wow6432Node", "AppDataLow", "zigsaw" }) |shared|
            if (std.ascii.eqlIgnoreCase(part, shared)) return false;
    }
    return count >= 2;
}

/// Whether registry key `inner` is `outer` or below it.
fn registryKeyWithin(outer: []const u8, inner: []const u8) bool {
    if (inner.len < outer.len or !std.ascii.eqlIgnoreCase(inner[0..outer.len], outer)) return false;
    return inner.len == outer.len or inner[outer.len] == '\\';
}

test isValidRegistryKey {
    for ([_][]const u8{ "Software\\7-Zip", "software\\VideoLAN\\VLC", "Software\\Some App\\Settings" }) |k|
        try std.testing.expect(isValidRegistryKey(k));
    for ([_][]const u8{
        "",                   "Software",               "Software\\",       "\\Software\\x",
        "SOFTWARE\\Classes",  "Software\\Microsoft\\x", "Software\\zigsaw", "Software\\AppDataLow\\x",
        "Software\\Policies", "Software\\Wow6432Node",  "System\\x",        "Software\\a\\\\b",
        "Software\\..\\x",    "Software\\a/b",          "Software\\a\x01",  "HKCU\\Software\\x",
    }) |k| try std.testing.expect(!isValidRegistryKey(k));
    try std.testing.expect(registryKeyWithin("Software\\A", "software\\a\\B"));
    try std.testing.expect(registryKeyWithin("Software\\A", "Software\\A"));
    try std.testing.expect(!registryKeyWithin("Software\\A", "Software\\AB"));
}

/// Extensions name registry keys, and end the name of the app's own
/// (`Zigsaw.<id>.<extension>`), so they are plain.
pub fn isValidExtension(ext: []const u8) bool {
    if (ext.len < 2 or ext.len > 33 or ext[0] != '.') return false;
    for (ext[1..]) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '+' => {},
        else => return false,
    };
    return true;
}

test isValidExtension {
    for ([_][]const u8{ ".rnote", ".xopp", ".TXT", ".c++", ".tar-gz", ".7z" }) |ok|
        try std.testing.expect(isValidExtension(ok));
    for ([_][]const u8{ "", ".", "rnote", "..x", ".a.b", ".a b", ".a\\b", ".é", "." ++ "x" ** 33 }) |bad|
        try std.testing.expect(!isValidExtension(bad));
}

/// Checks an image's aliases, or (`owner` "runtime x's ") those an app's
/// config copied from a runtime. Builds run an image's aliases from the image
/// itself, whose runtimes they don't have. And an app's runs share one set of
/// alias shims, ephemeral runs too, so they can't name a run's ${data} or
/// ${cache}.
/// An image's aliases run a file in it, or in one of its own runtimes, which
/// `runtimes` names: Composer's alias runs PHP's php.exe. A runtime's, which
/// apps copy, have only the runtime itself, as runtimes have no runtimes.
fn validateAliases(what: []const u8, owner: []const u8, aliases: std.json.ArrayHashMap(Export), runtimes: []const []const u8) error{Failed}!void {
    for (aliases.map.keys(), aliases.map.values()) |name, e| {
        if (!isValidExportName(name))
            return fail("{s}: {s}alias name \"{s}\" must be letters, digits, '.', '-', '_', '+' (and not zigsaw's own)", .{ what, owner, name });
        if (!isValidCommand(e.command, runtimes)) {
            if (runtimes.len == 0)
                return fail("{s}: {s}alias {s} command \"{s}\" must be a relative path inside the image", .{ what, owner, name, e.command });
            return fail("{s}: {s}alias {s} command \"{s}\" must be a relative path inside the image, or start with one of its runtimes' ${{alias}}\\", .{ what, owner, name, e.command });
        }
        for (e.args) |arg| if (std.mem.indexOf(u8, arg, "${data}") != null or std.mem.indexOf(u8, arg, "${cache}") != null)
            return fail("{s}: {s}alias {s} argument \"{s}\" can't use ${{data}} or ${{cache}}", .{ what, owner, name, arg });
        // Shims keep them one per line, trimmed.
        if (e.drop) |drop| for (drop) |d| {
            if (d.len == 0 or std.mem.indexOfAny(u8, d, "\r\n") != null or std.mem.trim(u8, d, " \t").len != d.len)
                return fail("{s}: {s}alias {s} drops \"{s}\": arguments to drop must be non-empty, on one line, without spaces or tabs at either end", .{ what, owner, name, d });
        };
    }
}

/// Shortcut names become file names (`<name>.lnk`), which people see, so
/// they may have spaces and any letters, but nothing Windows refuses.
pub fn isValidShortcutName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or !std.unicode.utf8ValidateSlice(name)) return false;
    for (name) |c| switch (c) {
        0...31, 127, '<', '>', ':', '"', '/', '\\', '|', '?', '*' => return false,
        else => {},
    };
    for ([_]u8{ name[0], name[name.len - 1] }) |c| if (c == ' ' or c == '.') return false;
    // Windows reserves these names, with any extension.
    const stem = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL" }) |device| if (std.ascii.eqlIgnoreCase(stem, device)) return false;
    if (stem.len == 4 and (std.ascii.startsWithIgnoreCase(stem, "COM") or std.ascii.startsWithIgnoreCase(stem, "LPT")) and
        stem[3] >= '0' and stem[3] <= '9') return false;
    return true;
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
        var owner_buf: [64]u8 = undefined;
        const owner = std.fmt.bufPrint(&owner_buf, "runtime {s}'s ", .{alias}) catch "a runtime's ";
        if (r.aliases) |a| try validateAliases(what, owner, a, &.{});
        if (r.extensions) |e| try validateExtensionPoints(what, owner, e);
        try validateUses(what, owner, r.uses, &.{});
        for (r.env.map.values()) |v| if (undeclaredUse(v, .{ .own = r.uses orelse &.{} })) |name|
            return fail("{s}: ${{{s}}} in {s}variables names a port it doesn't use", .{ what, name, owner });
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
/// and can't shadow zigsaw's own executables. '+' is for names like c++.
pub fn isValidExportName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '.') return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_', '+' => {},
        else => return false,
    };
    for ([_][]const u8{ "zigsaw", "zigsaw-shim", "zigsaw-shimw" }) |reserved| {
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

/// The user's own folders, which an app may be granted by name, like
/// Flatpak's xdg-documents (folders.zig).
pub const UserFolder = enum {
    desktop,
    documents,
    downloads,
    music,
    pictures,
    videos,

    /// For messages.
    pub const list = "desktop, documents, downloads, music, pictures, videos";

    pub fn parse(name: []const u8) ?UserFolder {
        inline for (@typeInfo(UserFolder).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(name, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

pub const FsGrant = struct {
    where: Where,
    read_only: bool,

    pub const Where = union(enum) {
        /// The working directory zigsaw was started from.
        cwd,
        /// An absolute path.
        path: []const u8,
        folder: UserFolder,
        /// A name this zigsaw doesn't know, such as a folder that a later
        /// zigsaw added: an image may ask for it, and a run leaves it out.
        unknown: []const u8,
    };
};

/// Parses a filesystem permission: "cwd", one of the user's folders or an
/// absolute path, optionally followed by ":ro" or ":rw". Any other lowercase
/// name is `.unknown`.
pub fn parseFsGrant(spec: []const u8) ?FsGrant {
    var s = spec;
    var read_only = false;
    if (std.mem.endsWith(u8, s, ":ro")) {
        read_only = true;
        s = s[0 .. s.len - 3];
    } else if (std.mem.endsWith(u8, s, ":rw")) {
        s = s[0 .. s.len - 3];
    }
    const where: FsGrant.Where = if (std.mem.eql(u8, s, "cwd"))
        .cwd
    else if (UserFolder.parse(s)) |f|
        .{ .folder = f }
    else if (std.fs.path.isAbsoluteWindows(s) and s.len > 2)
        .{ .path = s }
    else if (isPermissionName(s))
        .{ .unknown = s }
    else
        return null;
    return .{ .where = where, .read_only = read_only };
}

/// A lowercase name, such as "xdg-config", optionally followed by a
/// subpath: "documents/notes". What a later zigsaw might add.
fn isPermissionName(s: []const u8) bool {
    const name_end = std.mem.indexOfScalar(u8, s, '/') orelse s.len;
    if (name_end == 0 or !std.ascii.isLower(s[0])) return false;
    for (s[0..name_end]) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-') return false;
    return std.mem.indexOfAny(u8, s, "\\:") == null;
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

test isValidShortcutName {
    for ([_][]const u8{ "Text Editor", "GTK 4 Demo", "Éditeur de texte", "a", "Notes (beta)", "x.y", "COM10", "Console" }) |ok|
        try std.testing.expect(isValidShortcutName(ok));
    for ([_][]const u8{ "", " lead", "trail ", "dot.", ".dot", "a/b", "a\\b", "a:b", "what?", "tab\there", "con", "Nul.txt", "COM1", "lpt9", "\xff" }) |bad|
        try std.testing.expect(!isValidShortcutName(bad));
    try std.testing.expect(!isValidShortcutName("x" ** 65));
}

test isValidExportName {
    try std.testing.expect(isValidExportName("node"));
    try std.testing.expect(isValidExportName("python3.14"));
    try std.testing.expect(isValidExportName("c++"));
    try std.testing.expect(!isValidExportName("Zigsaw"));
    try std.testing.expect(!isValidExportName("zigsaw-shimW"));
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

test "Placeholders.expand services" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p: Placeholders = .{
        .app = "C:\\z\\deploy\\ab",
        .data = "C:\\z\\data\\x",
        .services = &.{ .{ .name = "http", .listen = "23817", .port = "8471" }, .{ .name = "admin", .listen = "9000", .port = "9000" } },
    };
    try std.testing.expectEqualStrings("127.0.0.1:23817", try p.expand(arena, "127.0.0.1:${listen:http}"));
    try std.testing.expectEqualStrings("http://127.0.0.1:8471/", try p.expand(arena, "http://127.0.0.1:${port:http}/"));
    try std.testing.expectEqualStrings("9000", try p.expand(arena, "${port:admin}"));
    // A service the app doesn't have, and other names, stay as they are.
    try std.testing.expectEqualStrings("${listen:db} ${listen} ${port:}", try p.expand(arena, "${listen:db} ${listen} ${port:}"));
}

test validateServices {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var c: AppConfig = .{ .id = "app", .version = "1", .command = "server.exe", .args = &.{"--port=${listen:http}"} };
    try c.exports.map.put(arena, "server", .{ .command = "server.exe", .args = &.{"--url=http://localhost:${port:http}/"} });
    // Without a service, its placeholders name nothing.
    try std.testing.expectError(error.Failed, validateServices("x", c));
    c.permissions.services = &.{.{ .name = "http", .port = 8471, .command = "server" }};
    try validateServices("x", c);
    try c.env.map.put(arena, "DB_PORT", "${port:db}");
    try std.testing.expectError(error.Failed, validateServices("x", c));
    _ = c.env.map.orderedRemove("DB_PORT");

    const bad = [_][]const Service{
        &.{},
        &.{.{ .name = "HTTP", .port = 80 }},
        &.{.{ .name = "a_b", .port = 80 }},
        &.{.{ .name = "http", .port = 0 }},
        &.{ .{ .name = "http", .port = 80 }, .{ .name = "http", .port = 81 } },
        &.{ .{ .name = "http", .port = 80 }, .{ .name = "other", .port = 80 } },
        &.{.{ .name = "http", .port = 80, .command = "missing" }},
    };
    for (bad) |services| {
        c.permissions.services = services;
        try std.testing.expectError(error.Failed, validateServices("x", c));
    }
    try std.testing.expectEqualStrings("http on localhost:8471 and db on localhost:5432", try describeServices(arena, &.{
        .{ .name = "http", .port = 8471 },
        .{ .name = "db", .port = 5432 },
    }));
}

test "Placeholders.expand uses" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p: Placeholders = .{ .app = "C:\\a", .data = "C:\\d", .uses = &.{.{ .name = "dbgp", .port = "23817" }} };
    try std.testing.expectEqualStrings("client_port=23817", try p.expand(arena, "client_port=${uses:dbgp}"));
    try std.testing.expectEqualStrings("${uses:db} ${uses}", try p.expand(arena, "${uses:db} ${uses}"));
}

test "uses: names, ports, and the placeholders that name them" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const digest = "sha256:" ++ "a" ** 64;
    var c: AppConfig = .{ .id = "app", .version = "1", .command = "app.exe" };
    try c.env.map.put(arena, "PGPORT", "${uses:postgresql}");
    // Nothing uses it.
    try std.testing.expectError(error.Failed, validateConfig("x", c));
    c.permissions.uses = &.{.{ .name = "postgresql", .port = 5432 }};
    try validateConfig("x", c);
    // A runtime's, which the app may name too, and whose own variables
    // name only its own.
    c.permissions.uses = null;
    var rt_env: std.json.ArrayHashMap([]const u8) = .{};
    try rt_env.map.put(arena, "XDEBUG_CLIENT_PORT", "${uses:dbgp}");
    try c.runtimes.map.put(arena, "xdebug", .{ .id = "x", .version = "1", .image = digest, .layer = digest, .env = rt_env, .uses = &.{.{ .name = "dbgp", .port = 9003 }} });
    try std.testing.expectError(error.Failed, validateConfig("x", c));
    _ = c.env.map.orderedRemove("PGPORT");
    try c.env.map.put(arena, "DEBUGGER", "${uses:dbgp}");
    try validateConfig("x", c);
    try rt_env.map.put(arena, "PGPORT", "${uses:postgresql}");
    c.runtimes.map.getPtr("xdebug").?.env = rt_env;
    c.permissions.uses = &.{.{ .name = "postgresql", .port = 5432 }};
    try std.testing.expectError(error.Failed, validateConfig("x", c));
    _ = c.runtimes.map.orderedRemove("xdebug");
    _ = c.env.map.orderedRemove("DEBUGGER");

    const bad = [_][]const Use{
        &.{},
        &.{.{ .name = "Postgres", .port = 5432 }},
        &.{.{ .name = "db", .port = 0 }},
        &.{ .{ .name = "db", .port = 5432 }, .{ .name = "db", .port = 5433 } },
        &.{ .{ .name = "db", .port = 5432 }, .{ .name = "pg", .port = 5432 } },
        // A service's name.
        &.{.{ .name = "http", .port = 80 }},
    };
    c.permissions.services = &.{.{ .name = "http", .port = 8471 }};
    for (bad) |uses| {
        c.permissions.uses = uses;
        try std.testing.expectError(error.Failed, validateConfig("x", c));
    }
    try std.testing.expectEqualStrings("localhost:5432 (postgresql) and localhost:9003 (dbgp)", try describeUses(arena, &.{
        .{ .name = "postgresql", .port = 5432 },
        .{ .name = "dbgp", .port = 9003 },
    }));
}

test "Access: the runtimes' uses, and a new port counted as added" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const digest = "sha256:" ++ "a" ** 64;
    var c: AppConfig = .{ .id = "app", .version = "1", .command = "app.exe" };
    c.permissions.uses = &.{.{ .name = "db", .port = 5432 }};
    try c.runtimes.map.put(arena, "x", .{ .id = "x", .version = "1", .image = digest, .layer = digest, .uses = &.{
        .{ .name = "db", .port = 1 },
        .{ .name = "dbgp", .port = 9003 },
    } });
    const access: Access = try .of(arena, c);
    try std.testing.expectEqual(2, access.uses.len);
    try std.testing.expectEqual(5432, access.uses[0].port);
    try std.testing.expect(!access.isEmpty());
    // The same ports under other names aren't more; another port is.
    try std.testing.expect((try addedAccess(arena, access, .{ .uses = &.{.{ .name = "pg", .port = 5432 }} })).isEmpty());
    const added = try addedAccess(arena, access, .{ .uses = &.{.{ .name = "redis", .port = 6379 }} });
    try std.testing.expectEqual(1, added.uses.len);
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

    // Plain and gzip layers can be mixed, as when a runtime was built before
    // layers were compressed; other types are refused.
    const gzip: Descriptor = .{ .mediaType = media_type.layer_tar_gzip, .digest = other, .size = 1 };
    try validateLayers("test", .{ .config = config, .layers = &.{ layer(digest), gzip } }, c);
    const zstd: Descriptor = .{ .mediaType = "application/vnd.oci.image.layer.v1.tar+zstd", .digest = other, .size = 1 };
    try std.testing.expectError(error.Failed, validateLayers("test", .{ .config = config, .layers = &.{ layer(digest), zstd } }, c));
    try std.testing.expectEqual(.gzip, layerCompression(media_type.layer_tar_gzip).?);
    try std.testing.expectEqual(.none, layerCompression(media_type.layer_tar).?);

    try c.runtimes.map.put(arena, "node2", .{ .id = "org.nodejs.NODE", .version = "22", .image = digest, .layer = other });
    try std.testing.expectError(error.Failed, validateConfig("test", c));
}

test "runtimes' aliases" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const digest = "sha256:" ++ "a" ** 64;
    var c: AppConfig = .{ .id = "x", .version = "1", .command = "x.exe" };
    try c.runtimes.map.put(arena, "zig", .{ .id = "org.ziglang.zig", .version = "1", .image = digest, .layer = digest });
    // Without aliases a runtime's JSON is as before, so configs don't change.
    try std.testing.expect(std.mem.indexOf(u8, try toJson(arena, c), "aliases") == null);

    var aliases: std.json.ArrayHashMap(Export) = .{};
    try aliases.map.put(arena, "cc", .{ .command = "zig.exe", .args = &.{ "cc", "${app}\\lib" } });
    c.runtimes.map.getPtr("zig").?.aliases = aliases;
    try validateConfig("test", c);
    const json = try toJson(arena, c);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"aliases\"") != null);
    const back = try std.json.parseFromSliceLeaky(AppConfig, arena, json, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("zig.exe", back.runtimes.map.get("zig").?.aliases.?.map.get("cc").?.command);

    const bad = [_]Export{
        .{ .command = "../zig.exe" },
        .{ .command = "${zig}\\zig.exe" },
        .{ .command = "zig.exe", .args = &.{"${data}\\x"} },
        .{ .command = "zig.exe", .args = &.{"--cache=${cache}"} },
        .{ .command = "zig.exe", .drop = &.{" --64"} },
    };
    for (bad) |e| {
        var a: std.json.ArrayHashMap(Export) = .{};
        try a.map.put(arena, "cc", e);
        c.runtimes.map.getPtr("zig").?.aliases = a;
        try std.testing.expectError(error.Failed, validateConfig("test", c));
        // The image's own aliases have the same rules.
        var own: AppConfig = .{ .id = "x", .version = "1", .command = "x.exe", .aliases = a };
        try std.testing.expectError(error.Failed, validateConfig("test", own));
        own.aliases = null;
        try validateConfig("test", own);
    }
    var a: std.json.ArrayHashMap(Export) = .{};
    try a.map.put(arena, "zigsaw", .{ .command = "x.exe" });
    c.runtimes.map.getPtr("zig").?.aliases = a;
    try std.testing.expectError(error.Failed, validateConfig("test", c));
}

test "an image's aliases may run its runtimes' files" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const digest = "sha256:" ++ "a" ** 64;
    var c: AppConfig = .{ .id = "x", .version = "1", .command = "x.exe" };
    try c.runtimes.map.put(arena, "php", .{ .id = "net.php.php", .version = "1", .image = digest, .layer = digest });
    var a: std.json.ArrayHashMap(Export) = .{};
    try a.map.put(arena, "composer", .{ .command = "${php}\\php.exe", .args = &.{ "${app}\\composer.phar", "-d", "${php}\\x" } });
    c.aliases = a;
    try validateConfig("test", c);
    // Not a runtime it doesn't have, nor outside the runtime.
    for ([_][]const u8{ "${node}\\node.exe", "${php}\\..\\php.exe", "${php}" }) |command| {
        var bad: std.json.ArrayHashMap(Export) = .{};
        try bad.map.put(arena, "composer", .{ .command = command });
        c.aliases = bad;
        try std.testing.expectError(error.Failed, validateConfig("test", c));
    }
}

test parseFsGrant {
    try std.testing.expectEqual(.cwd, parseFsGrant("cwd").?.where);
    try std.testing.expect(parseFsGrant("cwd:ro").?.read_only);
    try std.testing.expectEqualStrings("D:\\src", parseFsGrant("D:\\src:ro").?.where.path);
    try std.testing.expect(!parseFsGrant("D:\\src").?.read_only);
    try std.testing.expect(parseFsGrant("relative\\dir") == null);

    try std.testing.expectEqual(FsGrant.Where{ .folder = .documents }, parseFsGrant("documents").?.where);
    const pictures = parseFsGrant("Pictures:ro").?;
    try std.testing.expectEqual(FsGrant.Where{ .folder = .pictures }, pictures.where);
    try std.testing.expect(pictures.read_only);

    // A later zigsaw's names pass, as unknown.
    for ([_][]const u8{ "home", "xdg-config", "documents/notes:ro", "host-os" }) |name|
        try std.testing.expect(parseFsGrant(name).?.where == .unknown);
    for ([_][]const u8{ "", "Home", "relative\\dir", "dir/a\\b", "1st", "-x", "a b", ":ro", "C:" }) |bad|
        try std.testing.expect(parseFsGrant(bad) == null);
}

test sourcesTag {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const tag = try sourcesTag(arena_state.allocator(), "sha256:" ++ "ab" ** 32);
    try std.testing.expectEqualStrings("sha256-" ++ "ab" ** 32 ++ ".sources", tag);
    try std.testing.expect(tag.len <= 128);
}

test digestHex {
    const hex = "07bb1e5b095b00d68a695481f9240879f33c5724b40aa2308f999d54ed78f075";
    try std.testing.expectEqualStrings(hex, digestHex("sha256:" ++ hex).?);
    try std.testing.expect(digestHex(hex) == null);
    try std.testing.expect(digestHex("sha256:ABC") == null);
}
