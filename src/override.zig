//! Overrides: run options saved for an app, which every run of it gets, like
//! `flatpak override`, and for every app at once (`--global`), below each
//! app's own. Shims run apps through `zigsaw run`, so overrides reach them
//! too. An app's are kept in <root>\overrides\<id>.json, the store-wide ones
//! in <root>\overrides.json (an id needn't have a dot, so no name in
//! overrides\ is free for them).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const oci = @import("oci.zig");
const volumes = @import("volumes.zig");
const checkpoint = @import("checkpoint.zig");
const process = @import("process.zig");
const fail = Context.fail;

pub const Sandbox = oci.Sandbox;

/// Run options that can be given on the command line or saved as overrides.
/// Null or empty fields leave the choice to the layer below: the command line
/// goes over the app's overrides, those over the store-wide ones, and those
/// over the app's own permissions.
pub const Settings = struct {
    sandbox: ?Sandbox = null,
    network: ?bool = null,
    /// Whether the store's commands are on the run's PATH (see
    /// oci.Permissions).
    commands: ?bool = null,
    /// Whether `zigsaw-host` is on the run's PATH (see oci.Permissions).
    host: ?bool = null,
    ephemeral: ?bool = null,
    /// Filesystem permissions granted on top of the app's own, or instead of
    /// one of them for the same location (`documents:ro` for `documents`).
    filesystem: []const []const u8 = &.{},
    /// Locations whose filesystem permission the layers below give, and
    /// this one takes away, like Flatpak's --nofilesystem.
    nofilesystem: []const []const u8 = &.{},
    /// Hosts the run may reach, as hosts.zig reads them, on top of the
    /// app's own list (see `networkOf`).
    hosts: []const []const u8 = &.{},
    /// Hosts whose patterns the layers below give, and this one takes away.
    nohosts: []const []const u8 = &.{},
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
    /// "<volume or folder>:<target>[:ro]": what appears where in the app's
    /// data directory (see volumes.zig), as volumes.Mount.spec writes it.
    volumes: []const []const u8 = &.{},
    /// Targets whose mount a layer below has, and this one takes away.
    novolume: []const []const u8 = &.{},
    /// Whether this store's apps get the user's real folders, for a store
    /// that isn't the default one, whose apps otherwise don't (see
    /// folders.zig). Saved store-wide only.
    real_folders: ?bool = null,
    /// Whether an install that replaces the app's version keeps a copy of
    /// its data, for `rollback`, which it otherwise does (see snapshot.zig).
    /// No run option: saved only.
    snapshot: ?bool = null,
    /// Bytes of memory the run's processes may commit together (see
    /// process.Limits). 0 is none, said over a layer below that has one.
    memory: ?u64 = null,
    /// How many processors the run's processes run on. 0 is all of them,
    /// said over a layer below that has fewer.
    cpus: ?u32 = null,

    pub fn isEmpty(s: Settings) bool {
        return s.sandbox == null and s.network == null and s.commands == null and s.host == null and s.ephemeral == null and
            s.filesystem.len == 0 and s.nofilesystem.len == 0 and s.hosts.len == 0 and s.nohosts.len == 0 and s.env.len == 0 and
            s.noextension.len == 0 and s.extension.len == 0 and s.ports.len == 0 and
            s.volumes.len == 0 and s.novolume.len == 0 and s.real_folders == null and s.snapshot == null and
            s.memory == null and s.cpus == null;
    }

    /// What the run's job is held to.
    pub fn limits(s: Settings) process.Limits {
        return .{
            .memory = if ((s.memory orelse 0) == 0) null else s.memory,
            .cpus = if ((s.cpus orelse 0) == 0) null else s.cpus,
        };
    }

    /// `upper` over `lower`. For the lists, an entry of `upper` replaces
    /// `lower`'s for the same location or variable name; what `upper`
    /// grants or takes away for a location is what holds for it.
    pub fn merge(arena: Allocator, lower: Settings, upper: Settings) !Settings {
        return .{
            .sandbox = upper.sandbox orelse lower.sandbox,
            .network = upper.network orelse lower.network,
            .commands = upper.commands orelse lower.commands,
            .host = upper.host orelse lower.host,
            .ephemeral = upper.ephemeral orelse lower.ephemeral,
            .filesystem = try mergeList(arena, try without(arena, lower.filesystem, upper.nofilesystem, grantPath, grantPath), upper.filesystem, grantPath),
            .nofilesystem = try mergeList(arena, try without(arena, lower.nofilesystem, upper.filesystem, grantPath, grantPath), upper.nofilesystem, grantPath),
            .hosts = try mergeList(arena, try without(arena, lower.hosts, upper.nohosts, hostKey, hostKey), upper.hosts, hostKey),
            .nohosts = try mergeList(arena, try without(arena, lower.nohosts, upper.hosts, hostKey, hostKey), upper.nohosts, hostKey),
            .env = try mergeList(arena, lower.env, upper.env, envName),
            .noextension = try mergeList(arena, try without(arena, lower.noextension, upper.extension, itself, itself), upper.noextension, itself),
            .ports = try mergeList(arena, lower.ports, upper.ports, envName),
            .volumes = try mergeList(arena, try without(arena, lower.volumes, upper.novolume, volumes.targetOf, itself), upper.volumes, volumes.targetOf),
            .novolume = try mergeList(arena, try without(arena, lower.novolume, upper.volumes, itself, volumes.targetOf), upper.novolume, itself),
            .real_folders = upper.real_folders orelse lower.real_folders,
            .snapshot = upper.snapshot orelse lower.snapshot,
            .memory = upper.memory orelse lower.memory,
            .cpus = upper.cpus orelse lower.cpus,
        };
    }

    /// The filesystem permissions a run gets: the app's own under these
    /// settings.
    pub fn filesystemFor(s: Settings, arena: Allocator, app_permissions: []const []const u8) ![]const []const u8 {
        return (try merge(arena, .{ .filesystem = app_permissions }, s)).filesystem;
    }

    /// As saved: without the options left unset, and without the extension,
    /// port and volume lists when empty, so that a zigsaw from before them
    /// still reads it.
    pub fn jsonStringify(s: Settings, jw: anytype) !void {
        try jw.beginObject();
        const info = @typeInfo(Settings).@"struct";
        inline for (info.field_names, info.field_types) |name, T| {
            const v = @field(s, name);
            const later_list = comptime std.mem.eql(u8, name, "noextension") or std.mem.eql(u8, name, "extension") or
                std.mem.eql(u8, name, "ports") or std.mem.eql(u8, name, "volumes") or std.mem.eql(u8, name, "novolume") or
                std.mem.eql(u8, name, "hosts") or std.mem.eql(u8, name, "nohosts");
            const skip = switch (@typeInfo(T)) {
                .optional => v == null,
                else => if (later_list) v.len == 0 else false,
            };
            if (!skip) {
                try jw.objectField(name);
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
        if (s.commands) |on| {
            try w.print("{s}--{s}=commands", .{ sep, if (on) "share" else "unshare" });
            sep = " ";
        }
        if (s.host) |on| {
            try w.print("{s}--{s}=host", .{ sep, if (on) "share" else "unshare" });
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
        for (s.hosts) |h| {
            try w.print("{s}--allow-host={s}", .{ sep, h });
            sep = " ";
        }
        for (s.nohosts) |h| {
            try w.print("{s}--noallow-host={s}", .{ sep, h });
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
        for (s.volumes) |v| {
            try w.print("{s}--volume={s}", .{ sep, v });
            sep = " ";
        }
        for (s.novolume) |t| {
            try w.print("{s}--novolume={s}", .{ sep, t });
            sep = " ";
        }
        if (s.real_folders) |on| {
            try w.print("{s}--{s}real-folders", .{ sep, if (on) "" else "no" });
            sep = " ";
        }
        if (s.snapshot) |on| {
            try w.print("{s}--{s}snapshot", .{ sep, if (on) "" else "no" });
            sep = " ";
        }
        if (s.memory) |bytes| {
            if (bytes == 0) try w.print("{s}--memory=none", .{sep}) else try w.print("{s}--memory={f}", .{ sep, Size{ .bytes = bytes } });
            sep = " ";
        }
        if (s.cpus) |n| {
            if (n == 0) try w.print("{s}--cpus=all", .{sep}) else try w.print("{s}--cpus={d}", .{ sep, n });
            sep = " ";
        }
    }
};

/// A --memory value: a size as `checkpoint.parseSize` reads one, or "none";
/// null if it's neither.
pub fn parseMemory(value: []const u8) ?u64 {
    if (std.mem.eql(u8, value, "none")) return 0;
    const bytes = checkpoint.parseSize(value) catch return null;
    return if (bytes == 0) null else bytes;
}

/// A --cpus value: a whole number from 1, or "all"; null if it's neither.
pub fn parseCpus(value: []const u8) ?u32 {
    if (std.mem.eql(u8, value, "all")) return 0;
    const n = std.fmt.parseInt(u32, value, 10) catch return null;
    return if (n == 0) null else n;
}

/// A number of bytes as `checkpoint.parseSize` reads the same number back:
/// in the largest of its units that takes no fraction.
pub const Size = struct {
    bytes: u64,

    pub fn format(s: Size, w: *Io.Writer) Io.Writer.Error!void {
        const units = [_]struct { shift: u6, name: []const u8 }{
            .{ .shift = 40, .name = "TB" }, .{ .shift = 30, .name = "GB" }, .{ .shift = 20, .name = "MB" }, .{ .shift = 10, .name = "KB" },
        };
        for (units) |u| {
            if (s.bytes != 0 and s.bytes & ((@as(u64, 1) << u.shift) - 1) == 0) return w.print("{d}{s}", .{ s.bytes >> u.shift, u.name });
        }
        try w.print("{d}", .{s.bytes});
    }
};

/// The sandbox a run with `s` gets: the one the settings choose, else the one
/// the app's image asks for, else low.
pub fn sandboxOf(s: Settings, permissions: oci.Permissions) Sandbox {
    return s.sandbox orelse permissions.sandbox orelse .low;
}

/// What of the network a run reaches.
pub const Network = union(enum) {
    none,
    /// Every host.
    all,
    /// Only these, through zigsaw's proxy (see proxy.zig).
    list: []const []const u8,
};

/// The network a run with `s` gets. `--share=network` gives it all of it;
/// `--unshare=network` takes it away, and the app's own list too, which
/// lets `--allow-host` narrow an app that has the network to a few hosts.
/// Otherwise the app's own list, with the hosts `s` adds and without those
/// it takes away.
pub fn networkOf(arena: Allocator, s: Settings, permissions: oci.Permissions) !Network {
    if (s.network orelse permissions.network) return .all;
    const none: []const []const u8 = &.{};
    const own = if (s.network == false) none else permissions.hosts orelse none;
    const list = (try Settings.merge(arena, .{ .hosts = own }, s)).hosts;
    return if (list.len == 0) .none else .{ .list = list };
}

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

/// The entries of `list` whose key none of `others` has: `key` of an entry,
/// `other_key` of one of `others`.
fn without(arena: Allocator, list: []const []const u8, others: []const []const u8, key: fn ([]const u8) []const u8, other_key: fn ([]const u8) []const u8) ![]const []const u8 {
    if (others.len == 0) return list;
    var out: std.ArrayList([]const u8) = .empty;
    for (list) |entry| {
        const named = for (others) |o| {
            if (std.os.windows.eqlIgnoreCaseWtf8(key(entry), other_key(o))) break true;
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

/// A host pattern as a key: case is ignored when keys are compared.
fn hostKey(pattern: []const u8) []const u8 {
    return if (pattern.len > 1 and pattern[pattern.len - 1] == '.') pattern[0 .. pattern.len - 1] else pattern;
}

fn envName(assignment: []const u8) []const u8 {
    return assignment[0 .. std.mem.indexOfScalar(u8, assignment, '=') orelse assignment.len];
}

/// Whose overrides: an app's, by id, or with null the store-wide ones.
fn filePath(store: Store, arena: Allocator, id: ?[]const u8) ![]u8 {
    const app = id orelse return store.path(arena, &.{"overrides.json"});
    if (!oci.isValidId(app)) return fail("\"{s}\" is not a valid app id", .{app});
    return store.path(arena, &.{ "overrides", try std.fmt.allocPrint(arena, "{s}.json", .{app}) });
}

/// The app's saved overrides, or with a null id the store-wide ones; empty
/// if there are none.
pub fn load(store: Store, arena: Allocator, id: ?[]const u8) !Settings {
    const p = try filePath(store, arena, id);
    const bytes = Io.Dir.cwd().readFileAlloc(store.io, p, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => |e| return e,
    };
    return std.json.parseFromSliceLeaky(Settings, arena, bytes, .{}) catch |err|
        fail("{s}: {t}; fix it, or remove it with `zigsaw override --reset {s}`", .{ p, err, id orelse "--global" });
}

/// What the overrides give a run of the app: its own over the store-wide
/// ones.
pub fn loadFor(store: Store, arena: Allocator, id: []const u8) !Settings {
    return Settings.merge(arena, try load(store, arena, null), try load(store, arena, id));
}

/// Replaces the app's saved overrides, or with a null id the store-wide
/// ones. Saving none deletes the file.
pub fn save(store: Store, arena: Allocator, id: ?[]const u8, s: Settings) !void {
    if (s.isEmpty()) return delete(store, arena, id);
    const tmp = try store.tmpPath(arena, "override");
    try Io.Dir.cwd().writeFile(store.io, .{ .sub_path = tmp, .data = try oci.toJson(arena, s) });
    try Io.Dir.rename(.cwd(), tmp, .cwd(), try filePath(store, arena, id), store.io);
}

pub fn delete(store: Store, arena: Allocator, id: ?[]const u8) !void {
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

test networkOf {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const t = std.testing;
    const listed: oci.Permissions = .{ .hosts = &.{ "api.github.com", "pypi.org" } };
    try t.expectEqual(Network.none, try networkOf(arena, .{}, .{}));
    try t.expectEqual(Network.all, try networkOf(arena, .{}, .{ .network = true }));
    try t.expectEqualDeep(Network{ .list = &.{ "api.github.com", "pypi.org" } }, try networkOf(arena, .{}, listed));
    // --share=network widens a list; --unshare=network takes it away.
    try t.expectEqual(Network.all, try networkOf(arena, .{ .network = true }, listed));
    try t.expectEqual(Network.none, try networkOf(arena, .{ .network = false }, listed));
    // --unshare=network with --allow-host narrows an app with the network.
    try t.expectEqualDeep(Network{ .list = &.{"example.org"} }, try networkOf(arena, .{ .network = false, .hosts = &.{"example.org"} }, .{ .network = true }));
    // --allow-host adds to the app's list, --noallow-host takes from it.
    try t.expectEqualDeep(
        Network{ .list = &.{ "pypi.org", "example.org" } },
        try networkOf(arena, .{ .hosts = &.{"example.org"}, .nohosts = &.{"API.GitHub.com."} }, listed),
    );
    try t.expectEqual(Network.none, try networkOf(arena, .{ .nohosts = &.{ "api.github.com", "pypi.org" } }, listed));
    // An override's --noallow-host, and the command line's --allow-host of it.
    const saved: Settings = .{ .nohosts = &.{"pypi.org"} };
    try t.expectEqualDeep(Network{ .list = &.{"api.github.com"} }, try networkOf(arena, saved, listed));
    try t.expectEqualDeep(
        Network{ .list = &.{ "api.github.com", "pypi.org" } },
        try networkOf(arena, try Settings.merge(arena, saved, .{ .hosts = &.{"pypi.org"} }), listed),
    );

    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try (Settings{ .hosts = &.{"a.org"}, .nohosts = &.{"*.b.org:8080"} }).format(&w);
    try t.expectEqualStrings("--allow-host=a.org --noallow-host=*.b.org:8080", w.buffered());
    // Saved only when there are some: a zigsaw before them reads the rest.
    try t.expect(std.mem.indexOf(u8, try oci.toJson(arena, Settings{ .network = true }), "hosts") == null);
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

test "Settings.merge: --volume replaces a lower layer's at the same place, and --novolume takes it away" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const global: Settings = .{ .volumes = &.{ "cache:cache", "pg:data", "D:\\x:x" } };
    const app: Settings = .{ .volumes = &.{"pg2:data:ro"}, .novolume = &.{"Cache"} };
    const s = try Settings.merge(arena, global, app);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "D:\\x:x", "pg2:data:ro" }), s.volumes);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"Cache"}), s.novolume);
    try std.testing.expect(!s.isEmpty());

    // The command line mounts something at cache again.
    const cli = try Settings.merge(arena, s, .{ .volumes = &.{"c2:cache"} });
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "D:\\x:x", "pg2:data:ro", "c2:cache" }), cli.volumes);
    try std.testing.expectEqual(0, cli.novolume.len);

    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try s.format(&w);
    try std.testing.expectEqualStrings("--volume=D:\\x:x --volume=pg2:data:ro --novolume=Cache", w.buffered());

    // A zigsaw from before volumes reads settings without them.
    const json = try oci.toJson(arena, Settings{ .network = true });
    try std.testing.expect(std.mem.indexOf(u8, json, "volume") == null);
    try std.testing.expectEqualDeep(s, try std.json.parseFromSliceLeaky(Settings, arena, try oci.toJson(arena, s), .{}));
}

test "Settings.merge: --memory and --cpus, and none and all over a layer that has them" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const global: Settings = .{ .cpus = 8 };
    const app: Settings = .{ .memory = 4 << 30 };
    const saved = try Settings.merge(arena, global, app);
    try std.testing.expectEqualDeep(process.Limits{ .memory = 4 << 30, .cpus = 8 }, saved.limits());
    // The command line takes one away, and tightens the other.
    const cli = try Settings.merge(arena, saved, .{ .memory = parseMemory("none"), .cpus = parseCpus("2") });
    try std.testing.expectEqualDeep(process.Limits{ .cpus = 2 }, cli.limits());
    try std.testing.expectEqualDeep(process.Limits{}, (try Settings.merge(arena, saved, .{ .memory = 0, .cpus = parseCpus("all") })).limits());
    try std.testing.expect(!(Settings{ .memory = 0 }).isEmpty());
    try std.testing.expect(!(Settings{ .cpus = 1 }).isEmpty());

    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try saved.format(&w);
    try std.testing.expectEqualStrings("--memory=4GB --cpus=8", w.buffered());
    w = .fixed(&buf);
    try (Settings{ .memory = 0, .cpus = 0 }).format(&w);
    try std.testing.expectEqualStrings("--memory=none --cpus=all", w.buffered());

    // Sizes print as they parse back.
    for ([_][]const u8{ "1536MB", "2GB", "512KB", "1TB", "1000" }) |text| {
        w = .fixed(&buf);
        try w.print("{f}", .{Size{ .bytes = parseMemory(text).? }});
        try std.testing.expectEqualStrings(text, w.buffered());
    }
    try std.testing.expectEqual(3 << 29, parseMemory("1536M").?);
    for ([_][]const u8{ "0", "", "lots", "-1", "2 GiB" }) |bad| try std.testing.expectEqual(null, parseMemory(bad));
    for ([_][]const u8{ "0", "", "1.5", "-1", "none" }) |bad| try std.testing.expectEqual(null, parseCpus(bad));

    // A zigsaw from before limits reads settings without them, and this
    // one reads them back.
    const json = try oci.toJson(arena, Settings{ .network = true });
    try std.testing.expect(std.mem.indexOf(u8, json, "memory") == null and std.mem.indexOf(u8, json, "cpus") == null);
    try std.testing.expectEqualDeep(saved, try std.json.parseFromSliceLeaky(Settings, arena, try oci.toJson(arena, saved), .{}));
}

test sandboxOf {
    try std.testing.expectEqual(Sandbox.low, sandboxOf(.{}, .{}));
    try std.testing.expectEqual(Sandbox.soft, sandboxOf(.{}, .{ .sandbox = .soft }));
    try std.testing.expectEqual(Sandbox.appcontainer, sandboxOf(.{ .sandbox = .appcontainer }, .{ .sandbox = .soft }));
    try std.testing.expectEqual(Sandbox.low, sandboxOf(.{ .sandbox = .low }, .{ .sandbox = .soft }));
}

test "Settings.merge: the layers, store-wide under the app's under the command line" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const global: Settings = .{ .sandbox = .soft, .env = &.{"A=global"}, .noextension = &.{"x.y"} };
    const app: Settings = .{ .env = &.{"A=app"}, .extension = &.{"x.y"} };
    const s = try Settings.merge(arena, global, app);
    // The app's own sandbox isn't saved: the store-wide one holds.
    try std.testing.expectEqual(Sandbox.soft, sandboxOf(s, .{ .sandbox = .appcontainer }));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"A=app"}), s.env);
    // The app has an extension the store-wide overrides leave out join.
    try std.testing.expectEqual(0, s.noextension.len);
    const cli = try Settings.merge(arena, s, .{ .sandbox = .appcontainer });
    try std.testing.expectEqual(Sandbox.appcontainer, sandboxOf(cli, .{}));
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
