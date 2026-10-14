//! Registry keys, opened by path under a parent key: what file associations
//! (associations.zig) and the keys apps keep (hkcu.zig) are made of.

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");
const Context = @import("Context.zig");
const fail = Context.fail;

/// An open registry key.
pub const Key = struct {
    handle: win32.HKEY,

    /// Opens `parent`'s key `sub` to read and write, making it and the keys on
    /// the way if they aren't there.
    pub fn create(arena: Allocator, parent: win32.HKEY, sub: []const u8) !Key {
        return createWith(arena, parent, sub, win32.KEY_READ | win32.KEY_WRITE);
    }

    pub fn createWith(arena: Allocator, parent: win32.HKEY, sub: []const u8, access: win32.DWORD) !Key {
        var handle: win32.HKEY = undefined;
        try check("creating", sub, win32.RegCreateKeyExW(parent, try win32.wide(arena, sub), 0, null, 0, access, null, &handle, null));
        return .{ .handle = handle };
    }

    /// Null if there's no such key.
    pub fn open(arena: Allocator, parent: win32.HKEY, sub: []const u8, access: win32.DWORD) !?Key {
        var handle: win32.HKEY = undefined;
        const status = win32.RegOpenKeyExW(parent, try win32.wide(arena, sub), 0, access, &handle);
        if (status == win32.ERROR_FILE_NOT_FOUND) return null;
        try check("opening", sub, status);
        return .{ .handle = handle };
    }

    pub fn exists(arena: Allocator, parent: win32.HKEY, sub: []const u8) !bool {
        const k = try open(arena, parent, sub, win32.KEY_READ) orelse return false;
        k.close();
        return true;
    }

    pub fn close(k: Key) void {
        _ = win32.RegCloseKey(k.handle);
    }

    /// Sets a string value; a null `name` is the key's default value.
    pub fn setString(k: Key, arena: Allocator, name: ?[]const u8, value: []const u8) !void {
        const value_w = try win32.wide(arena, value);
        const name_w: ?win32.LPCWSTR = if (name) |n| try win32.wide(arena, n) else null;
        const bytes: []const u8 = std.mem.sliceAsBytes(value_w[0 .. value_w.len + 1]);
        try check("setting", name orelse "(default)", win32.RegSetValueExW(k.handle, name_w, 0, win32.REG_SZ, bytes.ptr, @intCast(bytes.len)));
    }

    /// A string value, or null if the key has no such value, or one of
    /// another type.
    pub fn getString(k: Key, arena: Allocator, name: []const u8) !?[]const u8 {
        const name_w = try win32.wide(arena, name);
        var size: win32.DWORD = 0;
        var kind: win32.DWORD = 0;
        var status = win32.RegQueryValueExW(k.handle, name_w, null, &kind, null, &size);
        if (status == win32.ERROR_FILE_NOT_FOUND) return null;
        try check("reading", name, status);
        if (kind != win32.REG_SZ) return null;
        const buf = try arena.alignedAlloc(u8, .of(u16), size + 2);
        status = win32.RegQueryValueExW(k.handle, name_w, null, null, buf.ptr, &size);
        try check("reading", name, status);
        const units: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, buf[0 .. size - size % 2]));
        return try std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.sliceTo(units, 0));
    }

    pub fn deleteValue(k: Key, arena: Allocator, name: []const u8) !void {
        const status = win32.RegDeleteValueW(k.handle, try win32.wide(arena, name));
        if (status != win32.ERROR_FILE_NOT_FOUND) try check("deleting", name, status);
    }

    /// The names of the key's own keys.
    pub fn subKeys(k: Key, arena: Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var index: win32.DWORD = 0;
        while (true) : (index += 1) {
            // Key names are at most 255 characters.
            var buf: [256]u16 = undefined;
            var len: win32.DWORD = buf.len;
            const status = win32.RegEnumKeyExW(k.handle, index, &buf, &len, null, null, null, null);
            if (status == win32.ERROR_NO_MORE_ITEMS) break;
            try check("listing", "keys", status);
            try out.append(arena, try std.unicode.wtf16LeToWtf8Alloc(arena, buf[0..len]));
        }
        return out.items;
    }

    /// Whether the key has no keys and no values, its default included.
    pub fn isEmpty(k: Key) !bool {
        var keys: win32.DWORD = 0;
        var values: win32.DWORD = 0;
        try check("reading", "a key", win32.RegQueryInfoKeyW(k.handle, null, null, null, &keys, null, null, &values, null, null, null, null));
        return keys == 0 and values == 0;
    }

    /// Deletes the key `sub` and all below it, if it's there.
    pub fn deleteTree(k: Key, arena: Allocator, sub: []const u8) !void {
        const status = win32.RegDeleteTreeW(k.handle, try win32.wide(arena, sub));
        if (status == win32.ERROR_FILE_NOT_FOUND) return;
        try check("deleting", sub, status);
    }

    /// Deletes the key `sub`, which has no keys of its own.
    pub fn deleteKey(k: Key, arena: Allocator, sub: []const u8) !void {
        const status = win32.RegDeleteKeyW(k.handle, try win32.wide(arena, sub));
        if (status != win32.ERROR_FILE_NOT_FOUND) try check("deleting", sub, status);
    }

    /// Copies the values and keys of `src` into `k`, value by value, keeping
    /// their types; what `k` has already stays, unless `src` has a value of
    /// the same name. (RegCopyTree can't copy into a hive RegLoadAppKey
    /// loaded: it's refused, see docs/findings.md.) `src` needs KEY_READ.
    pub fn copyFrom(k: Key, arena: Allocator, src: Key) !void {
        var max_name: win32.DWORD = 0;
        var max_data: win32.DWORD = 0;
        try check("reading", "a key", win32.RegQueryInfoKeyW(src.handle, null, null, null, null, null, null, null, &max_name, &max_data, null, null));
        // In characters, without the terminator.
        const name = try arena.alloc(u16, max_name + 1);
        const data = try arena.alloc(u8, @max(max_data, 1));
        var index: win32.DWORD = 0;
        while (true) : (index += 1) {
            var name_len: win32.DWORD = @intCast(name.len);
            var data_len: win32.DWORD = @intCast(data.len);
            var kind: win32.DWORD = 0;
            const status = win32.RegEnumValueW(src.handle, index, name.ptr, &name_len, null, &kind, data.ptr, &data_len);
            if (status == win32.ERROR_NO_MORE_ITEMS) break;
            try check("reading", "a value", status);
            name[name_len] = 0;
            const name_z: [*:0]const u16 = @ptrCast(name.ptr);
            try check("copying", "a value", win32.RegSetValueExW(k.handle, if (name_len == 0) null else name_z, 0, kind, data.ptr, data_len));
        }
        for (try src.subKeys(arena)) |sub| {
            const from = try open(arena, src.handle, sub, win32.KEY_READ) orelse continue;
            defer from.close();
            const to: Key = try .createWith(arena, k.handle, sub, win32.KEY_ALL_ACCESS);
            defer to.close();
            try to.copyFrom(arena, from);
        }
    }

    fn check(doing: []const u8, what: []const u8, status: win32.LSTATUS) !void {
        if (status == win32.ERROR_SUCCESS) return;
        return fail("{s} {s} in the registry: error {d} ({s})", .{ doing, what, status, win32.errorName(status) });
    }
};

test "copyFrom keeps every value type, the default value and subkeys" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try std.fmt.allocPrint(arena, "Software\\ZigsawTest\\regkey-{d}", .{std.os.windows.GetCurrentProcessId()});
    const root: Key = try .createWith(arena, win32.HKEY_CURRENT_USER, path, win32.KEY_ALL_ACCESS);
    defer {
        root.close();
        _ = win32.RegDeleteTreeW(win32.HKEY_CURRENT_USER, win32.wide(arena, path) catch unreachable);
        _ = win32.RegDeleteKeyW(win32.HKEY_CURRENT_USER, win32.wide(arena, "Software\\ZigsawTest") catch unreachable);
    }
    const src: Key = try .createWith(arena, root.handle, "src\\deep\\er", win32.KEY_ALL_ACCESS);
    src.close();
    const top = (try Key.open(arena, root.handle, "src", win32.KEY_ALL_ACCESS)).?;
    defer top.close();
    try top.setString(arena, null, "default");
    try top.setString(arena, "string", "välue");
    const dword: u32 = 7;
    _ = win32.RegSetValueExW(top.handle, std.unicode.utf8ToUtf16LeStringLiteral("dword"), 0, 4, std.mem.asBytes(&dword), 4);
    _ = win32.RegSetValueExW(top.handle, std.unicode.utf8ToUtf16LeStringLiteral("empty"), 0, 3, null, 0);

    const dest: Key = try .createWith(arena, root.handle, "dest", win32.KEY_ALL_ACCESS);
    defer dest.close();
    try dest.copyFrom(arena, top);
    try std.testing.expectEqualStrings("default", (try dest.getString(arena, "")).?);
    try std.testing.expectEqualStrings("välue", (try dest.getString(arena, "string")).?);
    var got: u32 = 0;
    var size: win32.DWORD = 4;
    try std.testing.expectEqual(0, win32.RegQueryValueExW(dest.handle, std.unicode.utf8ToUtf16LeStringLiteral("dword"), null, null, std.mem.asBytes(&got), &size));
    try std.testing.expectEqual(7, got);
    try std.testing.expect(try Key.exists(arena, dest.handle, "deep\\er"));
    size = 99;
    var kind: win32.DWORD = 0;
    try std.testing.expectEqual(0, win32.RegQueryValueExW(dest.handle, std.unicode.utf8ToUtf16LeStringLiteral("empty"), null, &kind, null, &size));
    try std.testing.expectEqual(3, kind);
    try std.testing.expectEqual(0, size);
}
