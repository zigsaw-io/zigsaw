//! `zigsaw ps`: the runs and builds going in a store, and what they are.
//!
//! Each `zigsaw run`, and each `zigsaw build`, writes a record of itself in
//! running\<its pid>.json, and holds running\<its pid>.lock exclusively while
//! it goes. A lock ends however its zigsaw does, so a record whose lock can
//! be taken is one a killed zigsaw left: `ps` deletes it, and the PID of a
//! zigsaw that's gone can't be taken for another's.
//!
//! The record names the run's job object (see process.newJob), which `ps`
//! opens only to query: what processes are in it, and what they used. A run
//! started from inside another, as a command of `--share=commands` is, is in
//! the other's job too; `ps` lists its processes under it, and not twice.
//!
//! Nothing here holds the store lock: `ps` only reads, as `list` does. A
//! zigsaw that can't write its record (one at low integrity, that a low
//! run's shim started) goes on without; its processes are still in the job
//! of the run it's inside.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const override = @import("override.zig");
const win32 = @import("win32.zig");
const note = Context.note;

pub const Kind = enum { run, build };

/// What a run or a build says of itself in running\.
pub const Record = struct {
    kind: Kind = .run,
    /// The app's id, or the recipe's.
    id: []const u8,
    version: []const u8 = "",
    manifest: []const u8 = "",
    /// The zigsaw that runs it: the run's name in `ps`.
    pid: u32,
    /// The app's first process, which the run waits for.
    app_pid: ?u32 = null,
    /// When it started, as a FILETIME.
    started: i64,
    /// Its job's name; null if it has none, as between a build's commands.
    job: ?[]const u8 = null,
    /// The name of the event `zigsaw stop` sets to ask it to end (see
    /// stop.zig); null if it can't be asked.
    stop: ?[]const u8 = null,
    /// Runs only: soft, low or appcontainer, and all, none or list.
    sandbox: ?[]const u8 = null,
    network: ?[]const u8 = null,
    memory_limit: ?u64 = null,
    cpus: ?u32 = null,
    ephemeral: bool = false,
    /// The command line the app was started with, or a build's command.
    command: []const u8 = "",
    /// The shortcut the run was started from.
    shortcut: ?[]const u8 = null,
    /// Builds only: the module, "build" or "vendor", and which command of
    /// how many.
    module: ?[]const u8 = null,
    step: ?[]const u8 = null,
    n: u32 = 0,
    of: u32 = 0,
};

/// A record being kept, until `end`.
pub const Entry = struct {
    store: Store,
    path: []const u8,
    lock_path: []const u8,
    lock: Store.Lock,
    record: Record,

    /// Writes the record again, after its fields changed. Only warns, under
    /// -v: `ps` just shows less.
    pub fn update(e: *const Entry, ctx: *const Context) void {
        write(e.store, ctx.arena, e.path, e.record) catch |err|
            if (ctx.verbose) note("note: couldn't update {s}: {t}", .{ e.path, err });
    }

    /// Deletes the record, then lets go of its lock.
    pub fn end(e: *const Entry, io: Io) void {
        Io.Dir.cwd().deleteFile(io, e.path) catch {};
        deleteStopping(io, e.lock_path);
        e.lock.release(io);
        Io.Dir.cwd().deleteFile(io, e.lock_path) catch {};
    }
};

/// running\<pid>.stopping, next to a record's lock: the PID of the `zigsaw
/// stop` that asked it to end (see stop.zig).
pub fn stoppingPath(arena: Allocator, lock_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.stopping", .{lock_path[0 .. lock_path.len - ".lock".len]});
}

fn deleteStopping(io: Io, lock_path: []const u8) void {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}.stopping", .{lock_path[0 .. lock_path.len - ".lock".len]}) catch return;
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// running\<pid>.lock, for a run's PID.
pub fn lockPath(store: Store, arena: Allocator, pid: u32) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}\\{d}.lock", .{ try store.path(arena, &.{"running"}), pid });
}

/// A name for a job of this zigsaw's (see process.newJob): random, so that
/// nobody can have taken it beforehand.
pub fn jobName(io: Io, arena: Allocator) ![]const u8 {
    var random: [8]u8 = undefined;
    io.random(&random);
    return std.fmt.allocPrint(arena, "Local\\zigsaw.{d}.{s}", .{ win32.GetCurrentProcessId(), &std.fmt.bytesToHex(random, .lower) });
}

pub fn now() i64 {
    var ft: i64 = 0;
    win32.GetSystemTimeAsFileTime(&ft);
    return ft;
}

/// Starts keeping `record` for this zigsaw; null if it can't be, which
/// only -v mentions.
pub fn begin(ctx: *const Context, record: Record) ?Entry {
    return beginIn(ctx.store, ctx.arena, record) catch |err| {
        if (ctx.verbose) note("note: `zigsaw ps` won't list this {t}: {t}", .{ record.kind, err });
        return null;
    };
}

fn beginIn(store: Store, arena: Allocator, record: Record) !Entry {
    const dir = try store.path(arena, &.{"running"});
    try Io.Dir.cwd().createDirPath(store.io, dir);
    const base = try std.fmt.allocPrint(arena, "{s}\\{d}", .{ dir, record.pid });
    const lock_path = try std.fmt.allocPrint(arena, "{s}.lock", .{base});
    const lock = try Store.openLock(store.io, lock_path, .exclusive, .no_wait);
    errdefer lock.release(store.io);
    const e: Entry = .{
        .store = store,
        .path = try std.fmt.allocPrint(arena, "{s}.json", .{base}),
        .lock_path = lock_path,
        .lock = lock,
        .record = record,
    };
    try write(store, arena, e.path, record);
    return e;
}

/// Through tmp\, so that `ps` reads all of a record or none of it.
fn write(store: Store, arena: Allocator, dest: []const u8, record: Record) !void {
    const json = try std.json.Stringify.valueAlloc(arena, record, .{ .emit_null_optional_fields = false });
    const tmp = try store.tmpPath(arena, "running");
    try Io.Dir.cwd().writeFile(store.io, .{ .sub_path = tmp, .data = json });
    try Io.Dir.rename(.cwd(), tmp, .cwd(), dest, store.io);
}

/// The records of the runs and builds going, oldest first. Deletes those
/// whose zigsaw is gone.
pub fn live(store: Store, arena: Allocator) ![]const Record {
    const io = store.io;
    const dir_path = try store.path(arena, &.{"running"});
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => |e| return e,
    };
    defer dir.close(io);
    var out: std.ArrayList(Record) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const stem = entry.name[0 .. entry.name.len - ".json".len];
        const json_path = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ dir_path, entry.name });
        const lock_path = try std.fmt.allocPrint(arena, "{s}\\{s}.lock", .{ dir_path, stem });
        // Taken: its zigsaw is gone, however it ended.
        if (try Store.tryLock(io, lock_path, .exclusive)) |l| {
            Io.Dir.cwd().deleteFile(io, json_path) catch {};
            deleteStopping(io, lock_path);
            l.release(io);
            Io.Dir.cwd().deleteFile(io, lock_path) catch {};
            continue;
        }
        const bytes = dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20)) catch continue;
        const record = std.json.parseFromSliceLeaky(Record, arena, bytes, .{ .ignore_unknown_fields = true }) catch continue;
        try out.append(arena, record);
    }
    std.mem.sort(Record, out.items, {}, struct {
        fn lessThan(_: void, a: Record, b: Record) bool {
            return if (a.started != b.started) a.started < b.started else a.pid < b.pid;
        }
    }.lessThan);
    return out.items;
}

// ---------------------------------------------------------------------------
// What a job and its processes are

/// A run's job, as `ps` sees it.
pub const JobView = struct {
    pids: []const u32,
    /// Processor time of all its processes, those ended too, in 100 ns.
    cpu: u64,
    /// The most memory its processes had committed together.
    peak: u64,
};

/// Opens a job by name to query it; null if it's gone, or Windows refuses.
pub fn viewJob(arena: Allocator, name: []const u8) !?JobView {
    const handle = win32.OpenJobObjectW(win32.JOB_OBJECT_QUERY, win32.FALSE, try win32.wide(arena, name)) orelse return null;
    defer _ = win32.CloseHandle(handle);
    var accounting: win32.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION = .{};
    if (win32.QueryInformationJobObject(handle, win32.JobObjectBasicAccountingInformation, &accounting, @sizeOf(@TypeOf(accounting)), null) == 0) return null;
    var limits: win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};
    const peak: u64 = if (win32.QueryInformationJobObject(handle, win32.JobObjectExtendedLimitInformation, &limits, @sizeOf(@TypeOf(limits)), null) != 0) limits.PeakJobMemoryUsed else 0;
    return .{
        .pids = try jobPids(arena, handle, accounting.ActiveProcesses) orelse return null,
        .cpu = @intCast(accounting.TotalUserTime + accounting.TotalKernelTime),
        .peak = peak,
    };
}

/// The PIDs of a job's processes; null if Windows won't say. `expect` is
/// about how many there are.
pub fn jobPids(arena: Allocator, handle: win32.HANDLE, expect: u32) !?[]const u32 {
    // Processes come and go between asking how many and asking which.
    var room: usize = @as(usize, @max(expect, 1)) + 8;
    const Head = win32.JOBOBJECT_BASIC_PROCESS_ID_LIST;
    while (true) : (room *= 2) {
        const size = @sizeOf(Head) + room * @sizeOf(usize);
        const buf = try arena.alignedAlloc(u8, .of(usize), size);
        @memset(buf, 0);
        if (win32.QueryInformationJobObject(handle, win32.JobObjectBasicProcessIdList, buf.ptr, @intCast(size), null) == 0) {
            if (win32.GetLastError() == win32.ERROR_MORE_DATA) continue;
            return null;
        }
        const head: *const Head = @ptrCast(buf.ptr);
        if (head.NumberOfAssignedProcesses > head.NumberOfProcessIdsInList) continue;
        const ids: [*]const usize = @ptrCast(@alignCast(buf.ptr + @sizeOf(Head)));
        const pids = try arena.alloc(u32, head.NumberOfProcessIdsInList);
        for (pids, ids[0..pids.len]) |*p, id| p.* = @intCast(id);
        return pids;
    }
}

/// Every process's parent and file name, from one snapshot.
pub const Snapshot = std.AutoHashMapUnmanaged(u32, struct { ppid: u32, name: []const u8 });

pub fn snapshot(arena: Allocator) !Snapshot {
    var map: Snapshot = .empty;
    const snap = win32.CreateToolhelp32Snapshot(win32.TH32CS_SNAPPROCESS, 0);
    if (snap == win32.INVALID_HANDLE_VALUE) return map;
    defer _ = win32.CloseHandle(snap);
    var entry: win32.PROCESSENTRY32W = .{};
    var ok = win32.Process32FirstW(snap, &entry);
    while (ok != 0) : (ok = win32.Process32NextW(snap, &entry)) {
        const len = std.mem.indexOfScalar(u16, &entry.szExeFile, 0) orelse entry.szExeFile.len;
        try map.put(arena, entry.th32ProcessID, .{
            .ppid = entry.th32ParentProcessID,
            .name = try std.unicode.wtf16LeToWtf8Alloc(arena, entry.szExeFile[0..len]),
        });
    }
    return map;
}

/// One process of a run, as far as Windows says; null for what it won't.
pub const Proc = struct {
    pid: u32,
    ppid: u32 = 0,
    name: []const u8 = "?",
    command_line: ?[]const u8 = null,
    /// Committed memory of its own.
    private: ?u64 = null,
    /// Processor time, in 100 ns.
    cpu: ?u64 = null,
    /// As a FILETIME.
    created: ?i64 = null,
};

pub fn describe(arena: Allocator, pid: u32, snap: *const Snapshot) !Proc {
    var p: Proc = .{ .pid = pid };
    if (snap.get(pid)) |s| {
        p.ppid = s.ppid;
        p.name = s.name;
    }
    const handle = win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, win32.FALSE, pid) orelse return p;
    defer _ = win32.CloseHandle(handle);
    var created: i64 = 0;
    var exited: i64 = 0;
    var kernel: i64 = 0;
    var user: i64 = 0;
    if (win32.GetProcessTimes(handle, &created, &exited, &kernel, &user) != 0) {
        p.created = created;
        p.cpu = @intCast(kernel + user);
    }
    var counters: win32.PROCESS_MEMORY_COUNTERS_EX = .{};
    if (win32.K32GetProcessMemoryInfo(handle, &counters, @sizeOf(@TypeOf(counters))) != 0) p.private = counters.PrivateUsage;
    p.command_line = commandLineOf(arena, handle) catch null;
    return p;
}

fn commandLineOf(arena: Allocator, handle: win32.HANDLE) !?[]const u8 {
    var size: u32 = 1024;
    var tries: u32 = 0;
    while (tries < 4) : (tries += 1) {
        const buf = try arena.alignedAlloc(u8, .of(usize), size);
        var needed: u32 = 0;
        const status = win32.NtQueryInformationProcess(handle, win32.ProcessCommandLineInformation, buf.ptr, size, &needed);
        if (status >= 0) {
            const s: *const win32.UNICODE_STRING = @ptrCast(buf.ptr);
            const chars = s.Buffer orelse return null;
            return try std.unicode.wtf16LeToWtf8Alloc(arena, chars[0 .. s.Length / 2]);
        }
        // STATUS_INFO_LENGTH_MISMATCH, or a buffer too small: again, as large
        // as it asks.
        if (needed <= size) return null;
        size = needed;
    }
    return null;
}

// ---------------------------------------------------------------------------
// The command

pub const Options = struct {
    processes: bool = false,
    /// App ids, or runs' PIDs.
    filters: []const []const u8 = &.{},
};

/// A record with what `ps` found of it.
pub const Seen = struct {
    record: Record,
    job: ?JobView,
    /// The run whose job it's in, if it's inside another.
    inside: ?u32 = null,
};

/// The records, each with its job looked into, and which run each is
/// inside, if any.
pub fn nest(arena: Allocator, records: []const Record) ![]Seen {
    const seen = try arena.alloc(Seen, records.len);
    for (seen, records) |*s, r| s.* = .{ .record = r, .job = if (r.job) |name| try viewJob(arena, name) else null };
    nestSeen(seen);
    return seen;
}

/// Innermost first: a run is inside the run with the fewest processes whose
/// job has its zigsaw.
fn nestSeen(seen: []Seen) void {
    for (seen) |*s| {
        var best: ?usize = null;
        for (seen, 0..) |o, i| {
            if (o.record.pid == s.record.pid) continue;
            const job = o.job orelse continue;
            if (std.mem.indexOfScalar(u32, job.pids, s.record.pid) == null) continue;
            if (best == null or job.pids.len < seen[best.?].job.?.pids.len) best = i;
        }
        if (best) |i| s.inside = seen[i].record.pid;
    }
}

/// How many runs `pid` is inside, by `inside`; 0 for one inside none.
pub fn depthOf(seen: []const Seen, pid: u32) usize {
    var d: usize = 0;
    var at = pid;
    while (d < seen.len) : (d += 1) {
        const s = for (seen) |s| {
            if (s.record.pid == at) break s;
        } else return d;
        at = s.inside orelse return d;
    }
    return d;
}

/// Whether the run `pid` is `outer`, or inside it, however deep.
pub fn within(seen: []const Seen, pid: u32, outer: u32) bool {
    var at = pid;
    var steps: usize = 0;
    while (steps <= seen.len) : (steps += 1) {
        if (at == outer) return true;
        const s = for (seen) |s| {
            if (s.record.pid == at) break s;
        } else return false;
        at = s.inside orelse return false;
    }
    return false;
}

pub fn ps(ctx: *Context, opts: Options) !void {
    const arena = ctx.arena;
    const seen = try nest(arena, try live(ctx.store, arena));

    var shown: std.ArrayList(*const Seen) = .empty;
    for (seen) |*s| if (matches(s.record, opts.filters)) try shown.append(arena, s);
    if (shown.items.len == 0) {
        if (opts.filters.len == 0)
            note("nothing is running", .{})
        else
            note("nothing running is {s}", .{try std.mem.join(arena, " or ", opts.filters)});
        return;
    }

    const snap = try snapshot(arena);
    const time = now();
    // The columns as wide as what's in them; COMMAND, last, as long as it is.
    const header = [columns]Cell{ .{ "RUN", .left }, .{ "APP", .left }, .{ "VERSION", .left }, .{ "SANDBOX", .left }, .{ "PROCS", .right }, .{ "MEMORY", .right }, .{ "CPU", .right }, .{ "UP", .right }, .{ "COMMAND", .left } };
    const lines = try arena.alloc([columns]Cell, shown.items.len);
    const procs_of = try arena.alloc([]const Proc, shown.items.len);
    for (shown.items, lines, procs_of) |s, *line, *procs| {
        const r = s.record;
        procs.* = if (s.job) |j| try describeAll(arena, j.pids, &snap) else &.{};
        var memory: u64 = 0;
        for (procs.*) |p| memory += p.private orelse 0;
        const memory_text = if (s.job == null) "-" else if (r.memory_limit) |l|
            try std.fmt.allocPrint(arena, "{f} (of {f})", .{ Bytes{ .n = memory }, override.Size{ .bytes = l } })
        else
            try std.fmt.allocPrint(arena, "{f}", .{Bytes{ .n = memory }});
        const command = try summary(arena, r);
        line.* = .{
            .{ try std.fmt.allocPrint(arena, "{d}", .{r.pid}), .left },
            .{ r.id, .left },
            .{ if (r.version.len > 0) r.version else "-", .left },
            .{ if (r.kind == .build) "build" else r.sandbox orelse "?", .left },
            .{ if (s.job) |j| try std.fmt.allocPrint(arena, "{d}", .{j.pids.len}) else "-", .right },
            .{ memory_text, .right },
            .{ if (s.job) |j| try std.fmt.allocPrint(arena, "{f}", .{Cpu{ .t = j.cpu }}) else "-", .right },
            .{ try std.fmt.allocPrint(arena, "{f}", .{Age{ .t = time - r.started }}), .right },
            .{ if (s.inside) |p| try std.fmt.allocPrint(arena, "{s}  (in run {d})", .{ command, p }) else command, .left },
        };
    }
    var widths: [columns]usize = undefined;
    for (&widths, header) |*width, h| width.* = h[0].len;
    for (lines) |line| for (&widths, line) |*width, cell| {
        width.* = @max(width.*, std.unicode.utf8CountCodepoints(cell[0]) catch cell[0].len);
    };

    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const w = &stdout.interface;
    try printLine(w, header, widths);
    for (shown.items, lines, procs_of) |s, line, procs| {
        try printLine(w, line, widths);
        if (opts.processes) try printTree(arena, w, s, seen, procs, time);
    }
    try w.flush();
}

const columns = 9;
const Cell = struct { []const u8, enum { left, right } };

fn printLine(w: *Io.Writer, cells: [columns]Cell, widths: [columns]usize) !void {
    for (cells, widths, 0..) |cell, width, i| {
        const text, const side = cell;
        const pad = width -| (std.unicode.utf8CountCodepoints(text) catch text.len);
        if (i == columns - 1) {
            try w.print("{s}\n", .{text});
            break;
        }
        if (side == .right) try w.splatByteAll(' ', pad);
        try w.writeAll(text);
        if (side == .left) try w.splatByteAll(' ', pad);
        try w.writeAll("  ");
    }
}

fn describeAll(arena: Allocator, pids: []const u32, snap: *const Snapshot) ![]const Proc {
    const procs = try arena.alloc(Proc, pids.len);
    for (procs, pids) |*p, pid| p.* = try describe(arena, pid, snap);
    return procs;
}

/// Whether the record is one the filters ask for: an app's id, or a run's
/// PID. No filter asks for all.
pub fn matches(r: Record, filters: []const []const u8) bool {
    if (filters.len == 0) return true;
    for (filters) |f| {
        if (std.fmt.parseInt(u32, f, 10)) |pid| {
            if (pid == r.pid) return true;
        } else |_| if (std.ascii.eqlIgnoreCase(f, r.id)) return true;
    }
    return false;
}

/// What the COMMAND column says: the program's file name and its arguments,
/// or a build's command after its place, as the build's log says it.
pub fn summary(arena: Allocator, r: Record) ![]const u8 {
    const max = 80;
    const text = switch (r.kind) {
        .run => try shortCommand(arena, r.command),
        .build => if (r.module) |m| try std.fmt.allocPrint(arena, "[{s}{s} {d}/{d}] {s}", .{
            m,
            if (r.step != null and std.mem.eql(u8, r.step.?, "vendor")) " vendor" else "",
            r.n,
            r.of,
            r.command,
        }) else "(preparing)",
    };
    if (text.len <= max) return text;
    // Not inside a UTF-8 sequence.
    var end: usize = max - 3;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return std.fmt.allocPrint(arena, "{s}...", .{text[0..end]});
}

/// A command line with its program's file name in place of its path.
pub fn shortCommand(arena: Allocator, command_line: []const u8) ![]const u8 {
    const line = std.mem.trimStart(u8, command_line, " \t");
    const first_end, const rest_start = if (line.len > 0 and line[0] == '"') quoted: {
        const close = std.mem.indexOfScalarPos(u8, line, 1, '"') orelse break :quoted .{ line.len, line.len };
        break :quoted .{ close, close + 1 };
    } else plain: {
        const space = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        break :plain .{ space, space };
    };
    const program = std.mem.trim(u8, line[0..first_end], "\"");
    const name = program[if (std.mem.lastIndexOfAny(u8, program, "\\/")) |i| i + 1 else 0..];
    const rest = std.mem.trimStart(u8, line[rest_start..], " \t");
    return if (rest.len == 0) arena.dupe(u8, name) else std.fmt.allocPrint(arena, "{s} {s}", .{ name, rest });
}

/// The run's processes as a tree, each under the one that started it. A
/// run inside it shows as itself, its processes under its own line.
fn printTree(arena: Allocator, w: *Io.Writer, s: *const Seen, all: []const Seen, procs: []const Proc, time: i64) !void {
    if (s.job == null) {
        try w.print("        (its processes can't be looked into)\n", .{});
        return;
    }
    // The processes of runs inside this one are theirs to show.
    var theirs: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    for (all) |o| if (o.inside != null and o.inside.? == s.record.pid) {
        try theirs.put(arena, o.record.pid, o.record.pid);
        if (o.job) |j| for (j.pids) |pid| try theirs.put(arena, pid, o.record.pid);
    };
    const rows = try treeOrder(arena, procs, theirs);
    try w.print("        {s:<7} {s:<7} {s:>10} {s:>8}  {s:>7}  {s}\n", .{ "PID", "PPID", "MEMORY", "CPU", "UP", "COMMAND" });
    for (rows) |row| {
        const p = row.proc;
        try w.print("        {d:<7} {d:<7} ", .{ p.pid, p.ppid });
        if (row.run) |run| {
            try w.print("{s:>10} {s:>8}  {s:>7}  ", .{ "", "", "" });
            try w.splatByteAll(' ', row.depth * 2);
            const id = for (all) |o| {
                if (o.record.pid == run) break o.record.id;
            } else "?";
            try w.print("-> run {d} ({s})\n", .{ run, id });
            continue;
        }
        const memory = if (p.private) |m| try std.fmt.allocPrint(arena, "{f}", .{Bytes{ .n = m }}) else "?";
        const cpu = if (p.cpu) |c| try std.fmt.allocPrint(arena, "{f}", .{Cpu{ .t = c }}) else "?";
        const up = if (p.created) |c| try std.fmt.allocPrint(arena, "{f}", .{Age{ .t = time - c }}) else "?";
        try w.print("{s:>10} {s:>8}  {s:>7}  ", .{ memory, cpu, up });
        try w.splatByteAll(' ', row.depth * 2);
        try w.print("{s}\n", .{p.command_line orelse p.name});
    }
}

pub const Row = struct {
    proc: Proc,
    depth: usize,
    /// The run inside this one that the process is the zigsaw of.
    run: ?u32 = null,
};

/// Depth first, oldest first among siblings; a process whose parent isn't
/// among them is a root. Those of runs inside (`theirs`, by PID to the
/// run's) are left out, but for each such run's zigsaw, which stands for it.
pub fn treeOrder(arena: Allocator, procs: []const Proc, theirs: std.AutoHashMapUnmanaged(u32, u32)) ![]const Row {
    var kept: std.ArrayList(Proc) = .empty;
    for (procs) |p| {
        if (theirs.get(p.pid)) |run| if (run != p.pid) continue;
        try kept.append(arena, p);
    }
    std.mem.sort(Proc, kept.items, {}, struct {
        fn lessThan(_: void, a: Proc, b: Proc) bool {
            const ac = a.created orelse std.math.maxInt(i64);
            const bc = b.created orelse std.math.maxInt(i64);
            return if (ac != bc) ac < bc else a.pid < b.pid;
        }
    }.lessThan);
    var rows: std.ArrayList(Row) = .empty;
    const placed = try arena.alloc(bool, kept.items.len);
    @memset(placed, false);
    for (kept.items, 0..) |p, i| {
        const has_parent = for (kept.items) |q| {
            // A PID Windows gave again to a newer process isn't its parent.
            if (q.pid == p.ppid and q.pid != p.pid and !newer(q, p)) break true;
        } else false;
        if (!has_parent) try place(arena, &rows, kept.items, placed, i, 0, theirs);
    }
    // A cycle, which reused PIDs could make: what's left, as roots.
    for (placed, 0..) |done, i| if (!done) try place(arena, &rows, kept.items, placed, i, 0, theirs);
    return rows.items;
}

fn newer(a: Proc, b: Proc) bool {
    const ac = a.created orelse return false;
    const bc = b.created orelse return false;
    return ac > bc;
}

fn place(arena: Allocator, rows: *std.ArrayList(Row), procs: []const Proc, placed: []bool, i: usize, depth: usize, theirs: std.AutoHashMapUnmanaged(u32, u32)) !void {
    if (placed[i]) return;
    placed[i] = true;
    const p = procs[i];
    const run = theirs.get(p.pid);
    try rows.append(arena, .{ .proc = p, .depth = depth, .run = run });
    if (run != null) return;
    for (procs, 0..) |q, j| {
        if (q.ppid == p.pid and q.pid != p.pid and !newer(p, q)) try place(arena, rows, procs, placed, j, depth + 1, theirs);
    }
}

/// Memory as `ps` shows it: "812 KB", "212 MB", "1.4 GB".
pub const Bytes = struct {
    n: u64,

    pub fn format(b: Bytes, w: *Io.Writer) Io.Writer.Error!void {
        const kb = 1 << 10;
        const mb = 1 << 20;
        const gb = 1 << 30;
        if (b.n < mb) return w.print("{d} KB", .{(b.n + kb - 1) / kb});
        if (b.n < gb) return w.print("{d} MB", .{(b.n + mb / 2) / mb});
        const tenths = (b.n * 10 + gb / 2) / gb;
        return w.print("{d}.{d} GB", .{ tenths / 10, tenths % 10 });
    }
};

/// Processor time, from 100 ns: "0:04", "12:31", "2:03:09".
pub const Cpu = struct {
    t: u64,

    pub fn format(c: Cpu, w: *Io.Writer) Io.Writer.Error!void {
        const s = c.t / 10_000_000;
        if (s < 3600) return w.print("{d}:{d:0>2}", .{ s / 60, s % 60 });
        return w.print("{d}:{d:0>2}:{d:0>2}", .{ s / 3600, s % 3600 / 60, s % 60 });
    }
};

/// How long ago, from a difference of FILETIMEs: "5s", "12m", "3h 04m",
/// "2d 03h".
pub const Age = struct {
    t: i64,

    pub fn format(a: Age, w: *Io.Writer) Io.Writer.Error!void {
        const s: u64 = @intCast(@max(0, @divTrunc(a.t, 10_000_000)));
        if (s < 60) return w.print("{d}s", .{s});
        if (s < 3600) return w.print("{d}m", .{s / 60});
        if (s < 86400) return w.print("{d}h {d:0>2}m", .{ s / 3600, s % 3600 / 60 });
        return w.print("{d}d {d:0>2}h", .{ s / 86400, s % 86400 / 3600 });
    }
};

const testing = std.testing;

test "formats" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ try std.fmt.allocPrint(testing.allocator, "{f}", .{Bytes{ .n = 1000 }}), "1 KB" },
        .{ try std.fmt.allocPrint(testing.allocator, "{f}", .{Bytes{ .n = 212 << 20 }}), "212 MB" },
        .{ try std.fmt.allocPrint(testing.allocator, "{f}", .{Bytes{ .n = 3 << 29 }}), "1.5 GB" },
        .{ try std.fmt.allocPrint(testing.allocator, "{f}", .{Cpu{ .t = 4 * 10_000_000 }}), "0:04" },
        .{ try std.fmt.allocPrint(testing.allocator, "{f}", .{Cpu{ .t = 7389 * 10_000_000 }}), "2:03:09" },
        .{ try std.fmt.allocPrint(testing.allocator, "{f}", .{Age{ .t = 5 * 10_000_000 }}), "5s" },
        .{ try std.fmt.allocPrint(testing.allocator, "{f}", .{Age{ .t = 734 * 10_000_000 }}), "12m" },
        .{ try std.fmt.allocPrint(testing.allocator, "{f}", .{Age{ .t = 11_040 * 10_000_000 }}), "3h 04m" },
        .{ try std.fmt.allocPrint(testing.allocator, "{f}", .{Age{ .t = -5 }}), "0s" },
    };
    for (cases) |c| {
        defer testing.allocator.free(c[0]);
        try testing.expectEqualStrings(c[1], c[0]);
    }
}

test shortCommand {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("node.exe server.js", try shortCommand(a, "\"C:\\zs\\deploy\\ab\\node.exe\" server.js"));
    try testing.expectEqualStrings("busybox.exe", try shortCommand(a, "C:\\x\\busybox.exe"));
    try testing.expectEqualStrings("cmd.exe /d /c \"x.bat\"", try shortCommand(a, "C:\\Windows\\System32\\cmd.exe /d /c \"x.bat\""));
    try testing.expectEqualStrings("", try shortCommand(a, ""));
}

test summary {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("[sqlite 3/5] make", try summary(a, .{ .kind = .build, .id = "x", .pid = 1, .started = 0, .module = "sqlite", .step = "build", .n = 3, .of = 5, .command = "make" }));
    try testing.expectEqualStrings("[zot vendor 1/2] go mod vendor", try summary(a, .{ .kind = .build, .id = "x", .pid = 1, .started = 0, .module = "zot", .step = "vendor", .n = 1, .of = 2, .command = "go mod vendor" }));
    try testing.expectEqualStrings("(preparing)", try summary(a, .{ .kind = .build, .id = "x", .pid = 1, .started = 0 }));
    const long = try summary(a, .{ .id = "x", .pid = 1, .started = 0, .command = "a.exe " ++ @as([100]u8, @splat('x')) });
    try testing.expectEqual(80, long.len);
    try testing.expect(std.mem.endsWith(u8, long, "..."));
}

test matches {
    const r: Record = .{ .id = "org.nodejs.node", .pid = 4812, .started = 0 };
    try testing.expect(matches(r, &.{}));
    try testing.expect(matches(r, &.{"ORG.nodejs.node"}));
    try testing.expect(matches(r, &.{ "x", "4812" }));
    try testing.expect(!matches(r, &.{"4813"}));
    try testing.expect(!matches(r, &.{"org.nodejs"}));
}

test treeOrder {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // zigsaw 100 runs sh 10 (in the job), which starts sleep 11 and a shim
    // 12, whose zigsaw 13 is a run inside with its own sh 14.
    const procs = [_]Proc{
        .{ .pid = 14, .ppid = 13, .created = 5 },
        .{ .pid = 11, .ppid = 10, .created = 2 },
        .{ .pid = 10, .ppid = 100, .created = 1 },
        .{ .pid = 12, .ppid = 10, .created = 3 },
        .{ .pid = 13, .ppid = 12, .created = 4 },
    };
    var theirs: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    try theirs.put(a, 13, 13);
    try theirs.put(a, 14, 13);
    const rows = try treeOrder(a, &procs, theirs);
    try testing.expectEqual(4, rows.len);
    const want = [_]struct { u32, usize, ?u32 }{ .{ 10, 0, null }, .{ 11, 1, null }, .{ 12, 1, null }, .{ 13, 2, 13 } };
    for (rows, want) |row, w| {
        try testing.expectEqual(w[0], row.proc.pid);
        try testing.expectEqual(w[1], row.depth);
        try testing.expectEqual(w[2], row.run);
    }
}

test "nesting: depthOf and within" {
    // 3 is inside 2, which is inside 1; 4 is inside none.
    const seen = [_]Seen{
        .{ .record = .{ .id = "a", .pid = 1, .started = 0 }, .job = null },
        .{ .record = .{ .id = "b", .pid = 2, .started = 0 }, .job = null, .inside = 1 },
        .{ .record = .{ .id = "c", .pid = 3, .started = 0 }, .job = null, .inside = 2 },
        .{ .record = .{ .id = "d", .pid = 4, .started = 0 }, .job = null },
    };
    try testing.expectEqual(0, depthOf(&seen, 1));
    try testing.expectEqual(2, depthOf(&seen, 3));
    try testing.expectEqual(0, depthOf(&seen, 4));
    try testing.expect(within(&seen, 3, 1));
    try testing.expect(within(&seen, 3, 3));
    try testing.expect(!within(&seen, 1, 3));
    try testing.expect(!within(&seen, 4, 1));
    // A loop, which no real nesting makes, still ends.
    const loop = [_]Seen{
        .{ .record = .{ .id = "x", .pid = 5, .started = 0 }, .job = null, .inside = 6 },
        .{ .record = .{ .id = "y", .pid = 6, .started = 0 }, .job = null, .inside = 5 },
    };
    try testing.expect(!within(&loop, 5, 7));
    _ = depthOf(&loop, 5);
}

test "a PID given again isn't a parent" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 20's parent was a 10 that ended; the 10 now is newer than it.
    const procs = [_]Proc{
        .{ .pid = 20, .ppid = 10, .created = 1 },
        .{ .pid = 10, .ppid = 5, .created = 9 },
    };
    const rows = try treeOrder(a, &procs, .empty);
    try testing.expectEqual(0, rows[0].depth);
    try testing.expectEqual(0, rows[1].depth);
}

test "records: kept, listed, and dropped once their zigsaw is gone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.createDirPath(io, "tmp");
    const store: Store = .{ .io = io, .root = root };

    const first = try beginIn(store, a, .{ .id = "a.b", .pid = 7, .started = 2, .sandbox = "low", .command = "x.exe" });
    var second = try beginIn(store, a, .{ .kind = .build, .id = "c.d", .pid = 8, .started = 1 });
    second.record.module = "m";
    second.record.n = 1;
    second.record.of = 2;
    try write(store, a, second.path, second.record);

    const both = try live(store, a);
    try testing.expectEqual(2, both.len);
    try testing.expectEqualStrings("c.d", both[0].id);
    try testing.expectEqualStrings("m", both[0].module.?);
    try testing.expectEqualStrings("a.b", both[1].id);
    try testing.expectEqualStrings("low", both[1].sandbox.?);

    // As if its zigsaw had been killed: the lock goes, the record stays.
    first.lock.release(io);
    const one = try live(store, a);
    try testing.expectEqual(1, one.len);
    try testing.expectEqualStrings("c.d", one[0].id);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "running\\7.json", .{}));

    second.end(io);
    try testing.expectEqual(0, (try live(store, a)).len);
}
