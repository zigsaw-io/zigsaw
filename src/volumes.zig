//! Volumes, as Docker has them: folders of files that outlive the data of the
//! apps that use them, and that several apps may share.
//!
//! An app's state is its data directory, and deleting that (`rm
//! --delete-data`, `prune --data`, the end of an `--ephemeral` run) deletes
//! all of it. A mount, `--volume=<source>:<target>`, makes <target>, a path in
//! the app's data directory, a directory junction to the volume's folder (see
//! junction.zig). Windows has no mount namespaces, so a volume can only appear
//! where the app keeps its data; but deleting the data directory stops at the
//! junction, and leaves the volume as it is.
//!
//! The source is either
//! - a named volume: a folder in the store, volumes\<name>\, which the first
//!   run that mounts it makes, or one kept elsewhere, which `zigsaw volume
//!   create --path=<dir> <name>` records in volumes\<name>.json; or
//! - a folder of yours, by its absolute path: a bind mount.
//!
//! Whichever it is, a run grants the folder as it grants a `--filesystem` path
//! (see run.zig and grants.zig): labelled low or given to the app's
//! AppContainer, recorded, and taken back as such grants are. The store is
//! somewhere zigsaw's grants never reach otherwise (grants.Own); a volume's
//! folder in it is the exception.
//!
//! A saved mount (`zigsaw override --volume`) over files the app has at its
//! target moves them into the volume, if the volume is empty, as Docker fills
//! an empty volume from the image. The junctions zigsaw made are listed in
//! grants\<id>.mounts, so that one no saved mount names any more goes when the
//! app's last run ends, as what a command line asked for does.
//!
//! Each run holds volumes\<name>.lock shared while it goes, so that `zigsaw
//! volume rm` and `volume prune` leave a volume in use alone.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");
const acl = @import("acl.zig");
const grants = @import("grants.zig");
const junction = @import("junction.zig");
const oci = @import("oci.zig");
const override = @import("override.zig");
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const fail = Context.fail;
const note = Context.note;
const isWithin = grants.isWithin;

/// Where a mount's files are.
pub const Source = union(enum) {
    /// A named volume.
    name: []const u8,
    /// A folder of the host's, by its absolute path: a bind mount.
    path: []const u8,
};

/// A `--volume` value.
pub const Mount = struct {
    source: Source,
    /// Where it appears: a path in the app's data directory, its parts
    /// separated by '\'.
    target: []const u8,
    read_only: bool = false,

    /// "<source>:<target>", and ":ro" if read-only: how settings keep it.
    pub fn spec(m: Mount, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}:{s}{s}", .{ m.sourceText(), m.target, if (m.read_only) ":ro" else "" });
    }

    fn sourceText(m: Mount) []const u8 {
        return switch (m.source) {
            .name => |n| n,
            .path => |p| p,
        };
    }

    /// For messages: "volume pgdata", or the folder.
    pub fn format(m: Mount, w: *Io.Writer) Io.Writer.Error!void {
        switch (m.source) {
            .name => |n| try w.print("volume {s}", .{n}),
            .path => |p| try w.writeAll(p),
        }
    }

    fn eql(a: Mount, b: Mount) bool {
        const same_kind = std.meta.activeTag(a.source) == std.meta.activeTag(b.source);
        return same_kind and a.read_only == b.read_only and
            std.os.windows.eqlIgnoreCaseWtf8(a.sourceText(), b.sourceText()) and
            std.os.windows.eqlIgnoreCaseWtf8(a.target, b.target);
    }
};

/// A value checked, or why it isn't one, for a message.
pub fn Parsed(comptime T: type) type {
    return union(enum) { ok: T, invalid: []const u8 };
}

const format_hint = "--volume expects <volume or folder>:<path in the app's data>, and :ro to make it read-only, such as pgdata:data or D:\\pgdata:data";

/// Parses a `--volume` value.
pub fn parse(arena: Allocator, value: []const u8) !Parsed(Mount) {
    const parts = split(value) orelse return .{ .invalid = format_hint };
    var rest = parts.rest;
    var read_only = false;
    if (std.mem.endsWith(u8, rest, ":ro")) {
        read_only = true;
        rest = rest[0 .. rest.len - 3];
    } else if (std.mem.endsWith(u8, rest, ":rw")) {
        rest = rest[0 .. rest.len - 3];
    }
    const source: Source = if (isDrivePath(parts.source))
        .{ .path = try normalPath(arena, parts.source) }
    else if (isUncPath(parts.source))
        return .{ .invalid = "a folder on the network can't be mounted: a junction only points into a drive of this machine" }
    else if (nameProblem(parts.source)) |why|
        return .{ .invalid = why }
    else
        .{ .name = parts.source };
    return switch (try parseTarget(arena, rest)) {
        .ok => |t| .{ .ok = .{ .source = source, .target = t, .read_only = read_only } },
        .invalid => |why| .{ .invalid = why },
    };
}

/// A value's source, and what follows its colon; null without a colon.
fn split(value: []const u8) ?struct { source: []const u8, rest: []const u8 } {
    // A drive letter's colon is the path's.
    const from: usize = if (isDrivePath(value)) 2 else 0;
    const colon = std.mem.indexOfScalarPos(u8, value, from, ':') orelse return null;
    if (colon == 0) return null;
    return .{ .source = value[0..colon], .rest = value[colon + 1 ..] };
}

/// The target of a value as settings keep it, which tells mounts apart when
/// settings merge: a later one at the same place replaces an earlier one.
pub fn targetOf(value: []const u8) []const u8 {
    const parts = split(value) orelse return value;
    const rest = parts.rest;
    if (std.mem.endsWith(u8, rest, ":ro") or std.mem.endsWith(u8, rest, ":rw")) return rest[0 .. rest.len - 3];
    return rest;
}

const target_hint = "the path in the app's data must be relative to its data directory, such as data or home\\AppData\\Roaming\\<app>";

/// Checks a target, a path in the app's data directory (`${data}\` before it
/// is allowed), and returns it with '\' between its parts.
pub fn parseTarget(arena: Allocator, raw: []const u8) !Parsed([]const u8) {
    var t = raw;
    for ([_][]const u8{ "${data}\\", "${data}/" }) |prefix| if (std.mem.startsWith(u8, t, prefix)) {
        t = t[prefix.len..];
        break;
    };
    t = std.mem.trimEnd(u8, t, "\\/");
    if (t.len == 0 or isSep(t[0]) or std.mem.indexOfScalar(u8, t, ':') != null) return .{ .invalid = target_hint };
    // Only a leading ${data}\ is; the whole data directory can't be a mount.
    if (std.mem.indexOf(u8, t, "${") != null) return .{ .invalid = target_hint };
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitAny(u8, t, "\\/");
    while (it.next()) |part| {
        if (!isValidPart(part)) return .{ .invalid = try std.fmt.allocPrint(arena, "\"{s}\" can't be part of a path in the app's data", .{part}) };
        try parts.append(arena, part);
    }
    const target = try std.mem.join(arena, "\\", parts.items);
    for (reserved) |r| if (overlaps(target, r))
        return .{ .invalid = try std.fmt.allocPrint(arena, "{s} can't hold a volume: zigsaw keeps {s} in the app's data", .{ target, r }) };
    for (std.enums.values(oci.UserFolder)) |f| {
        const link = try std.fmt.allocPrint(arena, "home\\{t}", .{f});
        if (overlaps(target, link))
            return .{ .invalid = try std.fmt.allocPrint(arena, "{s} can't hold a volume: the app finds your {t} folder at {s}", .{ target, f, link }) };
    }
    return .{ .ok = target };
}

/// What zigsaw makes in a data directory, which no mount may be, hold, or be
/// in: the hive of the keys the app keeps (hkcu.zig), the temporary
/// directory, an AppContainer's own under Packages, and where file dialogs
/// keep Quick access (run.zig). The user's folders are below.
const reserved = [_][]const u8{
    "registry",
    "home\\AppData\\Local\\Temp",
    "home\\AppData\\Local\\Packages",
    "home\\AppData\\Roaming\\Microsoft\\Windows\\Recent\\AutomaticDestinations",
};

/// Whether one of two paths in a data directory is, or is in, the other.
fn overlaps(a: []const u8, b: []const u8) bool {
    return isWithin(a, b) or isWithin(b, a);
}

/// Fails unless the mounts' targets are apart: a junction in another
/// mount's folder would be in the volume.
fn checkApart(id: []const u8, mounts: []const Mount) !void {
    for (mounts, 0..) |m, i| for (mounts[0..i]) |earlier| if (overlaps(m.target, earlier.target))
        return fail("{s}'s mounts at {s} and {s} overlap: give each its own place in the app's data", .{ id, earlier.target, m.target });
}

/// Why `name` can't be a volume's, if it can't. A name has no dots, so that
/// the files beside the volumes, <name>.json and <name>.lock, can never be
/// one.
fn nameProblem(name: []const u8) ?[]const u8 {
    if (std.mem.indexOfAny(u8, name, "\\/") != null)
        return "a folder of yours is given by its absolute path, such as D:\\pgdata; a volume by its name";
    const rule = "a volume's name has 2 to 64 letters, digits, '_' and '-', and starts with a letter or digit";
    if (name.len < 2 or name.len > 64 or !std.ascii.isAlphanumeric(name[0])) return rule;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return rule;
    if (isDeviceName(name)) return "a volume can't have the name of a Windows device, such as CON or NUL";
    if (std.ascii.eqlIgnoreCase(name, "cwd") or oci.UserFolder.parse(name) != null)
        return "cwd and the names of your folders are --filesystem's: give the volume another name";
    return null;
}

pub fn isValidName(name: []const u8) bool {
    return nameProblem(name) == null;
}

/// A part of a path that Windows takes as a file's name.
fn isValidPart(part: []const u8) bool {
    if (part.len == 0 or part.len > 255 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    for (part) |c| if (c < 0x20 or std.mem.indexOfScalar(u8, "<>:\"|?*", c) != null) return false;
    if (part[part.len - 1] == '.' or part[part.len - 1] == ' ') return false;
    const stem = part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len];
    return !isDeviceName(stem);
}

fn isDeviceName(s: []const u8) bool {
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL" }) |d| if (std.ascii.eqlIgnoreCase(s, d)) return true;
    if (s.len == 4 and std.ascii.isDigit(s[3]))
        for ([_][]const u8{ "COM", "LPT" }) |d| if (std.ascii.eqlIgnoreCase(s[0..3], d)) return true;
    return false;
}

fn isSep(c: u8) bool {
    return c == '\\' or c == '/';
}

/// "D:\..." or "D:/...".
fn isDrivePath(p: []const u8) bool {
    return p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and isSep(p[2]);
}

fn isUncPath(p: []const u8) bool {
    return p.len >= 2 and isSep(p[0]) and isSep(p[1]);
}

/// With '\' for '/', and no separator at the end but a drive root's.
fn normalPath(arena: Allocator, p: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, p);
    std.mem.replaceScalar(u8, out, '/', '\\');
    const trimmed = std.mem.trimEnd(u8, out, "\\");
    return if (trimmed.len <= 2) out[0..3] else trimmed;
}

// ---------------------------------------------------------------------------
// Named volumes

pub const Volume = struct {
    name: []const u8,
    /// Its folder.
    path: []const u8,
    /// Kept outside the store (`volume create --path`): `volume rm` forgets
    /// it, and never deletes its files.
    external: bool,

    /// For messages: "in the store" or where it's kept.
    pub fn format(v: Volume, w: *Io.Writer) Io.Writer.Error!void {
        if (v.external) try w.print("kept in {s}", .{v.path}) else try w.print("in the store, {s}", .{v.path});
    }
};

/// The record of a volume kept elsewhere: volumes\<name>.json.
const Record = struct { path: []const u8 };

/// The store's volumes\, by its full path, as grants.Own has the store's.
fn volumesDir(store: Store, arena: Allocator) ![]const u8 {
    return std.fs.path.join(arena, &.{ store.fullRoot(arena), "volumes" });
}

fn inStorePath(store: Store, arena: Allocator, name: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ try volumesDir(store, arena), name });
}

fn recordPath(store: Store, arena: Allocator, name: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ try volumesDir(store, arena), try std.fmt.allocPrint(arena, "{s}.json", .{name}) });
}

fn lockPath(store: Store, arena: Allocator, name: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ try volumesDir(store, arena), try std.fmt.allocPrint(arena, "{s}.lock", .{name}) });
}

/// The volume of that name, if there is one.
pub fn find(store: Store, arena: Allocator, name: []const u8) !?Volume {
    const in_store = try inStorePath(store, arena, name);
    if (try isDir(store.io, in_store)) return .{ .name = name, .path = in_store, .external = false };
    const record = try recordPath(store, arena, name);
    const bytes = Io.Dir.cwd().readFileAlloc(store.io, record, arena, .limited(64 << 10)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    const r = std.json.parseFromSliceLeaky(Record, arena, bytes, .{ .ignore_unknown_fields = true }) catch
        return fail("{s} isn't a volume's record; `zigsaw volume rm {s}` forgets it", .{ record, name });
    return .{ .name = name, .path = r.path, .external = true };
}

/// The store's volumes, by name.
pub fn list(store: Store, arena: Allocator) ![]const Volume {
    var out: std.ArrayList(Volume) = .empty;
    var dir = try Io.Dir.cwd().openDir(store.io, try volumesDir(store, arena), .{ .iterate = true });
    defer dir.close(store.io);
    var it = dir.iterate();
    while (try it.next(store.io)) |entry| {
        const name = switch (entry.kind) {
            .directory => entry.name,
            .file => if (std.mem.endsWith(u8, entry.name, ".json")) entry.name[0 .. entry.name.len - ".json".len] else continue,
            else => continue,
        };
        if (!isValidName(name)) continue;
        // The folder wins, as `find` has it.
        const seen = for (out.items) |v| {
            if (std.ascii.eqlIgnoreCase(v.name, name)) break true;
        } else false;
        if (seen) continue;
        if (try find(store, arena, try arena.dupe(u8, name))) |v| try out.append(arena, v);
    }
    std.mem.sort(Volume, out.items, {}, struct {
        fn lessThan(_: void, a: Volume, b: Volume) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan);
    return out.items;
}

/// Makes a volume in the store, and says so.
fn createInStore(ctx: *Context, name: []const u8) !Volume {
    const p = try inStorePath(ctx.store, ctx.arena, name);
    try Io.Dir.cwd().createDirPath(ctx.io, p);
    note("created volume {s} ({s})", .{ name, p });
    return .{ .name = name, .path = p, .external = false };
}

/// `zigsaw volume create [--path=<dir>] <name>`: a volume in the store, or
/// one kept in a folder of yours, which is made if it isn't there, and may
/// have files already.
pub fn create(ctx: *Context, name: []const u8, at: ?[]const u8) !void {
    const arena = ctx.arena;
    if (nameProblem(name)) |why| return fail("\"{s}\": {s}", .{ name, why });
    if (try find(ctx.store, arena, name)) |v| return fail("there's a volume {s} already, {f}", .{ name, v });
    const given = at orelse {
        _ = try createInStore(ctx, name);
        return;
    };
    if (!isDrivePath(given)) return fail("--path={s}: give a folder by its absolute path on a drive of this machine, such as E:\\volumes\\{s}", .{ given, name });
    const p = try normalPath(arena, given);
    if (try placeProblem(ctx, p)) |why| return fail("--path={s}: {s}", .{ p, why });
    const stat = Io.Dir.cwd().statFile(ctx.io, p, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
    if (stat) |s| {
        if (s.kind != .directory) return fail("--path={s} is a file", .{p});
    } else try Io.Dir.cwd().createDirPath(ctx.io, p);
    const tmp = try ctx.store.tmpPath(arena, "volume");
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tmp, .data = try oci.toJson(arena, Record{ .path = p }) });
    try Io.Dir.rename(.cwd(), tmp, .cwd(), try recordPath(ctx.store, arena, name), ctx.io);
    note("created volume {s}, kept in {s}", .{ name, p });
}

/// Why a folder of yours can't be a volume's, if it can't: what no run may
/// write (grants.Own, and a run would refuse it), or a folder a junction to it
/// would make a loop with.
fn placeProblem(ctx: *Context, p: []const u8) !?[]const u8 {
    if (std.fs.path.dirnameWindows(p) == null) return "it's the root of a drive";
    if (ctx.env.get("USERPROFILE")) |profile| if (isWithin(profile, p))
        return if (isWithin(p, profile)) "it's your user profile" else "your user profile is in it";
    const own: grants.Own = try .of(ctx);
    if (own.contains(p)) return "it's in zigsaw's store or folder: `zigsaw volume create` without --path makes one there";
    return own.refusal(p);
}

// ---------------------------------------------------------------------------
// Runs

/// A mount a run makes.
pub const Mounted = struct {
    mount: Mount,
    /// Where its files are, which the run grants: the volume's folder, or
    /// yours.
    host: []const u8,
};

/// What `prepare` made: the mounts, and the locks of their volumes, held
/// until the run ends.
pub const Prepared = struct {
    mounts: []const Mounted = &.{},
    locks: []const Store.Lock = &.{},

    pub fn release(p: Prepared, io: Io) void {
        for (p.locks) |l| l.release(io);
    }
};

pub const Options = struct {
    id: []const u8,
    data_dir: []const u8,
    /// The run's mounts, as its settings have them.
    values: []const []const u8,
    /// The saved ones (the overrides'), which may move the app's files.
    saved: []const []const u8,
    /// An --ephemeral run's data directory is its own, and goes with it.
    ephemeral: bool,
};

/// Makes the run's mounts: each one's volume, made if it's a new one in the
/// store, and locked as in use; the app's files at the place, moved into it
/// if they may be; and the junction. Runs with the store lock held, before
/// the run joins the app's runs (grants.begin), so that it can tell whether
/// another one goes on.
pub fn prepare(ctx: *Context, opts: Options) !Prepared {
    if (opts.values.len == 0) return .{};
    const io = ctx.io;
    const arena = ctx.arena;
    var mounts: std.ArrayList(Mount) = .empty;
    for (opts.values) |value| switch (try parse(arena, value)) {
        .ok => |m| try mounts.append(arena, m),
        .invalid => |why| return fail("{s}: --volume={s}: {s}", .{ opts.id, value, why }),
    };
    try checkApart(opts.id, mounts.items);
    // Recorded before any is made, so that one made before a later step
    // fails still goes (see `settle`); an --ephemeral run's go with its data
    // directory.
    if (!opts.ephemeral) try recordTargets(ctx, opts.id, mounts.items);

    // No other run of the app goes on: its junctions and files may change.
    const alone_lock = if (opts.ephemeral) null else try Store.tryLock(io, try ctx.store.runsLockPath(arena, opts.id), .exclusive);
    defer if (alone_lock) |l| l.release(io);
    const alone = opts.ephemeral or alone_lock != null;
    const own: grants.Own = try .of(ctx);

    var out: std.ArrayList(Mounted) = .empty;
    var locks: std.ArrayList(Store.Lock) = .empty;
    errdefer for (locks.items) |l| l.release(io);
    for (mounts.items) |m| {
        const host = switch (m.source) {
            .name => |name| host: {
                // Before it's looked up: `volume rm` deletes it under this lock.
                try locks.append(arena, try Store.openLock(io, try lockPath(ctx.store, arena, name), .shared, .wait));
                const v = try find(ctx.store, arena, name) orelse try createInStore(ctx, name);
                if (v.external and !try isDir(io, v.path))
                    return fail("{s}: volume {s} is kept in {s}, which isn't there: is its drive plugged in?", .{ opts.id, name, v.path });
                break :host v.path;
            },
            .path => |p| host: {
                if (!try isDir(io, p)) return fail("{s}: --volume={s}: there's no folder {s}", .{ opts.id, try m.spec(arena), p });
                break :host p;
            },
        };
        // A junction to a folder that holds the data directory would make a
        // loop in it; and one in it, a second way to its own files.
        if (isWithin(opts.data_dir, host) or isWithin(own.store, host))
            return fail("{s}: {f} holds zigsaw's store, and so the app's data: it can't be mounted in it", .{ opts.id, m });
        if (isWithin(host, opts.data_dir))
            return fail("{s}: {f} is in the app's data already", .{ opts.id, m });

        const at = try std.fs.path.join(arena, &.{ opts.data_dir, m.target });
        switch (try junction.inspect(io, arena, at)) {
            .missing, .empty_dir => {},
            .link => |old| if (!alone and !(if (old) |o| samePath(o, host) else false))
                return fail("{s}: another run of it has {s} at {s}: let it end first", .{ opts.id, old orelse "another link", m.target }),
            .other => {
                if (!try isDir(io, at)) return fail("{s}: {s} is a file of the app's, where {f} can't go", .{ opts.id, at, m });
                const why: ?[]const u8 = if (!isSaved(arena, m, opts.saved))
                    "the mount is only on the command line; `zigsaw override --volume` saves it, and moves them into an empty volume"
                else if (m.read_only)
                    "the mount is read-only"
                else if (!try isEmptyDir(io, host))
                    "the volume has files already: move the app's out first, or mount another"
                else if (!alone)
                    "another run of the app is going, which may be using them"
                else
                    null;
                if (why) |w| return fail("{s} has files of its own at {s}, which zigsaw won't hide under {f}: {s}", .{ opts.id, at, m, w });
                try populate(ctx, opts.id, at, host, m);
            },
        }
        if (try junction.link(io, arena, at, host) == .kept)
            return fail("{s}: {s} has the app's files again, where {f} can't go", .{ opts.id, at, m });
        try out.append(arena, .{ .mount = m, .host = host });
    }
    return .{ .mounts = out.items, .locks = locks.items };
}

/// Adds the mounts' targets to grants\<id>.mounts, the junctions to take away
/// once no saved mount names them. Taking one away never touches what isn't
/// a junction, so a target recorded where none was made costs nothing.
fn recordTargets(ctx: *Context, id: []const u8, mounts: []const Mount) !void {
    const arena = ctx.arena;
    const changes = try ctx.store.lockGrantChanges(arena);
    defer changes.release(ctx.io);
    var all: std.ArrayList([]const u8) = .empty;
    try all.appendSlice(arena, try ctx.store.readMounts(arena, id));
    const before = all.items.len;
    for (mounts) |m| {
        const known = for (all.items) |t| {
            if (std.os.windows.eqlIgnoreCaseWtf8(t, m.target)) break true;
        } else false;
        if (!known) try all.append(arena, m.target);
    }
    if (all.items.len != before) try ctx.store.writeMounts(arena, id, all.items);
}

/// Whether `m` is one of the saved mounts, as the overrides have it.
fn isSaved(arena: Allocator, m: Mount, saved: []const []const u8) bool {
    for (saved) |value| switch (parse(arena, value) catch continue) {
        .ok => |s| if (s.eql(m)) return true,
        .invalid => {},
    };
    return false;
}

/// Moves the app's files at `from` into the empty volume folder `into`, as
/// Docker fills an empty volume, so the junction can take their place. Only
/// renames, so only on the same drive: copying could take long, and leave
/// two copies.
fn populate(ctx: *Context, id: []const u8, from: []const u8, into: []const u8, m: Mount) !void {
    const io = ctx.io;
    const arena = ctx.arena;
    var names: std.ArrayList([]const u8) = .empty;
    {
        var dir = try Io.Dir.cwd().openDir(io, from, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| try names.append(arena, try arena.dupe(u8, entry.name));
    }
    for (names.items, 0..) |name, moved| {
        const src = try std.fs.path.join(arena, &.{ from, name });
        const dst = try std.fs.path.join(arena, &.{ into, name });
        if (win32.MoveFileExW(try win32.wide(arena, src), try win32.wide(arena, dst), 0) != 0) continue;
        const code = win32.GetLastError();
        if (moved == 0 and code == win32.ERROR_NOT_SAME_DEVICE)
            return fail("{s}'s files at {s} can't be moved into {f}, on another drive, without copying them: move them there yourself, then run it again", .{ id, from, m });
        const rest = if (moved > 0)
            try std.fmt.allocPrint(arena, "; {d} of the {d} there were moved, and the rest are still in {s}", .{ moved, names.items.len, from })
        else
            "";
        return fail("moving {s} into {s}: error {d} ({s}){s}", .{ src, into, code, win32.errorName(code), rest });
    }
    if (win32.RemoveDirectoryW(try win32.wide(arena, from)) == 0) return win32.lastErrorFail("RemoveDirectoryW");
    // What was moved keeps what it inherited where it was: the data
    // directory's label, or the app's AppContainer's access.
    try acl.reinherit(arena, into);
    note("moved {s}'s files at {s} into {f}", .{ id, m.target, m });
}

/// Takes away the junctions of the app's mounts that no saved mount names
/// any more: those only a command line asked for, or the overrides no longer
/// have. Never what the app put there itself. With grants.lock held: as the
/// app's last run ends, and when its overrides change while none goes (see
/// grants.settle).
pub fn settle(ctx: *Context, id: []const u8) !void {
    const arena = ctx.arena;
    const recorded = try ctx.store.readMounts(arena, id);
    if (recorded.len == 0) return;
    const saved = (try override.loadFor(ctx.store, arena, id)).volumes;
    var kept: std.ArrayList([]const u8) = .empty;
    for (recorded) |t| {
        const stands = for (saved) |value| {
            if (std.os.windows.eqlIgnoreCaseWtf8(targetOf(value), t)) break true;
        } else false;
        if (stands or !try unmount(ctx, id, t)) try kept.append(arena, t);
    }
    if (kept.items.len != recorded.len) try ctx.store.writeMounts(arena, id, kept.items);
}

/// Takes away every junction the app's mounts made, for `zigsaw rm`: a later
/// install's runs make them again. With grants.lock held.
pub fn unmountAll(ctx: *Context, id: []const u8) !void {
    for (try ctx.store.readMounts(ctx.arena, id)) |t| _ = try unmount(ctx, id, t);
    try ctx.store.writeMounts(ctx.arena, id, &.{});
}

/// Removes the junction at the target, if there's one; false if that failed
/// (reported).
fn unmount(ctx: *Context, id: []const u8, target: []const u8) !bool {
    const at = try ctx.store.path(ctx.arena, &.{ "data", id, target });
    const removed = junction.unlink(ctx.io, ctx.arena, at) catch |err| switch (err) {
        error.Failed => return false,
        else => |e| return e,
    };
    if (removed and ctx.verbose) note("took away {s}'s mount at {s}", .{ id, target });
    return true;
}

/// The folders the saved mounts `values` reach, as grants a run of the app
/// would be given (grants.Standing): a volume not yet made reaches none.
pub fn standing(ctx: *Context, values: []const []const u8) ![]const Mounted {
    const arena = ctx.arena;
    var out: std.ArrayList(Mounted) = .empty;
    for (values) |value| switch (try parse(arena, value)) {
        .ok => |m| switch (m.source) {
            .name => |n| if (try find(ctx.store, arena, n)) |v| try out.append(arena, .{ .mount = m, .host = v.path }),
            .path => |p| try out.append(arena, .{ .mount = m, .host = p }),
        },
        .invalid => {},
    };
    return out.items;
}

// ---------------------------------------------------------------------------
// `zigsaw volume`

/// A saved mount, and whose: an app's, or every app's (`override --global`).
const Saved = struct {
    /// Null for the store-wide overrides.
    id: ?[]const u8,
    mount: Mount,

    fn who(s: Saved) []const u8 {
        return s.id orelse "every app";
    }
};

/// Every saved mount: the store-wide overrides', and each app's, installed or
/// not (`rm` keeps an app's overrides, for when it comes back).
fn allSaved(ctx: *Context) ![]const Saved {
    const arena = ctx.arena;
    var out: std.ArrayList(Saved) = .empty;
    var ids: std.ArrayList(?[]const u8) = .empty;
    try ids.append(arena, null);
    {
        var dir = try Io.Dir.cwd().openDir(ctx.io, try ctx.store.path(arena, &.{"overrides"}), .{ .iterate = true });
        defer dir.close(ctx.io);
        var it = dir.iterate();
        while (try it.next(ctx.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
            const id = entry.name[0 .. entry.name.len - ".json".len];
            if (oci.isValidId(id)) try ids.append(arena, try arena.dupe(u8, id));
        }
    }
    for (ids.items) |id| {
        const s = override.load(ctx.store, arena, id) catch |err| switch (err) {
            error.Failed => continue, // Reported.
            else => |e| return e,
        };
        for (s.volumes) |value| switch (try parse(arena, value)) {
            .ok => |m| try out.append(arena, .{ .id = id, .mount = m }),
            .invalid => {},
        };
    }
    return out.items;
}

/// The saved mounts of the volume `name`.
fn mountsOf(saved: []const Saved, arena: Allocator, name: []const u8) ![]const Saved {
    var out: std.ArrayList(Saved) = .empty;
    for (saved) |s| switch (s.mount.source) {
        .name => |n| if (std.ascii.eqlIgnoreCase(n, name)) try out.append(arena, s),
        .path => {},
    };
    return out.items;
}

/// "org.postgresql.PostgreSQL at data, every app at cache (read-only)".
fn describeMounts(arena: Allocator, saved: []const Saved) ![]const u8 {
    if (saved.len == 0) return "-";
    const parts = try arena.alloc([]const u8, saved.len);
    for (parts, saved) |*p, s| p.* = try std.fmt.allocPrint(arena, "{s} at {s}{s}", .{ s.who(), s.mount.target, if (s.mount.read_only) " (read-only)" else "" });
    return std.mem.join(arena, ", ", parts);
}

/// Whether a run holds the volume's lock.
fn inUse(ctx: *Context, name: []const u8) !bool {
    return Store.isLocked(ctx.io, try lockPath(ctx.store, ctx.arena, name));
}

/// `zigsaw volume ls`.
pub fn show(ctx: *Context) !void {
    const arena = ctx.arena;
    const saved = try allSaved(ctx);
    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const w = &stdout.interface;
    try w.print("{s:<24} {s:<40} {s}\n", .{ "NAME", "LOCATION", "MOUNTED BY" });
    for (try list(ctx.store, arena)) |v| {
        const where = if (v.external) v.path else "store";
        try w.print("{s:<24} {s:<40} {s}\n", .{ v.name, where, try describeMounts(arena, try mountsOf(saved, arena, v.name)) });
    }
    try w.flush();
}

/// `zigsaw volume inspect <name>`.
pub fn inspect(ctx: *Context, name: []const u8) !void {
    const arena = ctx.arena;
    const v = try find(ctx.store, arena, name) orelse return fail("there's no volume {s}; `zigsaw volume ls` lists them", .{name});
    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const w = &stdout.interface;
    try w.print("name        {s}\n", .{v.name});
    try w.print("location    {s} ({s})\n", .{ v.path, if (v.external) "kept outside the store" else "in the store" });
    if (try isDir(ctx.io, v.path)) {
        const size = try measure(ctx.io, arena, v.path);
        try w.print("size        {Bi:.1} in {d} file(s)\n", .{ size.bytes, size.files });
    } else try w.writeAll("size        -, as the folder isn't there\n");
    try w.print("mounted by  {s}\n", .{try describeMounts(arena, try mountsOf(try allSaved(ctx), arena, v.name))});
    try w.print("in use      {s}\n", .{if (try inUse(ctx, v.name)) "yes, by a run" else "no"});
    var lines: std.ArrayList([]const u8) = .empty;
    for (try ctx.store.listGrantIds(arena)) |id| for (try ctx.store.readGrants(arena, id)) |g| {
        if (g.kind == .loopback or !samePath(g.path, v.path)) continue;
        try lines.append(arena, try std.fmt.allocPrint(arena, "{s} for {s}", .{ if (g.kind == .low) "labelled low" else "AppContainer access", id }));
    };
    try w.print("grants      {s}\n", .{if (lines.items.len == 0) "none" else try std.mem.join(arena, "; ", lines.items)});
    try w.flush();
}

/// `zigsaw volume rm <name>...`: deletes a volume in the store, and forgets
/// one kept elsewhere, leaving its files; not one a saved mount names, nor
/// one a run uses.
pub fn remove(ctx: *Context, names: []const []const u8) !void {
    const arena = ctx.arena;
    const saved = try allSaved(ctx);
    for (names) |name| {
        const v = try find(ctx.store, arena, name) orelse return fail("there's no volume {s}; `zigsaw volume ls` lists them", .{name});
        const users = try mountsOf(saved, arena, name);
        if (users.len > 0) return fail("{s} is mounted by {s}: take that away first, with `zigsaw override --novolume={s} {s}`", .{
            name, try describeMounts(arena, users), users[0].mount.target, users[0].id orelse "--global",
        });
        const lock = try Store.tryLock(ctx.io, try lockPath(ctx.store, arena, name), .exclusive) orelse
            return fail("volume {s} is in use by a run of an app", .{name});
        defer lock.release(ctx.io);
        try grants.undoPath(ctx, v.path);
        if (v.external) {
            try Io.Dir.cwd().deleteFile(ctx.io, try recordPath(ctx.store, arena, name));
            note("forgot volume {s}; its files stay in {s}", .{ name, v.path });
        } else {
            try Store.deleteTree(ctx.io, arena, v.path);
            note("removed volume {s}", .{name});
        }
    }
}

/// `zigsaw volume prune [--dry-run]`: deletes the volumes in the store that no
/// saved mount names and no run uses. Never one kept elsewhere: those are
/// folders of yours.
pub fn prune(ctx: *Context, dry_run: bool) !void {
    const arena = ctx.arena;
    const saved = try allSaved(ctx);
    var total: u64 = 0;
    var count: usize = 0;
    for (try list(ctx.store, arena)) |v| {
        if (v.external or (try mountsOf(saved, arena, v.name)).len > 0) continue;
        const lock = try Store.tryLock(ctx.io, try lockPath(ctx.store, arena, v.name), .exclusive) orelse {
            note("kept volume {s}, which a run uses", .{v.name});
            continue;
        };
        defer lock.release(ctx.io);
        const size = (try measure(ctx.io, arena, v.path)).bytes;
        total += size;
        count += 1;
        if (dry_run) {
            note("would remove volume {s} ({Bi:.1})", .{ v.name, size });
            continue;
        }
        try grants.undoPath(ctx, v.path);
        try Store.deleteTree(ctx.io, arena, v.path);
        note("removed volume {s} ({Bi:.1})", .{ v.name, size });
    }
    if (count == 0) note("no volume to remove: each is mounted by an app, kept outside the store, or in use", .{}) else if (!dry_run) note("removed {d} volume(s), {Bi:.1}", .{ count, total });
}

/// The volumes in the store that no saved mount names, and their size, for
/// what `zigsaw prune` says.
pub fn unused(ctx: *Context) !struct { count: usize, bytes: u64 } {
    const arena = ctx.arena;
    const saved = try allSaved(ctx);
    var count: usize = 0;
    var bytes: u64 = 0;
    for (try list(ctx.store, arena)) |v| {
        if (v.external or (try mountsOf(saved, arena, v.name)).len > 0) continue;
        count += 1;
        bytes += (try measure(ctx.io, arena, v.path)).bytes;
    }
    return .{ .count = count, .bytes = bytes };
}

/// The named volumes the app's saved mounts name, for what `rm
/// --delete-data` keeps.
pub fn namedIn(arena: Allocator, values: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (values) |value| switch (try parse(arena, value)) {
        .ok => |m| switch (m.source) {
            .name => |n| try out.append(arena, n),
            .path => {},
        },
        .invalid => {},
    };
    return out.items;
}

// ---------------------------------------------------------------------------
// Helpers

fn isDir(io: Io, p: []const u8) !bool {
    const stat = Io.Dir.cwd().statFile(io, p, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => |e| return e,
    };
    return stat.kind == .directory;
}

fn isEmptyDir(io: Io, p: []const u8) !bool {
    var dir = try Io.Dir.cwd().openDir(io, p, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    return try it.next(io) == null;
}

/// The size of the files below a folder, and how many there are. Junctions
/// in it aren't followed.
fn measure(io: Io, arena: Allocator, p: []const u8) !struct { bytes: u64, files: usize } {
    var dir = try Io.Dir.cwd().openDir(io, p, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var bytes: u64 = 0;
    var files: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        bytes += (try entry.dir.statFile(io, entry.basename, .{})).size;
        files += 1;
    }
    return .{ .bytes = bytes, .files = files };
}

fn samePath(a: []const u8, b: []const u8) bool {
    return isWithin(a, b) and isWithin(b, a);
}

// ---------------------------------------------------------------------------
// Tests

fn expectMount(value: []const u8, source: Source, target: []const u8, read_only: bool) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const got = switch (try parse(arena_state.allocator(), value)) {
        .ok => |m| m,
        .invalid => |why| {
            std.debug.print("{s}: {s}\n", .{ value, why });
            return error.TestUnexpectedResult;
        },
    };
    try std.testing.expectEqualDeep(source, got.source);
    try std.testing.expectEqualStrings(target, got.target);
    try std.testing.expectEqual(read_only, got.read_only);
}

fn expectInvalid(value: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    switch (try parse(arena_state.allocator(), value)) {
        .ok => |m| {
            std.debug.print("{s}: parsed as {s}\n", .{ value, try m.spec(arena_state.allocator()) });
            return error.TestUnexpectedResult;
        },
        .invalid => {},
    }
}

test parse {
    try expectMount("pgdata:data", .{ .name = "pgdata" }, "data", false);
    try expectMount("pg-data_2:data:ro", .{ .name = "pg-data_2" }, "data", true);
    try expectMount("pgdata:data:rw", .{ .name = "pgdata" }, "data", false);
    try expectMount("pgdata:${data}\\data\\", .{ .name = "pgdata" }, "data", false);
    try expectMount("cfg:home/AppData/Roaming/Code", .{ .name = "cfg" }, "home\\AppData\\Roaming\\Code", false);
    try expectMount("D:\\pg:data", .{ .path = "D:\\pg" }, "data", false);
    try expectMount("D:/pg/:data:ro", .{ .path = "D:\\pg" }, "data", true);
    try expectMount("E:\\:media", .{ .path = "E:\\" }, "media", false);
    try expectMount("cache:cache", .{ .name = "cache" }, "cache", false);
    try expectMount("cfg:home\\AppData\\Roaming\\Microsoft\\Edge", .{ .name = "cfg" }, "home\\AppData\\Roaming\\Microsoft\\Edge", false);

    // The format.
    for ([_][]const u8{ "pgdata", "pgdata:", ":data", "D:\\pg", "D:\\pg:" }) |v| try expectInvalid(v);
    // Names: two or more of letters, digits, '_' and '-', no device's, nor
    // --filesystem's.
    for ([_][]const u8{ "d:data", "p.g:data", "-pg:data", "nul:data", "COM1:data", "cwd:data", "Documents:data", "rel\\dir:data", "\\\\srv\\share:data" }) |v| try expectInvalid(v);
    // Targets: relative, plain, and none of zigsaw's own.
    for ([_][]const u8{
        "pg:D:\\x",                         "pg:\\data",                            "pg:..\\x",                             "pg:a\\..\\b",
        "pg:.",                             "pg:a\\\\b",                            "pg:a.",                                "pg:con",
        "pg:registry",                      "pg:registry\\x",                       "pg:home",                              "pg:home\\AppData",
        "pg:home\\AppData\\Local\\Temp\\x", "pg:home\\AppData\\Local\\Packages\\x", "pg:home\\AppData\\Roaming\\Microsoft", "pg:home\\Documents",
        "pg:home\\documents\\notes",        "pg:${data}",
    }) |v| try expectInvalid(v);
}

test "a mount as settings keep it, and its target" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const m = (try parse(arena, "D:/pg/:${data}/db/main:ro")).ok;
    const value = try m.spec(arena);
    try std.testing.expectEqualStrings("D:\\pg:db\\main:ro", value);
    try std.testing.expectEqualStrings("db\\main", targetOf(value));
    try std.testing.expectEqualStrings("data", targetOf("pgdata:data"));
    try std.testing.expectEqualStrings("data", targetOf("E:\\x:data:rw"));
    try std.testing.expect(m.eql((try parse(arena, value)).ok));
    try std.testing.expect(!m.eql((try parse(arena, "D:\\pg:db\\main")).ok));
    try std.testing.expect(isSaved(arena, (try parse(arena, "PG:Data")).ok, &.{ "x:y", "pg:data" }));
    try std.testing.expect(!isSaved(arena, (try parse(arena, "pg:data:ro")).ok, &.{"pg:data"}));
}

test checkApart {
    const a: Mount = .{ .source = .{ .name = "a" }, .target = "data" };
    const b: Mount = .{ .source = .{ .name = "b" }, .target = "data\\x" };
    const c: Mount = .{ .source = .{ .name = "c" }, .target = "database" };
    try checkApart("t", &.{ a, c });
    try std.testing.expectError(error.Failed, checkApart("t", &.{ a, b }));
    try std.testing.expectError(error.Failed, checkApart("t", &.{ b, a }));
}

test "volumes in a store: in it, kept elsewhere, and listed" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    try tmp.dir.createDirPath(io, "volumes\\pgdata");
    try tmp.dir.createDirPath(io, "elsewhere");
    try tmp.dir.writeFile(io, .{ .sub_path = "volumes\\pgdata.lock", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "volumes\\media.json", .data = try oci.toJson(arena, Record{ .path = try std.fs.path.join(arena, &.{ root, "elsewhere" }) }) });
    const store: Store = .{ .io = io, .root = root };

    const pg = (try find(store, arena, "PGDATA")).?;
    try std.testing.expect(!pg.external);
    const media = (try find(store, arena, "media")).?;
    try std.testing.expect(media.external);
    try std.testing.expect(std.mem.endsWith(u8, media.path, "elsewhere"));
    try std.testing.expectEqual(null, try find(store, arena, "other"));

    const all = try list(store, arena);
    try std.testing.expectEqual(2, all.len);
    try std.testing.expectEqualStrings("media", all[0].name);
    try std.testing.expectEqualStrings("pgdata", all[1].name);
}
