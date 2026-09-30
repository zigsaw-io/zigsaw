//! `zigsaw run`: starts an installed app in a clean environment.
//!
//! Every run gets:
//! - an environment built from scratch: PATH is the app's directories plus the
//!   system directories, and the user profile folders (USERPROFILE, APPDATA,
//!   LOCALAPPDATA, TEMP) point into the app's data directory;
//! - the data directory as its working directory, unless the app has the
//!   "cwd" filesystem permission;
//! - a job object, so the whole process tree ends when the run ends.
//!
//! The `appcontainer` sandbox additionally runs the app under its AppContainer
//! identity, which enforces the filesystem and network permissions. The `soft`
//! sandbox only shapes what the app sees; it enforces nothing.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");
const acl = @import("acl.zig");
const appcontainer = @import("appcontainer.zig");
const oci = @import("oci.zig");
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const process = @import("process.zig");
const fail = Context.fail;
const note = Context.note;

pub const Sandbox = enum { soft, appcontainer };

pub const Options = struct {
    id: []const u8,
    args: []const []const u8 = &.{},
    /// Runs this executable instead of the app's command. Looked up in the
    /// app's PATH directories, then in System32.
    command: ?[]const u8 = null,
    sandbox: Sandbox = .soft,
    /// Uses a fresh data directory that is deleted after the run.
    ephemeral: bool = false,
    /// Filesystem permissions granted on top of the app's own.
    filesystem: []const []const u8 = &.{},
    /// Overrides the app's network permission.
    network: ?bool = null,
    /// Extra "NAME=VALUE" environment variables, applied last.
    env: []const []const u8 = &.{},
};

/// Host variables passed through unchanged. Everything else from the host
/// environment is dropped.
const passthrough_env = [_][]const u8{
    "SystemRoot",           "windir",                 "SystemDrive",
    "ComSpec",              "PATHEXT",                "OS",
    "NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE", "PROCESSOR_IDENTIFIER",
    "PROCESSOR_LEVEL",      "PROCESSOR_REVISION",     "USERNAME",
};

/// Runs the app and returns its exit code.
pub fn run(ctx: *Context, opts: Options) !u32 {
    const io = ctx.io;
    const arena = ctx.arena;
    const image = try ctx.store.loadImage(arena, opts.id);
    const cfg = image.config;

    // Effective permissions: the app's own plus command-line grants.
    const network = opts.network orelse cfg.permissions.network;
    var grants: std.ArrayList(oci.FsGrant) = .empty;
    for ([_][]const []const u8{ cfg.permissions.filesystem, opts.filesystem }) |specs| {
        for (specs) |spec| try grants.append(arena, oci.parseFsGrant(spec) orelse
            return fail("invalid filesystem permission \"{s}\"", .{spec}));
    }
    var cwd_granted = false;
    for (grants.items) |g| {
        if (g.path == null) cwd_granted = true;
    }

    // Per-app writable state, laid out like a Windows user profile.
    const data_dir = if (opts.ephemeral)
        try ctx.store.makeTmpDir(arena, "run")
    else
        try ctx.store.path(arena, &.{ "data", cfg.id });
    defer if (opts.ephemeral) Io.Dir.cwd().deleteTree(io, data_dir) catch {};
    const profile: Profile = try .init(arena, data_dir);
    for ([_][]const u8{ profile.roaming, profile.temp }) |dir| try Io.Dir.cwd().createDirPath(io, dir);

    const host_cwd = try std.process.currentPathAlloc(io, arena);
    const cwd = if (cwd_granted) host_cwd else profile.home;

    const system_root = ctx.env.get("SystemRoot") orelse "C:\\Windows";
    const app_path = try appPathDirs(arena, image.deploy_dir, cfg.path);
    const command = try resolveCommand(io, arena, image.deploy_dir, cfg, opts.command, app_path, system_root);
    const exe = command.exe;
    const command_line = try process.buildCommandLine(arena, exe, try std.mem.concat(arena, []const u8, &.{ command.args, opts.args }));
    const env = try buildEnv(arena, ctx.env, .{
        .id = cfg.id,
        .profile = profile,
        .app_path = app_path,
        .system_root = system_root,
        .app_env = cfg.env,
        .overrides = opts.env,
    });

    if (ctx.verbose) {
        note("app      {s} {s} ({s})", .{ cfg.id, cfg.version, image.ref.manifest });
        note("sandbox  {t}, network {s}", .{ opts.sandbox, if (network) "on" else "off" });
        note("exe      {s}", .{exe});
        note("cmdline  {s}", .{command_line});
        note("cwd      {s}", .{cwd});
        for (env.items) |kv| note("env      {s}={s}", .{ kv.name, kv.value });
    }

    var security: ?win32.SECURITY_CAPABILITIES = null;
    switch (opts.sandbox) {
        .soft => if (ctx.verbose) {
            for (grants.items) |g| if (g.path) |p|
                note("note: soft sandbox doesn't enforce filesystem permissions; {s} is as reachable as any other path", .{p});
        },
        .appcontainer => security = try setUpAppContainer(ctx, cfg.id, .{
            .deploy_dir = image.deploy_dir,
            .data_dir = data_dir,
            .host_cwd = host_cwd,
            .grants = grants.items,
            .network = network,
        }),
    }

    return process.spawn(arena, .{
        .exe = exe,
        .command_line = command_line,
        .env_block = try encodeEnvBlock(arena, env.items),
        .cwd = cwd,
        .security = if (security) |*s| s else null,
    });
}

const Profile = struct {
    home: []const u8,
    roaming: []const u8,
    local: []const u8,
    temp: []const u8,

    fn init(arena: Allocator, data_dir: []const u8) !Profile {
        const home = try std.fs.path.join(arena, &.{ data_dir, "home" });
        const local = try std.fs.path.join(arena, &.{ home, "AppData", "Local" });
        return .{
            .home = home,
            .roaming = try std.fs.path.join(arena, &.{ home, "AppData", "Roaming" }),
            .local = local,
            .temp = try std.fs.path.join(arena, &.{ local, "Temp" }),
        };
    }
};

// ---------------------------------------------------------------------------
// AppContainer

const AppContainerSetup = struct {
    deploy_dir: []const u8,
    data_dir: []const u8,
    host_cwd: []const u8,
    grants: []const oci.FsGrant,
    network: bool,
};

fn setUpAppContainer(ctx: *Context, id: []const u8, setup: AppContainerSetup) !win32.SECURITY_CAPABILITIES {
    const arena = ctx.arena;
    const profile = try appcontainer.Profile.ensure(arena, id);

    const Grant = struct { path: []const u8, access: acl.Access, host: bool };
    var wanted: std.ArrayList(Grant) = .empty;
    try wanted.append(arena, .{ .path = setup.deploy_dir, .access = .read_execute, .host = false });
    try wanted.append(arena, .{ .path = setup.data_dir, .access = .full, .host = false });
    for (setup.grants) |g| try wanted.append(arena, .{
        .path = g.path orelse setup.host_cwd,
        .access = if (g.read_only) .read_execute else .full,
        .host = true,
    });

    for (wanted.items) |w| {
        // Record host grants before changing anything, so `zigsaw rm` can undo
        // them even if a later step fails.
        if (w.host) try ctx.store.recordGrant(arena, id, w.path);
        const start = Io.Timestamp.now(ctx.io, .awake);
        const changed = try acl.grant(arena, w.path, profile.sid, w.access);
        if (changed and (w.host or ctx.verbose)) {
            note("granted {s} {t} access to {s} ({d} ms)", .{
                profile.name, w.access, w.path, start.untilNow(ctx.io, .awake).toMilliseconds(),
            });
        }
    }

    var caps: std.ArrayList(win32.SID_AND_ATTRIBUTES) = .empty;
    if (setup.network) {
        for ([_][]const u8{ appcontainer.capability.internet_client, appcontainer.capability.private_network_client_server }) |s| {
            try caps.append(arena, .{ .Sid = try appcontainer.sidFromString(arena, s), .Attributes = win32.SE_GROUP_ENABLED });
        }
    }
    return .{
        .AppContainerSid = profile.sid,
        .Capabilities = if (caps.items.len > 0) caps.items.ptr else null,
        .CapabilityCount = @intCast(caps.items.len),
    };
}

// ---------------------------------------------------------------------------
// Command resolution and command lines

fn appPathDirs(arena: Allocator, deploy_dir: []const u8, entries: []const []const u8) ![]const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    for (entries) |entry| {
        const dir = if (std.mem.eql(u8, entry, "."))
            try arena.dupe(u8, deploy_dir)
        else
            try std.fs.path.join(arena, &.{ deploy_dir, entry });
        std.mem.replaceScalar(u8, dir, '/', '\\');
        try dirs.append(arena, dir);
    }
    return dirs.items;
}

const Command = struct {
    exe: []const u8,
    /// Arguments that go before the caller's.
    args: []const []const u8 = &.{},
};

/// What to run: the app's command, or with `--command`, one of the app's
/// exports or an executable from the app or System32.
fn resolveCommand(
    io: Io,
    arena: Allocator,
    deploy_dir: []const u8,
    config: oci.AppConfig,
    override: ?[]const u8,
    app_path: []const []const u8,
    system_root: []const u8,
) !Command {
    const name = override orelse return .{ .exe = try appFile(arena, deploy_dir, config.command) };

    var exported = config.exports.map.iterator();
    while (exported.next()) |e| {
        if (!std.ascii.eqlIgnoreCase(e.key_ptr.*, name)) continue;
        const args = try arena.alloc([]const u8, e.value_ptr.args.len);
        for (args, e.value_ptr.args) |*arg, template| {
            arg.* = try std.mem.replaceOwned(u8, arena, template, "${app}", deploy_dir);
        }
        return .{ .exe = try appFile(arena, deploy_dir, e.value_ptr.command), .args = args };
    }

    const resolved = try findCommand(io, arena, deploy_dir, name, app_path, system_root) orelse
        return fail("command \"{s}\" is not an export of the app, or an executable in it or in System32", .{name});
    const ext = std.fs.path.extension(resolved);
    if (std.ascii.eqlIgnoreCase(ext, ".bat") or std.ascii.eqlIgnoreCase(ext, ".cmd"))
        return fail("{s} is a batch file, which zigsaw can't start directly yet; run it through cmd instead: --command=cmd <app> /c {s} ...", .{ resolved, name });
    return .{ .exe = resolved };
}

fn appFile(arena: Allocator, deploy_dir: []const u8, rel: []const u8) ![]u8 {
    const p = try std.fs.path.join(arena, &.{ deploy_dir, rel });
    std.mem.replaceScalar(u8, p, '/', '\\');
    return p;
}

fn findCommand(
    io: Io,
    arena: Allocator,
    deploy_dir: []const u8,
    name: []const u8,
    app_path: []const []const u8,
    system_root: []const u8,
) !?[]const u8 {
    if (std.fs.path.isAbsolute(name)) return if (try Store.exists(io, name)) name else null;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) {
        const p = try std.fs.path.join(arena, &.{ deploy_dir, name });
        return if (try Store.exists(io, p)) p else null;
    }

    var dirs: std.ArrayList([]const u8) = .empty;
    try dirs.appendSlice(arena, app_path);
    try dirs.append(arena, try std.fs.path.join(arena, &.{ system_root, "System32" }));
    const exts: []const []const u8 = if (std.fs.path.extension(name).len == 0)
        &.{ ".exe", ".com", ".cmd", ".bat" }
    else
        &.{""};
    for (dirs.items) |dir| for (exts) |ext| {
        const p = try std.fmt.allocPrint(arena, "{s}\\{s}{s}", .{ dir, name, ext });
        if (try Store.exists(io, p)) return p;
    };
    return null;
}

// ---------------------------------------------------------------------------
// Environment

const EnvVar = struct { name: []const u8, value: []const u8 };

const EnvSpec = struct {
    id: []const u8,
    profile: Profile,
    app_path: []const []const u8,
    system_root: []const u8,
    app_env: std.json.ArrayHashMap([]const u8),
    overrides: []const []const u8,
};

fn buildEnv(arena: Allocator, host: *const std.process.Environ.Map, spec: EnvSpec) !std.ArrayList(EnvVar) {
    var env: std.ArrayList(EnvVar) = .empty;
    for (passthrough_env) |name| {
        if (host.get(name)) |value| try setEnv(arena, &env, name, value);
    }

    var path: std.ArrayList(u8) = .empty;
    for (spec.app_path) |dir| try path.print(arena, "{s};", .{dir});
    try path.print(arena, "{0s}\\System32;{0s};{0s}\\System32\\Wbem", .{spec.system_root});
    try setEnv(arena, &env, "PATH", path.items);

    const p = spec.profile;
    try setEnv(arena, &env, "USERPROFILE", p.home);
    try setEnv(arena, &env, "HOME", p.home);
    if (p.home.len > 2 and p.home[1] == ':') {
        try setEnv(arena, &env, "HOMEDRIVE", p.home[0..2]);
        try setEnv(arena, &env, "HOMEPATH", p.home[2..]);
    }
    try setEnv(arena, &env, "APPDATA", p.roaming);
    try setEnv(arena, &env, "LOCALAPPDATA", p.local);
    try setEnv(arena, &env, "TEMP", p.temp);
    try setEnv(arena, &env, "TMP", p.temp);
    try setEnv(arena, &env, "ZIGSAW_ID", spec.id);

    var it = spec.app_env.map.iterator();
    while (it.next()) |kv| try setEnv(arena, &env, kv.key_ptr.*, kv.value_ptr.*);
    for (spec.overrides) |assignment| {
        const eq = std.mem.indexOfScalar(u8, assignment, '=') orelse
            return fail("--env expects NAME=VALUE, got \"{s}\"", .{assignment});
        try setEnv(arena, &env, assignment[0..eq], assignment[eq + 1 ..]);
    }
    return env;
}

/// Sets a variable, replacing any existing one whose name matches
/// case-insensitively, as Windows treats them.
fn setEnv(arena: Allocator, env: *std.ArrayList(EnvVar), name: []const u8, value: []const u8) !void {
    for (env.items) |*kv| {
        if (std.os.windows.eqlIgnoreCaseWtf8(kv.name, name)) {
            kv.value = value;
            return;
        }
    }
    try env.append(arena, .{ .name = name, .value = value });
}

/// Encodes "NAME=VALUE\0...\0\0" in UTF-16, sorted by name as Windows expects.
fn encodeEnvBlock(arena: Allocator, vars: []EnvVar) ![]u16 {
    std.mem.sort(EnvVar, vars, {}, struct {
        fn lessThan(_: void, a: EnvVar, b: EnvVar) bool {
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

test encodeEnvBlock {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var vars: std.ArrayList(EnvVar) = .empty;
    try setEnv(arena, &vars, "Path", "x");
    try setEnv(arena, &vars, "ComSpec", "cmd");
    try setEnv(arena, &vars, "PATH", "y");
    const block = try encodeEnvBlock(arena, vars.items);
    const want = std.unicode.utf8ToUtf16LeStringLiteral("ComSpec=cmd\x00Path=y\x00\x00");
    try std.testing.expectEqualSlices(u16, want, block);
}
