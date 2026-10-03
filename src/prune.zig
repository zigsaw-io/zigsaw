//! `zigsaw prune`: deletes what no installed app needs: the blobs and
//! deployments of versions that were replaced or removed, and leftovers in
//! tmp\. On request, also cached downloads, build tools' caches, and the data
//! of apps that are no longer installed. Anything a running app uses is kept.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const oci = @import("oci.zig");
const note = Context.note;

pub const Options = struct {
    /// Only report what would be deleted.
    dry_run: bool = false,
    /// Also delete cached build sources, which rebuilds would download again,
    /// and the caches of build tools, which they would fill again.
    downloads: bool = false,
    /// Also delete the data directories of apps that aren't installed.
    data: bool = false,
};

const Tally = struct {
    count: usize = 0,
    bytes: u64 = 0,

    fn add(t: *Tally, bytes: u64) void {
        t.count += 1;
        t.bytes += bytes;
    }
};

/// Expects the store lock to be held exclusively, so nothing else is using
/// the store except running apps, which hold their own locks.
pub fn prune(ctx: *Context, opts: Options) !void {
    const io = ctx.io;
    const arena = ctx.arena;
    const store = ctx.store;
    const refs = try store.listRefs(arena);
    const build_images = try store.listBuildImages(arena);

    // Everything the installed apps refer to, by hex digest, and unless
    // downloads go too, the images that builds use.
    var manifests: std.ArrayList([]const u8) = .empty;
    for (refs) |ref| try manifests.append(arena, ref.manifest);
    if (!opts.downloads) try manifests.appendSlice(arena, build_images);
    var blobs_used: std.StringHashMapUnmanaged(void) = .empty;
    for (manifests.items) |digest| {
        const manifest = try store.readManifest(arena, digest);
        for ([_][]const oci.Descriptor{ &.{manifest.config}, manifest.layers }) |descs| {
            for (descs) |d| try blobs_used.put(arena, oci.digestHex(d.digest) orelse continue, {});
        }
        try blobs_used.put(arena, oci.digestHex(digest).?, {});
    }
    const deployments_used = try store.usedLayers(arena, .{ .build_images = !opts.downloads });

    var blobs: Tally = .{};
    const blob_dir = try store.path(arena, &.{ "blobs", "sha256" });
    for (try listDir(io, arena, blob_dir)) |entry| {
        if (blobs_used.contains(entry.name)) continue;
        const p = try std.fs.path.join(arena, &.{ blob_dir, entry.name });
        blobs.add(try treeSize(io, arena, p));
        if (!opts.dry_run) try Io.Dir.cwd().deleteFile(io, p);
    }

    // Deployments, then the lock files left without one.
    var deployments: Tally = .{};
    var deployments_in_use: usize = 0;
    const deploy_dir = try store.path(arena, &.{"deploy"});
    const deploy_entries = try listDir(io, arena, deploy_dir);
    for (deploy_entries) |entry| {
        if (entry.kind != .directory or !oci.isSha256Hex(entry.name) or deployments_used.contains(entry.name)) continue;
        const digest = try std.fmt.allocPrint(arena, "sha256:{s}", .{entry.name});
        const size = try treeSize(io, arena, try std.fs.path.join(arena, &.{ deploy_dir, entry.name }));
        const in_use = if (opts.dry_run)
            try store.deploymentInUse(arena, digest)
        else
            try store.deleteDeployment(arena, digest) == .in_use;
        if (in_use) {
            deployments_in_use += 1;
        } else {
            deployments.add(size);
        }
    }
    if (!opts.dry_run) try deleteStaleLocks(io, arena, deploy_dir);

    // Leftovers in tmp\: everything but the directories of running
    // --ephemeral apps. Builds and pulls stage files here too, but can't be
    // running while prune holds the store lock.
    var tmp: Tally = .{};
    var tmp_in_use: usize = 0;
    const tmp_dir = try store.path(arena, &.{"tmp"});
    for (try listDir(io, arena, tmp_dir)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".lock")) continue;
        const p = try std.fs.path.join(arena, &.{ tmp_dir, entry.name });
        if (try Store.isLocked(io, try Store.lockPathFor(arena, p))) {
            tmp_in_use += 1;
            continue;
        }
        tmp.add(try treeSize(io, arena, p));
        if (!opts.dry_run) try Store.deleteTree(io, arena, p);
    }
    if (!opts.dry_run) try deleteStaleLocks(io, arena, tmp_dir);

    var downloads: Tally = .{};
    const downloads_dir = try store.path(arena, &.{ "cache", "downloads" });
    for (try listDir(io, arena, downloads_dir)) |entry| {
        const p = try std.fs.path.join(arena, &.{ downloads_dir, entry.name });
        downloads.add(try treeSize(io, arena, p));
        if (opts.downloads and !opts.dry_run) try Io.Dir.cwd().deleteTree(io, p);
    }
    // Build tools' caches go like downloads: keeping them only makes builds
    // faster.
    var tool_caches: Tally = .{};
    const tools_dir = try store.path(arena, &.{ "cache", "tools" });
    for (try listDir(io, arena, tools_dir)) |entry| {
        const p = try std.fs.path.join(arena, &.{ tools_dir, entry.name });
        tool_caches.add(try treeSize(io, arena, p));
        if (opts.downloads and !opts.dry_run) try Store.deleteTree(io, arena, p);
    }
    // Builds remembered by their inputs: those whose image is gone now, and
    // with --downloads, all of them. (Tiny files, so not reported.)
    const builds_dir = try store.path(arena, &.{ "cache", "builds" });
    if (!opts.dry_run) for (try listDir(io, arena, builds_dir)) |entry| {
        const digest = try store.readBuildCache(arena, entry.name);
        const gone = if (digest) |d| !try Store.exists(io, try store.blobPath(arena, oci.digestHex(d).?)) else true;
        if (opts.downloads or gone) try Io.Dir.cwd().deleteFile(io, try std.fs.path.join(arena, &.{ builds_dir, entry.name }));
    };

    // The images builds use count as downloads: their blobs and deployments
    // went above, with --downloads, and these marks go with them.
    var build_only: usize = 0;
    for (build_images) |digest| {
        if (!isInstalledManifest(refs, digest)) build_only += 1;
        if (opts.downloads and !opts.dry_run)
            try Io.Dir.cwd().deleteFile(io, try store.path(arena, &.{ "cache", "images", oci.digestHex(digest).? }));
    }

    // Data of apps that were removed without --delete-data.
    var data: Tally = .{};
    var orphans: std.ArrayList([]const u8) = .empty;
    const data_dir = try store.path(arena, &.{"data"});
    for (try listDir(io, arena, data_dir)) |entry| {
        if (entry.kind != .directory or isInstalled(refs, entry.name)) continue;
        const p = try std.fs.path.join(arena, &.{ data_dir, entry.name });
        const size = try treeSize(io, arena, p);
        data.add(size);
        try orphans.append(arena, try std.fmt.allocPrint(arena, "{s} ({Bi:.1})", .{ entry.name, size }));
        if (opts.data and !opts.dry_run) try Store.deleteTree(io, arena, p);
    }

    // Report.
    var removed: std.ArrayList([]const u8) = .empty;
    var freed: u64 = 0;
    const parts = [_]struct { Tally, bool, []const u8, []const u8 }{
        .{ blobs, true, "blob", "blobs" },
        .{ deployments, true, "deployment", "deployments" },
        .{ tmp, true, "temporary item", "temporary items" },
        .{ downloads, opts.downloads, "cached download", "cached downloads" },
        .{ tool_caches, opts.downloads, "build tool cache", "build tool caches" },
        .{ data, opts.data, "data directory", "data directories" },
    };
    for (parts) |part| {
        const t, const selected, const one, const many = part;
        if (!selected or t.count == 0) continue;
        try removed.append(arena, try std.fmt.allocPrint(arena, "{d} {s} ({Bi:.1})", .{ t.count, if (t.count == 1) one else many, t.bytes }));
        freed += t.bytes;
    }
    const verb = if (opts.dry_run) "would remove" else "removed";
    if (removed.items.len == 0) {
        note("nothing to remove", .{});
    } else {
        note("{s} {s}", .{ verb, try std.mem.join(arena, ", ", removed.items) });
        note("{s} {Bi:.1}", .{ if (opts.dry_run) "would free" else "freed", freed });
    }

    if (deployments_in_use > 0)
        note("kept {d} unused deployment(s) that a running app still uses; prune again once it exits", .{deployments_in_use});
    if (tmp_in_use > 0)
        note("kept the data of {d} running --ephemeral app(s)", .{tmp_in_use});
    if (!opts.data and orphans.items.len > 0)
        note("kept data of apps that aren't installed: {s}; --data deletes it", .{try std.mem.join(arena, ", ", orphans.items)});
    if (!opts.downloads and downloads.count > 0)
        note("kept {d} cached download(s) ({Bi:.1}) for rebuilds; --downloads deletes them", .{ downloads.count, downloads.bytes });
    if (!opts.downloads and tool_caches.count > 0)
        note("kept the caches of {d} build tool(s) ({Bi:.1}) for faster builds; --downloads deletes them", .{ tool_caches.count, tool_caches.bytes });
    if (!opts.downloads and build_only > 0)
        note("kept {d} image(s) that builds use as runtimes or SDKs; --downloads deletes them", .{build_only});
}

const Entry = struct { name: []const u8, kind: Io.File.Kind };

/// The entries of a directory, read before any of them is deleted.
fn listDir(io: Io, arena: Allocator, p: []const u8) ![]Entry {
    var dir = try Io.Dir.cwd().openDir(io, p, .{ .iterate = true });
    defer dir.close(io);
    var entries: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| try entries.append(arena, .{ .name = try arena.dupe(u8, e.name), .kind = e.kind });
    return entries.items;
}

/// Deletes the `<name>.lock` files in `dir` that nothing is locked with and
/// whose `<name>` is gone.
fn deleteStaleLocks(io: Io, arena: Allocator, dir: []const u8) !void {
    for (try listDir(io, arena, dir)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".lock")) continue;
        const lock_path = try std.fs.path.join(arena, &.{ dir, entry.name });
        if (try Store.exists(io, lock_path[0 .. lock_path.len - ".lock".len])) continue;
        if (try Store.isLocked(io, lock_path)) continue;
        Io.Dir.cwd().deleteFile(io, lock_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }
}

/// The size of a file, or of all files below a directory.
fn treeSize(io: Io, arena: Allocator, p: []const u8) !u64 {
    const stat = try Io.Dir.cwd().statFile(io, p, .{});
    if (stat.kind != .directory) return stat.size;
    var dir = try Io.Dir.cwd().openDir(io, p, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var total: u64 = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        total += (try entry.dir.statFile(io, entry.basename, .{})).size;
    }
    return total;
}

fn isInstalled(refs: []const Store.Ref, id: []const u8) bool {
    for (refs) |ref| if (std.ascii.eqlIgnoreCase(ref.id, id)) return true;
    return false;
}

fn isInstalledManifest(refs: []const Store.Ref, digest: []const u8) bool {
    for (refs) |ref| if (std.mem.eql(u8, ref.manifest, digest)) return true;
    return false;
}
