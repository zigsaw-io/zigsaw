//! A kept build: the build root of a recipe's last build, left in the store
//! so that the next one picks up where it stopped, at the first module that
//! changed or failed, instead of at the first.
//!
//! The build root itself is tmp\zigsaw-build-<key> in the store (the key is
//! of the recipe's path and the app's id, so two checkouts don't share one),
//! mapped to B: where it is. That's where a build that keeps nothing builds
//! too, under a random name of the same length: tools that see through B: to
//! the real path (rustc does) then see one of the same shape, and GNU ld,
//! which orders a DLL's imports by the names of the files they came from,
//! orders them as in any other build of the recipe.
//!
//! Beside it, cache\work\<key>\ holds:
//!
//!   state               the modules built there, with which inputs, and how
//!                       many commands of the one that stopped ran
//!   prefix.journal      what each step did to B:\prefix: a step is a command
//!                       that ran to its end, or a module without commands
//!   saved\<n>\          the files step n put into the prefix, as hard links
//!   files\<module>.txt  the files a project's module was last given
//!
//! and cache\work\<key>.lock is held by the build that uses it.
//!
//! The record is written once the first module has its sources; a build
//! that stops before that, at a vendor step say, deletes the root it made.
//! One whose zigsaw was killed then is deleted by the recipe's next build,
//! or by `prune`.
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

/// The kept build's root for the kept build `cache\work\<key>` of the store
/// whose tmp\ is `tmp_dir`.
pub fn rootFor(arena: Allocator, tmp_dir: []const u8, key: []const u8) ![]u8 {
    return std.fs.path.join(arena, &.{ tmp_dir, try std.fmt.allocPrint(arena, "{s}{s}", .{ drive.dir_prefix, key }) });
}

/// Whether `name`, in the store's tmp\, is the root of a kept build that
/// `work_dir` (cache\work) has: `prune` takes it for part of that build.
pub fn isKeptRoot(io: Io, arena: Allocator, work_dir: []const u8, name: []const u8) !bool {
    if (!std.mem.startsWith(u8, name, drive.dir_prefix)) return false;
    return Store.exists(io, try std.fs.path.join(arena, &.{ work_dir, name[drive.dir_prefix.len..] }));
}

// ---------------------------------------------------------------------------
// How much room kept builds take

/// The variable that sets how much room the store's kept builds may take
/// together: bytes, or with K, M, G or T (1024-based, a B after them or
/// not). 0 keeps only the build that just ended.
pub const cap_var = "ZIGSAW_KEPT_BUILDS_SIZE";
pub const default_cap: u64 = 10 << 30;

/// Reads a size as `cap_var` takes it.
pub fn parseSize(text: []const u8) error{InvalidSize}!u64 {
    const t = std.mem.trim(u8, text, " \t");
    var end: usize = 0;
    while (end < t.len and std.ascii.isDigit(t[end])) end += 1;
    if (end == 0) return error.InvalidSize;
    const n = std.fmt.parseInt(u64, t[0..end], 10) catch return error.InvalidSize;
    var unit = std.mem.trim(u8, t[end..], " \t");
    if (unit.len > 1 and std.ascii.toUpper(unit[unit.len - 1]) == 'B') unit = unit[0 .. unit.len - 1];
    const shift: u6 = if (unit.len == 0 or std.ascii.eqlIgnoreCase(unit, "B")) 0 else if (unit.len == 1) switch (std.ascii.toUpper(unit[0])) {
        'K' => 10,
        'M' => 20,
        'G' => 30,
        'T' => 40,
        else => return error.InvalidSize,
    } else return error.InvalidSize;
    return std.math.shlExact(u64, n, shift) catch error.InvalidSize;
}

test parseSize {
    try std.testing.expectEqual(0, try parseSize("0"));
    try std.testing.expectEqual(1234, try parseSize("1234"));
    try std.testing.expectEqual(10 << 30, try parseSize("10GB"));
    try std.testing.expectEqual(10 << 30, try parseSize("10 g"));
    try std.testing.expectEqual(512 << 20, try parseSize("512M"));
    try std.testing.expectEqual(7, try parseSize("7B"));
    try std.testing.expectError(error.InvalidSize, parseSize("GB"));
    try std.testing.expectError(error.InvalidSize, parseSize("10 GiB"));
    try std.testing.expectError(error.InvalidSize, parseSize("-1"));
    try std.testing.expectError(error.InvalidSize, parseSize("99999999999T"));
}

test enforceCap {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const work = try std.fs.path.join(arena, &.{ base, "work" });
    const tmp_dir = try std.fs.path.join(arena, &.{ base, "tmp" });

    // Four kept builds of 100 bytes each, used in this order: a d's record
    // is of 0.88, with no size or about.
    const keys = [_][]const u8{ "aaaa", "bbbb", "cccc", "dddd" };
    for (keys) |key| {
        const dir = try std.fs.path.join(arena, &.{ work, key });
        const root = try rootFor(arena, tmp_dir, key);
        try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ root, "prefix" }));
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ root, "prefix", "f" }), .data = &@as([90]u8, @splat('x')) });
        try Io.Dir.cwd().createDirPath(io, dir);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dir, "state" }), .data = &@as([10]u8, @splat('y')) });
        if (!std.mem.eql(u8, key, "dddd")) {
            try std.testing.expectEqual(100, try writeSize(io, arena, dir, root));
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dir, "about" }), .data = try std.fmt.allocPrint(arena, "app.{s}\n", .{key}) });
        }
        win32.Sleep(30);
    }
    // b is in use by another build.
    const b_lock = (try Store.tryLock(io, try Store.lockPathFor(arena, try std.fs.path.join(arena, &.{ work, "bbbb" })), .exclusive)).?;

    // Under the cap: nothing goes.
    try std.testing.expectEqual(0, (try enforceCap(io, arena, work, tmp_dir, "cccc", 400)).len);
    // Room for two: a goes first, b is held, so d does, though c's the
    // oldest after them: c is this build's.
    const gone = try enforceCap(io, arena, work, tmp_dir, "cccc", 200);
    try std.testing.expectEqual(2, gone.len);
    try std.testing.expectEqualStrings("app.aaaa", gone[0].id);
    try std.testing.expectEqualStrings("dddd", gone[1].id);
    try std.testing.expectEqual(100, gone[1].bytes);
    try std.testing.expect(!try Store.exists(io, try rootFor(arena, tmp_dir, "aaaa")));
    try std.testing.expect(try Store.exists(io, try rootFor(arena, tmp_dir, "bbbb")));
    try std.testing.expect(try Store.exists(io, try std.fs.path.join(arena, &.{ work, "cccc" })));
    // 0: all but this build's, once b is free.
    b_lock.release(io);
    try std.testing.expectEqual(1, (try enforceCap(io, arena, work, tmp_dir, "cccc", 0)).len);
    var left: std.ArrayList([]const u8) = .empty;
    for (try listNames(io, arena, work)) |name| if (!std.mem.endsWith(u8, name, ".lock")) try left.append(arena, name);
    try std.testing.expectEqual(1, left.items.len);
    try std.testing.expectEqualStrings("cccc", left.items[0]);
}

/// The room a kept build takes: its root, and its record but for saved\,
/// whose files are other names of the root's while its prefix has them.
pub fn sizeOf(io: Io, arena: Allocator, dir: []const u8, root: []const u8) !u64 {
    var total: u64 = 0;
    if (try Store.exists(io, root)) total += try Store.treeSize(io, arena, root);
    if (try Store.exists(io, dir)) {
        total += try Store.treeSize(io, arena, dir);
        const saved = try std.fs.path.join(arena, &.{ dir, "saved" });
        if (try Store.exists(io, saved)) total -|= try Store.treeSize(io, arena, saved);
    }
    return total;
}

/// A kept build that `enforceCap` deleted.
pub const Deleted = struct {
    /// The app's id, as its build recorded it, or the key.
    id: []const u8,
    bytes: u64,
};

/// Deletes the least recently used of the kept builds in `work_dir`, whose
/// roots are in `tmp_dir`, until they take no more than `cap` together. The
/// one of key `keep` stays, and so do those another build holds. The size of
/// each is in its `size` file, written when its build ended, or measured
/// now and written, for one of 0.88's.
pub fn enforceCap(io: Io, arena: Allocator, work_dir: []const u8, tmp_dir: []const u8, keep: []const u8, cap: u64) ![]Deleted {
    const Candidate = struct { key: []const u8, dir: []const u8, root: []const u8, bytes: u64, used: i96 };
    var entries: std.ArrayList(Candidate) = .empty;
    var total: u64 = 0;
    for (try listNames(io, arena, work_dir)) |key| {
        if (std.mem.endsWith(u8, key, ".lock")) continue;
        const dir = try std.fs.path.join(arena, &.{ work_dir, key });
        const root = try rootFor(arena, tmp_dir, key);
        const bytes = try readSize(io, arena, dir) orelse try writeSize(io, arena, dir, root);
        total += bytes;
        if (std.ascii.eqlIgnoreCase(key, keep)) continue;
        const state = try std.fs.path.join(arena, &.{ dir, "state" });
        const stat = Io.Dir.cwd().statFile(io, if (try Store.exists(io, state)) state else dir, .{}) catch continue;
        try entries.append(arena, .{ .key = key, .dir = dir, .root = root, .bytes = bytes, .used = stat.mtime.nanoseconds });
    }
    std.mem.sort(Candidate, entries.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            return a.used < b.used;
        }
    }.lessThan);
    var deleted: std.ArrayList(Deleted) = .empty;
    for (entries.items) |e| {
        if (total <= cap) break;
        // Not one another build has.
        const lock = try Store.tryLock(io, try Store.lockPathFor(arena, e.dir), .exclusive) orelse continue;
        defer lock.release(io);
        const id = readAbout(io, arena, e.dir) orelse e.key;
        try Store.deleteTree(io, arena, e.dir);
        if (try Store.exists(io, e.root)) try Store.deleteTree(io, arena, e.root);
        total -|= e.bytes;
        try deleted.append(arena, .{ .id = id, .bytes = e.bytes });
    }
    return deleted.items;
}

fn readSize(io: Io, arena: Allocator, dir: []const u8) !?u64 {
    const text = Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ dir, "size" }), arena, .limited(64)) catch return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \r\n"), 10) catch null;
}

/// Measures the kept build at `dir` and writes its `size` file.
pub fn writeSize(io: Io, arena: Allocator, dir: []const u8, root: []const u8) !u64 {
    const bytes = try sizeOf(io, arena, dir, root);
    if (try Store.exists(io, dir))
        try replaceFile(io, arena, try std.fs.path.join(arena, &.{ dir, "size" }), try std.fmt.allocPrint(arena, "{d}\n", .{bytes}));
    return bytes;
}

fn readAbout(io: Io, arena: Allocator, dir: []const u8) ?[]const u8 {
    const text = Io.Dir.cwd().readFileAlloc(io, std.fs.path.join(arena, &.{ dir, "about" }) catch return null, arena, .limited(4096)) catch return null;
    const line = std.mem.trim(u8, text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len], " \r");
    return if (line.len > 0) line else null;
}

/// 2: the root moved from cache\work\<key>\zigsaw-build-root to tmp\. A
/// kept build of 0.88's is deleted, as one that can't be read.
const state_header = "zigsaw kept build 2";
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

    /// Takes the kept build at `dir`, whose root is `root` (see rootFor), for
    /// this build, or returns null if another build has it. One whose state
    /// can't be read, as one a zigsaw before 0.89 left, or whose root is
    /// gone, is deleted.
    pub fn open(io: Io, arena: Allocator, dir: []const u8, root: []const u8) !?Kept {
        try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(dir).?);
        const lock = try Store.tryLock(io, try Store.lockPathFor(arena, dir), .exclusive) orelse return null;
        errdefer lock.release(io);
        var k: Kept = .{ .io = io, .dir = dir, .root = root, .lock = lock };
        if (!try Store.exists(io, dir)) {
            // A root without its record is no use.
            if (try Store.exists(io, root)) try k.reset(arena);
            return k;
        }
        const state = Io.Dir.cwd().readFileAlloc(io, try k.path(arena, "state"), arena, .limited(1 << 24)) catch "";
        if (parseState(arena, state)) |records| {
            if (records.len > 0 and !try Store.exists(io, root)) {
                try k.reset(arena);
                return k;
            }
            k.records = records;
            k.found = true;
        } else |_| try k.reset(arena);
        return k;
    }

    /// Lets another build have it. A root with nothing recorded beside it
    /// goes first: one a build left that stopped before its first module
    /// started (at a vendor step, or with B: taken), which nothing can go on
    /// from, as `open` would find. The lock goes either way.
    pub fn release(k: Kept, arena: Allocator) !void {
        defer k.lock.release(k.io);
        if (!try Store.exists(k.io, k.dir) and try Store.exists(k.io, k.root))
            try Store.deleteTree(k.io, arena, k.root);
    }

    /// Records whose kept build it is, for `enforceCap`'s message.
    pub fn setAbout(k: Kept, arena: Allocator, id: []const u8) !void {
        try Io.Dir.cwd().createDirPath(k.io, k.dir);
        try replaceFile(k.io, arena, try k.path(arena, "about"), try std.fmt.allocPrint(arena, "{s}\n", .{id}));
    }

    /// Deletes everything kept, so the build starts afresh.
    pub fn reset(k: *Kept, arena: Allocator) !void {
        if (try Store.exists(k.io, k.dir)) try Store.deleteTree(k.io, arena, k.dir);
        if (try Store.exists(k.io, k.root)) try Store.deleteTree(k.io, arena, k.root);
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
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const dir = try std.fs.path.join(arena, &.{ base, "work", "0123456789abcdef" });
    const k = (try Kept.open(io, arena, dir, try rootFor(arena, try std.fs.path.join(arena, &.{ base, "tmp" }), "0123456789abcdef"))).?;
    // As the build makes it.
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ k.root, "prefix" }));
    return k;
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
    try std.testing.expect((try Kept.open(io, arena, k.dir, k.root)) == null);

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
    try k.release(arena);
    k = try testKept(io, arena, tmp);
    defer k.release(arena) catch {};
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
    try k.release(arena);
    k = try testKept(io, arena, tmp);
    try std.testing.expect(!k.found);
    try std.testing.expect(!try Store.exists(io, k.dir));

    // A record whose root is gone, as `prune` or a person may delete tmp\:
    // nothing is taken, and the record goes too.
    try k.started(arena, 0, "a", keys[0]);
    try k.finished(arena, 0, "a", keys[0], 0);
    try k.release(arena);
    try Store.deleteTree(io, arena, k.root);
    k = try testKept(io, arena, tmp);
    try std.testing.expect(!k.found);
    try std.testing.expectEqual(0, k.records.len);

    // A build that stopped before its first module started, at a vendor
    // step say, recorded nothing: its root goes as it lets go.
    const orphan = try std.fs.path.join(arena, &.{ k.root, "prefix", "x.txt" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = orphan, .data = "x" });
    try std.testing.expect(!try Store.exists(io, k.dir));
    try k.release(arena);
    try std.testing.expect(!try Store.exists(io, k.root));

    // Once a module started, the root stays, with its record.
    k = try testKept(io, arena, tmp);
    try k.started(arena, 0, "a", keys[0]);
    try k.release(arena);
    try std.testing.expect(try Store.exists(io, k.root));

    // A root with no record, as one whose record was deleted, or a killed
    // zigsaw's: gone.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = orphan, .data = "x" });
    try Store.deleteTree(io, arena, k.dir);
    k = (try Kept.open(io, arena, k.dir, k.root)).?;
    try std.testing.expect(!try Store.exists(io, orphan));
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
    defer k.release(arena) catch {};

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
    defer k.release(arena) catch {};
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
    defer k.release(arena) catch {};
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
