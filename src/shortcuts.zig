//! Start menu shortcuts: what Flatpak's exported .desktop files are on
//! Linux. Each shortcut an app's config declares becomes `<name>.lnk` in a
//! "Zigsaw" folder of the user's Start menu, running one of the app's exports
//! through its shim in `<root>\bin`, and they are synced with the shims.
//!
//! Only the default store (%LOCALAPPDATA%\zigsaw) adds to the Start menu;
//! ZIGSAW_SHORTCUTS_DIR names another folder, for any store. A shortcut
//! whose target is a shim in this store's bin belongs to the app that shim's
//! sidecar names; zigsaw leaves every other .lnk in the folder alone.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Sidecar = @import("Sidecar.zig");
const environment = @import("environment.zig");
const oci = @import("oci.zig");
const win32 = @import("win32.zig");
const note = Context.note;

pub const extension = ".lnk";

/// Where the store's shortcuts go, or null if it gets none.
pub fn dir(ctx: *Context) !?[]const u8 {
    const arena = ctx.arena;
    switch (choose(ctx.env.get("ZIGSAW_SHORTCUTS_DIR"), ctx.env.get("LOCALAPPDATA"), ctx.store.root)) {
        .none => return null,
        .override => |d| return d,
        .start_menu => {
            var programs: ?win32.LPWSTR = null;
            if (win32.SHGetKnownFolderPath(&win32.FOLDERID_Programs, 0, null, &programs) != win32.S_OK) return null;
            defer win32.CoTaskMemFree(programs);
            const path = try std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.span(programs.?));
            return try std.fs.path.join(arena, &.{ path, "Zigsaw" });
        },
    }
}

const Choice = union(enum) { none, override: []const u8, start_menu };

fn choose(override: ?[]const u8, local_app_data: ?[]const u8, root: []const u8) Choice {
    if (override) |d| if (d.len > 0) return .{ .override = d };
    const local = local_app_data orelse return .none;
    const want = std.mem.trimEnd(u8, root, "\\/");
    const base = std.mem.trimEnd(u8, local, "\\/");
    if (want.len != base.len + "\\zigsaw".len) return .none;
    if (!std.os.windows.eqlIgnoreCaseWtf8(want[0..base.len], base)) return .none;
    if (!std.os.windows.eqlIgnoreCaseWtf8(want[base.len..], "\\zigsaw")) return .none;
    return .start_menu;
}

test choose {
    const local = "C:\\Users\\me\\AppData\\Local";
    try std.testing.expectEqual(Choice.start_menu, choose(null, local, "c:\\users\\ME\\AppData\\Local\\Zigsaw\\"));
    try std.testing.expectEqual(Choice.none, choose(null, local, "C:\\Temp\\store"));
    try std.testing.expectEqual(Choice.none, choose(null, local, "C:\\Users\\me\\AppData\\Local\\zigsaw2"));
    try std.testing.expectEqual(Choice.none, choose(null, null, "C:\\Users\\me\\AppData\\Local\\zigsaw"));
    try std.testing.expectEqual(Choice.none, choose("", local, "C:\\Temp\\store"));
    try std.testing.expectEqualStrings("D:\\links", choose("D:\\links", local, "C:\\Temp\\store").override);
}

/// A shortcut in the folder that belongs to this store.
const Owned = struct {
    /// Its file name without .lnk: the name it shows.
    name: []const u8,
    /// The app whose shim it runs; null if that shim is gone.
    app: ?[]const u8,
};

/// The store's shortcuts in `folder`.
fn listOwned(ctx: *Context, com: *Com, folder: []const u8) ![]Owned {
    const io = ctx.io;
    const arena = ctx.arena;
    var d = Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => |e| return e,
    };
    defer d.close(io);
    const bin = try ctx.store.path(arena, &.{"bin"});
    var owned: std.ArrayList(Owned) = .empty;
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.name, extension)) continue;
        const lnk = try std.fs.path.join(arena, &.{ folder, entry.name });
        const target = com.target(arena, lnk) catch continue;
        const shim = shimName(target, bin) orelse continue;
        const sidecar_path = try std.fmt.allocPrint(arena, "{s}\\{s}{s}", .{ bin, shim, Sidecar.extension });
        const app: ?[]const u8 = app: {
            const bytes = Io.Dir.cwd().readFileAlloc(io, sidecar_path, arena, .limited(64 * 1024)) catch break :app null;
            const sidecar = Sidecar.parse(bytes) catch break :app null;
            break :app sidecar.app;
        };
        try owned.append(arena, .{ .name = try arena.dupe(u8, entry.name[0 .. entry.name.len - extension.len]), .app = app });
    }
    return owned.items;
}

/// The shim a shortcut's target is, if it's `<bin>\<name>.exe`.
fn shimName(target: []const u8, bin: []const u8) ?[]const u8 {
    const parent = std.fs.path.dirname(target) orelse return null;
    if (!std.os.windows.eqlIgnoreCaseWtf8(std.mem.trimEnd(u8, parent, "\\/"), std.mem.trimEnd(u8, bin, "\\/"))) return null;
    const base = std.fs.path.basename(target);
    if (!std.ascii.endsWithIgnoreCase(base, ".exe")) return null;
    return base[0 .. base.len - ".exe".len];
}

test shimName {
    const bin = "C:\\z\\bin";
    try std.testing.expectEqualStrings("gtk4-demo", shimName("c:\\Z\\bin\\gtk4-demo.exe", bin).?);
    try std.testing.expectEqual(null, shimName("C:\\z\\bin\\sub\\a.exe", bin));
    try std.testing.expectEqual(null, shimName("C:\\other\\a.exe", bin));
    try std.testing.expectEqual(null, shimName("C:\\z\\bin\\a.cmd", bin));
}

/// Makes the app's shortcuts match its config: writes those it declares, for
/// exports it owns, and removes those it no longer declares. Its layers are
/// deployed where `placeholders` say, and its shims synced; the caller holds
/// the shims' lock.
pub fn sync(ctx: *Context, config: oci.AppConfig, placeholders: oci.Placeholders) !void {
    const arena = ctx.arena;
    const declared: std.StringArrayHashMapUnmanaged(oci.Shortcut) = if (config.shortcuts) |s| s.map else .empty;
    const folder = try dir(ctx) orelse {
        if (declared.count() > 0) note("  shortcut none: only the default store adds to the Start menu (or set ZIGSAW_SHORTCUTS_DIR)", .{});
        return;
    };
    var com: Com = try .init();
    defer com.deinit();
    const owned = try listOwned(ctx, &com, folder);
    const bin = try ctx.store.path(arena, &.{"bin"});

    var written: std.ArrayList([]const u8) = .empty;
    for (declared.keys(), declared.values()) |name, shortcut| {
        // The shortcut runs the export's shim, if the app got it.
        const sidecar_path = try std.fmt.allocPrint(arena, "{s}\\{s}{s}", .{ bin, shortcut.command, Sidecar.extension });
        const owner = owner: {
            const bytes = Io.Dir.cwd().readFileAlloc(ctx.io, sidecar_path, arena, .limited(64 * 1024)) catch break :owner null;
            break :owner (Sidecar.parse(bytes) catch break :owner null).app;
        };
        if (owner == null or !std.mem.eql(u8, owner.?, config.id)) {
            note("warning: no shortcut \"{s}\": {s} runs {s}, which {s} provides", .{ name, name, shortcut.command, owner orelse "no app" });
            continue;
        }
        const lnk = try std.fmt.allocPrint(arena, "{s}\\{s}{s}", .{ folder, name, extension });
        if (findOwned(owned, name)) |o| {
            if (o.app != null and !std.mem.eql(u8, o.app.?, config.id)) {
                note("warning: no shortcut \"{s}\": {s} has one by that name", .{ name, o.app.? });
                continue;
            }
        } else if (Io.Dir.cwd().access(ctx.io, lnk, .{})) |_| {
            note("warning: no shortcut \"{s}\": {s} is there already, and isn't zigsaw's", .{ name, lnk });
            continue;
        } else |_| {}

        const export_command = try placeholders.commandPath(arena, config.exports.map.get(shortcut.command).?.command);
        const icon = if (shortcut.icon) |i| try placeholders.commandPath(arena, i) else export_command;
        // Started from the Start menu, the app's working directory is its
        // home in its data directory, as with `zigsaw run`; the shortcut's
        // own would otherwise be System32.
        const home = (try environment.Profile.init(arena, placeholders.data)).home;
        try Io.Dir.cwd().createDirPath(ctx.io, home);
        try Io.Dir.cwd().createDirPath(ctx.io, folder);
        try com.write(arena, lnk, .{
            .target = try std.fmt.allocPrint(arena, "{s}\\{s}.exe", .{ bin, shortcut.command }),
            .working_dir = home,
            .description = shortcut.description orelse "",
            .icon = icon,
        });
        try written.append(arena, name);
    }

    var removed: std.ArrayList([]const u8) = .empty;
    for (owned) |o| {
        // A shortcut whose shim is gone belongs to no app any more.
        const app = o.app orelse {
            try deleteLnk(ctx, folder, o.name);
            continue;
        };
        if (!std.mem.eql(u8, app, config.id) or declaredName(declared, o.name)) continue;
        try deleteLnk(ctx, folder, o.name);
        try removed.append(arena, o.name);
    }
    if (written.items.len > 0) note("  shortcut {s} (in {s})", .{ try std.mem.join(arena, ", ", written.items), folder });
    if (removed.items.len > 0) note("  removed shortcut {s}", .{try std.mem.join(arena, ", ", removed.items)});
}

/// Removes the app's shortcuts and returns their names. Run before its shims
/// go, which say which app a shortcut belongs to; the caller holds the
/// shims' lock.
pub fn removeAll(ctx: *Context, app: []const u8) ![]const []const u8 {
    const folder = try dir(ctx) orelse return &.{};
    var com: Com = try .init();
    defer com.deinit();
    var removed: std.ArrayList([]const u8) = .empty;
    for (try listOwned(ctx, &com, folder)) |o| {
        const owner = o.app orelse continue;
        if (!std.mem.eql(u8, owner, app)) continue;
        try deleteLnk(ctx, folder, o.name);
        try removed.append(ctx.arena, o.name);
    }
    return removed.items;
}

/// The names of the app's shortcuts, for `zigsaw list`.
pub fn names(ctx: *Context, app: []const u8) ![]const []const u8 {
    const folder = try dir(ctx) orelse return &.{};
    var com: Com = try .init();
    defer com.deinit();
    var found: std.ArrayList([]const u8) = .empty;
    for (try listOwned(ctx, &com, folder)) |o| if (o.app) |owner| if (std.mem.eql(u8, owner, app))
        try found.append(ctx.arena, o.name);
    return found.items;
}

/// Deletes a shortcut, and the folder if it's empty then, so the Start menu
/// isn't left with an empty Zigsaw folder.
fn deleteLnk(ctx: *Context, folder: []const u8, name: []const u8) !void {
    const p = try std.fmt.allocPrint(ctx.arena, "{s}\\{s}{s}", .{ folder, name, extension });
    Io.Dir.cwd().deleteFile(ctx.io, p) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    Io.Dir.cwd().deleteDir(ctx.io, folder) catch {};
}

fn findOwned(owned: []const Owned, name: []const u8) ?Owned {
    for (owned) |o| if (std.os.windows.eqlIgnoreCaseWtf8(o.name, name)) return o;
    return null;
}

fn declaredName(declared: std.StringArrayHashMapUnmanaged(oci.Shortcut), name: []const u8) bool {
    for (declared.keys()) |k| if (std.os.windows.eqlIgnoreCaseWtf8(k, name)) return true;
    return false;
}

/// COM on this thread, and the shell's link object.
const Com = struct {
    /// Whether this initialised COM, and so uninitialises it.
    initialized: bool,

    fn init() !Com {
        const hr = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED);
        // Another mode on this thread already is fine too.
        return .{ .initialized = hr == win32.S_OK or hr == win32.S_FALSE };
    }

    fn deinit(c: Com) void {
        if (c.initialized) win32.CoUninitialize();
    }

    const Link = struct {
        target: []const u8,
        working_dir: []const u8,
        description: []const u8,
        icon: []const u8,
    };

    fn create() !struct { link: *win32.IShellLinkW, file: *win32.IPersistFile } {
        var obj: ?*anyopaque = null;
        try check(win32.CoCreateInstance(&win32.CLSID_ShellLink, null, win32.CLSCTX_INPROC_SERVER, &win32.IID_IShellLinkW, &obj));
        const link: *win32.IShellLinkW = @ptrCast(@alignCast(obj.?));
        errdefer _ = link.vtable.Release(link);
        var file: ?*anyopaque = null;
        try check(link.vtable.QueryInterface(link, &win32.IID_IPersistFile, &file));
        return .{ .link = link, .file = @ptrCast(@alignCast(file.?)) };
    }

    fn write(_: *Com, arena: Allocator, path: []const u8, l: Link) !void {
        const o = try create();
        defer _ = o.link.vtable.Release(o.link);
        defer _ = o.file.vtable.Release(o.file);
        try check(o.link.vtable.SetPath(o.link, try win32.wide(arena, l.target)));
        try check(o.link.vtable.SetWorkingDirectory(o.link, try win32.wide(arena, l.working_dir)));
        try check(o.link.vtable.SetDescription(o.link, try win32.wide(arena, l.description)));
        try check(o.link.vtable.SetIconLocation(o.link, try win32.wide(arena, l.icon), 0));
        try check(o.file.vtable.Save(o.file, try win32.wide(arena, path), win32.TRUE));
    }

    /// The path a shortcut runs.
    fn target(_: *Com, arena: Allocator, path: []const u8) ![]const u8 {
        const o = try create();
        defer _ = o.link.vtable.Release(o.link);
        defer _ = o.file.vtable.Release(o.file);
        try check(o.file.vtable.Load(o.file, try win32.wide(arena, path), win32.STGM_READ));
        var buf: [32 * 1024]u16 = undefined;
        try check(o.link.vtable.GetPath(o.link, &buf, buf.len, null, win32.SLGP_RAWPATH));
        return std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.sliceTo(&buf, 0));
    }

    fn check(hr: win32.HRESULT) !void {
        if (hr < 0) return error.ComFailed;
    }
};
