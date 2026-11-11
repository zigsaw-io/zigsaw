//! Going back: `zigsaw rollback` returns an app to the version an update (or a
//! pull or build over it) replaced, from the blobs the store kept of it, with
//! no network. Updates then pass over the version it left (see update.zig),
//! though not a newer one. `zigsaw hold` and `unhold` keep updates away from
//! an app, or let them in again.
//!
//! The store keeps one previous version per app: install.zig writes it, and
//! prune.zig keeps its blobs, though not its unpacked files, which going back
//! makes again. It keeps the app's data as that version left it too
//! (snapshot.zig), which going back takes back if you say so.

const std = @import("std");
const Context = @import("Context.zig");
const Registry = @import("Registry.zig");
const Store = @import("Store.zig");
const install = @import("install.zig");
const oci = @import("oci.zig");
const prompt = @import("prompt.zig");
const remote = @import("remote.zig");
const snapshot = @import("snapshot.zig");
const fail = Context.fail;
const note = Context.note;

/// What a rollback does with the app's data, when its data as the version
/// gone back to left it is kept (see snapshot.zig).
pub const Data = enum {
    /// Asks; with nothing to answer, the data stays.
    ask,
    /// `--data`: takes it back too.
    take,
    /// `--keep-data`: leaves the data as it is.
    keep,
    /// `--data-only`: takes back the data of the installed version, and
    /// leaves the version: for after a rollback that left the data.
    only,
};

/// Installs the app's previous version again, once you agree to what it may
/// reach beyond the installed one, if anything (`consent`, as for `update`),
/// and has updates pass over the version it leaves. Its data goes back too
/// if a copy of it is kept and `data` or your answer says so.
pub fn rollback(ctx: *Context, id: []const u8, consent: remote.Consent, data: Data) !void {
    const arena = ctx.arena;
    const store = ctx.store;
    const current = try store.readRef(arena, id) orelse return fail("{s} is not installed", .{id});
    if (data == .only) return dataOnly(ctx, current);
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

    // Its data as the version gone back to left it, if that's kept.
    const kept = try snapshot.keptOf(ctx, current.id, previous.manifest);
    if (kept == null and data == .take)
        return fail("{s}: none of its data is kept as {s} left it; without --data, `zigsaw rollback` goes back and leaves the data as it is", .{ current.id, previous.version });

    const installed = try store.readImage(arena, current.id, current.manifest);
    try remote.agreeTo(ctx, image.manifest, image.config, .{
        .version = current.version,
        .access = try .of(arena, installed.config),
    }, consent, .rollback);

    const take = if (kept) |k| switch (data) {
        .take => true,
        .keep => false,
        .ask => try askForData(ctx, current, previous, k),
        .only => unreachable,
    } else false;
    if (take and try snapshot.running(ctx, current.id))
        return fail("{s} stays at {s}: a run of it goes on, and its data can't go back under it. Let it end first, or go back with --keep-data", .{ current.id, current.version });
    const had_data = try snapshot.hasData(ctx, current.id);

    try install.install(ctx, .{
        .manifest_digest = previous.manifest,
        .manifest = image.manifest,
        .config = image.config,
        // Where it came from: updates follow that again.
        .source = previous.source orelse "",
        // agreeTo told what it may reach beyond the installed one.
        .described = true,
        // What's kept is this version's: it's taken back, or stays for later.
        .data = if (kept != null) .leave else .keep,
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

    if (take) {
        snapshot.swap(ctx, current.id) catch |err| switch (err) {
            error.Failed => return fail("{s} went back to {s}, but its data is still as {s} left it; `zigsaw rollback --data-only {s}` takes the data back", .{
                current.id, previous.version, current.version, current.id,
            }),
            else => |e| return e,
        };
        note("  its data went back too, to how {s} left it {f}; what {s} wrote since is set aside, and returns with `zigsaw rollback --data {s}`, until the next update of the app", .{
            previous.version, snapshot.ago(ctx, kept.?.taken), current.version, current.id,
        });
    } else if (kept) |k| {
        note("  its data stays as {s} left it; `zigsaw rollback --data-only {s}` takes it back to how {s} left it {f}", .{
            current.version, current.id, previous.version, snapshot.ago(ctx, k.taken),
        });
    } else if (had_data) {
        note("  its data stays as {s} left it: none is kept as {s} left it", .{ current.version, previous.version });
    }
}

/// Says what data is kept, and asks whether it's to go back with the version.
fn askForData(ctx: *Context, current: Store.Ref, previous: Store.Ref, kept: snapshot.Kept) !bool {
    note("{s}'s data as {s} left it {f} is kept ({Bi:.1} in {d} file(s)). Taking it back sets aside what {s} wrote since, until the next update of the app.", .{
        current.id, previous.version, snapshot.ago(ctx, kept.taken), kept.bytes, kept.files, current.version,
    });
    return switch (try prompt.askNoYes(ctx, "Take its data back too?")) {
        .yes => true,
        .no => false,
        .none => none: {
            note("  nothing answered: its data stays. --data takes it back, --keep-data leaves it without asking", .{});
            break :none false;
        },
    };
}

/// `zigsaw rollback --data-only`: takes back the data kept as the installed
/// version left it, and sets the app's data aside in its place.
fn dataOnly(ctx: *Context, current: Store.Ref) !void {
    const arena = ctx.arena;
    const kept = try snapshot.keptOf(ctx, current.id, current.manifest) orelse {
        const other = try ctx.store.readKeptData(arena, current.id) orelse
            return fail("{s} {s}: none of its data is kept", .{ current.id, current.version });
        return fail("{s} {s}: the data kept is as {s} left it, not {s}; `zigsaw rollback {s}` goes back to that version, and asks about its data", .{
            current.id, current.version, other.version, current.version, current.id,
        });
    };
    try snapshot.swap(ctx, current.id);
    note("{s} {s}: its data is back to how this version left it {f}", .{ current.id, current.version, snapshot.ago(ctx, kept.taken) });
    if (try ctx.store.readKeptData(arena, current.id)) |aside|
        note("  what {s} wrote since is set aside, and returns with `zigsaw rollback --data {s}`, until the next update of the app", .{ aside.version, current.id });
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
