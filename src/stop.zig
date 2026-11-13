//! `zigsaw stop` and `zigsaw kill`: ending the runs and builds `zigsaw ps`
//! lists.
//!
//! The run's zigsaw asks; the stopper ends. Each run and build makes a
//! named event (`Asker`), which its record names, and waits on it besides
//! its app (process.Child.stop). `zigsaw stop` sets it: the run's zigsaw,
//! which has the job and shares the app's console, then posts WM_CLOSE to
//! the app's windows and sends Ctrl+C to its console, and goes on waiting.
//! What hasn't ended after `--time`, `stop` ends as `kill` does: a run by
//! its job, so that its zigsaw sees the app end and cleans up after it as
//! ever (the app's keys in HKCU, an --ephemeral data directory, its record);
//! a build by its zigsaw, whose kept build root the next build goes on from.
//! Runs inside another (see ps.nest) end first, for the same reason.
//!
//! Windows sends Ctrl+C to every process on a console, as the key does. So
//! it's sent only when everything else on the run's console is the run's
//! own or what started the run (its shell, which takes it as the key): never
//! to a program that only shares the terminal. Nor when the `zigsaw stop`
//! is on that console: its shell would get it too, and a script waiting on
//! a program dies of Ctrl+C in Git Bash. The stopper says who it is in
//! running\<pid>.stopping before it sets the event.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const process = @import("process.zig");
const ps = @import("ps.zig");
const win32 = @import("win32.zig");
const note = Context.note;
const fail = Context.fail;

// ---------------------------------------------------------------------------
// The run's side: being asked

/// What asking a tree to end did.
pub const Asked = struct {
    /// The windows asked to close.
    windows: u32 = 0,
    ctrl_c: CtrlC = .no_console,
};

pub const CtrlC = union(enum) {
    sent,
    /// This zigsaw has no console: a GUI shim started it.
    no_console,
    /// None of the tree's processes are on this zigsaw's console.
    not_on_console,
    /// Something else is on the console, which Ctrl+C would reach too.
    blocked: struct { pid: u32, name: []const u8 },
    /// The `zigsaw stop` is on it, with whatever started it.
    stopper_here,
    failed,
};

/// A stop event of this zigsaw's, for a run or a build: what `zigsaw stop`
/// sets to ask it to end.
pub const Asker = struct {
    event: win32.HANDLE,
    name: []const u8,
    arena: Allocator,
    io: Io,
    /// What the run is, as the note it prints when asked says.
    label: []const u8,
    /// running\<pid>.stopping, where the stopper writes its PID.
    stopping_path: []const u8,
    /// What asking did, once it has.
    asked: ?Asked = null,

    /// A named, manual-reset event, unset; null if Windows refuses (as to a
    /// zigsaw at low integrity) or the name is taken, which only -v says.
    pub fn create(ctx: *const Context, label: []const u8) ?*Asker {
        return createIn(ctx.store, ctx.arena, label) catch |err| {
            if (ctx.verbose) note("note: `zigsaw stop` can't ask this to end: {t}", .{err});
            return null;
        };
    }

    fn createIn(store: Store, arena: Allocator, label: []const u8) !*Asker {
        const name = try std.fmt.allocPrint(arena, "{s}.stop", .{try ps.jobName(store.io, arena)});
        win32.SetLastError(0);
        const event = win32.CreateEventW(null, win32.TRUE, win32.FALSE, try win32.wide(arena, name)) orelse
            return win32.lastErrorFail("CreateEventW");
        // Someone else's: not to be waited on.
        if (win32.GetLastError() == win32.ERROR_ALREADY_EXISTS) {
            _ = win32.CloseHandle(event);
            return error.NameTaken;
        }
        const a = try arena.create(Asker);
        a.* = .{
            .event = event,
            .name = name,
            .arena = arena,
            .io = store.io,
            .label = label,
            .stopping_path = try ps.stoppingPath(arena, try ps.lockPath(store, arena, win32.GetCurrentProcessId())),
        };
        return a;
    }

    /// For process.Child.stop.
    pub fn stop(a: *Asker) process.Stop {
        return .{ .event = a.event, .context = a, .ask = askFromWait };
    }

    /// Whether `zigsaw stop` has asked.
    pub fn isSet(a: *const Asker) bool {
        return win32.WaitForSingleObject(a.event, 0) == win32.WAIT_OBJECT_0;
    }

    /// The PID of the `zigsaw stop` that asked, if it said.
    fn stopper(a: *const Asker) ?u32 {
        const bytes = Io.Dir.cwd().readFileAlloc(a.io, a.stopping_path, a.arena, .limited(64)) catch return null;
        return std.fmt.parseInt(u32, std.mem.trim(u8, bytes, " \r\n"), 10) catch null;
    }
};

fn askFromWait(context: *anyopaque, job: win32.HANDLE) void {
    const a: *Asker = @ptrCast(@alignCast(context));
    const asked = askToEnd(a.arena, job, a.stopper());
    a.asked = asked;
    note("zigsaw: {s} was asked to stop: {s}", .{ a.label, describe(a.arena, asked) catch "" });
}

/// Asks the processes in `job` to end: their windows to close, and their
/// console for Ctrl+C, if nothing else is on it. Doesn't wait.
pub fn askToEnd(arena: Allocator, job: win32.HANDLE, stopper: ?u32) Asked {
    const pids = (ps.jobPids(arena, job, 8) catch null) orelse &.{};
    return .{
        .windows = closeWindows(pids),
        .ctrl_c = sendCtrlC(arena, pids, stopper) catch .failed,
    };
}

/// What asking did, in words, for the note the run prints.
pub fn describe(arena: Allocator, asked: Asked) ![]const u8 {
    const windows = if (asked.windows == 0) "" else if (asked.windows == 1) "asked its window to close" else try std.fmt.allocPrint(arena, "asked its {d} windows to close", .{asked.windows});
    const ctrl_c: []const u8 = switch (asked.ctrl_c) {
        .sent => "sent Ctrl+C to its console",
        .blocked => |b| try std.fmt.allocPrint(arena, "didn't send Ctrl+C: {s} ({d}) is on its console too, and isn't the run's", .{ b.name, b.pid }),
        .stopper_here => "didn't send Ctrl+C: the `zigsaw stop` is on its console, and its shell would get it too",
        .failed => "couldn't send Ctrl+C",
        .no_console, .not_on_console => "",
    };
    if (windows.len > 0 and ctrl_c.len > 0) return std.fmt.allocPrint(arena, "{s}, and {s}", .{ windows, ctrl_c });
    if (windows.len > 0) return windows;
    if (ctrl_c.len > 0) return ctrl_c;
    return "it has no window to close, and no console to send Ctrl+C to";
}

const Windows = struct { pids: []const u32, posted: u32 = 0 };

/// Posts WM_CLOSE to the visible top-level windows of `pids` that no other
/// window owns, as closing them by hand would; how many.
fn closeWindows(pids: []const u32) u32 {
    if (pids.len == 0) return 0;
    var w: Windows = .{ .pids = pids };
    _ = win32.EnumWindows(&eachWindow, @bitCast(@intFromPtr(&w)));
    return w.posted;
}

fn eachWindow(window: win32.HWND, param: isize) callconv(.winapi) win32.BOOL {
    const w: *Windows = @ptrFromInt(@as(usize, @bitCast(param)));
    var pid: win32.DWORD = 0;
    _ = win32.GetWindowThreadProcessId(window, &pid);
    if (std.mem.indexOfScalar(u32, w.pids, pid) == null) return win32.TRUE;
    if (win32.IsWindowVisible(window) == 0 or win32.GetWindow(window, win32.GW_OWNER) != null) return win32.TRUE;
    var class: [64]u16 = undefined;
    const len = win32.GetClassNameW(window, &class, class.len);
    if (isConsoleWindow(class[0..@intCast(@max(len, 0))])) return win32.TRUE;
    if (win32.PostMessageW(window, win32.WM_CLOSE, 0, 0) != 0) w.posted += 1;
    return win32.TRUE;
}

/// A console's own window, which Windows may count as an app's: closing it
/// would end everything on that console, the shell too.
pub fn isConsoleWindow(class: []const u16) bool {
    const classes = [_][]const u16{
        std.unicode.utf8ToUtf16LeStringLiteral("ConsoleWindowClass"),
        std.unicode.utf8ToUtf16LeStringLiteral("PseudoConsoleWindow"),
    };
    for (classes) |c| if (std.mem.eql(u16, class, c)) return true;
    return false;
}

fn sendCtrlC(arena: Allocator, pids: []const u32, stopper: ?u32) !CtrlC {
    // A zigsaw with no console (a GUI shim's) takes the app's, if it got one
    // of its own, for as long as this takes. Its standard handles, the
    // shim's pipes, stay as they are.
    var attached = false;
    defer if (attached) {
        _ = win32.FreeConsole();
    };
    var buf = try arena.alloc(u32, 64);
    if (win32.GetConsoleProcessList(buf.ptr, @intCast(buf.len)) == 0) {
        for (pids) |pid| if (win32.AttachConsole(pid) != 0) {
            attached = true;
            break;
        };
        if (!attached) return .no_console;
    }
    const console = while (true) {
        const n = win32.GetConsoleProcessList(buf.ptr, @intCast(buf.len));
        if (n == 0) return .no_console;
        if (n <= buf.len) break buf[0..n];
        buf = try arena.alloc(u32, n + 8);
    };
    const tree = try Tree.of(arena);
    var allowed: std.ArrayList(u32) = .empty;
    try allowed.append(arena, win32.GetCurrentProcessId());
    try allowed.appendSlice(arena, try ancestors(arena, win32.GetCurrentProcessId(), &tree));
    switch (guard(console, pids, allowed.items, stopper)) {
        .ok => {},
        .none_of_theirs => return .not_on_console,
        .stopper_here => return .stopper_here,
        .blocked => |pid| return .{ .blocked = .{ .pid = pid, .name = if (tree.snap.get(pid)) |p| p.name else "?" } },
    }
    return if (win32.GenerateConsoleCtrlEvent(win32.CTRL_C_EVENT, 0) != 0) .sent else .failed;
}

pub const Verdict = union(enum) {
    ok,
    /// None of the tree is on the console.
    none_of_theirs,
    /// This one is, and is neither the tree's nor allowed.
    blocked: u32,
    /// The stopper is.
    stopper_here,
};

/// Whether Ctrl+C may go to a console that has `console` on it, for the
/// processes `theirs`: only if some of them are on it, the `stopper` isn't,
/// and everything else on it is `allowed`.
pub fn guard(console: []const u32, theirs: []const u32, allowed: []const u32, stopper: ?u32) Verdict {
    var any = false;
    var blocked: ?u32 = null;
    for (console) |pid| {
        if (std.mem.indexOfScalar(u32, theirs, pid) != null) {
            any = true;
        } else if (std.mem.indexOfScalar(u32, allowed, pid) == null and blocked == null) blocked = pid;
    }
    if (!any) return .none_of_theirs;
    if (stopper) |s| if (std.mem.indexOfScalar(u32, console, s) != null) return .stopper_here;
    if (blocked) |pid| return .{ .blocked = pid };
    return .ok;
}

/// Every process's parent, and when a process was created, which it opens
/// only to ask.
const Tree = struct {
    snap: ps.Snapshot,

    fn of(arena: Allocator) !Tree {
        return .{ .snap = try ps.snapshot(arena) };
    }

    pub fn parentOf(t: *const Tree, pid: u32) ?u32 {
        return if (t.snap.get(pid)) |p| p.ppid else null;
    }

    pub fn created(_: *const Tree, pid: u32) ?i64 {
        const handle = win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, win32.FALSE, pid) orelse return null;
        defer _ = win32.CloseHandle(handle);
        var c: i64 = 0;
        var e: i64 = 0;
        var k: i64 = 0;
        var u: i64 = 0;
        return if (win32.GetProcessTimes(handle, &c, &e, &k, &u) != 0) c else null;
    }
};

/// The processes that started `pid`, its parent first. A parent newer than
/// its child is another process that Windows gave the PID again: the chain
/// ends there, as it does at one that's gone.
pub fn ancestors(arena: Allocator, pid: u32, tree: anytype) ![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    var at = pid;
    var at_created = tree.created(pid);
    while (out.items.len < 64) {
        const parent = tree.parentOf(at) orelse break;
        if (parent == 0 or parent == pid or parent == at or std.mem.indexOfScalar(u32, out.items, parent) != null) break;
        const parent_created = tree.created(parent) orelse break;
        if (at_created) |c| if (parent_created > c) break;
        try out.append(arena, parent);
        at = parent;
        at_created = parent_created;
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// The commands

pub const Options = struct {
    kill: bool = false,
    /// How long `stop` waits for what it asked, before it ends it.
    seconds: u32 = 10,
    /// App ids, or runs' PIDs, as `ps` takes them.
    filters: []const []const u8 = &.{},
};

/// After its app is ended, how long a run's zigsaw gets to clean up.
const cleanup_ms = 30_000;

const Outcome = enum { pending, stopped, gone, killed, cleaning, cant };

const Target = struct {
    seen: *const ps.Seen,
    /// The zigsaw that runs it, opened to wait for (and to end, a build's).
    process: ?win32.HANDLE,
    /// Asked for by name; the others are inside one that was.
    matched: bool,
    depth: usize,
    outcome: Outcome = .pending,
    why: []const u8 = "",

    fn ended(t: *const Target, ms: win32.DWORD) bool {
        const h = t.process orelse return true;
        return win32.WaitForSingleObject(h, ms) == win32.WAIT_OBJECT_0;
    }
};

pub fn stop(ctx: *Context, opts: Options) !u32 {
    const arena = ctx.arena;
    const io = ctx.io;
    // Ctrl+C may come to this console too.
    _ = win32.SetConsoleCtrlHandler(&process.ignoreCtrlC, win32.TRUE);
    const seen = try ps.nest(arena, try ps.live(ctx.store, arena));

    var targets: std.ArrayList(Target) = .empty;
    for (seen) |*s| {
        const matched = ps.matches(s.record, opts.filters);
        const inside_one = for (seen) |o| {
            if (o.record.pid != s.record.pid and ps.matches(o.record, opts.filters) and ps.within(seen, s.record.pid, o.record.pid)) break true;
        } else false;
        if (!matched and !inside_one) continue;
        try targets.append(arena, .{
            .seen = s,
            .process = try openZigsaw(ctx.store, arena, s.record),
            .matched = matched,
            .depth = ps.depthOf(seen, s.record.pid),
        });
    }
    if (targets.items.len == 0) return fail("nothing running is {s}", .{try std.mem.join(arena, " or ", opts.filters)});
    // Innermost first.
    std.mem.sort(Target, targets.items, {}, struct {
        fn lessThan(_: void, a: Target, b: Target) bool {
            return a.depth > b.depth;
        }
    }.lessThan);
    for (targets.items) |*t| if (t.process == null) {
        t.outcome = .gone;
    };

    if (!opts.kill) {
        const self = try std.fmt.allocPrint(arena, "{d}", .{win32.GetCurrentProcessId()});
        // Those asked for that aren't inside another asked for: asking that
        // one asks them, through its windows and console.
        for (targets.items) |*t| {
            if (t.outcome != .pending or !t.matched) continue;
            if (insideMatched(seen, targets.items, t.seen.record.pid)) continue;
            const name = t.seen.record.stop orelse {
                t.why = "it can't be asked to stop (its zigsaw is older than 0.98, or couldn't make the event)";
                continue;
            };
            ask(ctx.store, arena, t.seen.record.pid, name, self) catch |err| {
                t.why = try std.fmt.allocPrint(arena, "asking it to stop failed: {t}", .{err});
            };
        }
        // Waits for all at once: each gets what's left of the time.
        const start = ctx.now();
        const time = @as(u64, opts.seconds) * 1000;
        for (targets.items) |*t| {
            if (t.outcome != .pending) continue;
            const left: win32.DWORD = @intCast(@min(time -| ctx.since(start).ms, std.math.maxInt(u31)));
            if (t.ended(left)) t.outcome = .stopped;
        }
    }

    for (targets.items) |*t| {
        if (t.outcome != .pending) continue;
        if (t.ended(0)) {
            t.outcome = .stopped;
            continue;
        }
        end(arena, t) catch |err| {
            t.outcome = .cant;
            t.why = try std.fmt.allocPrint(arena, "{t}", .{err});
            continue;
        };
        t.outcome = if (t.ended(cleanup_ms)) .killed else .cleaning;
    }

    var buf: [4096]u8 = undefined;
    var out = Context.stdout().writerStreaming(io, &buf);
    const w = &out.interface;
    var all = true;
    // In the order `ps` lists them.
    for (seen) |*s| for (targets.items) |t| if (t.seen == s) {
        const r = t.seen.record;
        const inside: []const u8 = if (t.matched) "" else if (s.inside) |p| try std.fmt.allocPrint(arena, " (in run {d})", .{p}) else "";
        switch (t.outcome) {
            .stopped => if (opts.kill)
                try w.print("{d} ({s}){s} ended\n", .{ r.pid, r.id, inside })
            else
                try w.print("stopped {d} ({s}){s}\n", .{ r.pid, r.id, inside }),
            .gone => try w.print("{d} ({s}){s} had ended\n", .{ r.pid, r.id, inside }),
            .killed, .cleaning => {
                try w.print("killed {d} ({s}){s}", .{ r.pid, r.id, inside });
                if (!opts.kill and t.why.len == 0) try w.print(" after {d} s", .{opts.seconds});
                if (t.why.len > 0) try w.print(": {s}", .{t.why});
                if (t.outcome == .cleaning) try w.print("; its zigsaw is still cleaning up", .{});
                try w.writeAll("\n");
            },
            .cant, .pending => {
                all = false;
                try w.print("{d} ({s}){s} can't be ended: {s}\n", .{ r.pid, r.id, inside, t.why });
            },
        }
    };
    try w.flush();
    return if (all) 0 else 1;
}

fn insideMatched(seen: []const ps.Seen, targets: []const Target, pid: u32) bool {
    for (targets) |o| {
        if (!o.matched or o.seen.record.pid == pid) continue;
        if (ps.within(seen, pid, o.seen.record.pid)) return true;
    }
    return false;
}

/// The zigsaw of a record, opened to wait for it; null if it's gone. Its
/// lock still held after opening it means the PID is still that zigsaw's.
fn openZigsaw(store: Store, arena: Allocator, r: ps.Record) !?win32.HANDLE {
    const access = win32.SYNCHRONIZE | (if (r.kind == .build) win32.PROCESS_TERMINATE else 0);
    const handle = win32.OpenProcess(access, win32.FALSE, r.pid) orelse return null;
    const lock_path = try ps.lockPath(store, arena, r.pid);
    if (try Store.tryLock(store.io, lock_path, .exclusive)) |l| {
        l.release(store.io);
        _ = win32.CloseHandle(handle);
        return null;
    }
    return handle;
}

/// Says who's asking, then asks.
fn ask(store: Store, arena: Allocator, pid: u32, event_name: []const u8, self: []const u8) !void {
    const dest = try ps.stoppingPath(arena, try ps.lockPath(store, arena, pid));
    const tmp = try store.tmpPath(arena, "stopping");
    try Io.Dir.cwd().writeFile(store.io, .{ .sub_path = tmp, .data = self });
    try Io.Dir.rename(.cwd(), tmp, .cwd(), dest, store.io);
    const event = win32.OpenEventW(win32.EVENT_MODIFY_STATE, win32.FALSE, try win32.wide(arena, event_name)) orelse
        return win32.lastErrorFail("OpenEventW");
    defer _ = win32.CloseHandle(event);
    if (win32.SetEvent(event) == 0) return win32.lastErrorFail("SetEvent");
}

/// Ends a run by its job, and a build by its zigsaw.
fn end(arena: Allocator, t: *Target) !void {
    const r = t.seen.record;
    switch (r.kind) {
        .build => if (win32.TerminateProcess(t.process.?, 1) == 0) return win32.lastErrorFail("TerminateProcess"),
        .run => {
            const name = r.job orelse {
                t.why = "its job has no name, so nothing else can reach it";
                return error.NoJobName;
            };
            const job = win32.OpenJobObjectW(win32.JOB_OBJECT_TERMINATE, win32.FALSE, try win32.wide(arena, name)) orelse
                return win32.lastErrorFail("OpenJobObjectW");
            defer _ = win32.CloseHandle(job);
            if (win32.TerminateJobObject(job, 1) == 0) return win32.lastErrorFail("TerminateJobObject");
        },
    }
}

const testing = std.testing;

test guard {
    // zigsaw 10 runs 20 and 21; bash 5 started zigsaw 10; stopper 30.
    try testing.expectEqual(Verdict.ok, guard(&.{ 5, 10, 20, 21 }, &.{ 20, 21 }, &.{ 10, 5 }, 30));
    try testing.expectEqual(Verdict.ok, guard(&.{ 10, 20 }, &.{ 20, 21 }, &.{ 10, 5 }, null));
    try testing.expectEqual(Verdict{ .blocked = 40 }, guard(&.{ 5, 10, 20, 40 }, &.{ 20, 21 }, &.{ 10, 5 }, 30));
    try testing.expectEqual(Verdict.stopper_here, guard(&.{ 5, 10, 20, 30 }, &.{ 20, 21 }, &.{ 10, 5 }, 30));
    try testing.expectEqual(Verdict.stopper_here, guard(&.{ 5, 10, 20, 30, 40 }, &.{20}, &.{ 10, 5 }, 30));
    try testing.expectEqual(Verdict.none_of_theirs, guard(&.{ 5, 10 }, &.{ 20, 21 }, &.{ 10, 5 }, null));
    try testing.expectEqual(Verdict.none_of_theirs, guard(&.{ 5, 10, 40 }, &.{20}, &.{10}, 40));
}

test isConsoleWindow {
    try testing.expect(isConsoleWindow(std.unicode.utf8ToUtf16LeStringLiteral("ConsoleWindowClass")));
    try testing.expect(isConsoleWindow(std.unicode.utf8ToUtf16LeStringLiteral("PseudoConsoleWindow")));
    try testing.expect(!isConsoleWindow(std.unicode.utf8ToUtf16LeStringLiteral("Chrome_WidgetWin_1")));
    try testing.expect(!isConsoleWindow(&.{}));
}

test ancestors {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fake = struct {
        fn parentOf(_: *const @This(), pid: u32) ?u32 {
            return switch (pid) {
                10 => 5,
                5 => 3,
                3 => 1,
                1 => 0,
                // 7's parent 9 ended, and the 9 now is newer.
                7 => 9,
                9 => 1,
                // A loop, as reused PIDs could make one.
                50 => 51,
                51 => 50,
                else => null,
            };
        }
        fn created(_: *const @This(), pid: u32) ?i64 {
            return switch (pid) {
                1 => 1,
                3 => 2,
                5 => 3,
                10 => 4,
                7 => 5,
                9 => 9,
                50, 51 => 1,
                else => null,
            };
        }
    };
    const fake: Fake = .{};
    try testing.expectEqualSlices(u32, &.{ 5, 3, 1 }, try ancestors(a, 10, &fake));
    try testing.expectEqualSlices(u32, &.{}, try ancestors(a, 7, &fake));
    try testing.expectEqualSlices(u32, &.{51}, try ancestors(a, 50, &fake));
    try testing.expectEqualSlices(u32, &.{}, try ancestors(a, 99, &fake));
}

test describe {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("sent Ctrl+C to its console", try describe(a, .{ .ctrl_c = .sent }));
    try testing.expectEqualStrings("asked its 2 windows to close, and sent Ctrl+C to its console", try describe(a, .{ .windows = 2, .ctrl_c = .sent }));
    try testing.expectEqualStrings("asked its window to close", try describe(a, .{ .windows = 1, .ctrl_c = .not_on_console }));
    try testing.expectEqualStrings("didn't send Ctrl+C: x.exe (7) is on its console too, and isn't the run's", try describe(a, .{ .ctrl_c = .{ .blocked = .{ .pid = 7, .name = "x.exe" } } }));
}
