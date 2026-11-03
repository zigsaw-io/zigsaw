//! `zigsaw update`: brings installed apps up to date with the source their ref
//! records. An app built from a recipe is rebuilt from it; one pulled by tag
//! is pulled again if the tag has moved. One pulled by digest is pinned.

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
/// `consent` is `.given` (--yes).
pub fn update(ctx: *Context, ids: []const []const u8, consent: remote.Consent) !u32 {
    var failed: usize = 0;
    for (try refsOf(ctx, ids)) |ref| {
        updateApp(ctx, ref, consent) catch |err| switch (err) {
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

fn refsOf(ctx: *Context, ids: []const []const u8) ![]const Store.Ref {
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
    const arena = ctx.arena;
    const source = ref.source orelse {
        note("{s}: doesn't record where it came from; build or pull it again to update it", .{ref.id});
        return;
    };
    if (std.fs.path.isAbsoluteWindows(source)) {
        if (!try Store.exists(ctx.io, source)) return fail("{s}: its recipe {s} is gone", .{ ref.id, source });
        note("{s} {s}: built from {s}, so only rebuilding it tells", .{ ref.id, ref.version, source });
        return;
    }
    const reference = Registry.Reference.parse(source) catch
        return fail("{s}: its source \"{s}\" isn't a recipe path or an image reference", .{ ref.id, source });
    if (reference.digest != null) {
        note("{s} {s}: pinned to {s}", .{ ref.id, ref.version, source });
        return;
    }
    const new = try remote.fetchInfoUnless(ctx, source, ref.manifest) orelse {
        note("{s} {s}: up to date", .{ ref.id, ref.version });
        return;
    };
    if (!std.mem.eql(u8, new.config.id, ref.id))
        return fail("{s}: {s} now provides {s}; build or pull that explicitly", .{ ref.id, source, new.config.id });
    try w.print("{s} {s} -> {s} ({s} -> {s})\n", .{
        ref.id,                        ref.version,                          new.config.version,
        oci.shortDigest(ref.manifest), oci.shortDigest(new.manifest_digest),
    });
    const installed = try ctx.store.readImage(arena, ref.id, ref.manifest);
    const added = try oci.addedAccess(arena, try .of(arena, installed.config), try .of(arena, new.config));
    if (!added.isEmpty()) try remote.writeAddedAccess(arena, w, added);
}

fn updateApp(ctx: *Context, ref: Store.Ref, consent: remote.Consent) !void {
    const source = ref.source orelse {
        note("{s}: doesn't record where it came from; build or pull it again to update it", .{ref.id});
        return;
    };
    const newer = if (std.fs.path.isAbsoluteWindows(source)) newer: {
        if (!try Store.exists(ctx.io, source)) return fail("{s}: its recipe {s} is gone", .{ ref.id, source });
        const image = try builder.build(ctx, source, .{});
        break :newer if (std.mem.eql(u8, image.manifest_digest, ref.manifest)) null else image;
    } else newer: {
        const reference = Registry.Reference.parse(source) catch
            return fail("{s}: its source \"{s}\" isn't a recipe path or an image reference", .{ ref.id, source });
        if (reference.digest != null) {
            note("{s} {s}: pinned to {s}", .{ ref.id, ref.version, source });
            return;
        }
        const installed = try ctx.store.readImage(ctx.arena, ref.id, ref.manifest);
        break :newer try remote.fetch(ctx, source, .{
            .unless = ref.manifest,
            .installed = .{ .version = ref.version, .access = try .of(ctx.arena, installed.config) },
            .consent = consent,
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
