const std = @import("std");
const Io = std.Io;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const appcontainer = @import("appcontainer.zig");
const services = @import("services.zig");
const builder = @import("builder.zig");
const catalog = @import("catalog.zig");
const credentials = @import("credentials.zig");
const environment = @import("environment.zig");
const exports = @import("exports.zig");
const grants = @import("grants.zig");
const hkcu = @import("hkcu.zig");
const info = @import("info.zig");
const peek = @import("peek.zig");
const install = @import("install.zig");
const lazy = @import("lazy.zig");
const LazyHelper = @import("LazyHelper.zig");
const oci = @import("oci.zig");
const override = @import("override.zig");
const prune = @import("prune.zig");
const remote = @import("remote.zig");
const rollback = @import("rollback.zig");
const runtime = @import("run.zig");
const shortcuts = @import("shortcuts.zig");
const associations = @import("associations.zig");
const schedule = @import("schedule.zig");
const signature = @import("signature.zig");
const trust = @import("trust.zig");
const update = @import("update.zig");
const updates = @import("updates.zig");
const upgrade = @import("upgrade.zig");
const volumes = @import("volumes.zig");
const win32 = @import("win32.zig");
const options = @import("options");
const fail = Context.fail;
const note = Context.note;

const usage =
    \\usage: zigsaw [-v|--verbose] <command> [options]
    \\
    \\commands:
    \\  build [--rebuild] [--clean] [--keep-build-dir] [<recipe.json> | <dir>]
    \\                                  build an app from a recipe, or from the zigsaw.json of a
    \\                                  project's directory (by default the current one), and
    \\                                  install it and its commands; --rebuild builds even if an
    \\                                  earlier build had the same inputs, and --clean also starts
    \\                                  a project's modules without their kept work directories
    \\  search [<words>...]             find apps in the default registry's catalog
    \\  info <image>                    show what an app in a registry is, needs and may reach
    \\  ls <image>                      list the files of an app in a registry without pulling
    \\                                  it, as far as its layers' format allows (eStargz)
    \\  cat <image> <path>              write a file of an app in a registry to stdout, the
    \\                                  same way
    \\  pull [--yes] [--lazy] <image>   install an app and its commands from a registry, once
    \\                                  you agree to what it may reach; --yes agrees without
    \\                                  asking; --lazy installs it before its large eStargz
    \\                                  layers are downloaded, their files fetched as they're
    \\                                  first used while the rest downloads
    \\  push [--sources] <app-id> [<image>]
    \\                                  publish an installed app to a registry; --sources also
    \\                                  keeps the files it was built from next to it
    \\  push --catalog <app-id>...      make the default registry's catalog list these apps,
    \\                                  as it has them
    \\  login [--username=<user>] [--password-stdin] <registry>
    \\                                  check and save a login for a registry
    \\  logout <registry>               delete a registry's saved login
    \\  run [options] <app-id> [args]   run an installed app
    \\  list                            list installed apps, their commands and shortcuts,
    \\                                  and the kinds of file they open
    \\  override [options] <app-id>     save run options that every run of the app gets;
    \\                                  --show shows them, --reset removes them
    \\  override [options] --global     the same for every app, below each app's own; also
    \\                                  --real-folders lets the apps of a store that isn't your
    \\                                  default one use your real folders, --noreal-folders
    \\                                  stops them
    \\  grants [<app-id>]               list what zigsaw changed outside its store for apps, in
    \\                                  this store and others, what stores since deleted left,
    \\                                  and low labels on your folders no record explains
    \\  grants --take-back <path>       remove a low label that no record explains
    \\  update [--yes] [--lazy] [<app-id>...]
    \\                                  rebuild or re-pull apps from where they came from;
    \\                                  one pulled again that may reach more asks first,
    \\                                  unless given --yes; --lazy as for pull
    \\  update --check [<app-id>...]    list the apps a new image waits for, and what it may
    \\                                  reach beyond theirs, installing nothing
    \\  rollback [--yes] <app-id>       go back to the version the installed one replaced, with
    \\                                  no network; updates then pass over the version left,
    \\                                  though not a newer one
    \\  hold <app-id>...                have updates, and the daily check, leave the apps alone
    \\  unhold <app-id>...              let updates reach them again
    \\  updates                         say what the last check found waiting, and whether a
    \\                                  daily check is on; neither installs anything
    \\  updates check                   look for updates of apps and zigsaw now
    \\  updates on|off                  start or stop the daily check; off is remembered, so
    \\                                  that installing or upgrading zigsaw leaves it off
    \\  upgrade [--yes]                 install zigsaw's latest release over this one, once you
    \\                                  agree; --yes agrees without asking
    \\  trust                           list the keys that images' signatures are checked against
    \\  trust add <registry/path> <key> check images under that path against a public key, as
    \\                                  `cosign generate-key-pair` makes in cosign.pub
    \\  trust rm <registry/path> [<fingerprint>]
    \\                                  stop checking them against keys added there
    \\  signature payload <image>       print what to sign for an image, for `cosign sign-blob`
    \\  signature push <image> <payload file> <signature file>
    \\                                  put that signature beside the image, where pull looks
    \\  signature check <image>         say whether an image has a good signature
    \\  volume create [--path=<dir>] <name>
    \\                                  make a volume in the store, or keep one in a folder of
    \\                                  yours; a run's --volume makes one it doesn't find
    \\  volume ls                       list the volumes, where each is, and what mounts it
    \\  volume inspect <name>           show a volume's size, mounts, use and grants
    \\  volume rm <name>...             delete volumes in the store, or forget ones kept
    \\                                  elsewhere, leaving their files; not one an override
    \\                                  mounts
    \\  volume prune [--dry-run]        delete the volumes in the store that no override mounts
    \\  rm [--delete-data] <app-id>     uninstall an app and its commands; its volumes stay
    \\  prune [--dry-run] [--downloads] [--data] [--previous]
    \\                                  delete what no installed app needs; also cached
    \\                                  downloads and tool caches, the data of uninstalled
    \\                                  apps, and the versions kept for rollback
    \\  repair                          write every app's commands, shortcuts and file
    \\                                  associations again, as after installing a new zigsaw,
    \\                                  and take back what apps may no longer reach, and what
    \\                                  stores since deleted left
    \\  version                         print zigsaw's version
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
    \\but only for the default registry. Without either, the login `docker login` saved is
    \\used. From a multi-platform index, pull takes the image for windows/amd64. Blobs over
    \\64 MiB are pushed in chunks of ZIGSAW_UPLOAD_CHUNK_SIZE bytes (0: in one request).
    \\
    \\run options (override takes them too, except --command and --file):
    \\  --command=<name>                run one of the app's exported commands, or another
    \\                                  executable or batch file from the app or System32
    \\  --file=<path>                   have the app open a file of yours: grants it that
    \\                                  file for the run, and adds its path to the app's
    \\                                  arguments
    \\  --sandbox=soft|low|appcontainer soft shapes the environment; low (the default, unless
    \\                                  the app's image asks for another) also keeps the app
    \\                                  from writing anywhere but its data directory and the
    \\                                  paths granted; appcontainer enforces all of the app's
    \\                                  permissions
    \\  --filesystem=<location>[:ro]    grant access to a host location: cwd, an absolute path,
    \\                                  or one of your folders: desktop, documents, downloads,
    \\                                  music, pictures, videos
    \\  --nofilesystem=<location>       take away access the app or an override grants
    \\  --share=network                 allow network access, and pass on your proxy variables
    \\  --share=commands                put your zigsaw apps' commands on its PATH, after the
    \\                                  system's; each runs as its own app (soft sandbox only)
    \\  --share=host                    put zigsaw-host on its PATH, which runs your own programs
    \\                                  in your real environment, with the run's rights (not in
    \\                                  an AppContainer)
    \\  --unshare=<what>                take away what --share gives, or the app's image asks for
    \\  --port=<service>=<port>         serve one of the app's services on another port
    \\  --env=NAME=VALUE                set an environment variable
    \\  --noextension=<id>              leave out an installed extension, which otherwise
    \\                                  joins the runs of what it extends
    \\  --extension=<id>                have an extension an override leaves out join again
    \\  --volume=<source>:<path>[:ro]   make <path> in the app's data directory the volume of
    \\                                  that name, or a folder of yours by its absolute path;
    \\                                  it outlives the data, and other apps may mount it too
    \\  --novolume=<path>               take away the mount an override has there
    \\  --ephemeral                     use a fresh data directory, deleted afterwards; its
    \\                                  volumes stay
    \\
    \\What the low and appcontainer sandboxes grant on host paths stays while the app's
    \\permissions and overrides give it; what a command line adds goes when the app's
    \\last run ends. At low integrity, a working directory that's your user profile, a
    \\directory it's in, or a drive's root stays read-only.
    \\
    \\An app's services (`info` lists them) are on localhost, on the ports its config says
    \\or --port gives, in every sandbox.
    \\
    \\Under appcontainer, a run of an app with the network has its container exempt from
    \\loopback isolation while the app's runs go, so that it reaches other programs on this
    \\machine; with ZIGSAW_LOOPBACK_EXEMPTION=0, zigsaw never exempts one.
    \\
    \\Data lives in %ZIGSAW_HOME%, or %LOCALAPPDATA%\zigsaw when that isn't set. Apps of a
    \\store elsewhere don't get your real folders until `override --global --real-folders`.
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    // Started from inside a run, as a command of `--share=commands` is: what
    // zigsaw finds from the environment is to be the user's, not that run's.
    if (init.environ_map.contains("ZIGSAW_ID")) try environment.restoreUser(arena, init.environ_map);

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
    if (std.mem.eql(u8, command, "version") or isFlag(command, "version")) {
        var buf: [64]u8 = undefined;
        var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
        try stdout.interface.print("zigsaw {s}\n", .{options.version});
        try stdout.interface.flush();
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

    // A lazy layer's helper (see lazy.zig), which zigsaw starts, and nobody
    // else: the store it's for by its full path, whatever ZIGSAW_HOME says.
    if (std.mem.eql(u8, command, "lazy-helper")) {
        if (rest.len != 2) return usageError();
        try ctx.env.put("ZIGSAW_HOME", rest[0]);
        ctx.store = try .open(ctx.io, ctx.arena, ctx.env);
        return LazyHelper.main(ctx, rest[1]);
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
            } else if (isFlag(arg, "clean")) {
                opts.clean = true;
            } else if (recipe_path == null and !std.mem.startsWith(u8, arg, "-")) {
                recipe_path = arg;
            } else return usageError();
        }
        _ = try ctx.store.lock(ctx.arena, .shared);
        try install.install(ctx, try builder.build(ctx, try builder.recipePath(ctx, recipe_path), opts));
        return 0;
    }
    if (std.mem.eql(u8, command, "pull")) {
        var consent: remote.Consent = .ask;
        var image: ?[]const u8 = null;
        var lazily = false;
        for (rest) |arg| {
            if (isFlag(arg, "yes")) {
                consent = .given;
            } else if (isFlag(arg, "lazy")) {
                lazily = true;
            } else if (image == null and !std.mem.startsWith(u8, arg, "-")) {
                image = arg;
            } else return usageError();
        }
        _ = try ctx.store.lock(ctx.arena, .shared);
        try install.install(ctx, (try remote.fetch(ctx, image orelse return usageError(), .{ .consent = consent, .lazy = lazily })).?);
        return 0;
    }
    if (std.mem.eql(u8, command, "push")) {
        var opts: remote.PushOptions = .{};
        var make_catalog = false;
        var names: std.ArrayList([]const u8) = .empty;
        for (rest) |arg| {
            if (isFlag(arg, "sources")) {
                opts.sources = true;
            } else if (isFlag(arg, "catalog")) {
                make_catalog = true;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                try names.append(ctx.arena, arg);
            } else return usageError();
        }
        if (make_catalog) {
            if (opts.sources or names.items.len == 0) return usageError();
            _ = try ctx.store.lock(ctx.arena, .shared);
            try catalog.push(ctx, names.items);
            return 0;
        }
        if (names.items.len != 1 and names.items.len != 2) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        try remote.push(ctx, names.items[0], if (names.items.len == 2) names.items[1] else null, opts);
        return 0;
    }
    if (std.mem.eql(u8, command, "search")) {
        for (rest) |arg| if (std.mem.startsWith(u8, arg, "-")) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        return catalog.search(ctx, @ptrCast(rest));
    }
    if (std.mem.eql(u8, command, "info")) {
        if (rest.len != 1 or std.mem.startsWith(u8, rest[0], "-")) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        try info.info(ctx, rest[0]);
        return 0;
    }
    if (std.mem.eql(u8, command, "ls") or std.mem.eql(u8, command, "cat")) {
        const listing = std.mem.eql(u8, command, "ls");
        if (rest.len != @as(usize, if (listing) 1 else 2)) return usageError();
        for (rest) |arg| if (std.mem.startsWith(u8, arg, "-")) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        if (listing) try peek.ls(ctx, rest[0]) else try peek.cat(ctx, rest[0], rest[1]);
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
        var consent: remote.Consent = .ask;
        var only_check = false;
        var lazily = false;
        var ids: std.ArrayList([]const u8) = .empty;
        for (rest) |arg| {
            if (isFlag(arg, "yes")) {
                consent = .given;
            } else if (isFlag(arg, "check")) {
                only_check = true;
            } else if (isFlag(arg, "lazy")) {
                lazily = true;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                try ids.append(ctx.arena, arg);
            } else return usageError();
        }
        if (only_check and (consent == .given or lazily)) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        if (only_check) return update.check(ctx, ids.items);
        return update.update(ctx, ids.items, consent, lazily);
    }
    if (std.mem.eql(u8, command, "rollback")) {
        var consent: remote.Consent = .ask;
        var id: ?[]const u8 = null;
        for (rest) |arg| {
            if (isFlag(arg, "yes")) {
                consent = .given;
            } else if (id == null and !std.mem.startsWith(u8, arg, "-")) {
                id = arg;
            } else return usageError();
        }
        _ = try ctx.store.lock(ctx.arena, .shared);
        try rollback.rollback(ctx, id orelse return usageError(), consent);
        return 0;
    }
    if (std.mem.eql(u8, command, "hold") or std.mem.eql(u8, command, "unhold")) {
        if (rest.len == 0) return usageError();
        for (rest) |arg| if (std.mem.startsWith(u8, arg, "-")) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        try rollback.setHeld(ctx, @ptrCast(rest), std.mem.eql(u8, command, "hold"));
        return 0;
    }
    if (std.mem.eql(u8, command, "updates")) return updatesCommand(ctx, rest);
    if (std.mem.eql(u8, command, "trust")) return trustCommand(ctx, rest);
    if (std.mem.eql(u8, command, "signature")) return signatureCommand(ctx, rest);
    if (std.mem.eql(u8, command, "volume")) return volumeCommand(ctx, rest);
    if (std.mem.eql(u8, command, "upgrade")) {
        var consent: remote.Consent = .ask;
        for (rest) |arg| {
            if (isFlag(arg, "yes")) consent = .given else return usageError();
        }
        _ = try ctx.store.lock(ctx.arena, .shared);
        return upgrade.upgrade(ctx, consent);
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
            } else if (isFlag(arg, "previous")) {
                opts.previous = true;
            } else return usageError();
        }
        _ = try ctx.store.lock(ctx.arena, .exclusive);
        try prune.prune(ctx, opts);
        return 0;
    }
    if (std.mem.eql(u8, command, "repair")) {
        if (rest.len != 0) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        // What runs that didn't end left in HKCU first, as repair runs after
        // installing a zigsaw, maybe over one that was killed; and what they
        // were granted and no longer stands, by older zigsaws too.
        try hkcu.settleLeftovers(ctx, null);
        const unsettled = try grants.settleAll(ctx) + try grants.settleOrphans(ctx);
        const code = try exports.repair(ctx);
        try schedule.repair(ctx);
        return if (unsettled > 0) 1 else code;
    }
    if (std.mem.eql(u8, command, "grants")) {
        var id: ?[]const u8 = null;
        var take_back: ?[]const u8 = null;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            if (!std.mem.startsWith(u8, rest[i], "--")) {
                if (id != null) return usageError();
                id = rest[i];
                continue;
            }
            const opt = try Option.read(rest, &i, &.{});
            if (!std.mem.eql(u8, opt.name, "take-back")) return usageError();
            take_back = opt.value;
        }
        if (id != null and take_back != null) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        if (take_back) |p| try grants.takeBackLabel(ctx, p) else try grants.show(ctx, id);
        return 0;
    }
    return usageError();
}

fn updatesCommand(ctx: *Context, args: []const [:0]const u8) !u32 {
    if (args.len == 0) {
        try updates.show(ctx);
        return 0;
    }
    const what = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, what, "check")) {
        var opts: updates.CheckOptions = .{};
        for (rest) |arg| {
            if (isFlag(arg, "notify")) {
                opts.notify = true;
            } else if (isFlag(arg, "quiet")) {
                opts.quiet = true;
            } else return usageError();
        }
        if (opts.notify and opts.quiet) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        return updates.check(ctx, opts);
    }
    if (std.mem.eql(u8, what, "on")) {
        // An install or upgrade asks this way: what the user turned off stays off.
        const respect = rest.len == 1 and isFlag(rest[0], "unless-off");
        if (rest.len != @intFromBool(respect)) return usageError();
        if (respect and try schedule.turnedOff(ctx)) return 0;
        try schedule.turnOn(ctx);
        return 0;
    }
    if (std.mem.eql(u8, what, "off")) {
        if (rest.len != 0) return usageError();
        try schedule.turnOff(ctx);
        return 0;
    }
    return usageError();
}

/// `zigsaw volume`: the named volumes runs mount (see volumes.zig).
fn volumeCommand(ctx: *Context, args: []const [:0]const u8) !u32 {
    if (args.len == 0) return usageError();
    const what = args[0];
    const rest = args[1..];
    _ = try ctx.store.lock(ctx.arena, .shared);
    if (std.mem.eql(u8, what, "create")) {
        var name: ?[]const u8 = null;
        var at: ?[]const u8 = null;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            if (!std.mem.startsWith(u8, rest[i], "--")) {
                if (name != null) return usageError();
                name = rest[i];
                continue;
            }
            const opt = try Option.read(rest, &i, &.{});
            if (!std.mem.eql(u8, opt.name, "path") or opt.value.?.len == 0) return usageError();
            at = opt.value;
        }
        try volumes.create(ctx, name orelse return usageError(), at);
        return 0;
    }
    if (std.mem.eql(u8, what, "prune")) {
        var dry_run = false;
        for (rest) |arg| {
            if (isFlag(arg, "dry-run")) dry_run = true else return usageError();
        }
        try volumes.prune(ctx, dry_run);
        return 0;
    }
    for (rest) |arg| if (std.mem.startsWith(u8, arg, "-")) return usageError();
    if (std.mem.eql(u8, what, "ls")) {
        if (rest.len != 0) return usageError();
        try volumes.show(ctx);
        return 0;
    }
    if (std.mem.eql(u8, what, "inspect")) {
        if (rest.len != 1) return usageError();
        try volumes.inspect(ctx, rest[0]);
        return 0;
    }
    if (std.mem.eql(u8, what, "rm")) {
        if (rest.len == 0) return usageError();
        try volumes.remove(ctx, @ptrCast(rest));
        return 0;
    }
    return usageError();
}

/// `zigsaw trust`: which keys count for which images.
fn trustCommand(ctx: *Context, rest: []const []const u8) !u32 {
    _ = try ctx.store.lock(ctx.arena, .shared);
    if (rest.len == 0) {
        try trust.list(ctx);
        return 0;
    }
    if (std.mem.eql(u8, rest[0], "add") and rest.len == 3) {
        try trust.add(ctx, rest[1], rest[2]);
        return 0;
    }
    if (std.mem.eql(u8, rest[0], "rm") and (rest.len == 2 or rest.len == 3)) {
        try trust.remove(ctx, rest[1], if (rest.len == 3) rest[2] else null);
        return 0;
    }
    return usageError();
}

/// `zigsaw signature`: what scripts/sign-images.sh needs, on either side of cosign's
/// `sign-blob`, which is what holds the key.
fn signatureCommand(ctx: *Context, rest: []const []const u8) !u32 {
    if (rest.len < 2) return usageError();
    _ = try ctx.store.lock(ctx.arena, .shared);
    const what = rest[0];
    const image = rest[1];
    if (std.mem.startsWith(u8, image, "-")) return usageError();
    if (std.mem.eql(u8, what, "payload") and rest.len == 2) {
        const payload = try remote.signaturePayload(ctx, image);
        var buf: [4096]u8 = undefined;
        var stdout = Context.stdout().writerStreaming(ctx.io, &buf);
        try stdout.interface.writeAll(payload);
        try stdout.interface.flush();
        return 0;
    }
    if (std.mem.eql(u8, what, "push") and rest.len == 4) {
        const cwd = std.Io.Dir.cwd();
        const payload = cwd.readFileAlloc(ctx.io, rest[2], ctx.arena, .limited(signature.max_payload_size)) catch |err|
            return fail("reading {s}: {t}", .{ rest[2], err });
        const text = cwd.readFileAlloc(ctx.io, rest[3], ctx.arena, .limited(4096)) catch |err|
            return fail("reading {s}: {t}", .{ rest[3], err });
        try remote.pushSignature(ctx, image, payload, text);
        return 0;
    }
    if (std.mem.eql(u8, what, "check") and rest.len == 2) {
        const target = try remote.resolve(ctx, image);
        var registry: @import("Registry.zig") = undefined;
        try registry.init(ctx, target.ref, "pull");
        defer registry.deinit();
        const digest = try remote.manifestDigest(ctx, image);
        return switch (try remote.checkSignature(ctx, &registry, target.ref, null, digest)) {
            .no_key => fail("{s}: no key here for its registry", .{image}),
            .missing => fail("{s}: not signed", .{image}),
            .wrong => |why| fail("{s}: {s}", .{ image, why }),
            .signed => |fingerprint| signed: {
                note("{s}: signed, by key {s}", .{ image, fingerprint });
                break :signed 0;
            },
        };
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
    nofilesystem: std.ArrayList([]const u8) = .empty,
    env: std.ArrayList([]const u8) = .empty,
    noextension: std.ArrayList([]const u8) = .empty,
    extension: std.ArrayList([]const u8) = .empty,
    ports: std.ArrayList([]const u8) = .empty,
    volumes: std.ArrayList([]const u8) = .empty,
    novolume: std.ArrayList([]const u8) = .empty,

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
                return fail("--sandbox must be soft, low or appcontainer", .{});
        } else if (std.mem.eql(u8, name, "filesystem") or std.mem.eql(u8, name, "nofilesystem")) {
            const g = oci.parseFsGrant(value);
            if (g == null or g.?.where == .unknown)
                return fail("--{s} must be cwd, one of your folders ({s}) or an absolute path; got \"{s}\"", .{ name, oci.UserFolder.list, value });
            if (std.mem.eql(u8, name, "filesystem")) {
                try p.filesystem.append(arena, value);
            } else {
                if (std.mem.endsWith(u8, value, ":ro") or std.mem.endsWith(u8, value, ":rw"))
                    return fail("--nofilesystem takes away all access to a location; it takes no :ro or :rw", .{});
                try p.nofilesystem.append(arena, value);
            }
        } else if (std.mem.eql(u8, name, "share") or std.mem.eql(u8, name, "unshare")) {
            const on = std.mem.eql(u8, name, "share");
            if (std.mem.eql(u8, value, "network")) {
                p.settings.network = on;
            } else if (std.mem.eql(u8, value, "commands")) {
                p.settings.commands = on;
            } else if (std.mem.eql(u8, value, "host")) {
                p.settings.host = on;
            } else return fail("--{s} takes network, commands or host; got \"{s}\"", .{ name, value });
        } else if (std.mem.eql(u8, name, "env")) {
            if (std.mem.indexOfScalar(u8, value, '=') == null) return fail("--env expects NAME=VALUE, got \"{s}\"", .{value});
            try p.env.append(arena, value);
        } else if (std.mem.eql(u8, name, "noextension") or std.mem.eql(u8, name, "extension")) {
            if (!oci.isValidId(value)) return fail("--{s} takes an extension's id; got \"{s}\"", .{ name, value });
            try (if (name[0] == 'n') &p.noextension else &p.extension).append(arena, value);
        } else if (std.mem.eql(u8, name, "port")) {
            if (override.parsePort(value) == null) return fail("--port expects <service>=<port>, a port from 1 to 65535; got \"{s}\"", .{value});
            try p.ports.append(arena, value);
        } else if (std.mem.eql(u8, name, "volume")) {
            // Kept as volumes.Mount.spec writes it, which tells mounts apart
            // by where they go when settings merge.
            switch (try volumes.parse(arena, value)) {
                .ok => |m| try p.volumes.append(arena, try m.spec(arena)),
                .invalid => |why| return fail("--volume={s}: {s}", .{ value, why }),
            }
        } else if (std.mem.eql(u8, name, "novolume")) {
            switch (try volumes.parseTarget(arena, value)) {
                .ok => |t| try p.novolume.append(arena, t),
                .invalid => |why| return fail("--novolume={s}: {s}", .{ value, why }),
            }
        } else return false;
        return true;
    }

    fn finish(p: *const SettingsParser) override.Settings {
        var s = p.settings;
        s.filesystem = p.filesystem.items;
        s.nofilesystem = p.nofilesystem.items;
        s.env = p.env.items;
        s.noextension = p.noextension.items;
        s.extension = p.extension.items;
        s.ports = p.ports.items;
        s.volumes = p.volumes.items;
        s.novolume = p.novolume.items;
        return s;
    }
};

/// Options go before the app id, like `flatpak run`; everything after the id
/// belongs to the app. "--" also ends zigsaw's options.
fn parseRunOptions(ctx: *Context, args: []const [:0]const u8) !runtime.Options {
    var opts: runtime.Options = .{ .id = undefined };
    var settings: SettingsParser = .{};
    var files: std.ArrayList([]const u8) = .empty;
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
        } else if (std.mem.eql(u8, opt.name, "file") and opt.value != null) {
            if (opt.value.?.len == 0) return fail("--file needs a file's path", .{});
            try files.append(ctx.arena, opt.value.?);
        } else if (!try settings.apply(ctx.arena, opt)) {
            return fail("unknown run option --{s}", .{opt.name});
        }
    }
    if (i == args.len) return usageError();

    opts.id = args[i];
    opts.args = @ptrCast(args[i + 1 ..]);
    opts.files = files.items;
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
/// the app gets; with `--global` instead of an app, every app's runs, below
/// each app's own. New options are added to the saved ones; `--reset`
/// removes them all. Without options, or with `--show`, prints what's saved.
fn overrideApp(ctx: *Context, args: []const [:0]const u8) !void {
    const arena = ctx.arena;
    var settings: SettingsParser = .{};
    var id: ?[]const u8 = null;
    var reset = false;
    var global = false;
    var real_folders: ?bool = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!std.mem.startsWith(u8, args[i], "--")) {
            if (id != null) return usageError();
            id = args[i];
            continue;
        }
        const opt = try Option.read(args, &i, &(SettingsParser.flags ++ [_][]const u8{ "show", "reset", "global", "real-folders", "noreal-folders" }));
        if (opt.value == null and std.mem.eql(u8, opt.name, "reset")) {
            reset = true;
        } else if (opt.value == null and std.mem.eql(u8, opt.name, "global")) {
            global = true;
        } else if (opt.value == null and std.mem.eql(u8, opt.name, "show")) {
            // Showing is what happens anyway.
        } else if (opt.value == null and std.mem.eql(u8, opt.name, "real-folders")) {
            real_folders = true;
        } else if (opt.value == null and std.mem.eql(u8, opt.name, "noreal-folders")) {
            real_folders = false;
        } else if (!try settings.apply(arena, opt)) {
            return fail("--{s} can't be saved as an override", .{opt.name});
        }
    }
    // An app's overrides, or with --global (and no app) the store-wide ones.
    if (global == (id != null)) return usageError();
    const app: ?[]const u8 = id;
    const whose = app orelse "every app";
    if (real_folders != null and app != null) return fail("--real-folders is for a whole store: use it with --global", .{});
    var new = settings.finish();
    new.real_folders = real_folders;

    if (reset) {
        if (!new.isEmpty()) return fail("--reset removes all of {s}'s overrides; add new ones separately", .{whose});
        try override.delete(ctx.store, arena, app);
        if (app) |a| note("{s} has no overrides now", .{a}) else note("there are no store-wide overrides now", .{});
        return settleGrants(ctx, app);
    }
    const saved = try override.load(ctx.store, arena, app);
    if (new.isEmpty()) {
        if (saved.isEmpty()) {
            if (app) |a| note("{s} has no overrides", .{a}) else note("there are no store-wide overrides", .{});
            return;
        }
        var buf: [4096]u8 = undefined;
        var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
        try stdout.interface.print("{f}\n", .{saved});
        try stdout.interface.flush();
        return;
    }
    const ref = if (app) |a| try ctx.store.readRef(arena, a) orelse return fail("{s} is not installed", .{a}) else null;
    const merged = try override.Settings.merge(arena, saved, new);
    try override.save(ctx.store, arena, app, merged);
    // Said here as well as by each run: a run from a shortcut has no console.
    if (ref) |r| if (new.sandbox != null) {
        const image = try ctx.store.readImage(arena, r.id, r.manifest);
        runtime.warnUnsupported(image.config, new.sandbox.?);
    };
    if (app) |a| {
        if (merged.isEmpty()) {
            note("{s} has no overrides now", .{a});
        } else note("{s} now runs with {f}", .{ a, merged });
    } else if (merged.isEmpty()) {
        note("there are no store-wide overrides now", .{});
    } else note("every app now runs with {f}, unless its own overrides choose otherwise", .{merged});
    try settleGrants(ctx, app);
}

/// Takes back what the app's runs were granted that its overrides no longer
/// give it (see grants.zig), now unless a run of it is going; with a null
/// id, what any app's were, after the store-wide overrides changed.
fn settleGrants(ctx: *Context, id: ?[]const u8) !void {
    const ids = if (id) |a| &[_][]const u8{a} else try ctx.store.listGrantIds(ctx.arena);
    for (ids) |a| if (!try grants.settleUnlessRunning(ctx, a))
        note("{s} is running: what the change takes back goes when its last run ends", .{a});
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
        if (image.config.extensions) |e| for (e.map.keys()) |name| try w.print("  (extension point {s})", .{name});
        if (image.config.extends) |x| try w.print("  (extends {s} {s})", .{ x.point, x.version });
        for (try shortcuts.names(ctx, ref.id)) |name| try w.print("  (shortcut \"{s}\")", .{name});
        const opens = try associations.names(ctx, ref.id);
        if (opens.len > 0) try w.print("  (opens {s})", .{try std.mem.join(arena, ", ", opens)});
        if (image.config.registry) |keys| for (keys) |k| try w.print("  (keeps HKCU\\{s})", .{k});
        const saved = try override.load(ctx.store, arena, ref.id);
        if (!saved.isEmpty()) try w.print("  (override {f})", .{saved});
        if (try lazy.describe(ctx.store, arena, image.manifest)) |state| try w.print("  {s}", .{state});
        if (try ctx.store.isHeld(arena, ref.id)) try w.writeAll("  (held)");
        if (try ctx.store.readPrevious(arena, ref.id)) |p| if (!std.mem.eql(u8, p.manifest, ref.manifest)) try w.print("  (previous {s})", .{p.version});
        if (try ctx.store.readSkip(arena, ref.id)) |s| try w.print("  (skips {s})", .{s.version});
        try w.writeByte('\n');
    }
    try w.flush();
    try grants.noteLeftovers(ctx);
    try updates.noteWaiting(ctx);
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
    // Shortcuts first: the shims' sidecars say which app each one is for.
    const removed_shortcuts = try shortcuts.removeAll(ctx, id);
    if (removed_shortcuts.len > 0) note("removed shortcuts {s}", .{try std.mem.join(arena, ", ", removed_shortcuts)});
    const removed_associations = try associations.removeAll(ctx, id);
    if (removed_associations.len > 0) note("no longer opens {s}", .{try std.mem.join(arena, ", ", removed_associations)});
    const removed_exports = try exports.removeAll(ctx, id);
    if (removed_exports.len > 0) note("removed commands {s}", .{try std.mem.join(arena, ", ", removed_exports)});

    // Undo what the app's runs changed on host paths: access granted to its
    // AppContainer, and low integrity labels no other app's runs need.
    try grants.undoAll(ctx, id);
    try appcontainer.deleteProfile(arena, id);
    try services.forget(store, arena, id);
    // The keys the app keeps, if a run that didn't end left them in HKCU:
    // back into its data, before that goes too.
    try hkcu.settleLeftovers(ctx, id);

    try store.deleteRef(arena, id);
    // Its previous version, whose blobs prune then deletes, and whether it
    // was held: a new install starts afresh.
    try store.forgetVersions(arena, id);
    {
        const aliases_lock = try store.lockAliases(arena, id);
        defer aliases_lock.release(io);
        Store.deleteTree(io, arena, try store.aliasDir(arena, id)) catch
            note("kept {s}'s alias shims, which are in use; `zigsaw prune` removes them later", .{id});
    }
    if (try store.deleteUnusedDeployments(arena, ref.manifest))
        note("kept {s}'s files, which are still in use; `zigsaw prune` removes them later", .{id});
    // Deleting the data stops at the junctions of its volumes (see
    // volumes.zig), which stay.
    var kept_volumes: []const []const u8 = &.{};
    if (delete_data) {
        kept_volumes = try volumes.namedIn(arena, (try override.load(store, arena, id)).volumes);
        try Store.deleteTree(io, arena, try store.path(arena, &.{ "data", id }));
        try override.delete(store, arena, id);
    }

    note("removed {s} {s}{s}", .{ id, ref.version, if (delete_data) " and its data" else "" });
    for (kept_volumes) |name| note("kept volume {s}, which it mounted; `zigsaw volume rm {s}` deletes it", .{ name, name });
}

test {
    _ = @import("aliases.zig");
    _ = @import("associations.zig");
    _ = @import("BlobReader.zig");
    _ = @import("builder.zig");
    _ = @import("catalog.zig");
    _ = @import("cloudfiles.zig");
    _ = @import("credentials.zig");
    _ = @import("deps.zig");
    _ = @import("drive.zig");
    _ = @import("environment.zig");
    _ = @import("exports.zig");
    _ = @import("extensions.zig");
    _ = @import("folders.zig");
    _ = @import("format.zig");
    _ = @import("gitignore.zig");
    _ = @import("grants.zig");
    _ = @import("hkcu.zig");
    _ = @import("info.zig");
    _ = @import("junction.zig");
    _ = @import("msvc.zig");
    _ = @import("net.zig");
    _ = @import("oci.zig");
    _ = @import("override.zig");
    _ = @import("pe.zig");
    _ = @import("process.zig");
    _ = @import("project.zig");
    _ = @import("prompt.zig");
    _ = @import("prune.zig");
    _ = @import("recipe.zig");
    _ = @import("regkey.zig");
    _ = @import("Registry.zig");
    _ = @import("remote.zig");
    _ = @import("roots.zig");
    _ = @import("rollback.zig");
    _ = @import("layer.zig");
    _ = @import("ledger.zig");
    _ = @import("run.zig");
    _ = @import("schedule.zig");
    _ = @import("services.zig");
    _ = @import("signature.zig");
    _ = @import("trust.zig");
    _ = @import("shortcuts.zig");
    _ = @import("Sidecar.zig");
    _ = @import("Store.zig");
    _ = @import("testing.zig");
    _ = @import("Tree.zig");
    _ = @import("update.zig");
    _ = @import("updates.zig");
    _ = @import("upgrade.zig");
    _ = @import("volumes.zig");
    _ = @import("written.zig");
    _ = @import("zipfile.zig");
}

test "zigsaw is built for the x86-64 baseline, not for the CPU that builds it" {
    // build.zig's default target: a release then runs on any x86-64 CPU, and
    // builds the same on any machine.
    try std.testing.expectEqualStrings("x86_64", @import("builtin").cpu.model.name);
}
