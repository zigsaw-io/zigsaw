//! `zigsaw build`: builds an app from a recipe into an image in the local
//! store, ready to install.
//!
//! A recipe's modules go, in order, into one tree of files: the app's own
//! layer. Its runtimes' layers come before it in the image. A module without
//! build commands places its sources. When no module has build commands,
//! nothing is unpacked: the layer streams straight from the downloads (see
//! Tree.zig).
//!
//! Build commands need real files, so then the build happens in a build root,
//! mapped to B: while it runs (see drive.zig), so that paths in what it builds
//! are the same on every machine:
//!
//!   B:\src\<module>\  a module's sources, and the working directory of its commands
//!   B:\prefix\        $PREFIX, where the modules install the app's files
//!   B:\home\          the profile folders of the build's tools
//!   B:\data\          the data directory runtimes' variables point to while building
//!   B:\cache\<id>\    ${cache} of a tool that uses it, kept between builds in the
//!                     store's cache\tools\<id>, and moved here for the build;
//!                     zig's local cache is the module's B:\src\<module>\.zig-cache
//!   B:\bin\           shims for the commands the tools' images alias, first on PATH
//!
//! Commands run in an environment built from scratch, as apps do, with
//! B:\prefix\bin and the SDK's and runtimes' directories on PATH (after the
//! aliases' B:\bin), and in a job object that ends
//! whatever they leave running.
//!
//! The build root is kept in the store afterwards, a failed build's too, and
//! the recipe's next build happens in it: the modules whose inputs are the
//! same are skipped, and one that stopped goes on at the command that
//! didn't finish (see `Resume`, and checkpoint.zig). `--rebuild`, `--no-resume` and
//! `--keep-build-dir` build in a new root under the store's tmp\, as a host
//! toolchain's builds always do.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const aliases = @import("aliases.zig");
const checkpoint = @import("checkpoint.zig");
const Tree = @import("Tree.zig");
const deps = @import("deps.zig");
const drive = @import("drive.zig");
const environment = @import("environment.zig");
const install = @import("install.zig");
const Fetcher = @import("fetch.zig");
const msvc_host = @import("msvc.zig");
const oci = @import("oci.zig");
const process = @import("process.zig");
const ps = @import("ps.zig");
const override = @import("override.zig");
const project = @import("project.zig");
const recipe = @import("recipe.zig");
const roots = @import("roots.zig");
const Store = @import("Store.zig");
const repeat = @import("testing.zig").repeat;
const win32 = @import("win32.zig");
const fail = Context.fail;
const note = Context.note;

pub const Options = struct {
    /// Keep the build root afterwards, to look at what a build left. Builds
    /// even if an earlier build with the same inputs could be reused.
    keep_build_dir: bool = false,
    /// Build every module, in a new build root, even if an earlier build
    /// with the same inputs could be reused. The kept build is left alone.
    rebuild: bool = false,
    /// Delete the kept build first (see `Resume`), and build even if an
    /// earlier build could be reused.
    clean: bool = false,
    /// Start this module and those after it afresh, and build even if an
    /// earlier build could be reused.
    clean_from: ?[]const u8 = null,
    /// Neither use the kept build nor leave one, and reuse an earlier build
    /// only if it built every module: for what is published, or compared
    /// with what is.
    no_resume: bool = false,
    /// What each of the build's commands, with all it starts, may use (see
    /// process.Limits). No input of the build: what it makes is the same.
    limits: process.Limits = .{},
    /// What `zigsaw ps` lists of the build, which says each command as it
    /// starts; `build` keeps it.
    listed: ?*ps.Entry = null,
};

/// The fixed time builds see as SOURCE_DATE_EPOCH: 1980-01-01, the earliest
/// a zip file can say.
const source_date_epoch = "315532800";

/// Builds the recipe, or reuses the image of an earlier build with the same
/// inputs (see `inputHash`), which would be the same image again.
pub fn build(ctx: *Context, recipe_path: []const u8, opts: Options) !install.Image {
    const io = ctx.io;
    const arena = ctx.arena;

    const bytes = Io.Dir.cwd().readFileAlloc(io, recipe_path, arena, .limited(1 << 20)) catch |err|
        return fail("reading {s}: {t}", .{ recipe_path, err });
    const r = try recipe.parse(arena, recipe_path, bytes);
    const source = try Io.Dir.cwd().realPathFileAlloc(io, recipe_path, arena);
    // A project's own files, once, for the inputs and for the build.
    const projects = try project.Snapshots.take(ctx, r, recipe_path);

    // A host toolchain is an input zigsaw can't pin, so those builds are
    // never reused.
    const inputs = if (r.host.len == 0) try inputHash(ctx, r, bytes, recipe_path, &projects) else null;
    if (opts.clean_from) |name| if (moduleIndex(r, name) == null)
        return fail("{s} has no module {s} to start afresh", .{ recipe_path, name });
    const forced = opts.rebuild or opts.clean or opts.clean_from != null or opts.keep_build_dir;
    if (inputs) |*h| if (!forced) {
        // With --no-resume, only what a build of every module made.
        if (try ctx.store.readBuildCache(arena, h)) |earlier| if (!(opts.no_resume and earlier.resumed)) {
            if (try ctx.store.readCompleteImage(arena, earlier.digest)) |image| {
                if (ctx.verbose) note("{s} {s}: built before from the same inputs ({s}); --rebuild builds it again", .{ r.id, r.version, oci.shortDigest(earlier.digest) });
                return .{ .manifest_digest = earlier.digest, .manifest = image.manifest, .config = image.config, .source = source };
            }
        };
    };
    const start = ctx.now();
    var resumed = false;
    var listed = ps.begin(ctx, .{
        .kind = .build,
        .id = r.id,
        .version = r.version,
        .pid = win32.GetCurrentProcessId(),
        .started = ps.now(),
    });
    defer if (listed) |*l| l.end(io);
    var with_listed = opts;
    with_listed.listed = if (listed) |*l| l else null;
    const image = try buildImage(ctx, r, recipe_path, source, &projects, with_listed, &resumed);
    if (r.hasBuildCommands()) note("built {s} {s} in {f}", .{ r.id, r.version, ctx.since(start) });
    if (inputs) |*h| try ctx.store.writeBuildCache(arena, h, image.manifest_digest, resumed);
    return image;
}

fn moduleIndex(r: recipe.Recipe, name: []const u8) ?usize {
    for (r.modules, 0..) |m, i| if (std.ascii.eqlIgnoreCase(m.name, name)) return i;
    return null;
}

/// The recipe `zigsaw build` builds: the one given, or the zigsaw.json of
/// the project directory given (the current one, if none is), as make
/// builds a directory's Makefile.
pub fn recipePath(ctx: *Context, arg: ?[]const u8) ![]const u8 {
    if (arg) |p| {
        const stat = Io.Dir.cwd().statFile(ctx.io, p, .{}) catch return p;
        if (stat.kind != .directory) return p;
    }
    const dir = arg orelse ".";
    const manifest = try std.fs.path.join(ctx.arena, &.{ dir, project.manifest_name });
    if (!try Store.exists(ctx.io, manifest)) {
        const shown = Io.Dir.cwd().realPathFileAlloc(ctx.io, dir, ctx.arena) catch dir;
        return fail("{s} has no {s}; give a recipe, or a project directory with one", .{ shown, project.manifest_name });
    }
    return manifest;
}

/// A hash of everything a build's result depends on: this zigsaw, the
/// recipe, and the contents of its local sources, files and directories.
/// URL sources, runtimes and SDK images are pinned by hash in the recipe
/// itself.
fn inputHash(ctx: *Context, r: recipe.Recipe, bytes: []const u8, recipe_path: []const u8, projects: *const project.Snapshots) ![64]u8 {
    const io = ctx.io;
    const arena = ctx.arena;
    var h: std.crypto.hash.sha2.Sha256 = .init(.{});
    h.update("zigsaw build inputs\n");
    h.update(&(try Store.sha256File(io, try win32.selfExePath(arena))).hex);
    h.update(bytes);
    const base_dir = std.fs.path.dirname(recipe_path) orelse ".";
    for (r.modules) |m| for (m.sources, 0..) |src, i| {
        const p = src.path orelse continue;
        if (projects.get(m.name, i)) |s| {
            h.update(s.hash);
            continue;
        }
        const full = if (std.fs.path.isAbsolute(p)) p else try std.fs.path.join(arena, &.{ base_dir, p });
        const file_hash = Store.sha256File(io, full) catch |err|
            return fail("module {s}: reading {s}: {t}", .{ m.name, full, err });
        h.update(&file_hash.hex);
    };
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

fn buildImage(ctx: *Context, r: recipe.Recipe, recipe_path: []const u8, source: []const u8, projects: *const project.Snapshots, opts: Options, resumed: *bool) !install.Image {
    const arena = ctx.arena;

    // Runtimes go into the image and are on PATH while building. The SDK is
    // only on PATH, ahead of the runtimes, and in the record of the build;
    // it's only unpacked if there's something to build with it. An SDK's
    // own runtimes come with it, right after it, as on its runs' PATH; its
    // digest pins them.
    const building = r.hasBuildCommands();
    var tools: Tools = .{ .recipe_path = recipe_path };
    var build_info: oci.Build = .{};
    for (r.sdk.map.keys(), r.sdk.map.values()) |alias, reference| {
        const dep = try deps.resolve(ctx, recipe_path, .sdk, alias, reference);
        try build_info.sdk.map.put(arena, alias, dep.manifest_digest);
        if (!building) continue;
        const dirs = try ctx.store.useLayers(arena, dep.manifest.layers);
        const what = try std.fmt.allocPrint(arena, "sdk {s}", .{alias});
        const own = try runtimeDirs(arena, dep.config, dirs[0 .. dirs.len - 1]);
        const sdk = try tools.add(arena, .ofConfig(what, dep.manifest_digest, dirs[dirs.len - 1], dep.config, own));
        if (sdk == null) continue;
        for (dep.config.runtimes.map.keys(), dep.config.runtimes.map.values(), dirs[0 .. dirs.len - 1]) |rt_alias, rt, dir| {
            const rt_what = try std.fmt.allocPrint(arena, "{s}'s runtime {s}", .{ what, rt_alias });
            if (try tools.add(arena, .ofRuntime(rt_what, dir, rt)) != null) tools.list.items[sdk.?].brings += 1;
        }
    }
    var runtimes: std.json.ArrayHashMap(oci.Runtime) = .{};
    var layers: std.ArrayList(oci.Descriptor) = .empty;
    var runtime_dirs: std.ArrayList(oci.Placeholders.Dir) = .empty;
    for (r.runtimes.map.keys(), r.runtimes.map.values()) |alias, reference| {
        const dep = try deps.resolve(ctx, recipe_path, .runtime, alias, reference);
        const dir = (try ctx.store.useLayers(arena, &.{dep.layer()}))[0];
        try runtimes.map.put(arena, alias, dep.runtime());
        try layers.append(arena, dep.layer());
        try runtime_dirs.append(arena, .{ .alias = alias, .path = dir });
        // One an SDK brought already is on PATH, at the SDK's place.
        _ = try tools.add(arena, .ofConfig(try std.fmt.allocPrint(arena, "runtime {s}", .{alias}), dep.manifest_digest, dir, dep.config, &.{}));
    }
    for (r.modules) |m| build_info.network = build_info.network or m.network;

    var sources: Sources = .{ .ctx = ctx, .fetcher = .{ .ctx = ctx, .base_dir = std.fs.path.dirname(recipe_path) orelse ".", .app = r.id }, .projects = projects };
    defer sources.deinit();
    var tree: Tree = undefined;
    var root: ?BuildRoot = null;
    defer if (root) |*b| b.finish(ctx, opts.keep_build_dir);
    // Every download first, several at a time, so a missing or wrong hash
    // fails the build before anything is built.
    var downloads: std.ArrayList(recipe.Source) = .empty;
    for (r.modules) |m| for (m.sources, 0..) |src, i| {
        if (src.image == null and projects.get(m.name, i) == null) try downloads.append(arena, src);
    };
    try sources.fetcher.fetchAll(downloads.items);
    if (building) {
        // A host toolchain is an input zigsaw can't pin, so nothing of such
        // a build is taken into the next.
        const from_last: ?*Resume = if (r.host.len == 0 and !opts.keep_build_dir and !opts.rebuild and !opts.no_resume)
            try Resume.init(ctx, r, recipe_path, source, projects, tools.list.items, opts)
        else
            null;
        if (from_last) |res| resumed.* = res.plan.resumes();
        root = try .init(ctx, r, tools.list.items, from_last);
        root.?.limits = opts.limits;
        root.?.listed = opts.listed;
        if (root.?.msvc) |tc| {
            try build_info.host.map.put(arena, "msvc", tc.tools_version);
            try build_info.host.map.put(arena, "windows-sdk", tc.sdk_version);
        }
        // Then every vendor step, for the same reason. A module that's
        // skipped was built with what its step is pinned to.
        const done = if (from_last) |res| res.plan.done else 0;
        var vendored: std.json.ArrayHashMap([]const u8) = .{};
        for (r.modules, 0..) |m, i| if (m.vendor) |v| {
            try vendored.map.put(arena, m.name, if (i < done) v.sha256.? else try root.?.vendor(ctx, m, recipe_path, projects));
        };
        if (vendored.map.count() > 0) build_info.vendor = vendored;
        tree = try root.?.buildModules(ctx, &sources, r, recipe_path);
    } else {
        tree = .{};
        for (r.modules) |m| try sources.add(&tree, m, recipe_path);
    }
    build_info.sources = sources.hashes.items;
    if (sources.images.items.len > 0) build_info.images = sources.images.items;
    tree.cleanup(r.cleanup);

    const config = try r.appConfig(arena, runtimes, build_info);
    try oci.validateConfig(recipe_path, config);
    const placeholders: oci.Placeholders = .{ .app = "", .data = "", .runtimes = runtime_dirs.items };
    try checkCommand(ctx, &tree, placeholders, "command runs", config.command);
    var exported = config.exports.map.iterator();
    while (exported.next()) |e| try checkCommand(ctx, &tree, placeholders, try std.fmt.allocPrint(arena, "export {s} runs", .{e.key_ptr.*}), e.value_ptr.command);
    if (config.aliases) |a| for (a.map.keys(), a.map.values()) |name, e|
        try checkCommand(ctx, &tree, placeholders, try std.fmt.allocPrint(arena, "alias {s} runs", .{name}), e.command);
    if (config.shortcuts) |s| for (s.map.keys(), s.map.values()) |name, shortcut| if (shortcut.icon) |icon|
        try checkCommand(ctx, &tree, placeholders, try std.fmt.allocPrint(arena, "shortcut \"{s}\" has the icon", .{name}), icon);
    if (config.associations) |a| for (a.map.keys(), a.map.values()) |ext, association| if (association.icon) |icon|
        try checkCommand(ctx, &tree, placeholders, try std.fmt.allocPrint(arena, "association \"{s}\" has the icon", .{ext}), icon);
    if (config.schemes) |s| for (s.map.keys(), s.map.values()) |name, scheme| if (scheme.icon) |icon|
        try checkCommand(ctx, &tree, placeholders, try std.fmt.allocPrint(arena, "scheme \"{s}\" has the icon", .{name}), icon);

    const start = ctx.now();
    // A file a new version doesn't have any more is left out, so that a
    // version bump builds before its list is recorded again.
    var prefetch: std.ArrayList([]const u8) = .empty;
    for (r.prefetch) |p| {
        if (try tree.filePath(arena, p)) |actual| {
            try prefetch.append(arena, actual);
        } else Context.note("warning: prefetch \"{s}\" isn't a file of the app's; it's left out", .{p});
    }
    const layer_file = try tree.writeLayerFile(ctx, r.layer.format(), .{ .prefetch = prefetch.items });
    ctx.timed(start, "write layer ({d} entries)", .{tree.nodes.count()});
    // Without build commands, a project's files went from its directory
    // straight into the layer.
    if (!building) try projects.recheck(ctx, null);
    try layers.append(arena, layer_file.descriptor(try ctx.store.putBlobFile(arena, layer_file.path, layer_file.hash, layer_file.media_type)));

    const config_desc = try ctx.store.putBlob(arena, try oci.toJson(arena, config), oci.media_type.config);
    var annotations: std.json.ArrayHashMap([]const u8) = .{};
    try annotations.map.put(arena, "org.opencontainers.image.title", r.id);
    try annotations.map.put(arena, "org.opencontainers.image.version", r.version);
    // The standard ones registries show, as ghcr.io does on a package's page.
    if (r.summary) |s| try annotations.map.put(arena, "org.opencontainers.image.description", s);
    if (r.license) |l| try annotations.map.put(arena, "org.opencontainers.image.licenses", l);
    if (r.homepage) |h| try annotations.map.put(arena, "org.opencontainers.image.url", h);
    const manifest: oci.Manifest = .{
        .config = config_desc,
        .layers = layers.items,
        .annotations = annotations,
    };
    const manifest_desc = try ctx.store.putBlob(arena, try oci.toJson(arena, manifest), oci.media_type.manifest);

    return .{
        .manifest_digest = manifest_desc.digest,
        .manifest = manifest,
        .config = config,
        .source = source,
    };
}

/// Checks that a command is a file: in the app tree, or in a runtime's
/// deployment. `what` names it in messages, with a verb ("export rg runs").
fn checkCommand(ctx: *Context, tree: *const Tree, placeholders: oci.Placeholders, what: []const u8, command: []const u8) !void {
    const arena = ctx.arena;
    if (std.mem.startsWith(u8, command, "${app}")) {
        if (try tree.isFile(arena, command["${app}".len + 1 ..])) return;
    } else if (oci.isPlaceholderPath(command)) {
        const p = try placeholders.expand(arena, command);
        if (Store.exists(ctx.io, p) catch false) return;
        return fail("{s} \"{s}\", which is not a file in that runtime", .{ what, command });
    } else if (try tree.isFile(arena, command)) return;
    return fail("{s} \"{s}\", which is not a file in the app tree the modules produce", .{ what, command });
}

/// Fetches modules' sources and indexes them into trees, keeping their
/// archives open and noting each source's hash for the record of the build,
/// or for an image, its digest.
const Sources = struct {
    ctx: *Context,
    fetcher: Fetcher,
    /// The files of directory sources, as the build took them.
    projects: *const project.Snapshots,
    archives: std.ArrayList(*Tree.Archive) = .empty,
    hashes: std.ArrayList([]const u8) = .empty,
    images: std.ArrayList([]const u8) = .empty,

    fn deinit(s: *Sources) void {
        for (s.archives.items) |a| a.close(s.ctx.io);
        s.fetcher.deinit();
    }

    /// Notes the hashes of a module's sources, as `add` does, without
    /// reading what's in them: for a module that isn't built again.
    fn record(s: *Sources, m: recipe.Module, recipe_path: []const u8) !void {
        const ctx = s.ctx;
        const arena = ctx.arena;
        for (m.sources, 0..) |src, i| {
            if (s.projects.get(m.name, i)) |snapshot| {
                try s.hashes.append(arena, snapshot.hash);
            } else if (src.image) |reference| {
                const dep = try deps.resolve(ctx, recipe_path, .source, m.name, reference);
                try s.images.append(arena, dep.manifest_digest);
            } else if (src.sha256) |hash| {
                try s.hashes.append(arena, hash);
            } else {
                const h = try Store.sha256File(ctx.io, try s.fetcher.fetch(src));
                try s.hashes.append(arena, try arena.dupe(u8, &h.hex));
            }
        }
    }

    /// Adds a module's sources to `tree`.
    fn add(s: *Sources, tree: *Tree, m: recipe.Module, recipe_path: []const u8) !void {
        const ctx = s.ctx;
        const arena = ctx.arena;
        for (m.sources, 0..) |src, i| {
            if (s.projects.get(m.name, i)) |snapshot| {
                try s.hashes.append(arena, snapshot.hash);
                tree.addTree(arena, &snapshot.tree, try Tree.normalizePath(arena, src.dest orelse ".")) catch |err| switch (err) {
                    error.PathConflict => return fail("{s}: {s} is a file in one source and a directory in another", .{ recipe_path, tree.conflict }),
                    else => |e| return e,
                };
                continue;
            }
            if (src.image) |reference| {
                // Its own files, as deployed: pulled if the store doesn't
                // have the image, and kept like an SDK's.
                const dep = try deps.resolve(ctx, recipe_path, .source, m.name, reference);
                try s.images.append(arena, dep.manifest_digest);
                const dir = (try ctx.store.useLayers(arena, &.{dep.layer()}))[0];
                tree.addDirFiles(ctx.io, arena, dir, try Tree.normalizePath(arena, src.dest orelse ".")) catch |err| switch (err) {
                    error.PathConflict => return fail("{s}: {s} is a file in one source and a directory in another", .{ recipe_path, tree.conflict }),
                    else => |e| return e,
                };
                continue;
            }
            var start = ctx.now();
            const file = try s.fetcher.fetch(src);
            const hash = src.sha256 orelse hash: {
                const h = try Store.sha256File(ctx.io, file);
                break :hash try arena.dupe(u8, &h.hex);
            };
            try s.hashes.append(arena, hash);
            ctx.timed(start, "fetch {s}", .{src.fileName()});
            start = ctx.now();
            tree.addSource(ctx, &s.archives, src, file, hash) catch |err| switch (err) {
                error.PathConflict => return fail("{s}: {s} is a file in one source and a directory in another", .{ recipe_path, tree.conflict }),
                error.OutOfMemory => |e| return e,
                else => return fail("module {s}: reading {s}: {t}", .{ m.name, src.fileName(), err }),
            };
            ctx.timed(start, "index {s}", .{src.fileName()});
        }
    }
};

/// An image a build runs with: an SDK, a runtime, or a runtime an SDK
/// brings.
const Tool = struct {
    /// Its manifest digest: the same image is used once.
    image: []const u8,
    id: []const u8,
    version: []const u8,
    /// Names it in messages: "sdk gtksdk", "sdk gtksdk's runtime zig".
    what: []const u8,
    dir: []const u8,
    path: []const []const u8,
    env: std.json.ArrayHashMap([]const u8),
    aliases: ?std.json.ArrayHashMap(oci.Export),
    /// An SDK's own runtimes, by alias, for ${<alias>} in its entries.
    runtimes: []const oci.Placeholders.Dir = &.{},
    /// How many of the tools right after it are runtimes it brought.
    brings: usize = 0,

    fn ofConfig(what: []const u8, image: []const u8, dir: []const u8, c: oci.AppConfig, runtimes: []const oci.Placeholders.Dir) Tool {
        return .{ .image = image, .id = c.id, .version = c.version, .what = what, .dir = dir, .path = c.path, .env = c.env, .aliases = c.aliases, .runtimes = runtimes };
    }

    fn ofRuntime(what: []const u8, dir: []const u8, r: oci.Runtime) Tool {
        return .{ .image = r.image, .id = r.id, .version = r.version, .what = what, .dir = dir, .path = r.path, .env = r.env, .aliases = r.aliases };
    }

    /// What its own entries' placeholders stand for in a build: ${app} is
    /// its directory, ${data} where the build keeps runtimes' data,
    /// ${cache} its cache, if it uses one, and ${roots} the build's file of
    /// Windows' roots, if a tool names it.
    fn placeholders(t: Tool, arena: Allocator, roots_file: ?[]const u8) !oci.Placeholders {
        const cache = oci.usesCache(t.path, t.env);
        return .{
            .app = t.dir,
            .data = BuildRoot.letter ++ "\\data",
            .cache = if (cache) try std.fmt.allocPrint(arena, "{s}\\cache\\{s}", .{ BuildRoot.letter, t.id }) else null,
            .roots = roots_file,
            .runtimes = t.runtimes,
        };
    }
};

/// The tools of a build, in order.
const Tools = struct {
    recipe_path: []const u8,
    list: std.ArrayList(Tool) = .empty,

    /// Adds `t` and returns its index, or null if the build has the image
    /// already. Two versions of one app can't both be in a build: their
    /// commands, aliases and variables would clash, and only one would win.
    fn add(tools: *Tools, arena: Allocator, t: Tool) !?usize {
        for (tools.list.items) |other| {
            if (std.mem.eql(u8, other.image, t.image)) return null;
            if (std.ascii.eqlIgnoreCase(other.id, t.id))
                return fail("{s}: {s} is {s} {s} ({s}), and {s} is {s} {s} ({s}); a build can't use two versions of {s}", .{
                    tools.recipe_path, other.what, other.id,  other.version,            oci.shortDigest(other.image),
                    t.what,            t.id,       t.version, oci.shortDigest(t.image), t.id,
                });
        }
        try tools.list.append(arena, t);
        return tools.list.items.len - 1;
    }
};

/// The tools' variables. Later tools' win, but an SDK's own win over its
/// runtimes', as in its runs.
fn toolVars(arena: Allocator, tools: []const Tool, roots_file: ?[]const u8) !std.ArrayList(environment.Var) {
    var vars: std.ArrayList(environment.Var) = .empty;
    var i: usize = 0;
    while (i < tools.len) : (i += 1 + tools[i].brings) {
        for (tools[i + 1 ..][0..tools[i].brings]) |rt| try environment.expand(arena, &vars, try rt.placeholders(arena, roots_file), rt.env, &.{});
        try environment.expand(arena, &vars, try tools[i].placeholders(arena, roots_file), tools[i].env, &.{});
    }
    return vars;
}

/// An image's runtimes by alias, deployed in `dirs`.
fn runtimeDirs(arena: Allocator, c: oci.AppConfig, dirs: []const []const u8) ![]const oci.Placeholders.Dir {
    const out = try arena.alloc(oci.Placeholders.Dir, dirs.len);
    for (out, c.runtimes.map.keys(), dirs) |*o, alias, dir| o.* = .{ .alias = alias, .path = dir };
    return out;
}

/// The directory a build happens in, mapped to the build drive.
const BuildRoot = struct {
    /// The real path: the kept build's root, or one under the store's tmp\.
    path: []const u8,
    drive: drive.Drive,
    id: []const u8,
    profile: environment.Profile,
    /// The tools' PATH entries, and their variables: the SDK's, the
    /// runtimes', then MSVC's.
    path_dirs: []const []const u8,
    tool_vars: []const environment.Var,
    /// The host's MSVC, if the recipe builds with it.
    msvc: ?msvc_host.Toolchain,
    /// The ids of the tools whose caches are in cache\ for the build.
    caches: []const []const u8,
    /// The kept build this one happens in, and what it takes from it.
    from_last: ?*Resume = null,
    /// What each command, with all it starts, may use.
    limits: process.Limits = .{},
    /// See `Options.listed`.
    listed: ?*ps.Entry = null,

    const letter = drive.letter;

    fn init(ctx: *Context, r: recipe.Recipe, tools: []const Tool, from_last: ?*Resume) !BuildRoot {
        const io = ctx.io;
        const arena = ctx.arena;
        errdefer if (from_last) |res| releaseKept(ctx, res.kept);
        const path = if (from_last) |res| res.kept.root else try ctx.store.makeTmpDir(arena, drive.dir_prefix[0 .. drive.dir_prefix.len - 1]);
        errdefer if (from_last == null) Io.Dir.cwd().deleteTree(io, path) catch {};
        for ([_][]const u8{ "src", "prefix", "cache" }) |sub| try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ path, sub }));
        // The tools' folders are as the skipped modules left them, and the
        // commands that aren't run again. With none of either, they start
        // empty, as in a first build.
        try makeScratchDirs(ctx, path, if (from_last != null and from_last.?.plan.done == 0 and from_last.?.plan.step == null) .fresh else .new);
        const profile: environment.Profile = try .init(arena, letter ++ "\\");

        var path_dirs: std.ArrayList([]const u8) = .empty;
        // Windows' roots as a file, for the tools that take only one.
        const roots_file = for (tools) |t| {
            if (oci.usesRoots(t.env, &.{})) break try roots.file(ctx);
        } else null;
        var tool_vars = try toolVars(arena, tools, roots_file);
        var caches: std.ArrayList([]const u8) = .empty;
        var providers: std.ArrayList(aliases.Provider) = .empty;
        for (tools) |t| {
            const p = try t.placeholders(arena, roots_file);
            if (p.cache != null and !containsIgnoreCase(caches.items, t.id)) try caches.append(arena, t.id);
            try path_dirs.appendSlice(arena, try environment.pathDirs(arena, p, t.path));
            try providers.append(arena, .{ .id = t.id, .dir = t.dir, .aliases = t.aliases, .runtimes = t.runtimes });
        }
        // Of two tools with an alias of the same name, the first's wins, as
        // on PATH.
        const resolved = try aliases.resolve(ctx, providers.items, .fail);
        const bin = try std.fs.path.join(arena, &.{ path, "bin" });
        // In a kept root, a shim that's as it was is left as it is, with
        // its time: build tools note the programs they found, and Meson's
        // build files are out of date once `strip` is newer than them.
        if (from_last != null and (resolved.len > 0 or try Store.exists(io, bin))) {
            _ = try aliases.sync(ctx, bin, resolved);
        } else try aliases.writeAll(ctx, bin, resolved);
        // The aliases come first: a tool's image says what they are. BusyBox's
        // sh runs its own applets before anything on PATH, so they win over
        // those too (zig's ar over BusyBox's).
        // What earlier modules installed comes next, as /app/bin does in
        // Flatpak's builds: programs a later module runs (GLib's
        // glib-compile-resources), and the DLLs they need.
        try path_dirs.insert(arena, 0, letter ++ "\\prefix\\bin");
        if (resolved.len > 0) {
            try path_dirs.insert(arena, 0, letter ++ "\\bin");
            try environment.set(arena, &tool_vars, "BB_OVERRIDE_APPLETS", try aliases.names(arena, resolved));
        }
        try setSearchPaths(ctx, &tool_vars, tools);
        const msvc: ?msvc_host.Toolchain = if (r.host.len > 0) try msvc_host.find(ctx, path) else null;
        if (msvc) |tc| {
            try path_dirs.appendSlice(arena, tc.path);
            for (tc.vars) |v| try environment.set(arena, &tool_vars, v.name, v.value);
        }
        const b: BuildRoot = .{
            .path = path,
            .drive = try drive.acquire(arena, path),
            .id = r.id,
            .profile = profile,
            .path_dirs = path_dirs.items,
            .tool_vars = tool_vars.items,
            .msvc = msvc,
            .caches = caches.items,
            .from_last = from_last,
        };
        // Once the drive is this build's, so builds take turns with the
        // caches too.
        errdefer b.drive.release();
        for (b.caches) |id| try b.takeCache(ctx, id);
        return b;
    }

    /// Points pkg-config and CMake at the libraries a build can use: what
    /// earlier modules installed into the prefix, then the SDK and runtime
    /// images that have pkg-config files, such as a library's SDK. Set here
    /// rather than in those images' env, which would join no lists and
    /// would be in their runs too.
    fn setSearchPaths(ctx: *Context, vars: *std.ArrayList(environment.Var), tools: []const Tool) !void {
        const arena = ctx.arena;
        var pkg_config: std.ArrayList([]const u8) = .empty;
        var cmake: std.ArrayList([]const u8) = .empty;
        try pkg_config.appendSlice(arena, &.{ letter ++ "\\prefix\\lib\\pkgconfig", letter ++ "\\prefix\\share\\pkgconfig" });
        try cmake.append(arena, letter ++ "\\prefix");
        for (tools) |t| {
            var any = false;
            for ([_][]const u8{ "lib\\pkgconfig", "share\\pkgconfig" }) |sub| {
                const dir = try std.fs.path.join(arena, &.{ t.dir, sub });
                if (!try Store.exists(ctx.io, dir)) continue;
                try pkg_config.append(arena, dir);
                any = true;
            }
            if (any) try cmake.append(arena, t.dir);
        }
        try environment.set(arena, vars, "PKG_CONFIG_PATH", try std.mem.join(arena, ";", pkg_config.items));
        try environment.set(arena, vars, "CMAKE_PREFIX_PATH", try std.mem.join(arena, ";", cmake.items));
    }

    /// Moves a tool's cache from the store into the build root, or starts
    /// an empty one.
    fn takeCache(b: *const BuildRoot, ctx: *Context, id: []const u8) !void {
        const io = ctx.io;
        const arena = ctx.arena;
        const kept = try ctx.store.path(arena, &.{ "cache", "tools", id });
        const here = try std.fs.path.join(arena, &.{ b.path, "cache", id });
        if (try Store.exists(io, kept)) {
            // One that a build which was stopped left in a kept root is
            // older than the store's.
            if (try Store.exists(io, here)) Store.deleteTree(io, arena, here) catch {};
            Store.renameRetrying(io, kept, here, cache_move_wait_ms) catch |err| {
                if (ctx.verbose) note("couldn't use {s}'s cache ({t}); building without it", .{ id, err });
            };
        }
        try Io.Dir.cwd().createDirPath(io, here);
    }

    /// Moves the tools' caches back into the store, unmaps the drive, and
    /// deletes the build root, unless it's the kept build's, or to be kept
    /// for a look.
    fn finish(b: *BuildRoot, ctx: *Context, keep: bool) void {
        b.drive.release();
        for (b.caches) |id| b.keepCache(ctx, id) catch |err| {
            if (ctx.verbose) note("couldn't keep {s}'s cache ({t}); the next build starts without it", .{ id, err });
        };
        if (b.from_last) |res| {
            // While this build still has its own, which stays.
            keepWithinCap(ctx, b.id, res.kept);
            releaseKept(ctx, res.kept);
        } else if (keep) {
            note("kept the build directory: {s}", .{b.path});
        } else {
            Store.deleteTree(ctx.io, ctx.arena, b.path) catch |err|
                note("warning: couldn't delete all of {s} ({t}); `zigsaw prune` will retry", .{ b.path, err });
        }
    }

    /// Records how much room the kept build of the build that's ending
    /// takes, and deletes the least recently used others while all of them
    /// take more than ZIGSAW_KEPT_BUILDS_SIZE lets them. Nothing here fails
    /// the build.
    fn keepWithinCap(ctx: *Context, id: []const u8, kept: checkpoint.Kept) void {
        keepWithinCapOrFail(ctx, id, kept) catch |err|
            note("warning: couldn't keep the store's kept builds within their room ({t})", .{err});
    }

    fn keepWithinCapOrFail(ctx: *Context, id: []const u8, kept: checkpoint.Kept) !void {
        const io = ctx.io;
        const arena = ctx.arena;
        const cap = if (ctx.env.get(checkpoint.cap_var)) |text| checkpoint.parseSize(text) catch blk: {
            note("warning: {s} is \"{s}\", not a size such as 10GB; taking {Bi:.0}", .{ checkpoint.cap_var, text, checkpoint.default_cap });
            break :blk checkpoint.default_cap;
        } else checkpoint.default_cap;
        // Nothing was kept: a record that couldn't be written.
        if (!try Store.exists(io, kept.dir)) return;
        try kept.setAbout(arena, id);
        _ = try checkpoint.writeSize(io, arena, kept.dir, kept.root);
        const deleted = try checkpoint.enforceCap(io, arena, std.fs.path.dirname(kept.dir).?, std.fs.path.dirname(kept.root).?, std.fs.path.basename(kept.dir), cap);
        for (deleted) |d|
            note("deleted the kept build of {s} ({Bi:.1}): kept builds may take {Bi:.1} together ({s})", .{ d.id, d.bytes, cap, checkpoint.cap_var });
    }

    /// Moves a tool's cache back into the store. If the store has one again,
    /// put back by a build in another logon session, this one goes with the
    /// build root.
    fn keepCache(b: *const BuildRoot, ctx: *Context, id: []const u8) !void {
        const arena = ctx.arena;
        const here = try std.fs.path.join(arena, &.{ b.path, "cache", id });
        const kept = try ctx.store.path(arena, &.{ "cache", "tools", id });
        try Store.renameRetrying(ctx.io, here, kept, cache_move_wait_ms);
    }

    /// How long moving a tool's cache waits for Windows to stop refusing,
    /// which it does while Defender scans what the build just wrote.
    const cache_move_wait_ms = 5000;

    /// Builds each module in turn into the prefix, and returns the tree of
    /// what's there at the end.
    fn buildModules(b: *const BuildRoot, ctx: *Context, sources: *Sources, r: recipe.Recipe, recipe_path: []const u8) !Tree {
        const io = ctx.io;
        const arena = ctx.arena;
        const prefix = try std.fs.path.join(arena, &.{ b.path, "prefix" });
        for (r.modules, 0..) |m, i| {
            const from_last = b.from_last;
            if (from_last != null and i < from_last.?.plan.done) {
                try sources.record(m, recipe_path);
                continue;
            }
            var how: Commands = .{ .index = i };
            if (from_last != null and i == from_last.?.plan.done and from_last.?.plan.step != null) {
                // It goes on at the command that stopped, in its directory
                // as that command left it.
                try sources.record(m, recipe_path);
                how.from = from_last.?.plan.step.?.commands;
                how.continued = true;
            } else {
                var tree: Tree = .{};
                try sources.add(&tree, m, recipe_path);
                // A module with a vendor step has its files already.
                if (m.vendor == null) {
                    const dest = if (m.build.len == 0) prefix else try std.fs.path.join(arena, &.{ b.path, "src", m.name });
                    if (from_last) |res| {
                        how.continued = try res.bringSources(ctx, i, m, &tree, dest, sources.projects);
                    } else try writeSources(io, arena, &tree, m, dest);
                    try sources.projects.recheck(ctx, m.name);
                }
                if (from_last) |res| res.started(ctx, i, m);
            }
            if (m.build.len > 0) {
                try b.runCommands(ctx, m, .build, .fail, how);
            } else if (from_last) |res| res.stepped(ctx, i, m, 0);
            if (from_last) |res| res.finished(ctx, i, m);
        }
        return Tree.fromDir(io, arena, prefix);
    }

    /// How a module's commands run.
    const Commands = struct {
        /// The module's place in the recipe.
        index: usize = 0,
        /// How many commands, from the first, ran in an earlier build, and
        /// aren't run again.
        from: usize = 0,
        /// Whether the module's directory is the one its last build left.
        continued: bool = false,
    };

    /// Runs a module's vendor step, or takes what an earlier one made from
    /// the download cache, and leaves the module's directory with its sources
    /// and what the step made. Returns the sha256 of that. If the commands of
    /// a pinned step fail, what they make is fetched from the sources next to
    /// the app's image, if it's there.
    ///
    /// Either way, the build then starts from the same files: after the
    /// commands run, the module's directory and the build's profile folders
    /// start again from scratch, with only what the step left in its `dir`.
    fn vendor(b: *const BuildRoot, ctx: *Context, m: recipe.Module, recipe_path: []const u8, projects: *const project.Snapshots) ![]const u8 {
        const io = ctx.io;
        const arena = ctx.arena;
        const v = m.vendor.?;
        const dest = try std.fs.path.join(arena, &.{ b.path, "src", m.name });
        try unpackSources(ctx, m, recipe_path, projects, dest);

        var cached: ?[]const u8 = if (v.sha256) |h| try ctx.store.path(arena, &.{ "cache", "downloads", h }) else null;
        if (cached != null and try Store.exists(io, cached.?)) {
            if (ctx.verbose) note("module {s}: vendored files from the cache (sha256 {s})", .{ m.name, v.sha256.? });
        } else if (b.runCommands(ctx, m, .vendor, if (v.sha256 != null) .warn else .fail, .{})) |_| {
            const made = try std.fs.path.join(arena, &.{ dest, v.dir });
            if (!try Store.exists(io, made))
                return fail("module {s}: the vendor commands left nothing in {s}", .{ m.name, v.dir });
            const tree = try Tree.fromDir(io, arena, made);
            const file = try tree.writeLayerFile(ctx, .tar, .{});
            const got = try arena.dupe(u8, &file.hash.hex);
            // Kept under its actual hash, as downloads are, so pinning it
            // doesn't run the commands again.
            const kept = try ctx.store.path(arena, &.{ "cache", "downloads", got });
            if (try Store.exists(io, kept)) {
                Io.Dir.cwd().deleteFile(io, file.path) catch {};
            } else {
                try Io.Dir.rename(.cwd(), file.path, .cwd(), kept, io);
            }
            const want = v.sha256 orelse
                return fail("module {s}: \"vendor\" has no sha256. Pin what its commands made with:\n  \"sha256\": \"{s}\"", .{ m.name, got });
            if (!std.mem.eql(u8, want, got))
                return fail("sha256 mismatch for what module {s}'s vendor commands made in {s}\n  expected {s}\n  got      {s}", .{ m.name, v.dir, want, got });
            try Store.deleteTree(io, arena, dest);
            try unpackSources(ctx, m, recipe_path, projects, dest);
            try makeScratchDirs(ctx, b.path, .fresh);
            cached = kept;
        } else |err| {
            // What the commands would have made is pinned, so it may be kept
            // next to the app's image (see Fetcher.fromSources).
            if (err != error.CommandFailed) return err;
            var fetcher: Fetcher = .{ .ctx = ctx, .base_dir = std.fs.path.dirname(recipe_path) orelse ".", .app = b.id };
            defer fetcher.deinit();
            cached = try fetcher.fromSources(v.sha256.?, try std.fmt.allocPrint(arena, "module {s}'s vendored files", .{m.name}), "its vendor commands failed");
            try Store.deleteTree(io, arena, dest);
            try unpackSources(ctx, m, recipe_path, projects, dest);
            try makeScratchDirs(ctx, b.path, .fresh);
        }

        var tree: Tree = .{};
        var archives: std.ArrayList(*Tree.Archive) = .empty;
        defer for (archives.items) |a| a.close(io);
        const src: recipe.Source = .{ .path = cached.?, .type = .tar, .dest = v.dir };
        tree.addSource(ctx, &archives, src, cached.?, v.sha256.?) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return fail("module {s}: reading its vendored files ({s}): {t}", .{ m.name, cached.?, err }),
        };
        try writeSources(io, arena, &tree, m, dest);
        try projects.recheck(ctx, m.name);
        return v.sha256.?;
    }

    /// The directories of the build's profile and of runtimes' data in the
    /// build root `path`: made for a new build root, or made again from
    /// scratch.
    fn makeScratchDirs(ctx: *Context, path: []const u8, how: enum { new, fresh }) !void {
        const io = ctx.io;
        const arena = ctx.arena;
        const real_profile: environment.Profile = try .init(arena, path);
        const data = try std.fs.path.join(arena, &.{ path, "data" });
        if (how == .fresh) for ([_][]const u8{ real_profile.home, data }) |dir| try Store.deleteTree(io, arena, dir);
        for ([_][]const u8{ real_profile.roaming, real_profile.temp, data }) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    }

    const Step = enum { vendor, build };

    /// Runs a module's build commands, or its vendor commands, which have
    /// network access. If one fails, the build fails, or with `.warn`,
    /// runCommands returns error.CommandFailed after saying so. After each
    /// build command, the kept build records how far the module is.
    fn runCommands(b: *const BuildRoot, ctx: *Context, m: recipe.Module, step: Step, on_failure: enum { fail, warn }, how: Commands) !void {
        const arena = ctx.arena;
        const system_root = ctx.env.get("SystemRoot") orelse "C:\\Windows";
        const commands = switch (step) {
            .vendor => m.vendor.?.commands,
            .build => m.build,
        };
        var vars: std.ArrayList(environment.Var) = .empty;
        try vars.appendSlice(arena, b.tool_vars);
        try environment.set(arena, &vars, "PREFIX", letter ++ "\\prefix");
        try environment.set(arena, &vars, "SOURCE_DATE_EPOCH", source_date_epoch);
        try environment.set(arena, &vars, "ZIGSAW_BUILD", "1");
        // zig keeps what it compiles in its local cache, which is its global
        // one, ${cache}, unless this says otherwise; and a cache hit doesn't
        // repeat clang's warnings, so a check that a flag compiles without
        // any (cc-rs's) answers otherwise once it has run before: cargo-c
        // gained AVX-512 code in a store that had built it twice. So each
        // module has its own, in its directory, as `zig build` has by
        // default: as fresh as the module's directory is. ${cache} keeps
        // zig's libc and compiler-rt.
        try environment.set(arena, &vars, "ZIG_LOCAL_CACHE_DIR", try std.fmt.allocPrint(arena, "{s}\\src\\{s}\\.zig-cache", .{ letter, m.name }));
        // With its stderr on a console, zig 0.16 draws a progress line from
        // another thread; if zig cancels that thread just as it first takes
        // the stderr lock (200 ms in), the lock is never released, and
        // zig's exit waits for it forever: one of OpenSSL's hundreds of
        // parallel `zig cc` hung a build run from a terminal. A
        // ZIG_PROGRESS zig can't parse as a handle makes it skip the line.
        try environment.set(arena, &vars, "ZIG_PROGRESS", "off");
        // A build on fewer processors is told how many, where a tool that
        // doesn't ask Windows looks (cargo); a tool's image or the module
        // that says otherwise wins.
        if (b.limits.fewerCpus()) |n| {
            const count = try std.fmt.allocPrint(arena, "{d}", .{n});
            for (process.job_count_vars) |name| {
                if (!environment.has(vars.items, name)) try environment.set(arena, &vars, name, count);
            }
        }
        if (step == .build and !m.network) {
            // Discouraged, not prevented: tools that honor proxy variables
            // fail to connect, and nothing else is stopped.
            for ([_][]const u8{ "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY" }) |name|
                try environment.set(arena, &vars, name, "http://127.0.0.1:9");
            try environment.set(arena, &vars, "NO_PROXY", "");
        }
        try environment.expand(arena, &vars, .{ .app = "", .data = "" }, m.env, &.{});
        const env = try environment.build(arena, ctx.env, .{
            .id = b.id,
            .profile = b.profile,
            .path = b.path_dirs,
            .system_root = system_root,
            .vars = vars.items,
        });
        const block = try environment.encodeBlock(arena, env.items);
        const shell = try b.findShell(ctx, m, system_root);
        const cwd = try std.fmt.allocPrint(arena, "{s}\\src\\{s}", .{ letter, m.name });

        const label = if (step == .vendor) " vendor" else "";
        for (commands, 1..) |command, n| {
            if (n <= how.from) continue;
            note("[{s}{s} {d}/{d}] {s}", .{ m.name, label, n, commands.len, command });
            const start = ctx.now();
            // Named, so that `zigsaw ps` may look into it.
            const job_name = if (b.listed != null) try ps.jobName(ctx.io, arena) else null;
            const child = try process.start(arena, .{
                .exe = shell.exe,
                .command_line = try shell.commandLine(arena, command),
                .env_block = block,
                .cwd = cwd,
                .limits = b.limits,
                .job_name = job_name,
            });
            if (b.listed) |l| {
                l.record.module = m.name;
                l.record.step = @tagName(step);
                l.record.n = @intCast(n);
                l.record.of = @intCast(commands.len);
                l.record.command = command;
                l.record.job = child.job_name;
                l.record.memory_limit = b.limits.memory;
                l.record.cpus = b.limits.fewerCpus();
                l.update(ctx);
            }
            const report = try child.waitReport();
            const code = report.code;
            // So a log shows where a build's time goes, and its memory.
            const took = ctx.since(start);
            if (took.ms >= 1000) {
                if (ctx.verbose)
                    note("[{s}{s} {d}/{d}] took {f}, and {d} MB at most at once", .{ m.name, label, n, commands.len, took, (report.peak_memory + (1 << 20) - 1) >> 20 })
                else
                    note("[{s}{s} {d}/{d}] took {f}", .{ m.name, label, n, commands.len, took });
            }
            // A tool refused memory says what Windows told it, that the
            // paging file is too small, and may go on and fail later, or not.
            if (report.memory_limit_reached) |bytes|
                note("[{s}{s} {d}/{d}] reached the build's memory limit of {f} (--memory), and was refused more", .{ m.name, label, n, commands.len, override.Size{ .bytes = bytes } });
            if (code != 0) switch (on_failure) {
                .fail => {
                    if (how.continued) note("module {s} went on from what its last build left; if that's what's wrong, `zigsaw build --clean={s}` starts it afresh", .{ m.name, m.name });
                    return fail("module {s}: {t} command {d} exited with code {d}:\n  {s}", .{ m.name, step, n, code, command });
                },
                .warn => {
                    note("warning: module {s}: {t} command {d} exited with code {d}", .{ m.name, step, n, code });
                    return error.CommandFailed;
                },
            };
            if (step == .build) if (b.from_last) |res| res.stepped(ctx, how.index, m, n);
        }
    }

    fn findShell(b: *const BuildRoot, ctx: *Context, m: recipe.Module, system_root: []const u8) !Shell {
        const arena = ctx.arena;
        switch (m.shell) {
            .cmd => return .{ .exe = try std.fmt.allocPrint(arena, "{s}\\System32\\cmd.exe", .{system_root}), .kind = .cmd },
            .sh => {
                for ([_]struct { []const u8, Shell.Kind }{ .{ "sh.exe", .sh }, .{ "busybox.exe", .busybox } }) |candidate| {
                    for (b.path_dirs) |dir| {
                        const exe = try std.fs.path.join(arena, &.{ dir, candidate[0] });
                        if (try Store.exists(ctx.io, exe)) return .{ .exe = exe, .kind = candidate[1] };
                    }
                }
                return fail("module {s}: its build commands run in sh, which none of the recipe's sdk or runtimes provides; add busybox to \"sdk\"", .{m.name});
            },
        }
    }
};

/// Lets go of a recipe's kept build, whose root goes if nothing was recorded
/// (see checkpoint.Kept.release). Not deleting it fails nothing: `prune`
/// deletes such a root, as does the recipe's next build.
fn releaseKept(ctx: *Context, kept: checkpoint.Kept) void {
    kept.release(ctx.arena) catch |err|
        note("warning: couldn't delete all of {s} ({t}); `zigsaw prune` will retry", .{ kept.root, err });
}

/// What a build takes from the recipe's kept build (see checkpoint.zig): the
/// modules it skips, and the directories it builds in again.
///
/// A module is skipped while it and the modules before it have the inputs
/// they were built with. From the first that hasn't, modules are built,
/// where their last build left them while zigsaw, the build's tools and
/// the recipe's modules up to them are the same:
///
/// - One that stopped in its commands, failed or interrupted, goes on at
///   the command that didn't finish, in its directory as that command left
///   it. The commands before it aren't run again: a patch doesn't apply
///   twice, and ninja goes on from what it compiled.
/// - A project's module, whose files changed, is given them in its
///   directory and runs every command, as make is run again. Each file
///   whose contents differ from its source's is written again, changed by
///   the project or edited by the last build, so a `sed -i` doesn't apply
///   twice. So is a module after it.
///
/// Otherwise a module starts in a new directory, as a vendor step's always
/// does.
///
/// The kept build is in the store's cache\work\<key>, keyed by the recipe's
/// path and the app's id, so two checkouts don't share one; its root is
/// tmp\zigsaw-build-<key>, where any build's is (see checkpoint.zig).
const Resume = struct {
    kept: checkpoint.Kept,
    keys: []const checkpoint.Keys,
    plan: checkpoint.Plan,
    /// The kept build's record couldn't be written: the rest of this build
    /// leaves it as it is, and the next goes back to what it says.
    broken: bool = false,

    /// Takes the recipe's kept build, and brings it to where this build
    /// starts. Null if another build has it.
    fn init(ctx: *Context, r: recipe.Recipe, recipe_path: []const u8, source: []const u8, projects: *const project.Snapshots, tools: []const Tool, opts: Options) !?*Resume {
        const arena = ctx.arena;
        var h: std.crypto.hash.sha2.Sha256 = .init(.{});
        h.update(try std.ascii.allocLowerString(arena, source));
        h.update("\n");
        h.update(try std.ascii.allocLowerString(arena, r.id));
        const key = std.fmt.bytesToHex(h.finalResult(), .lower);
        const dir = try ctx.store.path(arena, &.{ "cache", "work", key[0..16] });
        const root = try checkpoint.rootFor(arena, try ctx.store.path(arena, &.{"tmp"}), key[0..16]);
        var kept = try checkpoint.Kept.open(ctx.io, arena, dir, root) orelse {
            note("{s}: another build is going on in its kept build; this one builds every module, in a directory of its own", .{r.id});
            return null;
        };
        errdefer releaseKept(ctx, kept);
        if (opts.clean and kept.found) {
            kept.reset(arena) catch |err| return fail("deleting {s}'s kept build, {s}: {t}", .{ r.id, dir, err });
            kept.found = false;
            if (ctx.verbose) note("{s}: deleted its kept build", .{r.id});
        }

        const keys = try moduleKeys(ctx, r, recipe_path, projects, tools);
        const names = try arena.alloc([]const u8, r.modules.len);
        for (names, r.modules) |*name, m| name.* = m.name;
        const afresh = if (opts.clean_from) |name| moduleIndex(r, name).? else r.modules.len;
        var plan = try kept.plan(arena, names, keys, afresh);
        const continues = try arena.dupe(bool, plan.continues);
        for (r.modules, continues) |m, *c| {
            if (m.vendor != null or m.build.len == 0) c.* = false;
        }
        plan.continues = continues;
        // A project's module is given its files as they are now, and runs
        // every command on them, as make is run again.
        if (plan.step) |s| {
            const m = r.modules[plan.done];
            if (!continues[plan.done] or hasProject(m, projects) or s.commands > m.build.len or
                !try Store.exists(ctx.io, try std.fs.path.join(arena, &.{ kept.root, "src", m.name })))
                plan.step = null;
        }

        var why: ?[]const u8 = null;
        if (plan.resumes()) {
            why = try vendorToRun(ctx, r, plan.done);
            if (why == null) why = kept.goBack(arena, plan, names) catch |err|
                @as(?[]const u8, try std.fmt.allocPrint(arena, "its files couldn't be put back as they were ({t})", .{err}));
        }
        if (why != null or !plan.resumes()) {
            if (why) |w| {
                note("{s}: building every module again: {s}", .{ r.id, w });
            } else if (kept.found and ctx.verbose) {
                note("{s}: nothing of its last build is taken: zigsaw, its tools or its first module changed", .{r.id});
            }
            kept.reset(arena) catch |err| return fail("deleting {s}'s kept build, {s}: {t}", .{ r.id, dir, err });
            const none = try arena.alloc(bool, r.modules.len);
            @memset(none, false);
            plan = .{ .done = 0, .continues = none };
        } else if (plan.done == r.modules.len) {
            note("{s}: every module is as its last build left it", .{r.id});
        } else {
            const m = r.modules[plan.done];
            const at = if (plan.step) |s|
                if (s.commands < m.build.len) try std.fmt.allocPrint(arena, ", command {d} of {d}", .{ s.commands + 1, m.build.len }) else ", whose commands all ran"
            else
                "";
            if (plan.done > 0 or plan.step != null)
                note("{s}: {d} of {d} modules are as its last build left them; going on at {s}{s}", .{ r.id, plan.done, r.modules.len, m.name, at });
        }

        const res = try arena.create(Resume);
        res.* = .{ .kept = kept, .keys = keys, .plan = plan };
        return res;
    }

    /// Why the build can't go on from module `from`: a vendor step whose
    /// commands have to run. They run before anything is built, and the
    /// tools' folders start again after them, as only a first build's can.
    fn vendorToRun(ctx: *Context, r: recipe.Recipe, from: usize) !?[]const u8 {
        const arena = ctx.arena;
        for (r.modules[from..]) |m| if (m.vendor) |v| {
            const cached = if (v.sha256) |hash| try Store.exists(ctx.io, try ctx.store.path(arena, &.{ "cache", "downloads", hash })) else false;
            if (!cached) return try std.fmt.allocPrint(arena, "module {s}'s vendor commands have to run", .{m.name});
        };
        return null;
    }

    fn started(res: *Resume, ctx: *Context, i: usize, m: recipe.Module) void {
        if (res.broken) return;
        res.kept.started(ctx.arena, i, m.name, res.keys[i]) catch |err| res.giveUp(err);
    }

    /// Records what's in the prefix after the module's command `commands`,
    /// for the build that goes on from there; or after its sources, for a
    /// module without commands.
    fn stepped(res: *Resume, ctx: *Context, i: usize, m: recipe.Module, commands: usize) void {
        if (res.broken) return;
        const start = ctx.now();
        res.kept.stepped(ctx.arena, i, m.name, res.keys[i], commands) catch |err| return res.giveUp(err);
        ctx.timed(start, "record what's in the prefix", .{});
    }

    fn finished(res: *Resume, ctx: *Context, i: usize, m: recipe.Module) void {
        if (res.broken) return;
        res.kept.finished(ctx.arena, i, m.name, res.keys[i], m.build.len) catch |err| res.giveUp(err);
    }

    fn giveUp(res: *Resume, err: anyerror) void {
        res.broken = true;
        note("warning: couldn't record how far the build is ({t}); the next one may build more again", .{err});
    }

    /// Puts the module's sources in `dest`: brought up to date in the
    /// directory its last build left, if the build goes on in it, which it
    /// returns; written into a new one otherwise.
    fn bringSources(res: *Resume, ctx: *Context, i: usize, m: recipe.Module, tree: *const Tree, dest: []const u8, projects: *const project.Snapshots) !bool {
        const io = ctx.io;
        const arena = ctx.arena;
        // What a project had the last time, to delete what it lost since.
        const lists = m.build.len > 0 and hasProject(m, projects);
        if (res.plan.continues[i] and try Store.exists(io, dest)) {
            const previous: []const []const u8 = if (lists) try res.kept.files(arena, m.name) else &.{};
            const start = ctx.now();
            const synced = tree.syncFiles(io, arena, dest, previous) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => return fail("module {s}: bringing its sources up to date in {s}: {t}", .{ m.name, dest, err }),
            };
            ctx.timed(start, "bring {d} files up to date", .{synced.files.len});
            if (ctx.verbose)
                note("module {s}: goes on in the directory its last build left, {d} file(s) rewritten, {d} removed", .{ m.name, synced.written, synced.removed });
            if (lists) try res.kept.setFiles(arena, m.name, synced.files);
            return true;
        }
        try writeSources(io, arena, tree, m, dest);
        if (lists) {
            var files: std.ArrayList([]const u8) = .empty;
            for (tree.nodes.values()) |node| if (node.content != .dir) try files.append(arena, node.path);
            try res.kept.setFiles(arena, m.name, files.items);
        }
        return false;
    }

    fn hasProject(m: recipe.Module, projects: *const project.Snapshots) bool {
        for (m.sources, 0..) |_, i| if (projects.get(m.name, i) != null) return true;
        return false;
    }
};

/// The keys of the recipe's modules (see checkpoint.zig): what each one's
/// build depends on, chained. The recipe's other fields shape the image's
/// config and layer, not what the modules build.
fn moduleKeys(ctx: *Context, r: recipe.Recipe, recipe_path: []const u8, projects: *const project.Snapshots, tools: []const Tool) ![]checkpoint.Keys {
    const io = ctx.io;
    const arena = ctx.arena;
    var h: std.crypto.hash.sha2.Sha256 = .init(.{});
    h.update("zigsaw kept build\n");
    h.update(&(try Store.sha256File(io, try win32.selfExePath(arena))).hex);
    h.update("\n");
    h.update(try std.ascii.allocLowerString(arena, r.id));
    for (tools) |t| {
        h.update("\n");
        h.update(t.image);
    }
    const base = std.fmt.bytesToHex(h.finalResult(), .lower);

    const base_dir = std.fs.path.dirname(recipe_path) orelse ".";
    const inputs = try arena.alloc(checkpoint.Inputs, r.modules.len);
    for (r.modules, inputs) |m, *in| {
        var local: std.ArrayList([]const u8) = .empty;
        var own: std.ArrayList([]const u8) = .empty;
        for (m.sources, 0..) |src, i| {
            const p = src.path orelse continue;
            if (projects.get(m.name, i)) |s| {
                try own.append(arena, s.hash);
                continue;
            }
            const full = if (std.fs.path.isAbsolute(p)) p else try std.fs.path.join(arena, &.{ base_dir, p });
            const file_hash = Store.sha256File(io, full) catch |err|
                return fail("module {s}: reading {s}: {t}", .{ m.name, full, err });
            try local.append(arena, try arena.dupe(u8, &file_hash.hex));
        }
        in.* = .{ .definition = try oci.toJson(arena, m), .local = local.items, .projects = own.items };
    }
    return checkpoint.chain(arena, &base, inputs);
}

/// Creates a module's indexed sources in `dest`.
fn writeSources(io: Io, arena: Allocator, tree: *const Tree, m: recipe.Module, dest: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, dest);
    tree.writeFiles(io, arena, dest) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return fail("module {s}: unpacking its sources into {s}: {t}", .{ m.name, dest, err }),
    };
}

/// Unpacks a module's sources into `dest`, all of them already downloaded,
/// without noting their hashes for the record of the build.
fn unpackSources(ctx: *Context, m: recipe.Module, recipe_path: []const u8, projects: *const project.Snapshots, dest: []const u8) !void {
    var sources: Sources = .{ .ctx = ctx, .fetcher = .{ .ctx = ctx, .base_dir = std.fs.path.dirname(recipe_path) orelse "." }, .projects = projects };
    defer sources.deinit();
    var tree: Tree = .{};
    try sources.add(&tree, m, recipe_path);
    try writeSources(ctx.io, ctx.arena, &tree, m, dest);
}

fn containsIgnoreCase(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.ascii.eqlIgnoreCase(n, name)) return true;
    return false;
}

const Shell = struct {
    exe: []const u8,
    kind: Kind,

    const Kind = enum { sh, busybox, cmd };

    fn commandLine(s: Shell, arena: Allocator, command: []const u8) ![]const u8 {
        return switch (s.kind) {
            .sh => process.buildCommandLine(arena, s.exe, &.{ "-c", command }),
            // BusyBox's sh runs its applets (make, sed, tar...) as commands,
            // without them being on PATH.
            .busybox => process.buildCommandLine(arena, s.exe, &.{ "sh", "-c", command }),
            // /s: the quotes around the command are cmd.exe's to strip, and
            // the command itself is the recipe's, as typed.
            .cmd => line: {
                var out: std.ArrayList(u8) = .empty;
                try process.appendQuoted(arena, &out, s.exe);
                try out.print(arena, " /d /s /c \"{s}\"", .{command});
                break :line out.items;
            },
        };
    }
};

test "a build's tools: each image once, one version of each app" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = "sha256:" ++ repeat("a", 64);
    const b = "sha256:" ++ repeat("b", 64);
    const tool = struct {
        fn of(what: []const u8, image: []const u8, id: []const u8) Tool {
            return .{ .image = image, .id = id, .version = "1", .what = what, .dir = "C:\\d", .path = &.{}, .env = .{}, .aliases = null };
        }
    }.of;
    var tools: Tools = .{ .recipe_path = "r.json" };
    try std.testing.expectEqual(0, (try tools.add(arena, tool("sdk x", a, "org.x"))).?);
    try std.testing.expectEqual(null, try tools.add(arena, tool("runtime x", a, "org.x")));
    try std.testing.expectError(error.Failed, tools.add(arena, tool("sdk y", b, "ORG.X")));
    try std.testing.expectEqual(1, (try tools.add(arena, tool("sdk y", b, "org.y"))).?);
    try std.testing.expectEqual(2, tools.list.items.len);
}

test "tool variables: later tools win, but an SDK over its runtimes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tool = struct {
        fn of(gpa: Allocator, id: []const u8, value: []const u8, brings: usize) !Tool {
            var env: std.json.ArrayHashMap([]const u8) = .{};
            try env.map.put(gpa, "X", value);
            try env.map.put(gpa, id, "${app}");
            return .{ .image = id, .id = id, .version = "1", .what = id, .dir = id, .path = &.{}, .env = env, .aliases = null, .brings = brings };
        }
    }.of;
    const get = struct {
        fn of(vars: []const environment.Var, name: []const u8) []const u8 {
            for (vars) |v| if (std.mem.eql(u8, v.name, name)) return v.value;
            return "";
        }
    }.of;
    // Two plain tools: the later wins.
    var vars = try toolVars(arena, &.{ try tool(arena, "a", "a", 0), try tool(arena, "b", "b", 0) }, null);
    try std.testing.expectEqualStrings("b", get(vars.items, "X"));
    // An SDK and the runtime it brings, then another tool.
    vars = try toolVars(arena, &.{ try tool(arena, "sdk", "sdk", 1), try tool(arena, "rt", "rt", 0) }, null);
    try std.testing.expectEqualStrings("sdk", get(vars.items, "X"));
    try std.testing.expectEqualStrings("rt", get(vars.items, "rt"));
    vars = try toolVars(arena, &.{ try tool(arena, "sdk", "sdk", 1), try tool(arena, "rt", "rt", 0), try tool(arena, "c", "c", 0) }, null);
    try std.testing.expectEqualStrings("c", get(vars.items, "X"));
}

test "shell command lines" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bb: Shell = .{ .exe = "C:\\z\\busybox.exe", .kind = .busybox };
    try std.testing.expectEqualStrings("C:\\z\\busybox.exe sh -c \"cp a \\\"$PREFIX/b c\\\"\"", try bb.commandLine(arena, "cp a \"$PREFIX/b c\""));
    const cmd: Shell = .{ .exe = "C:\\Windows\\System32\\cmd.exe", .kind = .cmd };
    try std.testing.expectEqualStrings("C:\\Windows\\System32\\cmd.exe /d /s /c \"cl /nologo \"a b.c\" && copy x %PREFIX%\"", try cmd.commandLine(arena, "cl /nologo \"a b.c\" && copy x %PREFIX%"));
}
