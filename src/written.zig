//! Programs a run writes where it may write on the host. Windows starts a
//! program whose file is labelled low at low integrity, whoever starts it,
//! and what a run writes there comes out labelled low: it inherits the label
//! of a folder a low run labelled (under soft too, in such a folder), and
//! what a low-integrity process writes, as an AppContainer's are, gets a low
//! label of its own. So 7-Zip extracting a program, or MinGit checking one
//! out, would make programs that start at low integrity outside zigsaw too.
//!
//! zigsaw watches the folders a run may write for programs written there
//! (ReadDirectoryChangesW, which needs no privilege, nor a walk of the tree),
//! and records those labelled low in grants\<id>.programs when the run ends.
//! When the app's last run ends (grants.settle), each gets a medium label of
//! its own (acl.labelProgram), which its folder's doesn't replace; the
//! app's next low or AppContainer run labels them low again while it goes,
//! so that the app may write them. `zigsaw rm` forgets them: they stay
//! medium.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");
const acl = @import("acl.zig");
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const note = Context.note;

/// What CreateProcess starts. A program by another name is missed.
pub fn isProgram(name: []const u8) bool {
    for ([_][]const u8{ ".exe", ".com", ".scr" }) |ext|
        if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    return false;
}

/// How many entries a folder's walk looks at, when its watch missed
/// changes, before it gives up.
const walk_limit = 50_000;

const Watch = struct {
    path: []const u8,
    handle: win32.HANDLE,
    overlapped: win32.OVERLAPPED = std.mem.zeroes(win32.OVERLAPPED),
    buffer: [64 * 1024]u8 align(@alignOf(win32.FILE_NOTIFY_INFORMATION)) = undefined,
    /// Changes came faster than the watch could take them.
    missed: bool = false,
};

/// Watches folders for the programs written in them while a run goes, from
/// a thread of its own.
pub const Watcher = struct {
    port: win32.HANDLE,
    watches: []*Watch,
    thread: std.Thread,
    since: Io.Timestamp,
    /// The thread's own, until `stop` returns.
    found_arena: std.heap.ArenaAllocator,
    found: std.ArrayList([]const u8) = .empty,

    /// Null when there's nothing to watch, or watching can't start: then
    /// the run's programs keep the label they get.
    pub fn start(arena: Allocator, io: Io, dirs: []const []const u8) ?*Watcher {
        if (dirs.len == 0) return null;
        return startOrFail(arena, io, dirs) catch |err| {
            note("warning: can't watch for the programs this run writes ({t}): they'll start at low integrity", .{err});
            return null;
        };
    }

    fn startOrFail(arena: Allocator, io: Io, dirs: []const []const u8) !*Watcher {
        const port = win32.CreateIoCompletionPort(win32.INVALID_HANDLE_VALUE, null, 0, 1) orelse return error.CreateIoCompletionPort;
        var watches: std.ArrayList(*Watch) = .empty;
        for (dirs) |dir| {
            const handle = win32.CreateFileW(
                try win32.wide(arena, dir),
                win32.FILE_LIST_DIRECTORY,
                win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
                null,
                win32.OPEN_EXISTING,
                win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OVERLAPPED,
                null,
            );
            if (handle == win32.INVALID_HANDLE_VALUE) continue;
            const w = try arena.create(Watch);
            w.* = .{ .path = dir, .handle = handle };
            if (win32.CreateIoCompletionPort(handle, port, @intFromPtr(w), 0) == null or !issue(w)) {
                _ = win32.CloseHandle(handle);
                continue;
            }
            try watches.append(arena, w);
        }
        const self = try arena.create(Watcher);
        self.* = .{
            .port = port,
            .watches = watches.items,
            .thread = undefined,
            .since = Io.Timestamp.now(io, .real),
            .found_arena = .init(std.heap.page_allocator),
        };
        self.thread = try std.Thread.spawn(.{}, collect, .{self});
        return self;
    }

    /// Ends the watch, and returns the programs written in the folders that
    /// are labelled low now, as absolute paths, each once.
    pub fn stop(self: *Watcher, arena: Allocator, io: Io) ![]const []const u8 {
        // Key 0 is no watch's: the thread ends at it.
        _ = win32.PostQueuedCompletionStatus(self.port, 0, 0, null);
        self.thread.join();
        // The cancelled reads complete into memory that stays until zigsaw
        // exits, which it does after the run.
        for (self.watches) |w| {
            _ = win32.CancelIoEx(w.handle, null);
            _ = win32.CloseHandle(w.handle);
        }

        var candidates: std.ArrayList([]const u8) = .empty;
        try candidates.appendSlice(arena, self.found.items);
        for (self.watches) |w| if (w.missed) try walk(arena, io, w.path, self.since, &candidates);

        var programs: std.ArrayList([]const u8) = .empty;
        next: for (candidates.items) |p| {
            for (programs.items) |q| if (std.os.windows.eqlIgnoreCaseWtf8(p, q)) continue :next;
            const attrs = win32.GetFileAttributesW(try win32.wide(arena, p));
            if (attrs == win32.INVALID_FILE_ATTRIBUTES or attrs & win32.FILE_ATTRIBUTE_DIRECTORY != 0) continue;
            const rid = (acl.effectiveLabel(arena, p) catch continue) orelse continue;
            if (rid <= win32.SECURITY_MANDATORY_LOW_RID) try programs.append(arena, try arena.dupe(u8, p));
        }
        return programs.items;
    }

    fn collect(self: *Watcher) void {
        const gpa = self.found_arena.allocator();
        while (true) {
            var bytes: win32.DWORD = 0;
            var key: usize = 0;
            var overlapped: ?*win32.OVERLAPPED = null;
            const ok = win32.GetQueuedCompletionStatus(self.port, &bytes, &key, &overlapped, win32.INFINITE) != 0;
            if (key == 0) return;
            const w: *Watch = @ptrFromInt(key);
            // The folder went, or can't be read any more.
            if (!ok) continue;
            if (bytes == 0) w.missed = true else gather(gpa, w, bytes, &self.found) catch {
                w.missed = true;
            };
            if (!issue(w)) w.missed = true;
        }
    }

    fn gather(gpa: Allocator, w: *Watch, bytes: win32.DWORD, list: *std.ArrayList([]const u8)) !void {
        var offset: usize = 0;
        while (offset + @sizeOf(win32.FILE_NOTIFY_INFORMATION) <= bytes) {
            const info: *const win32.FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(&w.buffer[offset]));
            const name_w = @as([*]const u16, @ptrCast(&info.FileName))[0 .. info.FileNameLength / 2];
            switch (info.Action) {
                win32.FILE_ACTION_ADDED, win32.FILE_ACTION_MODIFIED, win32.FILE_ACTION_RENAMED_NEW_NAME => {
                    const name = try std.unicode.wtf16LeToWtf8Alloc(gpa, name_w);
                    if (isProgram(name)) try list.append(gpa, try std.fs.path.join(gpa, &.{ w.path, name }));
                },
                else => {},
            }
            if (info.NextEntryOffset == 0) break;
            offset += info.NextEntryOffset;
        }
    }
};

/// Starts the watch's next read; false if it can't.
fn issue(w: *Watch) bool {
    w.overlapped = std.mem.zeroes(win32.OVERLAPPED);
    return win32.ReadDirectoryChangesW(
        w.handle,
        &w.buffer,
        w.buffer.len,
        1, // and every folder in it
        win32.FILE_NOTIFY_CHANGE_FILE_NAME | win32.FILE_NOTIFY_CHANGE_LAST_WRITE,
        null,
        &w.overlapped,
        null,
    ) != 0;
}

/// The programs in `dir` written since `since`, for a watch that missed
/// changes: up to walk_limit entries, then it says it gave up.
fn walk(arena: Allocator, io: Io, dir: []const u8, since: Io.Timestamp, list: *std.ArrayList([]const u8)) !void {
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var walker = try d.walk(arena);
    defer walker.deinit();
    var seen: usize = 0;
    while (walker.next(io) catch null) |entry| {
        seen += 1;
        if (seen > walk_limit) {
            note("warning: didn't look through all of {s} for the programs this run wrote; those it missed start at low integrity", .{dir});
            return;
        }
        if (entry.kind != .file or !isProgram(entry.basename)) continue;
        const stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
        // A second's slack, for file systems that round times.
        if (stat.mtime.nanoseconds + std.time.ns_per_s < since.nanoseconds) continue;
        try list.append(arena, try std.fs.path.join(arena, &.{ dir, entry.path }));
    }
}

/// Ends the watch, and records the programs the run wrote. Only warns if
/// that fails: the run itself went fine.
pub fn finish(ctx: *Context, id: []const u8, w: *Watcher) void {
    const programs = w.stop(ctx.arena, ctx.io) catch |err| return lost(err);
    record(ctx, id, programs) catch |err| lost(err);
}

fn lost(err: anyerror) void {
    note("warning: can't record the programs this run wrote ({t}): they'll start at low integrity", .{err});
}

/// Adds a run's programs to those the app's runs wrote, and says how many
/// weren't among them.
fn record(ctx: *Context, id: []const u8, programs: []const []const u8) !void {
    if (programs.len == 0) return;
    const arena = ctx.arena;
    const changes = try ctx.store.lockGrantChanges(arena);
    defer changes.release(ctx.io);
    var all: std.ArrayList([]const u8) = .empty;
    try all.appendSlice(arena, try ctx.store.readPrograms(arena, id));
    const before = all.items.len;
    next: for (programs) |p| {
        for (all.items) |q| if (std.os.windows.eqlIgnoreCaseWtf8(p, q)) continue :next;
        try all.append(arena, p);
    }
    try ctx.store.writePrograms(arena, id, all.items);
    const new = all.items.len - before;
    if (new > 0) note("{d} program{s} this run wrote will start at medium integrity, not low, once the app's runs have ended", .{ new, if (new == 1) "" else "s" });
}

/// Labels the app's programs low again, for a low or AppContainer run, so
/// that it may write them.
pub fn relabel(ctx: *Context, id: []const u8) !void {
    const arena = ctx.arena;
    if ((try ctx.store.readPrograms(arena, id)).len == 0) return;
    const changes = try ctx.store.lockGrantChanges(arena);
    defer changes.release(ctx.io);
    for (try ctx.store.readPrograms(arena, id)) |p| {
        if (!try Store.exists(ctx.io, p)) continue;
        if (try acl.effectiveLabel(arena, p)) |rid| if (rid <= win32.SECURITY_MANDATORY_LOW_RID) continue;
        acl.labelProgram(arena, p, .low) catch |err| switch (err) {
            error.Failed => continue, // Reported; the app can't write it.
            else => |e| return e,
        };
        if (ctx.verbose) note("labelled {s} low integrity again, for the run", .{p});
    }
}

/// Takes the low label off the app's programs, once its runs have all
/// ended; forgets those that are gone. The caller holds grants.lock.
pub fn settle(ctx: *Context, id: []const u8) !void {
    const arena = ctx.arena;
    const recorded = try ctx.store.readPrograms(arena, id);
    if (recorded.len == 0) return;
    var kept: std.ArrayList([]const u8) = .empty;
    for (recorded) |p| {
        if (!try Store.exists(ctx.io, p)) continue;
        try kept.append(arena, p);
        const rid = (try acl.effectiveLabel(arena, p)) orelse continue;
        if (rid > win32.SECURITY_MANDATORY_LOW_RID) continue;
        acl.labelProgram(arena, p, .medium) catch |err| switch (err) {
            error.Failed => continue, // Reported; tried again next time.
            else => |e| return e,
        };
        if (ctx.verbose) note("took the low integrity label off {s}", .{p});
    }
    try ctx.store.writePrograms(arena, id, kept.items);
}

test isProgram {
    for ([_][]const u8{ "a.exe", "B.EXE", "x.Com", "s.scr", "dir\\tool.exe" }) |n| try std.testing.expect(isProgram(n));
    for ([_][]const u8{ "a.dll", "a.exe.txt", "exe", "a.bat", "a.ps1" }) |n| try std.testing.expect(!isProgram(n));
}
