//! File associations: what the MimeType lines of Flatpak's exported .desktop
//! files are on Linux. For each extension an app's config declares, zigsaw
//! registers the app as something that opens such files, for the user, which
//! takes no administrator:
//!
//!   HKCU\Software\Classes\Zigsaw.<app id>.<ext>      the app's way to open them:
//!       its name for such files, their icon, and the command
//!       "<root>\open\<app id>\<export>.exe" "%1"
//!   HKCU\Software\Classes\.<ext>\OpenWithProgids     names that key
//!
//! The command is a shim (see shim.zig) that passes the file to
//! `zigsaw run --file`, so the app is granted the file it's asked to open.
//!
//! zigsaw only offers: it doesn't make the app the default for an extension,
//! which is the user's choice, and which Windows protects. Opening a file of
//! a kind nothing else opens asks once whether to use the app.
//!
//! Like shortcuts, only the default store (%LOCALAPPDATA%\zigsaw) registers;
//! ZIGSAW_CLASSES_KEY names another key under HKCU to use in place of
//! Software\Classes, for any store. A key belongs to the store its
//! ZigsawStore value names, and zigsaw leaves every other key alone.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Sidecar = @import("Sidecar.zig");
const Store = @import("Store.zig");
const exports = @import("exports.zig");
const oci = @import("oci.zig");
const shortcuts = @import("shortcuts.zig");
const win32 = @import("win32.zig");
const Key = @import("regkey.zig").Key;
const fail = Context.fail;
const note = Context.note;

const default_classes = "Software\\Classes";
const prefix = "Zigsaw.";
/// The values that say whose a key is, and what for.
const store_value = "ZigsawStore";
const app_value = "ZigsawApp";
const extension_value = "ZigsawExtension";

/// The key under HKCU where the store registers, or null if it doesn't.
fn classesKey(ctx: *Context) ?[]const u8 {
    if (ctx.env.get("ZIGSAW_CLASSES_KEY")) |k| if (k.len > 0) return k;
    return if (shortcuts.isDefaultStore(ctx.env.get("LOCALAPPDATA"), ctx.store.root)) default_classes else null;
}

/// The name of the key that says how an app opens files with an extension.
fn progId(arena: Allocator, app: []const u8, ext: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, prefix ++ "{s}.{s}", .{ app, ext[1..] });
}

test progId {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("Zigsaw.com.github.flxzt.rnote.rnote", try progId(arena_state.allocator(), "com.github.flxzt.rnote", ".rnote"));
}

/// Makes what's registered for the app match its config: registers the
/// extensions it declares, and removes those it no longer does, with the
/// shims they run. Its layers are deployed where `placeholders` say; the
/// caller holds the shims' lock.
pub fn sync(ctx: *Context, config: oci.AppConfig, placeholders: oci.Placeholders) !void {
    const arena = ctx.arena;
    const declared: std.StringArrayHashMapUnmanaged(oci.Association) = if (config.associations) |a| a.map else .empty;
    const dir = try ctx.store.openDir(arena, config.id);
    const classes_path = classesKey(ctx) orelse {
        if (declared.count() > 0) note("  opens    nothing: only the default store registers file types (or set ZIGSAW_CLASSES_KEY)", .{});
        // Shims that nothing registered runs.
        return removeShimsExcept(ctx, dir, &.{});
    };
    // An app that opens nothing leaves the registry as it is, down to not
    // making the classes' key.
    var classes: Key = if (declared.count() > 0)
        try .create(arena, win32.HKEY_CURRENT_USER, classes_path)
    else
        try Key.open(arena, win32.HKEY_CURRENT_USER, classes_path, win32.KEY_READ | win32.KEY_WRITE) orelse
            return removeShimsExcept(ctx, dir, &.{});
    defer classes.close();
    const owned = try listOwned(ctx, classes);

    const zigsaw = try win32.selfExePath(arena);
    var shims: std.ArrayList([]const u8) = .empty;
    var shim_exes: std.EnumArray(exports.ShimKind, ?[]const u8) = .initFill(null);
    var written: std.ArrayList([]const u8) = .empty;
    for (declared.keys(), declared.values()) |ext, association| {
        const target = try placeholders.commandPath(arena, config.exports.map.get(association.command).?.command);
        const shown = shownAs(config, association.command);
        if (!containsIgnoreCase(shims.items, association.command)) {
            const kind = exports.shimKind(ctx.io, target);
            const shim_exe = shim_exes.getPtr(kind);
            if (shim_exe.* == null) shim_exe.* = try exports.shimExe(ctx, zigsaw, kind);
            try Io.Dir.cwd().createDirPath(ctx.io, dir);
            exports.writeShimIn(ctx, dir, association.command, shim_exe.*.?, .{
                .zigsaw = zigsaw,
                .home = ctx.store.root,
                .app = config.id,
                .command = association.command,
                .gui = kind == .gui,
                .files = true,
            }) catch |err|
                return fail("writing the shim that opens {s} files in {s} (is it running?): {t}", .{ ext, dir, err });
            try shims.append(arena, association.command);
        }
        try register(ctx, classes, .{
            .prog_id = try progId(arena, config.id, ext),
            .app = config.id,
            .extension = ext,
            .description = association.description,
            .icon = if (association.icon) |i| try placeholders.commandPath(arena, i) else target,
            .shim = try std.fmt.allocPrint(arena, "{s}\\{s}.exe", .{ dir, association.command }),
            .app_name = shown.name,
            .app_icon = if (shown.icon) |i| try placeholders.commandPath(arena, i) else target,
        });
        try written.append(arena, ext);
    }

    var removed: std.ArrayList([]const u8) = .empty;
    for (owned) |o| {
        if (!std.mem.eql(u8, o.app, config.id) or containsIgnoreCase(declared.keys(), o.extension)) continue;
        try unregister(arena, classes, o);
        try removed.append(arena, o.extension);
    }
    try removeShimsExcept(ctx, dir, shims.items);

    if (written.items.len > 0) note("  opens    {s}", .{try std.mem.join(arena, ", ", written.items)});
    if (removed.items.len > 0) note("  no longer opens {s}", .{try std.mem.join(arena, ", ", removed.items)});
    if (written.items.len + removed.items.len > 0) changed(classes_path);
}

/// Removes what's registered for the app, and its shims, and returns the
/// extensions. The caller holds the shims' lock.
pub fn removeAll(ctx: *Context, app: []const u8) ![]const []const u8 {
    const arena = ctx.arena;
    var removed: std.ArrayList([]const u8) = .empty;
    if (classesKey(ctx)) |classes_path| not_there: {
        var classes = try Key.open(arena, win32.HKEY_CURRENT_USER, classes_path, win32.KEY_READ | win32.KEY_WRITE) orelse break :not_there;
        defer classes.close();
        for (try listOwned(ctx, classes)) |o| {
            if (!std.mem.eql(u8, o.app, app)) continue;
            try unregister(arena, classes, o);
            try removed.append(arena, o.extension);
        }
        if (removed.items.len > 0) changed(classes_path);
    }
    // One that's running stays, for `zigsaw prune`.
    Store.deleteTree(ctx.io, arena, try ctx.store.openDir(arena, app)) catch {};
    return removed.items;
}

/// The extensions registered for the app, for `zigsaw list`.
pub fn names(ctx: *Context, app: []const u8) ![]const []const u8 {
    const arena = ctx.arena;
    const classes_path = classesKey(ctx) orelse return &.{};
    var classes = try Key.open(arena, win32.HKEY_CURRENT_USER, classes_path, win32.KEY_READ) orelse return &.{};
    defer classes.close();
    var found: std.ArrayList([]const u8) = .empty;
    for (try listOwned(ctx, classes)) |o| if (std.mem.eql(u8, o.app, app)) try found.append(arena, o.extension);
    return found.items;
}

/// How the app shows where Windows lists what can open a file: as its
/// shortcut to the same export does, if it has one, or by the export's name
/// and its executable's icon.
fn shownAs(config: oci.AppConfig, command: []const u8) struct { name: []const u8, icon: ?[]const u8 } {
    if (config.shortcuts) |s| for (s.map.keys(), s.map.values()) |name, shortcut|
        if (std.mem.eql(u8, shortcut.command, command)) return .{ .name = name, .icon = shortcut.icon };
    return .{ .name = command, .icon = null };
}

test shownAs {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var config: oci.AppConfig = .{ .id = "x", .version = "1", .command = "a.exe" };
    try std.testing.expectEqualStrings("rnote", shownAs(config, "rnote").name);
    var s: std.json.ArrayHashMap(oci.Shortcut) = .{};
    try s.map.put(arena, "Rnote CLI", .{ .command = "rnote-cli" });
    try s.map.put(arena, "Rnote", .{ .command = "rnote", .icon = "share/rnote.ico" });
    config.shortcuts = s;
    try std.testing.expectEqualStrings("Rnote", shownAs(config, "rnote").name);
    try std.testing.expectEqualStrings("share/rnote.ico", shownAs(config, "rnote").icon.?);
    try std.testing.expectEqual(null, shownAs(config, "rnote-cli").icon);
    try std.testing.expectEqualStrings("other", shownAs(config, "other").name);
}

/// A key in the classes that belongs to this store.
const Owned = struct {
    prog_id: []const u8,
    app: []const u8,
    extension: []const u8,
};

/// The store's keys in `classes`.
fn listOwned(ctx: *Context, classes: Key) ![]Owned {
    const arena = ctx.arena;
    var owned: std.ArrayList(Owned) = .empty;
    for (try classes.subKeys(arena)) |name| {
        if (!std.ascii.startsWithIgnoreCase(name, prefix)) continue;
        var key = try Key.open(arena, classes.handle, name, win32.KEY_READ) orelse continue;
        defer key.close();
        const store = try key.getString(arena, store_value) orelse continue;
        if (!std.os.windows.eqlIgnoreCaseWtf8(std.mem.trimEnd(u8, store, "\\/"), std.mem.trimEnd(u8, ctx.store.root, "\\/"))) continue;
        try owned.append(arena, .{
            .prog_id = name,
            .app = try key.getString(arena, app_value) orelse continue,
            .extension = try key.getString(arena, extension_value) orelse continue,
        });
    }
    return owned.items;
}

const Registration = struct {
    prog_id: []const u8,
    app: []const u8,
    extension: []const u8,
    description: ?[]const u8,
    /// The file with the icon such files show.
    icon: []const u8,
    /// The shim that opens one.
    shim: []const u8,
    /// The app's name and the file with its icon, where Windows lists what
    /// can open such a file.
    app_name: []const u8,
    app_icon: []const u8,
};

/// Writes the app's key for an extension, from scratch, and names it among
/// what opens the extension.
fn register(ctx: *Context, classes: Key, r: Registration) !void {
    const arena = ctx.arena;
    try classes.deleteTree(arena, r.prog_id);
    var key: Key = try .create(arena, classes.handle, r.prog_id);
    defer key.close();
    // Without a name of its own, Explorer calls the file an "<EXT> File".
    if (r.description) |d| try key.setString(arena, null, d);
    try key.setString(arena, store_value, ctx.store.root);
    try key.setString(arena, app_value, r.app);
    try key.setString(arena, extension_value, r.extension);
    try setIn(arena, key, "DefaultIcon", null, try std.fmt.allocPrint(arena, "{s},0", .{r.icon}));
    // Without these, "Open with" would show the shim's file name and its
    // icon: the shim is a copy of zigsaw's, with neither of the app's.
    try setIn(arena, key, "Application", "ApplicationName", r.app_name);
    try setIn(arena, key, "Application", "ApplicationIcon", try std.fmt.allocPrint(arena, "{s},0", .{r.app_icon}));
    try setIn(arena, key, "shell\\open\\command", null, try std.fmt.allocPrint(arena, "\"{s}\" \"%1\"", .{r.shim}));

    var open_with: Key = try .create(arena, classes.handle, try openWithPath(arena, r.extension));
    defer open_with.close();
    try open_with.setString(arena, r.prog_id, "");
}

fn setIn(arena: Allocator, parent: Key, sub: []const u8, name: ?[]const u8, value: []const u8) !void {
    var key: Key = try .create(arena, parent.handle, sub);
    defer key.close();
    try key.setString(arena, name, value);
}

fn openWithPath(arena: Allocator, ext: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}\\OpenWithProgids", .{ext});
}

/// Removes a key of the store's, and its name from what opens its extension;
/// then the extension's own keys, if that leaves them with nothing.
fn unregister(arena: Allocator, classes: Key, o: Owned) !void {
    try classes.deleteTree(arena, o.prog_id);
    if (!oci.isValidExtension(o.extension)) return;
    const open_with_path = try openWithPath(arena, o.extension);
    {
        var open_with = try Key.open(arena, classes.handle, open_with_path, win32.KEY_READ | win32.KEY_WRITE) orelse return;
        defer open_with.close();
        try open_with.deleteValue(arena, o.prog_id);
        if (!try open_with.isEmpty()) return;
    }
    try classes.deleteKey(arena, open_with_path);
    {
        var ext = try Key.open(arena, classes.handle, o.extension, win32.KEY_READ) orelse return;
        defer ext.close();
        if (!try ext.isEmpty()) return;
    }
    try classes.deleteKey(arena, o.extension);
}

/// Deletes the shims in `dir` that aren't for one of `commands`, and `dir`
/// if that empties it. One that's running stays until the next time.
fn removeShimsExcept(ctx: *Context, dir: []const u8, commands: []const []const u8) !void {
    const io = ctx.io;
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (containsIgnoreCase(commands, std.fs.path.stem(entry.name))) continue;
        d.deleteFile(io, entry.name) catch {};
    }
    if (commands.len == 0) Io.Dir.cwd().deleteDir(io, dir) catch {};
}

/// Tells the shell that what opens files changed, so that Explorer shows it
/// without a new sign-in. Only for the classes Windows reads.
fn changed(classes_path: []const u8) void {
    if (!std.ascii.eqlIgnoreCase(classes_path, default_classes)) return;
    win32.SHChangeNotify(win32.SHCNE_ASSOCCHANGED, win32.SHCNF_IDLIST, null, null);
}

fn containsIgnoreCase(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.ascii.eqlIgnoreCase(n, name)) return true;
    return false;
}

test "registry keys: strings round-trip, an emptied extension goes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try std.fmt.allocPrint(arena, "Software\\ZigsawTest\\unit-{d}", .{std.os.windows.GetCurrentProcessId()});
    var classes: Key = try .create(arena, win32.HKEY_CURRENT_USER, path);
    defer {
        classes.close();
        _ = win32.RegDeleteTreeW(win32.HKEY_CURRENT_USER, win32.wide(arena, path) catch unreachable);
        // The key above too, unless another test run has one in it.
        _ = win32.RegDeleteKeyW(win32.HKEY_CURRENT_USER, win32.wide(arena, "Software\\ZigsawTest") catch unreachable);
    }

    try setIn(arena, classes, "Zigsaw.a.note", store_value, "C:\\störe");
    var key = (try Key.open(arena, classes.handle, "Zigsaw.a.note", win32.KEY_READ)).?;
    try std.testing.expectEqualStrings("C:\\störe", (try key.getString(arena, store_value)).?);
    try std.testing.expectEqual(null, try key.getString(arena, "missing"));
    key.close();
    try std.testing.expectEqual(null, try Key.open(arena, classes.handle, "none", win32.KEY_READ));

    // Our name among two, then alone: the extension's keys go only when
    // nothing is left in them.
    const o: Owned = .{ .prog_id = "Zigsaw.a.note", .app = "a", .extension = ".note" };
    try setIn(arena, classes, ".note\\OpenWithProgids", "Zigsaw.a.note", "");
    try setIn(arena, classes, ".note\\OpenWithProgids", "Other.note", "");
    try unregister(arena, classes, o);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{".note"}), try classes.subKeys(arena));
    try setIn(arena, classes, "Zigsaw.a.note", store_value, "x");
    try setIn(arena, classes, ".note\\OpenWithProgids", "Zigsaw.a.note", "");
    var open_with = (try Key.open(arena, classes.handle, ".note\\OpenWithProgids", win32.KEY_READ | win32.KEY_WRITE)).?;
    try open_with.deleteValue(arena, "Other.note");
    open_with.close();
    try unregister(arena, classes, o);
    try std.testing.expectEqual(0, (try classes.subKeys(arena)).len);
}
