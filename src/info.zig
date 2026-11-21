//! `zigsaw remote-info`: what an app in a registry is, needs and may reach,
//! before it's installed, from its image's manifest and config. And `zigsaw
//! info`: the same of an installed app, from the store, with where it is;
//! and `zigsaw list`, the installed apps.

const std = @import("std");
const Io = std.Io;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const associations = @import("associations.zig");
const exports = @import("exports.zig");
const format = @import("format.zig");
const grants = @import("grants.zig");
const lazy = @import("lazy.zig");
const oci = @import("oci.zig");
const output = @import("output.zig");
const override = @import("override.zig");
const remote = @import("remote.zig");
const remotes = @import("remotes.zig");
const shortcuts = @import("shortcuts.zig");
const updates = @import("updates.zig");
const fail = Context.fail;

/// An installed app, as `list` shows it.
pub const Listed = struct {
    id: []const u8,
    version: []const u8,
    manifest: []const u8,
    source: ?[]const u8,
    /// Its commands on your PATH: those it exports, and those runs installed.
    commands: []const []const u8,
    runtimes: []const RuntimeRef,
    extension_points: []const Point,
    extends: ?oci.Extends,
    shortcuts: []const []const u8,
    opens: []const []const u8,
    registry: []const []const u8,
    override: ?override.Settings,
    lazy: ?lazy.Progress,
    masked: bool,
    previous: ?Previous,
    skips: ?Store.Skip,
};

/// The version an installed one replaced, which `rollback` goes back to.
pub const Previous = struct {
    version: []const u8,
    manifest: []const u8,
    /// Whether the app's data as that version left it is kept too.
    with_data: bool,
};

/// `zigsaw list`.
pub fn list(ctx: *Context) !void {
    const arena = ctx.arena;
    const refs = try ctx.store.listRefs(arena);
    const shims = try exports.list(ctx);
    const apps = try arena.alloc(Listed, refs.len);
    for (apps, refs) |*app, ref| app.* = try listedWith(ctx, ref, shims);
    if (ctx.format == .json) {
        try output.write(ctx, apps);
    } else {
        var buf: [4096]u8 = undefined;
        var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
        try writeList(arena, &stdout.interface, apps);
    }
    try grants.noteLeftovers(ctx);
    try updates.noteWaiting(ctx);
}

/// An installed app, as `list` shows it: for what changed it to say so too.
pub fn listed(ctx: *Context, ref: Store.Ref) !Listed {
    return listedWith(ctx, ref, try exports.list(ctx));
}

fn listedWith(ctx: *Context, ref: Store.Ref, shims: anytype) !Listed {
    const arena = ctx.arena;
    var names: std.ArrayList([]const u8) = .empty;
    for (shims) |s| if (std.mem.eql(u8, s.sidecar.app, ref.id)) try names.append(arena, s.name);
    const image = try ctx.store.readImage(arena, ref.id, ref.manifest);
    const cfg = image.config;
    const saved = try override.load(ctx.store, arena, ref.id);
    return .{
        .id = ref.id,
        .version = ref.version,
        .manifest = ref.manifest,
        .source = ref.source,
        .commands = names.items,
        .runtimes = try runtimesOf(arena, cfg),
        .extension_points = try pointsOf(arena, cfg),
        .extends = cfg.extends,
        .shortcuts = try shortcuts.names(ctx, ref.id),
        .opens = try associations.names(ctx, ref.id),
        .registry = cfg.registry orelse &.{},
        .override = if (saved.isEmpty()) null else saved,
        .lazy = try lazy.progress(ctx.store, arena, image.manifest),
        .masked = try ctx.store.isHeld(arena, ref.id),
        .previous = try previousOf(ctx, ref),
        .skips = try ctx.store.readSkip(arena, ref.id),
    };
}

fn writeList(arena: std.mem.Allocator, w: *Io.Writer, apps: []const Listed) !void {
    try w.print("{s:<32} {s:<20} {s:<20} {s}\n", .{ "ID", "VERSION", "MANIFEST", "EXPORTS" });
    for (apps) |app| {
        try w.print("{s:<32} {s:<20} {s:<20} {s}", .{ app.id, app.version, oci.shortDigest(app.manifest), try std.mem.join(arena, ", ", app.commands) });
        for (app.runtimes) |r| try w.print("  (runtime {s} {s})", .{ r.id, r.version });
        for (app.extension_points) |p| try w.print("  (extension point {s})", .{p.name});
        if (app.extends) |x| try w.print("  (extends {s} {s})", .{ x.point, x.version });
        for (app.shortcuts) |name| try w.print("  (shortcut \"{s}\")", .{name});
        if (app.opens.len > 0) try w.print("  (opens {s})", .{try std.mem.join(arena, ", ", app.opens)});
        for (app.registry) |k| try w.print("  (keeps HKCU\\{s})", .{k});
        if (app.override) |saved| try w.print("  (override {f})", .{saved});
        if (app.lazy) |p| try w.print("  {s}", .{try p.text(arena)});
        if (app.masked) try w.writeAll("  (masked)");
        if (app.previous) |p| try w.print("  (previous {s}{s})", .{ p.version, if (p.with_data) ", with data" else "" });
        if (app.skips) |s| try w.print("  (skips {s})", .{s.version});
        try w.writeByte('\n');
    }
    try w.flush();
}

/// The version `rollback` would go back to, if there's one other than this.
fn previousOf(ctx: *Context, ref: Store.Ref) !?Previous {
    const arena = ctx.arena;
    const p = try ctx.store.readPrevious(arena, ref.id) orelse return null;
    if (std.mem.eql(u8, p.manifest, ref.manifest)) return null;
    const with_data = if (try ctx.store.readKeptData(arena, ref.id)) |k| std.mem.eql(u8, k.manifest, p.manifest) else false;
    return .{ .version = p.version, .manifest = p.manifest, .with_data = with_data };
}

/// `zigsaw info <app-id>`: an installed app, as the store has it; no network.
pub fn installedInfo(ctx: *Context, id: []const u8) !void {
    const arena = ctx.arena;
    if (!oci.isValidId(id))
        return fail("\"{s}\" isn't an installed app's id; `zigsaw remote-info {s}` shows an app in a remote", .{ id, id });
    const ref = try ctx.store.readRef(arena, id) orelse
        return fail("{s} isn't installed; `zigsaw remote-info {s}` shows what it is in its remote", .{ id, id });
    const image = try ctx.store.readImage(arena, ref.id, ref.manifest);
    const cfg = image.config;

    if (ctx.format == .json) {
        const remote_name: ?[]const u8 = if (ref.source) |source| if (try remotes.of(ctx, source)) |r| r.name else null else null;
        return output.write(ctx, output.merged(.{
            headOf(cfg),
            struct { source: ?[]const u8, remote: ?[]const u8, manifest: []const u8 }{
                .source = ref.source,
                .remote = remote_name,
                .manifest = ref.manifest,
            },
            try contentsOf(arena, image.manifest, cfg),
            struct { location: []const u8, data: []const u8, masked: bool, previous: ?Previous }{
                .location = try ctx.store.deployPath(arena, oci.ownLayer(image.manifest).digest),
                .data = try ctx.store.dataDir(arena, ref.id),
                .masked = try ctx.store.isHeld(arena, ref.id),
                .previous = try previousOf(ctx, ref),
            },
        }));
    }

    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const w = &stdout.interface;
    try writeName(w, cfg);
    try writeLine(w, "homepage", cfg.homepage orelse "");
    try writeLine(w, "license", cfg.license orelse "");
    try writeLine(w, "origin", if (ref.source) |source| if (try remotes.of(ctx, source)) |r|
        try std.fmt.allocPrint(arena, "{s}, in the remote {s}", .{ source, r.name })
    else
        source else "");
    try writeLine(w, "manifest", ref.manifest);
    try writeContents(ctx, w, image.manifest, cfg);
    if (cfg.build) |b| try writeLine(w, "built", try describeBuild(arena, b));
    try writeLine(w, "location", try ctx.store.deployPath(arena, oci.ownLayer(image.manifest).digest));
    try writeLine(w, "data", try ctx.store.dataDir(arena, ref.id));
    if (try ctx.store.isHeld(arena, ref.id)) try writeLine(w, "masked", try std.fmt.allocPrint(arena, "updates leave it alone until `zigsaw mask --remove {s}`", .{ref.id}));
    if (try ctx.store.readPrevious(arena, ref.id)) |p| try writeLine(w, "previous", try std.fmt.allocPrint(arena, "{s} ({s}), which `zigsaw rollback {s}` goes back to", .{ p.version, oci.shortDigest(p.manifest), ref.id }));
    try w.flush();
}

/// `zigsaw remote-info <image>`.
pub fn remoteInfo(ctx: *Context, image_text: []const u8) !void {
    const arena = ctx.arena;
    var registry: @import("Registry.zig") = undefined;
    const app = try remote.fetchInfoOpen(ctx, image_text, &registry);
    defer registry.deinit();
    const cfg = app.config;
    const checked = try remote.checkSignature(ctx, &registry, app.target.ref, app.index, app.manifest_digest);
    if (ctx.format == .json) {
        const installed = try ctx.store.readRef(arena, cfg.id);
        return output.write(ctx, output.merged(.{
            headOf(cfg),
            struct { image: []const u8, manifest: []const u8, index: ?[]const u8, signature: Signature, download: Download }{
                .image = app.target.text,
                .manifest = app.manifest_digest,
                .index = app.index,
                .signature = switch (checked) {
                    .no_key => .{ .state = .no_key },
                    .missing => .{ .state = .missing },
                    .signed => |by| .{ .state = .signed, .by = by },
                    .wrong => |why| .{ .state = .wrong, .why = why },
                },
                .download = try downloadOf(ctx, app.manifest),
            },
            try contentsOf(arena, app.manifest, cfg),
            struct { installed: ?struct { version: []const u8, manifest: []const u8 } }{
                .installed = if (installed) |ref| .{ .version = ref.version, .manifest = ref.manifest } else null,
            },
        }));
    }
    const signature_text: []const u8 = switch (checked) {
        .no_key => "not checked: no key here for its registry",
        .missing => "none: nothing says who made it",
        .signed => |by| try std.fmt.allocPrint(arena, "signed, by {s}", .{by}),
        .wrong => |why| try std.fmt.allocPrint(arena, "WRONG: {s}, so install refuses it", .{why}),
    };

    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const w = &stdout.interface;
    try writeName(w, cfg);
    try writeLine(w, "homepage", cfg.homepage orelse "");
    try writeLine(w, "license", cfg.license orelse "");
    try writeLine(w, "image", app.target.text);
    try writeLine(w, "manifest", app.manifest_digest);
    try writeLine(w, "signature", signature_text);
    if (app.index) |index| try writeLine(w, "index", try std.fmt.allocPrint(arena, "{s}, as its image for windows/amd64", .{index}));
    try writeDownload(ctx, w, app.manifest);
    try writeContents(ctx, w, app.manifest, cfg);
    if (cfg.build) |b| try writeLine(w, "built", try describeBuild(arena, b));
    const installed = try ctx.store.readRef(arena, cfg.id);
    try writeLine(w, "installed", if (installed) |ref|
        if (std.mem.eql(u8, ref.manifest, app.manifest_digest))
            try std.fmt.allocPrint(arena, "{s}, this image", .{ref.version})
        else
            try std.fmt.allocPrint(arena, "{s} ({s})", .{ ref.version, oci.shortDigest(ref.manifest) })
    else
        "no");
    try w.flush();
}

/// What `info` and `remote-info` say first, as JSON.
pub const Head = struct {
    id: []const u8,
    version: []const u8,
    name: ?[]const u8,
    summary: ?[]const u8,
    homepage: ?[]const u8,
    license: ?[]const u8,
};

pub fn headOf(cfg: oci.AppConfig) Head {
    return .{ .id = cfg.id, .version = cfg.version, .name = cfg.name, .summary = cfg.summary, .homepage = cfg.homepage, .license = cfg.license };
}

/// A runtime, as JSON names it.
pub const RuntimeRef = struct {
    id: []const u8,
    version: []const u8,
    /// Its image's manifest digest.
    image: []const u8,
};

/// An extension point, as JSON names it.
pub const Point = struct { name: []const u8, version: []const u8 };

/// A sandbox the app can't work under, and why.
pub const Unsupported = struct {
    sandbox: oci.Sandbox,
    why: []const u8,
    /// The runtime that can't, or null when it's the app's own reason.
    runtime: ?[]const u8,
};

/// What the app brings and may reach, as `info` and `remote-info` say it in
/// JSON (`writeContents` says it in text).
pub const Contents = struct {
    runtimes: []const RuntimeRef,
    /// Its own layer's: tar, gzip or estargz.
    layer_format: ?format.Format,
    extension_points: []const Point,
    extends: ?oci.Extends,
    commands: []const []const u8,
    shortcuts: []const []const u8,
    /// Kinds of file by extension (".rnote"), and URL schemes ("vscodium:").
    opens: []const []const u8,
    unsupported: []const Unsupported,
    /// As its config has them.
    permissions: oci.Permissions,
    /// The ports it connects to: its own and its runtimes'.
    uses: []const oci.Use,
    registry: []const []const u8,
    /// As its config says: null for images made before iteration 4.
    build: ?oci.Build,
};

pub fn contentsOf(arena: std.mem.Allocator, manifest: oci.Manifest, cfg: oci.AppConfig) !Contents {
    var opens: std.ArrayList([]const u8) = .empty;
    if (cfg.associations) |a| try opens.appendSlice(arena, a.map.keys());
    if (cfg.schemes) |s| for (s.map.keys()) |name| try opens.append(arena, try std.fmt.allocPrint(arena, "{s}:", .{name}));
    var unsupported: std.ArrayList(Unsupported) = .empty;
    for (std.enums.values(oci.Sandbox)) |sandbox| if (oci.unsupportedUnder(cfg, sandbox)) |reason|
        try unsupported.append(arena, .{ .sandbox = sandbox, .why = reason.why, .runtime = reason.runtime });
    const access: oci.Access = try .of(arena, cfg);
    return .{
        .runtimes = try runtimesOf(arena, cfg),
        .layer_format = format.Format.ofDescriptor(oci.ownLayer(manifest)),
        .extension_points = try pointsOf(arena, cfg),
        .extends = cfg.extends,
        .commands = cfg.exports.map.keys(),
        .shortcuts = if (cfg.shortcuts) |s| s.map.keys() else &.{},
        .opens = opens.items,
        .unsupported = unsupported.items,
        .permissions = cfg.permissions,
        .uses = access.uses,
        .registry = access.registry,
        .build = cfg.build,
    };
}

fn runtimesOf(arena: std.mem.Allocator, cfg: oci.AppConfig) ![]const RuntimeRef {
    const out = try arena.alloc(RuntimeRef, cfg.runtimes.map.count());
    for (out, cfg.runtimes.map.values()) |*o, r| o.* = .{ .id = r.id, .version = r.version, .image = r.image };
    return out;
}

fn pointsOf(arena: std.mem.Allocator, cfg: oci.AppConfig) ![]const Point {
    const e = cfg.extensions orelse return &.{};
    const out = try arena.alloc(Point, e.map.count());
    for (out, e.map.keys(), e.map.values()) |*o, name, p| o.* = .{ .name = name, .version = p.version };
    return out;
}

/// What the app is: the first lines of `info` and `remote-info`, and of what
/// `install` shows before it asks.
pub fn writeName(w: *Io.Writer, cfg: oci.AppConfig) !void {
    if (cfg.name) |n| try w.print("{s} {s}: {s}\n", .{ cfg.id, cfg.version, n }) else try w.print("{s} {s}\n", .{ cfg.id, cfg.version });
    if (cfg.summary) |s| try w.print("  {s}\n", .{s});
}

/// Whether an image is signed, as `remote-info --format=json` says it.
const Signature = struct {
    /// signed, missing (nothing says who made it), no_key (not checked: no
    /// key here for its registry) or wrong (install refuses it).
    state: enum { signed, missing, no_key, wrong },
    /// Whose signature it is, when signed.
    by: ?[]const u8 = null,
    /// What's wrong with it, when wrong.
    why: ?[]const u8 = null,
};

/// What installing an image downloads, in bytes: its config and layers, and
/// of those layers, what the store hasn't got yet.
const Download = struct { bytes: u64, missing: u64 };

fn downloadOf(ctx: *Context, manifest: oci.Manifest) !Download {
    var d: Download = .{ .bytes = manifest.config.size, .missing = 0 };
    for (manifest.layers) |l| {
        d.bytes += l.size;
        if (!try Store.exists(ctx.io, try ctx.store.blobPath(ctx.arena, oci.digestHex(l.digest).?))) d.missing += l.size;
    }
    return d;
}

/// What installing the image downloads, and how much of that the store has
/// already (a runtime another app has, say).
pub fn writeDownload(ctx: *Context, w: *Io.Writer, manifest: oci.Manifest) !void {
    const arena = ctx.arena;
    const d = try downloadOf(ctx, manifest);
    const total = d.bytes;
    const missing = d.missing;
    try writeLine(w, "download", if (missing == total - manifest.config.size)
        try std.fmt.allocPrint(arena, "{Bi:.1}", .{total})
    else if (missing == 0)
        try std.fmt.allocPrint(arena, "{Bi:.1}, all in the store already", .{total})
    else
        try std.fmt.allocPrint(arena, "{Bi:.1}, of which {Bi:.1} isn't in the store yet", .{ total, missing }));
}

/// What the app brings and may reach, as `info`, `remote-info` and `install`
/// show it.
pub fn writeContents(ctx: *Context, w: *Io.Writer, manifest: oci.Manifest, cfg: oci.AppConfig) !void {
    const arena = ctx.arena;
    var runtimes: std.ArrayList([]const u8) = .empty;
    for (cfg.runtimes.map.values()) |r| try runtimes.append(arena, try std.fmt.allocPrint(arena, "{s} {s}", .{ r.id, r.version }));
    try writeLine(w, "runtimes", try std.mem.join(arena, ", ", runtimes.items));
    // Only when it isn't what builds make by default.
    if (format.Format.ofDescriptor(oci.ownLayer(manifest))) |f| if (f != .gzip) try writeLine(w, "layer", f.label());
    if (cfg.extensions) |e| {
        var pts: std.ArrayList([]const u8) = .empty;
        for (e.map.keys(), e.map.values()) |name, p| try pts.append(arena, try std.fmt.allocPrint(arena, "{s} {s}", .{ name, p.version }));
        try writeLine(w, "points", try std.fmt.allocPrint(arena, "{s} (installed extensions of it join its runs)", .{try std.mem.join(arena, ", ", pts.items)}));
    }
    if (cfg.extends) |x| try writeLine(w, "extends", try std.fmt.allocPrint(arena, "{s} {s}{s}{s}", .{
        x.point,
        x.version,
        if (x.needs != null) ", after " else "",
        if (x.needs) |n| try oci.joinAnd(arena, n) else "",
    }));
    try writeLine(w, "commands", try std.mem.join(arena, ", ", cfg.exports.map.keys()));
    if (cfg.shortcuts) |s| {
        var names: std.ArrayList([]const u8) = .empty;
        for (s.map.keys()) |n| try names.append(arena, try std.fmt.allocPrint(arena, "\"{s}\"", .{n}));
        try writeLine(w, "shortcuts", try std.mem.join(arena, ", ", names.items));
    }
    var opens: std.ArrayList([]const u8) = .empty;
    if (cfg.associations) |a| try opens.appendSlice(arena, a.map.keys());
    if (cfg.schemes) |s| for (s.map.keys()) |name| try opens.append(arena, try std.fmt.allocPrint(arena, "{s}:", .{name}));
    try writeLine(w, "opens", try std.mem.join(arena, ", ", opens.items));
    if (cfg.permissions.services) |s| try writeLine(w, "serves", try oci.describeServices(arena, s));
    for (std.enums.values(oci.Sandbox)) |sandbox| if (oci.unsupportedUnder(cfg, sandbox)) |reason| {
        const line = if (reason.runtime) |runtime_id|
            try std.fmt.allocPrint(arena, "under {t}: {s} (its runtime {s})", .{ sandbox, reason.why, runtime_id })
        else
            try std.fmt.allocPrint(arena, "under {t}: {s}", .{ sandbox, reason.why });
        try writeLine(w, "can't run", line);
    };
    try writeAccess(arena, w, try .of(arena, cfg));
}

/// The lines saying what an app may reach: all of it, or what an update adds.
pub fn writeAccess(arena: std.mem.Allocator, w: *Io.Writer, access: oci.Access) !void {
    try writeLine(w, "permits", try oci.describePermissions(arena, access.permissions));
    if (access.uses.len > 0) try writeLine(w, "uses", try oci.describeUses(arena, access.uses));
    if (access.registry.len > 0) try writeLine(w, "keeps", try std.fmt.allocPrint(arena, "{s} with its data", .{try oci.describeRegistry(arena, access.registry)}));
}

/// A labelled line, unless there's nothing to say.
pub fn writeLine(w: *Io.Writer, label: []const u8, value: []const u8) !void {
    if (value.len > 0) try w.print("  {s:<10} {s}\n", .{ label, value });
}

/// How the image was built, as far as its config says: with which SDKs, and
/// whether it should rebuild the same.
fn describeBuild(arena: std.mem.Allocator, b: oci.Build) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var sdks: std.ArrayList([]const u8) = .empty;
    for (b.sdk.map.keys()) |alias| try sdks.append(arena, alias);
    // Not "from its sources": the config doesn't say whether anything was
    // compiled, and a recipe may only unpack upstream's own build.
    const downloads = try std.fmt.allocPrint(arena, "from {d} pinned download{s}", .{ b.sources.len, if (b.sources.len == 1) "" else "s" });
    try parts.append(arena, if (sdks.items.len > 0)
        try std.fmt.allocPrint(arena, "{s}, with {s}", .{ downloads, try oci.joinAnd(arena, sdks.items) })
    else
        try std.fmt.allocPrint(arena, "{s}, without an SDK", .{downloads}));
    if (b.network) try parts.append(arena, "a step used the network, so it may not rebuild the same");
    if (b.host.map.count() > 0) try parts.append(arena, try std.fmt.allocPrint(arena, "with the build machine's {s}, so it won't rebuild the same elsewhere", .{try std.mem.join(arena, ", ", b.host.map.keys())}));
    return std.mem.join(arena, "; ", parts.items);
}

test describeBuild {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("from 1 pinned download, without an SDK", try describeBuild(arena, .{ .sources = &.{"a"} }));
    var with: oci.Build = .{ .sources = &.{ "a", "b" }, .network = true };
    try with.sdk.map.put(arena, "zig", "sha256:z");
    try with.sdk.map.put(arena, "busybox", "sha256:b");
    try std.testing.expectEqualStrings("from 2 pinned downloads, with zig and busybox; a step used the network, so it may not rebuild the same", try describeBuild(arena, with));
}
