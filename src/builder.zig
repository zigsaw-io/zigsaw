//! `zigsaw build`: assembles an app tree from a recipe's sources, packs it into
//! an image in the local store, and installs it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Fetcher = @import("fetch.zig");
const layer = @import("layer.zig");
const oci = @import("oci.zig");
const recipe = @import("recipe.zig");
const Store = @import("Store.zig");
const fail = Context.fail;
const note = Context.note;

pub fn build(ctx: *Context, recipe_path: []const u8) !void {
    const io = ctx.io;
    const arena = ctx.arena;

    const bytes = Io.Dir.cwd().readFileAlloc(io, recipe_path, arena, .limited(1 << 20)) catch |err|
        return fail("reading {s}: {t}", .{ recipe_path, err });
    const r = try recipe.parse(arena, recipe_path, bytes);

    const work = try ctx.store.makeTmpDir(arena, "build");
    defer Io.Dir.cwd().deleteTree(io, work) catch {};
    const tree = try std.fs.path.join(arena, &.{ work, "app" });
    try Io.Dir.cwd().createDirPath(io, tree);

    var fetcher: Fetcher = .{ .ctx = ctx, .base_dir = std.fs.path.dirname(recipe_path) orelse "." };
    defer fetcher.deinit();

    for (r.sources, 0..) |src, i| {
        const file = try fetcher.fetch(src);
        switch (src.kind()) {
            .file => {
                const dest = try std.fs.path.join(arena, &.{ tree, src.dest orelse src.fileName() });
                if (std.fs.path.dirname(dest)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
                try Io.Dir.copyFile(.cwd(), file, .cwd(), dest, io, .{});
            },
            .zip => {
                const unpacked = try std.fs.path.join(arena, &.{ work, try std.fmt.allocPrint(arena, "src-{d}", .{i}) });
                try extractZip(io, file, unpacked);
                const dest = try std.fs.path.join(arena, &.{ tree, src.dest orelse "." });
                try Io.Dir.cwd().createDirPath(io, dest);
                try moveContents(io, arena, unpacked, dest, src.strip);
            },
        }
    }

    const command_path = try std.fs.path.join(arena, &.{ tree, r.command });
    if (!try Store.exists(io, command_path))
        return fail("command \"{s}\" is not in the app tree after unpacking the sources", .{r.command});

    const tar_path = try std.fs.path.join(arena, &.{ work, "layer.tar" });
    try layer.write(io, arena, tree, tar_path);
    const layer_desc = try ctx.store.putBlobFile(arena, tar_path, oci.media_type.layer_tar);

    const config_desc = try ctx.store.putBlob(arena, try oci.toJson(arena, r.appConfig()), oci.media_type.config);

    var annotations: std.json.ArrayHashMap([]const u8) = .{};
    try annotations.map.put(arena, "org.opencontainers.image.title", r.id);
    try annotations.map.put(arena, "org.opencontainers.image.version", r.version);
    const manifest: oci.Manifest = .{
        .config = config_desc,
        .layers = &.{layer_desc},
        .annotations = annotations,
    };
    const manifest_desc = try ctx.store.putBlob(arena, try oci.toJson(arena, manifest), oci.media_type.manifest);

    // The staged tree is exactly what the layer contains, so deploy it directly
    // instead of unpacking the tar again.
    _ = try ctx.store.adoptDeployment(arena, manifest_desc.digest, tree);
    try ctx.store.writeRef(arena, .{ .id = r.id, .version = r.version, .manifest = manifest_desc.digest });

    note("installed {s} {s}\n  manifest {s}\n  layer    {s} ({d} bytes)", .{
        r.id, r.version, manifest_desc.digest, layer_desc.digest, layer_desc.size,
    });
}

fn extractZip(io: Io, zip_path: []const u8, dest_path: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, dest_path);
    var dest = try Io.Dir.cwd().openDir(io, dest_path, .{});
    defer dest.close(io);
    var file = try Io.Dir.cwd().openFile(io, zip_path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buf);
    std.zip.extract(dest, &reader, .{ .allow_backslashes = true }) catch |err|
        return fail("extracting {s}: {t}", .{ zip_path, err });
}

/// Moves the contents of `src` into `dst`, dropping the first `strip`
/// directory levels (files above that depth are skipped, as with
/// `tar --strip-components`). Existing directories are merged and existing
/// files replaced, so later sources can overlay earlier ones.
fn moveContents(io: Io, arena: Allocator, src: []const u8, dst: []const u8, strip: u32) !void {
    const Entry = struct { name: []const u8, is_dir: bool };
    var entries: std.ArrayList(Entry) = .empty;
    {
        var dir = try Io.Dir.cwd().openDir(io, src, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            try entries.append(arena, .{ .name = try arena.dupe(u8, e.name), .is_dir = e.kind == .directory });
        }
    }

    for (entries.items) |e| {
        const from = try std.fs.path.join(arena, &.{ src, e.name });
        if (strip > 0) {
            if (e.is_dir) try moveContents(io, arena, from, dst, strip - 1);
            continue;
        }
        const to = try std.fs.path.join(arena, &.{ dst, e.name });
        if (e.is_dir and try isDir(io, to)) {
            try moveContents(io, arena, from, to, 0);
        } else {
            try Io.Dir.rename(.cwd(), from, .cwd(), to, io);
        }
    }
}

fn isDir(io: Io, p: []const u8) !bool {
    const stat = Io.Dir.cwd().statFile(io, p, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return stat.kind == .directory;
}
