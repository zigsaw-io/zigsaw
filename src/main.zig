const std = @import("std");
const Io = std.Io;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const acl = @import("acl.zig");
const appcontainer = @import("appcontainer.zig");
const builder = @import("builder.zig");
const exports = @import("exports.zig");
const remote = @import("remote.zig");
const runtime = @import("run.zig");
const win32 = @import("win32.zig");
const fail = Context.fail;
const note = Context.note;

const usage =
    \\usage: zigsaw [-v|--verbose] <command> [options]
    \\
    \\commands:
    \\  build <recipe.json>             build an app from a recipe, install it and its commands
    \\  pull <image>                    install an app and its commands from a registry
    \\  push <app-id> <image>           publish an installed app to a registry
    \\  run [options] <app-id> [args]   run an installed app
    \\  list                            list installed apps and their commands
    \\  rm [--delete-data] <app-id>     uninstall an app and its commands
    \\
    \\An image is <registry>/<repository>[:tag][@digest], e.g. ghcr.io/owner/node:24.21.0.
    \\push tags with the app's version unless given a tag. Registry credentials, needed
    \\to push and for private images, come from ZIGSAW_REGISTRY_USERNAME and
    \\ZIGSAW_REGISTRY_PASSWORD.
    \\
    \\run options:
    \\  --command=<name>                run one of the app's exported commands, or another
    \\                                  executable from the app or System32
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
        std.debug.print("{s}", .{usage});
        return 0;
    }

    ctx.store = try .open(ctx.io, ctx.arena, ctx.env);
    ctx.store.verbose = ctx.verbose;
    if (std.mem.eql(u8, command, "build")) {
        if (rest.len != 1) return usageError();
        try builder.build(ctx, rest[0]);
        return 0;
    }
    if (std.mem.eql(u8, command, "pull")) {
        if (rest.len != 1) return usageError();
        try remote.pull(ctx, rest[0]);
        return 0;
    }
    if (std.mem.eql(u8, command, "push")) {
        if (rest.len != 2) return usageError();
        try remote.push(ctx, rest[0], rest[1]);
        return 0;
    }
    if (std.mem.eql(u8, command, "run")) return runtime.run(ctx, try parseRunOptions(ctx, rest));
    if (std.mem.eql(u8, command, "list")) {
        if (rest.len != 0) return usageError();
        try list(ctx);
        return 0;
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
        try remove(ctx, id orelse return usageError(), delete_data);
        return 0;
    }
    return usageError();
}

fn usageError() error{Failed} {
    std.debug.print("{s}", .{usage});
    return error.Failed;
}

fn isFlag(arg: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, name, "verbose") and std.mem.eql(u8, arg, "-v")) return true;
    return arg.len == name.len + 2 and std.mem.startsWith(u8, arg, "--") and std.mem.eql(u8, arg[2..], name);
}

/// Options go before the app id, like `flatpak run`; everything after the id
/// belongs to the app. "--" also ends zigsaw's options.
fn parseRunOptions(ctx: *Context, args: []const [:0]const u8) !runtime.Options {
    const arena = ctx.arena;
    var opts: runtime.Options = .{ .id = undefined };
    var filesystem: std.ArrayList([]const u8) = .empty;
    var env: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (!std.mem.startsWith(u8, arg, "--")) break;

        // Accept both "--name=value" and "--name value".
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const name = arg[2 .. eq orelse arg.len];
        if (std.mem.eql(u8, name, "ephemeral") and eq == null) {
            opts.ephemeral = true;
            continue;
        }
        if (std.mem.eql(u8, name, "verbose") and eq == null) {
            ctx.verbose = true;
            ctx.store.verbose = true;
            continue;
        }
        const value = if (eq) |e| arg[e + 1 ..] else blk: {
            i += 1;
            if (i == args.len) return fail("--{s} needs a value", .{name});
            break :blk args[i];
        };

        if (std.mem.eql(u8, name, "command")) {
            opts.command = value;
        } else if (std.mem.eql(u8, name, "sandbox")) {
            opts.sandbox = std.meta.stringToEnum(runtime.Sandbox, value) orelse
                return fail("--sandbox must be soft or appcontainer", .{});
        } else if (std.mem.eql(u8, name, "filesystem")) {
            try filesystem.append(arena, value);
        } else if (std.mem.eql(u8, name, "share") or std.mem.eql(u8, name, "unshare")) {
            if (!std.mem.eql(u8, value, "network")) return fail("--{s} only supports network", .{name});
            opts.network = std.mem.eql(u8, name, "share");
        } else if (std.mem.eql(u8, name, "env")) {
            try env.append(arena, value);
        } else {
            return fail("unknown run option --{s}", .{name});
        }
    }
    if (i == args.len) return usageError();

    opts.id = args[i];
    opts.args = @ptrCast(args[i + 1 ..]);
    opts.filesystem = filesystem.items;
    opts.env = env.items;
    return opts;
}

fn list(ctx: *Context) !void {
    const arena = ctx.arena;
    const refs = try ctx.store.listRefs(arena);
    const shims = try exports.list(ctx);
    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(ctx.io, &buf);
    const w = &stdout.interface;
    try w.print("{s:<32} {s:<20} {s:<20} {s}\n", .{ "ID", "VERSION", "MANIFEST", "EXPORTS" });
    for (refs) |ref| {
        const short = ref.manifest[0..@min(ref.manifest.len, "sha256:".len + 12)];
        var names: std.ArrayList([]const u8) = .empty;
        for (shims) |s| if (std.mem.eql(u8, s.sidecar.app, ref.id)) try names.append(arena, s.name);
        try w.print("{s:<32} {s:<20} {s:<20} {s}\n", .{ ref.id, ref.version, short, try std.mem.join(arena, ", ", names.items) });
    }
    try w.flush();
}

fn remove(ctx: *Context, id: []const u8, delete_data: bool) !void {
    const io = ctx.io;
    const arena = ctx.arena;
    const store = ctx.store;
    const ref = try store.readRef(arena, id) orelse return fail("{s} is not installed", .{id});

    const removed_exports = try exports.removeAll(ctx, id);
    if (removed_exports.len > 0) note("removed exports {s}", .{try std.mem.join(arena, ", ", removed_exports)});

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
    // The deployment can be shared with another app built from identical inputs.
    var shared = false;
    for (try store.listRefs(arena)) |other| {
        if (std.mem.eql(u8, other.manifest, ref.manifest)) shared = true;
    }
    if (!shared) try store.deleteDeployment(arena, ref.manifest);
    if (delete_data) try Io.Dir.cwd().deleteTree(io, try store.path(arena, &.{ "data", id }));

    note("removed {s} {s}{s}", .{ id, ref.version, if (delete_data) " and its data" else "" });
}

test {
    _ = @import("builder.zig");
    _ = @import("exports.zig");
    _ = @import("oci.zig");
    _ = @import("process.zig");
    _ = @import("recipe.zig");
    _ = @import("Registry.zig");
    _ = @import("layer.zig");
    _ = @import("run.zig");
    _ = @import("Sidecar.zig");
    _ = @import("zipfile.zig");
}
