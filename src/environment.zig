//! The environment apps and build steps run in, built from scratch rather
//! than inherited: PATH has the app's directories and the system's, the user
//! profile folders point into a directory of zigsaw's choosing, and only a few
//! host variables that describe the machine pass through.

const std = @import("std");
const Allocator = std.mem.Allocator;
const oci = @import("oci.zig");
const Context = @import("Context.zig");
const fail = Context.fail;

/// Host variables passed through unchanged. Everything else from the host
/// environment is dropped.
const passthrough = [_][]const u8{
    "SystemRoot",           "windir",                 "SystemDrive",
    "ComSpec",              "PATHEXT",                "OS",
    "NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE", "PROCESSOR_IDENTIFIER",
    "PROCESSOR_LEVEL",      "PROCESSOR_REVISION",     "USERNAME",
};

/// User profile folders, laid out like a Windows user profile under `home`.
pub const Profile = struct {
    home: []const u8,
    roaming: []const u8,
    local: []const u8,
    temp: []const u8,

    /// The profile in `<dir>\home`.
    pub fn init(arena: Allocator, dir: []const u8) !Profile {
        const home = try std.fs.path.join(arena, &.{ dir, "home" });
        const local = try std.fs.path.join(arena, &.{ home, "AppData", "Local" });
        return .{
            .home = home,
            .roaming = try std.fs.path.join(arena, &.{ home, "AppData", "Roaming" }),
            .local = local,
            .temp = try std.fs.path.join(arena, &.{ local, "Temp" }),
        };
    }
};

pub const Var = struct { name: []const u8, value: []const u8 };

pub const Spec = struct {
    /// ZIGSAW_ID.
    id: []const u8,
    profile: Profile,
    /// Put on PATH ahead of the system directories.
    path: []const []const u8,
    system_root: []const u8,
    /// Set after zigsaw's own variables, in order.
    vars: []const Var,
    /// "NAME=VALUE" from --env and overrides, set last.
    extra: []const []const u8 = &.{},
};

pub fn build(arena: Allocator, host: *const std.process.Environ.Map, spec: Spec) !std.ArrayList(Var) {
    var env: std.ArrayList(Var) = .empty;
    for (passthrough) |name| {
        if (host.get(name)) |value| try set(arena, &env, name, value);
    }

    var path: std.ArrayList(u8) = .empty;
    for (spec.path) |dir| try path.print(arena, "{s};", .{dir});
    try path.print(arena, "{0s}\\System32;{0s};{0s}\\System32\\Wbem", .{spec.system_root});
    try set(arena, &env, "PATH", path.items);

    const p = spec.profile;
    try set(arena, &env, "USERPROFILE", p.home);
    try set(arena, &env, "HOME", p.home);
    if (p.home.len > 2 and p.home[1] == ':') {
        try set(arena, &env, "HOMEDRIVE", p.home[0..2]);
        try set(arena, &env, "HOMEPATH", p.home[2..]);
    }
    try set(arena, &env, "APPDATA", p.roaming);
    try set(arena, &env, "LOCALAPPDATA", p.local);
    try set(arena, &env, "TEMP", p.temp);
    try set(arena, &env, "TMP", p.temp);
    try set(arena, &env, "ZIGSAW_ID", spec.id);

    for (spec.vars) |kv| try set(arena, &env, kv.name, kv.value);
    for (spec.extra) |assignment| {
        const eq = std.mem.indexOfScalar(u8, assignment, '=') orelse
            return fail("--env expects NAME=VALUE, got \"{s}\"", .{assignment});
        try set(arena, &env, assignment[0..eq], assignment[eq + 1 ..]);
    }
    return env;
}

/// Adds a config's variables to `env`, with their placeholders expanded.
pub fn expand(arena: Allocator, env: *std.ArrayList(Var), placeholders: oci.Placeholders, vars: std.json.ArrayHashMap([]const u8)) !void {
    var it = vars.map.iterator();
    while (it.next()) |kv| try set(arena, env, kv.key_ptr.*, try placeholders.expand(arena, kv.value_ptr.*));
}

/// Sets a variable, replacing any existing one whose name matches
/// case-insensitively, as Windows treats them.
pub fn set(arena: Allocator, env: *std.ArrayList(Var), name: []const u8, value: []const u8) !void {
    for (env.items) |*kv| {
        if (std.os.windows.eqlIgnoreCaseWtf8(kv.name, name)) {
            kv.value = value;
            return;
        }
    }
    try env.append(arena, .{ .name = name, .value = value });
}

/// Encodes "NAME=VALUE\0...\0\0" in UTF-16, sorted by name as Windows expects.
pub fn encodeBlock(arena: Allocator, vars: []Var) ![]u16 {
    std.mem.sort(Var, vars, {}, struct {
        fn lessThan(_: void, a: Var, b: Var) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan);
    var block: std.ArrayList(u16) = .empty;
    for (vars) |kv| {
        const line = try std.fmt.allocPrint(arena, "{s}={s}", .{ kv.name, kv.value });
        try block.appendSlice(arena, try std.unicode.wtf8ToWtf16LeAlloc(arena, line));
        try block.append(arena, 0);
    }
    try block.append(arena, 0);
    return block.items;
}

/// A config's PATH entries as directories: relative ones are inside
/// `placeholders.app`.
pub fn pathDirs(arena: Allocator, placeholders: oci.Placeholders, entries: []const []const u8) ![]const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    for (entries) |entry| {
        const dir = if (oci.isPlaceholderPath(entry))
            try placeholders.expand(arena, entry)
        else if (std.mem.eql(u8, entry, "."))
            try arena.dupe(u8, placeholders.app)
        else
            try std.fs.path.join(arena, &.{ placeholders.app, entry });
        std.mem.replaceScalar(u8, dir, '/', '\\');
        try dirs.append(arena, dir);
    }
    return dirs.items;
}

test encodeBlock {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var vars: std.ArrayList(Var) = .empty;
    try set(arena, &vars, "Path", "x");
    try set(arena, &vars, "ComSpec", "cmd");
    try set(arena, &vars, "PATH", "y");
    const block = try encodeBlock(arena, vars.items);
    const want = std.unicode.utf8ToUtf16LeStringLiteral("ComSpec=cmd\x00Path=y\x00\x00");
    try std.testing.expectEqualSlices(u16, want, block);
}
