//! A project of several apps: a zigsaw.json that lists recipes as `"apps"`,
//! in place of being one, as a Cargo workspace lists its packages. `zigsaw
//! build` builds and installs them all, each after the apps it uses, as
//! `docker compose build` builds a compose file's services.
//!
//! An app of the project names another by its id, unpinned: `"runtimes": {
//! "engine": "org.example.engine" }`. The build resolves that to the image it
//! built of that app, in memory, before anything reads the recipe (`pin`), so
//! the recipe never changes, and the build's inputs, its kept build and the
//! image's record have the digest, as they would a pin's. The same files make
//! the same image, and so the same digest, anywhere.
//!
//! Built alone (`zigsaw build <its directory>`, or `zigsaw update`, which
//! builds the recipe its ref names), an app whose recipe names another so is
//! looked for in the projects above its directory (`buildFor`). The first
//! that lists it builds the apps it uses first, without installing them.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const builder = @import("builder.zig");
const container = @import("container.zig");
const deps = @import("deps.zig");
const install = @import("install.zig");
const oci = @import("oci.zig");
const process = @import("process.zig");
const project = @import("project.zig");
const recipe = @import("recipe.zig");
const fail = Context.fail;
const note = Context.note;

pub const Project = struct {
    /// The project's zigsaw.json, absolute.
    file: []const u8,
    members: []const Member,
    /// Indexes into `members`, each after those it uses.
    order: []const usize,
    /// For each member, the members it uses.
    uses: []const []const usize,
    /// What it lists in `"run"`, unchecked: the apps `zigsaw up` starts
    /// (see `runList`).
    run: ?std.json.Value = null,
};

pub const Member = struct {
    /// Its recipe, absolute.
    path: []const u8,
    recipe: recipe.Recipe,
};

/// The images a project built, by app id (lowercased, as ids compare).
pub const Built = struct {
    map: std.StringArrayHashMapUnmanaged(Image) = .empty,

    pub const Image = struct {
        id: []const u8,
        version: []const u8,
        digest: []const u8,
    };

    pub fn put(b: *Built, arena: Allocator, image: Image) !void {
        try b.map.put(arena, try std.ascii.allocLowerString(arena, image.id), image);
    }

    pub fn get(b: *const Built, arena: Allocator, id: []const u8) !?Image {
        return b.map.get(try std.ascii.allocLowerString(arena, id));
    }
};

/// The project at `path`, if it's a project's zigsaw.json: one with
/// `"apps"`. Null for anything else, which is built as a recipe.
pub fn read(ctx: *Context, path: []const u8) !?Project {
    const arena = ctx.arena;
    const bytes = Io.Dir.cwd().readFileAlloc(ctx.io, path, arena, .limited(1 << 20)) catch |err|
        return fail("reading {s}: {t}", .{ path, err });
    const entries = try parseList(arena, path, bytes) orelse return null;
    const file = try Io.Dir.cwd().realPathFileAlloc(ctx.io, path, arena);
    var p = try load(ctx, file, try memberPaths(ctx, file, entries));
    p.run = (std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch unreachable).object.get("run");
    return p;
}

/// The `"apps"` of a project's zigsaw.json, unchecked; null if it has none,
/// as a recipe hasn't. JSON that doesn't parse is left to the recipe's
/// parser, which says where it's wrong.
fn appsOf(arena: Allocator, bytes: []const u8) ?std.json.Value {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return null;
    if (value != .object) return null;
    return value.object.get("apps");
}

/// What a project's zigsaw.json lists in `"apps"`, checked: none, for one
/// that lists only apps to `"run"`; null if it has neither, as a recipe
/// hasn't (see `appsOf`).
fn parseList(arena: Allocator, file: []const u8, bytes: []const u8) !?[]const []const u8 {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return null;
    if (value != .object) return null;
    if (value.object.get("apps") == null and value.object.get("run") == null) return null;
    for (value.object.keys()) |key| if (!std.mem.eql(u8, key, "apps") and !std.mem.eql(u8, key, "run"))
        return fail("{s}: a project's zigsaw.json lists its \"apps\" and the apps to \"run\", and nothing else; \"{s}\" belongs in an app's recipe", .{ file, key });
    const apps = value.object.get("apps") orelse return &.{};
    if (apps != .array) return fail("{s}: \"apps\" is a list of the project's recipes, by path", .{file});
    if (apps.array.items.len == 0) return fail("{s}: \"apps\" lists no apps", .{file});
    const entries = try arena.alloc([]const u8, apps.array.items.len);
    for (entries, apps.array.items) |*e, item| {
        if (item != .string) return fail("{s}: \"apps\" is a list of the project's recipes, by path", .{file});
        if (!oci.isSafeRelPath(item.string))
            return fail("{s}: app \"{s}\" must be a path inside the project's directory", .{ file, item.string });
        e.* = item.string;
    }
    return entries;
}

/// The recipes a project lists, absolute: a directory's is its zigsaw.json.
fn memberPaths(ctx: *Context, file: []const u8, entries: []const []const u8) ![]const []const u8 {
    const io = ctx.io;
    const arena = ctx.arena;
    const dir = std.fs.path.dirname(file).?;
    const paths = try arena.alloc([]const u8, entries.len);
    for (paths, entries, 0..) |*p, entry, i| {
        var full = try std.fs.path.join(arena, &.{ dir, entry });
        const stat = Io.Dir.cwd().statFile(io, full, .{}) catch
            return fail("{s}: app \"{s}\": {s} isn't there", .{ file, entry, full });
        if (stat.kind == .directory) {
            full = try std.fs.path.join(arena, &.{ full, project.manifest_name });
            if (!try Store.exists(io, full))
                return fail("{s}: app \"{s}\" is a directory with no {s}", .{ file, entry, project.manifest_name });
        }
        p.* = try Io.Dir.cwd().realPathFileAlloc(io, full, arena);
        for (paths[0..i]) |earlier| if (std.ascii.eqlIgnoreCase(earlier, p.*))
            return fail("{s}: lists {s} twice", .{ file, p.* });
    }
    return paths;
}

fn load(ctx: *Context, file: []const u8, paths: []const []const u8) !Project {
    const arena = ctx.arena;
    const members = try arena.alloc(Member, paths.len);
    for (members, paths, 0..) |*m, path, i| {
        const bytes = Io.Dir.cwd().readFileAlloc(ctx.io, path, arena, .limited(1 << 20)) catch |err|
            return fail("reading {s}: {t}", .{ path, err });
        if (appsOf(arena, bytes) != null)
            return fail("{s}: {s} is a project's list of apps too; a project's apps are recipes", .{ file, path });
        m.* = .{ .path = path, .recipe = try recipe.parse(arena, path, bytes) };
        for (members[0..i]) |earlier| if (std.ascii.eqlIgnoreCase(earlier.recipe.id, m.recipe.id))
            return fail("{s}: {s} and {s} are both {s}", .{ file, earlier.path, path, m.recipe.id });
    }
    const recipes = try arena.alloc(recipe.Recipe, members.len);
    for (recipes, members) |*r, m| r.* = m.recipe;
    const uses = try dependencies(arena, recipes, paths);
    return .{ .file = file, .members = members, .order = try order(arena, file, recipes, uses), .uses = uses };
}

/// One of the images a recipe names: an SDK, a runtime, or a module's
/// source (whose alias is then the module's name).
pub const Reference = struct {
    kind: deps.Kind,
    alias: []const u8,
    text: []const u8,
};

fn references(arena: Allocator, r: recipe.Recipe) ![]const Reference {
    var out: std.ArrayList(Reference) = .empty;
    for (r.sdk.map.keys(), r.sdk.map.values()) |alias, text| try out.append(arena, .{ .kind = .sdk, .alias = alias, .text = text });
    for (r.runtimes.map.keys(), r.runtimes.map.values()) |alias, text| try out.append(arena, .{ .kind = .runtime, .alias = alias, .text = text });
    for (r.modules) |m| for (m.sources) |s| if (s.image) |text|
        try out.append(arena, .{ .kind = .source, .alias = m.name, .text = text });
    return out.items;
}

/// Whether a reference can name another app of the project: an app id,
/// with a tag or without, unpinned.
pub fn isSiblingRef(text: []const u8) bool {
    if (std.mem.indexOfAny(u8, text, "/@") != null) return false;
    return oci.isValidId(appId(text));
}

/// A reference's app id, without its tag and digest.
fn appId(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfAny(u8, text, ":@") orelse text.len];
}

/// Whether the recipe names any image as another app of a project would.
pub fn namesSiblings(r: recipe.Recipe) bool {
    for (r.sdk.map.values()) |text| if (isSiblingRef(text)) return true;
    for (r.runtimes.map.values()) |text| if (isSiblingRef(text)) return true;
    for (r.modules) |m| for (m.sources) |s| if (s.image) |text| if (isSiblingRef(text)) return true;
    return false;
}

/// For each recipe, the others it names unpinned. `paths` name them in
/// messages.
fn dependencies(arena: Allocator, recipes: []const recipe.Recipe, paths: []const []const u8) ![]const []const usize {
    const uses = try arena.alloc([]const usize, recipes.len);
    for (recipes, uses, paths) |r, *u, path| {
        var list: std.ArrayList(usize) = .empty;
        for (try references(arena, r)) |ref| {
            if (!isSiblingRef(ref.text)) continue;
            const id = appId(ref.text);
            if (std.ascii.eqlIgnoreCase(id, r.id))
                return fail("{s}: {t} {s} names the app itself, unpinned; only a pin can name an earlier build of it", .{ path, ref.kind, ref.alias });
            for (recipes, 0..) |other, j| if (std.ascii.eqlIgnoreCase(id, other.id)) {
                if (std.mem.indexOfScalar(u8, ref.text, ':')) |colon| if (!std.mem.eql(u8, ref.text[colon + 1 ..], other.version))
                    return fail("{s}: {t} {s} names {s}, but its project's {s} is version {s}", .{ path, ref.kind, ref.alias, ref.text, other.id, other.version });
                if (std.mem.indexOfScalar(usize, list.items, j) == null) try list.append(arena, j);
            };
        }
        u.* = list.items;
    }
    return uses;
}

/// The recipes in an order where each follows those it uses; of those that
/// could go next, the one listed first.
fn order(arena: Allocator, file: []const u8, recipes: []const recipe.Recipe, uses: []const []const usize) ![]const usize {
    const done = try arena.alloc(bool, recipes.len);
    @memset(done, false);
    var out: std.ArrayList(usize) = .empty;
    while (out.items.len < recipes.len) {
        const next = for (uses, 0..) |u, i| {
            if (done[i]) continue;
            if (for (u) |j| {
                if (!done[j]) break false;
            } else true) break i;
        } else {
            var left: std.ArrayList([]const u8) = .empty;
            for (recipes, done) |r, d| if (!d) try left.append(arena, r.id);
            return fail("{s}: its apps use each other in a circle, so none of these can be built first: {s}", .{ file, try oci.joinAnd(arena, left.items) });
        };
        done[next] = true;
        try out.append(arena, next);
    }
    return out.items;
}

pub const Pinned = struct {
    recipe: recipe.Recipe,
    /// "<kind> <alias> <reference>" for each reference pinned, for the
    /// build's inputs: the recipe's bytes don't say which image it got.
    pins: []const []const u8,
};

/// The recipe with each reference to an app in `built` pinned to that image,
/// as "<id>:<version>@<digest>". A reference with a tag must name the version
/// built. One pinned already is left alone, with a warning if it isn't what
/// was built.
pub fn pin(arena: Allocator, r: recipe.Recipe, built: *const Built, recipe_path: []const u8) !Pinned {
    var out = r;
    var pins: std.ArrayList([]const u8) = .empty;
    out.sdk = try pinMap(arena, r.sdk, .sdk, built, recipe_path, &pins);
    out.runtimes = try pinMap(arena, r.runtimes, .runtime, built, recipe_path, &pins);
    const modules = try arena.dupe(recipe.Module, r.modules);
    for (modules) |*m| {
        if (for (m.sources) |s| {
            if (s.image != null) break true;
        } else false) {
            const sources = try arena.dupe(recipe.Source, m.sources);
            for (sources) |*s| if (s.image) |text| {
                s.image = try pinOne(arena, .source, m.name, text, built, recipe_path, &pins);
            };
            m.sources = sources;
        }
    }
    out.modules = modules;
    return .{ .recipe = out, .pins = pins.items };
}

fn pinMap(arena: Allocator, refs: std.json.ArrayHashMap([]const u8), kind: deps.Kind, built: *const Built, recipe_path: []const u8, pins: *std.ArrayList([]const u8)) !std.json.ArrayHashMap([]const u8) {
    var out: std.json.ArrayHashMap([]const u8) = .{};
    for (refs.map.keys(), refs.map.values()) |alias, text|
        try out.map.put(arena, alias, try pinOne(arena, kind, alias, text, built, recipe_path, pins));
    return out;
}

fn pinOne(arena: Allocator, kind: deps.Kind, alias: []const u8, text: []const u8, built: *const Built, recipe_path: []const u8, pins: *std.ArrayList([]const u8)) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '/') != null) return text;
    const id = appId(text);
    const image = try built.get(arena, id) orelse return text;
    if (std.mem.indexOfScalar(u8, text, '@')) |at| {
        if (!std.mem.eql(u8, text[at + 1 ..], image.digest))
            note("warning: {s}: {t} {s} is pinned to {s}, not to the {s} its project built ({s}); the pin wins", .{
                recipe_path, kind, alias, oci.shortDigest(text[at + 1 ..]), image.id, oci.shortDigest(image.digest),
            });
        return text;
    }
    if (std.mem.indexOfScalar(u8, text, ':')) |colon| if (!std.mem.eql(u8, text[colon + 1 ..], image.version))
        return fail("{s}: {t} {s} names {s}, but its project's {s} is version {s}", .{ recipe_path, kind, alias, text, image.id, image.version });
    const pinned = try std.fmt.allocPrint(arena, "{s}:{s}@{s}", .{ image.id, image.version, image.digest });
    try pins.append(arena, try std.fmt.allocPrint(arena, "{t} {s} {s}", .{ kind, alias, pinned }));
    return pinned;
}

/// Builds and installs the project's apps, each after those it uses. What
/// isn't pinned and isn't one of them fails first, before anything builds.
pub fn buildAll(ctx: *Context, p: Project, opts: builder.Options) !void {
    const arena = ctx.arena;
    if (p.members.len == 0) {
        note("{s} lists no \"apps\" to build, only apps to \"run\"", .{p.file});
        return;
    }
    if (opts.clean_from) |module|
        return fail("--clean={s} starts a module of one app afresh; give that app's directory or recipe, as in: zigsaw build <dir> --clean={s}", .{ module, module });
    for (p.members) |m| for (try references(arena, m.recipe)) |ref| {
        if (std.mem.indexOfScalar(u8, ref.text, '@') != null) continue;
        if (isSiblingRef(ref.text)) if (for (p.members) |other| {
            if (std.ascii.eqlIgnoreCase(appId(ref.text), other.recipe.id)) break true;
        } else false) continue;
        try deps.checkPinned(ctx, m.path, ref.kind, ref.alias, ref.text);
    };
    if (p.members.len > 1) {
        const ids = try arena.alloc([]const u8, p.order.len);
        for (ids, p.order) |*id, i| id.* = p.members[i].recipe.id;
        note("building {d} apps: {s}", .{ ids.len, try std.mem.join(arena, ", ", ids) });
    }
    var built: Built = .{};
    for (p.order) |i| {
        var member_opts = opts;
        member_opts.siblings = &built;
        const image = try builder.build(ctx, p.members[i].path, member_opts);
        try install.install(ctx, image);
        try built.put(arena, .{ .id = image.config.id, .version = image.config.version, .digest = image.manifest_digest });
    }
}

/// For an app built alone whose recipe (`r`, at `source`, absolute) names
/// others unpinned: the first project above it that lists it builds the
/// apps it uses, as a build of the project would, without installing them.
/// Null if no project lists it. It builds with `builder.build`, which calls
/// it, so its errors are named: Zig can't infer them round that loop.
pub fn buildFor(ctx: *Context, source: []const u8, r: recipe.Recipe, limits: process.Limits, sandbox: container.Sandbox) anyerror!?*const Built {
    const arena = ctx.arena;
    const p = try findFor(ctx, source) orelse return null;
    const self = for (p.members, 0..) |m, i| {
        if (std.ascii.eqlIgnoreCase(m.path, source)) break i;
    } else unreachable;
    // What it uses, and what those use.
    const needed = try arena.alloc(bool, p.members.len);
    @memset(needed, false);
    var todo: std.ArrayList(usize) = .empty;
    try todo.appendSlice(arena, p.uses[self]);
    while (todo.pop()) |i| {
        if (needed[i]) continue;
        needed[i] = true;
        try todo.appendSlice(arena, p.uses[i]);
    }
    const built = try arena.create(Built);
    built.* = .{};
    for (p.order) |i| {
        if (!needed[i]) continue;
        const m = p.members[i];
        note("{s} uses {s}, which its project builds first; it isn't installed", .{ r.id, m.recipe.id });
        const image = try builder.build(ctx, m.path, .{ .limits = limits, .sandbox = sandbox, .siblings = built });
        try built.put(arena, .{ .id = image.config.id, .version = image.config.version, .digest = image.manifest_digest });
    }
    return built;
}

/// The first project at or above the recipe's directory that lists it.
fn findFor(ctx: *Context, source: []const u8) !?Project {
    const io = ctx.io;
    const arena = ctx.arena;
    var dir = std.fs.path.dirname(source);
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        const candidate = try std.fs.path.join(arena, &.{ d, project.manifest_name });
        if (std.ascii.eqlIgnoreCase(candidate, source) or !try Store.exists(io, candidate)) continue;
        const bytes = Io.Dir.cwd().readFileAlloc(io, candidate, arena, .limited(1 << 20)) catch continue;
        // Another project's troubles are its own, so this looks quietly; one
        // that lists the recipe is read as a build of it would.
        const apps = appsOf(arena, bytes) orelse continue;
        if (apps != .array) continue;
        const listed = for (apps.array.items) |item| {
            if (item != .string or !oci.isSafeRelPath(item.string)) continue;
            if (try quietPath(ctx, d, item.string)) |p| if (std.ascii.eqlIgnoreCase(p, source)) break true;
        } else false;
        if (!listed) continue;
        const file = try Io.Dir.cwd().realPathFileAlloc(io, candidate, arena);
        return try load(ctx, file, try memberPaths(ctx, file, (try parseList(arena, file, bytes)).?));
    }
    return null;
}

/// The recipe an entry of a project in `dir` names, as `memberPaths` finds
/// it, or null, saying nothing.
fn quietPath(ctx: *Context, dir: []const u8, entry: []const u8) !?[]const u8 {
    var full = try std.fs.path.join(ctx.arena, &.{ dir, entry });
    const stat = Io.Dir.cwd().statFile(ctx.io, full, .{}) catch return null;
    if (stat.kind == .directory) full = try std.fs.path.join(ctx.arena, &.{ full, project.manifest_name });
    return Io.Dir.cwd().realPathFileAlloc(ctx.io, full, ctx.arena) catch null;
}

// ---------------------------------------------------------------------------
// The apps to run

/// An app `zigsaw up` starts, as the project's `"run"` lists it: an app's
/// id, or an object with its `"app"`, its `"args"`, and `zigsaw run`'s
/// options by their names (`"env": ["A=B"]`, `"sandbox": "soft"`).
pub const RunEntry = struct {
    /// As listed: an app's id, or a pinned reference to one.
    app: []const u8,
    /// The app's id.
    id: []const u8,
    /// The project's app it is, by its index in `members`.
    member: ?usize = null,
    /// For an app from a registry, the pinned reference to pull it by.
    pinned: ?[]const u8 = null,
    /// Its run options, as `zigsaw run` takes them: "--env=A=B".
    options: []const []const u8 = &.{},
    /// The app's arguments.
    args: []const []const u8 = &.{},
    /// What its options and arguments hash to: a run started from it
    /// records it, and `up` starts the run again when it changes.
    key: []const u8,
};

/// The run options an entry may give, by their names: each takes a string
/// or a list of them, but `ephemeral`, which takes true.
pub const run_options = [_][]const u8{
    "sandbox",  "filesystem", "nofilesystem", "share",     "unshare",     "allow-host", "noallow-host",
    "device",   "nodevice",   "env",          "extension", "noextension", "port",       "volume",
    "novolume", "memory",     "cpus",         "ephemeral", "command",
};

/// The project's `"run"`, checked as far as it can be without the store:
/// that it's a list of apps, each the project's or pinned, listed once, with
/// options `zigsaw run` has (whose values `up` checks as `run` would).
pub fn runList(arena: Allocator, p: Project) ![]const RunEntry {
    const value = p.run orelse
        return fail("{s} lists no apps to \"run\": `zigsaw up` starts those, each an app's id or an object with its \"app\" and run options", .{p.file});
    if (value != .array) return fail("{s}: \"run\" is a list of apps, each an app's id or an object with its \"app\" and run options", .{p.file});
    if (value.array.items.len == 0) return fail("{s}: \"run\" lists no apps", .{p.file});
    const out = try arena.alloc(RunEntry, value.array.items.len);
    for (out, value.array.items, 0..) |*e, item, i| {
        e.* = try parseEntry(arena, p, item);
        for (out[0..i]) |earlier| if (std.ascii.eqlIgnoreCase(earlier.id, e.id))
            return fail("{s}: \"run\" lists {s} twice", .{ p.file, e.id });
    }
    return out;
}

fn parseEntry(arena: Allocator, p: Project, item: std.json.Value) !RunEntry {
    const file = p.file;
    var options: std.ArrayList([]const u8) = .empty;
    var args: std.ArrayList([]const u8) = .empty;
    const app = switch (item) {
        .string => |s| s,
        .object => |o| app: {
            const app_value = o.get("app") orelse
                return fail("{s}: an entry of \"run\" names its app as \"app\"", .{file});
            if (app_value != .string) return fail("{s}: an entry of \"run\" names its app as \"app\", a string", .{file});
            const app = app_value.string;
            for (o.keys(), o.values()) |key, v| {
                if (std.mem.eql(u8, key, "app")) continue;
                if (std.mem.eql(u8, key, "args")) {
                    try appendStrings(arena, &args, file, app, key, v);
                    continue;
                }
                const known = for (run_options) |name| {
                    if (std.mem.eql(u8, name, key)) break true;
                } else false;
                if (!known) return fail("{s}: run {s}: \"{s}\" isn't one of `zigsaw run`'s options, which an entry may give as \"args\" and {s}", .{
                    file, app, key, try oci.joinAnd(arena, &run_options),
                });
                if (std.mem.eql(u8, key, "ephemeral")) {
                    if (v != .bool) return fail("{s}: run {s}: \"ephemeral\" is true or false", .{ file, app });
                    if (v.bool) try options.append(arena, "--ephemeral");
                    continue;
                }
                var values: std.ArrayList([]const u8) = .empty;
                try appendStrings(arena, &values, file, app, key, v);
                for (values.items) |s| try options.append(arena, try std.fmt.allocPrint(arena, "--{s}={s}", .{ key, s }));
            }
            break :app app;
        },
        else => return fail("{s}: an entry of \"run\" is an app's id, or an object with its \"app\" and run options", .{file}),
    };
    var e: RunEntry = .{ .app = app, .id = appId(app), .options = options.items, .args = args.items, .key = undefined };
    if (std.mem.indexOfScalar(u8, app, '/') != null or !oci.isValidId(e.id))
        return fail("{s}: run \"{s}\": an app is named by its id, as org.example.web, and one from a registry pinned, as <id>:<version>@sha256:<digest>", .{ file, app });
    for (p.members, 0..) |m, i| if (std.ascii.eqlIgnoreCase(m.recipe.id, e.id)) {
        if (!std.mem.eql(u8, app, e.id))
            return fail("{s}: run {s}: the project's own apps are named by their id alone: {s}", .{ file, app, m.recipe.id });
        e.member = i;
        e.id = m.recipe.id;
    };
    if (e.member == null and !std.mem.eql(u8, app, e.id)) {
        if (std.mem.indexOfScalar(u8, app, '@') == null)
            return fail("{s}: run {s}: an app from a registry is pinned to its image's digest, as recipes pin theirs: \"{s}@sha256:...\"", .{ file, app, app });
        e.pinned = app;
    }
    e.key = try entryKey(arena, e);
    return e;
}

fn appendStrings(arena: Allocator, out: *std.ArrayList([]const u8), file: []const u8, app: []const u8, key: []const u8, v: std.json.Value) !void {
    switch (v) {
        .string => |s| try out.append(arena, s),
        .array => |a| for (a.items) |item| {
            if (item != .string) return fail("{s}: run {s}: \"{s}\" is a string or a list of strings", .{ file, app, key });
            try out.append(arena, item.string);
        },
        else => return fail("{s}: run {s}: \"{s}\" is a string or a list of strings", .{ file, app, key }),
    }
}

/// 16 hex digits of a hash of what the entry starts.
fn entryKey(arena: Allocator, e: RunEntry) ![]const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(e.app);
    for (e.options) |o| {
        h.update("\x00");
        h.update(o);
    }
    h.update("\x00--");
    for (e.args) |a| {
        h.update("\x00");
        h.update(a);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.allocPrint(arena, "{x}", .{digest[0..8]});
}

fn testRecipe(arena: Allocator, json: []const u8) !recipe.Recipe {
    return recipe.parse(arena, "t.json", json);
}

test "a project's zigsaw.json lists its apps, and nothing else" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const list = (try parseList(arena, "p", "{ \"apps\": [\"engine\", \"web/zigsaw.json\", \"tools\\\\cli\"] }")).?;
    try std.testing.expectEqual(3, list.len);
    try std.testing.expectEqualStrings("tools\\cli", list[2]);
    // A recipe, or what isn't JSON at all, is no project.
    try std.testing.expectEqual(null, try parseList(arena, "p", "{ \"id\": \"x\", \"modules\": [] }"));
    try std.testing.expectEqual(null, try parseList(arena, "p", "{ \"id\": "));
    try std.testing.expectEqual(null, try parseList(arena, "p", "[1]"));
    try std.testing.expectError(error.Failed, parseList(arena, "p", "{ \"apps\": [\"a\"], \"id\": \"x\" }"));
    try std.testing.expectError(error.Failed, parseList(arena, "p", "{ \"apps\": [] }"));
    try std.testing.expectError(error.Failed, parseList(arena, "p", "{ \"apps\": \"a\" }"));
    try std.testing.expectError(error.Failed, parseList(arena, "p", "{ \"apps\": [1] }"));
    try std.testing.expectError(error.Failed, parseList(arena, "p", "{ \"apps\": [\"../a\"] }"));
    try std.testing.expectError(error.Failed, parseList(arena, "p", "{ \"apps\": [\"C:\\\\a\"] }"));
    try std.testing.expectError(error.Failed, parseList(arena, "p", "{ \"apps\": [\"/a\"] }"));
}

test "an unpinned app id can name another app of the project" {
    try std.testing.expect(isSiblingRef("org.example.engine"));
    try std.testing.expect(isSiblingRef("org.example.engine:1.2"));
    try std.testing.expect(!isSiblingRef("org.example.engine@sha256:0000000000000000000000000000000000000000000000000000000000000000"));
    try std.testing.expect(!isSiblingRef("org.example.engine:1.2@sha256:0000000000000000000000000000000000000000000000000000000000000000"));
    try std.testing.expect(!isSiblingRef("ghcr.io/x/org.example.engine"));
    try std.testing.expect(!isSiblingRef("not an id"));
}

const digest_a = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const digest_b = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

test "a project's apps are built each after those it uses, else in the order listed" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const recipes = [_]recipe.Recipe{
        // web uses engine as a runtime and tool as a module's source.
        try testRecipe(arena,
            \\{ "id": "web", "version": "1", "command": "w.exe", "runtimes": { "engine": "Engine" },
            \\  "modules": [{ "name": "m", "sources": [{ "image": "tool:2" }] }] }
        ),
        try testRecipe(arena,
            \\{ "id": "cli", "version": "1", "command": "c.exe", "sdk": { "tool": "tool", "zig": "ghcr.io/x/zig", "pinned": "web@
        ++ digest_a ++
            \\" }, "modules": [{ "name": "m", "build": ["x"] }] }
        ),
        try testRecipe(arena,
            \\{ "id": "engine", "version": "1", "command": "e.exe", "modules": [{ "name": "m", "build": ["x"] }] }
        ),
        try testRecipe(arena,
            \\{ "id": "tool", "version": "2", "command": "t.exe", "sdk": { "e": "engine" }, "modules": [{ "name": "m", "build": ["x"] }] }
        ),
    };
    const paths = [_][]const u8{ "web.json", "cli.json", "engine.json", "tool.json" };
    const uses = try dependencies(arena, &recipes, &paths);
    // Ids compare ignoring case, and neither a pin nor a full reference makes
    // an app wait.
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, uses[0]);
    try std.testing.expectEqualSlices(usize, &.{3}, uses[1]);
    try std.testing.expectEqualSlices(usize, &.{}, uses[2]);
    try std.testing.expectEqualSlices(usize, &.{2}, uses[3]);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3, 0, 1 }, try order(arena, "p", &recipes, uses));

    // Two that use each other.
    const circle = [_]recipe.Recipe{
        try testRecipe(arena,
            \\{ "id": "a", "version": "1", "command": "a.exe", "sdk": { "b": "b" }, "modules": [{ "name": "m", "build": ["x"] }] }
        ),
        try testRecipe(arena,
            \\{ "id": "b", "version": "1", "command": "b.exe", "sdk": { "a": "a" }, "modules": [{ "name": "m", "build": ["x"] }] }
        ),
        try testRecipe(arena,
            \\{ "id": "c", "version": "1", "command": "c.exe", "modules": [{ "name": "m", "build": ["x"] }] }
        ),
    };
    const circle_uses = try dependencies(arena, &circle, &.{ "a", "b", "c" });
    try std.testing.expectError(error.Failed, order(arena, "p", &circle, circle_uses));

    // One that names itself, unpinned.
    const itself = [_]recipe.Recipe{try testRecipe(arena,
        \\{ "id": "a", "version": "1", "command": "a.exe", "modules": [{ "name": "m", "sources": [{ "image": "a" }] }] }
    )};
    try std.testing.expectError(error.Failed, dependencies(arena, &itself, &.{"a"}));

    // A tag that isn't the other's version fails before anything builds.
    const tagged = [_]recipe.Recipe{
        try testRecipe(arena,
            \\{ "id": "a", "version": "1", "command": "a.exe", "sdk": { "b": "b:2" }, "modules": [{ "name": "m", "build": ["x"] }] }
        ),
        try testRecipe(arena,
            \\{ "id": "b", "version": "3", "command": "b.exe", "modules": [{ "name": "m", "build": ["x"] }] }
        ),
    };
    try std.testing.expectError(error.Failed, dependencies(arena, &tagged, &.{ "a", "b" }));
}

test "pinning gives what the project built, by id, version and digest" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r = try testRecipe(arena,
        \\{ "id": "web", "version": "1", "command": "w.exe",
        \\  "sdk": { "tool": "TOOL", "zig": "ghcr.io/x/zig", "other": "org.other" },
        \\  "runtimes": { "engine": "engine:3" },
        \\  "modules": [
        \\    { "name": "a", "build": ["x"] },
        \\    { "name": "b", "sources": [{ "image": "engine", "dest": "e" }, { "url": "https://x/y.zip", "sha256": "0000000000000000000000000000000000000000000000000000000000000000" }] }
        \\  ] }
    );
    try std.testing.expect(namesSiblings(r));
    var built: Built = .{};
    try built.put(arena, .{ .id = "engine", .version = "3", .digest = digest_a });
    try built.put(arena, .{ .id = "tool", .version = "2", .digest = digest_b });

    const p = try pin(arena, r, &built, "web.json");
    try std.testing.expectEqualStrings("tool:2@" ++ digest_b, p.recipe.sdk.map.get("tool").?);
    try std.testing.expectEqualStrings("ghcr.io/x/zig", p.recipe.sdk.map.get("zig").?);
    try std.testing.expectEqualStrings("org.other", p.recipe.sdk.map.get("other").?);
    try std.testing.expectEqualStrings("engine:3@" ++ digest_a, p.recipe.runtimes.map.get("engine").?);
    try std.testing.expectEqualStrings("engine:3@" ++ digest_a, p.recipe.modules[1].sources[0].image.?);
    try std.testing.expectEqualStrings("e", p.recipe.modules[1].sources[0].dest.?);
    try std.testing.expectEqual(null, p.recipe.modules[1].sources[1].image);
    try std.testing.expectEqual(3, p.pins.len);
    try std.testing.expectEqualStrings("sdk tool tool:2@" ++ digest_b, p.pins[0]);
    try std.testing.expectEqualStrings("source b engine:3@" ++ digest_a, p.pins[2]);
    // org.other, which the project didn't build, is still unpinned.
    try std.testing.expect(namesSiblings(p.recipe));
    // The recipe it was given is as it was.
    try std.testing.expectEqualStrings("TOOL", r.sdk.map.get("tool").?);
    try std.testing.expectEqualStrings("engine", r.modules[1].sources[0].image.?);

    // A tag that isn't the version built fails.
    const tagged = try testRecipe(arena,
        \\{ "id": "web", "version": "1", "command": "w.exe", "runtimes": { "engine": "engine:2" }, "modules": [{ "name": "a", "build": ["x"] }] }
    );
    try std.testing.expectError(error.Failed, pin(arena, tagged, &built, "web.json"));

    // A pin stays as it is, and pins nothing for the inputs.
    const pinned = try testRecipe(arena,
        \\{ "id": "web", "version": "1", "command": "w.exe", "runtimes": { "engine": "engine@
    ++ digest_a ++
        \\" }, "modules": [{ "name": "a", "build": ["x"] }] }
    );
    const kept = try pin(arena, pinned, &built, "web.json");
    try std.testing.expectEqualStrings("engine@" ++ digest_a, kept.recipe.runtimes.map.get("engine").?);
    try std.testing.expectEqual(0, kept.pins.len);
}

fn testProject(arena: Allocator, members: []const Member, run: []const u8) !Project {
    return .{
        .file = "p.json",
        .members = members,
        .order = &.{},
        .uses = &.{},
        .run = try std.json.parseFromSliceLeaky(std.json.Value, arena, run, .{}),
    };
}

test "the apps a project runs" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const web = try testRecipe(arena,
        \\{ "id": "org.example.web", "version": "1", "command": "w.exe", "modules": [{ "name": "a", "build": ["x"] }] }
    );
    const members = [_]Member{.{ .path = "web.json", .recipe = web }};
    const list = try runList(arena, try testProject(arena, &members,
        \\[ "ORG.example.web",
        \\  { "app": "org.db:18@sha256:abc", "env": ["A=B", "C=D"], "ephemeral": true, "sandbox": "soft", "args": ["--dev"] },
        \\  { "app": "org.cache", "ephemeral": false } ]
    ));
    try std.testing.expectEqual(3, list.len);
    try std.testing.expectEqual(0, list[0].member.?);
    try std.testing.expectEqualStrings("org.example.web", list[0].id);
    try std.testing.expectEqual(null, list[0].pinned);
    try std.testing.expectEqualStrings("org.db", list[1].id);
    try std.testing.expectEqualStrings("org.db:18@sha256:abc", list[1].pinned.?);
    try std.testing.expectEqual(4, list[1].options.len);
    try std.testing.expectEqualStrings("--env=A=B", list[1].options[0]);
    try std.testing.expectEqualStrings("--env=C=D", list[1].options[1]);
    try std.testing.expectEqualStrings("--ephemeral", list[1].options[2]);
    try std.testing.expectEqualStrings("--sandbox=soft", list[1].options[3]);
    try std.testing.expectEqualStrings("--dev", list[1].args[0]);
    // An app installed from elsewhere, named by its id alone.
    try std.testing.expectEqual(null, list[2].member);
    try std.testing.expectEqual(null, list[2].pinned);
    try std.testing.expectEqual(0, list[2].options.len);
    try std.testing.expectEqual(16, list[0].key.len);

    // What an entry starts decides its key.
    const again = try runList(arena, try testProject(arena, &members,
        \\[ { "app": "org.db:18@sha256:abc", "env": ["A=B", "C=D"], "ephemeral": true, "sandbox": "soft", "args": ["--dev"] },
        \\  { "app": "org.example.web", "env": "A=B" } ]
    ));
    try std.testing.expectEqualStrings(list[1].key, again[0].key);
    try std.testing.expect(!std.mem.eql(u8, list[0].key, again[1].key));

    const refused = [_][]const u8{
        \\{ "app": "org.example.web" }
        ,
        \\[]
        ,
        \\[ 3 ]
        ,
        \\[ "org.example.web", "org.example.web" ]
        ,
        \\[ { "app": "org.example.web", "volumes": ["a:."] } ]
        ,
        \\[ { "app": "org.example.web", "env": [1] } ]
        ,
        \\[ { "app": "org.example.web", "ephemeral": "yes" } ]
        ,
        \\[ { "env": ["A=B"] } ]
        ,
        \\[ "org.example.web:1" ]
        ,
        \\[ "org.db:18" ]
        ,
        \\[ "ghcr.io/owner/db@sha256:abc" ]
        ,
    };
    for (refused) |json| try std.testing.expectError(error.Failed, runList(arena, try testProject(arena, &members, json)));
    // No "run" at all.
    try std.testing.expectError(error.Failed, runList(arena, .{ .file = "p.json", .members = &members, .order = &.{}, .uses = &.{} }));
}

test "a project may list only apps to run" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try std.testing.expectEqual(0, (try parseList(arena, "p", "{ \"run\": [\"org.db\"] }")).?.len);
    try std.testing.expectEqual(1, (try parseList(arena, "p", "{ \"apps\": [\"a\"], \"run\": [\"org.db\"] }")).?.len);
    try std.testing.expectError(error.Failed, parseList(arena, "p", "{ \"run\": [], \"id\": \"x\" }"));
}
