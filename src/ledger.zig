//! What zigsaw changed outside its stores, kept outside them: a copy of each
//! store's grants (see grants.zig) under HKCU\Software\Zigsaw\Grants, one value
//! per change, named `<store>|<app>|<grant as its file has it>`. A store's own
//! files stay what it goes by; this is for what they can't do: say what a store
//! did once it's been deleted, and tell one store what another needs. Windows
//! keeps low integrity labels and grants until something takes them away, so
//! deleting a store by hand leaves them behind, unrecorded otherwise.
//!
//! ZIGSAW_GRANTS_KEY names another key under HKCU, for tests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const acl = @import("acl.zig");
const regkey = @import("regkey.zig");
const win32 = @import("win32.zig");
const Store = @import("Store.zig");
const Key = regkey.Key;

pub const default_key = "Software\\Zigsaw\\Grants";

pub const Entry = struct {
    store: []const u8,
    id: []const u8,
    grant: Store.Grant,

    fn name(e: Entry, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}|{s}|{f}", .{ e.store, e.id, e.grant });
    }

    /// Null for a value that isn't one of ours. Neither a path nor an app id
    /// can have a `|`.
    fn parse(value_name: []const u8) ?Entry {
        var it = std.mem.splitScalar(u8, value_name, '|');
        const store = it.next() orelse return null;
        const id = it.next() orelse return null;
        const line = it.next() orelse return null;
        if (it.next() != null or store.len == 0 or id.len == 0 or line.len == 0) return null;
        return .{ .store = store, .id = id, .grant = .parse(line) };
    }

    pub fn ofStore(e: Entry, store: []const u8) bool {
        return std.os.windows.eqlIgnoreCaseWtf8(std.mem.trimEnd(u8, e.store, "\\/"), std.mem.trimEnd(u8, store, "\\/"));
    }
};

pub const State = enum {
    /// Its store says so too.
    live,
    /// Its store is gone, or no longer has this: nothing will take it back.
    orphan,
    /// Its store's drive or share can't be reached now: it may be back.
    away,
};

/// All that's recorded. None if nothing ever was.
pub fn list(arena: Allocator, key: []const u8) ![]const Entry {
    const k = try Key.open(arena, win32.HKEY_CURRENT_USER, key, win32.KEY_READ) orelse return &.{};
    defer k.close();
    var out: std.ArrayList(Entry) = .empty;
    for (try k.valueNames(arena)) |value_name| if (Entry.parse(value_name)) |e| try out.append(arena, e);
    return out.items;
}

/// Makes the record of the app's grants in `store` be `grants`. A zigsaw below
/// medium integrity can't, and changes no ACL anyway.
pub fn sync(arena: Allocator, key: []const u8, store: []const u8, id: []const u8, grants: []const Store.Grant) !void {
    if (try acl.belowMedium()) return;
    const existing = try list(arena, key);
    var stale: std.ArrayList(Entry) = .empty;
    for (existing) |e| {
        if (!e.ofStore(store) or !std.os.windows.eqlIgnoreCaseWtf8(e.id, id)) continue;
        const kept = for (grants) |g| {
            if (g.eql(e.grant)) break true;
        } else false;
        if (!kept) try stale.append(arena, e);
    }
    var missing: std.ArrayList(Entry) = .empty;
    for (grants) |g| {
        const here = for (existing) |e| {
            if (e.ofStore(store) and std.os.windows.eqlIgnoreCaseWtf8(e.id, id) and g.eql(e.grant)) break true;
        } else false;
        if (!here) try missing.append(arena, .{ .store = store, .id = id, .grant = g });
    }
    if (stale.items.len == 0 and missing.items.len == 0) return;
    const k: Key = try .create(arena, win32.HKEY_CURRENT_USER, key);
    defer k.close();
    for (stale.items) |e| try k.deleteValue(arena, try e.name(arena));
    for (missing.items) |e| try k.setString(arena, try e.name(arena), "");
    if (missing.items.len == 0) try dropIfEmpty(arena, key);
}

/// Forgets one entry.
pub fn remove(arena: Allocator, key: []const u8, e: Entry) !void {
    {
        const k = try Key.open(arena, win32.HKEY_CURRENT_USER, key, win32.KEY_READ | win32.KEY_WRITE) orelse return;
        defer k.close();
        try k.deleteValue(arena, try e.name(arena));
    }
    try dropIfEmpty(arena, key);
}

/// With nothing recorded, the key goes, and the one above it if that leaves it
/// empty, so that uninstalling apps leaves nothing of zigsaw's in the registry.
pub fn dropIfEmpty(arena: Allocator, key: []const u8) !void {
    if (!try removeIfEmpty(arena, key)) return;
    const slash = std.mem.lastIndexOfScalar(u8, key, '\\') orelse return;
    // Never a top-level key, such as Software.
    if (std.mem.indexOfScalar(u8, key[0..slash], '\\') != null) _ = try removeIfEmpty(arena, key[0..slash]);
}

fn removeIfEmpty(arena: Allocator, key: []const u8) !bool {
    const k = try Key.open(arena, win32.HKEY_CURRENT_USER, key, win32.KEY_READ) orelse return false;
    const empty = k.isEmpty() catch false;
    k.close();
    if (!empty) return false;
    return win32.RegDeleteKeyW(win32.HKEY_CURRENT_USER, try win32.wide(arena, key)) == win32.ERROR_SUCCESS;
}

/// Whether anything still stands behind the entry.
pub fn stateOf(io: Io, arena: Allocator, e: Entry) !State {
    const store: Store = .{ .io = io, .root = e.store };
    if (!existsOrUnreadable(io, try store.path(arena, &.{"grants"}))) {
        // Without a drive to look on, it can't be told from one unplugged.
        if (std.mem.startsWith(u8, e.store, "\\\\")) return .away;
        if (e.store.len < 3 or e.store[1] != ':') return .orphan;
        return if (existsOrUnreadable(io, e.store[0..3])) .orphan else .away;
    }
    for (store.readGrants(arena, e.id) catch return .live) |g| if (g.eql(e.grant)) return .live;
    return .orphan;
}

/// A path that can't be looked at isn't known to be gone.
fn existsOrUnreadable(io: Io, p: []const u8) bool {
    return Store.exists(io, p) catch true;
}

test "Entry: name and parse agree" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]Store.Grant{
        .{ .kind = .low, .path = "C:\\Users\\a\\Documents" },
        .{ .kind = .appcontainer, .path = "D:\\proj" },
        .loopback,
    };
    for (cases) |g| {
        const e: Entry = .{ .store = "E:\\s", .id = "a.b", .grant = g };
        const back = Entry.parse(try e.name(arena)).?;
        try std.testing.expectEqualStrings("E:\\s", back.store);
        try std.testing.expectEqualStrings("a.b", back.id);
        try std.testing.expect(g.eql(back.grant));
    }
    for ([_][]const u8{ "", "E:\\s", "E:\\s|a.b", "|a.b|x", "E:\\s||x", "E:\\s|a.b|", "a|b|c|d" }) |bad| try std.testing.expectEqual(null, Entry.parse(bad));
    const e: Entry = .{ .store = "E:\\S\\", .id = "a.b", .grant = .loopback };
    try std.testing.expect(e.ofStore("e:\\s"));
    try std.testing.expect(!e.ofStore("e:\\s2"));
}

test "sync, list, stateOf and remove, on a key of their own" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const key = try std.fmt.allocPrint(arena, "Software\\ZigsawTest\\ledger-{d}", .{std.os.windows.GetCurrentProcessId()});
    defer {
        _ = win32.RegDeleteTreeW(win32.HKEY_CURRENT_USER, win32.wide(arena, key) catch unreachable);
        _ = win32.RegDeleteKeyW(win32.HKEY_CURRENT_USER, win32.wide(arena, "Software\\ZigsawTest") catch unreachable);
    }
    try std.testing.expectEqual(0, (try list(arena, key)).len);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    try tmp.dir.createDirPath(io, "grants");
    try tmp.dir.createDirPath(io, "tmp");
    const store: Store = .{ .io = io, .root = root };
    const label: Store.Grant = .{ .kind = .low, .path = "D:\\proj" };
    const other: Store.Grant = .{ .kind = .appcontainer, .path = "D:\\other" };
    try store.writeGrants(arena, "a.app", &.{label});

    try sync(arena, key, root, "a.app", &.{ label, other });
    try sync(arena, key, "E:\\gone", "b.app", &.{label});
    try std.testing.expectEqual(3, (try list(arena, key)).len);
    // Again: nothing changes.
    try sync(arena, key, root, "a.app", &.{ label, other });
    try std.testing.expectEqual(3, (try list(arena, key)).len);

    var live: usize = 0;
    var orphans: usize = 0;
    for (try list(arena, key)) |e| switch (try stateOf(io, arena, e)) {
        .live => live += 1,
        .orphan => orphans += 1,
        .away => {},
    };
    // Its store has only the label; E:\gone has no grants, wherever E: is.
    try std.testing.expectEqual(1, live);
    try std.testing.expect(orphans >= 1);

    try sync(arena, key, root, "a.app", &.{other});
    const left = try list(arena, key);
    try std.testing.expectEqual(2, left.len);
    for (left) |e| try remove(arena, key, e);
    try std.testing.expectEqual(0, (try list(arena, key)).len);
    // Nothing left: the key has gone.
    try std.testing.expect(!try Key.exists(arena, win32.HKEY_CURRENT_USER, key));
}
