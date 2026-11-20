//! The logs of detached runs (`run --detach`, and the apps `up` starts):
//! what a run's app writes on its stdout and stderr, and what the run's
//! zigsaw says once the run has started, in <store>\logs\<id>.<pid>.log, by
//! the app's id lowercased and the run's number. A log stays after its run
//! ends, until a detached run of the same app starts, `zigsaw uninstall` removes the
//! app, or `prune` finds it gone. A log that's still being written is never
//! deleted: its writers don't share writing, so Windows refuses (see
//! `deleteIfEnded`).
//!
//! `zigsaw logs` prints one, and with --follow goes on until its run ends.
//! A Follower does that for several at once, each line after its app's
//! name, for `zigsaw logs` in a project and for `zigsaw up`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const ps = @import("ps.zig");
const stop = @import("stop.zig");
const win32 = @import("win32.zig");
const fail = Context.fail;
const note = Context.note;

pub const Log = struct {
    path: []const u8,
    /// Open to append: for the run's zigsaw, and its app's stdout and stderr.
    handle: win32.HANDLE,
};

pub fn dirPath(store: Store, arena: Allocator) ![]const u8 {
    return store.path(arena, &.{"logs"});
}

/// The log of `id`'s run `pid`.
pub fn pathFor(store: Store, arena: Allocator, id: []const u8, pid: u32) ![]const u8 {
    const name = try std.fmt.allocPrint(arena, "{s}.{d}.log", .{ try std.ascii.allocLowerString(arena, id), pid });
    return store.path(arena, &.{ "logs", name });
}

/// A log's file name, read back: whose run it is.
pub const Name = struct {
    id: []const u8,
    pid: u32,

    pub fn parse(name: []const u8) ?Name {
        if (!std.mem.endsWith(u8, name, ".log")) return null;
        const stem = name[0 .. name.len - ".log".len];
        const dot = std.mem.lastIndexOfScalar(u8, stem, '.') orelse return null;
        if (dot == 0 or dot + 1 == stem.len) return null;
        for (stem[dot + 1 ..]) |c| if (!std.ascii.isDigit(c)) return null;
        const pid = std.fmt.parseInt(u32, stem[dot + 1 ..], 10) catch return null;
        return .{ .id = stem[0..dot], .pid = pid };
    }
};

/// The log of this zigsaw's run of `id`, with a first line that says what
/// the run is. The app's logs of runs that have ended go first.
pub fn create(ctx: *Context, id: []const u8, version: []const u8, cwd: []const u8) !Log {
    const arena = ctx.arena;
    try Io.Dir.cwd().createDirPath(ctx.io, try dirPath(ctx.store, arena));
    _ = try deleteEnded(ctx.store, arena, .{ .app = id });
    const path = try pathFor(ctx.store, arena, id, win32.GetCurrentProcessId());
    const h = win32.CreateFileW(try win32.wide(arena, path), win32.FILE_APPEND_DATA | win32.SYNCHRONIZE, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE, null, win32.OPEN_ALWAYS, 0, null);
    if (h == win32.INVALID_HANDLE_VALUE) return win32.lastErrorFail("creating the run's log");
    const header = try std.fmt.allocPrint(arena, "zigsaw: {s} {s}, run {d}, started {s} in {s}\n", .{
        id, version, win32.GetCurrentProcessId(), try localTime(arena, ps.now()), cwd,
    });
    var written: win32.DWORD = 0;
    _ = win32.WriteFile(h, header.ptr, @intCast(header.len), &written, null);
    return .{ .path = path, .handle = h };
}

pub const Which = union(enum) {
    /// One app's.
    app: []const u8,
    /// Those of apps that aren't installed.
    uninstalled,
};

/// Deletes the logs of runs that have ended, of `which` apps: how many.
pub fn deleteEnded(store: Store, arena: Allocator, which: Which) !u32 {
    var n: u32 = 0;
    for (try list(store, arena)) |l| {
        switch (which) {
            .app => |id| if (!std.ascii.eqlIgnoreCase(id, l.name.id)) continue,
            .uninstalled => if (try store.readRef(arena, l.name.id) != null) continue,
        }
        if (deleteIfEnded(arena, l.path)) n += 1;
    }
    return n;
}

/// Deletes a log if nothing writes it any more. Its run's zigsaw and app
/// hold it open to write, sharing reading and deleting but not writing: so
/// opening it to delete, without sharing writing, fails while they do.
fn deleteIfEnded(arena: Allocator, path: []const u8) bool {
    const wide = win32.wide(arena, path) catch return false;
    const h = win32.CreateFileW(wide, win32.DELETE, win32.FILE_SHARE_READ | win32.FILE_SHARE_DELETE, null, win32.OPEN_EXISTING, win32.FILE_FLAG_DELETE_ON_CLOSE, null);
    if (h == win32.INVALID_HANDLE_VALUE) return false;
    _ = win32.CloseHandle(h);
    return true;
}

pub const Listed = struct { name: Name, path: []const u8 };

/// The logs there are, going or ended.
pub fn list(store: Store, arena: Allocator) ![]const Listed {
    const dir_path = try dirPath(store, arena);
    var dir = Io.Dir.cwd().openDir(store.io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => |e| return e,
    };
    defer dir.close(store.io);
    var out: std.ArrayList(Listed) = .empty;
    var it = dir.iterate();
    while (try it.next(store.io)) |entry| {
        if (entry.kind != .file) continue;
        const name = Name.parse(entry.name) orelse continue;
        try out.append(arena, .{
            .name = .{ .id = try arena.dupe(u8, name.id), .pid = name.pid },
            .path = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ dir_path, entry.name }),
        });
    }
    return out.items;
}

/// The log of `id`'s run that started last, of those there are.
pub fn newestOf(store: Store, arena: Allocator, id: []const u8) !?[]const u8 {
    var best: ?[]const u8 = null;
    var best_time: i64 = std.math.minInt(i64);
    for (try list(store, arena)) |l| {
        if (!std.ascii.eqlIgnoreCase(l.name.id, id)) continue;
        const t = createdAt(arena, l.path) orelse continue;
        if (t > best_time) {
            best = l.path;
            best_time = t;
        }
    }
    return best;
}

fn createdAt(arena: Allocator, path: []const u8) ?i64 {
    const h = win32.CreateFileW(win32.wide(arena, path) catch return null, win32.FILE_READ_ATTRIBUTES, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE, null, win32.OPEN_EXISTING, 0, null);
    if (h == win32.INVALID_HANDLE_VALUE) return null;
    defer _ = win32.CloseHandle(h);
    var created: i64 = 0;
    if (win32.GetFileTime(h, &created, null, null) == 0) return null;
    return created;
}

/// "2026-11-15 12:30:05", in this machine's time zone, from a FILETIME.
pub fn localTime(arena: Allocator, filetime: i64) ![]const u8 {
    var local: i64 = 0;
    var t: win32.SYSTEMTIME = undefined;
    if (win32.FileTimeToLocalFileTime(&filetime, &local) == 0 or win32.FileTimeToSystemTime(&local, &t) == 0) return "at an unknown time";
    return std.fmt.allocPrint(arena, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond });
}

// ---------------------------------------------------------------------------
// `zigsaw logs`

pub const Options = struct {
    /// Goes on printing until the runs end.
    follow: bool = false,
    /// Only each log's last lines.
    tail: ?usize = null,
    /// An app's id or a run's number; null for the runs of the project in
    /// the working directory (see up.zig).
    target: ?[]const u8 = null,
};

/// `zigsaw logs <app-id>|<run>`.
pub fn logs(ctx: *Context, opts: Options) !u32 {
    const found = try find(ctx, opts.target.?);
    var f: Follower = .{ .arena = ctx.arena, .io = ctx.io };
    try f.add(.{
        .path = found.path,
        .zigsaw = if (opts.follow) found.zigsaw else null,
        .from = if (opts.tail) |n| .{ .tail = n } else .start,
    });
    try f.run(null);
    return 0;
}

pub const Found = struct {
    path: []const u8,
    /// The run's zigsaw, while the run goes.
    zigsaw: ?win32.HANDLE,
};

/// The log `target` names: a run's, going or ended, by its number; or an
/// app's, of its one detached run going, or else of its run that started
/// last.
pub fn find(ctx: *Context, target: []const u8) !Found {
    const arena = ctx.arena;
    const records = try ps.live(ctx.store, arena);
    if (std.fmt.parseInt(u32, target, 10)) |pid| {
        for (records) |r| if (r.pid == pid) {
            switch (r.kind) {
                .build => return fail("{d} is a build of {s}: only a detached run has a log", .{ r.pid, r.id }),
                .exec => return fail("{d} is a command exec started in a run: only a detached run has a log", .{r.pid}),
                .run => {},
            }
            const log = r.log orelse return fail("run {d} ({s}) isn't detached: its output goes to the terminal it was started in", .{ r.pid, r.id });
            return .{ .path = log, .zigsaw = try stop.openZigsaw(ctx.store, arena, r) };
        };
        for (try list(ctx.store, arena)) |l| if (l.name.pid == pid) return .{ .path = l.path, .zigsaw = null };
        return fail("no run {d} is going, or left a log", .{pid});
    } else |_| {}

    var going: std.ArrayList(ps.Record) = .empty;
    var undetached = false;
    for (records) |r| if (r.kind == .run and std.ascii.eqlIgnoreCase(r.id, target)) {
        if (r.log != null) try going.append(arena, r) else undetached = true;
    };
    switch (going.items.len) {
        0 => {},
        1 => return .{ .path = going.items[0].log.?, .zigsaw = try stop.openZigsaw(ctx.store, arena, going.items[0]) },
        else => {
            var pids: std.ArrayList(u8) = .empty;
            for (going.items, 0..) |r, i| try pids.print(arena, "{s}{d}", .{ if (i == 0) "" else ", ", r.pid });
            return fail("{s} has {d} detached runs going ({s}): name one by its number, as `zigsaw ps` lists it", .{ target, going.items.len, pids.items });
        },
    }
    if (try newestOf(ctx.store, arena, target)) |path| return .{ .path = path, .zigsaw = null };
    if (undetached) return fail("{s}'s run isn't detached: its output goes to the terminal it was started in", .{target});
    return fail("{s} has no log: only a detached run (`zigsaw run -d`, `zigsaw up`) has one", .{target});
}

// ---------------------------------------------------------------------------
// Following logs

pub const From = union(enum) {
    start,
    /// Only what's written from now on.
    end,
    /// The last lines, then what's written from now on.
    tail: usize,
};

pub const Source = struct {
    /// Before each line: "<app> | ", or nothing.
    prefix: []const u8 = "",
    path: []const u8,
    /// The run's zigsaw, to follow the log until the run ends; null to
    /// print what it has.
    zigsaw: ?win32.HANDLE = null,
    from: From = .start,
};

/// Prints logs as they grow, whole lines at a time, each after its prefix,
/// until their runs end.
pub const Follower = struct {
    arena: Allocator,
    io: Io,
    open: std.ArrayList(Open) = .empty,

    const Open = struct {
        source: Source,
        handle: win32.HANDLE,
        /// What came after the last line break so far.
        partial: std.ArrayList(u8) = .empty,
        done: bool = false,
    };

    /// A line that long without a break is printed as it is.
    const longest_line = 16 * 1024;

    pub fn add(f: *Follower, s: Source) !void {
        const h = win32.CreateFileW(try win32.wide(f.arena, s.path), win32.GENERIC_READ, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE, null, win32.OPEN_EXISTING, 0, null);
        if (h == win32.INVALID_HANDLE_VALUE) return win32.lastErrorFail("opening the log");
        switch (s.from) {
            .start => {},
            .end => _ = win32.SetFilePointerEx(h, 0, null, win32.FILE_END),
            .tail => |n| _ = win32.SetFilePointerEx(h, tailStart(h, n), null, win32.FILE_BEGIN),
        }
        try f.open.append(f.arena, .{ .source = s, .handle = h });
    }

    /// Whether every log's run has ended, and all it wrote is printed.
    pub fn done(f: *const Follower) bool {
        for (f.open.items) |o| if (!o.done) return false;
        return true;
    }

    /// Prints what's new in the logs. A log whose run has ended is read to
    /// its end once more, and done.
    pub fn poll(f: *Follower) !void {
        var buf: [16 * 1024]u8 = undefined;
        var stdout = Context.stdout().writerStreaming(f.io, &buf);
        const w = &stdout.interface;
        for (f.open.items) |*o| {
            if (o.done) continue;
            // Asked before reading: what it wrote before it ended is read now.
            const ended = if (o.source.zigsaw) |z| win32.WaitForSingleObject(z, 0) == win32.WAIT_OBJECT_0 else true;
            var chunk: [8192]u8 = undefined;
            while (true) {
                var n: win32.DWORD = 0;
                if (win32.ReadFile(o.handle, &chunk, chunk.len, &n, null) == 0 or n == 0) break;
                try o.partial.appendSlice(f.arena, chunk[0..n]);
                try printLines(w, o.source.prefix, &o.partial);
            }
            if (ended) {
                if (o.partial.items.len > 0) try w.print("{s}{s}\n", .{ o.source.prefix, o.partial.items });
                o.partial.clearRetainingCapacity();
                o.done = true;
                _ = win32.CloseHandle(o.handle);
            }
        }
        w.flush() catch {};
    }

    /// Polls until every log's run has ended, or `until` is set.
    pub fn run(f: *Follower, until: ?win32.HANDLE) !void {
        while (true) {
            try f.poll();
            if (f.done()) return;
            if (until) |e| {
                if (win32.WaitForSingleObject(e, 150) == win32.WAIT_OBJECT_0) return;
            } else win32.Sleep(150);
        }
    }
};

/// Prints the whole lines of `partial`, each after `prefix`, and keeps the
/// rest; or all of it, if it has grown too long for a line.
fn printLines(w: *Io.Writer, prefix: []const u8, partial: *std.ArrayList(u8)) !void {
    const items = partial.items;
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, items, start, '\n')) |nl| {
        try w.print("{s}{s}", .{ prefix, items[start .. nl + 1] });
        start = nl + 1;
    }
    if (items.len - start >= Follower.longest_line) {
        try w.print("{s}{s}\n", .{ prefix, items[start..] });
        start = items.len;
    }
    const rest = items.len - start;
    std.mem.copyForwards(u8, items[0..rest], items[start..]);
    partial.shrinkRetainingCapacity(rest);
}

/// Where the last `n` lines of the file start, reading back from its end a
/// block at a time: a log may be large.
fn tailStart(h: win32.HANDLE, n: usize) i64 {
    var size: i64 = 0;
    if (win32.GetFileSizeEx(h, &size) == 0) return 0;
    if (n == 0) return size;
    var block: [64 * 1024]u8 = undefined;
    var pos = size;
    var count: usize = 0;
    while (pos > 0) {
        const len: usize = @intCast(@min(pos, block.len));
        pos -= @intCast(len);
        if (win32.SetFilePointerEx(h, pos, null, win32.FILE_BEGIN) == 0) return 0;
        var got: usize = 0;
        while (got < len) {
            var read: win32.DWORD = 0;
            if (win32.ReadFile(h, block[got..].ptr, @intCast(len - got), &read, null) == 0 or read == 0) return 0;
            got += read;
        }
        var i = len;
        while (i > 0) {
            i -= 1;
            if (block[i] != '\n') continue;
            // The last line's own break ends it, rather than one before.
            if (pos + @as(i64, @intCast(i)) == size - 1) continue;
            count += 1;
            if (count == n) return pos + @as(i64, @intCast(i)) + 1;
        }
    }
    return 0;
}

/// What each app's lines go after, for a Follower: the last part of its id
/// ("web" for org.example.web), or all of it where two would be the same,
/// padded to one width.
pub fn prefixes(arena: Allocator, ids: []const []const u8) ![]const []const u8 {
    const names = try arena.alloc([]const u8, ids.len);
    for (names, ids, 0..) |*name, id, i| {
        name.* = lastPart(id);
        for (ids, 0..) |other, j| if (i != j and std.ascii.eqlIgnoreCase(lastPart(id), lastPart(other))) {
            name.* = id;
            break;
        };
    }
    var width: usize = 0;
    for (names) |name| width = @max(width, name.len);
    const out = try arena.alloc([]const u8, ids.len);
    for (out, names) |*o, name| {
        const padded = try arena.alloc(u8, width + 3);
        @memcpy(padded[0..name.len], name);
        @memset(padded[name.len..width], ' ');
        @memcpy(padded[width..], " | ");
        o.* = padded;
    }
    return out;
}

fn lastPart(id: []const u8) []const u8 {
    return id[if (std.mem.lastIndexOfScalar(u8, id, '.')) |d| d + 1 else 0..];
}

const testing = std.testing;

test "log names" {
    const n = Name.parse("org.example.web.4812.log").?;
    try testing.expectEqualStrings("org.example.web", n.id);
    try testing.expectEqual(4812, n.pid);
    try testing.expectEqual(null, Name.parse("org.example.web.log"));
    try testing.expectEqual(null, Name.parse("web.48a.log"));
    try testing.expectEqual(null, Name.parse(".4812.log"));
    try testing.expectEqual(null, Name.parse("web.4812.txt"));
    try testing.expectEqual(null, Name.parse("web.+4.log"));
}

test prefixes {
    const arena = testing.allocator;
    var a: std.heap.ArenaAllocator = .init(arena);
    defer a.deinit();
    const got = try prefixes(a.allocator(), &.{ "org.postgresql.postgresql", "org.example.web", "com.other.web", "solo" });
    try testing.expectEqualStrings("postgresql      | ", got[0]);
    try testing.expectEqualStrings("org.example.web | ", got[1]);
    try testing.expectEqualStrings("com.other.web   | ", got[2]);
    try testing.expectEqualStrings("solo            | ", got[3]);
}

test printLines {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    var partial: std.ArrayList(u8) = .empty;
    try partial.appendSlice(a.allocator(), "one\r\ntwo\nthr");
    var out: std.Io.Writer.Allocating = .init(a.allocator());
    try printLines(&out.writer, "x | ", &partial);
    try testing.expectEqualStrings("x | one\r\nx | two\n", out.written());
    try testing.expectEqualStrings("thr", partial.items);
}
