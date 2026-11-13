//! `zigsaw exec`: a command in a run that's going, as the run's own app
//! goes: in its job, with its token or AppContainer identity, its variables
//! and its working directory. So it has what the run has: its data
//! directory (an --ephemeral one too), its volumes and grants, its keys in
//! HKCU, its relay and ports, and the limits of its job.
//!
//! The run writes down how it starts programs, in running\<pid>.spec beside
//! its record (see ps.zig), labelled so that nothing below medium integrity
//! may read it: its variables hold what --env gave it. `exec` reads that,
//! and starts the command itself, on its own console, in the run's job and
//! in a job of its own nested in that one. The run's limits hold it, the run
//! ending ends it, and so does its exec ending, as a run's app ends with its
//! zigsaw.
//!
//! An exec keeps a record of its own (kind exec), which names the run it's
//! in: `zigsaw ps` lists it under that run, and `zigsaw stop` asks it, and
//! ends it by its own job, as it does a run.
//!
//! `--detach` starts a zigsaw of its own (`exec --detached-child`) to start
//! the command and wait for it, with no console; that one says on a pipe
//! whether the command started, then goes on alone.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const acl = @import("acl.zig");
const appcontainer = @import("appcontainer.zig");
const environment = @import("environment.zig");
const process = @import("process.zig");
const ps = @import("ps.zig");
const runtime = @import("run.zig");
const stop = @import("stop.zig");
const win32 = @import("win32.zig");
const fail = Context.fail;
const note = Context.note;

/// One of the app's exports, as the run would start it.
pub const Export = struct {
    name: []const u8,
    exe: []const u8,
    args: []const []const u8 = &.{},
};

/// How a run starts programs: running\<pid>.spec.
pub const Spec = struct {
    id: []const u8,
    /// The run's job's name.
    job: []const u8,
    /// soft, low or appcontainer.
    sandbox: []const u8,
    /// An AppContainer run's capabilities, as string SIDs: the app's own
    /// first, then the network's and the devices'.
    capabilities: []const []const u8 = &.{},
    cwd: []const u8,
    env: []const environment.Var,
    /// The directories commands are looked up in before System32: the
    /// aliases', the app's, its runtimes' and its extensions'.
    path: []const []const u8,
    deploy_dir: []const u8,
    system_root: []const u8,
    exports: []const Export = &.{},
};

// ---------------------------------------------------------------------------
// The run's side

/// Writes the run's spec beside its record. Only -v says if it can't: then
/// `exec` can't join the run, and says so.
pub fn writeSpec(ctx: *const Context, entry: ps.Entry, spec: Spec) void {
    writeSpecIn(ctx.store, ctx.arena, entry.lock_path, spec) catch |err| {
        if (ctx.verbose) note("note: `zigsaw exec` can't join this run: its spec couldn't be written ({t})", .{err});
    };
}

fn writeSpecIn(store: Store, arena: Allocator, lock_path: []const u8, spec: Spec) !void {
    // Below medium, the label wouldn't keep the runs below out.
    if (try acl.belowMedium()) return error.BelowMediumIntegrity;
    const json = try std.json.Stringify.valueAlloc(arena, spec, .{});
    const tmp = try store.tmpPath(arena, "spec");
    acl.writeUnreadableBelowMedium(arena, tmp, json) catch |err| {
        Io.Dir.cwd().deleteFile(store.io, tmp) catch {};
        return err;
    };
    Io.Dir.rename(.cwd(), tmp, .cwd(), try ps.specPath(arena, lock_path), store.io) catch |err| {
        Io.Dir.cwd().deleteFile(store.io, tmp) catch {};
        return err;
    };
}

/// An AppContainer run's capabilities, as string SIDs, for its spec. Fails
/// with nothing printed: the run goes on all the same.
pub fn capabilityStrings(arena: Allocator, security: win32.SECURITY_CAPABILITIES) ![]const []const u8 {
    const caps = security.Capabilities orelse return &.{};
    const out = try arena.alloc([]const u8, security.CapabilityCount);
    for (out, caps[0..security.CapabilityCount]) |*s, c| {
        var text: ?[*:0]u16 = null;
        if (win32.ConvertSidToStringSidW(c.Sid, &text) == 0) return error.ConvertSidToStringSid;
        defer _ = win32.LocalFree(text);
        s.* = try std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.span(text.?));
    }
    return out;
}

// ---------------------------------------------------------------------------
// The command

pub const Options = struct {
    /// An app's id, with one run going, or a run's PID.
    target: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    /// "NAME=VALUE", over the run's variables.
    env: []const []const u8 = &.{},
    detach: bool = false,
    /// This is the zigsaw `--detach` started (see `detach`).
    detached_child: bool = false,
};

pub fn exec(ctx: *Context, opts: Options) !u32 {
    const arena = ctx.arena;
    const run = try findRun(ctx, opts.target);
    // Its zigsaw, still that run's: its lock is held.
    const run_zigsaw = try stop.openZigsaw(ctx.store, arena, run) orelse
        return fail("run {d} ({s}) has ended", .{ run.pid, run.id });
    defer _ = win32.CloseHandle(run_zigsaw);
    const spec = try readSpec(ctx, run, run_zigsaw);
    const prepared = try prepare(ctx, spec, opts);
    if (opts.detach and !opts.detached_child) return detach(ctx, opts);

    // The app, whose end is the run's: it ends the command too.
    const app = if (run.app_pid) |pid| win32.OpenProcess(win32.SYNCHRONIZE | win32.PROCESS_QUERY_LIMITED_INFORMATION, win32.FALSE, pid) else null;
    defer if (app) |h| {
        _ = win32.CloseHandle(h);
    };
    if (app == null or win32.WaitForSingleObject(app.?, 0) == win32.WAIT_OBJECT_0)
        return fail("run {d} ({s}) is ending", .{ run.pid, run.id });

    const run_job = win32.OpenJobObjectW(win32.JOB_OBJECT_ASSIGN_PROCESS | win32.JOB_OBJECT_QUERY, win32.FALSE, try win32.wide(arena, spec.job)) orelse
        return fail("can't open the job of run {d} ({s}): error {d} ({s})", .{ run.pid, run.id, win32.GetLastError(), win32.errorName(win32.GetLastError()) });
    var run_job_open = true;
    defer if (run_job_open) {
        _ = win32.CloseHandle(run_job);
    };
    const job = try process.newJob(arena, .{}, try ps.jobName(ctx.io, arena));
    const label = try std.fmt.allocPrint(arena, "the command in {s}'s run {d}", .{ run.id, run.pid });
    const asker = stop.Asker.create(ctx, label);
    const nul = if (opts.detached_child) try openNul(arena) else null;
    const started = ps.now();
    const handle = try process.startIn(arena, job.handle, .{
        .exe = prepared.exe,
        .command_line = prepared.command_line,
        .env_block = prepared.env_block,
        .cwd = spec.cwd,
        .security = if (prepared.security) |*s| s else null,
        .token = prepared.token,
        .outer_jobs = &.{run_job},
        // Detached: no console of its own, and none of ours.
        .creation_flags = if (nul != null) win32.CREATE_NO_WINDOW else 0,
        .stdio = if (nul) |h| .{ h, h, h } else null,
    });
    // The run's job ends what's left in it when its zigsaw lets go of it:
    // not when this one does.
    _ = win32.CloseHandle(run_job);
    run_job_open = false;
    var child: process.Child = .in(job, handle);
    // A job the run ended a moment ago still takes processes, which then go
    // on until the run's zigsaw lets go of it.
    if (win32.WaitForSingleObject(app.?, 0) == win32.WAIT_OBJECT_0) {
        _ = try child.waitFor(0);
        return fail("run {d} ({s}) ended as the command started", .{ run.pid, run.id });
    }
    // Kept to tell when the command ended, after `child` lets go of it.
    const command_process = win32.OpenProcess(win32.SYNCHRONIZE | win32.PROCESS_QUERY_LIMITED_INFORMATION, win32.FALSE, win32.GetProcessId(handle));
    defer if (command_process) |h| {
        _ = win32.CloseHandle(h);
    };
    if (asker) |a| child.stop = a.stop();
    const listed = ps.begin(ctx, .{
        .kind = .exec,
        .id = run.id,
        .version = run.version,
        .manifest = run.manifest,
        .pid = win32.GetCurrentProcessId(),
        .app_pid = win32.GetProcessId(handle),
        .run = run.pid,
        .started = started,
        .job = job.name,
        .stop = if (asker) |a| a.name else null,
        .sandbox = run.sandbox,
        .network = run.network,
        .memory_limit = run.memory_limit,
        .cpus = run.cpus,
        .ephemeral = run.ephemeral,
        .command = prepared.command_line,
    });
    defer if (listed) |l| l.end(ctx.io);
    if (opts.detached_child) try tellStarted(ctx, nul.?);

    const report = try child.waitReport();
    // Ended by the run's ending: then the command ended after the app did.
    if (ranOut(app.?, command_process)) {
        note("zigsaw: {s}'s run {d} ended, and with it this command", .{ run.id, run.pid });
        return if (report.code == 0) 1 else report.code;
    }
    return report.code;
}

/// Whether the run's app ended, and the command no sooner.
fn ranOut(app: win32.HANDLE, command: ?win32.HANDLE) bool {
    if (win32.WaitForSingleObject(app, 0) != win32.WAIT_OBJECT_0) return false;
    const app_end = exitTime(app) orelse return true;
    const command_end = exitTime(command orelse return true) orelse return true;
    return command_end >= app_end;
}

fn exitTime(h: win32.HANDLE) ?i64 {
    var created: i64 = 0;
    var exited: i64 = 0;
    var kernel: i64 = 0;
    var user: i64 = 0;
    if (win32.GetProcessTimes(h, &created, &exited, &kernel, &user) == 0) return null;
    return exited;
}

/// The run `target` names: its record. Builds and execs are refused; an app
/// with more than one run going has to be named by the run.
fn findRun(ctx: *Context, target: []const u8) !ps.Record {
    const arena = ctx.arena;
    const by_pid = std.fmt.parseInt(u32, target, 10) catch null;
    var runs: std.ArrayList(ps.Record) = .empty;
    for (try ps.live(ctx.store, arena)) |r| {
        if (!ps.matches(r, &.{target})) continue;
        switch (r.kind) {
            .run => try runs.append(arena, r),
            .build => if (by_pid != null) return fail("{d} is a build of {s}: exec joins runs", .{ r.pid, r.id }),
            .exec => if (by_pid != null) {
                if (r.run) |p| return fail("{d} is a command exec started in run {d}: name the run instead", .{ r.pid, p });
                return fail("{d} is a command exec started in a run: name the run instead", .{r.pid});
            },
        }
    }
    return switch (runs.items.len) {
        0 => fail("nothing running is {s}", .{target}),
        1 => runs.items[0],
        else => fail("{s} has {d} runs going ({s}): name one by its PID, as `zigsaw ps` lists it", .{ target, runs.items.len, try pidList(arena, runs.items) }),
    };
}

fn pidList(arena: Allocator, records: []const ps.Record) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (records, 0..) |r, i| try out.print(arena, "{s}{d}", .{ if (i == 0) "" else ", ", r.pid });
    return out.items;
}

/// The run's spec. A run writes it once its record is there, so one that's
/// just begun may not have it yet.
fn readSpec(ctx: *Context, run: ps.Record, run_zigsaw: win32.HANDLE) !Spec {
    const arena = ctx.arena;
    const path = try ps.specPath(arena, try ps.lockPath(ctx.store, arena, run.pid));
    var tries: u32 = 0;
    const bytes = while (true) : (tries += 1) {
        break Io.Dir.cwd().readFileAlloc(ctx.io, path, arena, .limited(16 << 20)) catch |err| switch (err) {
            error.FileNotFound => {
                if (tries < 20 and win32.WaitForSingleObject(run_zigsaw, 100) == win32.WAIT_TIMEOUT) continue;
                return fail("run {d} ({s}) can't be joined: its zigsaw is older than 0.99, or couldn't write down how it starts programs (`zigsaw -v run` says why)", .{ run.pid, run.id });
            },
            error.AccessDenied => return fail("can't read how run {d} ({s}) starts programs: only a zigsaw at medium integrity may, not one started from a low or AppContainer run", .{ run.pid, run.id }),
            else => |e| return e,
        };
    };
    return std.json.parseFromSliceLeaky(Spec, arena, bytes, .{ .ignore_unknown_fields = true }) catch
        return fail("can't read how run {d} ({s}) starts programs: {s} isn't what this zigsaw writes", .{ run.pid, run.id, path });
}

const Prepared = struct {
    exe: []const u8,
    command_line: []const u8,
    env_block: []const u16,
    security: ?win32.SECURITY_CAPABILITIES = null,
    token: ?win32.HANDLE = null,
};

/// What starting the command takes, as the run's spec says.
fn prepare(ctx: *Context, spec: Spec, opts: Options) !Prepared {
    const arena = ctx.arena;
    const command = try resolve(ctx.io, arena, spec, opts.command);
    const exe, const command_line = try runtime.commandLine(arena, command, opts.args, spec.system_root);
    var env: std.ArrayList(environment.Var) = .empty;
    try env.appendSlice(arena, spec.env);
    for (opts.env) |assignment| {
        const eq = std.mem.indexOfScalar(u8, assignment, '=') orelse
            return fail("--env expects NAME=VALUE, got \"{s}\"", .{assignment});
        if (eq == 0) return fail("--env expects NAME=VALUE, got \"{s}\"", .{assignment});
        try environment.set(arena, &env, assignment[0..eq], assignment[eq + 1 ..]);
    }
    var prepared: Prepared = .{
        .exe = exe,
        .command_line = command_line,
        .env_block = try environment.encodeBlock(arena, env.items),
    };
    const sandbox = std.meta.stringToEnum(@import("oci.zig").Sandbox, spec.sandbox) orelse
        return fail("run of {s} has the sandbox \"{s}\", which this zigsaw doesn't know", .{ spec.id, spec.sandbox });
    switch (sandbox) {
        .soft => {},
        .low => {
            try acl.letChildrenQueryUs(arena);
            prepared.token = try process.lowIntegrityToken(arena);
        },
        .appcontainer => {
            const profile = try appcontainer.Profile.ensure(arena, spec.id);
            if (spec.capabilities.len == 0) return fail("run of {s} names no capabilities, as an AppContainer run's spec should", .{spec.id});
            const caps = try arena.alloc(win32.SID_AND_ATTRIBUTES, spec.capabilities.len);
            for (caps, spec.capabilities) |*c, s| c.* = .{ .Sid = try appcontainer.sidFromString(arena, s), .Attributes = win32.SE_GROUP_ENABLED };
            prepared.security = .{
                .AppContainerSid = profile.sid,
                .Capabilities = caps.ptr,
                .CapabilityCount = @intCast(caps.len),
            };
        },
    }
    if (ctx.verbose) {
        note("run      {s}, sandbox {s}, job {s}", .{ spec.id, spec.sandbox, spec.job });
        note("exe      {s}", .{exe});
        if (command.batch) note("script   {s}", .{command.exe});
        note("cmdline  {s}", .{command_line});
        note("cwd      {s}", .{spec.cwd});
        for (env.items) |kv| note("env      {s}={s}", .{ kv.name, kv.value });
    }
    return prepared;
}

/// The command by name, as `run --command` finds it: an export, then the
/// run's PATH directories and System32; or an absolute path.
fn resolve(io: Io, arena: Allocator, spec: Spec, name: []const u8) !runtime.Command {
    for (spec.exports) |e| {
        if (std.ascii.eqlIgnoreCase(e.name, name)) return .init(e.exe, e.args);
    }
    const found = try runtime.findCommand(io, arena, spec.deploy_dir, name, spec.path, spec.system_root) orelse {
        if (std.mem.indexOfAny(u8, name, "/\\") != null and !std.fs.path.isAbsolute(name))
            return fail("command \"{s}\" is not a file in the app; for a program of yours, give its absolute path", .{name});
        return fail("command \"{s}\" is not an export of {s}, or an executable or batch file on its run's PATH or in System32", .{ name, spec.id });
    };
    return .init(found, &.{});
}

// ---------------------------------------------------------------------------
// --detach

/// Starts `zigsaw exec --detached-child` with the same options, which starts
/// the command and waits for it, and says on its stdout once it has: then
/// this prints the PID `ps` lists it by. If it doesn't, what it said on its
/// stderr is why.
fn detach(ctx: *Context, opts: Options) !u32 {
    const arena = ctx.arena;
    var args: std.ArrayList([]const u8) = .empty;
    if (ctx.verbose) try args.append(arena, "--verbose");
    try args.appendSlice(arena, &.{ "exec", "--detached-child" });
    for (opts.env) |e| try args.append(arena, try std.fmt.allocPrint(arena, "--env={s}", .{e}));
    try args.appendSlice(arena, &.{ "--", opts.target, opts.command });
    try args.appendSlice(arena, opts.args);
    const self = try win32.selfExePath(arena);
    const command_line = try process.buildCommandLine(arena, self, args.items);

    var out_read: win32.HANDLE = undefined;
    var out_write: win32.HANDLE = undefined;
    if (win32.CreatePipe(&out_read, &out_write, null, 0) == 0) return win32.lastErrorFail("CreatePipe");
    defer _ = win32.CloseHandle(out_read);
    var err_read: win32.HANDLE = undefined;
    var err_write: win32.HANDLE = undefined;
    if (win32.CreatePipe(&err_read, &err_write, null, 64 * 1024) == 0) {
        _ = win32.CloseHandle(out_write);
        return win32.lastErrorFail("CreatePipe");
    }
    defer _ = win32.CloseHandle(err_read);
    const nul = try openNul(arena);
    const cwd = try std.process.currentPathAlloc(ctx.io, arena);
    const started = process.startDetachedWith(arena, self, command_line, cwd, .{ nul, out_write, err_write });
    // Ours closed, its ends are its own: the pipes end when it lets go.
    _ = win32.CloseHandle(out_write);
    _ = win32.CloseHandle(err_write);
    _ = win32.CloseHandle(nul);
    const waiter = try started;
    defer _ = win32.CloseHandle(waiter.process);

    const said = try readAll(arena, out_read);
    if (std.mem.startsWith(u8, said, "started")) {
        var buf: [64]u8 = undefined;
        var out = Context.stdout().writerStreaming(ctx.io, &buf);
        try out.interface.print("{d}\n", .{waiter.pid});
        try out.interface.flush();
        if (!waiter.broke_away and ctx.verbose)
            note("note: the job this zigsaw is in kept it, so the command ends when that job does", .{});
        return 0;
    }
    // It ended without starting the command: what it said is why.
    const why = try readAll(arena, err_read);
    Context.printStderr("{s}", .{why});
    if (why.len == 0) note("error: the zigsaw that was to start the command ended without saying why", .{});
    return 1;
}

/// Says the command started, on the pipe `detach` reads, then leaves its
/// standard handles to NUL: the zigsaw that reads it is about to end.
fn tellStarted(ctx: *Context, nul: win32.HANDLE) !void {
    _ = ctx;
    const out = win32.GetStdHandle(win32.STD_OUTPUT_HANDLE);
    const err = win32.GetStdHandle(win32.STD_ERROR_HANDLE);
    const line = "started\n";
    if (out) |h| _ = win32.WriteFile(h, line.ptr, line.len, null, null);
    _ = win32.SetStdHandle(win32.STD_INPUT_HANDLE, nul);
    _ = win32.SetStdHandle(win32.STD_OUTPUT_HANDLE, nul);
    _ = win32.SetStdHandle(win32.STD_ERROR_HANDLE, nul);
    if (out) |h| _ = win32.CloseHandle(h);
    if (err) |h| if (h != out) {
        _ = win32.CloseHandle(h);
    };
}

fn readAll(arena: Allocator, pipe: win32.HANDLE) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        var n: win32.DWORD = 0;
        if (win32.ReadFile(pipe, &buf, buf.len, &n, null) == 0 or n == 0) break;
        try out.appendSlice(arena, buf[0..n]);
    }
    return out.items;
}

fn openNul(arena: Allocator) !win32.HANDLE {
    const h = win32.CreateFileW(try win32.wide(arena, "NUL"), win32.GENERIC_READ | win32.GENERIC_WRITE, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE, null, win32.OPEN_EXISTING, 0, null);
    if (h == win32.INVALID_HANDLE_VALUE) return win32.lastErrorFail("CreateFileW(NUL)");
    return h;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "a spec reads back as written" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const spec: Spec = .{
        .id = "org.x",
        .job = "Local\\zigsaw.12.0011223344556677",
        .sandbox = "appcontainer",
        .capabilities = &.{ "S-1-15-3-1024-1", "S-1-15-3-1" },
        .cwd = "D:\\s\\volumes\\org.x",
        .env = &.{ .{ .name = "PATH", .value = "D:\\a;C:\\Windows\\System32" }, .{ .name = "SECRET", .value = "a \"b\" \\ c" } },
        .path = &.{"D:\\a"},
        .deploy_dir = "D:\\a",
        .system_root = "C:\\Windows",
        .exports = &.{.{ .name = "sh", .exe = "D:\\a\\busybox.exe", .args = &.{"sh"} }},
    };
    const json = try std.json.Stringify.valueAlloc(arena, spec, .{});
    const back = try std.json.parseFromSliceLeaky(Spec, arena, json, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings(spec.job, back.job);
    try testing.expectEqualStrings("a \"b\" \\ c", back.env[1].value);
    try testing.expectEqual(2, back.capabilities.len);
    try testing.expectEqualStrings("sh", back.exports[0].args[0]);
}

test resolve {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const spec: Spec = .{
        .id = "org.x",
        .job = "j",
        .sandbox = "soft",
        .cwd = "D:\\",
        .env = &.{},
        .path = &.{},
        .deploy_dir = "D:\\nowhere-zigsaw-test",
        .system_root = "C:\\Windows",
        .exports = &.{.{ .name = "Sh", .exe = "D:\\a\\busybox.exe", .args = &.{"sh"} }},
    };
    // An export, by any case, with its arguments first.
    const c = try resolve(testing.io, arena, spec, "sh");
    try testing.expectEqualStrings("D:\\a\\busybox.exe", c.exe);
    try testing.expectEqualStrings("sh", c.args[0]);
    // A program in System32.
    const cmd = try resolve(testing.io, arena, spec, "cmd");
    try testing.expect(std.ascii.endsWithIgnoreCase(cmd.exe, "\\System32\\cmd.exe"));
    try testing.expect(cmd.batch == false);
    try testing.expectError(error.Failed, resolve(testing.io, arena, spec, "no-such-command-zigsaw"));
}
