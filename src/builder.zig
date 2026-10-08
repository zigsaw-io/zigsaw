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
//!   B:\home\          the profile folders of the build's tools, fresh for each build
//!   B:\data\          the data directory runtimes' variables point to while building
//!   B:\cache\<id>\    ${cache} of a tool that uses it, kept between builds in the
//!                     store's cache\tools\<id>, and moved here for the build
//!   B:\bin\           shims for the commands the tools' images alias, first on PATH
//!
//! Commands run in an environment built from scratch, as apps do, with
//! B:\prefix\bin and the SDK's and runtimes' directories on PATH (after the
//! aliases' B:\bin), and in a job object that ends
//! whatever they leave running.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Tree = @import("Tree.zig");
const deps = @import("deps.zig");
const drive = @import("drive.zig");
const environment = @import("environment.zig");
const exports = @import("exports.zig");
const install = @import("install.zig");
const Fetcher = @import("fetch.zig");
const msvc_host = @import("msvc.zig");
const oci = @import("oci.zig");
const process = @import("process.zig");
const recipe = @import("recipe.zig");
const Sidecar = @import("Sidecar.zig");
const Store = @import("Store.zig");
const win32 = @import("win32.zig");
const fail = Context.fail;
const note = Context.note;

pub const Options = struct {
    /// Keep the build root afterwards, to look at what a build left. Builds
    /// even if an earlier build with the same inputs could be reused.
    keep_build_dir: bool = false,
    /// Build even if an earlier build with the same inputs could be reused.
    rebuild: bool = false,
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

    // A host toolchain is an input zigsaw can't pin, so those builds are
    // never reused.
    const inputs = if (r.host.len == 0) try inputHash(ctx, r, bytes, recipe_path) else null;
    if (inputs) |*h| if (!opts.rebuild and !opts.keep_build_dir) {
        if (try ctx.store.readBuildCache(arena, h)) |digest| if (try ctx.store.readCompleteImage(arena, digest)) |image| {
            if (ctx.verbose) note("{s} {s}: built before from the same inputs ({s}); --rebuild builds it again", .{ r.id, r.version, oci.shortDigest(digest) });
            return .{ .manifest_digest = digest, .manifest = image.manifest, .config = image.config, .source = source };
        };
    };
    const image = try buildImage(ctx, r, recipe_path, source, opts);
    if (inputs) |*h| try ctx.store.writeBuildCache(arena, h, image.manifest_digest);
    return image;
}

/// A hash of everything a build's result depends on: this zigsaw, the
/// recipe, and the contents of its local sources. URL sources, runtimes and
/// SDK images are pinned by hash in the recipe itself.
fn inputHash(ctx: *Context, r: recipe.Recipe, bytes: []const u8, recipe_path: []const u8) ![64]u8 {
    const io = ctx.io;
    const arena = ctx.arena;
    var h: std.crypto.hash.sha2.Sha256 = .init(.{});
    h.update("zigsaw build inputs\n");
    h.update(&(try Store.sha256File(io, try win32.selfExePath(arena))).hex);
    h.update(bytes);
    const base_dir = std.fs.path.dirname(recipe_path) orelse ".";
    for (r.modules) |m| for (m.sources) |src| {
        const p = src.path orelse continue;
        const full = if (std.fs.path.isAbsolute(p)) p else try std.fs.path.join(arena, &.{ base_dir, p });
        const file_hash = Store.sha256File(io, full) catch |err|
            return fail("module {s}: reading {s}: {t}", .{ m.name, full, err });
        h.update(&file_hash.hex);
    };
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

fn buildImage(ctx: *Context, r: recipe.Recipe, recipe_path: []const u8, source: []const u8, opts: Options) !install.Image {
    const arena = ctx.arena;

    // Runtimes go into the image and are on PATH while building. The SDK is
    // only on PATH, ahead of the runtimes, and in the record of the build;
    // it's only unpacked if there's something to build with it.
    const building = r.hasBuildCommands();
    var tools: std.ArrayList(Tool) = .empty;
    var build_info: oci.Build = .{};
    for (r.sdk.map.keys(), r.sdk.map.values()) |alias, reference| {
        const dep = try deps.resolve(ctx, recipe_path, .sdk, alias, reference);
        try build_info.sdk.map.put(arena, alias, dep.manifest_digest);
        if (building) try tools.append(arena, .{ .dir = (try ctx.store.useLayers(arena, &.{dep.layer()}))[0], .config = dep.config });
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
        try tools.append(arena, .{ .dir = dir, .config = dep.config });
    }
    for (r.modules) |m| build_info.network = build_info.network or m.network;

    var sources: Sources = .{ .ctx = ctx, .fetcher = .{ .ctx = ctx, .base_dir = std.fs.path.dirname(recipe_path) orelse ".", .app = r.id } };
    defer sources.deinit();
    var tree: Tree = undefined;
    var root: ?BuildRoot = null;
    defer if (root) |*b| b.finish(ctx, opts.keep_build_dir);
    if (building) {
        // Every download first, so a missing or wrong hash fails the build
        // before anything is built.
        for (r.modules) |m| for (m.sources) |src| {
            if (src.image == null) _ = try sources.fetcher.fetch(src);
        };
        root = try .init(ctx, r, tools.items);
        if (root.?.msvc) |tc| {
            try build_info.host.map.put(arena, "msvc", tc.tools_version);
            try build_info.host.map.put(arena, "windows-sdk", tc.sdk_version);
        }
        // Then every vendor step, for the same reason.
        var vendored: std.json.ArrayHashMap([]const u8) = .{};
        for (r.modules) |m| if (m.vendor != null) {
            try vendored.map.put(arena, m.name, try root.?.vendor(ctx, m, recipe_path));
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
    if (config.shortcuts) |s| for (s.map.keys(), s.map.values()) |name, shortcut| if (shortcut.icon) |icon|
        try checkCommand(ctx, &tree, placeholders, try std.fmt.allocPrint(arena, "shortcut \"{s}\" has the icon", .{name}), icon);

    const start = ctx.now();
    const layer_file = try tree.writeLayerFile(ctx, .gzip);
    ctx.timed(start, "write layer ({d} entries)", .{tree.nodes.count()});
    try layers.append(arena, try ctx.store.putBlobFile(arena, layer_file.path, layer_file.hash, oci.media_type.layer_tar_gzip));

    const config_desc = try ctx.store.putBlob(arena, try oci.toJson(arena, config), oci.media_type.config);
    var annotations: std.json.ArrayHashMap([]const u8) = .{};
    try annotations.map.put(arena, "org.opencontainers.image.title", r.id);
    try annotations.map.put(arena, "org.opencontainers.image.version", r.version);
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
    archives: std.ArrayList(*Tree.Archive) = .empty,
    hashes: std.ArrayList([]const u8) = .empty,
    images: std.ArrayList([]const u8) = .empty,

    fn deinit(s: *Sources) void {
        for (s.archives.items) |a| a.close(s.ctx.io);
        s.fetcher.deinit();
    }

    /// Adds a module's sources to `tree`.
    fn add(s: *Sources, tree: *Tree, m: recipe.Module, recipe_path: []const u8) !void {
        const ctx = s.ctx;
        const arena = ctx.arena;
        for (m.sources) |src| {
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

/// An SDK image or runtime that builds run with.
const Tool = struct {
    dir: []const u8,
    config: oci.AppConfig,
};

/// The directory a build happens in, mapped to the build drive.
const BuildRoot = struct {
    /// The real path, under the store's tmp\.
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

    const letter = drive.letter;

    fn init(ctx: *Context, r: recipe.Recipe, tools: []const Tool) !BuildRoot {
        const io = ctx.io;
        const arena = ctx.arena;
        const path = try ctx.store.makeTmpDir(arena, drive.dir_prefix[0 .. drive.dir_prefix.len - 1]);
        errdefer Io.Dir.cwd().deleteTree(io, path) catch {};
        for ([_][]const u8{ "src", "prefix", "cache" }) |sub| try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ path, sub }));
        try makeScratchDirs(ctx, path, .new);
        const profile: environment.Profile = try .init(arena, letter ++ "\\");

        var path_dirs: std.ArrayList([]const u8) = .empty;
        var tool_vars: std.ArrayList(environment.Var) = .empty;
        var caches: std.ArrayList([]const u8) = .empty;
        var aliases: std.ArrayList([]const u8) = .empty;
        var shim_exe: ?[]const u8 = null;
        for (tools) |t| {
            // In a tool's own entries, ${app} is its directory; ${data} is
            // where the build keeps runtimes' data, and ${cache} the tool's
            // cache, if it uses one.
            const id = t.config.id;
            const cache = oci.usesCache(t.config.path, t.config.env);
            if (cache and !containsIgnoreCase(caches.items, id)) try caches.append(arena, id);
            const p: oci.Placeholders = .{
                .app = t.dir,
                .data = letter ++ "\\data",
                .cache = if (cache) try std.fmt.allocPrint(arena, "{s}\\cache\\{s}", .{ letter, id }) else null,
            };
            try path_dirs.appendSlice(arena, try environment.pathDirs(arena, p, t.config.path));
            try environment.expand(arena, &tool_vars, p, t.config.env);
            // Of two tools with an alias of the same name, the first's wins,
            // as on PATH.
            if (t.config.aliases) |a| for (a.map.keys(), a.map.values()) |name, e| {
                if (containsIgnoreCase(aliases.items, name)) continue;
                try aliases.append(arena, name);
                if (shim_exe == null) shim_exe = try exports.shimExe(ctx, try win32.selfExePath(arena), .console);
                try writeAlias(ctx, path, shim_exe.?, t, p, name, e);
            };
        }
        // The aliases come first: a tool's image says what they are. BusyBox's
        // sh runs its own applets before anything on PATH, so they win over
        // those too (zig's ar over BusyBox's).
        // What earlier modules installed comes next, as /app/bin does in
        // Flatpak's builds: programs a later module runs (GLib's
        // glib-compile-resources), and the DLLs they need.
        try path_dirs.insert(arena, 0, letter ++ "\\prefix\\bin");
        if (aliases.items.len > 0) {
            try path_dirs.insert(arena, 0, letter ++ "\\bin");
            try environment.set(arena, &tool_vars, "BB_OVERRIDE_APPLETS", try std.mem.join(arena, " ", aliases.items));
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
            Store.renameRetrying(io, kept, here, cache_move_wait_ms) catch |err| {
                if (ctx.verbose) note("couldn't use {s}'s cache ({t}); building without it", .{ id, err });
            };
        }
        try Io.Dir.cwd().createDirPath(io, here);
    }

    /// Moves the tools' caches back into the store, unmaps the drive, and
    /// deletes the build root, unless it's to be kept.
    fn finish(b: *BuildRoot, ctx: *Context, keep: bool) void {
        b.drive.release();
        for (b.caches) |id| b.keepCache(ctx, id) catch |err| {
            if (ctx.verbose) note("couldn't keep {s}'s cache ({t}); the next build starts without it", .{ id, err });
        };
        if (keep) {
            note("kept the build directory: {s}", .{b.path});
        } else {
            Store.deleteTree(ctx.io, ctx.arena, b.path) catch |err|
                note("warning: couldn't delete all of {s} ({t}); `zigsaw prune` will retry", .{ b.path, err });
        }
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
        for (r.modules) |m| {
            var tree: Tree = .{};
            try sources.add(&tree, m, recipe_path);
            // A module with a vendor step has its files already.
            if (m.vendor == null) {
                const dest = if (m.build.len == 0) prefix else try std.fs.path.join(arena, &.{ b.path, "src", m.name });
                try writeSources(io, arena, &tree, m, dest);
            }
            if (m.build.len > 0) try b.runCommands(ctx, m, .build, .fail);
        }
        return Tree.fromDir(io, arena, prefix);
    }

    /// Runs a module's vendor step, or takes what an earlier one made from
    /// the download cache, and leaves the module's directory with its sources
    /// and what the step made. Returns the sha256 of that. If the commands of
    /// a pinned step fail, what they make is fetched from the sources next to
    /// the app's image, if it's there.
    ///
    /// Either way, the build then starts from the same files: after the
    /// commands run, the module's directory and the build's profile folders
    /// start again from scratch, with only what the step left in its `dir`.
    fn vendor(b: *const BuildRoot, ctx: *Context, m: recipe.Module, recipe_path: []const u8) ![]const u8 {
        const io = ctx.io;
        const arena = ctx.arena;
        const v = m.vendor.?;
        const dest = try std.fs.path.join(arena, &.{ b.path, "src", m.name });
        try unpackSources(ctx, m, recipe_path, dest);

        var cached: ?[]const u8 = if (v.sha256) |h| try ctx.store.path(arena, &.{ "cache", "downloads", h }) else null;
        if (cached != null and try Store.exists(io, cached.?)) {
            if (ctx.verbose) note("module {s}: vendored files from the cache (sha256 {s})", .{ m.name, v.sha256.? });
        } else if (b.runCommands(ctx, m, .vendor, if (v.sha256 != null) .warn else .fail)) |_| {
            const made = try std.fs.path.join(arena, &.{ dest, v.dir });
            if (!try Store.exists(io, made))
                return fail("module {s}: the vendor commands left nothing in {s}", .{ m.name, v.dir });
            const tree = try Tree.fromDir(io, arena, made);
            const file = try tree.writeLayerFile(ctx, .none);
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
            try unpackSources(ctx, m, recipe_path, dest);
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
            try unpackSources(ctx, m, recipe_path, dest);
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
    /// runCommands returns error.CommandFailed after saying so.
    fn runCommands(b: *const BuildRoot, ctx: *Context, m: recipe.Module, step: Step, on_failure: enum { fail, warn }) !void {
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
        if (step == .build and !m.network) {
            // Discouraged, not prevented: tools that honor proxy variables
            // fail to connect, and nothing else is stopped.
            for ([_][]const u8{ "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY" }) |name|
                try environment.set(arena, &vars, name, "http://127.0.0.1:9");
            try environment.set(arena, &vars, "NO_PROXY", "");
        }
        try environment.expand(arena, &vars, .{ .app = "", .data = "" }, m.env);
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
            note("[{s}{s} {d}/{d}] {s}", .{ m.name, label, n, commands.len, command });
            const code = try process.spawn(arena, .{
                .exe = shell.exe,
                .command_line = try shell.commandLine(arena, command),
                .env_block = block,
                .cwd = cwd,
            });
            if (code != 0) switch (on_failure) {
                .fail => return fail("module {s}: {t} command {d} exited with code {d}:\n  {s}", .{ m.name, step, n, code, command }),
                .warn => {
                    note("warning: module {s}: {t} command {d} exited with code {d}", .{ m.name, step, n, code });
                    return error.CommandFailed;
                },
            };
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

/// Puts one of a tool's aliases into the build root's bin\, as a shim that
/// runs its command with its arguments, then the caller's, less those it
/// drops.
fn writeAlias(ctx: *Context, root: []const u8, shim_exe: []const u8, t: Tool, p: oci.Placeholders, name: []const u8, e: oci.Export) !void {
    const io = ctx.io;
    const arena = ctx.arena;
    const exe = if (oci.isPlaceholderPath(e.command)) try p.expand(arena, e.command) else try std.fs.path.join(arena, &.{ t.dir, e.command });
    std.mem.replaceScalar(u8, exe, '/', '\\');
    if (!try Store.exists(io, exe))
        return fail("{s}'s alias {s} runs {s}, which isn't in it", .{ t.config.id, name, e.command });
    const args = try arena.alloc([]const u8, e.args.len);
    for (args, e.args) |*arg, template| arg.* = try p.expand(arena, template);

    const bin = try std.fs.path.join(arena, &.{ root, "bin" });
    try Io.Dir.cwd().createDirPath(io, bin);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}\\{s}.exe", .{ bin, name }), .data = shim_exe });
    const alias: Sidecar.Alias = .{ .exe = exe, .command_line = try process.buildCommandLine(arena, exe, args), .drop = e.drop orelse &.{} };
    var text: Io.Writer.Allocating = .init(arena);
    try alias.format(&text.writer);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}\\{s}{s}", .{ bin, name, Sidecar.extension }), .data = text.written() });
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
fn unpackSources(ctx: *Context, m: recipe.Module, recipe_path: []const u8, dest: []const u8) !void {
    var sources: Sources = .{ .ctx = ctx, .fetcher = .{ .ctx = ctx, .base_dir = std.fs.path.dirname(recipe_path) orelse "." } };
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

test "shell command lines" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bb: Shell = .{ .exe = "C:\\z\\busybox.exe", .kind = .busybox };
    try std.testing.expectEqualStrings("C:\\z\\busybox.exe sh -c \"cp a \\\"$PREFIX/b c\\\"\"", try bb.commandLine(arena, "cp a \"$PREFIX/b c\""));
    const cmd: Shell = .{ .exe = "C:\\Windows\\System32\\cmd.exe", .kind = .cmd };
    try std.testing.expectEqualStrings("C:\\Windows\\System32\\cmd.exe /d /s /c \"cl /nologo \"a b.c\" && copy x %PREFIX%\"", try cmd.commandLine(arena, "cl /nologo \"a b.c\" && copy x %PREFIX%"));
}
