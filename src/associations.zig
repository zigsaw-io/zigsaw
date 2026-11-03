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
//! URL schemes, what x-scheme-handler is in those lines, are registered the
//! same way, with a shim that takes one URL and is granted nothing:
//!
//!   HKCU\Software\Classes\Zigsaw.<app id>.url.<scheme>   the app's way to open
//!       them: "<root>\open\<app id>\urls\<export>.exe" "%1"
//!   HKCU\Software\Classes\<scheme>   the same, for Windows to find, if nothing
//!       else has the scheme (HKEY_CLASSES_ROOT has no such key). If something
//!       does, as for http, it stays as it is, and the app is only offered.
//!
//! An app with either is listed in Settings' Default apps, where the user can
//! choose it:
//!
//!   HKCU\Software\RegisteredApplications\Zigsaw.<app id>   names the next
//!   HKCU\Software\Zigsaw\Apps\<app id>\Capabilities        what it opens
//!
//! Like shortcuts, only the default store (%LOCALAPPDATA%\zigsaw) registers;
//! ZIGSAW_CLASSES_KEY names another key under HKCU to use in place of
//! Software\Classes, for any store, and has the Default apps keys inside it,
//! unless it's Software\Classes itself. A key belongs to the store its
//! ZigsawStore value names, and zigsaw leaves every other key alone, except a
//! scheme's that names a program in this store's deployments, as only an app
//! that registered itself from inside a run writes: it starts the app with
//! no zigsaw in the way, and stops working when the app is updated.

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
const scheme_value = "ZigsawScheme";
/// Where the shims of an app's schemes are, in its directory of them.
const urls_dir = "urls";

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

/// The name of the key that says how an app opens links of a scheme. An
/// extension can't have a '.' in it, so this can't be an extension's.
fn schemeProgId(arena: Allocator, app: []const u8, scheme: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, prefix ++ "{s}.url.{s}", .{ app, scheme });
}

/// Makes what's registered for the app match its config: registers the
/// extensions and schemes it declares, and removes those it no longer does,
/// with the shims they run. Its layers are deployed where `placeholders` say;
/// the caller holds the shims' lock.
pub fn sync(ctx: *Context, config: oci.AppConfig, placeholders: oci.Placeholders) !void {
    const arena = ctx.arena;
    const declared: std.StringArrayHashMapUnmanaged(oci.Association) = if (config.associations) |a| a.map else .empty;
    const declared_schemes: std.StringArrayHashMapUnmanaged(oci.Scheme) = if (config.schemes) |s| s.map else .empty;
    const opens_any = declared.count() + declared_schemes.count() > 0;
    const dir = try ctx.store.openDir(arena, config.id);
    const classes_path = classesKey(ctx) orelse {
        if (opens_any) note("  opens    nothing: only the default store registers file types and links (or set ZIGSAW_CLASSES_KEY)", .{});
        // Shims that nothing registered runs.
        return removeAllShims(ctx, dir);
    };
    // An app that opens nothing leaves the registry as it is, down to not
    // making the classes' key.
    var classes: Key = if (opens_any)
        try .create(arena, win32.HKEY_CURRENT_USER, classes_path)
    else
        try Key.open(arena, win32.HKEY_CURRENT_USER, classes_path, win32.KEY_READ | win32.KEY_WRITE) orelse
            return removeAllShims(ctx, dir);
    defer classes.close();
    const owned = try listOwned(ctx, classes);
    const owned_schemes = try listOwnedSchemes(ctx, classes);

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

    // The schemes: one shim per export, which takes links of its schemes.
    const urls = try std.fs.path.join(arena, &.{ dir, urls_dir });
    var url_shims: std.ArrayList([]const u8) = .empty;
    var opened: std.ArrayList([]const u8) = .empty;
    var offered: std.ArrayList([]const u8) = .empty;
    for (declared_schemes.values()) |scheme| {
        if (containsIgnoreCase(url_shims.items, scheme.command)) continue;
        var of_command: std.ArrayList([]const u8) = .empty;
        for (declared_schemes.keys(), declared_schemes.values()) |n, s| if (std.mem.eql(u8, s.command, scheme.command)) try of_command.append(arena, n);
        const target = try placeholders.commandPath(arena, config.exports.map.get(scheme.command).?.command);
        const kind = exports.shimKind(ctx.io, target);
        const shim_exe = shim_exes.getPtr(kind);
        if (shim_exe.* == null) shim_exe.* = try exports.shimExe(ctx, zigsaw, kind);
        try Io.Dir.cwd().createDirPath(ctx.io, urls);
        exports.writeShimIn(ctx, urls, scheme.command, shim_exe.*.?, .{
            .zigsaw = zigsaw,
            .home = ctx.store.root,
            .app = config.id,
            .command = scheme.command,
            .gui = kind == .gui,
            .schemes = try std.mem.join(arena, ",", of_command.items),
        }) catch |err|
            return fail("writing the shim that opens links of {s} in {s} (is it running?): {t}", .{ scheme.command, urls, err });
        try url_shims.append(arena, scheme.command);
    }
    for (declared_schemes.keys(), declared_schemes.values()) |name, scheme| {
        const target = try placeholders.commandPath(arena, config.exports.map.get(scheme.command).?.command);
        const shown = shownAs(config, scheme.command);
        const direct = try registerScheme(ctx, classes, .{
            .prog_id = try schemeProgId(arena, config.id, name),
            .app = config.id,
            .scheme = name,
            .description = scheme.description,
            .icon = if (scheme.icon) |i| try placeholders.commandPath(arena, i) else target,
            .shim = try std.fmt.allocPrint(arena, "{s}\\{s}.exe", .{ urls, scheme.command }),
            .app_name = shown.name,
            .app_icon = if (shown.icon) |i| try placeholders.commandPath(arena, i) else target,
        });
        try (if (direct) &opened else &offered).append(arena, try std.fmt.allocPrint(arena, "{s}:", .{name}));
    }
    for (owned_schemes) |o| {
        if (!std.mem.eql(u8, o.app, config.id) or declared_schemes.contains(o.scheme)) continue;
        try unregisterScheme(ctx, classes, o);
        try removed.append(arena, try std.fmt.allocPrint(arena, "{s}:", .{o.scheme}));
    }
    try removeShimsExcept(ctx, urls, url_shims.items);
    // After the shims in it, as it's empty only then.
    if (shims.items.len == 0 and url_shims.items.len == 0) Io.Dir.cwd().deleteDir(ctx.io, dir) catch {};

    try syncCapabilities(ctx, classes_path, config, placeholders);

    const opens = try std.mem.concat(arena, []const u8, &.{ written.items, opened.items });
    if (opens.len > 0) note("  opens    {s}", .{try std.mem.join(arena, ", ", opens)});
    if (offered.items.len > 0) note("  offered  for {s}, which something else has: choose it in Settings > Default apps", .{try std.mem.join(arena, ", ", offered.items)});
    if (removed.items.len > 0) note("  no longer opens {s}", .{try std.mem.join(arena, ", ", removed.items)});
    if (opens.len + offered.items.len + removed.items.len > 0) changed(classes_path);
}

/// Removes what's registered for the app, and its shims, and returns the
/// extensions and schemes. The caller holds the shims' lock.
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
        for (try listOwnedSchemes(ctx, classes)) |o| {
            if (!std.mem.eql(u8, o.app, app)) continue;
            try unregisterScheme(ctx, classes, o);
            try removed.append(arena, try std.fmt.allocPrint(arena, "{s}:", .{o.scheme}));
        }
        try removeCapabilities(arena, classes_path, app);
        try removeStale(ctx, classes);
        if (removed.items.len > 0) changed(classes_path);
    }
    // One that's running stays, for `zigsaw prune`.
    Store.deleteTree(ctx.io, arena, try ctx.store.openDir(arena, app)) catch {};
    return removed.items;
}

/// Removes the keys of schemes that name a program in this store's
/// deployments, which an app wrote for itself from inside a run (see the top
/// of this file) and none of the installed apps declares: those that do have
/// taken theirs over by now. For `zigsaw repair`, after every app's `sync`,
/// and `zigsaw rm`.
pub fn removeStale(ctx: *Context, classes: Key) !void {
    const arena = ctx.arena;
    for (try classes.subKeys(arena)) |name| {
        if (name.len == 0 or name[0] == '.' or std.ascii.startsWithIgnoreCase(name, prefix)) continue;
        if (!try namesThisStore(ctx, classes, name)) continue;
        try classes.deleteTree(arena, name);
        note("removed the handler of {s}: links, which it started an app's program for directly", .{name});
    }
}

/// `removeStale`, on the store's own classes.
pub fn repair(ctx: *Context) !void {
    const arena = ctx.arena;
    const classes_path = classesKey(ctx) orelse return;
    var classes = try Key.open(arena, win32.HKEY_CURRENT_USER, classes_path, win32.KEY_READ | win32.KEY_WRITE) orelse return;
    defer classes.close();
    try removeStale(ctx, classes);
}

/// Whether the key is a URL scheme's with no owner, whose command runs a
/// program in this store's deployments.
fn namesThisStore(ctx: *Context, classes: Key, name: []const u8) !bool {
    const arena = ctx.arena;
    var key = try Key.open(arena, classes.handle, name, win32.KEY_READ) orelse return false;
    defer key.close();
    if (try key.getString(arena, "URL Protocol") == null) return false;
    if (try key.getString(arena, store_value) != null) return false;
    var command = try Key.open(arena, key.handle, "shell\\open\\command", win32.KEY_READ) orelse return false;
    defer command.close();
    const line = try command.getString(arena, "") orelse return false;
    const deploy = try std.fmt.allocPrint(arena, "{s}\\deploy\\", .{std.mem.trimEnd(u8, ctx.store.root, "\\/")});
    return std.ascii.findIgnoreCase(line, deploy) != null;
}

/// The extensions and schemes registered for the app, for `zigsaw list`.
pub fn names(ctx: *Context, app: []const u8) ![]const []const u8 {
    const arena = ctx.arena;
    const classes_path = classesKey(ctx) orelse return &.{};
    var classes = try Key.open(arena, win32.HKEY_CURRENT_USER, classes_path, win32.KEY_READ) orelse return &.{};
    defer classes.close();
    var found: std.ArrayList([]const u8) = .empty;
    for (try listOwned(ctx, classes)) |o| if (std.mem.eql(u8, o.app, app)) try found.append(arena, o.extension);
    for (try listOwnedSchemes(ctx, classes)) |o| if (std.mem.eql(u8, o.app, app)) try found.append(arena, try std.fmt.allocPrint(arena, "{s}:", .{o.scheme}));
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

/// A scheme's key of the store's.
const OwnedScheme = struct {
    prog_id: []const u8,
    app: []const u8,
    scheme: []const u8,
};

/// The store's scheme keys in `classes`, by the one each has for the app.
fn listOwnedSchemes(ctx: *Context, classes: Key) ![]OwnedScheme {
    const arena = ctx.arena;
    var owned: std.ArrayList(OwnedScheme) = .empty;
    for (try classes.subKeys(arena)) |name| {
        if (!std.ascii.startsWithIgnoreCase(name, prefix)) continue;
        var key = try Key.open(arena, classes.handle, name, win32.KEY_READ) orelse continue;
        defer key.close();
        if (!isStores(ctx, try key.getString(arena, store_value))) continue;
        try owned.append(arena, .{
            .prog_id = name,
            .app = try key.getString(arena, app_value) orelse continue,
            .scheme = try key.getString(arena, scheme_value) orelse continue,
        });
    }
    return owned.items;
}

fn isStores(ctx: *Context, store: ?[]const u8) bool {
    return std.os.windows.eqlIgnoreCaseWtf8(std.mem.trimEnd(u8, store orelse return false, "\\/"), std.mem.trimEnd(u8, ctx.store.root, "\\/"));
}

const SchemeRegistration = struct {
    prog_id: []const u8,
    app: []const u8,
    scheme: []const u8,
    description: ?[]const u8,
    icon: []const u8,
    shim: []const u8,
    app_name: []const u8,
    app_icon: []const u8,
};

/// Writes the app's key for a scheme, and the scheme's own, if it may: it's
/// free, this app's already, or one the app wrote itself from inside a run.
/// Returns whether it wrote that one: whether links open with the app, and
/// not only offer it.
fn registerScheme(ctx: *Context, classes: Key, r: SchemeRegistration) !bool {
    const arena = ctx.arena;
    try classes.deleteTree(arena, r.prog_id);
    try writeSchemeKey(ctx, classes, r.prog_id, r);
    if (!try mayTake(ctx, classes, r.scheme, r.app)) return false;
    try classes.deleteTree(arena, r.scheme);
    try writeSchemeKey(ctx, classes, r.scheme, r);
    return true;
}

fn writeSchemeKey(ctx: *Context, classes: Key, name: []const u8, r: SchemeRegistration) !void {
    const arena = ctx.arena;
    var key: Key = try .create(arena, classes.handle, name);
    defer key.close();
    try key.setString(arena, null, try std.fmt.allocPrint(arena, "URL:{s}", .{r.description orelse r.scheme}));
    // What says it's a scheme, and not a kind of file.
    try key.setString(arena, "URL Protocol", "");
    try key.setString(arena, store_value, ctx.store.root);
    try key.setString(arena, app_value, r.app);
    try key.setString(arena, scheme_value, r.scheme);
    try setIn(arena, key, "DefaultIcon", null, try std.fmt.allocPrint(arena, "{s},0", .{r.icon}));
    try setIn(arena, key, "Application", "ApplicationName", r.app_name);
    try setIn(arena, key, "Application", "ApplicationIcon", try std.fmt.allocPrint(arena, "{s},0", .{r.app_icon}));
    try setIn(arena, key, "shell\\open\\command", null, try std.fmt.allocPrint(arena, "\"{s}\" \"%1\"", .{r.shim}));
}

/// Whether the app may have the scheme's own key.
fn mayTake(ctx: *Context, classes: Key, scheme: []const u8, app: []const u8) !bool {
    const arena = ctx.arena;
    if (try Key.open(arena, classes.handle, scheme, win32.KEY_READ)) |k| {
        var key = k;
        defer key.close();
        if (isStores(ctx, try key.getString(arena, store_value))) {
            const whose = try key.getString(arena, app_value) orelse return false;
            return std.mem.eql(u8, whose, app);
        }
        return namesThisStore(ctx, classes, scheme);
    }
    // In HKEY_LOCAL_MACHINE, as http's is, or in scratch classes the real ones'.
    return !try Key.exists(arena, win32.HKEY_CLASSES_ROOT, scheme);
}

/// Removes a scheme's keys of the app's, the scheme's own if it has it.
fn unregisterScheme(ctx: *Context, classes: Key, o: OwnedScheme) !void {
    const arena = ctx.arena;
    try classes.deleteTree(arena, o.prog_id);
    var key = try Key.open(arena, classes.handle, o.scheme, win32.KEY_READ) orelse return;
    defer key.close();
    if (!isStores(ctx, try key.getString(arena, store_value))) return;
    const whose = try key.getString(arena, app_value) orelse return;
    if (std.mem.eql(u8, whose, o.app)) try classes.deleteTree(arena, o.scheme);
}

const registered_applications = "Software\\RegisteredApplications";
const apps_key = "Software\\Zigsaw\\Apps";

/// Where a store's Default apps keys are: Windows' own, or, for scratch
/// classes, inside them.
const CapabilityKeys = struct {
    registered: []const u8,
    apps: []const u8,

    fn of(arena: Allocator, classes_path: []const u8) !CapabilityKeys {
        if (std.ascii.eqlIgnoreCase(classes_path, default_classes)) return .{ .registered = registered_applications, .apps = apps_key };
        return .{
            .registered = try std.fmt.allocPrint(arena, "{s}\\RegisteredApplications", .{classes_path}),
            .apps = try std.fmt.allocPrint(arena, "{s}\\Apps", .{classes_path}),
        };
    }
};

/// Lists the app in Default apps with what it opens, or not at all if that's
/// nothing, from scratch.
fn syncCapabilities(ctx: *Context, classes_path: []const u8, config: oci.AppConfig, placeholders: oci.Placeholders) !void {
    const arena = ctx.arena;
    const extensions: std.StringArrayHashMapUnmanaged(oci.Association) = if (config.associations) |a| a.map else .empty;
    const schemes: std.StringArrayHashMapUnmanaged(oci.Scheme) = if (config.schemes) |s| s.map else .empty;
    try removeCapabilities(arena, classes_path, config.id);
    if (extensions.count() + schemes.count() == 0) return;

    const keys: CapabilityKeys = try .of(arena, classes_path);
    const command = if (extensions.count() > 0) extensions.values()[0].command else schemes.values()[0].command;
    const shown = shownAs(config, command);
    const icon = if (shown.icon) |i| i else config.exports.map.get(command).?.command;
    const path = try std.fmt.allocPrint(arena, "{s}\\{s}\\Capabilities", .{ keys.apps, config.id });
    var capabilities: Key = try .create(arena, win32.HKEY_CURRENT_USER, path);
    defer capabilities.close();
    const name = config.name orelse shown.name;
    try capabilities.setString(arena, "ApplicationName", name);
    try capabilities.setString(arena, "ApplicationDescription", config.summary orelse name);
    try capabilities.setString(arena, "ApplicationIcon", try std.fmt.allocPrint(arena, "{s},0", .{try placeholders.commandPath(arena, icon)}));
    if (extensions.count() > 0) {
        var files: Key = try .create(arena, capabilities.handle, "FileAssociations");
        defer files.close();
        for (extensions.keys()) |ext| try files.setString(arena, ext, try progId(arena, config.id, ext));
    }
    if (schemes.count() > 0) {
        var urls: Key = try .create(arena, capabilities.handle, "URLAssociations");
        defer urls.close();
        for (schemes.keys()) |scheme| try urls.setString(arena, scheme, try schemeProgId(arena, config.id, scheme));
    }
    var registered: Key = try .create(arena, win32.HKEY_CURRENT_USER, keys.registered);
    defer registered.close();
    try registered.setString(arena, try std.fmt.allocPrint(arena, prefix ++ "{s}", .{config.id}), path);
}

fn removeCapabilities(arena: Allocator, classes_path: []const u8, app: []const u8) !void {
    const keys: CapabilityKeys = try .of(arena, classes_path);
    if (try Key.open(arena, win32.HKEY_CURRENT_USER, keys.registered, win32.KEY_READ | win32.KEY_WRITE)) |k| {
        var registered = k;
        defer registered.close();
        try registered.deleteValue(arena, try std.fmt.allocPrint(arena, prefix ++ "{s}", .{app}));
    }
    var apps = try Key.open(arena, win32.HKEY_CURRENT_USER, keys.apps, win32.KEY_READ | win32.KEY_WRITE) orelse return;
    {
        defer apps.close();
        try apps.deleteTree(arena, app);
        if (!try apps.isEmpty()) return;
    }
    // Windows' list stays, with the others on it; keys of ours go when empty.
    var user: Key = .{ .handle = win32.HKEY_CURRENT_USER };
    try user.deleteKey(arena, keys.apps);
    if (std.mem.eql(u8, keys.apps, apps_key)) {
        var zigsaw = try Key.open(arena, win32.HKEY_CURRENT_USER, "Software\\Zigsaw", win32.KEY_READ) orelse return;
        defer zigsaw.close();
        if (try zigsaw.isEmpty()) try user.deleteKey(arena, "Software\\Zigsaw");
    } else if (try Key.open(arena, win32.HKEY_CURRENT_USER, keys.registered, win32.KEY_READ)) |k| {
        var registered = k;
        defer registered.close();
        if (try registered.isEmpty()) try user.deleteKey(arena, keys.registered);
    }
}

/// Deletes both of the directories of an app's shims. One that's running
/// stays until the next time.
fn removeAllShims(ctx: *Context, dir: []const u8) !void {
    try removeShimsExcept(ctx, try std.fs.path.join(ctx.arena, &.{ dir, urls_dir }), &.{});
    try removeShimsExcept(ctx, dir, &.{});
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
