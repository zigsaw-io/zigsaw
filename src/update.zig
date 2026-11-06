//! `zigsaw update`: brings installed apps up to date with the source their ref
//! records. An app built from a recipe is rebuilt from it; one pulled by tag
//! is pulled again if the tag has moved. One pulled by digest is pinned, and
//! one held (`zigsaw hold`) is left alone too. The version a rollback left is
//! passed over, and a newer one isn't (see rollback.zig).

const std = @import("std");
const Context = @import("Context.zig");
const Registry = @import("Registry.zig");
const Store = @import("Store.zig");
const builder = @import("builder.zig");
const install = @import("install.zig");
const oci = @import("oci.zig");
const remote = @import("remote.zig");
const fail = Context.fail;
const note = Context.note;

/// Updates the given apps, or every installed app, and returns the exit code:
/// 1 if any couldn't be updated. One failure doesn't stop the others. An app
/// whose new version may reach more is updated only if you agree, unless
/// `consent` is `.given` (--yes). `lazily`: `--lazy`, as for `pull`.
pub fn update(ctx: *Context, ids: []const []const u8, consent: remote.Consent, lazily: bool) !u32 {
    var failed: usize = 0;
    for (try refsOf(ctx, ids)) |ref| {
        updateApp(ctx, ref, consent, lazily) catch |err| switch (err) {
            error.Failed => failed += 1, // Already reported.
            else => |e| return e,
        };
    }
    if (failed == 0) return 0;
    note("{d} app(s) couldn't be updated", .{failed});
    return 1;
}

/// `update --check`: what `update` would do for the given apps, or every
/// installed app, without doing it. An app a new image waits for gets its
/// lines on stdout, and the others a note. Returns the exit code: 1 if any
/// couldn't be checked, whatever the others found.
pub fn check(ctx: *Context, ids: []const []const u8) !u32 {
    var failed: usize = 0;
    var buf: [1024]u8 = undefined;
    var stdout = Context.stdout().writerStreaming(ctx.io, &buf);
    for (try refsOf(ctx, ids)) |ref| {
        checkApp(ctx, ref, &stdout.interface) catch |err| switch (err) {
            error.Failed => failed += 1, // Already reported.
            error.WriteFailed => return fail("writing to stdout failed", .{}),
            else => |e| return e,
        };
        stdout.interface.flush() catch return fail("writing to stdout failed", .{});
    }
    if (failed == 0) return 0;
    note("{d} app(s) couldn't be checked", .{failed});
    return 1;
}

pub fn refsOf(ctx: *Context, ids: []const []const u8) ![]const Store.Ref {
    const arena = ctx.arena;
    var refs: std.ArrayList(Store.Ref) = .empty;
    if (ids.len == 0) {
        try refs.appendSlice(arena, try ctx.store.listRefs(arena));
        if (refs.items.len == 0) note("no apps are installed", .{});
    } else for (ids) |id| {
        try refs.append(arena, try ctx.store.readRef(arena, id) orelse return fail("{s} is not installed", .{id}));
    }
    return refs.items;
}

fn checkApp(ctx: *Context, ref: Store.Ref, w: *std.Io.Writer) !void {
    const app = try newImage(ctx, ref) orelse return;
    try app.write(w);
}

/// A new image an installed app could update to.
pub const Waiting = struct {
    id: []const u8,
    from: []const u8,
    to: []const u8,
    from_digest: []const u8,
    to_digest: []const u8,
    /// What it may reach beyond the installed version, as lines ready to show.
    added: []const u8 = "",

    pub fn write(app: Waiting, w: *std.Io.Writer) !void {
        try w.print("{s} {s} -> {s} ({s} -> {s})\n", .{
            app.id,                           app.from,                       app.to,
            oci.shortDigest(app.from_digest), oci.shortDigest(app.to_digest),
        });
        try w.writeAll(app.added);
    }
};

/// Whether the app is held, which updates leave alone, after a note saying so.
fn held(ctx: *Context, ref: Store.Ref) !bool {
    if (!try ctx.store.isHeld(ctx.arena, ref.id)) return false;
    note("{s} {s}: held; `zigsaw unhold {s}` lets updates in", .{ ref.id, ref.version, ref.id });
    return true;
}

/// The version a rollback left, if `digest` is it: an update passes over that.
pub fn passesOver(skip: ?Store.Skip, digest: []const u8) ?Store.Skip {
    const s = skip orelse return null;
    return if (std.mem.eql(u8, s.manifest, digest)) s else null;
}

/// Whether a new image with this digest is the one a rollback left, after a note
/// saying so.
fn skipped(ctx: *Context, ref: Store.Ref, digest: []const u8) !bool {
    const s = passesOver(try ctx.store.readSkip(ctx.arena, ref.id), digest) orelse return false;
    note("{s} {s}: skipping {s} ({s}), which it went back from", .{ ref.id, ref.version, s.version, oci.shortDigest(s.manifest) });
    return true;
}

/// What a new image waits for the app, reading no layers; null, after a note
/// saying why, if there's none, or nothing could tell.
pub fn newImage(ctx: *Context, ref: Store.Ref) !?Waiting {
    const arena = ctx.arena;
    if (try held(ctx, ref)) return null;
    const source = ref.source orelse {
        note("{s}: doesn't record where it came from; build or pull it again to update it", .{ref.id});
        return null;
    };
    if (std.fs.path.isAbsoluteWindows(source)) {
        if (!try Store.exists(ctx.io, source)) return fail("{s}: its recipe {s} is gone", .{ ref.id, source });
        note("{s} {s}: built from {s}, so only rebuilding it tells", .{ ref.id, ref.version, source });
        return null;
    }
    const reference = Registry.Reference.parse(source) catch
        return fail("{s}: its source \"{s}\" isn't a recipe path or an image reference", .{ ref.id, source });
    if (reference.digest != null) {
        note("{s} {s}: pinned to {s}", .{ ref.id, ref.version, source });
        return null;
    }
    const new = try remote.fetchInfoUnless(ctx, source, ref.manifest) orelse {
        note("{s} {s}: up to date", .{ ref.id, ref.version });
        return null;
    };
    if (try skipped(ctx, ref, new.manifest_digest)) return null;
    if (!std.mem.eql(u8, new.config.id, ref.id))
        return fail("{s}: {s} now provides {s}; build or pull that explicitly", .{ ref.id, source, new.config.id });
    const installed = try ctx.store.readImage(arena, ref.id, ref.manifest);
    const added = try oci.addedAccess(arena, try .of(arena, installed.config), try .of(arena, new.config));
    var lines: std.Io.Writer.Allocating = .init(arena);
    if (!added.isEmpty()) try remote.writeAddedAccess(arena, &lines.writer, added);
    return .{
        .id = ref.id,
        .from = ref.version,
        .to = new.config.version,
        .from_digest = ref.manifest,
        .to_digest = new.manifest_digest,
        .added = lines.written(),
    };
}

fn updateApp(ctx: *Context, ref: Store.Ref, consent: remote.Consent, lazily: bool) !void {
    if (try held(ctx, ref)) return;
    const source = ref.source orelse {
        note("{s}: doesn't record where it came from; build or pull it again to update it", .{ref.id});
        return;
    };
    const newer = if (std.fs.path.isAbsoluteWindows(source)) newer: {
        if (!try Store.exists(ctx.io, source)) return fail("{s}: its recipe {s} is gone", .{ ref.id, source });
        const image = try builder.build(ctx, source, .{});
        if (!std.mem.eql(u8, image.manifest_digest, ref.manifest) and try skipped(ctx, ref, image.manifest_digest)) return;
        break :newer if (std.mem.eql(u8, image.manifest_digest, ref.manifest)) null else image;
    } else newer: {
        const reference = Registry.Reference.parse(source) catch
            return fail("{s}: its source \"{s}\" isn't a recipe path or an image reference", .{ ref.id, source });
        if (reference.digest != null) {
            note("{s} {s}: pinned to {s}", .{ ref.id, ref.version, source });
            return;
        }
        // With a version to pass over, what the tag names first, so that
        // nothing of that version is downloaded, or asked about.
        if (try ctx.store.readSkip(ctx.arena, ref.id) != null) {
            const digest = try remote.manifestDigest(ctx, source);
            if (std.mem.eql(u8, digest, ref.manifest)) break :newer null;
            if (try skipped(ctx, ref, digest)) return;
        }
        const installed = try ctx.store.readImage(ctx.arena, ref.id, ref.manifest);
        break :newer try remote.fetch(ctx, source, .{
            .unless = ref.manifest,
            .installed = .{ .version = ref.version, .access = try .of(ctx.arena, installed.config) },
            .consent = consent,
            .lazy = lazily,
        });
    };

    const image = newer orelse {
        note("{s} {s}: up to date", .{ ref.id, ref.version });
        return;
    };
    if (!std.mem.eql(u8, image.config.id, ref.id))
        return fail("{s}: {s} now provides {s}; build or pull that explicitly", .{ ref.id, source, image.config.id });
    try install.install(ctx, image);
    note("updated {s} {s} -> {s} ({s} -> {s})", .{
        ref.id,                        ref.version,                            image.config.version,
        oci.shortDigest(ref.manifest), oci.shortDigest(image.manifest_digest),
    });
}

test "passesOver: only the very version a rollback left" {
    const skip: Store.Skip = .{ .version = "2", .manifest = "sha256:bb" };
    try std.testing.expectEqualStrings("2", passesOver(skip, "sha256:bb").?.version);
    try std.testing.expectEqual(null, passesOver(skip, "sha256:cc"));
    try std.testing.expectEqual(null, passesOver(null, "sha256:bb"));
}
