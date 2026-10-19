//! The keys an app keeps in HKEY_CURRENT_USER, as its config's `registry`
//! names them ("Software\\7-Zip"), kept with its data: between runs they're
//! in a hive file in its data directory, registry\user.dat. So they go with
//! `rm --delete-data`, an `--ephemeral` run starts without them, and a copy
//! of the app installed the usual way keeps its own.
//!
//! Apps look for them in HKCU, so that's where they are while the app runs.
//! The first run copies them in, moving aside a key of the same name that's
//! there already; the last run to end copies them back into the hive and
//! puts that key back. Each run labels the keys low, or grants them to the
//! app's capability, as its sandbox needs, so that the app can save its
//! settings in every sandbox: the keys are deleted afterwards, and the label
//! and the grant with them. An AppContainer also gets read access to the keys
//! above them, which it opens on its way there, until they're taken back.
//! Nothing else in HKCU is kept from the app.
//!
//! HKCU\Software\zigsaw\keys\<the key, with '/' for '\'> records which data
//! directory a key in HKCU belongs to, and how far putting it there or
//! taking it back got. So what a run that didn't end left (zigsaw was
//! killed) is settled by the next run, `repair` or `rm`, without losing the
//! app's settings or the ones moved aside; and two apps, or two stores'
//! copies of one, don't use a key at once. A key moved aside waits in
//! HKCU\Software\zigsaw\aside\<the same name>.
//!
//! Each run holds `<data directory>.hkcu.lock` shared while it runs: the run
//! that can lock it exclusively at its end is the last. All changes happen
//! under one named mutex, so zigsaw processes take turns.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");
const acl = @import("acl.zig");
const appcontainer = @import("appcontainer.zig");
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const Key = @import("regkey.zig").Key;
const fail = Context.fail;
const note = Context.note;

const hkcu = win32.HKEY_CURRENT_USER;
const records_key = "Software\\zigsaw\\keys";
const aside_key = "Software\\zigsaw\\aside";
const mutex_name = "Local\\zigsaw-hkcu";

/// What a run's sandbox needs of the keys to write them.
pub const Access = union(enum) {
    /// soft: nothing.
    none,
    /// low: a low integrity label.
    low,
    /// appcontainer: access for the app's capability.
    capability: win32.PSID,
};

pub const Session = struct {
    id: []const u8,
    keys: []const []const u8,
    data_dir: []const u8,
    lock_path: []const u8,
    lock: Store.Lock,
    /// Whether the keys go back into the hive at the end: not for an
    /// --ephemeral run, whose data directory is deleted.
    keep: bool,
};

/// Puts the app's keys in HKCU for a run, unless runs that are still going
/// have; null if the app keeps none. `leave` takes them back.
pub fn enter(ctx: *Context, id: []const u8, keys: ?[]const []const u8, data_dir: []const u8, access: Access, keep: bool) !?Session {
    const list = keys orelse return null;
    if (list.len == 0) return null;
    const arena = ctx.arena;
    const io = ctx.io;
    const mutex = try Mutex.acquire();
    defer mutex.release();

    const lock_path = try lockPath(arena, data_dir);
    // No other run of the app holds it: this run is the first.
    const first = if (try Store.tryLock(io, lock_path, .exclusive)) |l| blk: {
        l.release(io);
        break :blk true;
    } else false;
    const lock = try Store.openLock(io, lock_path, .shared, .wait);
    errdefer lock.release(io);

    for (list) |key| {
        if (try Record.read(arena, key)) |r| {
            if (samePath(r.data, data_dir)) {
                // In place for the runs still going; or left by one that
                // didn't end, which this run settles.
                if (first) {
                    try settle(ctx, key, r, true);
                    try putInPlace(ctx, id, key, data_dir);
                }
            } else {
                if (try Store.isLocked(io, try lockPath(arena, r.data)))
                    return fail("{s} keeps HKCU\\{s}, which a run of {s} is using (its data is in {s}); run it once that ends", .{ id, key, r.app, r.data });
                try settle(ctx, key, r, true);
                try putInPlace(ctx, id, key, data_dir);
            }
        } else try putInPlace(ctx, id, key, data_dir);

        switch (access) {
            .none => {},
            .low => try acl.labelKeyLow(arena, key),
            .capability => |sid| {
                try acl.grantKey(arena, key, sid);
                try grantAbove(arena, key, sid);
            },
        }
    }
    return .{ .id = id, .keys = list, .data_dir = data_dir, .lock_path = lock_path, .lock = lock, .keep = keep };
}

/// Ends a run's use of the keys: the last run takes them back. A failure
/// leaves them in HKCU, for the next run, `repair` or `rm` to settle.
pub fn leave(ctx: *Context, s: Session) void {
    leaveOrFail(ctx, s) catch note("warning: {s}'s registry keys stay in HKCU until its next run, `zigsaw repair` or `zigsaw rm`", .{s.id});
}

fn leaveOrFail(ctx: *Context, s: Session) !void {
    const mutex = try Mutex.acquire();
    defer mutex.release();
    s.lock.release(ctx.io);
    const last = try Store.tryLock(ctx.io, s.lock_path, .exclusive) orelse return;
    for (s.keys) |key| {
        const r = try Record.read(ctx.arena, key) orelse continue;
        if (samePath(r.data, s.data_dir)) settle(ctx, key, r, s.keep) catch |err| {
            last.release(ctx.io);
            return err;
        };
    }
    try tidy(ctx.arena);
    // No run of the app holds the lock, and none can start while zigsaw
    // has the mutex, so it can go.
    last.release(ctx.io);
    Io.Dir.cwd().deleteFile(ctx.io, s.lock_path) catch {};
}

/// Deletes zigsaw's own keys in HKCU once nothing is recorded in them.
fn tidy(arena: Allocator) !void {
    for ([_][]const u8{ records_key, aside_key, "Software\\zigsaw" }) |name| {
        const k = try Key.open(arena, hkcu, name, win32.KEY_READ) orelse continue;
        const empty = try k.isEmpty();
        k.close();
        if (empty) _ = win32.RegDeleteKeyW(hkcu, try win32.wide(arena, name));
    }
}

/// Settles the keys runs of this store's apps left in HKCU (when zigsaw
/// didn't see them end), all of them or `id`'s, as their last run would
/// have; except those of runs still going. Also drops keys moved aside that
/// nothing will put back, since what they hold is in HKCU again.
pub fn settleLeftovers(ctx: *Context, id: ?[]const u8) !void {
    const arena = ctx.arena;
    const records = try Key.open(arena, hkcu, records_key, win32.KEY_READ);
    const asides = try Key.open(arena, hkcu, aside_key, win32.KEY_READ | win32.KEY_WRITE);
    if (records == null and asides == null) return;
    const mutex = try Mutex.acquire();
    defer mutex.release();
    if (records) |k| {
        defer k.close();
        for (try k.subKeys(arena)) |name| {
            const key = try unescape(arena, name);
            const r = try Record.read(arena, key) orelse continue;
            if (!isInStore(r.data, ctx.store.root)) continue;
            if (id) |i| if (!std.ascii.eqlIgnoreCase(i, r.app)) continue;
            const lock_path = try lockPath(arena, r.data);
            if (try Store.isLocked(ctx.io, lock_path)) continue;
            try settle(ctx, key, r, true);
            Io.Dir.cwd().deleteFile(ctx.io, lock_path) catch {};
        }
    }
    if (asides) |k| {
        defer k.close();
        for (try k.subKeys(arena)) |name| {
            if (try Record.read(arena, try unescape(arena, name)) != null) continue;
            try k.deleteTree(arena, name);
        }
    }
    try tidy(arena);
}

// ---------------------------------------------------------------------------
// Moving keys
//
// Each step is recorded before the next, so that settling what an
// interrupted one left keeps both the app's settings and those moved aside:
// - putInPlace copies a key that's there aside, then records it (moving),
//   then replaces it with the hive's copy (in place).
// - settle copies an in-place key back into the hive (taken back), deletes
//   it, copies back what was aside, deletes the record, then the aside copy.
//   A key still moving isn't the app's yet, so it's only deleted.

fn putInPlace(ctx: *Context, id: []const u8, key: []const u8, data_dir: []const u8) !void {
    const arena = ctx.arena;
    const name = try escape(arena, key);
    const native = try Key.exists(arena, hkcu, key);
    if (native) {
        const asides: Key = try .createWith(arena, hkcu, aside_key, win32.KEY_ALL_ACCESS);
        defer asides.close();
        try asides.deleteTree(arena, name);
        const to: Key = try .createWith(arena, asides.handle, name, win32.KEY_ALL_ACCESS);
        defer to.close();
        const from = (try Key.open(arena, hkcu, key, win32.KEY_READ)).?;
        defer from.close();
        try to.copyFrom(arena, from);
    }
    // A key that was there had the keys above it. Otherwise creating it makes
    // those that aren't there yet, which taking it back deletes, and no others.
    const made = if (native) null else try outermostMissing(arena, key);
    try Record.write(arena, key, .{ .data = data_dir, .app = id, .aside = native, .state = .moving, .made = made });
    if (native) {
        try deleteKey(arena, key);
        note("moved HKCU\\{s} aside while {s} runs; it comes back when the app ends", .{ key, id });
    }
    const dest: Key = try .createWith(arena, hkcu, key, win32.KEY_ALL_ACCESS);
    defer dest.close();
    if (try Hive.open(ctx, data_dir, .existing)) |h| {
        defer h.close();
        if (try Key.open(arena, h.root, key, win32.KEY_READ)) |src| {
            defer src.close();
            try dest.copyFrom(arena, src);
        }
    }
    try Record.setState(arena, key, .in_place);
}

/// Takes the key back from HKCU: into its data directory's hive if `keep`
/// and the directory is still there, and puts back what was aside.
fn settle(ctx: *Context, key: []const u8, r: Record, keep: bool) !void {
    const arena = ctx.arena;
    if (r.state == .in_place) {
        if (keep) try saveToHive(ctx, key, r.data);
        try Record.setState(arena, key, .taken_back);
    }
    try deleteKey(arena, key);
    const name = try escape(arena, key);
    if (r.aside) {
        const asides = try Key.open(arena, hkcu, aside_key, win32.KEY_READ);
        defer if (asides) |a| a.close();
        if (asides) |a| if (try Key.open(arena, a.handle, name, win32.KEY_READ)) |from| {
            defer from.close();
            const to: Key = try .createWith(arena, hkcu, key, win32.KEY_ALL_ACCESS);
            defer to.close();
            try to.copyFrom(arena, from);
        };
    }
    try Record.delete(arena, key);
    if (try Key.open(arena, hkcu, aside_key, win32.KEY_READ | win32.KEY_WRITE)) |a| {
        defer a.close();
        try a.deleteTree(arena, name);
    }
    if (!r.aside) if (r.made) |outermost| try deleteEmptyParents(arena, key, outermost);
    try revokeAbove(arena, key, r.app);
}

/// Lets the app's AppContainer read the keys above `key`, below Software,
/// which it opens on the way to `key`: Java's preferences open theirs from
/// their root, HKCU\Software\JavaSoft\Prefs, one key at a time. Read access
/// to each key itself, not the keys in it; taking `key` back takes it away.
fn grantAbove(arena: Allocator, key: []const u8, sid: win32.PSID) !void {
    var parent = std.fs.path.dirnameWindows(key) orelse return;
    while (std.mem.indexOfScalar(u8, parent, '\\') != null) {
        if (try Key.exists(arena, hkcu, parent)) try acl.grantKeyRead(arena, parent, sid);
        parent = std.fs.path.dirnameWindows(parent) orelse return;
    }
}

/// Takes back what `grantAbove` gave the app's AppContainer, if it did.
fn revokeAbove(arena: Allocator, key: []const u8, app: []const u8) !void {
    if (app.len == 0) return;
    const sid = try appcontainer.appCapability(arena, app);
    var parent = std.fs.path.dirnameWindows(key) orelse return;
    while (std.mem.indexOfScalar(u8, parent, '\\') != null) {
        if (try Key.exists(arena, hkcu, parent)) try acl.revokeKey(arena, parent, sid);
        parent = std.fs.path.dirnameWindows(parent) orelse return;
    }
}

/// Replaces the hive's copy of the key with HKCU's, if the data directory is
/// still there.
fn saveToHive(ctx: *Context, key: []const u8, data_dir: []const u8) !void {
    const arena = ctx.arena;
    const current = try Key.open(arena, hkcu, key, win32.KEY_READ) orelse return;
    defer current.close();
    const h = try Hive.open(ctx, data_dir, .create) orelse return;
    defer h.close();
    const root: Key = .{ .handle = h.root };
    try root.deleteTree(arena, key);
    const to: Key = try .createWith(arena, h.root, key, win32.KEY_ALL_ACCESS);
    defer to.close();
    try to.copyFrom(arena, current);
}

/// Deletes HKCU\<key> and everything in it.
fn deleteKey(arena: Allocator, key: []const u8) !void {
    const root: Key = .{ .handle = hkcu };
    try root.deleteTree(arena, key);
}

/// The outermost of the keys `key` is in that HKCU doesn't have, below
/// Software; null if it has them all.
fn outermostMissing(arena: Allocator, key: []const u8) !?[]const u8 {
    var missing: ?[]const u8 = null;
    var parent = std.fs.path.dirnameWindows(key) orelse return null;
    while (std.mem.indexOfScalar(u8, parent, '\\') != null) {
        if (try Key.exists(arena, hkcu, parent)) break;
        missing = parent;
        parent = std.fs.path.dirnameWindows(parent) orelse break;
    }
    return missing;
}

/// Deletes the keys `key` was in that putting it in place made, from the
/// innermost out to `outermost`, while they're empty (another app's key may
/// be in them by now). Keys that were there before, empty or not, stay:
/// `HKCU\Software\JavaSoft\Prefs` is often there and empty, and Java apps
/// keep keys below it.
fn deleteEmptyParents(arena: Allocator, key: []const u8, outermost: []const u8) !void {
    if (!isAbove(outermost, key)) return;
    var parent = std.fs.path.dirnameWindows(key) orelse return;
    while (parent.len >= outermost.len) {
        const k = try Key.open(arena, hkcu, parent, win32.KEY_READ) orelse return;
        const empty = try k.isEmpty();
        k.close();
        if (!empty) return;
        if (win32.RegDeleteKeyW(hkcu, try win32.wide(arena, parent)) != 0) return;
        parent = std.fs.path.dirnameWindows(parent) orelse return;
    }
}

/// Whether `outer` is a key that `key` is in, below Software.
fn isAbove(outer: []const u8, key: []const u8) bool {
    return std.mem.indexOfScalar(u8, outer, '\\') != null and key.len > outer.len + 1 and
        std.ascii.eqlIgnoreCase(key[0..outer.len], outer) and key[outer.len] == '\\';
}

// ---------------------------------------------------------------------------
// Records

const Record = struct {
    /// The data directory the key goes back to.
    data: []const u8,
    app: []const u8,
    /// Whether a key that was there is aside, to be put back.
    aside: bool,
    state: State,
    /// The outermost of the keys above it that putting it in place made,
    /// which taking it back deletes while empty; null if they were all
    /// there (and in records of zigsaw 0.26 and earlier, which deleted
    /// every empty key above it, made or not).
    made: ?[]const u8 = null,

    const State = enum {
        moving,
        in_place,
        taken_back,

        fn text(s: State) []const u8 {
            return switch (s) {
                .moving => "moving",
                .in_place => "in place",
                .taken_back => "taken back",
            };
        }
    };

    fn path(arena: Allocator, key: []const u8) ![]u8 {
        return std.fmt.allocPrint(arena, "{s}\\{s}", .{ records_key, try escape(arena, key) });
    }

    fn read(arena: Allocator, key: []const u8) !?Record {
        const k = try Key.open(arena, hkcu, try path(arena, key), win32.KEY_READ) orelse return null;
        defer k.close();
        const state_text = try k.getString(arena, "State") orelse return null;
        const state: State = for (std.enums.values(State)) |s| {
            if (std.mem.eql(u8, s.text(), state_text)) break s;
        } else return null;
        return .{
            .data = try k.getString(arena, "Data") orelse return null,
            .app = try k.getString(arena, "App") orelse "",
            .aside = std.mem.eql(u8, try k.getString(arena, "Aside") orelse "", "yes"),
            .state = state,
            .made = try k.getString(arena, "Made"),
        };
    }

    fn write(arena: Allocator, key: []const u8, r: Record) !void {
        const k: Key = try .create(arena, hkcu, try path(arena, key));
        defer k.close();
        try k.setString(arena, "Data", r.data);
        try k.setString(arena, "App", r.app);
        try k.setString(arena, "Aside", if (r.aside) "yes" else "no");
        try k.setString(arena, "State", r.state.text());
        if (r.made) |m| try k.setString(arena, "Made", m);
    }

    fn setState(arena: Allocator, key: []const u8, state: State) !void {
        const k: Key = try .create(arena, hkcu, try path(arena, key));
        defer k.close();
        try k.setString(arena, "State", state.text());
    }

    fn delete(arena: Allocator, key: []const u8) !void {
        const records = try Key.open(arena, hkcu, records_key, win32.KEY_READ | win32.KEY_WRITE) orelse return;
        defer records.close();
        try records.deleteTree(arena, try escape(arena, key));
    }
};

/// A key's name among the records: its path with '/' for '\', which the
/// keys apps keep don't have (see `oci.isValidRegistryKey`).
fn escape(arena: Allocator, key: []const u8) ![]u8 {
    const out = try arena.dupe(u8, key);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

fn unescape(arena: Allocator, name: []const u8) ![]u8 {
    const out = try arena.dupe(u8, name);
    std.mem.replaceScalar(u8, out, '/', '\\');
    return out;
}

// ---------------------------------------------------------------------------

/// The hive in a data directory, loaded privately by zigsaw.
const Hive = struct {
    root: win32.HKEY,

    fn close(h: Hive) void {
        _ = win32.RegCloseKey(h.root);
    }

    /// Null for `.existing` when the data directory has no hive yet, and for
    /// `.create` when the data directory itself is gone.
    fn open(ctx: *Context, data_dir: []const u8, mode: enum { existing, create }) !?Hive {
        const arena = ctx.arena;
        const dir = try std.fs.path.join(arena, &.{ data_dir, "registry" });
        const file = try std.fs.path.join(arena, &.{ dir, "user.dat" });
        switch (mode) {
            .existing => if (!try Store.exists(ctx.io, file)) return null,
            .create => {
                if (!try Store.exists(ctx.io, data_dir)) return null;
                try Io.Dir.cwd().createDirPath(ctx.io, dir);
            },
        }
        var root: win32.HKEY = undefined;
        const status = win32.RegLoadAppKeyW(try win32.wide(arena, file), &root, win32.KEY_ALL_ACCESS, 0, 0);
        if (status != 0) return fail("loading the registry hive {s}: error {d} ({s})", .{ file, status, win32.errorName(status) });
        return .{ .root = root };
    }
};

const Mutex = struct {
    handle: win32.HANDLE,

    fn acquire() !Mutex {
        const handle = win32.CreateMutexW(null, win32.FALSE, std.unicode.utf8ToUtf16LeStringLiteral(mutex_name)) orelse
            return win32.lastErrorFail("CreateMutexW");
        // Abandoned: a zigsaw that had it ended without releasing it.
        switch (win32.WaitForSingleObject(handle, win32.INFINITE)) {
            win32.WAIT_OBJECT_0, win32.WAIT_ABANDONED => return .{ .handle = handle },
            else => {
                _ = win32.CloseHandle(handle);
                return win32.lastErrorFail("WaitForSingleObject");
            },
        }
    }

    fn release(m: Mutex) void {
        _ = win32.ReleaseMutex(m.handle);
        _ = win32.CloseHandle(m.handle);
    }
};

fn lockPath(arena: Allocator, data_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}.hkcu.lock", .{std.mem.trimEnd(u8, data_dir, "\\/")});
}

fn samePath(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, a, "\\/"), std.mem.trimEnd(u8, b, "\\/"));
}

/// Whether `p` is in the store at `root`.
fn isInStore(p: []const u8, root: []const u8) bool {
    const r = std.mem.trimEnd(u8, root, "\\/");
    return p.len > r.len and std.ascii.eqlIgnoreCase(p[0..r.len], r) and (p[r.len] == '\\' or p[r.len] == '/');
}

test "escaped key names" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("Software/VideoLAN/VLC", try escape(arena, "Software\\VideoLAN\\VLC"));
    try std.testing.expectEqualStrings("Software\\VideoLAN\\VLC", try unescape(arena, "Software/VideoLAN/VLC"));
    try std.testing.expect(isInStore("C:\\Store\\data\\app", "c:\\store\\"));
    try std.testing.expect(!isInStore("C:\\Store2\\data\\app", "C:\\Store"));
    try std.testing.expect(samePath("C:\\a\\data\\x\\", "c:\\A\\data\\X"));
}

test "keys above a key" {
    try std.testing.expect(isAbove("Software\\JavaSoft\\Prefs\\org", "Software\\JavaSoft\\Prefs\\org\\apache\\pdfbox"));
    try std.testing.expect(isAbove("software\\javasoft", "Software\\JavaSoft\\Prefs"));
    try std.testing.expect(!isAbove("Software", "Software\\JavaSoft"));
    try std.testing.expect(!isAbove("Software\\Java", "Software\\JavaSoft\\Prefs"));
    try std.testing.expect(!isAbove("Software\\JavaSoft\\Prefs", "Software\\JavaSoft\\Prefs"));
    try std.testing.expect(!isAbove("Software\\Other", "Software\\JavaSoft\\Prefs"));
}
