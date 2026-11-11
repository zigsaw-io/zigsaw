//! A kept build: the build root of a recipe's last build, left in the store
//! so that the next one picks up where it stopped, at the first module that
//! changed or failed, instead of at the first.
//!
//! In the store, cache\work\<key>\ (the key is of the recipe's path and the
//! app's id, so two checkouts don't share one) holds:
//!
//!   zigsaw-build-root\  the build root, mapped to B: where it is
//!   state               the modules built there, with which inputs, and how
//!                       many commands of the one that stopped ran
//!   prefix.journal      what each step did to B:\prefix: a step is a command
//!                       that ran to its end, or a module without commands
//!   saved\<n>\          the files step n put into the prefix, as hard links
//!   files\<module>.txt  the files a project's module was last given
//!
//! and cache\work\<key>.lock is held by the build that uses it.
//!
//! Each module has two keys, both chained on the module before:
//!
//! - its work key: zigsaw, the build's tools, and the module as the recipe
//!   has it, with its local files. While it's the same, the module's
//!   B:\src\<module> may be built in again, as makepkg builds in src/.
//! - its done key: the work key and a project's own files. While it's the
//!   same, and the modules before it were skipped too, the module is skipped.
//!
//! A module that stopped in its commands, and whose work key is the same,
//! goes on at the command that didn't finish, in its directory as that
//! command left it: the commands before it aren't run again, as a patch
//! applied twice fails, and a build tool that sees its inputs touched does
//! more than go on.
//!
//! Either way the prefix has to be as the last step taken left it. The
//! journal says what that was: every file's size and modification time. A
//! file a later step added is deleted; one it replaced or deleted comes back from
//! its hard link in saved\, which still holds the old bytes when the file was
//! replaced by a new one (a rename, as `sed -i` and meson's tools do). When a
//! tool wrote into the file itself, the link has the new bytes too, and its
//! time says so: then the build starts afresh.
//!
//! What a module writes outside the prefix and its own directory isn't
//! tracked: `zigsaw build --clean` starts afresh.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = @import("Store.zig");
const drive = @import("drive.zig");
const win32 = @import("win32.zig");
const repeat = @import("testing.zig").repeat;

pub const Keys = struct {
    work: [64]u8,
    done: [64]u8,
};

/// What a module's keys are made of, besides the modules before it.
pub const Inputs = struct {
    /// The module as the recipe has it.
    definition: []const u8,
    /// The hashes of its local files, in order.
    local: []const []const u8 = &.{},
    /// The hashes of a project's own files among its sources, in order.
    projects: []const []const u8 = &.{},
};

/// The keys of a recipe's modules. `base` is what every module depends on:
/// zigsaw, the build's tools, the app's id.
pub fn chain(arena: Allocator, base: []const u8, modules: []const Inputs) ![]Keys {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    const keys = try arena.alloc(Keys, modules.len);
    var work: [64]u8 = undefined;
    var done: [64]u8 = undefined;
    for (modules, keys, 0..) |m, *k, i| {
        var h: Sha256 = .init(.{});
        h.update("zigsaw module work\n");
        if (i == 0) part(&h, base) else part(&h, &work);
        part(&h, m.definition);
        for (m.local) |hash| part(&h, hash);
        work = std.fmt.bytesToHex(h.finalResult(), .lower);

        h = .init(.{});
        h.update("zigsaw module done\n");
        if (i > 0) part(&h, &done);
        part(&h, &work);
        for (m.projects) |hash| part(&h, hash);
        done = std.fmt.bytesToHex(h.finalResult(), .lower);
        k.* = .{ .work = work, .done = done };
    }
    return keys;
}

/// Length first, so that two parts never read as one.
fn part(h: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, bytes.len, .little);
    h.update(&len);
    h.update(bytes);
}

pub const Status = enum {
    /// Built, and the modules before it too.
    done,
    /// Its commands began, and didn't finish, or failed.
    started,
    /// Its work directory is from an earlier build, of other files.
    kept,
};

pub const Record = struct {
    status: Status,
    keys: Keys,
    /// How many of its commands have run, each to its end.
    commands: usize = 0,
    /// How many steps the journal had after the last of them.
    steps: usize = 0,
    name: []const u8,
};

/// What a build can take from the kept one.
pub const Plan = struct {
    /// How many modules, from the first, are skipped.
    done: usize = 0,
    /// For each module, whether it's built in the directory its last build
    /// left.
    continues: []const bool = &.{},
    /// The journal's steps up to the last skipped module's.
    steps: usize = 0,
    /// Where the first module that isn't skipped stopped, if its commands
    /// had begun: it can go on at the command that didn't finish.
    step: ?Step = null,

    pub const Step = struct {
        /// The commands that ran to their end.
        commands: usize,
        /// The journal's steps up to the last of them.
        steps: usize,
    };

    pub fn resumes(p: Plan) bool {
        if (p.done > 0) return true;
        for (p.continues) |c| if (c) return true;
        return false;
    }
};

pub const root_name = drive.dir_prefix ++ "root";

const state_header = "zigsaw kept build 1";
const journal_header = "zigsaw prefix journal 1";

pub const Kept = struct {
    io: Io,
    /// cache\work\<key>.
    dir: []const u8,
    /// The build root in it.
    root: []const u8,
    lock: Store.Lock,
    records: []Record = &.{},
    /// How many steps the journal has: one for each command that ran to its
    /// end, and one for a module without commands. Known once the build
    /// has gone back (`goBack`) or started afresh (`reset`).
    steps: usize = 0,
    /// Whether there was anything of an earlier build's when it was opened.
    found: bool = false,

    /// Takes the kept build at `dir` for this build, or returns null if
    /// another build has it. One whose state can't be read, as one a zigsaw
    /// before 0.88 left, is deleted.
    pub fn open(io: Io, arena: Allocator, dir: []const u8) !?Kept {
        try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(dir).?);
        const lock = try Store.tryLock(io, try Store.lockPathFor(arena, dir), .exclusive) orelse return null;
        errdefer lock.release(io);
        var k: Kept = .{ .io = io, .dir = dir, .root = try std.fs.path.join(arena, &.{ dir, root_name }), .lock = lock };
        if (!try Store.exists(io, dir)) return k;
        const state = Io.Dir.cwd().readFileAlloc(io, try k.path(arena, "state"), arena, .limited(1 << 24)) catch "";
        if (parseState(arena, state)) |records| {
            k.records = records;
            k.found = true;
        } else |_| try k.reset(arena);
        return k;
    }

    pub fn release(k: Kept) void {
        k.lock.release(k.io);
    }

    /// Deletes everything kept, so the build starts afresh.
    pub fn reset(k: *Kept, arena: Allocator) !void {
        if (try Store.exists(k.io, k.dir)) try Store.deleteTree(k.io, arena, k.dir);
        k.records = &.{};
        k.steps = 0;
    }

    fn path(k: Kept, arena: Allocator, name: []const u8) ![]u8 {
        return std.fs.path.join(arena, &.{ k.dir, name });
    }

    /// What a build of these modules, with these keys, can take. The
    /// modules from `afresh` on take nothing.
    pub fn plan(k: Kept, arena: Allocator, names: []const []const u8, keys: []const Keys, afresh: usize) !Plan {
        var done: usize = 0;
        while (done < @min(names.len, afresh) and done < k.records.len) : (done += 1) {
            const r = k.records[done];
            if (r.status != .done or !std.ascii.eqlIgnoreCase(r.name, names[done]) or !std.mem.eql(u8, &r.keys.done, &keys[done].done)) break;
        }
        const continues = try arena.alloc(bool, names.len);
        for (continues, names, keys, 0..) |*c, name, key, i| {
            c.* = if (i < done or i >= afresh) false else if (k.record(name)) |r| std.mem.eql(u8, &r.keys.work, &key.work) else false;
        }
        var p: Plan = .{ .done = done, .continues = continues, .steps = if (done > 0) k.records[done - 1].steps else 0 };
        if (done < names.len and continues[done]) {
            const r = k.record(names[done]).?;
            if (r.status == .started and r.steps >= p.steps) p.step = .{ .commands = r.commands, .steps = r.steps };
        }
        return p;
    }

    fn record(k: Kept, name: []const u8) ?Record {
        for (k.records) |r| if (std.ascii.eqlIgnoreCase(r.name, name)) return r;
        return null;
    }

    /// Makes the kept build what `p` takes from it: the prefix as the last
    /// skipped module left it, or the last command that finished, if the
    /// next module goes on from there; and only the work directories that
    /// are built in again. Returns why it can't, if it can't: the build
    /// then starts afresh.
    pub fn goBack(k: *Kept, arena: Allocator, p: Plan, names: []const []const u8) !?[]const u8 {
        const io = k.io;
        const steps = if (p.step) |s| s.steps else p.steps;
        if (try k.prefixBack(arena, steps)) |why| return why;
        k.steps = steps;

        const src = try std.fs.path.join(arena, &.{ k.root, "src" });
        for (try listNames(io, arena, src)) |name| {
            const stays = for (names, 0..) |n, i| {
                if (std.ascii.eqlIgnoreCase(n, name)) break i < p.done or p.continues[i];
            } else false;
            if (!stays) try Store.deleteTree(io, arena, try std.fs.path.join(arena, &.{ src, name }));
        }

        var records: std.ArrayList(Record) = .empty;
        try records.appendSlice(arena, k.records[0..p.done]);
        for (names[p.done..], p.continues[p.done..], p.done..) |name, continues, i| {
            if (!continues) continue;
            var r = k.record(name).?;
            // The one that goes on at a command stays as it stopped.
            if (!(i == p.done and p.step != null)) r.status = .kept;
            try records.append(arena, r);
        }
        k.records = records.items;
        try k.writeState(arena);
        return null;
    }

    /// Records that module `i` has its sources, and its commands are about
    /// to run.
    pub fn started(k: *Kept, arena: Allocator, i: usize, name: []const u8, keys: Keys) !void {
        try k.set(arena, i, .{ .status = .started, .keys = keys, .steps = k.steps, .name = name });
    }

    /// Records what module `i` did to the prefix since the step before, and
    /// that `commands` of its commands have run.
    pub fn stepped(k: *Kept, arena: Allocator, i: usize, name: []const u8, keys: Keys, commands: usize) !void {
        try k.journal(arena);
        k.steps += 1;
        try k.set(arena, i, .{ .status = .started, .keys = keys, .commands = commands, .steps = k.steps, .name = name });
    }

    /// Records that module `i` is built.
    pub fn finished(k: *Kept, arena: Allocator, i: usize, name: []const u8, keys: Keys, commands: usize) !void {
        try k.set(arena, i, .{ .status = .done, .keys = keys, .commands = commands, .steps = k.steps, .name = name });
    }

    /// Puts `r` at `i`, after the modules built before it. The work
    /// directories of other modules stay on record, though not as built.
    fn set(k: *Kept, arena: Allocator, i: usize, r: Record) !void {
        var records: std.ArrayList(Record) = .empty;
        for (k.records, 0..) |old, at| {
            if (std.ascii.eqlIgnoreCase(old.name, r.name)) continue;
            if (at < i and old.status == .done) {
                try records.append(arena, old);
                continue;
            }
            var other = old;
            other.status = .kept;
            try records.append(arena, other);
        }
        const before = @min(i, records.items.len);
        try records.insert(arena, before, r);
        k.records = records.items;
        try k.writeState(arena);
    }

    fn writeState(k: Kept, arena: Allocator) !void {
        var out: Io.Writer.Allocating = .init(arena);
        try out.writer.print("{s}\n", .{state_header});
        for (k.records) |r| try out.writer.print("{t} {s} {s} {d} {d} {s}\n", .{ r.status, r.keys.work, r.keys.done, r.commands, r.steps, r.name });
        try Io.Dir.cwd().createDirPath(k.io, k.dir);
        try replaceFile(k.io, arena, try k.path(arena, "state"), out.written());
    }

    /// The files a project's module was given by its last build, for
    /// Tree.syncFiles.
    pub fn files(k: Kept, arena: Allocator, module: []const u8) ![]const []const u8 {
        const p = try k.filesPath(arena, module);
        const bytes = Io.Dir.cwd().readFileAlloc(k.io, p, arena, .limited(1 << 28)) catch return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| if (line.len > 0) try out.append(arena, line);
        return out.items;
    }

    pub fn setFiles(k: Kept, arena: Allocator, module: []const u8, paths: []const []const u8) !void {
        var out: Io.Writer.Allocating = .init(arena);
        for (paths) |p| try out.writer.print("{s}\n", .{p});
        const p = try k.filesPath(arena, module);
        try Io.Dir.cwd().createDirPath(k.io, std.fs.path.dirname(p).?);
        try replaceFile(k.io, arena, p, out.written());
    }

    fn filesPath(k: Kept, arena: Allocator, module: []const u8) ![]u8 {
        return std.fs.path.join(arena, &.{ k.dir, "files", try std.fmt.allocPrint(arena, "{s}.txt", .{module}) });
    }

    // -----------------------------------------------------------------------
    // The prefix

    fn prefixDir(k: Kept, arena: Allocator) ![]u8 {
        return std.fs.path.join(arena, &.{ k.root, "prefix" });
    }

    fn savedPath(k: Kept, arena: Allocator, section: usize, rel: []const u8) ![]u8 {
        const native = try arena.dupe(u8, rel);
        std.mem.replaceScalar(u8, native, '/', '\\');
        return std.fs.path.join(arena, &.{ k.dir, "saved", try std.fmt.allocPrint(arena, "{d}", .{section}), native });
    }

    fn prefixPath(k: Kept, arena: Allocator, rel: []const u8) ![]u8 {
        const native = try arena.dupe(u8, rel);
        std.mem.replaceScalar(u8, native, '/', '\\');
        return std.fs.path.join(arena, &.{ k.root, "prefix", native });
    }

    fn readJournal(k: Kept, arena: Allocator) ![]const u8 {
        return Io.Dir.cwd().readFileAlloc(k.io, try k.path(arena, "prefix.journal"), arena, .limited(1 << 30)) catch |err| switch (err) {
            error.FileNotFound => journal_header ++ "\n",
            else => |e| e,
        };
    }

    /// Adds a step to the journal: what's in the prefix now that wasn't at
    /// the step before, and what no longer is.
    fn journal(k: Kept, arena: Allocator) !void {
        const io = k.io;
        const i = k.steps;
        const bytes = try k.readJournal(arena);
        const before = try replay(arena, bytes, i);
        if (before.sections < i) return error.JournalShort;
        const now = try walk(io, arena, try k.prefixDir(arena));

        const saved = try std.fs.path.join(arena, &.{ k.dir, "saved", try std.fmt.allocPrint(arena, "{d}", .{i}) });
        if (try Store.exists(io, saved)) try Store.deleteTree(io, arena, saved);

        var out: Io.Writer.Allocating = .init(arena);
        try out.writer.writeAll(bytes[0..before.end]);
        try out.writer.print("= {d}\n", .{i});
        for (now.keys(), now.values()) |key, e| {
            if (before.entries.get(key)) |old| if (old.same(e)) continue;
            switch (e.kind) {
                .dir => try out.writer.print("d {s}\n", .{e.path}),
                .other => try out.writer.print("? {s}\n", .{e.path}),
                .file => {
                    try out.writer.print("+ {d} {d} {s}\n", .{ e.size, e.mtime, e.path });
                    // Without the link, the file can't come back if a later
                    // module replaces it; the build then starts afresh.
                    const to = try k.savedPath(arena, i, e.path);
                    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(to).?);
                    _ = try hardLink(arena, try k.prefixPath(arena, e.path), to);
                },
            }
        }
        for (before.entries.keys(), before.entries.values()) |key, old| {
            if (!now.contains(key)) try out.writer.print("- {s}\n", .{old.path});
        }
        try Io.Dir.cwd().createDirPath(io, k.dir);
        try replaceFile(io, arena, try k.path(arena, "prefix.journal"), out.written());
    }

    /// Makes the prefix what it was after `n` steps. Returns why it can't,
    /// if it can't, having changed nothing.
    fn prefixBack(k: Kept, arena: Allocator, n: usize) !?[]const u8 {
        const io = k.io;
        const bytes = try k.readJournal(arena);
        const then = replay(arena, bytes, n) catch return "its record of the prefix can't be read";
        if (then.sections < n) return "its record of the prefix ends before what it built";
        const prefix = try k.prefixDir(arena);
        const now = try walk(io, arena, prefix);

        // First what has to come back, and whether it can.
        var back: std.ArrayList(Entry) = .empty;
        for (then.entries.keys(), then.entries.values()) |key, want| switch (want.kind) {
            .dir => {},
            .other => return try std.fmt.allocPrint(arena, "{s} in the prefix is a link", .{want.path}),
            .file => {
                if (now.get(key)) |have| if (have.same(want)) continue;
                const stat = Io.Dir.cwd().statFile(io, try k.savedPath(arena, want.section, want.path), .{}) catch
                    return try std.fmt.allocPrint(arena, "a later module changed {s} in the prefix, and its copy is gone", .{want.path});
                if (stat.kind != .file or stat.size != want.size or stat.mtime.nanoseconds != want.mtime)
                    return try std.fmt.allocPrint(arena, "a later module wrote into {s} in the prefix", .{want.path});
                try back.append(arena, want);
            },
        };

        // Then what a later module left: its files, then its directories,
        // deepest first.
        var dirs: std.ArrayList([]const u8) = .empty;
        for (now.keys(), now.values()) |key, have| {
            const want = then.entries.get(key);
            switch (have.kind) {
                .dir => if (want == null or want.?.kind != .dir) try dirs.append(arena, have.path),
                .file, .other => if (want == null or !want.?.same(have)) try deleteEntry(io, arena, try k.prefixPath(arena, have.path)),
            }
        }
        std.mem.sort([]const u8, dirs.items, {}, struct {
            fn longerFirst(_: void, a: []const u8, b: []const u8) bool {
                return a.len > b.len;
            }
        }.longerFirst);
        for (dirs.items) |d| try Store.deleteTree(io, arena, try k.prefixPath(arena, d));

        for (then.entries.keys(), then.entries.values()) |key, want| {
            if (want.kind == .dir and (now.get(key) orelse Entry{ .path = "", .kind = .other }).kind != .dir)
                try Io.Dir.cwd().createDirPath(io, try k.prefixPath(arena, want.path));
        }
        for (back.items) |want| {
            const to = try k.prefixPath(arena, want.path);
            try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(to).?);
            if (!try hardLink(arena, try k.savedPath(arena, want.section, want.path), to)) return error.LinkFailed;
        }

        // And the record of what those modules did.
        if (then.end < bytes.len) try replaceFile(io, arena, try k.path(arena, "prefix.journal"), bytes[0..then.end]);
        const saved = try k.path(arena, "saved");
        for (try listNames(io, arena, saved)) |name| {
            const section = std.fmt.parseInt(usize, name, 10) catch continue;
            if (section >= n) try Store.deleteTree(io, arena, try std.fs.path.join(arena, &.{ saved, name }));
        }
        return null;
    }
};

const Entry = struct {
    /// '/'-separated, from the prefix.
    path: []const u8,
    kind: enum { file, dir, other },
    size: u64 = 0,
    mtime: i96 = 0,
    /// The step that put it there.
    section: usize = 0,

    fn same(a: Entry, b: Entry) bool {
        return a.kind == b.kind and a.size == b.size and a.mtime == b.mtime;
    }
};

/// Keyed by lowercased path, as Tree's nodes are.
const Entries = std.StringArrayHashMapUnmanaged(Entry);

const Replayed = struct {
    entries: Entries,
    /// How many of the sections asked for the journal has.
    sections: usize,
    /// Where they end in it.
    end: usize,
};

/// The prefix after the journal's first `upto` sections.
fn replay(arena: Allocator, bytes: []const u8, upto: usize) !Replayed {
    var entries: Entries = .empty;
    var sections: usize = 0;
    var at: usize = 0;
    var first = true;
    while (at < bytes.len) {
        const nl = std.mem.indexOfScalarPos(u8, bytes, at, '\n') orelse return error.BadJournal;
        const line = bytes[at..nl];
        if (first) {
            if (!std.mem.eql(u8, line, journal_header)) return error.BadJournal;
            first = false;
        } else if (line.len < 3 or line[1] != ' ' or (sections == 0 and line[0] != '=')) {
            return error.BadJournal;
        } else switch (line[0]) {
            '=' => {
                if (sections == upto) break;
                if (try std.fmt.parseInt(usize, line[2..], 10) != sections) return error.BadJournal;
                sections += 1;
            },
            'd', '?' => try entries.put(arena, try std.ascii.allocLowerString(arena, line[2..]), .{
                .path = line[2..],
                .kind = if (line[0] == 'd') .dir else .other,
                .section = sections - 1,
            }),
            '+' => {
                var fields = std.mem.splitScalar(u8, line[2..], ' ');
                const size = try std.fmt.parseInt(u64, fields.first(), 10);
                const mtime = try std.fmt.parseInt(i96, fields.next() orelse return error.BadJournal, 10);
                const rel = fields.rest();
                if (rel.len == 0) return error.BadJournal;
                try entries.put(arena, try std.ascii.allocLowerString(arena, rel), .{ .path = rel, .kind = .file, .size = size, .mtime = mtime, .section = sections - 1 });
            },
            '-' => _ = entries.orderedRemove(try std.ascii.allocLowerString(arena, line[2..])),
            else => return error.BadJournal,
        }
        at = nl + 1;
    }
    if (first) return error.BadJournal;
    return .{ .entries = entries, .sections = sections, .end = at };
}

/// What's below `dir_path` now.
fn walk(io: Io, arena: Allocator, dir_path: []const u8) !Entries {
    var entries: Entries = .empty;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return entries,
        else => |e| return e,
    };
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |found| {
        const rel = try arena.dupe(u8, found.path);
        std.mem.replaceScalar(u8, rel, '\\', '/');
        var e: Entry = .{ .path = rel, .kind = .other };
        switch (found.kind) {
            .directory => e.kind = .dir,
            .file => {
                const stat = try found.dir.statFile(io, found.basename, .{});
                e.kind = .file;
                e.size = stat.size;
                e.mtime = stat.mtime.nanoseconds;
            },
            else => {},
        }
        try entries.put(arena, try std.ascii.allocLowerString(arena, rel), e);
    }
    return entries;
}

fn parseState(arena: Allocator, bytes: []const u8) ![]Record {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (!std.mem.eql(u8, lines.first(), state_header)) return error.BadState;
    var records: std.ArrayList(Record) = .empty;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ' ');
        const status = std.meta.stringToEnum(Status, fields.first()) orelse return error.BadState;
        const work = fields.next() orelse return error.BadState;
        const done = fields.next() orelse return error.BadState;
        const commands = std.fmt.parseInt(usize, fields.next() orelse return error.BadState, 10) catch return error.BadState;
        const steps = std.fmt.parseInt(usize, fields.next() orelse return error.BadState, 10) catch return error.BadState;
        const name = fields.rest();
        if (work.len != 64 or done.len != 64 or name.len == 0) return error.BadState;
        try records.append(arena, .{ .status = status, .keys = .{ .work = work[0..64].*, .done = done[0..64].* }, .commands = commands, .steps = steps, .name = name });
    }
    return records.items;
}

/// The names in a directory; none if it isn't there.
fn listNames(io: Io, arena: Allocator, dir_path: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return names.items,
        else => |e| return e,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| try names.append(arena, try arena.dupe(u8, entry.name));
    return names.items;
}

/// Writes `bytes` beside `p`, then over it, so a build that's stopped leaves
/// the old file or the new one.
fn replaceFile(io: Io, arena: Allocator, p: []const u8, bytes: []const u8) !void {
    const tmp = try std.fmt.allocPrint(arena, "{s}.new", .{p});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = bytes });
    try Io.Dir.rename(.cwd(), tmp, .cwd(), p, io);
}

/// Deletes a file, or a link itself.
fn deleteEntry(io: Io, arena: Allocator, p: []const u8) !void {
    Io.Dir.cwd().deleteFile(io, p) catch |err| switch (err) {
        error.FileNotFound => {},
        else => if (win32.RemoveDirectoryW(try win32.wide(arena, p)) == 0) return err,
    };
}

/// Makes `new` another name of the file `existing`. False if Windows won't,
/// as on a volume without hard links.
fn hardLink(arena: Allocator, existing: []const u8, new: []const u8) !bool {
    return win32.CreateHardLinkW(try win32.wide(arena, try extended(arena, new)), try win32.wide(arena, try extended(arena, existing)), null) != 0;
}

/// An absolute path as Windows takes it past 260 characters.
fn extended(arena: Allocator, p: []const u8) ![]const u8 {
    if (p.len < 3 or p[1] != ':' or std.mem.startsWith(u8, p, "\\\\")) return p;
    const out = try std.fmt.allocPrint(arena, "\\\\?\\{s}", .{p});
    std.mem.replaceScalar(u8, out, '/', '\\');
    return out;
}

// ---------------------------------------------------------------------------
// Tests

fn testKeys(comptime work: []const u8, comptime done: []const u8) Keys {
    return .{ .work = repeat(work, 64).*, .done = repeat(done, 64).* };
}

test "module keys: chained, and a project's files only change the done key" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a: Inputs = .{ .definition = "a" };
    const b: Inputs = .{ .definition = "b", .local = &.{"patch"} };
    const c: Inputs = .{ .definition = "c", .projects = &.{"files 1"} };
    const first = try chain(arena, "base", &.{ a, b, c });

    // The last module's project changed.
    var again = try chain(arena, "base", &.{ a, b, .{ .definition = "c", .projects = &.{"files 2"} } });
    try std.testing.expectEqualStrings(&first[1].done, &again[1].done);
    try std.testing.expectEqualStrings(&first[2].work, &again[2].work);
    try std.testing.expect(!std.mem.eql(u8, &first[2].done, &again[2].done));

    // The middle one's local file changed: it and what follows start again.
    again = try chain(arena, "base", &.{ a, .{ .definition = "b", .local = &.{"patch 2"} }, c });
    try std.testing.expectEqualStrings(&first[0].work, &again[0].work);
    try std.testing.expectEqualStrings(&first[0].done, &again[0].done);
    try std.testing.expect(!std.mem.eql(u8, &first[1].work, &again[1].work));
    try std.testing.expect(!std.mem.eql(u8, &first[2].work, &again[2].work));
    try std.testing.expect(!std.mem.eql(u8, &first[2].done, &again[2].done));

    // Another zigsaw, or other tools: everything does.
    again = try chain(arena, "base 2", &.{ a, b, c });
    try std.testing.expect(!std.mem.eql(u8, &first[0].work, &again[0].work));

    // A part that moved from one field to the next isn't the same module.
    const split = try chain(arena, "base", &.{.{ .definition = "ab" }});
    const joined = try chain(arena, "base", &.{.{ .definition = "a", .local = &.{"b"} }});
    try std.testing.expect(!std.mem.eql(u8, &split[0].work, &joined[0].work));
}

fn testKept(io: Io, arena: Allocator, tmp: std.testing.TmpDir) !Kept {
    const dir = try std.fs.path.join(arena, &.{ try tmp.dir.realPathFileAlloc(io, ".", arena), "work", "0123456789abcdef" });
    return (try Kept.open(io, arena, dir)).?;
}

test "a kept build's state: what's skipped, what's continued" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const names: []const []const u8 = &.{ "a", "b", "c" };
    const keys: []const Keys = &.{ testKeys("1", "a"), testKeys("2", "b"), testKeys("3", "c") };
    var k = try testKept(io, arena, tmp);
    try std.testing.expect(!k.found);
    // Another build can't have it meanwhile.
    try std.testing.expect((try Kept.open(io, arena, k.dir)) == null);

    // Nothing kept: nothing taken.
    var p = try k.plan(arena, names, keys, names.len);
    try std.testing.expect(!p.resumes());

    // a and b built; c's first command ran, and its second failed.
    for (names, keys, 0..) |name, key, i| {
        try k.started(arena, i, name, key);
        if (i < 2) {
            try k.stepped(arena, i, name, key, 1);
            try k.finished(arena, i, name, key, 1);
        } else try k.stepped(arena, i, name, key, 1);
    }
    k.release();
    k = try testKept(io, arena, tmp);
    defer k.release();
    try std.testing.expect(k.found);
    try std.testing.expectEqual(3, k.records.len);
    p = try k.plan(arena, names, keys, names.len);
    try std.testing.expectEqual(2, p.done);
    try std.testing.expectEqualSlices(bool, &.{ false, false, true }, p.continues);
    // c goes on at its second command, after the three steps so far.
    try std.testing.expectEqual(2, p.steps);
    try std.testing.expectEqual(1, p.step.?.commands);
    try std.testing.expectEqual(3, p.step.?.steps);

    // b's project changed: b and c are built again where they were, each
    // from its first command.
    p = try k.plan(arena, names, &.{ keys[0], testKeys("2", "x"), testKeys("3", "y") }, names.len);
    try std.testing.expectEqual(1, p.done);
    try std.testing.expectEqualSlices(bool, &.{ false, true, true }, p.continues);
    try std.testing.expectEqual(1, p.steps);
    try std.testing.expect(p.step == null);

    // b and what follows start afresh, as with --clean=b.
    p = try k.plan(arena, names, keys, 1);
    try std.testing.expectEqual(1, p.done);
    try std.testing.expectEqualSlices(bool, &.{ false, false, false }, p.continues);
    try std.testing.expect(p.step == null);

    // b itself changed: c's work key is another too.
    p = try k.plan(arena, names, &.{ keys[0], testKeys("8", "x"), testKeys("9", "y") }, names.len);
    try std.testing.expectEqual(1, p.done);
    try std.testing.expectEqualSlices(bool, &.{ false, false, false }, p.continues);

    // A module put before them: none is skipped, and those that are as they
    // were are continued.
    p = try k.plan(arena, &.{ "new", "a", "b" }, &.{ testKeys("0", "n"), keys[0], keys[1] }, 3);
    try std.testing.expectEqual(0, p.done);
    try std.testing.expectEqualSlices(bool, &.{ false, true, true }, p.continues);

    // Starting b again: a is still built, c's directory only kept.
    try k.started(arena, 1, "b", testKeys("2", "x"));
    try std.testing.expectEqual(Status.done, k.records[0].status);
    try std.testing.expectEqual(Status.started, k.records[1].status);
    try std.testing.expectEqualStrings("c", k.records[2].name);
    try std.testing.expectEqual(Status.kept, k.records[2].status);

    // State a zigsaw can't read, as an old layout's: gone.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try k.path(arena, "state"), .data = "zigsaw work 1 abc\n" });
    k.release();
    k = try testKept(io, arena, tmp);
    try std.testing.expect(!k.found);
    try std.testing.expect(!try Store.exists(io, k.dir));
}

fn testWrite(io: Io, arena: Allocator, k: Kept, rel: []const u8, data: []const u8) !void {
    const p = try k.prefixPath(arena, rel);
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(p).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = data });
}

/// As a tool that writes a new file and renames it over the old one.
fn testReplace(io: Io, arena: Allocator, k: Kept, rel: []const u8, data: []const u8) !void {
    try testWrite(io, arena, k, "replacing.tmp", data);
    try Io.Dir.rename(.cwd(), try k.prefixPath(arena, "replacing.tmp"), .cwd(), try k.prefixPath(arena, rel), io);
}

fn testRead(io: Io, arena: Allocator, k: Kept, rel: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, try k.prefixPath(arena, rel), arena, .limited(1 << 20)) catch "(none)";
}

test "the prefix goes back to how a module left it" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const names: []const []const u8 = &.{ "a", "b", "c" };
    const keys: []const Keys = &.{ testKeys("1", "a"), testKeys("2", "b"), testKeys("3", "c") };
    var k = try testKept(io, arena, tmp);
    defer k.release();

    // a: two files and an empty directory.
    try testWrite(io, arena, k, "bin/a.exe", "a's program");
    try testWrite(io, arena, k, "share/schemas.compiled", "a");
    try Io.Dir.cwd().createDirPath(io, try k.prefixPath(arena, "var/empty"));
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ k.root, "src", "a" }));
    try k.started(arena, 0, "a", keys[0]);
    try k.stepped(arena, 0, "a", keys[0], 1);
    try k.finished(arena, 0, "a", keys[0], 1);

    // b: replaces a's file by a new one, deletes another and the directory,
    // adds its own.
    try testReplace(io, arena, k, "share/schemas.compiled", "a and b");
    try Io.Dir.cwd().deleteFile(io, try k.prefixPath(arena, "bin/a.exe"));
    try Store.deleteTree(io, arena, try k.prefixPath(arena, "var"));
    try testWrite(io, arena, k, "lib/b/b.dll", "b's library");
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ k.root, "src", "b" }));
    try k.started(arena, 1, "b", keys[1]);
    try k.stepped(arena, 1, "b", keys[1], 1);
    try k.finished(arena, 1, "b", keys[1], 1);

    // c: replaces it again, and fails.
    try testReplace(io, arena, k, "share/schemas.compiled", "a, b and c");
    try testWrite(io, arena, k, "bin/c.exe", "half of c");
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ k.root, "src", "c" }));
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ k.root, "src", "gone" }));
    try k.started(arena, 2, "c", keys[2]);

    // Built again as it is: back to b's, with c's directory.
    var p = try k.plan(arena, names, keys, names.len);
    try std.testing.expectEqual(2, p.done);
    try std.testing.expect((try k.goBack(arena, p, names)) == null);
    try std.testing.expectEqualStrings("a and b", try testRead(io, arena, k, "share/schemas.compiled"));
    try std.testing.expectEqualStrings("b's library", try testRead(io, arena, k, "lib/b/b.dll"));
    try std.testing.expectEqualStrings("(none)", try testRead(io, arena, k, "bin/c.exe"));
    try std.testing.expectEqualStrings("(none)", try testRead(io, arena, k, "bin/a.exe"));
    try std.testing.expect(!try Store.exists(io, try k.prefixPath(arena, "var")));
    try std.testing.expect(try Store.exists(io, try std.fs.path.join(arena, &.{ k.root, "src", "c" })));
    try std.testing.expect(!try Store.exists(io, try std.fs.path.join(arena, &.{ k.root, "src", "gone" })));
    try std.testing.expectEqual(Status.started, k.records[2].status);
    try std.testing.expectEqual(2, k.steps);

    // c built, then b changed: back to a's, and b's and c's directories go.
    try testReplace(io, arena, k, "share/schemas.compiled", "a, b and c");
    try k.stepped(arena, 2, "c", keys[2], 1);
    try k.finished(arena, 2, "c", keys[2], 1);
    const changed: []const Keys = &.{ keys[0], testKeys("8", "x"), testKeys("9", "y") };
    p = try k.plan(arena, names, changed, names.len);
    try std.testing.expectEqual(1, p.done);
    try std.testing.expect((try k.goBack(arena, p, names)) == null);
    try std.testing.expectEqualStrings("a", try testRead(io, arena, k, "share/schemas.compiled"));
    try std.testing.expectEqualStrings("a's program", try testRead(io, arena, k, "bin/a.exe"));
    try std.testing.expect(try Store.exists(io, try k.prefixPath(arena, "var/empty")));
    try std.testing.expect(!try Store.exists(io, try k.prefixPath(arena, "lib")));
    try std.testing.expect(try Store.exists(io, try std.fs.path.join(arena, &.{ k.root, "src", "a" })));
    try std.testing.expect(!try Store.exists(io, try std.fs.path.join(arena, &.{ k.root, "src", "b" })));
    try std.testing.expectEqual(1, k.records.len);
    try std.testing.expect(!try Store.exists(io, try k.savedPath(arena, 1, "lib/b/b.dll")));

    // b again, as before: the journal takes its section again.
    try testReplace(io, arena, k, "share/schemas.compiled", "a and b");
    try k.started(arena, 1, "b", changed[1]);
    try k.stepped(arena, 1, "b", changed[1], 1);
    try k.finished(arena, 1, "b", changed[1], 1);
    // To nothing: an empty prefix.
    try std.testing.expect((try k.goBack(arena, .{ .done = 0, .continues = &.{ false, false, false } }, names)) == null);
    try std.testing.expectEqual(0, (try walk(io, arena, try k.prefixDir(arena))).count());
    try std.testing.expectEqual(0, k.records.len);
}

test "a module goes on at the command that stopped" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const names: []const []const u8 = &.{ "a", "b" };
    const keys: []const Keys = &.{ testKeys("1", "a"), testKeys("2", "b") };
    var k = try testKept(io, arena, tmp);
    defer k.release();
    try testWrite(io, arena, k, "bin/a.exe", "a's program");
    try k.started(arena, 0, "a", keys[0]);
    try k.stepped(arena, 0, "a", keys[0], 1);
    try k.finished(arena, 0, "a", keys[0], 1);
    // b's first command installs a file; its second replaces a's, leaves
    // half of another, and fails.
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ k.root, "src", "b" }));
    try k.started(arena, 1, "b", keys[1]);
    try testWrite(io, arena, k, "lib/b1.dll", "from b's first command");
    try k.stepped(arena, 1, "b", keys[1], 1);
    try testReplace(io, arena, k, "bin/a.exe", "b's wrapper around a");
    try testWrite(io, arena, k, "lib/half.dll", "half");

    var p = try k.plan(arena, names, keys, names.len);
    try std.testing.expectEqual(1, p.done);
    try std.testing.expectEqual(1, p.step.?.commands);
    try std.testing.expect((try k.goBack(arena, p, names)) == null);
    // What the first command did is there; what the second did isn't.
    try std.testing.expectEqualStrings("from b's first command", try testRead(io, arena, k, "lib/b1.dll"));
    try std.testing.expectEqualStrings("(none)", try testRead(io, arena, k, "lib/half.dll"));
    try std.testing.expectEqualStrings("a's program", try testRead(io, arena, k, "bin/a.exe"));
    try std.testing.expectEqual(Status.started, k.records[1].status);
    try std.testing.expectEqual(1, k.records[1].commands);
    try std.testing.expectEqual(2, k.steps);

    // The second command again, to its end this time.
    try testWrite(io, arena, k, "lib/b2.dll", "from b's second command");
    try k.stepped(arena, 1, "b", keys[1], 2);
    try k.finished(arena, 1, "b", keys[1], 2);
    p = try k.plan(arena, names, keys, names.len);
    try std.testing.expectEqual(2, p.done);
    try std.testing.expectEqual(3, p.steps);

    // Not from a command, if the build says so (a project's module): back
    // to a's, though b's directory stays.
    p = try k.plan(arena, names, &.{ keys[0], testKeys("2", "x") }, names.len);
    try std.testing.expect(p.step == null);
    try std.testing.expect((try k.goBack(arena, p, names)) == null);
    try std.testing.expectEqualStrings("(none)", try testRead(io, arena, k, "lib/b1.dll"));
    try std.testing.expect(try Store.exists(io, try std.fs.path.join(arena, &.{ k.root, "src", "b" })));
    try std.testing.expectEqual(Status.kept, k.records[1].status);
}

test "a file written into can't come back" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const names: []const []const u8 = &.{ "a", "b" };
    const keys: []const Keys = &.{ testKeys("1", "a"), testKeys("2", "b") };
    var k = try testKept(io, arena, tmp);
    defer k.release();
    try testWrite(io, arena, k, "etc/config", "a");
    try k.started(arena, 0, "a", keys[0]);
    try k.stepped(arena, 0, "a", keys[0], 1);
    try k.finished(arena, 0, "a", keys[0], 1);
    // b opens a's file and writes: its other name has the new bytes too.
    try testWrite(io, arena, k, "etc/config", "a, then more from b");
    try testWrite(io, arena, k, "etc/b", "b");
    try k.started(arena, 1, "b", keys[1]);

    const p = try k.plan(arena, names, keys, names.len);
    try std.testing.expectEqual(1, p.done);
    const why = (try k.goBack(arena, p, names)).?;
    try std.testing.expect(std.mem.indexOf(u8, why, "wrote into etc/config") != null);
    // Nothing was changed.
    try std.testing.expectEqualStrings("b", try testRead(io, arena, k, "etc/b"));
}
