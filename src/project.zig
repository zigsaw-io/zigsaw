//! A project's own files as a recipe's source: a `path` that names a
//! directory, as "." does in the zigsaw.json at a project's root, which
//! `zigsaw build` builds when given the directory, or nothing, as make builds
//! a Makefile.
//!
//! The build gets the files git would commit: those the project's
//! `.gitignore` files don't ignore (see gitignore.zig), without `.git` and
//! without empty directories, so a checkout with nothing uncommitted gives the
//! same files as a fresh clone. A source's `skip` leaves out more.
//!
//! A working tree isn't pinned as a download is, so its files are hashed as
//! the build takes them, as a vendor step's are: as a layer-format tar, which
//! depends only on their paths and contents. The hash is one of the build's
//! inputs, so an unchanged tree reuses the earlier build, and is in the
//! image's record of the build, as a local file's is. The files are read
//! from the project's directory, which a build never writes to.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const Tree = @import("Tree.zig");
const gitignore = @import("gitignore.zig");
const recipe = @import("recipe.zig");
const fail = Context.fail;
const note = Context.note;

/// The recipe `zigsaw build` builds in a project's directory.
pub const manifest_name = "zigsaw.json";

/// A directory source's files, as the build took them.
pub const Snapshot = struct {
    /// The directory, absolute.
    dir: []const u8,
    /// Its files, by path from the directory, read from there.
    tree: Tree,
    /// Of the files, as a layer-format tar (see Tree.contentHash).
    hash: []const u8,
    files: usize,
};

/// The snapshots of a recipe's directory sources, taken once per build, so
/// that the build's inputs, its record and what it builds are the same
/// files.
pub const Snapshots = struct {
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        module: []const u8,
        /// Of the source in the module's.
        index: usize,
        snapshot: Snapshot,
    };

    /// Takes a snapshot of each source of the recipe at `recipe_path` whose
    /// `path` is a directory.
    pub fn take(ctx: *Context, r: recipe.Recipe, recipe_path: []const u8) !Snapshots {
        const io = ctx.io;
        const arena = ctx.arena;
        var s: Snapshots = .{};
        const base_dir = std.fs.path.dirname(recipe_path) orelse ".";
        for (r.modules) |m| for (m.sources, 0..) |src, i| {
            const p = src.path orelse continue;
            const full = if (std.fs.path.isAbsolute(p)) p else try std.fs.path.join(arena, &.{ base_dir, p });
            // A path that isn't there fails the build as a missing file.
            const dir = Io.Dir.cwd().realPathFileAlloc(io, full, arena) catch continue;
            const stat = Io.Dir.cwd().statFile(io, dir, .{}) catch continue;
            if (stat.kind != .directory) {
                if (src.skip.len > 0) return fail("module {s}: {s} is a file; \"skip\" is for a directory", .{ m.name, p });
                continue;
            }
            if (src.sha256 != null or src.type != null or src.strip != 0)
                return fail("module {s}: {s} is a directory, whose files are hashed as the build takes them; \"sha256\", \"type\" and \"strip\" don't apply", .{ m.name, p });
            const start = ctx.now();
            const snap = try snapshot(io, arena, dir, src.skip);
            ctx.timed(start, "take {d} files from {s}", .{ snap.files, dir });
            if (ctx.verbose) note("module {s}: {d} files from {s} (sha256 {s})", .{ m.name, snap.files, dir, snap.hash });
            try s.entries.append(arena, .{ .module = m.name, .index = i, .snapshot = snap });
        };
        return s;
    }

    /// The snapshot of a module's source, if it's a directory.
    pub fn get(s: *const Snapshots, module: []const u8, index: usize) ?*const Snapshot {
        for (s.entries.items) |*e| if (e.index == index and std.mem.eql(u8, e.module, module)) return &e.snapshot;
        return null;
    }

    /// Fails if the files of a module's directory sources (every module's,
    /// for null) changed since their snapshots, as they would if edited
    /// while the build copied them: what it copied might then not be what
    /// its record says.
    pub fn recheck(s: *const Snapshots, ctx: *Context, module: ?[]const u8) !void {
        for (s.entries.items) |e| {
            if (module) |name| if (!std.mem.eql(u8, e.module, name)) continue;
            if (!try unchanged(ctx.io, ctx.arena, e.snapshot))
                return fail("module {s}: files in {s} changed while zigsaw took them; build again", .{ e.module, e.snapshot.dir });
        }
    }
};

/// The files git would commit in `dir` (absolute), less those `skip`
/// matches (cleanup patterns, from `dir`).
pub fn snapshot(io: Io, arena: Allocator, dir: []const u8, skip: []const []const u8) !Snapshot {
    var w: Walk = .{ .io = io, .arena = arena, .skip = skip };
    // The .gitignore files above it count too, from the top of its
    // repository down.
    var top_rel: []const u8 = "";
    if (try repositoryTop(io, arena, dir)) |top| {
        var at = top;
        var parts = std.mem.tokenizeAny(u8, dir[top.len..], "\\/");
        while (parts.next()) |part| {
            _ = try w.pushGitignore(at, top_rel);
            top_rel = try join(arena, top_rel, part);
            if (w.rules.ignored(top_rel, true))
                return fail("{s} is ignored by its repository's .gitignore, so git would commit none of it", .{dir});
            at = try std.fs.path.join(arena, &.{ at, part });
        }
    }
    try w.walk(dir, "", top_rel);
    if (w.files == 0) return fail("{s} has no files that git would commit", .{dir});
    return .{ .dir = dir, .tree = w.tree, .hash = try arena.dupe(u8, &try w.tree.contentHash(io, arena)), .files = w.files };
}

/// The nearest directory at or above `dir` that has `.git`, a directory or
/// (in a worktree or a submodule) a file.
fn repositoryTop(io: Io, arena: Allocator, dir: []const u8) !?[]const u8 {
    var at = dir;
    while (true) {
        if (try Store.exists(io, try std.fs.path.join(arena, &.{ at, ".git" }))) return at;
        at = std.fs.path.dirname(at) orelse return null;
    }
}

/// Whether the snapshot's files are still as it found them: as long, and
/// with the same hash.
fn unchanged(io: Io, arena: Allocator, s: Snapshot) !bool {
    for (s.tree.nodes.values()) |node| switch (node.content) {
        .file => |f| {
            const stat = Io.Dir.cwd().statFile(io, f.path, .{}) catch return false;
            if (stat.size != f.size) return false;
        },
        else => {},
    };
    const hash = s.tree.contentHash(io, arena) catch return false;
    return std.mem.eql(u8, &hash, s.hash);
}

fn join(arena: Allocator, base: []const u8, name: []const u8) ![]const u8 {
    return if (base.len == 0) arena.dupe(u8, name) else std.fmt.allocPrint(arena, "{s}/{s}", .{ base, name });
}

const Walk = struct {
    io: Io,
    arena: Allocator,
    skip: []const []const u8,
    rules: gitignore.Rules = .{},
    tree: Tree = .{},
    files: usize = 0,

    /// Adds the files below the directory at `path`, which is `rel` from the
    /// source's directory and `top_rel` from the top of its repository.
    /// What's ignored isn't entered, so a node_modules costs nothing.
    fn walk(w: *Walk, path: []const u8, rel: []const u8, top_rel: []const u8) !void {
        var dir = Io.Dir.cwd().openDir(w.io, path, .{ .iterate = true }) catch |err|
            return fail("reading {s}: {t}", .{ path, err });
        defer dir.close(w.io);
        const pushed = try w.pushGitignore(path, top_rel);
        defer if (pushed) w.rules.pop();
        var it = dir.iterate();
        while (try it.next(w.io)) |entry| {
            // Git's own files, here or in a repository inside this one.
            if (std.ascii.eqlIgnoreCase(entry.name, ".git")) continue;
            const name = try w.arena.dupe(u8, entry.name);
            const entry_rel = try join(w.arena, rel, name);
            const entry_top = try join(w.arena, top_rel, name);
            if (w.rules.ignored(entry_top, entry.kind == .directory) or recipe.cleanupMatches(w.skip, entry_rel)) continue;
            const full = try std.fs.path.join(w.arena, &.{ path, name });
            switch (entry.kind) {
                .directory => if (try Store.exists(w.io, try std.fs.path.join(w.arena, &.{ full, ".git" }))) {
                    // A repository of its own, such as a submodule: its
                    // .gitignore files count, not this one's.
                    const outer = w.rules;
                    defer w.rules = outer;
                    w.rules = .{};
                    try w.walk(full, entry_rel, "");
                } else try w.walk(full, entry_rel, entry_top),
                .file => {
                    const stat = try dir.statFile(w.io, name, .{});
                    w.tree.addFile(w.arena, entry_rel, .{ .file = .{ .path = full, .size = stat.size } }) catch |err| switch (err) {
                        error.PathConflict => return fail("{s} and {s} differ only in case", .{ full, w.tree.conflict }),
                        else => |e| return e,
                    };
                    w.files += 1;
                },
                // As git would commit a link as a link, which a layer
                // can't hold.
                .sym_link => return fail("{s} is a link, which an image can't hold; leave it out with the source's \"skip\"", .{full}),
                else => return fail("{s} is a {t}, which an image can't hold; leave it out with the source's \"skip\"", .{ full, entry.kind }),
            }
        }
    }

    /// Adds the patterns of the `.gitignore` in the directory at `path`, if
    /// it has one with any, and returns whether it did.
    fn pushGitignore(w: *Walk, path: []const u8, top_rel: []const u8) !bool {
        const p = try std.fs.path.join(w.arena, &.{ path, ".gitignore" });
        const bytes = Io.Dir.cwd().readFileAlloc(w.io, p, w.arena, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return fail("reading {s}: {t}", .{ p, err }),
        };
        const patterns = try gitignore.parse(w.arena, bytes);
        if (patterns.len == 0) return false;
        try w.rules.push(w.arena, top_rel, patterns);
        return true;
    }
};

fn writeTestFiles(io: Io, dir: Io.Dir, files: []const [2][]const u8) !void {
    for (files) |f| {
        if (std.fs.path.dirname(f[0])) |parent| try dir.createDirPath(io, parent);
        try dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    }
}

fn testPaths(arena: Allocator, s: Snapshot) ![]const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    for (s.tree.nodes.values()) |node| if (node.content != .dir) try paths.append(arena, node.path);
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return std.mem.join(arena, " ", paths.items);
}

test "a project's files are those git would commit" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFiles(io, tmp.dir, &.{
        .{ "repo/.git/HEAD", "ref: refs/heads/main\n" },
        .{ "repo/.gitignore", "*.log\n!keep.log\nzig-out/\n/top.txt\n" },
        .{ "repo/build.zig", "x" },
        .{ "repo/a.log", "x" },
        .{ "repo/keep.log", "x" },
        .{ "repo/top.txt", "x" },
        .{ "repo/zig-out/bin/app.exe", "x" },
        .{ "repo/src/main.zig", "x" },
        .{ "repo/src/top.txt", "x" },
        .{ "repo/src/.gitignore", "gen.zig\n" },
        .{ "repo/src/gen.zig", "x" },
        .{ "repo/docs/index.md", "x" },
        // A repository of its own: its .gitignore counts, not the outer one's.
        .{ "repo/vendor/lib/.git", "gitdir: ../../.git/modules/lib\n" },
        .{ "repo/vendor/lib/.gitignore", "gen.zig\n" },
        .{ "repo/vendor/lib/x.log", "x" },
        .{ "repo/vendor/lib/gen.zig", "x" },
    });
    try tmp.dir.createDirPath(io, "repo/empty/below");
    const repo = try tmp.dir.realPathFileAlloc(io, "repo", arena);

    const all = try snapshot(io, arena, repo, &.{});
    try std.testing.expectEqualStrings(
        ".gitignore build.zig docs/index.md keep.log src/.gitignore src/main.zig src/top.txt vendor/lib/.gitignore vendor/lib/x.log",
        try testPaths(arena, all),
    );
    try std.testing.expectEqual(9, all.files);
    // Empty directories are left out, as git leaves them out.
    try std.testing.expect(!all.tree.nodes.contains("empty"));

    // skip leaves out more, from the source's directory.
    const skipped = try snapshot(io, arena, repo, &.{ "/docs", "*.log", "/vendor" });
    try std.testing.expectEqualStrings(".gitignore build.zig src/.gitignore src/main.zig src/top.txt", try testPaths(arena, skipped));

    // A directory below the top has the .gitignore files above it too.
    const src = try snapshot(io, arena, try std.fs.path.join(arena, &.{ repo, "src" }), &.{});
    try std.testing.expectEqualStrings(".gitignore main.zig top.txt", try testPaths(arena, src));
    try std.testing.expectError(error.Failed, snapshot(io, arena, try std.fs.path.join(arena, &.{ repo, "zig-out" }), &.{}));

    // The hash depends on the files' paths and contents only.
    const again = try snapshot(io, arena, repo, &.{});
    try std.testing.expectEqualStrings(all.hash, again.hash);
    try std.testing.expect(try unchanged(io, arena, all));
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/a.log", .data = "ignored, so it doesn't count" });
    try std.testing.expect(try unchanged(io, arena, all));
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/build.zig", .data = "y" });
    try std.testing.expect(!try unchanged(io, arena, all));
    try std.testing.expect(!std.mem.eql(u8, all.hash, (try snapshot(io, arena, repo, &.{})).hash));

    // Nothing to commit fails.
    try std.testing.expectError(error.Failed, snapshot(io, arena, try std.fs.path.join(arena, &.{ repo, "empty" }), &.{}));
}
