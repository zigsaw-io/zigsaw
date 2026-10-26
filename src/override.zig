//! Per-app overrides: run options saved for an app, which every run of it
//! gets, like `flatpak override`. Shims run apps through `zigsaw run`, so
//! overrides reach them too. They are kept in <root>\overrides\<id>.json.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const oci = @import("oci.zig");
const fail = Context.fail;

pub const Sandbox = enum { soft, low, appcontainer };

/// Run options that can be given on the command line or saved as overrides.
/// Null or empty fields leave the choice to the layer below: the command line
/// goes over overrides, and overrides over the app's own permissions.
pub const Settings = struct {
    sandbox: ?Sandbox = null,
    network: ?bool = null,
    ephemeral: ?bool = null,
    /// Filesystem permissions granted on top of the app's own, or instead of
    /// one of them for the same location (`documents:ro` for `documents`).
    filesystem: []const []const u8 = &.{},
    /// Locations whose filesystem permission the layers below give, and
    /// this one takes away, like Flatpak's --nofilesystem.
    nofilesystem: []const []const u8 = &.{},
    /// "NAME=VALUE" environment variables, set over the app's own.
    env: []const []const u8 = &.{},
    /// Installed extensions, by id, that don't join the app's runs, which
    /// they otherwise do (see extensions.zig).
    noextension: []const []const u8 = &.{},
    /// Extensions a layer below leaves out, by id, that this one has join
    /// the runs again. Merging uses them up: a merge's result has none.
    extension: []const []const u8 = &.{},
    /// "NAME=PORT": where other programs reach the app's service NAME,
    /// instead of the port its config says (see services.zig).
    ports: []const []const u8 = &.{},

    pub fn isEmpty(s: Settings) bool {
        return s.sandbox == null and s.network == null and s.ephemeral == null and
            s.filesystem.len == 0 and s.nofilesystem.len == 0 and s.env.len == 0 and
            s.noextension.len == 0 and s.extension.len == 0 and s.ports.len == 0;
    }

    /// `upper` over `lower`. For the lists, an entry of `upper` replaces
    /// `lower`'s for the same location or variable name; what `upper`
    /// grants or takes away for a location is what holds for it.
    pub fn merge(arena: Allocator, lower: Settings, upper: Settings) !Settings {
        return .{
            .sandbox = upper.sandbox orelse lower.sandbox,
            .network = upper.network orelse lower.network,
            .ephemeral = upper.ephemeral orelse lower.ephemeral,
            .filesystem = try mergeList(arena, try without(arena, lower.filesystem, upper.nofilesystem, grantPath), upper.filesystem, grantPath),
            .nofilesystem = try mergeList(arena, try without(arena, lower.nofilesystem, upper.filesystem, grantPath), upper.nofilesystem, grantPath),
            .env = try mergeList(arena, lower.env, upper.env, envName),
            .noextension = try mergeList(arena, try without(arena, lower.noextension, upper.extension, itself), upper.noextension, itself),
            .ports = try mergeList(arena, lower.ports, upper.ports, envName),
        };
    }

    /// The filesystem permissions a run gets: the app's own under these
    /// settings.
    pub fn filesystemFor(s: Settings, arena: Allocator, app_permissions: []const []const u8) ![]const []const u8 {
        return (try merge(arena, .{ .filesystem = app_permissions }, s)).filesystem;
    }

    /// As saved: without the options left unset, and without the extension
    /// and port lists when empty, so that a zigsaw from before them still
    /// reads it.
    pub fn jsonStringify(s: Settings, jw: anytype) !void {
        try jw.beginObject();
        inline for (std.meta.fields(Settings)) |f| {
            const v = @field(s, f.name);
            const later_list = comptime std.mem.eql(u8, f.name, "noextension") or std.mem.eql(u8, f.name, "extension") or
                std.mem.eql(u8, f.name, "ports");
            const skip = switch (@typeInfo(f.type)) {
                .optional => v == null,
                else => if (later_list) v.len == 0 else false,
            };
            if (!skip) {
                try jw.objectField(f.name);
                try jw.write(v);
            }
        }
        try jw.endObject();
    }

    /// As the command-line options that set them.
    pub fn format(s: Settings, w: *Io.Writer) Io.Writer.Error!void {
        var sep: []const u8 = "";
        if (s.sandbox) |sb| {
            try w.print("{s}--sandbox={t}", .{ sep, sb });
            sep = " ";
        }
        if (s.network) |on| {
            try w.print("{s}--{s}=network", .{ sep, if (on) "share" else "unshare" });
            sep = " ";
        }
        if (s.ephemeral orelse false) {
            try w.print("{s}--ephemeral", .{sep});
            sep = " ";
        }
        for (s.filesystem) |f| {
            try w.print("{s}--filesystem={s}", .{ sep, f });
            sep = " ";
        }
        for (s.nofilesystem) |f| {
            try w.print("{s}--nofilesystem={s}", .{ sep, f });
            sep = " ";
        }
        for (s.env) |e| {
            try w.print("{s}--env={s}", .{ sep, e });
            sep = " ";
        }
        for (s.noextension) |id| {
            try w.print("{s}--noextension={s}", .{ sep, id });
            sep = " ";
        }
        for (s.extension) |id| {
            try w.print("{s}--extension={s}", .{ sep, id });
            sep = " ";
        }
        for (s.ports) |p| {
            try w.print("{s}--port={s}", .{ sep, p });
            sep = " ";
        }
    }
};

/// A --port value, "NAME=PORT", as two parts; null if it isn't one.
pub fn parsePort(value: []const u8) ?struct { name: []const u8, port: u16 } {
    const eq = std.mem.indexOfScalar(u8, value, '=') orelse return null;
    const port = std.fmt.parseInt(u16, value[eq + 1 ..], 10) catch return null;
    if (eq == 0 or port == 0) return null;
    return .{ .name = value[0..eq], .port = port };
}

/// `lower` followed by `upper`, where each entry of `upper` first removes the
/// entries with the same key.
fn mergeList(arena: Allocator, lower: []const []const u8, upper: []const []const u8, key: fn ([]const u8) []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(arena, lower);
    for (upper) |u| {
        var i: usize = 0;
        while (i < out.items.len) {
            if (std.os.windows.eqlIgnoreCaseWtf8(key(out.items[i]), key(u))) {
                _ = out.orderedRemove(i);
            } else i += 1;
        }
        try out.append(arena, u);
    }
    return out.items;
}

/// The entries of `list` whose key none of `others` has.
fn without(arena: Allocator, list: []const []const u8, others: []const []const u8, key: fn ([]const u8) []const u8) ![]const []const u8 {
    if (others.len == 0) return list;
    var out: std.ArrayList([]const u8) = .empty;
    for (list) |entry| {
        const named = for (others) |o| {
            if (std.os.windows.eqlIgnoreCaseWtf8(key(entry), key(o))) break true;
        } else false;
        if (!named) try out.append(arena, entry);
    }
    return out.items;
}

fn itself(id: []const u8) []const u8 {
    return id;
}

/// A filesystem permission without its ":ro" or ":rw".
fn grantPath(spec: []const u8) []const u8 {
    if (std.mem.endsWith(u8, spec, ":ro") or std.mem.endsWith(u8, spec, ":rw")) return spec[0 .. spec.len - 3];
    return spec;
}

fn envName(assignment: []const u8) []const u8 {
    return assignment[0 .. std.mem.indexOfScalar(u8, assignment, '=') orelse assignment.len];
}

fn filePath(store: Store, arena: Allocator, id: []const u8) ![]u8 {
    if (!oci.isValidId(id)) return fail("\"{s}\" is not a valid app id", .{id});
    return store.path(arena, &.{ "overrides", try std.fmt.allocPrint(arena, "{s}.json", .{id}) });
}

/// The app's saved overrides; empty if it has none.
pub fn load(store: Store, arena: Allocator, id: []const u8) !Settings {
    const p = try filePath(store, arena, id);
    const bytes = Io.Dir.cwd().readFileAlloc(store.io, p, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => |e| return e,
    };
    return std.json.parseFromSliceLeaky(Settings, arena, bytes, .{}) catch |err|
        fail("{s}: {t}; fix it, or remove it with `zigsaw override --reset {s}`", .{ p, err, id });
}

/// Replaces the app's saved overrides. Saving none deletes the file.
pub fn save(store: Store, arena: Allocator, id: []const u8, s: Settings) !void {
    if (s.isEmpty()) return delete(store, arena, id);
    const tmp = try store.tmpPath(arena, "override");
    try Io.Dir.cwd().writeFile(store.io, .{ .sub_path = tmp, .data = try oci.toJson(arena, s) });
    try Io.Dir.rename(.cwd(), tmp, .cwd(), try filePath(store, arena, id), store.io);
}

pub fn delete(store: Store, arena: Allocator, id: []const u8) !void {
    Io.Dir.cwd().deleteFile(store.io, try filePath(store, arena, id)) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
}

test "Settings.merge: upper wins, lists replace by path or name" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const saved: Settings = .{
        .sandbox = .appcontainer,
        .ephemeral = true,
        .filesystem = &.{ "D:\\src", "cwd" },
        .env = &.{ "A=1", "B=1" },
    };
    const command_line: Settings = .{
        .network = false,
        .ephemeral = false,
        .filesystem = &.{"d:\\SRC:ro"},
        .env = &.{ "a=2", "C=3", "C=4" },
    };
    const s = try Settings.merge(arena, saved, command_line);
    try std.testing.expectEqual(Sandbox.appcontainer, s.sandbox.?);
    try std.testing.expectEqual(false, s.network.?);
    try std.testing.expectEqual(false, s.ephemeral.?);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "cwd", "d:\\SRC:ro" }), s.filesystem);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "B=1", "a=2", "C=4" }), s.env);

    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try s.format(&w);
    try std.testing.expectEqualStrings("--sandbox=appcontainer --unshare=network --filesystem=cwd --filesystem=d:\\SRC:ro --env=B=1 --env=a=2 --env=C=4", w.buffered());

    try std.testing.expect((Settings{}).isEmpty());
    try std.testing.expectEqualDeep(saved, try Settings.merge(arena, .{}, saved));
}

test "Settings.merge: --nofilesystem takes away what the layers below grant, until a layer above grants it again" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const app: []const []const u8 = &.{ "cwd", "documents", "downloads:ro" };

    // An override takes documents away, and makes downloads writable.
    const saved: Settings = .{ .filesystem = &.{"downloads"}, .nofilesystem = &.{"Documents"} };
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "cwd", "downloads" }), try saved.filesystemFor(arena, app));

    // The command line gives documents back, read-only, and takes cwd away.
    const command_line: Settings = .{ .filesystem = &.{"documents:ro"}, .nofilesystem = &.{"cwd"} };
    const s = try Settings.merge(arena, saved, command_line);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "downloads", "documents:ro" }), s.filesystem);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"cwd"}), s.nofilesystem);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "downloads", "documents:ro" }), try s.filesystemFor(arena, app));

    // A layer's own grant downgrades the app's for the same location.
    const ro: Settings = .{ .filesystem = &.{"documents:ro"} };
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "cwd", "downloads:ro", "documents:ro" }), try ro.filesystemFor(arena, app));

    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try s.format(&w);
    try std.testing.expectEqualStrings("--filesystem=downloads --filesystem=documents:ro --nofilesystem=cwd", w.buffered());
    try std.testing.expect(!(Settings{ .nofilesystem = &.{"cwd"} }).isEmpty());
}

test "Settings.merge: --noextension leaves an extension out until a layer above has it join again" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const saved: Settings = .{ .noextension = &.{ "net.php.php.Xdebug", "net.php.php.APCu" } };
    const command_line: Settings = .{ .extension = &.{"NET.php.php.xdebug"}, .noextension = &.{"x.y"} };
    const s = try Settings.merge(arena, saved, command_line);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "net.php.php.APCu", "x.y" }), s.noextension);
    try std.testing.expectEqual(0, s.extension.len);
    // What `override --extension` saves: nothing, once nothing's left out.
    try std.testing.expect((try Settings.merge(arena, .{ .noextension = &.{"a"} }, .{ .extension = &.{"a"} })).isEmpty());

    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try (Settings{ .noextension = &.{"a"}, .extension = &.{"b"} }).format(&w);
    try std.testing.expectEqualStrings("--noextension=a --extension=b", w.buffered());
}

test "Settings.merge: --port replaces a lower layer's for the same service" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try Settings.merge(arena, .{ .ports = &.{ "http=9090", "admin=9091" } }, .{ .ports = &.{"http=8080"} });
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "admin=9091", "http=8080" }), s.ports);
    try std.testing.expect(!s.isEmpty());

    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try s.format(&w);
    try std.testing.expectEqualStrings("--port=admin=9091 --port=http=8080", w.buffered());

    const p = parsePort("postgresql=5433").?;
    try std.testing.expectEqualStrings("postgresql", p.name);
    try std.testing.expectEqual(5433, p.port);
    for ([_][]const u8{ "postgresql", "=5433", "pg=0", "pg=65536", "pg=x" }) |bad| try std.testing.expectEqual(null, parsePort(bad));

    // A zigsaw from before ports reads settings without them.
    try std.testing.expect(std.mem.indexOf(u8, try oci.toJson(arena, Settings{ .network = true }), "ports") == null);
}

test "Settings round-trips through JSON" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s: Settings = .{ .sandbox = .appcontainer, .network = true, .filesystem = &.{"D:\\src:ro"} };
    const json = try oci.toJson(arena, s);
    try std.testing.expectEqualDeep(s, try std.json.parseFromSliceLeaky(Settings, arena, json, .{}));
    // zigsaw 0.23 reads settings without the extension lists.
    try std.testing.expect(std.mem.indexOf(u8, json, "extension") == null);
    const x: Settings = .{ .noextension = &.{"a.b"} };
    try std.testing.expectEqualDeep(x, try std.json.parseFromSliceLeaky(Settings, arena, try oci.toJson(arena, x), .{}));
}
