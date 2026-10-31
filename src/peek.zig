//! `zigsaw ls` and `zigsaw cat`: the files of an app's image in a registry,
//! and one file's contents, read through the indexes of its layers (see
//! `format.Format.indexed`) without pulling them: a few Range requests per
//! layer, or the store's copy of a blob it has.

const std = @import("std");
const Io = std.Io;
const Context = @import("Context.zig");
const Registry = @import("Registry.zig");
const RemoteBlob = @import("RemoteBlob.zig");
const format = @import("format.zig");
const oci = @import("oci.zig");
const remote = @import("remote.zig");
const fail = Context.fail;

/// One of the image's layers, and whose it is.
const Layer = struct {
    desc: oci.Descriptor,
    id: []const u8,
    version: []const u8,
    format: format.Format,
};

/// The image's layers, the app's own first, then its runtimes', last first:
/// the order in which a name is looked for.
fn layers(ctx: *Context, app: remote.Info) ![]Layer {
    const list = try ctx.arena.alloc(Layer, app.manifest.layers.len);
    const runtimes = app.config.runtimes.map.values();
    for (list, 0..) |*l, n| {
        const i = app.manifest.layers.len - 1 - n;
        const desc = app.manifest.layers[i];
        l.* = .{
            .desc = desc,
            .id = if (i < runtimes.len) runtimes[i].id else app.config.id,
            .version = if (i < runtimes.len) runtimes[i].version else app.config.version,
            // validateLayers checked every layer has one.
            .format = format.Format.ofDescriptor(desc).?,
        };
    }
    return list;
}

/// An indexed layer, opened.
const Opened = struct {
    blob: *RemoteBlob,
    index: *format.Index,

    fn open(ctx: *Context, registry: *Registry, l: Layer) !Opened {
        const blob = try RemoteBlob.open(ctx, registry, l.desc);
        errdefer blob.close();
        const index = format.openIndex(ctx.gpa, l.desc, blob.source()) catch |err| switch (err) {
            error.RangeIgnored => return blob.wholeOnly(),
            else => |e| return e,
        };
        return .{ .blob = blob, .index = index };
    }

    fn close(o: Opened, ctx: *Context) void {
        if (ctx.verbose) {
            if (o.blob.file != null)
                Context.note("  layer {s}: read from the store", .{oci.shortDigest(o.blob.desc.digest)})
            else
                Context.note("  layer {s}: {d} request(s), {d} bytes of {d}", .{ oci.shortDigest(o.blob.desc.digest), o.blob.requests, o.blob.fetched, o.blob.desc.size });
        }
        o.index.deinit();
        o.blob.close();
    }
};

pub fn ls(ctx: *Context, image_text: []const u8) !void {
    var registry: Registry = undefined;
    const app = try remote.fetchInfoOpen(ctx, image_text, &registry);
    defer registry.deinit();
    const all = try layers(ctx, app);

    var buf: [64 * 1024]u8 = undefined;
    var stdout = Context.stdout().writerStreaming(ctx.io, &buf);
    listTo(ctx, &registry, app, all, &stdout.interface) catch |err| switch (err) {
        error.WriteFailed => return stdoutFailed(&stdout),
        else => |e| return e,
    };
}

fn listTo(ctx: *Context, registry: *Registry, app: remote.Info, all: []const Layer, w: *Io.Writer) !void {
    // Headings only when there's more than one layer to tell apart.
    const headings = all.len > 1;
    for (all) |l| {
        if (!l.format.indexed()) {
            if (headings)
                try w.print("{s} {s}: {s}, which can't be listed without pulling it\n", .{ l.id, l.version, l.format.label() })
            else
                return fail("{s}'s layer is {s}, which can't be listed without pulling it", .{ app.target.text, l.format.label() });
            continue;
        }
        const opened = try Opened.open(ctx, registry, l);
        defer opened.close(ctx);
        if (headings) {
            var files: usize = 0;
            for (opened.index.files) |f| if (f.entry.type == .reg and format.isLayerFile(f.name)) {
                files += 1;
            };
            try w.print("{s} {s}: {d} files\n", .{ l.id, l.version, files });
        }
        for (opened.index.files) |f| {
            if (f.entry.type != .reg or !format.isLayerFile(f.name)) continue;
            try w.print("{s}{d: >12}  {s}\n", .{ if (headings) "  " else "", f.size, f.name });
        }
    }
    try w.flush();
}

pub fn cat(ctx: *Context, image_text: []const u8, path: []const u8) !void {
    const arena = ctx.arena;
    var registry: Registry = undefined;
    const app = try remote.fetchInfoOpen(ctx, image_text, &registry);
    defer registry.deinit();
    const name = try arena.dupe(u8, path);
    std.mem.replaceScalar(u8, name, '\\', '/');

    var skipped: std.ArrayList([]const u8) = .empty;
    for (try layers(ctx, app)) |l| {
        if (!l.format.indexed()) {
            try skipped.append(arena, try std.fmt.allocPrint(arena, "{s}'s ({s})", .{ l.id, l.format.label() }));
            continue;
        }
        const opened = try Opened.open(ctx, &registry, l);
        defer opened.close(ctx);
        const f = opened.index.lookup(name) orelse continue;
        if (!format.isLayerFile(f.name)) continue;
        if (f.entry.type != .reg) return fail("{s} is a directory in {s}", .{ path, app.target.text });
        var buf: [64 * 1024]u8 = undefined;
        var stdout = Context.stdout().writerStreaming(ctx.io, &buf);
        var scratch: format.Index.Scratch = .{};
        defer scratch.deinit(ctx.gpa);
        opened.index.readFile(ctx.gpa, &scratch, f, &stdout.interface) catch |err| switch (err) {
            error.OutOfMemory, error.Failed => |e| return e,
            error.WriteFailed => return stdoutFailed(&stdout),
            error.RangeIgnored => return opened.blob.wholeOnly(),
            else => return fail("reading {s} from layer {s}: {t}", .{ path, oci.shortDigest(l.desc.digest), err }),
        };
        stdout.interface.flush() catch return stdoutFailed(&stdout);
        return;
    }
    if (skipped.items.len > 0)
        return fail("{s} has no {s} in the layers zigsaw can read without pulling; {s} can't be", .{ app.target.text, path, try oci.joinAnd(arena, skipped.items) });
    return fail("{s} has no file {s}", .{ app.target.text, path });
}

/// After a write to stdout failed: quiet if whoever read it stopped, as in
/// `zigsaw cat ... | head`.
fn stdoutFailed(stdout: *const Io.File.Writer) error{Failed} {
    const err = stdout.err orelse return fail("writing to stdout failed", .{});
    if (err == error.BrokenPipe) return error.Failed;
    return fail("writing to stdout: {t}", .{err});
}
