//! `zigsaw up` and `zigsaw down`: a project's apps running together, as
//! `docker compose up` and `down` run a compose file's services. The
//! project's zigsaw.json lists them as `"run"` (see compose.zig), each with
//! the options `zigsaw run` would take.
//!
//! `up` builds the project's apps that aren't installed from it (all of them
//! with --build), pulls the pinned ones from registries that aren't
//! installed, then starts each, in the order listed, as `zigsaw run --detach`
//! starts a run: in a zigsaw of its own, its output in a log. An app that
//! serves something is up once its services' ports answer, and only then
//! does the next start. Its record names the project, and what its entry
//! hashed to: a later `up` leaves a run that's still what it would start,
//! and starts one again whose image or entry has changed.
//!
//! Then `up` follows their logs, each line after its app's name, until they
//! end. Ctrl+C stops them, last started first, and a second Ctrl+C ends what
//! hasn't stopped yet. `up --detach` returns once they're up instead, and
//! `down` stops them later.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const compose = @import("compose.zig");
const install = @import("install.zig");
const logs = @import("logs.zig");
const net = @import("net.zig");
const oci = @import("oci.zig");
const process = @import("process.zig");
const project = @import("project.zig");
const ps = @import("ps.zig");
const remote = @import("remote.zig");
const runtime = @import("run.zig");
const stop = @import("stop.zig");
const win32 = @import("win32.zig");
const fail = Context.fail;
const note = Context.note;

/// Checks run options as `zigsaw run` would take them, with the app's id
/// and arguments after them (main.zig's parser).
pub const CheckRun = *const fn (ctx: *Context, args: []const [:0]const u8) anyerror!void;

pub const UpOptions = struct {
    /// Returns once the apps are up, rather than follow their logs.
    detach: bool = false,
    /// Builds every app of the project first, not only those not installed.
    build: bool = false,
    /// For the apps it pulls.
    consent: remote.Consent = .ask,
    /// The project's directory, or its zigsaw.json; the working directory
    /// by default.
    dir: ?[]const u8 = null,
};

pub const DownOptions = struct {
    /// How long each app gets to stop, as `stop --time` gives.
    seconds: u32 = 10,
    dir: ?[]const u8 = null,
};

/// How long an app's services get to answer.
const ready_ms = 120_000;

const Loaded = struct {
    project: compose.Project,
    entries: []const compose.RunEntry,
};

/// The project's zigsaw.json: `dir` itself, or the one in `dir`, or in the
/// working directory. Fails, naming `command`, if there's none.
fn projectPath(ctx: *Context, dir: ?[]const u8, command: []const u8) ![]const u8 {
    if (dir) |d| {
        const stat = Io.Dir.cwd().statFile(ctx.io, d, .{}) catch return fail("{s} isn't there", .{d});
        if (stat.kind != .directory) return d;
    }
    const path = try std.fs.path.join(ctx.arena, &.{ dir orelse ".", project.manifest_name });
    if (!try Store.exists(ctx.io, path)) {
        const shown = Io.Dir.cwd().realPathFileAlloc(ctx.io, dir orelse ".", ctx.arena) catch dir orelse ".";
        return fail("{s} has no {s}: `zigsaw {s}` takes a project's directory, the current one unless given", .{ shown, project.manifest_name, command });
    }
    return path;
}

fn load(ctx: *Context, dir: ?[]const u8) !Loaded {
    const path = try projectPath(ctx, dir, "up");
    const p = try compose.read(ctx, path) orelse
        return fail("{s} isn't a project's: `zigsaw up` starts the apps a project's zigsaw.json lists as \"run\"", .{path});
    return .{ .project = p, .entries = try compose.runList(ctx.arena, p) };
}

/// Runs of the project's that are going, by their records.
fn runsOf(ctx: *Context, file: []const u8) ![]const ps.Record {
    var out: std.ArrayList(ps.Record) = .empty;
    for (try ps.live(ctx.store, ctx.arena)) |r| {
        if (r.kind != .run) continue;
        const of = r.project orelse continue;
        if (std.ascii.eqlIgnoreCase(of, file)) try out.append(ctx.arena, r);
    }
    return out.items;
}

fn findRun(runs: []const ps.Record, id: []const u8) ?ps.Record {
    for (runs) |r| if (std.ascii.eqlIgnoreCase(r.id, id)) return r;
    return null;
}

// ---------------------------------------------------------------------------
// up

pub fn up(ctx: *Context, opts: UpOptions, check: CheckRun) !u32 {
    const arena = ctx.arena;
    const loaded = try load(ctx, opts.dir);
    const p = loaded.project;
    const entries = loaded.entries;

    // Every entry's options, as `run` would take them, before anything.
    for (entries) |e| {
        var args: std.ArrayList([:0]const u8) = .empty;
        for (e.options) |o| try args.append(arena, try arena.dupeSentinel(u8, o, 0));
        try args.append(arena, try arena.dupeSentinel(u8, e.id, 0));
        check(ctx, args.items) catch |err| {
            if (err == error.Failed) note("  (in {s}, the \"run\" entry of {s})", .{ p.file, e.app });
            return err;
        };
    }

    {
        const lock = try ctx.store.lock(arena, .shared);
        defer lock.release(ctx.io);
        try buildMissing(ctx, p, entries, opts.build);
        try pullMissing(ctx, p, entries, opts.consent);
    }

    // Ctrl+C from here on stops what's up, rather than end `up`.
    presses_event = win32.CreateEventW(null, win32.FALSE, win32.FALSE, null);
    _ = win32.SetConsoleCtrlHandler(&pressed, win32.TRUE);
    net.startup() catch return fail("Windows' sockets aren't available", .{});

    var started_now: std.ArrayList(u32) = .empty;
    var follow: std.ArrayList(Followed) = .empty;
    const going = try runsOf(ctx, p.file);
    for (entries) |e| {
        if (presses.load(.monotonic) > 0) break;
        const ref = (try ctx.store.readRef(arena, e.id)) orelse return fail("{s} isn't installed", .{e.id});
        if (findRun(going, e.id)) |r| {
            const why: ?[]const u8 = if (!std.mem.eql(u8, r.manifest, ref.manifest))
                "its image changed"
            else if (!std.mem.eql(u8, r.entry orelse "", e.key))
                "its entry in \"run\" changed"
            else
                null;
            if (why == null) {
                note("{s} is up already, as run {d}", .{ e.id, r.pid });
                try follow.append(arena, .{ .id = e.id, .record = r, .from = .end });
                continue;
            }
            note("starting {s} again, as {s}: stopping run {d}", .{ e.id, why.?, r.pid });
            _ = try stop.end(ctx, .{ .pids = &.{r.pid} });
        }
        warnOthers(ctx, p.file, e.id) catch {};
        const record = startOne(ctx, p, e) catch |err| {
            rollBack(ctx, started_now.items);
            return err;
        };
        try started_now.append(arena, record.pid);
        try follow.append(arena, .{ .id = e.id, .record = record, .from = .start });
        waitReady(ctx, e.id, record) catch |err| {
            rollBack(ctx, started_now.items);
            return err;
        };
    }
    // Runs of the project's whose app it no longer lists stay up.
    for (going) |r| if (for (entries) |e| {
        if (std.ascii.eqlIgnoreCase(e.id, r.id)) break false;
    } else true) {
        note("note: {s} is up from this project as run {d}, though \"run\" no longer lists it; `zigsaw down` stops it", .{ r.id, r.pid });
    };

    if (opts.detach and presses.load(.monotonic) == 0) return 0;
    return followAll(ctx, p, entries, follow.items);
}

const Followed = struct {
    id: []const u8,
    record: ps.Record,
    from: logs.From,
};

/// Builds the project's apps, all of them, if one it runs isn't installed
/// from its recipe, or if asked to.
fn buildMissing(ctx: *Context, p: compose.Project, entries: []const compose.RunEntry, always: bool) !void {
    if (p.members.len == 0) return;
    var missing: ?[]const u8 = null;
    for (entries) |e| {
        const m = e.member orelse continue;
        const ref = try ctx.store.readRef(ctx.arena, e.id);
        const from_here = if (ref) |r| if (r.source) |s| std.ascii.eqlIgnoreCase(s, p.members[m].path) else false else false;
        if (!from_here) {
            missing = e.id;
            break;
        }
    }
    if (!always and missing == null) return;
    if (missing) |id| if (!always) note("{s} isn't installed from this project, so it builds first", .{id});
    try compose.buildAll(ctx, p, .{});
}

/// Pulls the pinned apps that aren't installed as pinned, and checks that
/// the others it runs from elsewhere are installed.
fn pullMissing(ctx: *Context, p: compose.Project, entries: []const compose.RunEntry, consent: remote.Consent) !void {
    const arena = ctx.arena;
    for (entries) |e| {
        if (e.member != null) continue;
        const ref = try ctx.store.readRef(arena, e.id);
        const pinned = e.pinned orelse {
            if (ref == null) return fail("{s}: run {s}: it isn't installed, and isn't one of the project's apps: install it, or pin it here, as \"{s}:<version>@sha256:<digest>\"", .{ p.file, e.id, e.id });
            continue;
        };
        const digest = pinned[std.mem.indexOfScalar(u8, pinned, '@').? + 1 ..];
        if (ref) |r| if (std.mem.eql(u8, r.manifest, digest)) continue;
        note("{s} isn't installed as \"run\" pins it, so it's installed first", .{e.id});
        const fetched = (try remote.fetch(ctx, pinned, .{ .consent = consent })).?;
        if (!std.mem.eql(u8, fetched.manifest_digest, digest))
            return fail("{s}: run {s}: {s} is a multi-platform index; pin its image for windows/amd64: \"{s}@{s}\"", .{
                p.file, pinned, digest, pinned[0..std.mem.indexOfScalar(u8, pinned, '@').?], fetched.manifest_digest,
            });
        if (!std.ascii.eqlIgnoreCase(fetched.config.id, e.id))
            return fail("{s}: run {s}: that image is {s}, not {s}", .{ p.file, pinned, fetched.config.id, e.id });
        try install.install(ctx, fetched);
    }
}

/// Starts the entry's app, as `run --detach` would, its record naming the
/// project.
fn startOne(ctx: *Context, p: compose.Project, e: compose.RunEntry) !ps.Record {
    const arena = ctx.arena;
    var options: std.ArrayList([]const u8) = .empty;
    try options.appendSlice(arena, &.{
        try std.fmt.allocPrint(arena, "--project={s}", .{p.file}),
        try std.fmt.allocPrint(arena, "--entry={s}", .{e.key}),
    });
    try options.appendSlice(arena, e.options);
    const started = try runtime.startDetached(ctx, options.items, e.id, e.args);
    // Its record is there before it says it started.
    for (try ps.live(ctx.store, arena)) |r| if (r.pid == started.pid) {
        note("started {s}, as run {d}", .{ e.id, r.pid });
        return r;
    };
    showTail(ctx, .{ .id = e.id, .pid = started.pid, .started = 0, .log = try logs.pathFor(ctx.store, arena, e.id, started.pid) });
    return fail("{s}'s run {d} ended as it started", .{ e.id, started.pid });
}

/// Waits until the run's services answer on their ports; fails, showing the
/// end of its log, if the run ends first, or they don't in time.
fn waitReady(ctx: *Context, id: []const u8, r: ps.Record) !void {
    const ports = r.ports orelse return;
    const arena = ctx.arena;
    const zigsaw = try stop.openZigsaw(ctx.store, arena, r) orelse return endedEarly(ctx, id, r);
    defer _ = win32.CloseHandle(zigsaw);
    const start = ctx.now();
    for (ports) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const name = entry[0..eq];
        const port = std.fmt.parseInt(u16, entry[eq + 1 ..], 10) catch continue;
        var told = false;
        while (!answers(port)) {
            if (presses.load(.monotonic) > 0) return;
            if (win32.WaitForSingleObject(zigsaw, 200) == win32.WAIT_OBJECT_0) return endedEarly(ctx, id, r);
            const ms = ctx.since(start).ms;
            if (ms >= ready_ms) {
                showTail(ctx, r);
                return fail("{s}'s {s} didn't answer on port {d} in {d} s", .{ id, name, port, ready_ms / 1000 });
            }
            if (!told and ms >= 2000) {
                note("waiting for {s}'s {s} to answer on port {d}", .{ id, name, port });
                told = true;
            }
        }
        note("{s}'s {s} answers on port {d}", .{ id, name, port });
    }
}

fn endedEarly(ctx: *Context, id: []const u8, r: ps.Record) error{Failed} {
    showTail(ctx, r);
    return fail("{s}'s run {d} ended before its services answered", .{ id, r.pid });
}

/// Whether something listens on the port, on 127.0.0.1 or ::1.
fn answers(port: u16) bool {
    for ([_]net.Family{ .ipv4, .ipv6 }) |family| switch (net.connect(.loopback(family, port), 500)) {
        .socket => |s| {
            _ = win32.closesocket(s);
            return true;
        },
        .failed => {},
    };
    return false;
}

/// The last lines of the run's log, for why it failed.
fn showTail(ctx: *Context, r: ps.Record) void {
    const path = r.log orelse return;
    var f: logs.Follower = .{ .arena = ctx.arena, .io = ctx.io };
    f.add(.{ .prefix = "  | ", .path = path, .from = .{ .tail = 15 } }) catch return;
    f.run(null) catch {};
}

fn warnOthers(ctx: *Context, file: []const u8, id: []const u8) !void {
    var pids: std.ArrayList(u8) = .empty;
    for (try ps.live(ctx.store, ctx.arena)) |r| {
        if (r.kind != .run or !std.ascii.eqlIgnoreCase(r.id, id)) continue;
        if (r.project) |of| if (std.ascii.eqlIgnoreCase(of, file)) continue;
        try pids.print(ctx.arena, "{s}{d}", .{ if (pids.items.len == 0) "" else ", ", r.pid });
    }
    if (pids.items.len > 0)
        note("note: {s} has a run going that this project didn't start ({s}); the ports of the one it starts may be taken, or answer for it", .{ id, pids.items });
}

/// Stops what this `up` started, after it failed: last started first.
fn rollBack(ctx: *Context, pids: []const u32) void {
    if (pids.len == 0) return;
    note("stopping what this `up` started", .{});
    var i = pids.len;
    while (i > 0) {
        i -= 1;
        _ = stop.end(ctx, .{ .pids = pids[i .. i + 1] }) catch {};
    }
}

// ---------------------------------------------------------------------------
// Following, and Ctrl+C

/// Ctrl+C or Ctrl+Break, pressed while `up` follows: how many times.
var presses = std.atomic.Value(u32).init(0);
var presses_event: ?win32.HANDLE = null;

fn pressed(event: win32.DWORD) callconv(.winapi) win32.BOOL {
    if (event != win32.CTRL_C_EVENT and event != win32.CTRL_BREAK_EVENT) return win32.FALSE;
    _ = presses.fetchAdd(1, .monotonic);
    if (presses_event) |e| _ = win32.SetEvent(e);
    return win32.TRUE;
}

/// Prints the runs' logs until they've all ended; the first Ctrl+C stops
/// them, last started first, and a second ends them now.
fn followAll(ctx: *Context, p: compose.Project, entries: []const compose.RunEntry, followed: []const Followed) !u32 {
    const arena = ctx.arena;
    const ids = try arena.alloc([]const u8, followed.len);
    for (ids, followed) |*id, f| id.* = f.id;
    const prefixes = try logs.prefixes(arena, ids);
    var f: logs.Follower = .{ .arena = arena, .io = ctx.io };
    for (followed, prefixes) |item, prefix| {
        const path = item.record.log orelse continue;
        const zigsaw = try stop.openZigsaw(ctx.store, arena, item.record) orelse continue;
        f.add(.{ .prefix = prefix, .path = path, .zigsaw = zigsaw, .from = item.from }) catch continue;
    }

    const cancel = win32.CreateEventW(null, win32.TRUE, win32.FALSE, null) orelse return win32.lastErrorFail("CreateEventW");
    var stopper: ?std.Thread = null;
    var stopping: Stopping = .{ .ctx = ctx.*, .file = p.file, .entries = entries, .cancel = cancel };
    var thread_arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    stopping.ctx.arena = thread_arena.allocator();
    var cancelled = false;
    while (true) {
        try f.poll();
        if (f.done()) break;
        const n = presses.load(.monotonic);
        if (n >= 1 and stopper == null) {
            note("stopping {s}'s apps (Ctrl+C again ends them now)", .{p.file});
            stopper = try std.Thread.spawn(.{}, Stopping.run, .{&stopping});
        }
        if (n >= 2 and !cancelled) {
            _ = win32.SetEvent(cancel);
            cancelled = true;
        }
        if (presses_event) |e| {
            _ = win32.WaitForSingleObject(e, 150);
        } else win32.Sleep(150);
    }
    if (stopper) |t| t.join();
    return stopping.code;
}

/// What the first Ctrl+C sets going: the project's runs stopped, on a
/// thread of their own, while the logs go on being printed.
const Stopping = struct {
    ctx: Context,
    file: []const u8,
    entries: []const compose.RunEntry,
    cancel: win32.HANDLE,
    code: u32 = 0,

    fn run(s: *Stopping) void {
        s.code = stopAll(&s.ctx, s.file, s.entries, 10, s.cancel) catch 1;
    }
};

/// Stops the project's runs: those of apps it no longer lists first, then
/// the rest, last listed first, an app at a time. 1 if one had to be
/// killed, or couldn't be ended, as `stop` returns.
fn stopAll(ctx: *Context, file: []const u8, entries: []const compose.RunEntry, seconds: u32, cancel: ?win32.HANDLE) !u32 {
    const arena = ctx.arena;
    const runs = try runsOf(ctx, file);
    var code: u32 = 0;
    var unlisted: std.ArrayList(u32) = .empty;
    for (runs) |r| if (for (entries) |e| {
        if (std.ascii.eqlIgnoreCase(e.id, r.id)) break false;
    } else true) try unlisted.append(arena, r.pid);
    if (unlisted.items.len > 0) code |= try stop.end(ctx, .{ .pids = unlisted.items, .seconds = seconds, .cancel = cancel }) orelse 0;
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        var pids: std.ArrayList(u32) = .empty;
        for (runs) |r| if (std.ascii.eqlIgnoreCase(r.id, entries[i].id)) try pids.append(arena, r.pid);
        if (pids.items.len > 0) code |= try stop.end(ctx, .{ .pids = pids.items, .seconds = seconds, .cancel = cancel }) orelse 0;
    }
    return code;
}

// ---------------------------------------------------------------------------
// down

pub fn down(ctx: *Context, opts: DownOptions) !u32 {
    // Ctrl+C may come to this console too.
    _ = win32.SetConsoleCtrlHandler(&process.ignoreCtrlC, win32.TRUE);
    const path = try projectPath(ctx, opts.dir, "down");
    const p = try compose.read(ctx, path) orelse
        return fail("{s} isn't a project's: `zigsaw down` stops the apps a project's `zigsaw up` started", .{path});
    // Without a list, its runs all go at once.
    const entries = compose.runList(ctx.arena, p) catch &.{};
    if ((try runsOf(ctx, p.file)).len == 0) {
        note("nothing of {s} is running", .{p.file});
        return 0;
    }
    return stopAll(ctx, p.file, entries, opts.seconds, null);
}

// ---------------------------------------------------------------------------
// logs, in a project

/// `zigsaw logs` with no app or run: the logs of the apps of the project in
/// the working directory, each line after its app's name.
pub fn projectLogs(ctx: *Context, opts: logs.Options) !u32 {
    const arena = ctx.arena;
    const path = project.manifest_name;
    if (!try Store.exists(ctx.io, path))
        return fail("give an app's id or a run's number, or run `zigsaw logs` in a project's directory", .{});
    const p = try compose.read(ctx, path) orelse
        return fail("give an app's id or a run's number: {s} isn't a project's", .{path});
    const entries = try compose.runList(arena, p);
    const runs = try runsOf(ctx, p.file);
    var ids: std.ArrayList([]const u8) = .empty;
    var sources: std.ArrayList(logs.Source) = .empty;
    for (entries) |e| {
        if (findRun(runs, e.id)) |r| if (r.log) |log| {
            try ids.append(arena, e.id);
            try sources.append(arena, .{ .path = log, .zigsaw = if (opts.follow) try stop.openZigsaw(ctx.store, arena, r) else null });
            continue;
        };
        const log = try logs.newestOf(ctx.store, arena, e.id) orelse continue;
        try ids.append(arena, e.id);
        try sources.append(arena, .{ .path = log });
    }
    if (sources.items.len == 0) {
        note("none of {s}'s apps has a log yet: `zigsaw up` starts them", .{p.file});
        return 0;
    }
    const prefixes = try logs.prefixes(arena, ids.items);
    var f: logs.Follower = .{ .arena = arena, .io = ctx.io };
    for (sources.items, prefixes) |*s, prefix| {
        s.prefix = prefix;
        if (opts.tail) |n| s.from = .{ .tail = n };
        try f.add(s.*);
    }
    try f.run(null);
    return 0;
}
