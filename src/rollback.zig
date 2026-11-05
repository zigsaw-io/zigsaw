//! Going back: `zigsaw rollback` returns an app to the version an update (or a
//! pull or build over it) replaced, from the blobs the store kept of it, with
//! no network. Updates then pass over the version it left (see update.zig),
//! though not a newer one. `zigsaw hold` and `unhold` keep updates away from
//! an app, or let them in again.
//!
//! The store keeps one previous version per app: install.zig writes it, and
//! prune.zig keeps its blobs, though not its unpacked files, which going back
//! makes again.

const std = @import("std");
const Context = @import("Context.zig");
const Registry = @import("Registry.zig");
const Store = @import("Store.zig");
const install = @import("install.zig");
const oci = @import("oci.zig");
const remote = @import("remote.zig");
const fail = Context.fail;
const note = Context.note;

/// Installs the app's previous version again, once you agree to what it may
/// reach beyond the installed one, if anything (`consent`, as for `update`),
/// and has updates pass over the version it leaves.
pub fn rollback(ctx: *Context, id: []const u8, consent: remote.Consent) !void {
    const arena = ctx.arena;
    const store = ctx.store;
    const current = try store.readRef(arena, id) orelse return fail("{s} is not installed", .{id});
    const previous = try store.readPrevious(arena, current.id) orelse
        return fail("{s} {s}: nothing to go back to; zigsaw keeps the version an update replaces from 0.76 on", .{ current.id, current.version });
    if (std.mem.eql(u8, previous.manifest, current.manifest))
        return fail("{s} {s}: nothing to go back to; its previous version is this one", .{ current.id, current.version });

    const image = try store.readCompleteImage(arena, previous.manifest) orelse
        return fail("{s}: the files of {s} ({s}) are gone, as `zigsaw prune --previous` or a zigsaw before 0.76 deletes them. {s}", .{
            current.id, previous.version, oci.shortDigest(previous.manifest), try howToGetBack(arena, previous),
        });
    if (!std.mem.eql(u8, image.config.id, current.id))
        return fail("{s}: its previous version is an image of {s}", .{ current.id, image.config.id });

    const installed = try store.readImage(arena, current.id, current.manifest);
    try remote.agreeTo(ctx, image.manifest, image.config, .{
        .version = current.version,
        .access = try .of(arena, installed.config),
    }, consent, .rollback);

    try install.install(ctx, .{
        .manifest_digest = previous.manifest,
        .manifest = image.manifest,
        .config = image.config,
        // Where it came from: updates follow that again.
        .source = previous.source orelse "",
        // agreeTo told what it may reach beyond the installed one.
        .described = true,
    });
    // A ref with no source is a very old zigsaw's: keep it as it was, so that
    // `update` says so rather than failing on an empty one.
    if (previous.source == null) try store.writeRef(arena, previous);
    try store.writeSkip(arena, current.id, .{ .version = current.version, .manifest = current.manifest });
    note("went back: {s} {s} -> {s} ({s} -> {s})", .{
        current.id,                        current.version,                    previous.version,
        oci.shortDigest(current.manifest), oci.shortDigest(previous.manifest),
    });
    note("  `zigsaw update` passes over {s} from now on, and takes a newer version; `zigsaw rollback {s}` returns to it", .{ current.version, current.id });
}

/// How to have the version again once its blobs are gone.
fn howToGetBack(arena: std.mem.Allocator, previous: Store.Ref) ![]const u8 {
    const source = previous.source orelse return "Nothing records where it came from.";
    if (std.fs.path.isAbsoluteWindows(source))
        return std.fmt.allocPrint(arena, "Rebuilding it from its recipe as it was then brings it back; the recipe was {s}.", .{source});
    const reference = Registry.Reference.parse(source) catch return "";
    return std.fmt.allocPrint(arena, "`zigsaw pull {s}/{s}@{s}` brings it back, while its registry has it.", .{
        reference.host, reference.repository, previous.manifest,
    });
}

/// `zigsaw hold` and `unhold`: keeps updates away from the apps, or lets them in.
pub fn setHeld(ctx: *Context, ids: []const []const u8, held: bool) !void {
    const arena = ctx.arena;
    var refs: std.ArrayList(Store.Ref) = .empty;
    for (ids) |id| try refs.append(arena, try ctx.store.readRef(arena, id) orelse return fail("{s} is not installed", .{id}));
    for (refs.items) |ref| {
        const changed = try ctx.store.setHeld(arena, ref.id, held);
        if (held) {
            if (changed) note("held {s} at {s}: updates leave it alone until `zigsaw unhold {s}`", .{ ref.id, ref.version, ref.id }) else note("{s} was held already", .{ref.id});
        } else {
            if (changed) note("{s} {s}: updates reach it again", .{ ref.id, ref.version }) else note("{s} wasn't held", .{ref.id});
        }
    }
}
