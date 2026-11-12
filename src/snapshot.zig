//! An app's data as an earlier version left it, so that going back to that
//! version (rollback.zig) can take the data back too: PostgreSQL's server
//! doesn't read a cluster a newer major version made.
//!
//! When an install replaces an app's version, the app's own volume (see
//! volumes.zig) is copied to snapshots\<id>\, and versions\<id>.data.json
//! says which version left it so. One copy is kept for each app, as one
//! previous version is. The copy
//! - is of the app's own volume only: a directory link in it, to a volume it
//!   mounts or to one of your folders, is neither followed nor copied, as the
//!   app's next run makes those again; and data mounted in place of the
//!   volume (`--volume=<source>:.`) isn't copied at all;
//! - leaves out what the app can make again: its temporary files and cache;
//! - is taken while no run of the app goes on, with the keys it keeps in
//!   HKCU back in its data (hkcu.zig). If a run goes on, the copy is owed:
//!   the app's next run takes it before it starts, if it's alone then.
//!
//! Taking the data back swaps the two folders, by renaming them: the data
//! as the version left wrote it is set aside in the copy's place, for going
//! forward again, until the next install replaces it.
//!
//! `zigsaw override --nosnapshot` keeps an app's data from being copied.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const hkcu = @import("hkcu.zig");
const junction = @import("junction.zig");
const oci = @import("oci.zig");
const override = @import("override.zig");
const updates = @import("updates.zig");
const fail = Context.fail;
const note = Context.note;

pub const Kept = Store.KeptData;

/// What a copy leaves out, as paths in the data directory: what the app
/// makes again, and would only take long to copy.
pub const left_out = [_][]const u8{ "home\\AppData\\Local\\Temp", "cache" };

/// How many files a folder has, and their size.
pub const Tally = struct { bytes: u64 = 0, files: u64 = 0 };

/// Keeps the app's data as the version an install replaces left it, in
/// place of whatever was kept before; or owes that, if a run of the app goes
/// on. Says what it did. A copy that fails only warns: the install goes on.
pub fn keep(ctx: *Context, id: []const u8, replaced: Store.Ref) !void {
    const arena = ctx.arena;
    const store = ctx.store;
    const io = ctx.io;
    // A swap that stopped halfway has the app's data: back in place first.
    try finishSwap(ctx, id);
    // What's kept is of a version before the one replaced now, or an earlier
    // copy of its data: nothing goes back to either any more.
    if (try forget(ctx, id)) |old| if (old.set_aside)
        note("  dropped  its data as {s} left it, which a rollback set aside {f}", .{ old.version, ago(ctx, old.taken) });
    _ = try store.forgetOwedData(arena, id);
    const settings = override.loadFor(store, arena, id) catch |err| switch (err) {
        error.Failed => return, // Reported.
        else => |e| return e,
    };
    if (settings.snapshot) |on| if (!on) return;

    const data_dir = try store.dataDir(arena, id);
    switch (try junction.inspect(io, arena, data_dir)) {
        .missing, .empty_dir => return,
        .link => |to| {
            note("  data     no copy is kept for `zigsaw rollback`: its data is {s}, mounted in place of its own volume", .{to orelse "elsewhere"});
            return;
        },
        .other => {},
    }
    const alone = try Store.tryLock(io, try store.runsLockPath(arena, id), .exclusive) orelse {
        try store.writeOwedData(arena, id, .{ .version = replaced.version, .manifest = replaced.manifest });
        note("  data     a run of {s} goes on: its next run copies its data as {s} left it first, for `zigsaw rollback`", .{ id, replaced.version });
        return;
    };
    defer alone.release(io);
    const kept = try copy(ctx, id, replaced) orelse return;
    note("  kept     its data as {s} left it ({Bi:.1} in {d} file(s), copied in {f}), for `zigsaw rollback`", .{
        replaced.version, kept.bytes, kept.files, ctx.since(kept.start),
    });
}

const Copied = struct { bytes: u64, files: u64, start: Io.Timestamp };

/// Copies the app's data to snapshots\<id>, as `of` left it; null if there
/// was nothing to copy, or it failed (reported as a warning). The caller
/// holds the app's runs lock exclusively, and nothing is kept yet.
fn copy(ctx: *Context, id: []const u8, of: Store.Ref) !?Copied {
    const arena = ctx.arena;
    const store = ctx.store;
    const io = ctx.io;
    const start = ctx.now();
    // What a run that didn't end left in HKCU goes back into the data first.
    hkcu.settleLeftovers(ctx, id) catch |err| switch (err) {
        error.Failed => {
            note("  warning: no copy of {s}'s data is kept for `zigsaw rollback`: the keys it keeps in the registry couldn't be put back with it", .{id});
            return null;
        },
        else => |e| return e,
    };
    const tmp = try store.tmpPath(arena, "snapshot");
    var walk: Walk = .{ .io = io, .arena = arena, .left_out = &left_out };
    walk.run(try store.dataDir(arena, id), tmp) catch |err| switch (err) {
        error.Stopped => {
            Store.deleteTree(io, arena, tmp) catch {};
            note("  warning: no copy of {s}'s data is kept for `zigsaw rollback`: {s}", .{ id, walk.why });
            return null;
        },
        else => |e| return e,
    };
    if (walk.tally.files == 0) {
        Store.deleteTree(io, arena, tmp) catch {};
        return null;
    }
    const dir = try store.snapshotDir(arena, id);
    if (try Store.exists(io, dir)) try Store.deleteTree(io, arena, dir);
    try Io.Dir.rename(.cwd(), tmp, .cwd(), dir, io);
    // Last: a copy that stopped is only a leftover in tmp\.
    try store.writeKeptData(arena, id, .{
        .version = of.version,
        .manifest = of.manifest,
        .taken = Io.Timestamp.now(io, .real).toSeconds(),
        .bytes = walk.tally.bytes,
        .files = walk.tally.files,
    });
    return .{ .bytes = walk.tally.bytes, .files = walk.tally.files, .start = start };
}

/// Before a run of the app that isn't `--ephemeral` starts, with the store
/// lock held: finishes a swap that stopped halfway, and takes the copy an
/// install owed, if no other run of the app goes on.
pub fn beforeRun(ctx: *Context, id: []const u8) !void {
    const arena = ctx.arena;
    const store = ctx.store;
    const io = ctx.io;
    try finishSwap(ctx, id);
    const owed = try store.readOwedData(arena, id) orelse return;
    const alone = try Store.tryLock(io, try store.runsLockPath(arena, id), .exclusive) orelse {
        // The new version runs beside the one replaced: the data is no
        // longer as that one left it. Unless another run is taking the copy.
        if (try store.forgetOwedData(arena, id))
            note("note: no copy of {s}'s data as {s} left it is kept for `zigsaw rollback`: a run of that version still goes on", .{ id, owed.version });
        return;
    };
    defer alone.release(io);
    _ = try store.forgetOwedData(arena, id);
    // Only for the version there is to go back to.
    const previous = try store.readPrevious(arena, id) orelse return;
    if (!std.mem.eql(u8, previous.manifest, owed.manifest)) return;
    if (try store.readKeptData(arena, id) != null) return;
    switch (try junction.inspect(io, arena, try store.dataDir(arena, id))) {
        .other => {},
        .missing, .empty_dir, .link => return,
    }
    const kept = try copy(ctx, id, previous) orelse return;
    note("kept {s}'s data as {s} left it ({Bi:.1} in {d} file(s), copied in {f}), for `zigsaw rollback`", .{
        id, previous.version, kept.bytes, kept.files, ctx.since(kept.start),
    });
}

/// The data kept as the version of that manifest left it, if it's there.
pub fn keptOf(ctx: *Context, id: []const u8, manifest: []const u8) !?Kept {
    const kept = try ctx.store.readKeptData(ctx.arena, id) orelse return null;
    if (!std.mem.eql(u8, kept.manifest, manifest)) return null;
    return switch (try junction.inspect(ctx.io, ctx.arena, try ctx.store.snapshotDir(ctx.arena, id))) {
        .other, .empty_dir => kept,
        .missing, .link => null,
    };
}

/// Whether the app has data of its own, in its own volume.
pub fn hasData(ctx: *Context, id: []const u8) !bool {
    return try junction.inspect(ctx.io, ctx.arena, try ctx.store.dataDir(ctx.arena, id)) == .other;
}

/// Whether a run of the app goes on.
pub fn running(ctx: *Context, id: []const u8) !bool {
    const l = try Store.tryLock(ctx.io, try ctx.store.runsLockPath(ctx.arena, id), .exclusive) orelse return true;
    l.release(ctx.io);
    return false;
}

/// "3 days ago", for when data was copied or set aside.
pub fn ago(ctx: *Context, taken: i64) updates.Ago {
    return .{ .seconds = Io.Timestamp.now(ctx.io, .real).toSeconds() - taken };
}

/// Where a swap keeps the app's data between its renames: a name no app's id
/// can be, as none starts with a dot.
fn swapPath(ctx: *Context, id: []const u8) ![]u8 {
    return ctx.store.path(ctx.arena, &.{ "snapshots", try std.fmt.allocPrint(ctx.arena, ".swap-{s}", .{id}) });
}

/// Makes the data kept of the installed version the app's data, and sets
/// the app's data aside in its place, as the data the version left wrote:
/// the app's previous version, which a rollback has just made so. Only
/// renames, so it takes no time, and a second swap undoes it. The caller has
/// checked that the data kept is the installed version's (`keptOf`). Fails
/// if a run of the app goes on.
pub fn swap(ctx: *Context, id: []const u8) !void {
    const arena = ctx.arena;
    const store = ctx.store;
    const io = ctx.io;
    const alone = try Store.tryLock(io, try store.runsLockPath(arena, id), .exclusive) orelse
        return fail("a run of {s} goes on, and its data can't change under it: let it end first", .{id});
    defer alone.release(io);
    try finishSwapAlone(ctx, id);
    try hkcu.settleLeftovers(ctx, id);

    const data_dir = try store.dataDir(arena, id);
    const kept_dir = try store.snapshotDir(arena, id);
    const aside = try swapPath(ctx, id);
    const live = try junction.inspect(io, arena, data_dir);
    if (live == .link) return fail("{s}'s data is {s}, mounted in place of its own volume, which zigsaw doesn't move: `zigsaw override --novolume=. {s}` first", .{
        id, live.link orelse "elsewhere", id,
    });
    // From here on the record is gone: what stops between the renames is
    // finished by the app's next run, or the next rollback (finishSwap). If a
    // rename fails, all is put back as it was, the record too.
    const record = try store.readKeptData(arena, id);
    _ = try store.forgetKeptData(arena, id);
    switch (live) {
        .missing => {},
        .empty_dir => _ = win32.RemoveDirectoryW(try win32.wide(arena, data_dir)),
        .other => move(arena, id, data_dir, aside) catch |err| {
            if (record) |r| store.writeKeptData(arena, id, r) catch {};
            return err;
        },
        .link => unreachable,
    }
    move(arena, id, kept_dir, data_dir) catch |err| {
        if (live == .other) move(arena, id, aside, data_dir) catch {};
        if (record) |r| store.writeKeptData(arena, id, r) catch {};
        return err;
    };
    if (live == .other) try settleAside(ctx, id);
}

/// Renames a folder of an app's data, or says why it can't be.
fn move(arena: Allocator, id: []const u8, from: []const u8, to: []const u8) !void {
    if (win32.MoveFileExW(try win32.wide(arena, from), try win32.wide(arena, to), 0) != 0) return;
    const code = win32.GetLastError();
    return fail("moving {s}'s data from {s} to {s}: error {d} ({s}); close what has files open there, then try again", .{
        id, from, to, code, win32.errorName(code),
    });
}

/// The last step of a swap: the data set aside becomes what's kept, as the
/// app's previous version left it.
fn settleAside(ctx: *Context, id: []const u8) !void {
    const arena = ctx.arena;
    const store = ctx.store;
    const aside = try swapPath(ctx, id);
    const kept_dir = try store.snapshotDir(arena, id);
    try move(arena, id, aside, kept_dir);
    // With nothing to go back to, nothing would offer it: `prune` deletes it.
    const left = try store.readPrevious(arena, id) orelse return;
    var walk: Walk = .{ .io = ctx.io, .arena = arena, .left_out = &.{} };
    walk.run(kept_dir, null) catch |err| switch (err) {
        error.Stopped => {},
        else => |e| return e,
    };
    try store.writeKeptData(arena, id, .{
        .version = left.version,
        .manifest = left.manifest,
        .taken = Io.Timestamp.now(ctx.io, .real).toSeconds(),
        .bytes = walk.tally.bytes,
        .files = walk.tally.files,
        .set_aside = true,
    });
}

/// Finishes a swap that stopped between its renames (zigsaw was killed), if
/// no run of the app goes on.
pub fn finishSwap(ctx: *Context, id: []const u8) !void {
    if (!try Store.exists(ctx.io, try swapPath(ctx, id))) return;
    const alone = try Store.tryLock(ctx.io, try ctx.store.runsLockPath(ctx.arena, id), .exclusive) orelse return;
    defer alone.release(ctx.io);
    try finishSwapAlone(ctx, id);
}

fn finishSwapAlone(ctx: *Context, id: []const u8) !void {
    const arena = ctx.arena;
    const io = ctx.io;
    const aside = try swapPath(ctx, id);
    if (!try Store.exists(io, aside)) return;
    const data_dir = try ctx.store.dataDir(arena, id);
    switch (try junction.inspect(io, arena, data_dir)) {
        // It stopped before the data kept took its place: back as it was.
        .missing, .empty_dir => {
            _ = win32.RemoveDirectoryW(try win32.wide(arena, data_dir));
            try move(arena, id, aside, data_dir);
            note("note: put {s}'s data back where a rollback that didn't finish left it", .{id});
        },
        // It stopped after: only the last step is left.
        .other, .link => if (!try Store.exists(io, try ctx.store.snapshotDir(arena, id))) try settleAside(ctx, id),
    }
}

/// Deletes what's kept of the app's data, and returns what it was.
pub fn forget(ctx: *Context, id: []const u8) !?Kept {
    const arena = ctx.arena;
    const kept = try ctx.store.readKeptData(arena, id);
    // The record first: the folder without it is a leftover to `prune`.
    _ = try ctx.store.forgetKeptData(arena, id);
    const dir = try ctx.store.snapshotDir(arena, id);
    if (try Store.exists(ctx.io, dir)) try Store.deleteTree(ctx.io, arena, dir);
    return kept;
}

/// The data kept of installed apps: how many, and their size, as recorded.
pub fn keptTotal(ctx: *Context, installed: []const Store.Ref) !Tally {
    var out: Tally = .{};
    for (installed) |ref| if (try ctx.store.readKeptData(ctx.arena, ref.id)) |k| {
        out.files += 1;
        out.bytes += k.bytes;
    };
    return out;
}

/// For `prune`: deletes the folders in snapshots\ that nothing records, and
/// those of apps that aren't installed, or with `all`, every one. Never a
/// swap's, which is an app's data on its way. Returns how many went, or
/// would, and their size.
pub fn prune(ctx: *Context, installed: []const Store.Ref, all: bool, dry_run: bool) !Tally {
    const arena = ctx.arena;
    const io = ctx.io;
    var names: std.ArrayList([]const u8) = .empty;
    {
        var dir = try Io.Dir.cwd().openDir(io, try ctx.store.path(arena, &.{"snapshots"}), .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            // A swap's folder isn't an id's.
            if (entry.kind != .directory or !oci.isValidId(entry.name)) continue;
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
    }
    var out: Tally = .{};
    for (names.items) |id| {
        const is_installed = for (installed) |ref| {
            if (std.ascii.eqlIgnoreCase(ref.id, id)) break true;
        } else false;
        const recorded = try ctx.store.readKeptData(arena, id) != null;
        if (!all and is_installed and recorded) continue;
        // In use only while it's being made or swapped, under this lock.
        const alone = try Store.tryLock(io, try ctx.store.runsLockPath(arena, id), .exclusive) orelse continue;
        defer alone.release(io);
        var walk: Walk = .{ .io = io, .arena = arena, .left_out = &.{} };
        walk.run(try ctx.store.snapshotDir(arena, id), null) catch |err| switch (err) {
            error.Stopped => {},
            else => |e| return e,
        };
        out.files += 1;
        out.bytes += walk.tally.bytes;
        if (!dry_run) _ = try forget(ctx, id);
    }
    return out;
}

// ---------------------------------------------------------------------------
// Copying

/// Copies a folder's files, or with no destination only counts them. Never
/// follows a directory link, nor copies one.
const Walk = struct {
    io: Io,
    /// For `why` only.
    arena: Allocator,
    /// Paths in the folder that are left out, their parts separated by '\'.
    left_out: []const []const u8,
    tally: Tally = .{},
    /// The links it passed over.
    links: usize = 0,
    /// Why it stopped, after error.Stopped.
    why: []const u8 = "",
    /// The files still to copy, whose folders are made already, and the
    /// memory their paths are in. They go a batch at a time, a few at once:
    /// a profile's many small files each cost more to open than to copy.
    jobs: std.ArrayList(Job) = .empty,
    batch: std.heap.ArenaAllocator = .init(std.heap.page_allocator),

    const Error = error{ Stopped, OutOfMemory };
    const Job = struct { src: [:0]const u16, dst: [:0]const u16, name: []const u8 };
    const batch_size = 2048;
    const max_threads = 8;

    fn run(w: *Walk, from: []const u8, to: ?[]const u8) Error!void {
        const src = absolute(w.io, w.arena, from) catch return w.stop("{s} has no full path", .{from});
        const dst = if (to) |t| absolute(w.io, w.arena, t) catch return w.stop("{s} has no full path", .{t}) else null;
        if (dst) |d| Io.Dir.cwd().createDirPath(w.io, d) catch |err| return w.stop("making {s}: {t}", .{ d, err });
        defer {
            w.batch.deinit();
            w.batch = .init(std.heap.page_allocator);
            w.jobs = .empty;
        }
        try w.dir(src, dst, "");
        try w.flush();
    }

    /// Copies the files that wait, with as many threads as helps.
    fn flush(w: *Walk) Error!void {
        const jobs = w.jobs.items;
        if (jobs.len == 0) return;
        defer {
            w.jobs = .empty;
            _ = w.batch.reset(.retain_capacity);
        }
        var copying: Copying = .{ .jobs = jobs };
        const cpus = std.Thread.getCpuCount() catch 2;
        const wanted = @min(@min(max_threads, cpus), @max(1, jobs.len / 4));
        var threads: [max_threads]std.Thread = undefined;
        var started: usize = 0;
        // This thread is one of them.
        while (started + 1 < wanted) : (started += 1)
            threads[started] = std.Thread.spawn(.{}, Copying.work, .{&copying}) catch break;
        copying.work();
        for (threads[0..started]) |t| t.join();
        w.tally.files += copying.done.load(.monotonic);
        w.tally.bytes += copying.bytes.load(.monotonic);
        if (copying.failed.load(.monotonic)) return w.stop("copying {s}: error {d} ({s})", .{
            jobs[copying.failed_job].name, copying.code, win32.errorName(copying.code),
        });
    }

    /// A batch of files being copied, which threads take one after another.
    const Copying = struct {
        jobs: []const Job,
        next: std.atomic.Value(usize) = .init(0),
        done: std.atomic.Value(usize) = .init(0),
        bytes: std.atomic.Value(u64) = .init(0),
        failed: std.atomic.Value(bool) = .init(false),
        /// Of the first copy that failed: written by the thread it failed in.
        failed_job: usize = 0,
        code: win32.DWORD = 0,

        fn work(c: *Copying) void {
            while (!c.failed.load(.monotonic)) {
                const i = c.next.fetchAdd(1, .monotonic);
                if (i >= c.jobs.len) return;
                const job = c.jobs[i];
                if (win32.CopyFileW(job.src, job.dst, 1) == 0) {
                    const code = win32.GetLastError();
                    if (!c.failed.swap(true, .monotonic)) {
                        c.failed_job = i;
                        c.code = code;
                    }
                    return;
                }
                _ = c.bytes.fetchAdd(sizeOf(job.src), .monotonic);
                _ = c.done.fetchAdd(1, .monotonic);
            }
        }
    };

    fn sizeOf(file: [:0]const u16) u64 {
        var data: win32.WIN32_FILE_ATTRIBUTE_DATA = undefined;
        if (win32.GetFileAttributesExW(file, win32.GetFileExInfoStandard, &data) == 0) return 0;
        return (@as(u64, data.nFileSizeHigh) << 32) | data.nFileSizeLow;
    }

    fn stop(w: *Walk, comptime fmt: []const u8, args: anytype) Error {
        w.why = try std.fmt.allocPrint(w.arena, fmt, args);
        return error.Stopped;
    }

    fn dir(w: *Walk, from: []const u8, to: ?[]const u8, rel: []const u8) Error!void {
        // Its own memory, freed as it ends: a large tree has many paths.
        var scratch_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        const Entry = struct { name: []const u8, kind: Io.File.Kind };
        var entries: std.ArrayList(Entry) = .empty;
        {
            var d = Io.Dir.cwd().openDir(w.io, from, .{ .iterate = true }) catch |err| return w.stop("reading {s}: {t}", .{ from, err });
            defer d.close(w.io);
            var it = d.iterate();
            while (it.next(w.io) catch |err| return w.stop("reading {s}: {t}", .{ from, err })) |entry|
                try entries.append(scratch, .{ .name = try scratch.dupe(u8, entry.name), .kind = entry.kind });
        }
        for (entries.items) |entry| {
            const child_rel = if (rel.len == 0) entry.name else try std.fs.path.join(scratch, &.{ rel, entry.name });
            if (w.isLeftOut(child_rel)) continue;
            const src = try std.fs.path.join(scratch, &.{ from, entry.name });
            const dst = if (to) |t| try std.fs.path.join(scratch, &.{ t, entry.name }) else null;
            const src_w = try w.wide(scratch, src);
            switch (entry.kind) {
                .directory => {
                    // However it shows: what a link leads to isn't the app's.
                    const attrs = win32.GetFileAttributesW(src_w);
                    if (attrs != win32.INVALID_FILE_ATTRIBUTES and attrs & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0) {
                        w.links += 1;
                        continue;
                    }
                    if (dst) |d| if (win32.CreateDirectoryW(try w.wide(scratch, d), null) == 0)
                        return w.stop("making {s}: error {d} ({s})", .{ d, win32.GetLastError(), win32.errorName(win32.GetLastError()) });
                    try w.dir(src, dst, child_rel);
                },
                .file => if (dst) |d| {
                    const kept = w.batch.allocator();
                    try w.jobs.append(kept, .{ .src = try w.wide(kept, src), .dst = try w.wide(kept, d), .name = try kept.dupe(u8, src) });
                    if (w.jobs.items.len >= batch_size) try w.flush();
                } else {
                    w.tally.bytes += sizeOf(src_w);
                    w.tally.files += 1;
                },
                else => w.links += 1,
            }
        }
    }

    fn wide(w: *Walk, scratch: Allocator, p: []const u8) Error![:0]u16 {
        return long(scratch, p) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => w.stop("{s} isn't a path Windows takes", .{p}),
        };
    }

    fn isLeftOut(w: *const Walk, rel: []const u8) bool {
        for (w.left_out) |p| if (std.os.windows.eqlIgnoreCaseWtf8(p, rel)) return true;
        return false;
    }
};

/// A path with its drive, and '\' between its parts.
pub fn absolute(io: Io, arena: Allocator, p: []const u8) ![]u8 {
    const full = if (std.fs.path.isAbsoluteWindows(p))
        try arena.dupe(u8, p)
    else
        try std.fs.path.resolveWindows(arena, &.{ try std.process.currentPathAlloc(io, arena), p });
    std.mem.replaceScalar(u8, full, '/', '\\');
    return full;
}

/// A path for the Windows functions that otherwise stop at 260 characters:
/// an app's profile may hold longer ones.
pub fn long(arena: Allocator, p: []const u8) ![:0]u16 {
    const on_drive = p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and p[2] == '\\';
    return win32.wide(arena, if (on_drive) try std.mem.concat(arena, u8, &.{ "\\\\?\\", p }) else p);
}

// ---------------------------------------------------------------------------
// Tests

test "a copy has the files, and neither what's left out nor what a link leads to" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    for ([_][]const u8{ "data\\home\\AppData\\Local\\Temp", "data\\home\\AppData\\Roaming\\app", "data\\cache", "data\\registry", "docs" }) |d| try tmp.dir.createDirPath(io, d);
    try tmp.dir.writeFile(io, .{ .sub_path = "data\\home\\AppData\\Roaming\\app\\settings.ini", .data = "12345" });
    try tmp.dir.writeFile(io, .{ .sub_path = "data\\registry\\user.dat", .data = "hive" });
    try tmp.dir.writeFile(io, .{ .sub_path = "data\\home\\AppData\\Local\\Temp\\t.tmp", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "data\\cache\\big.bin", .data = "x" });
    // Another's Temp, deeper, is the app's own business.
    try tmp.dir.createDirPath(io, "data\\home\\AppData\\Roaming\\app\\cache");
    try tmp.dir.writeFile(io, .{ .sub_path = "data\\home\\AppData\\Roaming\\app\\cache\\kept.bin", .data = "xy" });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs\\mine.txt", .data = "x" });
    const data = try std.fs.path.join(arena, &.{ root, "data" });
    const docs = try std.fs.path.join(arena, &.{ root, "docs" });
    _ = try junction.link(io, arena, try std.fs.path.join(arena, &.{ data, "home", "Documents" }), docs);

    const to = try std.fs.path.join(arena, &.{ root, "copy" });
    var walk: Walk = .{ .io = io, .arena = arena, .left_out = &left_out };
    try walk.run(data, to);
    try std.testing.expectEqual(3, walk.tally.files);
    try std.testing.expectEqual(11, walk.tally.bytes);
    try std.testing.expectEqual(1, walk.links);
    try std.testing.expectEqualStrings("12345", try tmp.dir.readFileAlloc(io, "copy\\home\\AppData\\Roaming\\app\\settings.ini", arena, .limited(64)));
    try std.testing.expectEqualStrings("hive", try tmp.dir.readFileAlloc(io, "copy\\registry\\user.dat", arena, .limited(64)));
    try std.testing.expect(try Store.exists(io, try std.fs.path.join(arena, &.{ to, "home", "AppData", "Roaming", "app", "cache", "kept.bin" })));
    for ([_][]const u8{ "home\\AppData\\Local\\Temp", "cache", "home\\Documents" }) |gone|
        try std.testing.expect(!try Store.exists(io, try std.fs.path.join(arena, &.{ to, gone })));
    // The folder the link leads to is as it was.
    try std.testing.expect(try Store.exists(io, try std.fs.path.join(arena, &.{ docs, "mine.txt" })));

    // Counting alone finds the same, and with nothing left out, all of it.
    var count: Walk = .{ .io = io, .arena = arena, .left_out = &.{} };
    try count.run(data, null);
    try std.testing.expectEqual(5, count.tally.files);

    // A copy over files that are there stops, and says why.
    var again: Walk = .{ .io = io, .arena = arena, .left_out = &left_out };
    try std.testing.expectError(error.Stopped, again.run(data, to));
    try std.testing.expect(again.why.len > 0);
}

test "many files are copied by several threads, each once, in batches" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    // More than a batch, in two folders.
    const count = Walk.batch_size + 300;
    try tmp.dir.createDirPath(io, "data\\a");
    try tmp.dir.createDirPath(io, "data\\b");
    for (0..count) |i| {
        const name = try std.fmt.allocPrint(arena, "data\\{s}\\f{d}.txt", .{ if (i % 2 == 0) "a" else "b", i });
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = try std.fmt.allocPrint(arena, "{d}", .{i}) });
    }
    var walk: Walk = .{ .io = io, .arena = arena, .left_out = &.{} };
    try walk.run(try std.fs.path.join(arena, &.{ root, "data" }), try std.fs.path.join(arena, &.{ root, "copy" }));
    try std.testing.expectEqual(count, walk.tally.files);
    for ([_]usize{ 0, 1, 777, count - 1 }) |i| {
        const name = try std.fmt.allocPrint(arena, "copy\\{s}\\f{d}.txt", .{ if (i % 2 == 0) "a" else "b", i });
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{d}", .{i}), try tmp.dir.readFileAlloc(io, name, arena, .limited(64)));
    }
    var counted: Walk = .{ .io = io, .arena = arena, .left_out = &.{} };
    try counted.run(try std.fs.path.join(arena, &.{ root, "copy" }), null);
    try std.testing.expectEqual(count, counted.tally.files);
    try std.testing.expectEqual(walk.tally.bytes, counted.tally.bytes);
}
