const std = @import("std");
const Io = std.Io;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const appcontainer = @import("appcontainer.zig");
const builder = @import("builder.zig");
const runtime = @import("run.zig");
const win32 = @import("win32.zig");
const fail = Context.fail;
const note = Context.note;

const usage =
    \\usage: zigsaw [-v|--verbose] <command> [options]
    \\
    \\commands:
    \\  build <recipe.json>             build an app from a recipe and install it
    \\  run [options] <app-id> [args]   run an installed app
    \\  list                            list installed apps
    \\  rm [--delete-data] <app-id>     uninstall an app
    \\
    \\run options:
    \\  --command=<exe>                 run another executable from the app, or from System32
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
    if (std.mem.eql(u8, command, "build")) {
        if (rest.len != 1) return usageError();
        try builder.build(ctx, rest[0]);
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
    const refs = try ctx.store.listRefs(ctx.arena);
    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(ctx.io, &buf);
    const w = &stdout.interface;
    try w.print("{s:<32} {s:<20} {s}\n", .{ "ID", "VERSION", "MANIFEST" });
    for (refs) |ref| {
        const short = ref.manifest[0..@min(ref.manifest.len, "sha256:".len + 12)];
        try w.print("{s:<32} {s:<20} {s}\n", .{ ref.id, ref.version, short });
    }
    try w.flush();
}

fn remove(ctx: *Context, id: []const u8, delete_data: bool) !void {
    const io = ctx.io;
    const arena = ctx.arena;
    const store = ctx.store;
    const ref = try store.readRef(arena, id) orelse return fail("{s} is not installed", .{id});

    // Undo ACL grants on host paths made for the app's AppContainer.
    const host_grants = try store.readGrants(arena, id);
    if (host_grants.len > 0) {
        const profile = try appcontainer.Profile.ensure(arena, id);
        for (host_grants) |p| {
            appcontainer.revoke(arena, p, profile.sid) catch |err| switch (err) {
                error.Failed => continue, // Logged; the path may be gone.
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
    if (!shared) try Io.Dir.cwd().deleteTree(io, try store.deployPath(arena, ref.manifest));
    if (delete_data) try Io.Dir.cwd().deleteTree(io, try store.path(arena, &.{ "data", id }));

    note("removed {s} {s}{s}", .{ id, ref.version, if (delete_data) " and its data" else "" });
}

test {
    _ = @import("oci.zig");
    _ = @import("recipe.zig");
    _ = @import("layer.zig");
    _ = @import("run.zig");
}
