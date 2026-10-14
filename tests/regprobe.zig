//! Probes what zigsaw needs to keep an app's registry settings with its data
//! (iteration 19, docs/findings.md): an app hive in a directory, copies of a
//! key into it and back, and whether a key in HKCU that zigsaw has labelled
//! low, or granted to an app's capability, can be written from inside the
//! low and AppContainer sandboxes. Built by `zig build regprobe`;
//! tests/regprobe/app.json makes an app of it.
//!
//!   regprobe hive <dir>         at medium integrity, as zigsaw: a hive in <dir>,
//!                               copies of a key into it and out again
//!   regprobe prepare <key> plain|low|<capability name>
//!                               makes HKCU\<key> (with a value) and an
//!                               unprepared HKCU\<key>-plain; labels the
//!                               first low, or grants the capability
//!                               (zigsaw.<app id>) full access to it
//!   regprobe app <key>          inside a run: reads, writes and adds subkeys
//!                               under HKCU\<key>, and tries <key>-plain
//!   regprobe show <key>         prints the tree under HKCU\<key>
//!   regprobe set <key> <name> <value>
//!                               sets a string value in HKCU\<key>
//!   regprobe sleep <seconds>    waits, as a run that goes on
//!   regprobe clean <key>        deletes HKCU\<key> and HKCU\<key>-plain
//!
//! Prints one line per check: `<what> ok` or `<what> error <code> (<name>)`.

const std = @import("std");
const win32 = @import("win32");

const DWORD = win32.DWORD;
const HKEY = win32.HKEY;
const LPCWSTR = win32.LPCWSTR;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

const KEY_ALL_ACCESS: DWORD = 0xF003F;
const KEY_SET_VALUE: DWORD = 0x0002;
const SE_REGISTRY_KEY: c_int = 4;
const REG_EXPAND_SZ: DWORD = 2;
const REG_BINARY: DWORD = 3;
const REG_DWORD: DWORD = 4;
const REG_MULTI_SZ: DWORD = 7;
const REG_QWORD: DWORD = 11;

extern "advapi32" fn RegLoadAppKeyW(file: LPCWSTR, result: *HKEY, access: DWORD, options: DWORD, reserved: DWORD) callconv(.winapi) DWORD;
extern "advapi32" fn RegCopyTreeW(src: HKEY, sub_key: ?LPCWSTR, dest: HKEY) callconv(.winapi) DWORD;
extern "advapi32" fn RegRenameKey(key: HKEY, sub_key: ?LPCWSTR, new_name: LPCWSTR) callconv(.winapi) DWORD;
extern "advapi32" fn RegEnumValueW(key: HKEY, index: DWORD, name: [*]u16, name_len: *DWORD, reserved: ?*DWORD, type: ?*DWORD, data: ?[*]u8, data_len: ?*DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;

var out: *std.Io.Writer = undefined;
var arena: std.mem.Allocator = undefined;

pub fn main(init: std.process.Init) !u8 {
    arena = init.arena.allocator();
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    out = &stdout.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.print("usage: regprobe hive <dir> | prepare <key> plain|low|<capability> | app <key> | show <key> | clean <key>\n", .{});
        return 2;
    }
    const mode = args[1];
    if (std.mem.eql(u8, mode, "hive")) {
        try hive(args[2]);
    } else if (std.mem.eql(u8, mode, "prepare") and args.len == 4) {
        try prepare(args[2], args[3]);
    } else if (std.mem.eql(u8, mode, "app")) {
        try printSelf();
        try app(args[2]);
    } else if (std.mem.eql(u8, mode, "show")) {
        const key = open(win32.HKEY_CURRENT_USER, args[2], win32.KEY_READ) catch {
            try out.print("HKCU\\{s}: error {d} ({s})\n", .{ args[2], last_status, win32.errorName(last_status) });
            return 1;
        };
        try out.print("HKCU\\{s}\n", .{args[2]});
        try show(key, 1);
    } else if (std.mem.eql(u8, mode, "sleep")) {
        // A run that's still going, for tests that end it from outside.
        Sleep(1000 * try std.fmt.parseInt(DWORD, args[2], 10));
    } else if (std.mem.eql(u8, mode, "set")) {
        // set <key> <name> <value>: a string value, as an app saves a setting.
        if (args.len != 5) return 2;
        const key = create(win32.HKEY_CURRENT_USER, args[2]) catch return 1;
        const v = try win32.wide(arena, args[4]);
        try report(try std.fmt.allocPrint(arena, "set {s}", .{args[3]}), win32.RegSetValueExW(key, try win32.wide(arena, args[3]), 0, win32.REG_SZ, @ptrCast(v.ptr), @intCast((v.len + 1) * 2)));
    } else if (std.mem.eql(u8, mode, "clean")) {
        for ([_][]const u8{ args[2], try std.fmt.allocPrint(arena, "{s}-plain", .{args[2]}) }) |key|
            try report(try std.fmt.allocPrint(arena, "delete HKCU\\{s}", .{key}), deleteTree(win32.HKEY_CURRENT_USER, key));
    } else {
        std.debug.print("unknown mode {s}\n", .{mode});
        return 2;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// hive

fn hive(dir: []const u8) !void {
    const file = try std.fs.path.join(arena, &.{ dir, "user.dat" });
    const src_name = "Software\\ZigsawTest\\i19-hive";
    const back_name = "Software\\ZigsawTest\\i19-hive-back";
    _ = deleteTree(win32.HKEY_CURRENT_USER, src_name);
    _ = deleteTree(win32.HKEY_CURRENT_USER, back_name);
    _ = deleteTree(win32.HKEY_CURRENT_USER, "Software\\ZigsawTest\\i19-hive-renamed");

    const src = try create(win32.HKEY_CURRENT_USER, src_name);
    try fill(src);
    const deep = try create(src, "Sub\\Deep");
    try fill(deep);
    _ = win32.RegCloseKey(deep);

    var h: HKEY = undefined;
    var t = GetTickCount64();
    var status = RegLoadAppKeyW(try win32.wide(arena, file), &h, KEY_ALL_ACCESS, 0, 0);
    try report(try std.fmt.allocPrint(arena, "load a new app hive ({d} ms)", .{GetTickCount64() - t}), status);
    if (status != 0) return;
    const in_hive = try create(h, "Software\\7-Zip");
    t = GetTickCount64();
    status = RegCopyTreeW(src, null, in_hive);
    try report(try std.fmt.allocPrint(arena, "copy HKCU key into the hive with RegCopyTree ({d} ms)", .{GetTickCount64() - t}), status);
    t = GetTickCount64();
    status = copyTree(src, in_hive);
    try report(try std.fmt.allocPrint(arena, "copy HKCU key into the hive, value by value ({d} ms)", .{GetTickCount64() - t}), status);
    _ = win32.RegCloseKey(in_hive);

    // A second load while the first is open, as a second run would.
    var h2: HKEY = undefined;
    status = RegLoadAppKeyW(try win32.wide(arena, file), &h2, KEY_ALL_ACCESS, 0, 0);
    try report("load the same hive again while it's loaded", status);
    if (status == 0) {
        const seen = open(h2, "Software\\7-Zip", win32.KEY_READ) catch blk: {
            try report("the second handle sees the copy", last_status);
            break :blk null;
        };
        if (seen) |k| {
            try report("the second handle sees the copy", if (try sameTree(src, k)) 0 else 1);
            _ = win32.RegCloseKey(k);
        }
        _ = win32.RegCloseKey(h2);
    }
    _ = win32.RegCloseKey(h);

    // Unloaded once its last handle closed: load it again from the file.
    status = RegLoadAppKeyW(try win32.wide(arena, file), &h, KEY_ALL_ACCESS, 0, 0);
    try report("load the hive from its file again", status);
    if (status != 0) return;
    const kept = try open(h, "Software\\7-Zip", win32.KEY_READ);
    try report("the hive kept every value type, the default value and subkeys", if (try sameTree(src, kept)) 0 else 1);

    const back = try create(win32.HKEY_CURRENT_USER, back_name);
    status = RegCopyTreeW(kept, null, back);
    try report("copy the hive's key back into HKCU with RegCopyTree", status);
    try report("RegCopyTree's copy back is the same", if (try sameTree(src, back)) 0 else 1);
    _ = win32.RegCloseKey(back);
    _ = deleteTree(win32.HKEY_CURRENT_USER, back_name);
    const again = try create(win32.HKEY_CURRENT_USER, back_name);
    try report("copy the hive's key back into HKCU, value by value", copyTree(kept, again));
    try report("the value-by-value copy back is the same", if (try sameTree(src, again)) 0 else 1);
    _ = win32.RegCloseKey(again);
    _ = win32.RegCloseKey(kept);

    // A key with many values, as an app with a long history might have.
    const big = try create(win32.HKEY_CURRENT_USER, "Software\\ZigsawTest\\i19-hive-big");
    for (0..2000) |i| {
        const name = try win32.wide(arena, try std.fmt.allocPrint(arena, "value{d}", .{i}));
        const data = try win32.wide(arena, try std.fmt.allocPrint(arena, "C:\\Users\\Someone\\Documents\\archive-{d}.7z", .{i}));
        _ = win32.RegSetValueExW(big, name, 0, win32.REG_SZ, @ptrCast(data.ptr), @intCast((data.len + 1) * 2));
    }
    const big_dest = try create(h, "Software\\Big");
    t = GetTickCount64();
    status = copyTree(big, big_dest);
    try report(try std.fmt.allocPrint(arena, "copy 2000 values into the hive, value by value ({d} ms)", .{GetTickCount64() - t}), status);
    _ = win32.RegCloseKey(big_dest);
    _ = win32.RegCloseKey(big);
    _ = win32.RegCloseKey(h);
    _ = deleteTree(win32.HKEY_CURRENT_USER, "Software\\ZigsawTest\\i19-hive-big");

    const parent = try open(win32.HKEY_CURRENT_USER, "Software\\ZigsawTest", KEY_ALL_ACCESS);
    status = RegRenameKey(parent, L("i19-hive-back"), L("i19-hive-renamed"));
    try report("rename a key in HKCU (RegRenameKey)", status);
    _ = win32.RegCloseKey(parent);

    _ = win32.RegCloseKey(src);
    for ([_][]const u8{ src_name, back_name, "Software\\ZigsawTest\\i19-hive-renamed" }) |name| _ = deleteTree(win32.HKEY_CURRENT_USER, name);
}

/// One value of each type, and the key's default value.
fn fill(key: HKEY) !void {
    const sz = L("a string");
    try set(key, "sz", win32.REG_SZ, std.mem.sliceAsBytes(sz[0 .. sz.len + 1]));
    const expand = L("%USERPROFILE%\\x");
    try set(key, "expand", REG_EXPAND_SZ, std.mem.sliceAsBytes(expand[0 .. expand.len + 1]));
    try set(key, "binary", REG_BINARY, &.{ 0, 1, 2, 0xff });
    try set(key, "dword", REG_DWORD, std.mem.asBytes(&@as(u32, 0xdeadbeef)));
    try set(key, "qword", REG_QWORD, std.mem.asBytes(&@as(u64, 0x0123456789abcdef)));
    const multi = L("one\x00two\x00\x00");
    try set(key, "multi", REG_MULTI_SZ, std.mem.sliceAsBytes(multi[0..multi.len]));
    const default = L("the default");
    try set(key, "", win32.REG_SZ, std.mem.sliceAsBytes(default[0 .. default.len + 1]));
}

fn set(key: HKEY, name: []const u8, value_type: DWORD, data: []const u8) !void {
    const status = win32.RegSetValueExW(key, if (name.len == 0) null else try win32.wide(arena, name), 0, value_type, data.ptr, @intCast(data.len));
    if (status != 0) return error.SetValue;
}

/// Copies `src`'s values and subkeys into `dest` through their handles, as
/// RegCopyTree would; returns the first failure.
fn copyTree(src: HKEY, dest: HKEY) DWORD {
    var i: DWORD = 0;
    while (true) : (i += 1) {
        var name: [256]u16 = undefined;
        var name_len: DWORD = name.len;
        var value_type: DWORD = 0;
        var data: [4096]u8 = undefined;
        var data_len: DWORD = data.len;
        const status = RegEnumValueW(src, i, &name, &name_len, null, &value_type, &data, &data_len);
        if (status == win32.ERROR_NO_MORE_ITEMS) break;
        if (status != 0) return status;
        name[name_len] = 0;
        const name_z: [*:0]const u16 = @ptrCast(&name);
        const set_status = win32.RegSetValueExW(dest, if (name_len == 0) null else name_z, 0, value_type, &data, data_len);
        if (set_status != 0) return set_status;
    }
    i = 0;
    while (true) : (i += 1) {
        var name: [256]u16 = undefined;
        var name_len: DWORD = name.len;
        const status = win32.RegEnumKeyExW(src, i, &name, &name_len, null, null, null, null);
        if (status == win32.ERROR_NO_MORE_ITEMS) break;
        if (status != 0) return status;
        name[name_len] = 0;
        const name_z: [*:0]const u16 = @ptrCast(&name);
        var s: HKEY = undefined;
        const opened = win32.RegOpenKeyExW(src, name_z, 0, win32.KEY_READ, &s);
        if (opened != 0) return opened;
        defer _ = win32.RegCloseKey(s);
        var d: HKEY = undefined;
        const created = win32.RegCreateKeyExW(dest, name_z, 0, null, 0, KEY_ALL_ACCESS, null, &d, null);
        if (created != 0) return created;
        defer _ = win32.RegCloseKey(d);
        const copied = copyTree(s, d);
        if (copied != 0) return copied;
    }
    return 0;
}

/// Whether `b` has exactly `a`'s values (types and data) and subkeys.
fn sameTree(a: HKEY, b: HKEY) !bool {
    var a_values: DWORD = 0;
    var b_values: DWORD = 0;
    var a_keys: DWORD = 0;
    var b_keys: DWORD = 0;
    _ = win32.RegQueryInfoKeyW(a, null, null, null, &a_keys, null, null, &a_values, null, null, null, null);
    _ = win32.RegQueryInfoKeyW(b, null, null, null, &b_keys, null, null, &b_values, null, null, null, null);
    if (a_values != b_values or a_keys != b_keys) return false;
    var i: DWORD = 0;
    while (true) : (i += 1) {
        var name: [256]u16 = undefined;
        var name_len: DWORD = name.len;
        var value_type: DWORD = 0;
        var data: [4096]u8 = undefined;
        var data_len: DWORD = data.len;
        const status = RegEnumValueW(a, i, &name, &name_len, null, &value_type, &data, &data_len);
        if (status == win32.ERROR_NO_MORE_ITEMS) break;
        if (status != 0) return false;
        name[name_len] = 0;
        var b_type: DWORD = 0;
        var b_data: [4096]u8 = undefined;
        var b_len: DWORD = b_data.len;
        const name_z: [*:0]const u16 = @ptrCast(&name);
        if (win32.RegQueryValueExW(b, if (name_len == 0) null else name_z, null, &b_type, &b_data, &b_len) != 0) return false;
        if (b_type != value_type or !std.mem.eql(u8, data[0..data_len], b_data[0..b_len])) return false;
    }
    i = 0;
    while (true) : (i += 1) {
        var name: [256]u16 = undefined;
        var name_len: DWORD = name.len;
        const status = win32.RegEnumKeyExW(a, i, &name, &name_len, null, null, null, null);
        if (status == win32.ERROR_NO_MORE_ITEMS) break;
        if (status != 0) return false;
        const sub = try std.unicode.wtf16LeToWtf8Alloc(arena, name[0..name_len]);
        const sa = open(a, sub, win32.KEY_READ) catch return false;
        defer _ = win32.RegCloseKey(sa);
        const sb = open(b, sub, win32.KEY_READ) catch return false;
        defer _ = win32.RegCloseKey(sb);
        if (!try sameTree(sa, sb)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// prepare

fn prepare(key_name: []const u8, how: []const u8) !void {
    const plain_name = try std.fmt.allocPrint(arena, "{s}-plain", .{key_name});
    _ = deleteTree(win32.HKEY_CURRENT_USER, key_name);
    _ = deleteTree(win32.HKEY_CURRENT_USER, plain_name);
    const key = try create(win32.HKEY_CURRENT_USER, key_name);
    const seed = L("1");
    try set(key, "seed", win32.REG_SZ, std.mem.sliceAsBytes(seed[0 .. seed.len + 1]));
    _ = win32.RegCloseKey(key);
    _ = win32.RegCloseKey(try create(win32.HKEY_CURRENT_USER, plain_name));
    const object = try win32.wide(arena, try std.fmt.allocPrint(arena, "CURRENT_USER\\{s}", .{key_name}));

    if (std.mem.eql(u8, how, "plain")) {
        try report("prepare (plain)", 0);
    } else if (std.mem.eql(u8, how, "low")) {
        var low: ?win32.PSID = null;
        if (win32.ConvertStringSidToSidW(L("S-1-16-4096"), &low) == 0) return error.Sid;
        const size = @sizeOf(win32.ACL) + @sizeOf(win32.ACCESS_ALLOWED_ACE) + win32.GetLengthSid(low.?);
        const buf = try arena.alignedAlloc(u8, .of(u64), size);
        const sacl: *win32.ACL = @ptrCast(buf.ptr);
        if (win32.InitializeAcl(sacl, @intCast(size), win32.ACL_REVISION) == 0) return error.Acl;
        if (win32.AddMandatoryAce(sacl, win32.ACL_REVISION, win32.CONTAINER_INHERIT_ACE, win32.SYSTEM_MANDATORY_LABEL_NO_WRITE_UP, low.?) == 0) return error.Acl;
        try report("label the key low (inheritable)", win32.SetNamedSecurityInfoW(object, SE_REGISTRY_KEY, win32.LABEL_SECURITY_INFORMATION, null, null, null, sacl));
    } else {
        var groups: ?[*]win32.PSID = null;
        var group_count: DWORD = 0;
        var sids: ?[*]win32.PSID = null;
        var count: DWORD = 0;
        if (win32.DeriveCapabilitySidsFromName(try win32.wide(arena, how), &groups, &group_count, &sids, &count) == 0 or count == 0) {
            try report("derive the capability SID", win32.GetLastError());
            return;
        }
        var dacl: ?*win32.ACL = null;
        var sd: ?*anyopaque = null;
        const read = win32.GetNamedSecurityInfoW(object, SE_REGISTRY_KEY, win32.DACL_SECURITY_INFORMATION, null, null, &dacl, null, &sd);
        if (read != 0) return report("read the key's DACL", read);
        var entry = [1]win32.EXPLICIT_ACCESS_W{.{
            .grfAccessPermissions = KEY_ALL_ACCESS,
            .grfAccessMode = win32.GRANT_ACCESS,
            .grfInheritance = win32.SUB_CONTAINERS_AND_OBJECTS_INHERIT,
            .Trustee = .{ .ptstrName = sids.?[0] },
        }};
        var new_dacl: ?*win32.ACL = null;
        const merged = win32.SetEntriesInAclW(1, &entry, dacl, &new_dacl);
        if (merged != 0) return report("add the capability's ACE", merged);
        try report(try std.fmt.allocPrint(arena, "grant {s} full access to the key (inheritable)", .{how}), win32.SetNamedSecurityInfoW(object, SE_REGISTRY_KEY, win32.DACL_SECURITY_INFORMATION, null, null, new_dacl, null));
    }
}

// ---------------------------------------------------------------------------
// app

fn app(key_name: []const u8) !void {
    const plain_name = try std.fmt.allocPrint(arena, "{s}-plain", .{key_name});

    if (open(win32.HKEY_CURRENT_USER, key_name, win32.KEY_READ)) |key| {
        var size: DWORD = 0;
        try report("read the key's value", win32.RegQueryValueExW(key, L("seed"), null, null, null, &size));
        _ = win32.RegCloseKey(key);
    } else |_| try report("open the key to read", last_status);

    if (open(win32.HKEY_CURRENT_USER, key_name, KEY_SET_VALUE)) |key| {
        const v = L("from the app");
        try report("set a value", win32.RegSetValueExW(key, L("written"), 0, win32.REG_SZ, @ptrCast(v), (v.len + 1) * 2));
        try report("delete a value", win32.RegDeleteValueW(key, L("seed")));
        _ = win32.RegCloseKey(key);
    } else |_| try report("open the key to write", last_status);

    // As 7-Zip does: RegCreateKeyEx from HKCU with the whole path.
    for ([_][]const u8{ "FM", "FM\\Columns", "Compression\\Options" }) |sub| {
        const path = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ key_name, sub });
        var key: HKEY = undefined;
        const status = win32.RegCreateKeyExW(win32.HKEY_CURRENT_USER, try win32.wide(arena, path), 0, null, 0, KEY_ALL_ACCESS, null, &key, null);
        try report(try std.fmt.allocPrint(arena, "create {s} with all access", .{sub}), status);
        if (status == 0) {
            try report(try std.fmt.allocPrint(arena, "set a value in {s}", .{sub}), win32.RegSetValueExW(key, L("x"), 0, REG_DWORD, std.mem.asBytes(&@as(u32, 1)), 4));
            _ = win32.RegCloseKey(key);
        }
    }

    // Two missing levels at once, from a handle to the key rather than HKCU.
    if (open(win32.HKEY_CURRENT_USER, key_name, KEY_ALL_ACCESS)) |key| {
        var sub: HKEY = undefined;
        const status = win32.RegCreateKeyExW(key, L("Multi\\Level"), 0, null, 0, KEY_ALL_ACCESS, null, &sub, null);
        try report("create Multi\\Level from a handle to the key", status);
        if (status == 0) _ = win32.RegCloseKey(sub);
        _ = win32.RegCloseKey(key);
    } else |_| try report("open the key with all access", last_status);

    var other: HKEY = undefined;
    const status = win32.RegCreateKeyExW(win32.HKEY_CURRENT_USER, try win32.wide(arena, try std.fmt.allocPrint(arena, "{s}\\FM", .{plain_name})), 0, null, 0, win32.KEY_WRITE, null, &other, null);
    try report("create a subkey of the unprepared key (should fail in a sandbox)", status);
    if (status == 0) _ = win32.RegCloseKey(other);

    if (open(win32.HKEY_CURRENT_USER, "Software", win32.KEY_READ)) |key| {
        var name: [256]u16 = undefined;
        var name_len: DWORD = name.len;
        try report("list HKCU\\Software", win32.RegEnumKeyExW(key, 0, &name, &name_len, null, null, null, null));
        _ = win32.RegCloseKey(key);
    } else |_| try report("open HKCU\\Software to read", last_status);
}

fn printSelf() !void {
    var token: ?win32.HANDLE = null;
    if (win32.OpenProcessToken(win32.GetCurrentProcess(), win32.TOKEN_QUERY, &token) == 0) return out.print("# token unreadable\n", .{});
    defer _ = win32.CloseHandle(token.?);
    var is_ac: DWORD = 0;
    var len: DWORD = 0;
    _ = win32.GetTokenInformation(token.?, win32.TokenIsAppContainer, &is_ac, @sizeOf(DWORD), &len);
    var label: [256]u8 align(@alignOf(win32.TOKEN_MANDATORY_LABEL)) = undefined;
    if (win32.GetTokenInformation(token.?, win32.TokenIntegrityLevel, &label, label.len, &len) == 0) return out.print("# integrity unreadable\n", .{});
    const sid = @as(*const win32.TOKEN_MANDATORY_LABEL, @ptrCast(&label)).Label.Sid;
    const rid = win32.GetSidSubAuthority(sid, win32.GetSidSubAuthorityCount(sid).* - 1).*;
    const level = if (rid < 0x1000) "untrusted" else if (rid < 0x2000) "low" else if (rid < 0x3000) "medium" else if (rid < 0x4000) "high" else "system";
    try out.print("# integrity {s}{s}\n", .{ level, if (is_ac != 0) ", in an AppContainer" else "" });
}

// ---------------------------------------------------------------------------
// show, and helpers

fn show(key: HKEY, depth: usize) !void {
    var i: DWORD = 0;
    while (true) : (i += 1) {
        var name: [256]u16 = undefined;
        var name_len: DWORD = name.len;
        var value_type: DWORD = 0;
        var data: [4096]u8 = undefined;
        var data_len: DWORD = data.len;
        const status = RegEnumValueW(key, i, &name, &name_len, null, &value_type, &data, &data_len);
        if (status != 0) break;
        try out.splatByteAll(' ', depth * 2);
        try out.print("{s} type {d}, {d} bytes\n", .{ try std.unicode.wtf16LeToWtf8Alloc(arena, name[0..name_len]), value_type, data_len });
    }
    i = 0;
    while (true) : (i += 1) {
        var name: [256]u16 = undefined;
        var name_len: DWORD = name.len;
        if (win32.RegEnumKeyExW(key, i, &name, &name_len, null, null, null, null) != 0) break;
        const sub = try std.unicode.wtf16LeToWtf8Alloc(arena, name[0..name_len]);
        try out.splatByteAll(' ', depth * 2);
        try out.print("{s}\\\n", .{sub});
        const child = open(key, sub, win32.KEY_READ) catch continue;
        defer _ = win32.RegCloseKey(child);
        try show(child, depth + 1);
    }
}

fn report(what: []const u8, status: DWORD) !void {
    if (status == 0) {
        try out.print("{s} ok\n", .{what});
    } else {
        try out.print("{s} error {d} ({s})\n", .{ what, status, win32.errorName(status) });
    }
}

fn create(parent: HKEY, sub: []const u8) !HKEY {
    var key: HKEY = undefined;
    const status = win32.RegCreateKeyExW(parent, try win32.wide(arena, sub), 0, null, 0, KEY_ALL_ACCESS, null, &key, null);
    if (status != 0) {
        try report(try std.fmt.allocPrint(arena, "create {s}", .{sub}), status);
        return error.Create;
    }
    return key;
}

fn open(parent: HKEY, sub: []const u8, access: DWORD) !HKEY {
    var key: HKEY = undefined;
    const status = win32.RegOpenKeyExW(parent, try win32.wide(arena, sub), 0, access, &key);
    if (status != 0) {
        last_status = status;
        return error.Status;
    }
    return key;
}
var last_status: DWORD = 0;

fn deleteTree(parent: HKEY, sub: []const u8) DWORD {
    const w = win32.wide(arena, sub) catch return 8;
    const status = win32.RegDeleteTreeW(parent, w);
    if (status != 0) return status;
    return win32.RegDeleteKeyW(parent, w);
}
