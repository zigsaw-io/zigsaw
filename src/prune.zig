//! `zigsaw prune`: deletes what no installed app needs: the blobs and
//! deployments of versions that were replaced or removed, and leftovers in
//! tmp\. Each app's previous version keeps its blobs, for `rollback`, though
//! not its deployments, and the copy of the app's data as it left it. On request, also cached downloads, build tools'
//! caches, recipes' kept builds, the data of apps that are no
//! longer installed, and those previous versions. Anything a running app uses
//! is kept.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const lazy = @import("lazy.zig");
const oci = @import("oci.zig");
const roots = @import("roots.zig");
const services = @import("services.zig");
const snapshot = @import("snapshot.zig");
const volumes = @import("volumes.zig");
const note = Context.note;

pub const Options = struct {
    /// Only report what would be deleted.
    dry_run: bool = false,
    /// Also delete cached build sources, which rebuilds would download again,
    /// the caches of build tools, which they would fill again, and the work
    /// directories projects' builds keep, which they would start afresh.
    downloads: bool = false,
    /// Also delete the volumes nothing mounts, as `zigsaw volume prune` does:
    /// those no override names, and the data of apps that aren't installed.
    volumes: bool = false,
    /// Also forget the versions kept for `rollback`, so that their blobs go.
    previous: bool = false,
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

    // The versions kept for rollback, of installed apps only: what an app
    // that's gone kept goes with the rest of what it left in versions\.
    var previous: std.ArrayList(Store.Ref) = .empty;
    for (try store.listPrevious(arena)) |p| if (isInstalled(refs, p.id)) try previous.append(arena, p);
    const kept_previous = !opts.previous;

    // Everything the installed apps refer to, by hex digest, their previous
    // versions too, unless they go, and unless downloads go too, the images
    // that builds use.
    var manifests: std.ArrayList([]const u8) = .empty;
    for (refs) |ref| try manifests.append(arena, ref.manifest);
    if (kept_previous) for (previous.items) |p| {
        // Only one whose manifest is still here: one an older zigsaw pruned
        // is gone already, and `rollback` says how to have it back.
        if (try Store.exists(io, try store.blobPath(arena, oci.digestHex(p.manifest) orelse continue)))
            try manifests.append(arena, p.manifest);
    };
    if (!opts.downloads) try manifests.appendSlice(arena, build_images);
    var blobs_used: std.StringHashMapUnmanaged(void) = .empty;
    for (manifests.items) |digest| {
        const manifest = try store.readManifest(arena, digest);
        for ([_][]const oci.Descriptor{ &.{manifest.config}, manifest.layers }) |descs| {
            for (descs) |d| try blobs_used.put(arena, oci.digestHex(d.digest) orelse continue, {});
        }
        try blobs_used.put(arena, oci.digestHex(digest).?, {});
    }
    // What only the previous versions keep, to say what they cost.
    var previous_only: Tally = .{};
    if (kept_previous) {
        var others: std.StringHashMapUnmanaged(void) = .empty;
        for (refs) |ref| {
            const m = try store.readManifest(arena, ref.manifest);
            try others.put(arena, oci.digestHex(ref.manifest).?, {});
            try others.put(arena, oci.digestHex(m.config.digest) orelse continue, {});
            for (m.layers) |l| try others.put(arena, oci.digestHex(l.digest) orelse continue, {});
        }
        var counted: std.StringHashMapUnmanaged(void) = .empty;
        for (previous.items) |p| {
            const hex = oci.digestHex(p.manifest) orelse continue;
            // One that's the installed version, as an install that stopped
            // halfway leaves, isn't anything to go back to.
            if (others.contains(hex) or !try Store.exists(io, try store.blobPath(arena, hex))) continue;
            previous_only.count += 1;
            const m = try store.readManifest(arena, p.manifest);
            var descs: std.ArrayList(oci.Descriptor) = .empty;
            try descs.append(arena, m.config);
            try descs.appendSlice(arena, m.layers);
            for (descs.items) |d| {
                const h = oci.digestHex(d.digest) orelse continue;
                if (others.contains(h) or counted.contains(h)) continue;
                try counted.put(arena, h, {});
                const bp = try store.blobPath(arena, h);
                if (try Store.exists(io, bp)) previous_only.bytes += try treeSize(io, arena, bp);
            }
        }
    } else if (!opts.dry_run) {
        // Forgotten before the blobs go, so that none is left naming them.
        for (previous.items) |p| _ = try store.forgetPrevious(arena, p.id);
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
        // Not only directories: a lazy pull's placeholders are a sync root,
        // which lists as a reparse point (see lazy.zig).
        if (entry.kind == .file or !oci.isSha256Hex(entry.name) or deployments_used.contains(entry.name)) continue;
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
    // What lazy pulls left (see lazy.zig): a layer's folder in lazy\ once its
    // deployment is gone, as above, and copies of zigsaw no helper runs.
    if (!opts.dry_run) _ = try lazy.prune(store, arena, null);

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
    // The locks of apps whose grants are all taken back (see grants.zig).
    if (!opts.dry_run) try deleteStaleLocks(io, arena, try store.path(arena, &.{"grants"}));

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
    // Kept builds too (see checkpoint.zig): a recipe without one builds
    // every module. No build holds one while prune has the store.
    var work: Tally = .{};
    const work_dir = try store.path(arena, &.{ "cache", "work" });
    for (try listDir(io, arena, work_dir)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".lock")) continue;
        const p = try std.fs.path.join(arena, &.{ work_dir, entry.name });
        // Its saved\ holds other names of the prefix's files, which take no
        // room of their own while the prefix has them.
        const saved = try std.fs.path.join(arena, &.{ p, "saved" });
        const links = if (entry.kind == .directory and try Store.exists(io, saved)) try treeSize(io, arena, saved) else 0;
        work.add(try treeSize(io, arena, p) -| links);
        if (opts.downloads and !opts.dry_run) try Store.deleteTree(io, arena, p);
    }
    if (!opts.dry_run) try deleteStaleLocks(io, arena, work_dir);
    // Builds remembered by their inputs: those whose image is gone now, and
    // with --downloads, all of them. (Tiny files, so not reported.)
    const builds_dir = try store.path(arena, &.{ "cache", "builds" });
    if (!opts.dry_run) for (try listDir(io, arena, builds_dir)) |entry| {
        const earlier = try store.readBuildCache(arena, entry.name);
        const gone = if (earlier) |e| !try Store.exists(io, try store.blobPath(arena, oci.digestHex(e.digest).?)) else true;
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

    // The volumes nothing mounts: those no override names, and the data of
    // apps that were removed without --delete-data (see volumes.zig).
    const pruned: volumes.Pruned = if (opts.volumes) try volumes.prune(ctx, opts.dry_run) else .{};
    const unmounted: Tally = .{ .count = pruned.count, .bytes = pruned.bytes };

    // The data kept as apps' previous versions left it (see snapshot.zig):
    // with those versions, all of it; otherwise what apps that aren't
    // installed left, and what nothing records.
    const data_gone = try snapshot.prune(ctx, refs, opts.previous, opts.dry_run);
    const kept_data: Tally = .{ .count = data_gone.files, .bytes = data_gone.bytes };

    // The alias shims of apps that aren't installed, unless one is running.
    // (Tiny files, so not reported.)
    const aliases_dir = try store.path(arena, &.{"aliases"});
    if (!opts.dry_run) {
        for (try listDir(io, arena, aliases_dir)) |entry| {
            if (entry.kind != .directory or isInstalled(refs, entry.name)) continue;
            const l = try store.lockAliases(arena, entry.name);
            defer l.release(io);
            Store.deleteTree(io, arena, try std.fs.path.join(arena, &.{ aliases_dir, entry.name })) catch {};
        }
        try deleteStaleLocks(io, arena, aliases_dir);
        // And the shims of their file associations, which `rm` deletes
        // unless one is running.
        const open_dir = try store.path(arena, &.{"open"});
        for (try listDir(io, arena, open_dir)) |entry| {
            if (entry.kind != .directory or isInstalled(refs, entry.name)) continue;
            Store.deleteTree(io, arena, try std.fs.path.join(arena, &.{ open_dir, entry.name })) catch {};
        }
        // And what versions\ says of them, which `rm` deletes, though an
        // older zigsaw's doesn't.
        for (try store.listVersionIds(arena)) |id| if (!isInstalled(refs, id)) try store.forgetVersions(arena, id);
        // And their internal ports, and relays an earlier zigsaw copied.
        const ids = try arena.alloc([]const u8, refs.len);
        for (ids, refs) |*i, r| i.* = r.id;
        try services.prune(ctx, ids);
        // And files of Windows' roots older runs had.
        try roots.prune(ctx);
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
        .{ work, opts.downloads, "kept build", "kept builds" },
        .{ unmounted, opts.volumes, "volume", "volumes" },
        .{ kept_data, true, "copy of an app's data", "copies of apps' data" },
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
    if (!opts.downloads and downloads.count > 0)
        note("kept {d} cached download(s) ({Bi:.1}) for rebuilds; --downloads deletes them", .{ downloads.count, downloads.bytes });
    if (!opts.downloads and tool_caches.count > 0)
        note("kept the caches of {d} build tool(s) ({Bi:.1}) for faster builds; --downloads deletes them", .{ tool_caches.count, tool_caches.bytes });
    if (!opts.downloads and work.count > 0)
        note("kept the builds of {d} recipe(s) ({Bi:.1}), which their next builds go on from; --downloads deletes them", .{ work.count, work.bytes });
    if (!opts.downloads and build_only > 0)
        note("kept {d} image(s) that builds use as runtimes or SDKs; --downloads deletes them", .{build_only});
    if (kept_previous and previous_only.count > 0)
        note("kept {d} previous version(s) ({Bi:.1}) for `zigsaw rollback`; --previous deletes them", .{ previous_only.count, previous_only.bytes });
    if (kept_previous) {
        const data = try snapshot.keptTotal(ctx, refs);
        if (data.files > 0)
            note("kept the data of {d} app(s) as an earlier version left it ({Bi:.1}) for `zigsaw rollback`; --previous deletes it", .{ data.files, data.bytes });
    }
    if (!kept_previous and previous.items.len > 0)
        note("{s} {d} previous version(s): `zigsaw rollback` has nothing to go back to", .{ if (opts.dry_run) "would forget" else "forgot", previous.items.len });
    // Volumes outlive apps: their own, their data, and the ones they mounted.
    if (!opts.volumes) {
        const left = try volumes.unmounted(ctx);
        if (left.names.len > 0)
            note("kept {d} volume(s) that nothing mounts: {s}; --volumes deletes them", .{ left.names.len, try std.mem.join(arena, ", ", left.names) });
    }
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
