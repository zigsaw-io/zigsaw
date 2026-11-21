const std = @import("std");
const Io = std.Io;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const appcontainer = @import("appcontainer.zig");
const services = @import("services.zig");
const builder = @import("builder.zig");
const compose = @import("compose.zig");
const container = @import("container.zig");
const catalog = @import("catalog.zig");
const credentials = @import("credentials.zig");
const doctor = @import("doctor.zig");
const environment = @import("environment.zig");
const exec = @import("exec.zig");
const exports = @import("exports.zig");
const grants = @import("grants.zig");
const hkcu = @import("hkcu.zig");
const hosts = @import("hosts.zig");
const info = @import("info.zig");
const peek = @import("peek.zig");
const install = @import("install.zig");
const LazyHelper = @import("LazyHelper.zig");
const logs = @import("logs.zig");
const up = @import("up.zig");
const oci = @import("oci.zig");
const output = @import("output.zig");
const override = @import("override.zig");
const prune = @import("prune.zig");
const ps = @import("ps.zig");
const stop = @import("stop.zig");
const remote = @import("remote.zig");
const remotes = @import("remotes.zig");
const rollback = @import("rollback.zig");
const snapshot = @import("snapshot.zig");
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
    \\Manage installed apps:
    \\  install [-y] [--lazy] [<remote>] <image>
    \\                                  install an app and its commands from a remote, once
    \\                                  you agree to what it may reach; -y (--yes) agrees
    \\                                  without asking; --lazy installs it before its large
    \\                                  eStargz layers are downloaded, their files fetched as
    \\                                  they're first used while the rest downloads
    \\  update [-y] [--lazy] [<app-id>...]
    \\                                  rebuild or reinstall apps from where they came from;
    \\                                  one installed again that may reach more asks first,
    \\                                  unless given -y; --lazy as for install
    \\  update --check [<app-id>...]    list the apps a new image waits for, and what it may
    \\                                  reach beyond theirs, installing nothing
    \\  uninstall [--delete-data] <app-id>
    \\                                  uninstall an app and its commands; --delete-data also
    \\                                  deletes its own volume; the others it mounted stay
    \\  uninstall --unused [--dry-run] [--downloads] [--volumes] [--previous]
    \\                                  delete what no installed app needs; also cached
    \\                                  downloads and tool caches, the volumes nothing
    \\                                  mounts, and the versions kept for rollback with
    \\                                  the copies of their data
    \\  mask [--remove] [<app-id>...]   have updates, and the daily check, leave the apps
    \\                                  alone; --remove lets updates reach them again; with
    \\                                  no app, list those masked
    \\  list                            list installed apps, their commands and shortcuts,
    \\                                  and the kinds of file they open
    \\  info <app-id>                   show what an installed app is and may reach, where it
    \\                                  came from, and where its files and data are
    \\  repair                          write every app's commands, shortcuts and file
    \\                                  associations again, as after installing a new zigsaw,
    \\                                  and take back what apps may no longer reach, and what
    \\                                  stores since deleted left
    \\
    \\Find apps:
    \\  search [<words>...]             find apps in the remotes' catalogs
    \\  remote-ls [<remote>]            list the apps in a remote's catalog, or every remote's
    \\  remote-info [<remote>] <image>  show what an app in a remote is, needs and may reach
    \\  remote-info --show-files [<remote>] <image>
    \\                                  list its files without installing it, as far as its
    \\                                  layers' format allows (eStargz)
    \\  remote-info --file=<path> [<remote>] <image>
    \\                                  write one of its files to stdout, the same way
    \\
    \\Run apps:
    \\  run [options] <app-id> [args]   run an installed app (options below)
    \\  override [options] <app-id>     save run options that every run of the app gets;
    \\                                  --show shows them, --reset removes them; also
    \\                                  --nosnapshot has updates keep no copy of its data
    \\                                  for rollback, --snapshot has them keep one again
    \\  override [options] --global     the same for every app, below each app's own; also
    \\                                  --real-folders lets the apps of a store that isn't your
    \\                                  default one use your real folders, --noreal-folders
    \\                                  stops them
    \\  ps [--processes] [<app-id>|<run>...]
    \\                                  list the runs and builds going, each by its zigsaw's
    \\                                  process id: its sandbox, processes, memory, processor
    \\                                  time and command; --processes lists its processes
    \\                                  too, each under the one that started it
    \\  kill [--time=<seconds>] <app-id>|<run>...
    \\                                  ask runs and builds to end: their windows to close,
    \\                                  and Ctrl+C if nothing else is on their console; what
    \\                                  hasn't ended after 10 seconds, or --time, is killed
    \\  kill --now <app-id>|<run>...    end runs and builds now; a run's zigsaw still cleans
    \\                                  up after it, and a build goes on from there next time
    \\  enter [--env=NAME=VALUE]... [-d|--detach] <app-id>|<run> <command> [<arg>...]
    \\                                  run a command in a run that's going, in its sandbox,
    \\                                  job, variables and working directory, on this
    \\                                  terminal; the command is found as --command finds
    \\                                  one. It ends with the run, and with this zigsaw.
    \\                                  --detach starts it with no console and prints the
    \\                                  PID `ps` lists it by
    \\
    \\Manage permissions:
    \\  permissions [<app-id>]          list what zigsaw changed outside its store for apps, in
    \\                                  this store and others, what stores since deleted left,
    \\                                  and low labels on your folders no record explains
    \\  permission-remove <path>        remove a low label that no record explains
    \\
    \\Manage remotes:
    \\  remotes                         list the remotes, in order, whose signatures count for
    \\                                  each one's images, and its login; and for zigsaw's
    \\                                  releases
    \\  remote-add [--if-not-exists] [<changes>] <name> <location>
    \\                                  add a remote: a name (letters, digits, - and _) for a
    \\                                  registry and a path in it, such as ghcr.io/me, or
    \\                                  oci+https://ghcr.io/me as Flatpak writes it
    \\  remote-modify <changes> <name>  change a remote:
    \\    --url=<location>              move it
    \\    --sign-key=<file>             check its images against a public key, as `cosign
    \\                                  generate-key-pair` makes in cosign.pub
    \\    --keyless=<identity> [--issuer=<url>]
    \\                                  check them for a keyless signature, by a certificate
    \\                                  Sigstore's Fulcio gave <identity> (a workflow's URI, as
    \\                                  cosign's --certificate-identity takes it); the issuer is
    \\                                  GitHub Actions' unless given
    \\    --no-sign-key[=<fingerprint or identity>]
    \\                                  stop checking them for that one, or all added
    \\    --login [--username=<user>] [--password-stdin]
    \\                                  check and save a login for its registry
    \\    --logout                      delete its registry's saved login
    \\                                  (remote-add takes them too, but --url, --no-sign-key
    \\                                  and --logout)
    \\  remote-delete [--force] <name>  delete a remote, whose signatures counted for it, and
    \\                                  its registry's login when no other remote is there;
    \\                                  --force even if apps were installed from it
    \\
    \\Build and publish apps:
    \\  build [--clean[=<module>]] [--rebuild] [--no-resume] [--keep-build-dir]
    \\        [--memory=<size>] [--cpus=<n>] [--sandbox=auto|appcontainer|soft]
    \\        [<recipe.json> | <dir>]   build an app from a recipe, or from the zigsaw.json of a
    \\                                  project's directory (by default the current one), and
    \\                                  install it and its commands. A zigsaw.json that lists
    \\                                  "apps" builds and installs each of them, after those it
    \\                                  names by id, unpinned; one of them built alone builds
    \\                                  those first, without installing them. A build goes on
    \\                                  from the recipe's last one: modules whose inputs are the
    \\                                  same are skipped, and one that stopped goes on at its
    \\                                  command.
    \\                                  --clean deletes what that build left first, and
    \\                                  --clean=<module> starts that module and those after it
    \\                                  afresh; --rebuild builds every module in a new directory,
    \\                                  even if an earlier build had the same inputs; --no-resume
    \\                                  does too, unless such a build made the image already.
    \\                                  The builds kept may take 10 GB together; set
    \\                                  ZIGSAW_KEPT_BUILDS_SIZE (20GB, 500MB, 0) to change that.
    \\                                  --memory and --cpus hold each of the build's commands,
    \\                                  with all it starts, to that much memory and that many
    \\                                  processors, as they do a run (see below).
    \\                                  A recipe that says "contained": true has its build
    \\                                  commands run in a container without the network, where
    \\                                  Windows can (not Server 2025); --sandbox=appcontainer
    \\                                  runs any recipe's so, or fails, and soft none
    \\  build-export [--sources] <app-id> [<remote> | <image>]
    \\                                  publish an installed app to a remote, the first unless
    \\                                  given one, or as an image; --sources also keeps the
    \\                                  files it was built from next to it
    \\  build-update-repo [<remote>] <app-id>...
    \\                                  make a remote's catalog, the first's unless given one,
    \\                                  list these apps, as it has them
    \\  build-sign --print-payload <image>
    \\                                  print what to sign for an image, for `cosign sign-blob`
    \\  build-sign <image> <payload file> <signature file>
    \\                                  put a key's signature beside the image, where install
    \\                                  looks
    \\  build-sign --bundle <image> <payload file> <bundle file>
    \\                                  put a keyless one, as `cosign sign-blob --bundle` writes
    \\                                  it, beside the image, once it's checked
    \\  build-sign --check <image>      say whether an image has a good signature
    \\
    \\zigsaw's own, which Flatpak has no command for:
    \\  run -d [options] <app-id> [args]
    \\                                  run an installed app in the background, its output in
    \\                                  a log, and print the number `ps` lists it by
    \\  logs [-f] [--tail=<n>] [<app-id>|<run>]
    \\                                  print a detached run's log, as it goes or after it
    \\                                  ended; -f (--follow) goes on until the run ends; with
    \\                                  no app or run, in a project's directory, the logs of
    \\                                  the apps it lists as "run", each line after its app
    \\  up [-d] [--build] [-y] [<dir>]  start the apps a project's zigsaw.json lists as "run",
    \\                                  building those not installed from it and installing
    \\                                  those pinned there, each once the one before serves,
    \\                                  then follow their logs; Ctrl+C stops them. -d
    \\                                  (--detach) returns once they're up; --build builds all
    \\                                  first
    \\  down [--time=<seconds>] [<dir>] stop the apps `up` started, the last started first
    \\  volume create [--path=<dir>] <name>
    \\                                  make a volume in the store, or keep one in a folder of
    \\                                  yours; a run's --volume makes one it doesn't find
    \\  volume ls                       list the volumes, each app's own (its data, named by
    \\                                  its id) too, where each is, and what mounts it
    \\  volume inspect <name>           show a volume's size, mounts, use and grants
    \\  volume export [--all] <name> <file>
    \\                                  write a volume's files to a tar, .tar.gz by its name,
    \\                                  or - for stdout; an app's data by the app's id,
    \\                                  without its temporary files and cache unless --all
    \\  volume import [--replace] <name> <file>
    \\                                  make a tar's files (- for stdin) a volume's, a new
    \\                                  one or one with no files; --replace puts them in the
    \\                                  place of the files it has, which are deleted
    \\  volume rm <name>...             delete volumes in the store, or forget ones kept
    \\                                  elsewhere, leaving their files; not one an override
    \\                                  mounts, nor the data of an installed app
    \\  volume prune [--dry-run]        delete the volumes in the store that nothing mounts:
    \\                                  those no override names, and uninstalled apps' data
    \\  rollback [-y] <app-id>          go back to the version the installed one replaced, with
    \\                                  no network; updates then pass over the version left,
    \\                                  though not a newer one. Asks whether its data is to
    \\                                  go back too, to the copy kept of it as that version
    \\                                  left it: --data says yes, --keep-data no
    \\  rollback --data-only <app-id>   take the data back after a rollback that left it
    \\  doctor [--offline] [<app-id>]   look for what would make zigsaw fail here, in this
    \\                                  zigsaw, its store, its apps and the network, and say
    \\                                  what fixes each; changes nothing. --offline leaves out
    \\                                  the network; an app's id tells about that app at length
    \\  updates                         say what the last check found waiting, and whether a
    \\                                  daily check is on; neither installs anything
    \\  updates check                   look for updates of apps and zigsaw now
    \\  updates on|off                  start or stop the daily check; off is remembered, so
    \\                                  that installing or upgrading zigsaw leaves it off
    \\  upgrade [-y]                    install zigsaw's latest release over this one, once you
    \\                                  agree; -y (--yes) agrees without asking
    \\  version                         print zigsaw's version
    \\
    \\An image is <registry>/<repository>[:tag][@digest], e.g. ghcr.io/owner/node:24.21.0,
    \\or <app-id>[:tag][@digest] for the app's image in a remote: the one named before it,
    \\or else the first. A store has the remote zigsaw, ghcr.io/zigsaw-io, until told
    \\otherwise, so org.nodejs.node is ghcr.io/zigsaw-io/org.nodejs.node. ZIGSAW_REGISTRY
    \\moves the first remote, for this command. build-export goes to the app's image in
    \\the remote unless given one, and tags with the app's version unless given a tag.
    \\
    \\Publishing, and installing private images, needs a login. --login saves one per
    \\registry in Windows Credential Manager; --password-stdin reads the password from
    \\stdin. For CI and scripts, ZIGSAW_REGISTRY_USERNAME and ZIGSAW_REGISTRY_PASSWORD are
    \\used instead, but only for ZIGSAW_REGISTRY's registry, or ghcr.io. Without either, the
    \\login `docker login` saved is used. From a multi-platform index, install takes the
    \\image for windows/amd64. Blobs over 64 MiB are published in chunks of
    \\ZIGSAW_UPLOAD_CHUNK_SIZE bytes (0: in one request).
    \\
    \\With --format=json, list, info, remote-info (and --show-files), search, remote-ls,
    \\remotes, ps, mask, update --check, updates, permissions, volume ls, volume inspect,
    \\doctor and version print one JSON value on stdout in place of their text, with the
    \\keys docs/json.md lists; --format=text is their text. Exit codes and stderr stay.
    \\
    \\Before 0.105, zigsaw's commands were Docker's: pull is now install, rm uninstall, prune
    \\uninstall --unused, ls and cat remote-info, stop kill, kill kill --now, exec enter,
    \\hold and unhold mask, grants permissions, push build-export, signature build-sign,
    \\and login, logout and trust remote-modify; the old names fail, saying the new.
    \\
    \\run options (override takes them too, except -d, --command and --file):
    \\  -d, --detach                    run it in the background: print the run's number and
    \\                                  return; its output goes to a log (see logs)
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
    \\  --allow-host=<host>[:<port>]    let it reach this host, through zigsaw's proxy, when it
    \\                                  hasn't the network: a name, *.<domain> for the names
    \\                                  under it, an IPv4 address or an [IPv6] one; without a
    \\                                  port, 443 and 80. --unshare=network --allow-host=...
    \\                                  narrows an app that has the network to those
    \\  --noallow-host=<host>[:<port>]  take away a host the app or an override allows
    \\  --device=camera                 let it use the camera: under appcontainer, a run without
    \\                                  it gets none
    \\  --nodevice=camera               take away a device the app or an override gives
    \\  --share=commands               put your zigsaw apps' commands on its PATH, after the
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
    \\                                  it outlives the data, and other apps may mount it too;
    \\                                  the path . puts it in the place of the app's own
    \\                                  volume, as all of its data
    \\  --novolume=<path>               take away the mount an override has there
    \\  --ephemeral                     use a fresh data directory, deleted afterwards; the
    \\                                  volumes mounted in it stay
    \\  --memory=<size>                 let the app and all it starts have no more memory than
    \\                                  this together (2GB, 512MB): past it Windows refuses them
    \\                                  more, and zigsaw says so afterwards; none takes away
    \\                                  what an override has
    \\  --cpus=<n>                      run the app and all it starts on n processors, which
    \\                                  programs that ask Windows then count; NUMBER_OF_PROCESSORS
    \\                                  and CARGO_BUILD_JOBS say so to those that don't, unless
    \\                                  set already; all takes away what an override has
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
    \\A run with a list of hosts holds no network capability: under appcontainer, it reaches
    \\those hosts only through the proxy that HTTP_PROXY and HTTPS_PROXY name, and programs
    \\that don't use them reach nothing. Under soft and low, the list isn't enforced.
    \\
    \\Under appcontainer, a run opens the camera only with the camera device, its image's or
    \\yours, and through Media Foundation. At low integrity Windows opens it for no program;
    \\under soft, for any. The microphone, speakers, GPU and printers open in every sandbox,
    \\and USB, HID and Bluetooth devices under soft and low only: zigsaw can't change either.
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
    if (std.mem.eql(u8, command, "help") or isFlag(command, "help")) {
        Context.printStderr("{s}", .{usage});
        return 0;
    }
    if (movedCommand(command, args[1..])) |now|
        return fail("`zigsaw {s}` is `zigsaw {s}` since zigsaw 0.105, whose commands are Flatpak's; `zigsaw help` lists them", .{ command, now });
    // --format, wherever it is among the options: out, into ctx.format.
    const rest = try output.take(ctx, if (isFlag(command, "version")) "version" else command, args[1..]);
    if (std.mem.eql(u8, command, "version") or isFlag(command, "version")) {
        if (ctx.format == .json) {
            try output.write(ctx, .{ .version = options.version });
            return 0;
        }
        var buf: [64]u8 = undefined;
        var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
        try stdout.interface.print("zigsaw {s}\n", .{options.version});
        try stdout.interface.flush();
        return 0;
    }
    // Before the store is opened, which makes its folders, and before its
    // data is moved: doctor changes nothing (see doctor.zig).
    if (std.mem.eql(u8, command, "doctor")) {
        var opts: doctor.Options = .{};
        for (rest) |arg| {
            if (isFlag(arg, "offline")) {
                opts.offline = true;
            } else if (opts.app == null and !std.mem.startsWith(u8, arg, "-")) {
                opts.app = arg;
            } else return usageError();
        }
        return doctor.doctor(ctx, opts);
    }

    // What a build asks of a copy of zigsaw in its container (see
    // container.zig), which may read nothing else: no store.
    if (std.mem.eql(u8, command, "build-check")) {
        if (rest.len != 1) return usageError();
        return container.selfCheck(ctx.arena, ctx.io, rest[0]);
    }

    // A lazy layer's helper (see lazy.zig), which zigsaw starts, and nobody
    // else: the store it's for by its full path, whatever ZIGSAW_HOME says.
    if (std.mem.eql(u8, command, "lazy-helper")) {
        if (rest.len != 2) return usageError();
        try ctx.env.put("ZIGSAW_HOME", rest[0]);
        ctx.store = try .open(ctx.io, ctx.arena, ctx.env);
        ctx.store_open = true;
        return LazyHelper.main(ctx, rest[1]);
    }

    ctx.store = try .open(ctx.io, ctx.arena, ctx.env);
    ctx.store_open = true;
    ctx.store.verbose = ctx.verbose;
    // A store from before 0.85 keeps apps' data in data\: into their own
    // volumes, the apps' that aren't running (see volumes.zig). `repair`
    // then points their commands and shortcuts there.
    if (try volumes.adoptAll(ctx) and !std.mem.eql(u8, command, "repair"))
        note("note: `zigsaw repair` points the commands and shortcuts of those apps at where their data is now", .{});
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
            } else if (std.mem.startsWith(u8, arg, "--clean=") and arg.len > "--clean=".len) {
                opts.clean_from = arg["--clean=".len..];
            } else if (isFlag(arg, "no-resume")) {
                opts.no_resume = true;
            } else if (std.mem.startsWith(u8, arg, "--memory=")) {
                const value = arg["--memory=".len..];
                const bytes = override.parseMemory(value) orelse return fail(memory_expects, .{value});
                opts.limits.memory = if (bytes == 0) null else bytes;
            } else if (std.mem.startsWith(u8, arg, "--cpus=")) {
                const value = arg["--cpus=".len..];
                const n = override.parseCpus(value) orelse return fail(cpus_expects, .{value});
                opts.limits.cpus = if (n == 0) null else n;
            } else if (std.mem.startsWith(u8, arg, "--sandbox=")) {
                const value = arg["--sandbox=".len..];
                opts.sandbox = std.meta.stringToEnum(container.Sandbox, value) orelse
                    return fail("--sandbox expects auto, appcontainer or soft; got \"{s}\"", .{value});
            } else if (recipe_path == null and !std.mem.startsWith(u8, arg, "-")) {
                recipe_path = arg;
            } else return usageError();
        }
        _ = try ctx.store.lock(ctx.arena, .shared);
        const path = try builder.recipePath(ctx, recipe_path);
        if (try compose.read(ctx, path)) |p| {
            try compose.buildAll(ctx, p, opts);
        } else try install.install(ctx, try builder.build(ctx, path, opts));
        return 0;
    }
    if (std.mem.eql(u8, command, "install")) {
        var consent: remote.Consent = .ask;
        var words: std.ArrayList([]const u8) = .empty;
        var lazily = false;
        for (rest) |arg| {
            if (isFlag(arg, "yes")) {
                consent = .given;
            } else if (isFlag(arg, "lazy")) {
                lazily = true;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                try words.append(ctx.arena, arg);
            } else return usageError();
        }
        _ = try ctx.store.lock(ctx.arena, .shared);
        const image = try inRemote(ctx, words.items) orelse return usageError();
        try install.install(ctx, (try remote.fetch(ctx, image, .{ .consent = consent, .lazy = lazily })).?);
        return 0;
    }
    if (std.mem.eql(u8, command, "build-export")) {
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
        // A remote by its name, or an image.
        var image: ?[]const u8 = if (names.items.len == 2) names.items[1] else null;
        if (image) |name| if (remotes.isName(name)) if (try remotes.find(ctx, name)) |r| {
            ctx.remote = r.url;
            image = null;
        };
        try remote.push(ctx, names.items[0], image, opts);
        return 0;
    }
    if (std.mem.eql(u8, command, "build-update-repo")) {
        if (rest.len == 0) return usageError();
        for (rest) |arg| if (std.mem.startsWith(u8, arg, "-")) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        var ids: []const []const u8 = @ptrCast(rest);
        if (remotes.isName(ids[0])) if (try remotes.find(ctx, ids[0])) |r| {
            ctx.remote = r.url;
            ids = ids[1..];
        };
        if (ids.len == 0) return usageError();
        try catalog.push(ctx, ids);
        return 0;
    }
    if (std.mem.eql(u8, command, "build-sign")) return buildSignCommand(ctx, rest);
    if (std.mem.eql(u8, command, "search")) {
        for (rest) |arg| if (std.mem.startsWith(u8, arg, "-")) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        return catalog.search(ctx, @ptrCast(rest), null);
    }
    if (std.mem.eql(u8, command, "remote-ls")) {
        if (rest.len > 1) return usageError();
        for (rest) |arg| if (std.mem.startsWith(u8, arg, "-")) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        return catalog.search(ctx, &.{}, if (rest.len == 1) try remotes.named(ctx, rest[0]) else null);
    }
    if (std.mem.eql(u8, command, "remotes")) {
        if (rest.len != 0) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        try remotes.show(ctx);
        return 0;
    }
    if (std.mem.eql(u8, command, "remote-add") or std.mem.eql(u8, command, "remote-modify")) {
        const adding = std.mem.eql(u8, command, "remote-add");
        const parsed = try parseRemoteOptions(ctx, rest, adding);
        _ = try ctx.store.lock(ctx.arena, .shared);
        if (adding) {
            if (parsed.words.len != 2) return usageError();
            try remotes.add(ctx, parsed.words[0], parsed.words[1], parsed.changes, parsed.if_not_exists);
        } else {
            if (parsed.words.len != 1) return usageError();
            try remotes.modify(ctx, parsed.words[0], parsed.changes);
        }
        return 0;
    }
    if (std.mem.eql(u8, command, "remote-delete")) {
        var force = false;
        var name: ?[]const u8 = null;
        for (rest) |arg| {
            if (isFlag(arg, "force")) {
                force = true;
            } else if (name == null and !std.mem.startsWith(u8, arg, "-")) {
                name = arg;
            } else return usageError();
        }
        _ = try ctx.store.lock(ctx.arena, .shared);
        try remotes.delete(ctx, name orelse return usageError(), force);
        return 0;
    }
    if (std.mem.eql(u8, command, "info")) {
        if (rest.len != 1 or std.mem.startsWith(u8, rest[0], "-")) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        try info.installedInfo(ctx, rest[0]);
        return 0;
    }
    if (std.mem.eql(u8, command, "remote-info")) {
        var words: std.ArrayList([]const u8) = .empty;
        var files = false;
        var file: ?[]const u8 = null;
        for (rest) |arg| {
            if (isFlag(arg, "show-files")) {
                files = true;
            } else if (std.mem.startsWith(u8, arg, "--file=") and arg.len > "--file=".len) {
                file = arg["--file=".len..];
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                try words.append(ctx.arena, arg);
            } else return usageError();
        }
        if (files and file != null) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        const name = try inRemote(ctx, words.items) orelse return usageError();
        if (files) try peek.ls(ctx, name) else if (file) |path| try peek.cat(ctx, name, path) else try info.remoteInfo(ctx, name);
        return 0;
    }
    if (std.mem.eql(u8, command, "run")) return runtime.run(ctx, try parseRunOptions(ctx, rest));
    if (std.mem.eql(u8, command, "list")) {
        if (rest.len != 0) return usageError();
        try info.list(ctx);
        return 0;
    }
    if (std.mem.eql(u8, command, "ps")) {
        var opts: ps.Options = .{};
        var filters: std.ArrayList([]const u8) = .empty;
        for (rest) |arg| {
            if (isFlag(arg, "processes")) {
                opts.processes = true;
            } else if (std.mem.startsWith(u8, arg, "-")) {
                return usageError();
            } else try filters.append(ctx.arena, arg);
        }
        opts.filters = filters.items;
        try ps.ps(ctx, opts);
        return 0;
    }
    if (std.mem.eql(u8, command, "kill")) {
        var opts: stop.Options = .{};
        var timed = false;
        var filters: std.ArrayList([]const u8) = .empty;
        for (rest) |arg| {
            if (isFlag(arg, "now")) {
                opts.kill = true;
            } else if (std.mem.startsWith(u8, arg, "--time=")) {
                opts.seconds = std.fmt.parseInt(u32, arg["--time=".len..], 10) catch
                    return fail("--time takes a number of seconds, not {s}", .{arg["--time=".len..]});
                timed = true;
            } else if (std.mem.startsWith(u8, arg, "-")) {
                return usageError();
            } else try filters.append(ctx.arena, arg);
        }
        if (filters.items.len == 0 or (opts.kill and timed)) return usageError();
        opts.filters = filters.items;
        return stop.stop(ctx, opts);
    }
    if (std.mem.eql(u8, command, "enter")) return exec.exec(ctx, try parseExecOptions(ctx, rest));
    if (std.mem.eql(u8, command, "logs")) {
        var opts: logs.Options = .{};
        for (rest) |arg| {
            if (isFlag(arg, "follow") or std.mem.eql(u8, arg, "-f")) {
                opts.follow = true;
            } else if (std.mem.startsWith(u8, arg, "--tail=")) {
                opts.tail = std.fmt.parseInt(usize, arg["--tail=".len..], 10) catch
                    return fail("--tail takes a number of lines, not {s}", .{arg["--tail=".len..]});
            } else if (opts.target == null and !std.mem.startsWith(u8, arg, "-")) {
                opts.target = arg;
            } else return usageError();
        }
        return if (opts.target != null) logs.logs(ctx, opts) else up.projectLogs(ctx, opts);
    }
    if (std.mem.eql(u8, command, "up")) {
        var opts: up.UpOptions = .{};
        for (rest) |arg| {
            if (isFlag(arg, "detach") or std.mem.eql(u8, arg, "-d")) {
                opts.detach = true;
            } else if (isFlag(arg, "build")) {
                opts.build = true;
            } else if (isFlag(arg, "yes")) {
                opts.consent = .given;
            } else if (opts.dir == null and !std.mem.startsWith(u8, arg, "-")) {
                opts.dir = arg;
            } else return usageError();
        }
        return up.up(ctx, opts, &checkRunOptions);
    }
    if (std.mem.eql(u8, command, "down")) {
        var opts: up.DownOptions = .{};
        for (rest) |arg| {
            if (std.mem.startsWith(u8, arg, "--time=")) {
                opts.seconds = std.fmt.parseInt(u32, arg["--time=".len..], 10) catch
                    return fail("--time takes a number of seconds, not {s}", .{arg["--time=".len..]});
            } else if (opts.dir == null and !std.mem.startsWith(u8, arg, "-")) {
                opts.dir = arg;
            } else return usageError();
        }
        return up.down(ctx, opts);
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
        var data: ?rollback.Data = null;
        for (rest) |arg| {
            const chosen: ?rollback.Data = if (isFlag(arg, "data")) .take else if (isFlag(arg, "keep-data")) .keep else if (isFlag(arg, "data-only")) .only else null;
            if (chosen) |d| {
                if (data != null and data.? != d) return fail("--data, --keep-data and --data-only each say what becomes of the app's data: give one", .{});
                data = d;
            } else if (isFlag(arg, "yes")) {
                consent = .given;
            } else if (id == null and !std.mem.startsWith(u8, arg, "-")) {
                id = arg;
            } else return usageError();
        }
        _ = try ctx.store.lock(ctx.arena, .shared);
        try rollback.rollback(ctx, id orelse return usageError(), consent, data orelse .ask);
        return 0;
    }
    if (std.mem.eql(u8, command, "mask")) {
        var masking = true;
        var ids: std.ArrayList([]const u8) = .empty;
        for (rest) |arg| {
            if (isFlag(arg, "remove")) {
                masking = false;
            } else if (std.mem.startsWith(u8, arg, "-")) {
                return usageError();
            } else try ids.append(ctx.arena, arg);
        }
        _ = try ctx.store.lock(ctx.arena, .shared);
        if (ids.items.len == 0) {
            if (!masking) return usageError();
            try rollback.listHeld(ctx);
            return 0;
        }
        try rollback.setHeld(ctx, ids.items, masking);
        return 0;
    }
    if (std.mem.eql(u8, command, "updates")) return updatesCommand(ctx, rest);
    if (std.mem.eql(u8, command, "volume")) return volumeCommand(ctx, rest);
    if (std.mem.eql(u8, command, "upgrade")) {
        var consent: remote.Consent = .ask;
        for (rest) |arg| {
            if (isFlag(arg, "yes")) consent = .given else return usageError();
        }
        _ = try ctx.store.lock(ctx.arena, .shared);
        return upgrade.upgrade(ctx, consent);
    }
    if (std.mem.eql(u8, command, "uninstall")) {
        var delete_data = false;
        var unused = false;
        var opts: prune.Options = .{};
        var id: ?[]const u8 = null;
        for (rest) |arg| {
            if (isFlag(arg, "delete-data")) {
                delete_data = true;
            } else if (isFlag(arg, "unused")) {
                unused = true;
            } else if (isFlag(arg, "dry-run")) {
                opts.dry_run = true;
            } else if (isFlag(arg, "downloads")) {
                opts.downloads = true;
            } else if (isFlag(arg, "volumes")) {
                opts.volumes = true;
            } else if (isFlag(arg, "previous")) {
                opts.previous = true;
            } else if (isFlag(arg, "data")) {
                // What it deleted is a part of what --volumes does: nobody is
                // to delete more by habit.
                return fail("--data is --volumes from zigsaw 0.85: an app's data is its own volume, and --volumes deletes every volume nothing mounts, the named ones too; `zigsaw uninstall --unused --dry-run --volumes` shows which", .{});
            } else if (id == null and !std.mem.startsWith(u8, arg, "-")) {
                id = arg;
            } else return usageError();
        }
        if (unused) {
            // Nothing of one app's: what no installed app needs.
            if (id != null or delete_data) return usageError();
            _ = try ctx.store.lock(ctx.arena, .exclusive);
            try prune.prune(ctx, opts);
            return 0;
        }
        if (opts.dry_run or opts.downloads or opts.volumes or opts.previous) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        try remove(ctx, id orelse return usageError(), delete_data);
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
    if (std.mem.eql(u8, command, "permissions")) {
        if (rest.len > 1) return usageError();
        for (rest) |arg| if (std.mem.startsWith(u8, arg, "-")) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        try grants.show(ctx, if (rest.len == 1) rest[0] else null);
        return 0;
    }
    if (std.mem.eql(u8, command, "permission-remove")) {
        if (rest.len != 1 or std.mem.startsWith(u8, rest[0], "-")) return usageError();
        _ = try ctx.store.lock(ctx.arena, .shared);
        try grants.takeBackLabel(ctx, rest[0]);
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

/// `zigsaw volume`: the apps' own volumes, and the ones runs mount (see
/// volumes.zig).
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
        const pruned = try volumes.prune(ctx, dry_run);
        if (pruned.count == 0)
            note("no volume to remove: each is mounted by an app, kept outside the store, or in use", .{})
        else
            note("{s} {d} volume(s), {Bi:.1}", .{ if (dry_run) "would remove" else "removed", pruned.count, pruned.bytes });
        return 0;
    }
    const exporting = std.mem.eql(u8, what, "export");
    if (exporting or std.mem.eql(u8, what, "import")) {
        // --all for an export, --replace for an import; "-" is a file.
        var flag = false;
        var words: std.ArrayList([]const u8) = .empty;
        for (rest) |arg| {
            if (isFlag(arg, if (exporting) "all" else "replace")) {
                flag = true;
            } else if (std.mem.startsWith(u8, arg, "--")) {
                return usageError();
            } else try words.append(ctx.arena, arg);
        }
        if (words.items.len != 2) return usageError();
        if (exporting)
            try volumes.exportTo(ctx, words.items[0], words.items[1], flag)
        else
            try volumes.importFrom(ctx, words.items[0], words.items[1], flag);
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

/// `[<remote>] <image>`, as install and remote-info take it: the image, with
/// the remote named made where its app id is. Null if that isn't what's given.
fn inRemote(ctx: *Context, words: []const []const u8) !?[]const u8 {
    switch (words.len) {
        1 => return words[0],
        2 => {
            if (std.mem.indexOfScalar(u8, words[1], '/') != null)
                return fail("{s} is an image's full name, which needs no remote: give it alone, or the app's id after {s}", .{ words[1], words[0] });
            try remotes.use(ctx, words[0]);
            return words[1];
        },
        else => return null,
    }
}

const RemoteOptions = struct {
    words: []const []const u8,
    changes: remotes.Changes,
    if_not_exists: bool = false,
};

/// The options of `remote-add` (`adding`) and `remote-modify`.
fn parseRemoteOptions(ctx: *Context, args: []const [:0]const u8, adding: bool) !RemoteOptions {
    var words: std.ArrayList([]const u8) = .empty;
    var keys: std.ArrayList([]const u8) = .empty;
    var out: RemoteOptions = .{ .words = &.{}, .changes = .{} };
    const flags = [_][]const u8{ "if-not-exists", "login", "logout", "password-stdin", "no-sign-key" };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!std.mem.startsWith(u8, args[i], "--")) {
            try words.append(ctx.arena, args[i]);
            continue;
        }
        const opt = try Option.read(args, &i, &flags);
        const eql = std.mem.eql;
        const v = opt.value;
        if (eql(u8, opt.name, "sign-key") and v != null) {
            try keys.append(ctx.arena, v.?);
        } else if (eql(u8, opt.name, "keyless") and v != null) {
            out.changes.keyless = v;
        } else if (eql(u8, opt.name, "issuer") and v != null) {
            out.changes.issuer = v;
        } else if (eql(u8, opt.name, "login") and v == null) {
            out.changes.login = true;
        } else if (eql(u8, opt.name, "username") and v != null) {
            out.changes.username = v;
        } else if (eql(u8, opt.name, "password-stdin") and v == null) {
            out.changes.password_stdin = true;
        } else if (adding and eql(u8, opt.name, "if-not-exists") and v == null) {
            out.if_not_exists = true;
        } else if (!adding and eql(u8, opt.name, "url") and v != null) {
            out.changes.url = v;
        } else if (!adding and eql(u8, opt.name, "logout") and v == null) {
            out.changes.logout = true;
        } else if (!adding and eql(u8, opt.name, "no-sign-key")) {
            out.changes.no_sign_key = if (v) |w| .{ .one = w } else .all;
        } else {
            return fail("--{s} isn't an option of {s}", .{ opt.name, if (adding) "remote-add" else "remote-modify" });
        }
    }
    const c = out.changes;
    if (c.issuer != null and c.keyless == null) return fail("--issuer goes with --keyless", .{});
    if ((c.username != null or c.password_stdin) and !c.login) return fail("--username and --password-stdin go with --login", .{});
    if (c.login and c.logout) return fail("--login and --logout each say what becomes of the login: give one", .{});
    out.changes.sign_keys = keys.items;
    out.words = words.items;
    return out;
}

/// `zigsaw build-sign`: what scripts/sign-images.sh needs, on either side of
/// cosign's `sign-blob`, which is what signs: the payload to sign, a key's
/// signature or a keyless bundle put beside the image, and a check of it.
fn buildSignCommand(ctx: *Context, args: []const []const u8) !u32 {
    const Mode = enum { push, print_payload, bundle, check };
    var mode: Mode = .push;
    var words: std.ArrayList([]const u8) = .empty;
    for (args) |arg| {
        const chosen: ?Mode = if (isFlag(arg, "print-payload")) .print_payload else if (isFlag(arg, "bundle")) .bundle else if (isFlag(arg, "check")) .check else null;
        if (chosen) |m| {
            if (mode != .push) return usageError();
            mode = m;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageError();
        } else try words.append(ctx.arena, arg);
    }
    const want: usize = switch (mode) {
        .print_payload, .check => 1,
        .push, .bundle => 3,
    };
    if (words.items.len != want) return usageError();
    _ = try ctx.store.lock(ctx.arena, .shared);
    const image = words.items[0];
    switch (mode) {
        .print_payload => {
            const payload = try remote.signaturePayload(ctx, image);
            var buf: [4096]u8 = undefined;
            var stdout = Context.stdout().writerStreaming(ctx.io, &buf);
            try stdout.interface.writeAll(payload);
            try stdout.interface.flush();
            return 0;
        },
        .push, .bundle => {
            const cwd = std.Io.Dir.cwd();
            const payload = cwd.readFileAlloc(ctx.io, words.items[1], ctx.arena, .limited(signature.max_payload_size)) catch |err|
                return fail("reading {s}: {t}", .{ words.items[1], err });
            const limit: usize = if (mode == .bundle) @import("sigstore.zig").max_bundle_size else 4096;
            const text = cwd.readFileAlloc(ctx.io, words.items[2], ctx.arena, .limited(limit)) catch |err|
                return fail("reading {s}: {t}", .{ words.items[2], err });
            if (mode == .bundle) try remote.pushBundle(ctx, image, payload, text) else try remote.pushSignature(ctx, image, payload, text);
            return 0;
        },
        .check => {
            const target = try remote.resolve(ctx, image);
            var registry: @import("Registry.zig") = undefined;
            try registry.init(ctx, target.ref, "pull");
            defer registry.deinit();
            const digest = try remote.manifestDigest(ctx, image);
            return switch (try remote.checkSignature(ctx, &registry, target.ref, null, digest)) {
                .no_key => fail("{s}: no key here for its registry", .{image}),
                .missing => fail("{s}: not signed", .{image}),
                .wrong => |why| fail("{s}: {s}", .{ image, why }),
                .signed => |by| signed: {
                    note("{s}: signed, by {s}", .{ image, by });
                    break :signed 0;
                },
            };
        },
    }
}

/// The commands zigsaw had before 0.105, when they were Docker's, and what
/// each is now: they fail, saying so, rather than go on working under two
/// names.
fn movedCommand(command: []const u8, rest: []const []const u8) ?[]const u8 {
    const has = struct {
        fn flag(args: []const []const u8, name: []const u8) bool {
            for (args) |a| if (isFlag(a, name) or (std.mem.startsWith(u8, a, "--") and std.mem.startsWith(u8, a[2..], name) and a.len > name.len + 2 and a[name.len + 2] == '=')) return true;
            return false;
        }
    }.flag;
    const eql = std.mem.eql;
    if (eql(u8, command, "pull")) return "install";
    if (eql(u8, command, "push")) return if (has(rest, "catalog")) "build-update-repo" else "build-export";
    if (eql(u8, command, "rm")) return "uninstall";
    if (eql(u8, command, "prune")) return "uninstall --unused";
    if (eql(u8, command, "ls")) return "remote-info --show-files";
    if (eql(u8, command, "cat")) return "remote-info --file=<path>";
    if (eql(u8, command, "stop")) return "kill";
    if (eql(u8, command, "exec")) return "enter";
    if (eql(u8, command, "hold")) return "mask";
    if (eql(u8, command, "unhold")) return "mask --remove";
    if (eql(u8, command, "grants")) return if (has(rest, "take-back")) "permission-remove" else "permissions";
    if (eql(u8, command, "login")) return "remote-modify --login";
    if (eql(u8, command, "logout")) return "remote-modify --logout";
    if (eql(u8, command, "trust")) {
        const what = if (rest.len > 0) rest[0] else "";
        if (eql(u8, what, "add")) return if (has(rest, "keyless")) "remote-modify --keyless=<identity>" else "remote-modify --sign-key=<file>";
        if (eql(u8, what, "rm")) return "remote-modify --no-sign-key";
        return "remotes";
    }
    if (eql(u8, command, "signature")) {
        const what = if (rest.len > 0) rest[0] else "";
        if (eql(u8, what, "payload")) return "build-sign --print-payload";
        if (eql(u8, what, "push-bundle")) return "build-sign --bundle";
        if (eql(u8, what, "check")) return "build-sign --check";
        return "build-sign";
    }
    return null;
}

test movedCommand {
    try std.testing.expectEqualStrings("install", movedCommand("pull", &.{"org.nodejs.node"}).?);
    try std.testing.expectEqualStrings("build-update-repo", movedCommand("push", &.{ "--catalog", "a.b" }).?);
    try std.testing.expectEqualStrings("permission-remove", movedCommand("grants", &.{ "--take-back", "C:\\x" }).?);
    try std.testing.expectEqualStrings("permission-remove", movedCommand("grants", &.{"--take-back=C:\\x"}).?);
    try std.testing.expectEqualStrings("permissions", movedCommand("grants", &.{"org.a.b"}).?);
    try std.testing.expectEqualStrings("build-sign --bundle", movedCommand("signature", &.{ "push-bundle", "x", "p", "b" }).?);
    try std.testing.expectEqualStrings("remote-modify --login", movedCommand("login", &.{"ghcr.io"}).?);
    try std.testing.expectEqualStrings("remote-modify --keyless=<identity>", movedCommand("trust", &.{ "add", "ghcr.io/me", "--keyless", "x" }).?);
    try std.testing.expectEqualStrings("remotes", movedCommand("trust", &.{}).?);
    try std.testing.expect(movedCommand("run", &.{}) == null);
    try std.testing.expect(movedCommand("kill", &.{}) == null);
}

fn usageError() error{Failed} {
    Context.printStderr("{s}", .{usage});
    return error.Failed;
}

fn isFlag(arg: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, name, "verbose") and std.mem.eql(u8, arg, "-v")) return true;
    // Flatpak's way of agreeing ahead.
    if (std.mem.eql(u8, name, "yes") and std.mem.eql(u8, arg, "-y")) return true;
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

const memory_expects = "--memory expects a size, such as 2GB or 512MB, or none; got \"{s}\"";
const cpus_expects = "--cpus expects a number of processors, from 1, or all; got \"{s}\"";

/// Collects the run options that `run` and `override` share.
const SettingsParser = struct {
    settings: override.Settings = .{},
    filesystem: std.ArrayList([]const u8) = .empty,
    nofilesystem: std.ArrayList([]const u8) = .empty,
    hosts: std.ArrayList([]const u8) = .empty,
    nohosts: std.ArrayList([]const u8) = .empty,
    devices: std.ArrayList([]const u8) = .empty,
    nodevices: std.ArrayList([]const u8) = .empty,
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
        } else if (std.mem.eql(u8, name, "allow-host") or std.mem.eql(u8, name, "noallow-host")) {
            if (hosts.parse(value) == null) return fail("--{s}={s}: a host {s}", .{ name, value, hosts.invalid_message });
            try (if (name[0] == 'n') &p.nohosts else &p.hosts).append(arena, value);
        } else if (std.mem.eql(u8, name, "device") or std.mem.eql(u8, name, "nodevice")) {
            // Kept as images write it, so that the layers' names compare.
            const device = oci.Device.parse(value) orelse
                return fail("--{s} takes a device zigsaw knows, which is only {s}; got \"{s}\"", .{ name, oci.Device.list, value });
            try (if (name[0] == 'n') &p.nodevices else &p.devices).append(arena, @tagName(device));
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
        } else if (std.mem.eql(u8, name, "memory")) {
            p.settings.memory = override.parseMemory(value) orelse return fail(memory_expects, .{value});
        } else if (std.mem.eql(u8, name, "cpus")) {
            p.settings.cpus = override.parseCpus(value) orelse return fail(cpus_expects, .{value});
        } else return false;
        return true;
    }

    fn finish(p: *const SettingsParser) override.Settings {
        var s = p.settings;
        s.filesystem = p.filesystem.items;
        s.nofilesystem = p.nofilesystem.items;
        s.hosts = p.hosts.items;
        s.nohosts = p.nohosts.items;
        s.devices = p.devices.items;
        s.nodevices = p.nodevices.items;
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
    // As given, for a detached run's zigsaw, which takes them again.
    var given: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, args[i], "-d")) {
            opts.detach = true;
            continue;
        }
        if (!std.mem.startsWith(u8, args[i], "--")) break;
        const first = i;
        const opt = try Option.read(args, &i, &(SettingsParser.flags ++ [_][]const u8{ "verbose", "detach", "detached-child" }));
        if (std.mem.eql(u8, opt.name, "detach") and opt.value == null) {
            opts.detach = true;
            continue;
        }
        try given.appendSlice(ctx.arena, @ptrCast(args[first .. i + 1]));
        if (std.mem.eql(u8, opt.name, "verbose") and opt.value == null) {
            ctx.verbose = true;
            ctx.store.verbose = true;
        } else if (std.mem.eql(u8, opt.name, "detached-child") and opt.value == null) {
            opts.detached_child = true;
        } else if (opts.detached_child and std.mem.eql(u8, opt.name, "project") and opt.value != null) {
            opts.project = opt.value;
        } else if (opts.detached_child and std.mem.eql(u8, opt.name, "entry") and opt.value != null) {
            opts.entry = opt.value;
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
    opts.given = given.items;
    return opts;
}

/// For `up`: an entry of a project's "run", checked as `run` would take it.
fn checkRunOptions(ctx: *Context, args: []const [:0]const u8) anyerror!void {
    const opts = try parseRunOptions(ctx, args);
    if (opts.detach) return fail("--detach: `zigsaw up` starts every app detached already", .{});
}

/// Options go before the run, as for `run`; the command and everything
/// after it are the command's. "--" also ends zigsaw's options.
fn parseExecOptions(ctx: *Context, args: []const [:0]const u8) !exec.Options {
    var env: std.ArrayList([]const u8) = .empty;
    var detach = false;
    var detached_child = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (!std.mem.startsWith(u8, arg, "-")) break;
        if (isFlag(arg, "verbose")) {
            ctx.verbose = true;
            ctx.store.verbose = true;
        } else if (isFlag(arg, "detach") or std.mem.eql(u8, arg, "-d")) {
            detach = true;
        } else if (isFlag(arg, "detached-child")) {
            detached_child = true;
        } else if (std.mem.startsWith(u8, arg, "--env=")) {
            try env.append(ctx.arena, arg["--env=".len..]);
        } else if (std.mem.eql(u8, arg, "--env") and i + 1 < args.len) {
            i += 1;
            try env.append(ctx.arena, args[i]);
        } else return fail("unknown exec option {s}", .{arg});
    }
    if (args.len - i < 2) return usageError();
    return .{
        .target = args[i],
        .command = args[i + 1],
        .args = @ptrCast(args[i + 2 ..]),
        .env = env.items,
        .detach = detach or detached_child,
        .detached_child = detached_child,
    };
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
    var keep_data: ?bool = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!std.mem.startsWith(u8, args[i], "--")) {
            if (id != null) return usageError();
            id = args[i];
            continue;
        }
        const opt = try Option.read(args, &i, &(SettingsParser.flags ++ [_][]const u8{ "show", "reset", "global", "real-folders", "noreal-folders", "snapshot", "nosnapshot" }));
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
        } else if (opt.value == null and std.mem.eql(u8, opt.name, "snapshot")) {
            keep_data = true;
        } else if (opt.value == null and std.mem.eql(u8, opt.name, "nosnapshot")) {
            keep_data = false;
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
    new.snapshot = keep_data;

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
    // Its detached runs' logs, but those still being written.
    _ = try logs.deleteEnded(store, arena, .{ .app = id });
    // The keys the app keeps, if a run that didn't end left them in HKCU:
    // back into its data, before that goes too.
    try hkcu.settleLeftovers(ctx, id);

    try store.deleteRef(arena, id);
    // Its previous version, whose blobs prune then deletes, the data kept as
    // that one left it, and whether it was held: a new install starts afresh.
    try snapshot.finishSwap(ctx, id);
    if (try snapshot.forget(ctx, id)) |kept|
        note("deleted its data as {s} left it ({Bi:.1}), kept for `zigsaw rollback`", .{ kept.version, kept.bytes });
    try store.forgetVersions(arena, id);
    {
        const aliases_lock = try store.lockAliases(arena, id);
        defer aliases_lock.release(io);
        Store.deleteTree(io, arena, try store.aliasDir(arena, id)) catch
            note("kept {s}'s alias shims, which are in use; `zigsaw uninstall --unused` removes them later", .{id});
    }
    // An app whose manifest is gone (`zigsaw doctor` says so) doesn't say
    // which files are its own: prune finds them, now nothing uses them.
    const manifest_there = if (oci.digestHex(ref.manifest)) |hex| try Store.exists(io, try store.blobPath(arena, hex)) else false;
    if (!manifest_there) {
        note("its manifest is gone, so its files stay until `zigsaw uninstall --unused`", .{});
    } else if (try store.deleteUnusedDeployments(arena, ref.manifest)) {
        note("kept {s}'s files, which are still in use; `zigsaw uninstall --unused` removes them later", .{id});
    }
    // Its own volume, its data, goes only if asked. Deleting it stops at the
    // junctions of the volumes it mounted (see volumes.zig), which stay.
    var kept_volumes: []const []const u8 = &.{};
    if (delete_data) {
        kept_volumes = try volumes.namedIn(arena, (try override.load(store, arena, id)).volumes);
        const data_dir = try store.dataDir(arena, id);
        try Store.deleteTree(io, arena, data_dir);
        Io.Dir.cwd().deleteFile(io, try std.fmt.allocPrint(arena, "{s}.hkcu.lock", .{data_dir})) catch {};
        // And what a zigsaw before 0.85 left that couldn't move there.
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
    _ = @import("checkpoint.zig");
    _ = @import("ps.zig");
    _ = @import("stop.zig");
    _ = @import("exec.zig");
    _ = @import("logs.zig");
    _ = @import("catalog.zig");
    _ = @import("cloudfiles.zig");
    _ = @import("credentials.zig");
    _ = @import("deps.zig");
    _ = @import("doctor.zig");
    _ = @import("drive.zig");
    _ = @import("environment.zig");
    _ = @import("exports.zig");
    _ = @import("extensions.zig");
    _ = @import("folders.zig");
    _ = @import("format.zig");
    _ = @import("gitignore.zig");
    _ = @import("grants.zig");
    _ = @import("hkcu.zig");
    _ = @import("hosts.zig");
    _ = @import("proxy.zig");
    _ = @import("info.zig");
    _ = @import("junction.zig");
    _ = @import("msvc.zig");
    _ = @import("net.zig");
    _ = @import("oci.zig");
    _ = @import("output.zig");
    _ = @import("override.zig");
    _ = @import("pe.zig");
    _ = @import("process.zig");
    _ = @import("project.zig");
    _ = @import("compose.zig");
    _ = @import("prompt.zig");
    _ = @import("prune.zig");
    _ = @import("recipe.zig");
    _ = @import("regkey.zig");
    _ = @import("Registry.zig");
    _ = @import("remote.zig");
    _ = @import("remotes.zig");
    _ = @import("roots.zig");
    _ = @import("rollback.zig");
    _ = @import("snapshot.zig");
    _ = @import("layer.zig");
    _ = @import("learned.zig");
    _ = @import("ledger.zig");
    _ = @import("run.zig");
    _ = @import("schedule.zig");
    _ = @import("services.zig");
    _ = @import("signature.zig");
    _ = @import("sigstore.zig");
    _ = @import("archive.zig");
    _ = @import("der.zig");
    _ = @import("merkle.zig");
    _ = @import("timestamp.zig");
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
