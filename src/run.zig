//! `zigsaw run`: starts an installed app in a clean environment.
//!
//! Every run gets:
//! - an environment built from scratch: PATH is the app's directories, then
//!   its runtimes', then the system directories; the runtimes' variables and
//!   then the app's are set; and the user profile folders (USERPROFILE,
//!   APPDATA, LOCALAPPDATA, TEMP) point into the app's data directory;
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
const environment = @import("environment.zig");
const exports = @import("exports.zig");
const override = @import("override.zig");
const process = @import("process.zig");
const fail = Context.fail;
const note = Context.note;

pub const Options = struct {
    id: []const u8,
    args: []const []const u8 = &.{},
    /// Runs this executable instead of the app's command. Looked up in the
    /// app's PATH directories, then in System32.
    command: ?[]const u8 = null,
    /// From the command line. They go over the app's saved overrides.
    settings: override.Settings = .{},
};

/// Runs the app and returns its exit code.
pub fn run(ctx: *Context, opts: Options) !u32 {
    const io = ctx.io;
    const arena = ctx.arena;
    // Held while preparing the run, not while the app runs. The deployment
    // and any ephemeral data directory stay locked as in use until the end.
    // (On errors, zigsaw exits and that releases every lock.)
    const store_lock = try ctx.store.lock(arena, .shared);
    const image = try ctx.store.loadImage(arena, opts.id);
    const cfg = image.config;

    // Effective settings: the command line over the app's overrides, over the
    // app's own permissions.
    const saved = try override.load(ctx.store, arena, cfg.id);
    const settings = try override.Settings.merge(arena, saved, opts.settings);
    const sandbox = settings.sandbox orelse .soft;
    const network = settings.network orelse cfg.permissions.network;
    var grants: std.ArrayList(oci.FsGrant) = .empty;
    for ([_][]const []const u8{ cfg.permissions.filesystem, settings.filesystem }) |specs| {
        for (specs) |spec| try grants.append(arena, oci.parseFsGrant(spec) orelse
            return fail("invalid filesystem permission \"{s}\"", .{spec}));
    }
    var cwd_granted = false;
    for (grants.items) |g| {
        if (g.path == null) cwd_granted = true;
    }

    // Per-app writable state, laid out like a Windows user profile.
    const run_dir: ?Store.RunDir = if (settings.ephemeral orelse false) try ctx.store.makeRunDir(arena) else null;
    defer if (run_dir) |d| d.delete(ctx.store, arena);
    store_lock.release(io);
    const data_dir = if (run_dir) |d| d.path else try ctx.store.path(arena, &.{ "data", cfg.id });
    const profile: environment.Profile = try .init(arena, data_dir);
    for ([_][]const u8{ profile.roaming, profile.temp }) |dir| try Io.Dir.cwd().createDirPath(io, dir);

    const host_cwd = try std.process.currentPathAlloc(io, arena);
    const cwd = if (cwd_granted) host_cwd else profile.home;

    const cache_dir = try std.fs.path.join(arena, &.{ data_dir, "cache" });
    if (usesCache(cfg)) try Io.Dir.cwd().createDirPath(io, cache_dir);

    const system_root = ctx.env.get("SystemRoot") orelse "C:\\Windows";
    const runtimes = try runtimeDirs(arena, cfg, image.runtime_dirs, data_dir, cache_dir);
    const placeholders: oci.Placeholders = .{ .app = image.deploy_dir, .data = data_dir, .cache = cache_dir, .runtimes = runtimes.dirs };
    // The app's directories first, then each runtime's.
    var app_path: std.ArrayList([]const u8) = .empty;
    try app_path.appendSlice(arena, try environment.pathDirs(arena, placeholders, cfg.path));
    for (runtimes.own, cfg.runtimes.map.values()) |p, r| try app_path.appendSlice(arena, try environment.pathDirs(arena, p, r.path));
    const command = try resolveCommand(io, arena, placeholders, cfg, opts.command, app_path.items, system_root);
    const args = try std.mem.concat(arena, []const u8, &.{ command.args, opts.args });
    // Batch files run through cmd.exe; System32's, not ComSpec's.
    const exe = if (command.batch) try std.fmt.allocPrint(arena, "{s}\\System32\\cmd.exe", .{system_root}) else command.exe;
    const command_line = if (command.batch)
        process.buildBatchCommandLine(arena, exe, command.exe, args) catch |err| switch (err) {
            error.InvalidBatchArgument => return fail("{s} is a batch file, and cmd.exe can't pass it an argument with a line break or a NUL character", .{command.exe}),
            error.InvalidBatchScript => return fail("{s} can't be run as a batch file", .{command.exe}),
            error.OutOfMemory => |e| return e,
        }
    else
        try process.buildCommandLine(arena, exe, args);
    // The runtimes' variables first, so the app's win.
    var app_env: std.ArrayList(environment.Var) = .empty;
    for (runtimes.own, cfg.runtimes.map.values()) |p, r| try environment.expand(arena, &app_env, p, r.env);
    try environment.expand(arena, &app_env, placeholders, cfg.env);
    const env = try environment.build(arena, ctx.env, .{
        .id = cfg.id,
        .profile = profile,
        .path = app_path.items,
        .system_root = system_root,
        .vars = app_env.items,
        .extra = settings.env,
    });

    if (ctx.verbose) {
        note("app      {s} {s} ({s})", .{ cfg.id, cfg.version, image.ref.manifest });
        for (cfg.runtimes.map.keys(), cfg.runtimes.map.values(), image.runtime_dirs) |alias, r, dir|
            note("runtime  {s}: {s} {s} ({s})", .{ alias, r.id, r.version, dir });
        if (!saved.isEmpty()) note("override {f}", .{saved});
        note("sandbox  {t}, network {s}", .{ sandbox, if (network) "on" else "off" });
        note("exe      {s}", .{exe});
        if (command.batch) note("script   {s}", .{command.exe});
        note("cmdline  {s}", .{command_line});
        note("cwd      {s}", .{cwd});
        for (env.items) |kv| note("env      {s}={s}", .{ kv.name, kv.value });
    }

    var security: ?win32.SECURITY_CAPABILITIES = null;
    switch (sandbox) {
        .soft => if (ctx.verbose) {
            for (grants.items) |g| if (g.path) |p|
                note("note: soft sandbox doesn't enforce filesystem permissions; {s} is as reachable as any other path", .{p});
        },
        .appcontainer => security = try setUpAppContainer(ctx, cfg.id, .{
            .deploy_dir = image.deploy_dir,
            .runtime_dirs = image.runtime_dirs,
            .data_dir = data_dir,
            .local_app_data = profile.local,
            .host_cwd = host_cwd,
            .grants = grants.items,
            .network = network,
        }),
    }

    const code = try process.spawn(arena, .{
        .exe = exe,
        .command_line = command_line,
        .env_block = try environment.encodeBlock(arena, env.items),
        .cwd = cwd,
        .security = if (security) |*s| s else null,
    });
    // Commands the run installed, as `npm install -g` does, get shims. An
    // --ephemeral run's are gone with its data directory.
    if (run_dir == null and exports.hasCommandDirs(cfg)) exports.syncAfterRun(ctx, cfg.id);
    return code;
}

// ---------------------------------------------------------------------------
// AppContainer

const AppContainerSetup = struct {
    deploy_dir: []const u8,
    runtime_dirs: []const []const u8,
    data_dir: []const u8,
    /// The run's LOCALAPPDATA, in its data directory.
    local_app_data: []const u8,
    host_cwd: []const u8,
    grants: []const oci.FsGrant,
    network: bool,
};

fn setUpAppContainer(ctx: *Context, id: []const u8, setup: AppContainerSetup) !win32.SECURITY_CAPABILITIES {
    const arena = ctx.arena;
    const profile = try appcontainer.Profile.ensure(arena, id);
    // In an AppContainer, Windows' temporary directory isn't TEMP but the
    // container's own, under LOCALAPPDATA, which is in the data directory
    // here. Programs that ask Windows for it (GetTempPath2), as Go's and
    // Rust's standard libraries do, need it to exist.
    try Io.Dir.cwd().createDirPath(ctx.io, try std.fs.path.join(arena, &.{ setup.local_app_data, "Packages", profile.name, "AC", "Temp" }));

    const Grant = struct { path: []const u8, access: acl.Access, host: bool };
    var wanted: std.ArrayList(Grant) = .empty;
    try wanted.append(arena, .{ .path = setup.deploy_dir, .access = .read_execute, .host = false });
    for (setup.runtime_dirs) |dir| try wanted.append(arena, .{ .path = dir, .access = .read_execute, .host = false });
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

const Runtimes = struct {
    /// Each runtime's directory, by alias, for the app's placeholders.
    dirs: []const oci.Placeholders.Dir,
    /// The placeholders of each runtime's own entries: ${app} is the
    /// runtime's directory, and ${data} and ${cache} are the app's.
    own: []const oci.Placeholders,
};

fn runtimeDirs(arena: Allocator, cfg: oci.AppConfig, dirs: []const []const u8, data_dir: []const u8, cache_dir: []const u8) !Runtimes {
    const named = try arena.alloc(oci.Placeholders.Dir, dirs.len);
    const own = try arena.alloc(oci.Placeholders, dirs.len);
    for (cfg.runtimes.map.keys(), dirs, named, own) |alias, dir, *n, *o| {
        n.* = .{ .alias = alias, .path = dir };
        o.* = .{ .app = dir, .data = data_dir, .cache = cache_dir };
    }
    return .{ .dirs = named, .own = own };
}

/// Whether the app's entries or its runtimes' use ${cache}, which is then
/// created before the run.
fn usesCache(cfg: oci.AppConfig) bool {
    if (oci.usesCache(cfg.path, cfg.env)) return true;
    for (cfg.runtimes.map.values()) |r| if (oci.usesCache(r.path, r.env)) return true;
    return false;
}

const Command = struct {
    /// The executable, or the batch file.
    exe: []const u8,
    /// Arguments that go before the caller's.
    args: []const []const u8 = &.{},
    /// A .bat or .cmd file, which runs through cmd.exe.
    batch: bool = false,

    fn init(exe: []const u8, args: []const []const u8) Command {
        const ext = std.fs.path.extension(exe);
        return .{
            .exe = exe,
            .args = args,
            .batch = std.ascii.eqlIgnoreCase(ext, ".bat") or std.ascii.eqlIgnoreCase(ext, ".cmd"),
        };
    }
};

/// What to run: the app's command, or with `--command`, one of the app's
/// exports or an executable from the app or System32.
fn resolveCommand(
    io: Io,
    arena: Allocator,
    placeholders: oci.Placeholders,
    config: oci.AppConfig,
    requested: ?[]const u8,
    app_path: []const []const u8,
    system_root: []const u8,
) !Command {
    const deploy_dir = placeholders.app;
    const name = requested orelse
        return .init(try commandPath(arena, placeholders, config.command), try expandAll(arena, placeholders, config.args));

    var exported = config.exports.map.iterator();
    while (exported.next()) |e| {
        if (!std.ascii.eqlIgnoreCase(e.key_ptr.*, name)) continue;
        return .init(try commandPath(arena, placeholders, e.value_ptr.command), try expandAll(arena, placeholders, e.value_ptr.args));
    }

    const resolved = try findCommand(io, arena, deploy_dir, name, app_path, system_root) orelse
        return fail("command \"{s}\" is not an export of the app, or an executable or batch file in it or in System32", .{name});
    return .init(resolved, &.{});
}

/// A config's command: relative to the app's directory, or starting with a
/// placeholder.
fn commandPath(arena: Allocator, placeholders: oci.Placeholders, command: []const u8) ![]u8 {
    const p = if (oci.isPlaceholderPath(command))
        try placeholders.expand(arena, command)
    else
        try std.fs.path.join(arena, &.{ placeholders.app, command });
    std.mem.replaceScalar(u8, p, '/', '\\');
    return p;
}

fn expandAll(arena: Allocator, placeholders: oci.Placeholders, templates: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, templates.len);
    for (out, templates) |*arg, template| arg.* = try placeholders.expand(arena, template);
    return out;
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
