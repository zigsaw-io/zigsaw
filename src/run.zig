//! `zigsaw run`: starts an installed app in a clean environment.
//!
//! Every run gets:
//! - an environment built from scratch: PATH is the app's directories, then
//!   its runtimes', then the system directories; the runtimes' variables and
//!   then the app's are set; and the user profile folders (USERPROFILE,
//!   APPDATA, LOCALAPPDATA, TEMP) point into the app's data directory;
//! - the data directory as its working directory, unless the app has the
//!   "cwd" filesystem permission;
//! - the user's folders it may use, such as Documents, linked into that
//!   profile (see folders.zig);
//! - a job object, so the whole process tree ends when the run ends.
//!
//! The `low` sandbox, the default unless the app's image asks for another,
//! runs it at low integrity, with its data directory and the paths it may
//! write labelled low, which keeps it from writing anywhere else; reading and
//! the network stay open. The `appcontainer` sandbox runs the app under its
//! AppContainer identity instead, which enforces the filesystem and network
//! permissions. The `soft` sandbox only shapes what the app sees; it enforces
//! nothing. What the enforcing sandboxes change on host paths lasts as
//! grants.zig says.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");
const acl = @import("acl.zig");
const aliases = @import("aliases.zig");
const appcontainer = @import("appcontainer.zig");
const oci = @import("oci.zig");
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const environment = @import("environment.zig");
const exports = @import("exports.zig");
const extensions = @import("extensions.zig");
const folders = @import("folders.zig");
const forward = @import("forward.zig");
const grants = @import("grants.zig");
const hkcu = @import("hkcu.zig");
const override = @import("override.zig");
const process = @import("process.zig");
const roots = @import("roots.zig");
const services = @import("services.zig");
const written = @import("written.zig");
const fail = Context.fail;
const note = Context.note;
const isWithin = grants.isWithin;

pub const Options = struct {
    id: []const u8,
    args: []const []const u8 = &.{},
    /// Runs this executable instead of the app's command. Looked up in the
    /// app's PATH directories, then in System32.
    command: ?[]const u8 = null,
    /// Host files for the app to open (`--file`): each is granted to it as
    /// that one file, to read and write, and goes after `args` as an
    /// absolute path. What opening a file from Explorer comes to.
    files: []const []const u8 = &.{},
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
    // store-wide ones, over the app's own permissions.
    const saved = try override.loadFor(ctx.store, arena, cfg.id);
    const settings = try override.Settings.merge(arena, saved, opts.settings);
    const sandbox = override.sandboxOf(settings, cfg.permissions);
    const network = settings.network orelse cfg.permissions.network;
    var host_grants: std.ArrayList(HostGrant) = .empty;
    var folder_grants: std.ArrayList(folders.Grant) = .empty;
    var cwd_granted = false;
    for (try settings.filesystemFor(arena, cfg.permissions.filesystem)) |spec| {
        const g = oci.parseFsGrant(spec) orelse return fail("invalid filesystem permission \"{s}\"", .{spec});
        switch (g.where) {
            .cwd => {
                cwd_granted = true;
                try host_grants.append(arena, .{ .path = null, .read_only = g.read_only });
            },
            .path => |p| try host_grants.append(arena, .{ .path = p, .read_only = g.read_only }),
            .folder => |f| try folder_grants.append(arena, .{ .folder = f, .read_only = g.read_only }),
            .unknown => note("warning: {s} asks for the filesystem permission \"{s}\", which this zigsaw doesn't know, and leaves out; a newer zigsaw may", .{ cfg.id, spec }),
        }
    }
    const host_cwd = try std.process.currentPathAlloc(io, arena);
    const files = try openedFiles(io, arena, host_cwd, opts.files);
    for (files) |f| try host_grants.append(arena, .{ .path = f, .read_only = false });

    // Per-app writable state, laid out like a Windows user profile.
    const run_dir: ?Store.RunDir = if (settings.ephemeral orelse false) try ctx.store.makeRunDir(arena) else null;
    defer if (run_dir) |d| d.delete(ctx.store, arena);
    const app_aliases = try syncAliases(ctx, image);
    // Installed images that plug into the app or its runtimes join the run
    // (see extensions.zig).
    const found = try extensions.find(ctx.store, arena, cfg, settings.noextension);
    for (found.skipped) |s| if (s.warn or ctx.verbose) note("note: {s} doesn't join this run: {s}", .{ s.id, s.reason });
    // One of the app's runs from here on: the last to end takes back what
    // its command line asked for, and what no longer stands.
    const runs = try grants.begin(ctx, cfg.id);
    defer grants.end(ctx, runs);
    store_lock.release(io);
    const data_dir = if (run_dir) |d| d.path else try ctx.store.path(arena, &.{ "data", cfg.id });
    const profile: environment.Profile = try .init(arena, data_dir);
    // Where file dialogs keep Quick access: only if it exists do they make
    // it, with the user's folders pinned (docs/findings.md).
    const quick_access = try std.fs.path.join(arena, &.{ profile.roaming, "Microsoft", "Windows", "Recent", "AutomaticDestinations" });
    for ([_][]const u8{ quick_access, profile.temp }) |dir| try Io.Dir.cwd().createDirPath(io, dir);

    const cwd = if (cwd_granted) host_cwd else profile.home;

    const cache_dir = try std.fs.path.join(arena, &.{ data_dir, "cache" });
    if (usesCache(cfg, found.loaded)) try Io.Dir.cwd().createDirPath(io, cache_dir);
    // Windows' roots as a file, for the programs that take only one.
    const roots_file = if (usesRoots(cfg, found.loaded)) try roots.file(ctx) else null;

    const system_root = ctx.env.get("SystemRoot") orelse "C:\\Windows";
    // The ports the run uses, its extensions' too, and where it reaches them.
    const used = try services.usedBy(arena, cfg, try extensionConfigs(arena, found.loaded));
    const targets = try services.targets(arena, used, settings.ports);
    // Where the app listens for its services, and where they're reached.
    const service_ports = try services.resolve(ctx, cfg, used, settings.ports, sandbox);
    // How it reaches other programs on this machine: in an AppContainer
    // that isn't exempt, only the ports it uses, through zigsaw.
    const reach: Loopback = if (sandbox == .appcontainer) try exemptLoopback(ctx, cfg.id, network, targets.len > 0) else .open;
    const forwarding = reach == .isolated and targets.len > 0;
    if (forwarding) try services.forwardThrough(ctx, targets, service_ports);
    const uses = try services.usePlaceholders(arena, targets);
    const runtimes = try runtimeDirs(arena, cfg, image.runtime_dirs, data_dir, cache_dir, roots_file, uses);
    const placeholders: oci.Placeholders = .{
        .app = image.deploy_dir,
        .data = data_dir,
        .cache = cache_dir,
        .roots = roots_file,
        .runtimes = runtimes.dirs,
        .services = try services.placeholders(arena, service_ports),
        .uses = uses,
    };
    // The aliases first, as in builds, then the app's directories, then each
    // runtime's.
    var app_path: std.ArrayList([]const u8) = .empty;
    if (app_aliases) |a| try app_path.append(arena, a.dir);
    try app_path.appendSlice(arena, try environment.pathDirs(arena, placeholders, cfg.path));
    for (runtimes.own, cfg.runtimes.map.values()) |p, r| try app_path.appendSlice(arena, try environment.pathDirs(arena, p, r.path));
    // Then the extensions', as runtimes the app didn't list; in them, ${app}
    // is the extension's directory.
    const ext_own = try arena.alloc(oci.Placeholders, found.loaded.len);
    for (ext_own, found.loaded) |*p, e| p.* = .{ .app = e.dir, .data = data_dir, .cache = cache_dir, .roots = roots_file, .uses = uses };
    for (ext_own, found.loaded) |p, e| try app_path.appendSlice(arena, try environment.pathDirs(arena, p, e.config.path));
    const command = try resolveCommand(io, arena, placeholders, cfg, opts.command, app_path.items, system_root);
    const args = try std.mem.concat(arena, []const u8, &.{ command.args, opts.args, files });
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
    // The runtimes' variables first, then the extensions', so the app's win;
    // those the extension points join add up instead.
    const joined = try extensions.joined(arena, found.points);
    var app_env: std.ArrayList(environment.Var) = .empty;
    for (runtimes.own, cfg.runtimes.map.values()) |p, r| try environment.expand(arena, &app_env, p, r.env, joined);
    for (ext_own, found.loaded) |p, e| try environment.expand(arena, &app_env, p, e.config.env, joined);
    try environment.expand(arena, &app_env, placeholders, cfg.env, joined);
    if (app_aliases) |a| try environment.set(arena, &app_env, "BB_OVERRIDE_APPLETS", a.names);
    const env = try environment.build(arena, ctx.env, .{
        .id = cfg.id,
        .profile = profile,
        .path = app_path.items,
        .system_root = system_root,
        .vars = app_env.items,
        .extra = settings.env,
        .proxies = network,
    });
    // The user's folders, where the app's environment says it looks for them.
    for (try folders.apply(ctx, data_dir, env.items, folder_grants.items)) |f|
        try host_grants.append(arena, .{ .path = f.path, .read_only = f.read_only });

    if (ctx.verbose) {
        note("app      {s} {s} ({s})", .{ cfg.id, cfg.version, image.ref.manifest });
        for (cfg.runtimes.map.keys(), cfg.runtimes.map.values(), image.runtime_dirs) |alias, r, dir|
            note("runtime  {s}: {s} {s} ({s})", .{ alias, r.id, r.version, dir });
        for (found.loaded) |e| note("extension {s} {s} ({s})", .{ e.id, e.version, e.dir });
        if (app_aliases) |a| note("aliases  {s} ({s})", .{ a.names, a.dir });
        if (!saved.isEmpty()) note("override {f}", .{saved});
        note("sandbox  {t}, network {s}", .{ sandbox, if (network) "on" else "off" });
        switch (reach) {
            .open => {},
            .exempt => note("loopback exempt while the app's runs go: it reaches other programs on this machine", .{}),
            .isolated => if (forwarding)
                note("loopback isolated: it reaches other programs on this machine only on the ports it uses, which zigsaw forwards", .{})
            else
                note("loopback isolated: it reaches no other program on this machine", .{}),
        }
        for (service_ports) |s| if (s.listen == s.port)
            note("service  {s}: localhost:{d}", .{ s.service.name, s.port })
        else
            note("service  {s}: localhost:{d}, which the app listens for on {d} in its container", .{ s.service.name, s.port, s.listen });
        for (targets) |t| if (t.connect == t.port)
            note("uses     {s}: localhost:{d}", .{ t.use.name, t.port })
        else
            note("uses     {s}: localhost:{d}, which zigsaw forwards from {d} in its container", .{ t.use.name, t.port, t.connect });
        note("exe      {s}", .{exe});
        if (command.batch) note("script   {s}", .{command.exe});
        note("cmdline  {s}", .{command_line});
        note("cwd      {s}", .{cwd});
        for (env.items) |kv| note("env      {s}={s}", .{ kv.name, kv.value });
    }

    // In an AppContainer, the services this run serves are published by the
    // relay, from sockets zigsaw listens on outside it. zigsaw's copies close
    // when the run ends, and so the ports are free again.
    const published = if (sandbox == .appcontainer) try services.publish(ctx, cfg, service_ports, opts.command) else null;
    defer if (published) |p| p.close();
    // The relay also forwards the ports the run uses, if it has to.
    const forwards: ?forward.Forwards = if (forwarding) try forwardsOf(arena, targets) else null;
    const relay_exe = if (published != null or forwards != null) try services.relayExe(ctx) else null;

    // Windows starts a program whose file is labelled low at low integrity,
    // whoever starts it: this soft run would go at low, unasked.
    if (sandbox == .soft) if (acl.effectiveLabel(arena, exe) catch null) |rid| if (rid <= win32.SECURITY_MANDATORY_LOW_RID)
        note("warning: {s} is labelled low integrity, so Windows starts it, and this run, at low integrity; `zigsaw repair` takes back a label zigsaw gave a folder it's in", .{exe});

    const own: grants.Own = try .of(ctx);
    var security: ?win32.SECURITY_CAPABILITIES = null;
    var token: ?win32.HANDLE = null;
    switch (sandbox) {
        .soft => if (ctx.verbose) {
            for (host_grants.items) |g| if (g.path) |p|
                note("note: soft sandbox doesn't enforce filesystem permissions; {s} is as reachable as any other path", .{p});
        },
        .low => token = try setUpLow(ctx, cfg.id, .{
            .data_dir = data_dir,
            .host_cwd = host_cwd,
            .grants = host_grants.items,
            .network = network,
            .own = own,
        }),
        .appcontainer => security = try setUpAppContainer(ctx, cfg.id, .{
            .deploy_dir = image.deploy_dir,
            .runtime_dirs = try std.mem.concat(arena, []const u8, &.{ image.runtime_dirs, try extensionDirs(arena, found.loaded) }),
            .alias_dir = if (app_aliases) |a| a.dir else null,
            .relay_dir = if (relay_exe) |r| std.fs.path.dirname(r).? else null,
            .roots_file = roots_file,
            .data_dir = data_dir,
            .local_app_data = profile.local,
            .host_cwd = host_cwd,
            .grants = host_grants.items,
            .network = network,
            .own = own,
        }),
    }
    // The programs the app's runs wrote are medium between runs, and low
    // during low and AppContainer ones, so that they may write them (see
    // written.zig).
    if (sandbox != .soft) try written.relabel(ctx, cfg.id);

    // The keys the app keeps in HKCU, there for the run (see hkcu.zig), and
    // taken back before an --ephemeral run's data directory goes.
    const keys = try hkcu.enter(ctx, cfg.id, cfg.registry, data_dir, switch (sandbox) {
        .soft => .none,
        .low => .low,
        .appcontainer => .{ .capability = try appcontainer.appCapability(arena, cfg.id) },
    }, run_dir == null);
    defer if (keys) |k| hkcu.leave(ctx, k);
    if (ctx.verbose) if (cfg.registry) |r| note("registry {s} (kept in {s}\\registry)", .{ try std.mem.join(arena, ", ", r), data_dir });

    const env_block = try environment.encodeBlock(arena, env.items);
    // The relay starts first, in the app's job: the app may connect to the
    // ports it forwards at once.
    const job = try process.newJob();
    if (relay_exe) |r| startRelay(ctx, cfg.id, job, r, published, forwards, security.?, env_block);
    const watcher = written.Watcher.start(arena, ctx.io, try watchedDirs(arena, sandbox, host_grants.items, host_cwd, data_dir, ctx.env.get("USERPROFILE"), own));
    const child: process.Child = .{
        .job = job,
        .process = try process.startIn(arena, job, .{
            .exe = exe,
            .command_line = command_line,
            .env_block = env_block,
            .cwd = cwd,
            .security = if (security) |*s| s else null,
            .token = token,
            // Set by a shim that a shortcut started (see shim.zig).
            .shortcut = ctx.env.get("ZIGSAW_SHORTCUT"),
        }),
    };
    const code = try child.wait();
    if (watcher) |w| written.finish(ctx, cfg.id, w);
    // Commands the run installed, as `npm install -g` does, get shims. An
    // --ephemeral run's are gone with its data directory.
    if (run_dir == null and exports.hasCommandDirs(cfg)) exports.syncAfterRun(ctx, cfg.id);
    return code;
}

/// Starts the relay in the app's container and job, with the sockets of the
/// services the run publishes (see services.zig), and the pipes of the
/// ports it forwards (see forward.zig), which it listens on before this
/// returns. It holds only the app's own capability: runs in one container
/// reach each other without a network one. If it can't start, the app runs
/// on, without them.
fn startRelay(
    ctx: *Context,
    id: []const u8,
    job: win32.HANDLE,
    exe: []const u8,
    published: ?services.Published,
    forwards: ?forward.Forwards,
    app: win32.SECURITY_CAPABILITIES,
    env_block: []const u16,
) void {
    const arena = ctx.arena;
    var own = app;
    own.CapabilityCount = 1;
    var handles: std.ArrayList(win32.HANDLE) = .empty;
    var args: std.ArrayList([]const u8) = .empty;
    if (published) |p| {
        for (p.sockets) |s| handles.append(arena, @ptrFromInt(s)) catch return;
        args.appendSlice(arena, p.args) catch return;
    }
    if (forwards) |f| {
        handles.appendSlice(arena, &.{ f.relay_in, f.relay_out }) catch return;
        args.appendSlice(arena, f.args(arena) catch return) catch return;
    }
    const command_line = process.buildCommandLine(arena, exe, args.items) catch return;
    const relay = process.startIn(arena, job, .{
        .exe = exe,
        .command_line = command_line,
        .env_block = env_block,
        .cwd = std.fs.path.dirname(exe).?,
        .security = &own,
        .creation_flags = win32.DETACHED_PROCESS,
        .stdio = .{ null, null, null },
        .inherit = handles.items,
    }) catch {
        if (forwards) |f| f.close();
        note("note: the relay of {s}'s run didn't start, so it {s} this run", .{
            id,
            if (published != null and forwards != null)
                "publishes no service, and reaches none of the ports it uses,"
            else if (published != null)
                "publishes no service"
            else
                "reaches none of the ports it uses",
        });
        return;
    };
    if (forwards) |f| if (!f.serve(relay))
        note("note: the relay of {s}'s run couldn't listen for the ports it uses, so it doesn't reach them this run", .{id});
    _ = win32.CloseHandle(relay);
}

/// The forwards of the ports a run uses, to the ports the relay listens on.
fn forwardsOf(arena: Allocator, targets: []const services.Target) !forward.Forwards {
    const ports = try arena.alloc(u16, targets.len);
    const connect = try arena.alloc(u16, targets.len);
    for (ports, connect, targets) |*p, *c, t| {
        p.* = t.port;
        c.* = t.connect;
    }
    return forward.Forwards.open(arena, ports, connect);
}

/// A host path the run may use, which the enforcing sandboxes grant: null
/// for the working directory zigsaw was started from.
const HostGrant = struct { path: ?[]const u8, read_only: bool };

/// The absolute paths of the files `--file` names, which may be relative to
/// the directory zigsaw was started from; the app's own working directory
/// may be another. Each has to be a file that exists: there's nothing to
/// grant otherwise, and a directory is `--filesystem`'s to give.
fn openedFiles(io: Io, arena: Allocator, host_cwd: []const u8, named: []const []const u8) ![]const []const u8 {
    const files = try arena.alloc([]const u8, named.len);
    for (files, named) |*file, name| {
        const p = try std.fs.path.resolve(arena, &.{ host_cwd, name });
        const stat = Io.Dir.cwd().statFile(io, p, .{}) catch |err| switch (err) {
            error.FileNotFound => return fail("--file={s}: there's no such file", .{name}),
            else => return fail("--file={s}: {t}", .{ name, err }),
        };
        if (stat.kind == .directory)
            return fail("--file={s} is a directory; --filesystem={s} grants one", .{ name, p });
        file.* = p;
    }
    return files;
}

// ---------------------------------------------------------------------------
// Aliases

const AppAliases = struct {
    /// The store's aliases\<id>\, first on the run's PATH.
    dir: []const u8,
    /// For BB_OVERRIDE_APPLETS.
    names: []const u8,
};

/// Brings the shims of the app's aliases, and its runtimes', up to date in
/// the store (see aliases.zig); null if it has none. Runs with the store
/// lock held, so prune doesn't delete them meanwhile.
fn syncAliases(ctx: *Context, image: Store.Image) !?AppAliases {
    const arena = ctx.arena;
    const cfg = image.config;
    const dir = try ctx.store.aliasDir(arena, cfg.id);
    const resolved = try aliases.resolve(ctx, try aliasProviders(arena, image), .skip);
    if (resolved.len == 0) {
        // Left by a version of the app that had some.
        if (try Store.exists(ctx.io, dir)) {
            const l = try ctx.store.lockAliases(arena, cfg.id);
            defer l.release(ctx.io);
            Store.deleteTree(ctx.io, arena, dir) catch {};
        }
        return null;
    }
    const l = try ctx.store.lockAliases(arena, cfg.id);
    defer l.release(ctx.io);
    const start = ctx.now();
    const changed = try aliases.sync(ctx, dir, resolved);
    if (changed > 0) ctx.timed(start, "update {d} alias file(s)", .{changed});
    return .{ .dir = dir, .names = try aliases.names(arena, resolved) };
}

/// The app first, then its runtimes in order: the first to have an alias
/// of a name wins it. The app's aliases may run its runtimes' files.
fn aliasProviders(arena: Allocator, image: Store.Image) ![]const aliases.Provider {
    const cfg = image.config;
    const runtimes = try arena.alloc(oci.Placeholders.Dir, image.runtime_dirs.len);
    for (runtimes, cfg.runtimes.map.keys(), image.runtime_dirs) |*r, alias, dir| r.* = .{ .alias = alias, .path = dir };
    var out: std.ArrayList(aliases.Provider) = .empty;
    try out.append(arena, .{ .id = cfg.id, .dir = image.deploy_dir, .aliases = cfg.aliases, .runtimes = runtimes });
    for (cfg.runtimes.map.values(), image.runtime_dirs) |r, dir| try out.append(arena, .{ .id = r.id, .dir = dir, .aliases = r.aliases });
    return out.items;
}

test aliasProviders {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const digest = "sha256:" ++ "a" ** 64;
    var cfg: oci.AppConfig = .{ .id = "app", .version = "1", .command = "x.exe" };
    try cfg.runtimes.map.put(arena, "b", .{ .id = "rt.b", .version = "1", .image = digest, .layer = digest });
    try cfg.runtimes.map.put(arena, "a", .{ .id = "rt.a", .version = "1", .image = digest, .layer = digest });
    const image: Store.Image = .{
        .ref = .{ .id = "app", .version = "1", .manifest = digest },
        .manifest = .{ .config = .{ .mediaType = "", .digest = digest, .size = 0 }, .layers = &.{} },
        .config = cfg,
        .deploy_dir = "D:\\app",
        .runtime_dirs = &.{ "D:\\b", "D:\\a" },
    };
    const p = try aliasProviders(arena, image);
    try std.testing.expectEqual(3, p.len);
    for ([_][]const u8{ "app", "rt.b", "rt.a" }, [_][]const u8{ "D:\\app", "D:\\b", "D:\\a" }, p) |id, dir, got| {
        try std.testing.expectEqualStrings(id, got.id);
        try std.testing.expectEqualStrings(dir, got.dir);
    }
    // The app's aliases may name its runtimes; theirs have only themselves.
    try std.testing.expectEqual(2, p[0].runtimes.len);
    try std.testing.expectEqualStrings("b", p[0].runtimes[0].alias);
    try std.testing.expectEqualStrings("D:\\b", p[0].runtimes[0].path);
    try std.testing.expectEqualStrings("a", p[0].runtimes[1].alias);
    try std.testing.expectEqualStrings("D:\\a", p[0].runtimes[1].path);
    try std.testing.expectEqual(0, p[1].runtimes.len);
}

// ---------------------------------------------------------------------------
// AppContainer

const AppContainerSetup = struct {
    deploy_dir: []const u8,
    runtime_dirs: []const []const u8,
    /// The app's alias shims, if it has aliases.
    alias_dir: ?[]const u8,
    /// The store's copies of the relay, if the run publishes services.
    relay_dir: ?[]const u8,
    /// The store's file of Windows' roots, if the run names it. Granted
    /// itself, not its directory: a file renamed into a directory keeps the
    /// ACL it had, and the directory's grant reaches only the files there
    /// when it's made.
    roots_file: ?[]const u8,
    data_dir: []const u8,
    /// The run's LOCALAPPDATA, in its data directory.
    local_app_data: []const u8,
    host_cwd: []const u8,
    grants: []const HostGrant,
    network: bool,
    own: grants.Own,
};

fn setUpAppContainer(ctx: *Context, id: []const u8, setup: AppContainerSetup) !win32.SECURITY_CAPABILITIES {
    const arena = ctx.arena;
    const profile = try appcontainer.Profile.ensure(arena, id);
    // In an AppContainer, Windows' temporary directory isn't TEMP but the
    // container's own, under LOCALAPPDATA, which is in the data directory
    // here. Programs that ask Windows for it (GetTempPath2), as Go's and
    // Rust's standard libraries do, need it to exist.
    try Io.Dir.cwd().createDirPath(ctx.io, try std.fs.path.join(arena, &.{ setup.local_app_data, "Packages", profile.name, "AC", "Temp" }));

    const Grant = struct { path: []const u8, access: acl.Access, host: bool, cwd: bool = false };
    var wanted: std.ArrayList(Grant) = .empty;
    try wanted.append(arena, .{ .path = setup.deploy_dir, .access = .read_execute, .host = false });
    for (setup.runtime_dirs) |dir| try wanted.append(arena, .{ .path = dir, .access = .read_execute, .host = false });
    if (setup.alias_dir) |dir| try wanted.append(arena, .{ .path = dir, .access = .read_execute, .host = false });
    if (setup.relay_dir) |dir| try wanted.append(arena, .{ .path = dir, .access = .read_execute, .host = false });
    if (setup.roots_file) |file| try wanted.append(arena, .{ .path = file, .access = .read_execute, .host = false });
    try wanted.append(arena, .{ .path = setup.data_dir, .access = .full, .host = false });
    for (setup.grants) |g| {
        const p = g.path orelse setup.host_cwd;
        var access: acl.Access = if (g.read_only) .read_execute else .full;
        if (access == .full and !isWithin(p, setup.data_dir)) if (setup.own.refusal(p)) |why| {
            const elsewhere = if (setup.own.contains(p)) "elsewhere" else "inside it";
            if (g.path != null)
                return fail("--sandbox=appcontainer won't let {s} write {s}: {s}, and the app could then change every app's files; grant a directory {s}, or read-only access (:ro)", .{ id, p, why, elsewhere });
            note("warning: {s} is read-only for this run, as {s}: run the app from a folder {s} to let it write there, or with --sandbox=soft", .{ p, why, elsewhere });
            access = .read_execute;
        };
        try wanted.append(arena, .{ .path = p, .access = access, .host = true, .cwd = g.path == null });
    }

    // Host paths last, under grants.lock (see grants.zig).
    var changes: ?Store.Lock = null;
    defer if (changes) |l| l.release(ctx.io);
    for (wanted.items) |w| {
        // Granted with the data directory: a shortcut starts the app in its
        // home.
        if (w.host and isWithin(w.path, setup.data_dir)) continue;
        // Record host grants before changing anything, so that they're
        // undone even if a later step fails.
        if (w.host) {
            if (changes == null) changes = try ctx.store.lockGrantChanges(arena);
            try ctx.store.recordGrant(arena, id, .{ .kind = .appcontainer, .path = w.path });
            if (w.cwd) try ctx.store.recordCwdGrant(arena, id, w.path);
        }
        // Access goes to the app's capability. What zigsaw granted the
        // profile's package SID before goes in the same change: on the host,
        // the app's own; in the store, any app's.
        const old: acl.Revoke = if (w.host) .{ .sids = &.{profile.sid} } else .package_sids;
        const start = Io.Timestamp.now(ctx.io, .awake);
        const changed = try acl.grant(arena, w.path, profile.capability, w.access, old);
        if (changed and (w.host or ctx.verbose)) {
            note("granted {s} {t} access to {s} ({d} ms)", .{
                profile.name, w.access, w.path, start.untilNow(ctx.io, .awake).toMilliseconds(),
            });
        }
    }

    var caps: std.ArrayList(win32.SID_AND_ATTRIBUTES) = .empty;
    try caps.append(arena, .{ .Sid = profile.capability, .Attributes = win32.SE_GROUP_ENABLED });
    if (setup.network) {
        for ([_][]const u8{ appcontainer.capability.internet_client, appcontainer.capability.private_network_client_server }) |s| {
            try caps.append(arena, .{ .Sid = try appcontainer.sidFromString(arena, s), .Attributes = win32.SE_GROUP_ENABLED });
        }
    }
    return .{
        .AppContainerSid = profile.sid,
        .Capabilities = caps.items.ptr,
        .CapabilityCount = @intCast(caps.items.len),
    };
}

/// How a run reaches other programs on this machine, over the loopback.
const Loopback = enum {
    /// As any program does: outside an AppContainer.
    open,
    /// Its container is exempt from loopback isolation while the app's
    /// runs go.
    exempt,
    /// It reaches no program outside its container.
    isolated,
};

/// Exempts the app's container from loopback isolation for a run with the
/// network (see appcontainer.loopback), unless ZIGSAW_LOOPBACK_EXEMPTION is
/// 0 or Windows refuses. Recorded first, as host grants are, so that the
/// app's last run to end takes it back (see grants.zig). An exemption you
/// made yourself isn't recorded, and stays. `uses` if the run uses ports,
/// which zigsaw then forwards.
fn exemptLoopback(ctx: *Context, id: []const u8, network: bool, uses: bool) !Loopback {
    if (!network) return .isolated;
    if (ctx.env.get("ZIGSAW_LOOPBACK_EXEMPTION")) |v| if (std.mem.eql(u8, v, "0")) return .isolated;
    const arena = ctx.arena;
    const sid = try appcontainer.packageSid(arena, id);
    const changes = try ctx.store.lockGrantChanges(arena);
    defer changes.release(ctx.io);
    const recorded = for (try ctx.store.readGrants(arena, id)) |g| {
        if (g.kind == .loopback) break true;
    } else false;
    if (!recorded and (appcontainer.loopback.isExempt(sid) orelse false)) return .exempt;
    if (!recorded) try ctx.store.recordGrant(arena, id, .loopback);
    const start = Io.Timestamp.now(ctx.io, .awake);
    switch (try appcontainer.loopback.exempt(arena, sid)) {
        .added => if (ctx.verbose) note("exempted {s} from loopback isolation ({d} ms)", .{
            try appcontainer.profileName(arena, id), start.untilNow(ctx.io, .awake).toMilliseconds(),
        }),
        .already => {},
        .refused => |code| {
            if (!recorded) try ctx.store.forgetGrant(arena, id, .loopback);
            note("note: Windows didn't let zigsaw exempt {s} from loopback isolation (error {d}), so this run reaches {s} on this machine", .{
                try appcontainer.profileName(arena, id),
                code,
                if (uses) "other programs only on the ports it uses, through zigsaw," else "no other program",
            });
            return .isolated;
        },
    }
    return .exempt;
}

// ---------------------------------------------------------------------------
// Low integrity

const LowSetup = struct {
    data_dir: []const u8,
    host_cwd: []const u8,
    grants: []const HostGrant,
    network: bool,
    own: grants.Own,
};

/// Labels the data directory and the host paths the app may write low
/// integrity, and returns the token the app runs with.
fn setUpLow(ctx: *Context, id: []const u8, setup: LowSetup) !win32.HANDLE {
    const arena = ctx.arena;
    // Before iteration 9, AppContainer runs granted the app's package SID
    // access, which keeps low-integrity processes out (see appcontainer.zig).
    // The app's next AppContainer run grants its capability instead.
    const package = try appcontainer.packageSid(arena, id);
    _ = try acl.revoke(arena, setup.data_dir, .package_sids);
    // Once for each app, but a large data directory takes seconds, as an
    // app's first low run after zigsaw 0.54 made low the default may.
    const data_start = Io.Timestamp.now(ctx.io, .awake);
    if (try acl.labelLow(arena, setup.data_dir)) {
        const ms = data_start.untilNow(ctx.io, .awake).toMilliseconds();
        if (ms >= 1000 or ctx.verbose) note("labelled {s} low integrity ({d} ms)", .{ setup.data_dir, ms });
    }

    // Host paths change under grants.lock (see grants.zig).
    const changes: ?Store.Lock = if (setup.grants.len > 0) try ctx.store.lockGrantChanges(arena) else null;
    defer if (changes) |l| l.release(ctx.io);
    for (setup.grants) |g| {
        const p = g.path orelse setup.host_cwd;
        // Labelled with the data directory: a shortcut starts the app in its
        // home.
        if (isWithin(p, setup.data_dir)) continue;
        _ = try acl.revoke(arena, p, .{ .sids = &.{package} });
        // Low integrity reads what the user can.
        if (g.read_only) continue;
        if (labelRefusal(p, ctx.env.get("USERPROFILE"), setup.own)) |why| {
            // Inside zigsaw's store or folder, no folder in it will do.
            const elsewhere = if (setup.own.contains(p)) "elsewhere" else "inside it";
            // A working directory is wherever you are: the app runs, and may
            // only read it.
            if (g.path == null) {
                note("warning: {s} is read-only for this run, as {s}: run the app from a folder {s} to let it write there, or with --sandbox=soft", .{ p, why, elsewhere });
                continue;
            }
            // The app's own permissions can't be taken back, only added to.
            return fail("--sandbox=low won't label {s} low integrity: {s}, and every low-integrity process could then write anywhere in it; grant a directory {s}, or read-only access (:ro)", .{ p, why, elsewhere });
        }
        const label: Store.Grant = .{ .kind = .low, .path = p };
        if (try acl.ownLabel(arena, p)) |rid| if (rid <= win32.SECURITY_MANDATORY_LOW_RID) {
            // Labelled for another app's runs: this app's need it too, so
            // removing that app keeps it. A label that zigsaw didn't give
            // stays when the app goes.
            if (try ctx.store.grantedToOthers(arena, id, label)) try recordLabel(ctx, id, label, g.path == null);
            continue;
        };
        // Recorded first, so that it's undone even if a later step fails.
        try recordLabel(ctx, id, label, g.path == null);
        const start = Io.Timestamp.now(ctx.io, .awake);
        if (try acl.labelLow(arena, p))
            note("labelled {s} low integrity ({d} ms)", .{ p, start.untilNow(ctx.io, .awake).toMilliseconds() });
    }
    if (ctx.verbose) {
        note("note: low sandbox doesn't keep the app from reading what you can", .{});
        if (!setup.network) note("note: low sandbox doesn't enforce network permissions", .{});
    }
    try acl.letChildrenQueryUs(arena);
    return process.lowIntegrityToken(arena);
}

fn recordLabel(ctx: *Context, id: []const u8, label: Store.Grant, cwd: bool) !void {
    try ctx.store.recordGrant(ctx.arena, id, label);
    if (cwd) try ctx.store.recordCwdGrant(ctx.arena, id, label.path);
}

/// The host folders the run may write, where the programs it writes come out
/// labelled low (see written.zig): under soft, only those labelled low
/// already. Not its data directory, nor what the run may only read after
/// all.
fn watchedDirs(
    arena: Allocator,
    sandbox: override.Sandbox,
    host_grants: []const HostGrant,
    host_cwd: []const u8,
    data_dir: []const u8,
    user_profile: ?[]const u8,
    own: grants.Own,
) ![]const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    next: for (host_grants) |g| {
        if (g.read_only) continue;
        const p = g.path orelse host_cwd;
        if (isWithin(p, data_dir)) continue;
        const read_only = switch (sandbox) {
            .low => labelRefusal(p, user_profile, own) != null,
            .appcontainer => own.refusal(p) != null,
            .soft => own.refusal(p) != null or
                ((acl.effectiveLabel(arena, p) catch null) orelse continue) > win32.SECURITY_MANDATORY_LOW_RID,
        };
        if (read_only) continue;
        const attrs = win32.GetFileAttributesW(try win32.wide(arena, p));
        if (attrs == win32.INVALID_FILE_ATTRIBUTES or attrs & win32.FILE_ATTRIBUTE_DIRECTORY == 0) continue;
        for (dirs.items) |d| if (isWithin(p, d)) continue :next;
        try dirs.append(arena, p);
    }
    return dirs.items;
}

/// Why zigsaw won't label `path` low for a run, if it won't: it's a drive's
/// root, the user's profile, or a directory the profile is in; or zigsaw's
/// store or folder is in it, or it's in them (see grants.Own).
fn labelRefusal(path: []const u8, user_profile: ?[]const u8, own: grants.Own) ?[]const u8 {
    if (std.fs.path.dirnameWindows(std.mem.trimEnd(u8, path, "\\/")) == null) return "it's the root of a drive";
    if (user_profile) |profile| if (isWithin(profile, path))
        return if (isWithin(path, profile)) "it's your user profile" else "your user profile is in it";
    return own.refusal(path);
}

test labelRefusal {
    const home = "C:\\Users\\Ann";
    const own: grants.Own = .{ .store = "C:\\Users\\Ann\\AppData\\Local\\zigsaw", .self_dir = "C:\\Users\\Ann\\AppData\\Local\\zigsaw\\bin" };
    for ([_][]const u8{ "C:\\", "C:", "D:\\", "d:/", "\\\\server\\share\\" }) |root|
        try std.testing.expectEqualStrings("it's the root of a drive", labelRefusal(root, home, own).?);
    try std.testing.expectEqualStrings("it's your user profile", labelRefusal("c:\\users\\ann\\", home, own).?);
    try std.testing.expectEqualStrings("it's your user profile", labelRefusal("C:/Users/Ann", home ++ "\\", own).?);
    try std.testing.expectEqualStrings("your user profile is in it", labelRefusal("C:\\Users", home, own).?);
    try std.testing.expectEqualStrings("zigsaw's store is in it", labelRefusal("C:\\Users\\Ann\\AppData", home, own).?);
    for ([_][]const u8{ "C:\\Users\\Ann\\src", "C:\\Users\\Anna", "C:\\Users\\An", "D:\\src", "\\\\server\\share\\dir" }) |ok|
        try std.testing.expectEqual(null, labelRefusal(ok, home, own));
    try std.testing.expectEqualStrings("zigsaw's store is in it", labelRefusal("C:\\Users", null, own).?);
}

// ---------------------------------------------------------------------------
// Command resolution and command lines

const Runtimes = struct {
    /// Each runtime's directory, by alias, for the app's placeholders.
    dirs: []const oci.Placeholders.Dir,
    /// The placeholders of each runtime's own entries: ${app} is the
    /// runtime's directory, and ${data}, ${cache} and ${uses:x} are the
    /// app's.
    own: []const oci.Placeholders,
};

fn runtimeDirs(
    arena: Allocator,
    cfg: oci.AppConfig,
    dirs: []const []const u8,
    data_dir: []const u8,
    cache_dir: []const u8,
    roots_file: ?[]const u8,
    uses: []const oci.Placeholders.UsedPort,
) !Runtimes {
    const named = try arena.alloc(oci.Placeholders.Dir, dirs.len);
    const own = try arena.alloc(oci.Placeholders, dirs.len);
    for (cfg.runtimes.map.keys(), dirs, named, own) |alias, dir, *n, *o| {
        n.* = .{ .alias = alias, .path = dir };
        o.* = .{ .app = dir, .data = data_dir, .cache = cache_dir, .roots = roots_file, .uses = uses };
    }
    return .{ .dirs = named, .own = own };
}

/// Whether the app's entries or its runtimes' use ${cache}, which is then
/// created before the run.
fn usesCache(cfg: oci.AppConfig, exts: []const extensions.Extension) bool {
    if (oci.usesCache(cfg.path, cfg.env)) return true;
    for (cfg.runtimes.map.values()) |r| if (oci.usesCache(r.path, r.env)) return true;
    for (exts) |e| if (oci.usesCache(e.config.path, e.config.env)) return true;
    return false;
}

/// Whether the app's variables, arguments or exports, or its runtimes' or
/// extensions' variables, name ${roots}.
fn usesRoots(cfg: oci.AppConfig, exts: []const extensions.Extension) bool {
    if (oci.usesRoots(cfg.env, cfg.args)) return true;
    for (cfg.exports.map.values()) |e| if (oci.usesRoots(.{}, e.args)) return true;
    for (cfg.runtimes.map.values()) |r| if (oci.usesRoots(r.env, &.{})) return true;
    for (exts) |e| if (oci.usesRoots(e.config.env, e.config.args)) return true;
    return false;
}

fn extensionConfigs(arena: Allocator, exts: []const extensions.Extension) ![]const oci.AppConfig {
    const configs = try arena.alloc(oci.AppConfig, exts.len);
    for (configs, exts) |*c, e| c.* = e.config;
    return configs;
}

fn extensionDirs(arena: Allocator, exts: []const extensions.Extension) ![]const []const u8 {
    const dirs = try arena.alloc([]const u8, exts.len);
    for (dirs, exts) |*d, e| d.* = e.dir;
    return dirs;
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
        return .init(try placeholders.commandPath(arena, config.command), try expandAll(arena, placeholders, config.args));

    var exported = config.exports.map.iterator();
    while (exported.next()) |e| {
        if (!std.ascii.eqlIgnoreCase(e.key_ptr.*, name)) continue;
        return .init(try placeholders.commandPath(arena, e.value_ptr.command), try expandAll(arena, placeholders, e.value_ptr.args));
    }

    const resolved = try findCommand(io, arena, deploy_dir, name, app_path, system_root) orelse {
        // A relative path is the app's; one of yours is absolute.
        if (std.mem.indexOfAny(u8, name, "/\\") != null and !std.fs.path.isAbsolute(name))
            return fail("command \"{s}\" is not a file in the app; for a program of yours, give its absolute path (e.g. --command=%CD%\\{s})", .{ name, std.fs.path.basename(name) });
        return fail("command \"{s}\" is not an export of the app, or an executable or batch file in it or in System32", .{name});
    };
    return .init(resolved, &.{});
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
