const std = @import("std");
const Io = std.Io;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const acl = @import("acl.zig");
const appcontainer = @import("appcontainer.zig");
const builder = @import("builder.zig");
const credentials = @import("credentials.zig");
const exports = @import("exports.zig");
const install = @import("install.zig");
const oci = @import("oci.zig");
const override = @import("override.zig");
const prune = @import("prune.zig");
const remote = @import("remote.zig");
const runtime = @import("run.zig");
const update = @import("update.zig");
const win32 = @import("win32.zig");
const fail = Context.fail;
const note = Context.note;

const usage =
    \\usage: zigsaw [-v|--verbose] <command> [options]
    \\
    \\commands:
    \\  build [--rebuild] [--keep-build-dir] <recipe.json>
    \\                                  build an app from a recipe, install it and its commands;
    \\                                  --rebuild builds even if an earlier build had the same inputs
    \\  pull <image>                    install an app and its commands from a registry
    \\  push [--sources] <app-id> [<image>]
    \\                                  publish an installed app to a registry; --sources also
    \\                                  keeps the files it was built from next to it
    \\  login [--username=<user>] [--password-stdin] <registry>
    \\                                  check and save a login for a registry
    \\  logout <registry>               delete a registry's saved login
    \\  run [options] <app-id> [args]   run an installed app
    \\  list                            list installed apps and their commands
    \\  override [options] <app-id>     save run options that every run of the app gets;
    \\                                  --show shows them, --reset removes them
    \\  update [<app-id>...]            rebuild or re-pull apps from where they came from
    \\  rm [--delete-data] <app-id>     uninstall an app and its commands
    \\  prune [--dry-run] [--downloads] [--data]
    \\                                  delete what no installed app needs; also cached
    \\                                  downloads and tool caches, and the data of
    \\                                  uninstalled apps
    \\
    \\An image is <registry>/<repository>[:tag][@digest], e.g. ghcr.io/owner/node:24.21.0,
    \\or <app-id>[:tag][@digest] for the app's image in the default registry, e.g.
    \\org.nodejs.node for ghcr.io/zigsaw-io/org.nodejs.node. ZIGSAW_REGISTRY changes the
    \\default registry. push goes to the app's image there unless given one, and tags
    \\with the app's version unless given a tag.
    \\
    \\Pushing, and pulling private images, needs a login. login saves one per registry in
    \\Windows Credential Manager; --password-stdin reads the password from stdin. For CI
    \\and scripts, ZIGSAW_REGISTRY_USERNAME and ZIGSAW_REGISTRY_PASSWORD are used instead,
    \\but only for the default registry.
    \\
    \\run options (override takes them too, except --command):
    \\  --command=<name>                run one of the app's exported commands, or another
    \\                                  executable or batch file from the app or System32
    \\  --sandbox=soft|appcontainer     soft (default) shapes the environment; appcontainer
    \\                                  also enforces the app's permissions
    \\  --filesystem=<cwd|path>[:ro]    grant access to a host location
    \\  --share=network                 allow network access
    \\  --unshare=network               deny network access
    \\  --env=NAME=VALUE                set an environment variable
    \\  --ephemeral                     use a fresh data directory, deleted afterwards
    \\
    \\Data lives in %ZIGSAW_HOME%, or %LOCALAPPDATA%\zigsaw when that isn't set.
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var ctx: Context = .{
        .io = init.io,
        .gpa = init.gpa,
        .arena = arena,
        .env = init.environ_map,
        .store = undefined,
    };

    const exit_code = dispatch(&ctx, args[1..]) catch |err| switch (err) {
        // Already reported to the user.
        error.Failed => 1,
        // Unexpected; let std print the error and its trace.
        else => return err,
    };
    // ExitProcess rather than std.process.exit: Windows exit codes are 32-bit
    // (e.g. 0xC0000005), and `run` passes the app's through unchanged.
    win32.ExitProcess(exit_code);
}

fn dispatch(ctx: *Context, all_args: []const [:0]const u8) !u32 {
    var args = all_args;
    while (args.len > 0 and isFlag(args[0], "verbose")) : (args = args[1..]) ctx.verbose = true;
    if (args.len == 0) return usageError();

    const command = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, command, "help") or isFlag(command, "help")) {
        Context.printStderr("{s}", .{usage});
        return 0;
    }
    // Logins don't touch the store.
    if (std.mem.eql(u8, command, "login")) {
        try credentials.login(ctx, try parseLoginOptions(rest));
        return 0;
    }
    if (std.mem.eql(u8, command, "logout")) {
        if (rest.len != 1 or std.mem.startsWith(u8, rest[0], "-")) return usageError();
        try credentials.logout(ctx, rest[0]);
        return 0;
    }

    ctx.store = try .open(ctx.io, ctx.arena, ctx.env);
    ctx.store.verbose = ctx.verbose;
    // Commands hold the store lock shared, and prune exclusively; see Store.zig.
    // `run` takes it itself, and `list` only reads.
    if (std.mem.eql(u8, command, "build")) {
        var opts: builder.Options = .{};
        var recipe_path: ?[]const u8 = null;
        for (rest) |arg| {
            if (isFlag(arg, "keep-build-dir")) {
                opts.keep_build_dir = true;
            } else if (isFlag(arg, "rebuild")) {
                opts.rebuild = true;
            } else if (recipe_path == null and !std.mem.startsWith(u8, arg, "-")) {
                recipe_path = arg;
            } else return usageError();
        }
        _ = try ctx.store.lock(ctx.arena, .shared);
        try install.install(ctx, try builder.build(ctx, recipe_path orelse return usageError(), opts));
        return 0;
    }
    if (std.mem.eql(u8, command, "pull")) {
        if (rest.len != 1) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        try install.install(ctx, (try remote.fetch(ctx, rest[0], .{})).?);
        return 0;
    }
    if (std.mem.eql(u8, command, "push")) {
        var opts: remote.PushOptions = .{};
        var names: std.ArrayList([]const u8) = .empty;
        for (rest) |arg| {
            if (isFlag(arg, "sources")) {
                opts.sources = true;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                try names.append(ctx.arena, arg);
            } else return usageError();
        }
        if (names.items.len != 1 and names.items.len != 2) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        try remote.push(ctx, names.items[0], if (names.items.len == 2) names.items[1] else null, opts);
        return 0;
    }
    if (std.mem.eql(u8, command, "run")) return runtime.run(ctx, try parseRunOptions(ctx, rest));
    if (std.mem.eql(u8, command, "list")) {
        if (rest.len != 0) return usageError();
        try list(ctx);
        return 0;
    }
    if (std.mem.eql(u8, command, "override")) {
        _ = try ctx.store.lock(ctx.arena, .shared);
        try overrideApp(ctx, rest);
        return 0;
    }
    if (std.mem.eql(u8, command, "update")) {
        for (rest) |arg| if (std.mem.startsWith(u8, arg, "-")) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        return update.update(ctx, @ptrCast(rest));
    }
    if (std.mem.eql(u8, command, "rm")) {
        var delete_data = false;
        var id: ?[]const u8 = null;
        for (rest) |arg| {
            if (isFlag(arg, "delete-data")) {
                delete_data = true;
            } else if (id == null and !std.mem.startsWith(u8, arg, "-")) {
                id = arg;
            } else return usageError();
        }
        _ = try ctx.store.lock(ctx.arena, .shared);
        try remove(ctx, id orelse return usageError(), delete_data);
        return 0;
    }
    if (std.mem.eql(u8, command, "prune")) {
        var opts: prune.Options = .{};
        for (rest) |arg| {
            if (isFlag(arg, "dry-run")) {
                opts.dry_run = true;
            } else if (isFlag(arg, "downloads")) {
                opts.downloads = true;
            } else if (isFlag(arg, "data")) {
                opts.data = true;
            } else return usageError();
        }
        _ = try ctx.store.lock(ctx.arena, .exclusive);
        try prune.prune(ctx, opts);
        return 0;
    }
    return usageError();
}

fn usageError() error{Failed} {
    Context.printStderr("{s}", .{usage});
    return error.Failed;
}

fn isFlag(arg: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, name, "verbose") and std.mem.eql(u8, arg, "-v")) return true;
    return arg.len == name.len + 2 and std.mem.startsWith(u8, arg, "--") and std.mem.eql(u8, arg[2..], name);
}

/// A "--name=value" option. "--name value" works too, except for flags,
/// which never take a value.
const Option = struct {
    name: []const u8,
    value: ?[]const u8,

    /// Reads the option at `args[i.*]`, moving `i` past a separate value.
    fn read(args: []const [:0]const u8, i: *usize, flags: []const []const u8) !Option {
        const arg = args[i.*];
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const name = arg[2 .. eq orelse arg.len];
        if (eq) |e| return .{ .name = name, .value = arg[e + 1 ..] };
        for (flags) |flag| if (std.mem.eql(u8, name, flag)) return .{ .name = name, .value = null };
        i.* += 1;
        if (i.* == args.len) return fail("--{s} needs a value", .{name});
        return .{ .name = name, .value = args[i.*] };
    }
};

/// Collects the run options that `run` and `override` share.
const SettingsParser = struct {
    settings: override.Settings = .{},
    filesystem: std.ArrayList([]const u8) = .empty,
    env: std.ArrayList([]const u8) = .empty,

    const flags = [_][]const u8{"ephemeral"};

    /// Applies `opt`, or returns false if it isn't one of these options.
    fn apply(p: *SettingsParser, arena: std.mem.Allocator, opt: Option) !bool {
        const name = opt.name;
        if (std.mem.eql(u8, name, "ephemeral")) {
            if (opt.value != null) return fail("--ephemeral takes no value", .{});
            p.settings.ephemeral = true;
            return true;
        }
        const value = opt.value orelse return false;
        if (std.mem.eql(u8, name, "sandbox")) {
            p.settings.sandbox = std.meta.stringToEnum(override.Sandbox, value) orelse
                return fail("--sandbox must be soft or appcontainer", .{});
        } else if (std.mem.eql(u8, name, "filesystem")) {
            if (oci.parseFsGrant(value) == null)
                return fail("--filesystem must be cwd or an absolute path, optionally with :ro; got \"{s}\"", .{value});
            try p.filesystem.append(arena, value);
        } else if (std.mem.eql(u8, name, "share") or std.mem.eql(u8, name, "unshare")) {
            if (!std.mem.eql(u8, value, "network")) return fail("--{s} only supports network", .{name});
            p.settings.network = std.mem.eql(u8, name, "share");
        } else if (std.mem.eql(u8, name, "env")) {
            if (std.mem.indexOfScalar(u8, value, '=') == null) return fail("--env expects NAME=VALUE, got \"{s}\"", .{value});
            try p.env.append(arena, value);
        } else return false;
        return true;
    }

    fn finish(p: *const SettingsParser) override.Settings {
        var s = p.settings;
        s.filesystem = p.filesystem.items;
        s.env = p.env.items;
        return s;
    }
};

/// Options go before the app id, like `flatpak run`; everything after the id
/// belongs to the app. "--" also ends zigsaw's options.
fn parseRunOptions(ctx: *Context, args: []const [:0]const u8) !runtime.Options {
    var opts: runtime.Options = .{ .id = undefined };
    var settings: SettingsParser = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        if (!std.mem.startsWith(u8, args[i], "--")) break;
        const opt = try Option.read(args, &i, &(SettingsParser.flags ++ [_][]const u8{"verbose"}));
        if (std.mem.eql(u8, opt.name, "verbose") and opt.value == null) {
            ctx.verbose = true;
            ctx.store.verbose = true;
        } else if (std.mem.eql(u8, opt.name, "command") and opt.value != null) {
            opts.command = opt.value;
        } else if (!try settings.apply(ctx.arena, opt)) {
            return fail("unknown run option --{s}", .{opt.name});
        }
    }
    if (i == args.len) return usageError();

    opts.id = args[i];
    opts.args = @ptrCast(args[i + 1 ..]);
    opts.settings = settings.finish();
    return opts;
}

fn parseLoginOptions(args: []const [:0]const u8) !credentials.LoginOptions {
    var opts: credentials.LoginOptions = .{ .registry = undefined };
    var registry: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!std.mem.startsWith(u8, args[i], "--")) {
            if (registry != null) return usageError();
            registry = args[i];
            continue;
        }
        const opt = try Option.read(args, &i, &.{"password-stdin"});
        if (std.mem.eql(u8, opt.name, "password-stdin") and opt.value == null) {
            opts.password_stdin = true;
        } else if (std.mem.eql(u8, opt.name, "username") and opt.value != null) {
            opts.username = opt.value;
        } else {
            return fail("unknown login option --{s}", .{opt.name});
        }
    }
    opts.registry = registry orelse return usageError();
    return opts;
}

/// `zigsaw override [options] <app-id>`: saves run options that every run of
/// the app gets. New options are added to the saved ones; `--reset` removes
/// them all. Without options, or with `--show`, prints what's saved.
fn overrideApp(ctx: *Context, args: []const [:0]const u8) !void {
    const arena = ctx.arena;
    var settings: SettingsParser = .{};
    var id: ?[]const u8 = null;
    var reset = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!std.mem.startsWith(u8, args[i], "--")) {
            if (id != null) return usageError();
            id = args[i];
            continue;
        }
        const opt = try Option.read(args, &i, &(SettingsParser.flags ++ [_][]const u8{ "show", "reset" }));
        if (opt.value == null and std.mem.eql(u8, opt.name, "reset")) {
            reset = true;
        } else if (opt.value == null and std.mem.eql(u8, opt.name, "show")) {
            // Showing is what happens anyway.
        } else if (!try settings.apply(arena, opt)) {
            return fail("--{s} can't be saved as an override", .{opt.name});
        }
    }
    const app = id orelse return usageError();
    const new = settings.finish();

    if (reset) {
        if (!new.isEmpty()) return fail("--reset removes all of {s}'s overrides; add new ones separately", .{app});
        try override.delete(ctx.store, arena, app);
        note("{s} has no overrides now", .{app});
        return;
    }
    const saved = try override.load(ctx.store, arena, app);
    if (new.isEmpty()) {
        if (saved.isEmpty()) {
            note("{s} has no overrides", .{app});
            return;
        }
        var buf: [4096]u8 = undefined;
        var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
        try stdout.interface.print("{f}\n", .{saved});
        try stdout.interface.flush();
        return;
    }
    if (try ctx.store.readRef(arena, app) == null) return fail("{s} is not installed", .{app});
    const merged = try override.Settings.merge(arena, saved, new);
    try override.save(ctx.store, arena, app, merged);
    note("{s} now runs with {f}", .{ app, merged });
}

fn list(ctx: *Context) !void {
    const arena = ctx.arena;
    const refs = try ctx.store.listRefs(arena);
    const shims = try exports.list(ctx);
    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const w = &stdout.interface;
    try w.print("{s:<32} {s:<20} {s:<20} {s}\n", .{ "ID", "VERSION", "MANIFEST", "EXPORTS" });
    for (refs) |ref| {
        var names: std.ArrayList([]const u8) = .empty;
        for (shims) |s| if (std.mem.eql(u8, s.sidecar.app, ref.id)) try names.append(arena, s.name);
        try w.print("{s:<32} {s:<20} {s:<20} {s}", .{ ref.id, ref.version, oci.shortDigest(ref.manifest), try std.mem.join(arena, ", ", names.items) });
        const image = try ctx.store.readImage(arena, ref.id, ref.manifest);
        for (image.config.runtimes.map.values()) |r| try w.print("  (runtime {s} {s})", .{ r.id, r.version });
        const saved = try override.load(ctx.store, arena, ref.id);
        if (!saved.isEmpty()) try w.print("  (override {f})", .{saved});
        try w.writeByte('\n');
    }
    try w.flush();
}

fn remove(ctx: *Context, id: []const u8, delete_data: bool) !void {
    const io = ctx.io;
    const arena = ctx.arena;
    const store = ctx.store;
    const ref = try store.readRef(arena, id) orelse return fail("{s} is not installed", .{id});

    // Held until the ref is gone, so a run of the app that ends meanwhile
    // can't give it shims again.
    const shims_lock = try store.lockShims(arena);
    defer shims_lock.release(io);
    const removed_exports = try exports.removeAll(ctx, id);
    if (removed_exports.len > 0) note("removed commands {s}", .{try std.mem.join(arena, ", ", removed_exports)});

    // Undo ACL grants on host paths made for the app's AppContainer.
    const host_grants = try store.readGrants(arena, id);
    if (host_grants.len > 0) {
        const profile = try appcontainer.Profile.ensure(arena, id);
        for (host_grants) |p| {
            // A deleted path took its ACL with it.
            if (!try Store.exists(io, p)) continue;
            acl.revoke(arena, p, profile.sid) catch |err| switch (err) {
                error.Failed => continue, // Logged; keep undoing the rest.
                else => |e| return e,
            };
            note("revoked {s} access to {s}", .{ profile.name, p });
        }
        try store.deleteGrants(arena, id);
    }
    try appcontainer.deleteProfile(arena, id);

    try store.deleteRef(arena, id);
    if (try store.deleteUnusedDeployments(arena, ref.manifest))
        note("kept {s}'s files, which are still in use; `zigsaw prune` removes them later", .{id});
    if (delete_data) {
        try Store.deleteTree(io, arena, try store.path(arena, &.{ "data", id }));
        try override.delete(store, arena, id);
    }

    note("removed {s} {s}{s}", .{ id, ref.version, if (delete_data) " and its data" else "" });
}

test {
    _ = @import("builder.zig");
    _ = @import("credentials.zig");
    _ = @import("deps.zig");
    _ = @import("drive.zig");
    _ = @import("environment.zig");
    _ = @import("exports.zig");
    _ = @import("msvc.zig");
    _ = @import("oci.zig");
    _ = @import("override.zig");
    _ = @import("process.zig");
    _ = @import("prune.zig");
    _ = @import("recipe.zig");
    _ = @import("Registry.zig");
    _ = @import("remote.zig");
    _ = @import("layer.zig");
    _ = @import("run.zig");
    _ = @import("Sidecar.zig");
    _ = @import("Store.zig");
    _ = @import("Tree.zig");
    _ = @import("zipfile.zig");
}
