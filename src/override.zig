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

pub const Sandbox = enum { soft, appcontainer };

/// Run options that can be given on the command line or saved as overrides.
/// Null or empty fields leave the choice to the layer below: the command line
/// goes over overrides, and overrides over the app's own permissions.
pub const Settings = struct {
    sandbox: ?Sandbox = null,
    network: ?bool = null,
    ephemeral: ?bool = null,
    /// Filesystem permissions granted on top of the app's own.
    filesystem: []const []const u8 = &.{},
    /// "NAME=VALUE" environment variables, set over the app's own.
    env: []const []const u8 = &.{},

    pub fn isEmpty(s: Settings) bool {
        return s.sandbox == null and s.network == null and s.ephemeral == null and
            s.filesystem.len == 0 and s.env.len == 0;
    }

    /// `upper` over `lower`. For the lists, an entry of `upper` replaces
    /// `lower`'s for the same path or variable name.
    pub fn merge(arena: Allocator, lower: Settings, upper: Settings) !Settings {
        return .{
            .sandbox = upper.sandbox orelse lower.sandbox,
            .network = upper.network orelse lower.network,
            .ephemeral = upper.ephemeral orelse lower.ephemeral,
            .filesystem = try mergeList(arena, lower.filesystem, upper.filesystem, grantPath),
            .env = try mergeList(arena, lower.env, upper.env, envName),
        };
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
        for (s.env) |e| {
            try w.print("{s}--env={s}", .{ sep, e });
            sep = " ";
        }
    }
};

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

test "Settings round-trips through JSON" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s: Settings = .{ .sandbox = .appcontainer, .network = true, .filesystem = &.{"D:\\src:ro"} };
    const json = try oci.toJson(arena, s);
    try std.testing.expectEqualDeep(s, try std.json.parseFromSliceLeaky(Settings, arena, json, .{}));
}
