//! Volumes, as Docker has them: the folders apps keep their files in.
//!
//! Every app has a volume of its own, named by its id: volumes\<id>\, its data
//! directory, which its first run makes. It goes with `rm --delete-data`, and
//! once the app is gone it's a volume nothing mounts, as any other may be. An
//! `--ephemeral` run has a fresh one in tmp\ instead, deleted as it ends.
//!
//! A mount, `--volume=<source>:<target>`, makes <target>, a path in the app's
//! data directory, a directory junction to another volume's folder (see
//! junction.zig). Windows has no mount namespaces, so a volume can only appear
//! where the app keeps its data; but deleting the app's own volume stops at
//! the junction, and leaves the other as it is. The target `.` is the data
//! directory itself: volumes\<id> is then the junction, and the source takes
//! the place of the app's own volume, for one app only.
//!
//! The source is either
//! - a named volume: a folder in the store, volumes\<name>\, which the first
//!   run that mounts it makes, or one kept elsewhere, which `zigsaw volume
//!   create --path=<dir> <name>` records in volumes\<name>.json; or
//! - a folder of yours, by its absolute path: a bind mount.
//!
//! A name has no dot, and the ids of apps nearly always do; an app whose id
//! has none owns the volume of that name, which no other app may then mount.
//!
//! Before 0.85 an app's data was in data\<id>\: `adopt` moves it here, when
//! no run of the app goes on.
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
const flate = std.compress.flate;
const options = @import("options");
const acl = @import("acl.zig");
const archive = @import("archive.zig");
const grants = @import("grants.zig");
const hkcu = @import("hkcu.zig");
const junction = @import("junction.zig");
const layer = @import("layer.zig");
const oci = @import("oci.zig");
const override = @import("override.zig");
const snapshot = @import("snapshot.zig");
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
    /// separated by '\'; or `root`, the data directory itself.
    target: []const u8,
    read_only: bool = false,

    /// Whether it's the app's data directory: in place of its own volume.
    pub fn isRoot(m: Mount) bool {
        return std.mem.eql(u8, m.target, root);
    }

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

/// The target that is the app's data directory itself.
pub const root = ".";

const format_hint = "--volume expects <volume or folder>:<path in the app's data>, and :ro to make it read-only, such as pgdata:data or D:\\pgdata:data; the path . is all of the app's data";

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
        .ok => |t| if (read_only and std.mem.eql(u8, t, root))
            .{ .invalid = "an app's data can't be read-only: it keeps its settings and temporary files there" }
        else
            .{ .ok = .{ .source = source, .target = t, .read_only = read_only } },
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

const target_hint = "the path in the app's data must be relative to its data directory, such as data or home\\AppData\\Roaming\\<app>, or . for all of it";

/// Checks a target, a path in the app's data directory (`${data}\` before it
/// is allowed), and returns it with '\' between its parts; or `root`, for
/// `.` and `${data}`, the data directory itself.
pub fn parseTarget(arena: Allocator, raw: []const u8) !Parsed([]const u8) {
    var t = std.mem.trimEnd(u8, raw, "\\/");
    if (std.mem.eql(u8, t, root) or std.mem.eql(u8, t, "${data}")) return .{ .ok = root };
    for ([_][]const u8{ "${data}\\", "${data}/" }) |prefix| if (std.mem.startsWith(u8, t, prefix)) {
        t = t[prefix.len..];
        break;
    };
    if (t.len == 0 or isSep(t[0]) or std.mem.indexOfScalar(u8, t, ':') != null) return .{ .invalid = target_hint };
    // Only a leading ${data} is.
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
/// mount's folder would be in the volume. All but the one at the root, which
/// is the app's alone, as its own volume is: the others' links are in it.
fn checkApart(id: []const u8, mounts: []const Mount) !void {
    for (mounts, 0..) |m, i| for (mounts[0..i]) |earlier| {
        if (m.isRoot() != earlier.isRoot()) continue;
        if (m.isRoot() or overlaps(m.target, earlier.target))
            return fail("{s}'s mounts at {s} and {s} overlap: give each its own place in the app's data", .{ id, earlier.target, m.target });
    };
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
pub fn isValidPart(part: []const u8) bool {
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
    /// An app's own, named by the app's id: its data directory.
    own: bool = false,

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

/// Whether a volume of that name is an app's own: the name is an id that
/// can't be a volume's name, or an app of that id is installed.
fn isOwn(store: Store, arena: Allocator, name: []const u8) !bool {
    return !isValidName(name) or try store.readRef(arena, name) != null;
}

/// The volume of that name, if there is one: an app's own, by the app's id,
/// or a named one. A link at volumes\<id> is no volume: it's where a mount at
/// the root put another in the place of the app's own.
pub fn find(store: Store, arena: Allocator, name: []const u8) !?Volume {
    if (!isValidName(name) and !oci.isValidId(name)) return null;
    const in_store = try inStorePath(store, arena, name);
    switch (try junction.inspect(store.io, arena, in_store)) {
        .missing, .link => {},
        .empty_dir, .other => if (try isDir(store.io, in_store))
            return .{ .name = name, .path = in_store, .external = false, .own = try isOwn(store, arena, name) },
    }
    if (!isValidName(name)) return null;
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
            // A link too, however it shows: `find` tells it from a folder.
            .directory, .sym_link => entry.name,
            .file => name: {
                if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
                const stem = entry.name[0 .. entry.name.len - ".json".len];
                if (!isValidName(stem)) continue;
                break :name stem;
            },
            else => continue,
        };
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
    if (try ctx.store.readRef(arena, name) != null) return fail("{s} is an app's id, and its own volume's name: give this one another", .{name});
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

    /// The folder mounted as the data directory, in place of the app's own
    /// volume, if one is.
    pub fn dataRoot(p: Prepared) ?[]const u8 {
        for (p.mounts) |m| if (m.mount.isRoot()) return m.host;
        return null;
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
        .ok => |m| {
            // A fresh data directory is what an --ephemeral run is for.
            if (m.isRoot() and opts.ephemeral) {
                if (ctx.verbose) note("note: an --ephemeral run has a data directory of its own, not {f}", .{m});
                continue;
            }
            // The one at the root first: the others' links are made in it.
            if (m.isRoot()) try mounts.insert(arena, 0, m) else try mounts.append(arena, m);
        },
        .invalid => |why| return fail("{s}: --volume={s}: {s}", .{ opts.id, value, why }),
    };
    if (mounts.items.len == 0) return .{};
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
                if (try ctx.store.readRef(arena, name) != null)
                    return fail("{s}: {s} is the app {s}'s own volume, which only it mounts", .{ opts.id, name, name });
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
        if (m.isRoot()) try checkAlone(ctx, opts.id, m, host);

        const at = if (m.isRoot()) opts.data_dir else try std.fs.path.join(arena, &.{ opts.data_dir, m.target });
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

/// Fails if the volume the app's id names, its own, is one a saved mount
/// names: a named volume made before an app whose id has no dot came. Only
/// such an id can be a volume's name, so only then is anything read.
pub fn checkOwn(ctx: *Context, id: []const u8) !void {
    if (!isValidName(id)) return;
    const users = try mountsOf(try allSaved(ctx), ctx.arena, id);
    if (users.len > 0) return fail("{s}: the volume of its name, which would be its data, is mounted by {s}: take that away with `zigsaw override --novolume={s} {s}`, and give that volume another name", .{
        id, try describeMounts(ctx.arena, users), users[0].mount.target, users[0].id orelse "--global",
    });
}

/// Fails unless the app is the only one whose saved mounts have `host` as
/// their data directory: two apps' settings, registry keys and temporary
/// files can't be in one folder.
fn checkAlone(ctx: *Context, id: []const u8, m: Mount, host: []const u8) !void {
    for (try allSaved(ctx)) |s| {
        if (!s.mount.isRoot()) continue;
        const other = s.id orelse
            return fail("{s}: the overrides for every app (--global) mount {f} as the data of each: take that away with `zigsaw override --global --novolume=.`", .{ id, s.mount });
        if (std.ascii.eqlIgnoreCase(other, id)) continue;
        const theirs = switch (s.mount.source) {
            .name => |n| if (try find(ctx.store, ctx.arena, n)) |v| v.path else continue,
            .path => |p| p,
        };
        if (samePath(theirs, host)) return fail("{s}: {f} is {s}'s data already, and two apps can't keep theirs in one folder", .{ id, m, other });
    }
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
    const root_goes = for (recorded) |t| {
        if (std.mem.eql(u8, t, root)) break !standsIn(saved, t);
    } else false;
    for (try rootLast(arena, recorded)) |t| {
        const stands = standsIn(saved, t);
        // With the root's, the others' links go from its folder too: a run
        // makes those that stand again, in the app's own volume.
        if (stands and !(root_goes and !std.mem.eql(u8, t, root))) {
            try kept.append(arena, t);
            continue;
        }
        if (!try unmount(ctx, id, t) or stands) try kept.append(arena, t);
    }
    if (kept.items.len != recorded.len) try ctx.store.writeMounts(arena, id, kept.items);
}

/// Whether a saved mount is at the target.
fn standsIn(saved: []const []const u8, target: []const u8) bool {
    for (saved) |value| if (std.os.windows.eqlIgnoreCaseWtf8(targetOf(value), target)) return true;
    return false;
}

/// Takes away every junction the app's mounts made, for `zigsaw rm`: a later
/// install's runs make them again. With grants.lock held.
pub fn unmountAll(ctx: *Context, id: []const u8) !void {
    for (try rootLast(ctx.arena, try ctx.store.readMounts(ctx.arena, id))) |t| _ = try unmount(ctx, id, t);
    try ctx.store.writeMounts(ctx.arena, id, &.{});
}

/// The targets with the root's after the others: their links are found
/// through it.
fn rootLast(arena: Allocator, targets: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (targets) |t| if (!std.mem.eql(u8, t, root)) try out.append(arena, t);
    if (out.items.len != targets.len) try out.append(arena, root);
    return out.items;
}

/// Removes the junction at the target, if there's one; false if that failed
/// (reported).
fn unmount(ctx: *Context, id: []const u8, target: []const u8) !bool {
    const data_dir = try ctx.store.dataDir(ctx.arena, id);
    const at = if (std.mem.eql(u8, target, root)) data_dir else try std.fs.path.join(ctx.arena, &.{ data_dir, target });
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
    /// Not saved at all: an installed app and its own volume.
    own: bool = false,

    fn who(s: Saved) []const u8 {
        return s.id orelse "every app";
    }
};

/// What mounts the volume: the saved mounts that name it, and, its own, the
/// app if it's installed.
fn usersOf(ctx: *Context, saved: []const Saved, v: Volume) ![]const Saved {
    const arena = ctx.arena;
    var out: std.ArrayList(Saved) = .empty;
    if (v.own and try ctx.store.readRef(arena, v.name) != null)
        try out.append(arena, .{ .id = v.name, .mount = .{ .source = .{ .name = v.name }, .target = root }, .own = true });
    if (isValidName(v.name)) try out.appendSlice(arena, try mountsOf(saved, arena, v.name));
    return out.items;
}

/// The lock that says no run uses the volume, if none does: an app's own has
/// its runs' lock, another its own.
fn lockUnused(ctx: *Context, v: Volume) !?Store.Lock {
    const p = if (isValidName(v.name) and !v.own) try lockPath(ctx.store, ctx.arena, v.name) else try ctx.store.runsLockPath(ctx.arena, v.name);
    return Store.tryLock(ctx.io, p, .exclusive);
}

/// Deletes a volume in the store, and what zigsaw keeps beside an app's own.
fn delete(ctx: *Context, v: Volume) !void {
    try grants.undoPath(ctx, v.path);
    try Store.deleteTree(ctx.io, ctx.arena, v.path);
    Io.Dir.cwd().deleteFile(ctx.io, try std.fmt.allocPrint(ctx.arena, "{s}.hkcu.lock", .{v.path})) catch {};
}

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
    for (parts, saved) |*p, s| p.* = if (s.mount.isRoot())
        try std.fmt.allocPrint(arena, "{s} as its data", .{s.who()})
    else
        try std.fmt.allocPrint(arena, "{s} at {s}{s}", .{ s.who(), s.mount.target, if (s.mount.read_only) " (read-only)" else "" });
    return std.mem.join(arena, ", ", parts);
}

/// Whether a run uses the volume.
fn inUse(ctx: *Context, v: Volume) !bool {
    const l = try lockUnused(ctx, v) orelse return true;
    l.release(ctx.io);
    return false;
}

/// `zigsaw volume ls`.
pub fn show(ctx: *Context) !void {
    const arena = ctx.arena;
    const saved = try allSaved(ctx);
    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const w = &stdout.interface;
    const all = try list(ctx.store, arena);
    var width: usize = 24;
    for (all) |v| width = @max(width, v.name.len);
    try w.print("{[n]s:<[w]} {[l]s:<40} {[m]s}\n", .{ .n = "NAME", .w = width, .l = "LOCATION", .m = "MOUNTED BY" });
    for (all) |v| {
        const where = if (v.external) v.path else "store";
        try w.print("{[n]s:<[w]} {[l]s:<40} {[m]s}\n", .{ .n = v.name, .w = width, .l = where, .m = try describeMounts(arena, try usersOf(ctx, saved, v)) });
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
    try w.print("name        {s}{s}\n", .{ v.name, if (v.own) " (the app's own: its data)" else "" });
    try w.print("location    {s} ({s})\n", .{ v.path, if (v.external) "kept outside the store" else "in the store" });
    if (try isDir(ctx.io, v.path)) {
        const size = try measure(ctx.io, arena, v.path);
        try w.print("size        {Bi:.1} in {d} file(s)\n", .{ size.bytes, size.files });
    } else try w.writeAll("size        -, as the folder isn't there\n");
    try w.print("mounted by  {s}\n", .{try describeMounts(arena, try usersOf(ctx, try allSaved(ctx), v))});
    try w.print("in use      {s}\n", .{if (try inUse(ctx, v)) "yes, by a run" else "no"});
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
        const users = try usersOf(ctx, saved, v);
        if (users.len > 0 and users[0].own)
            return fail("{s} is the data of an app that's installed: `zigsaw rm --delete-data {s}` removes both", .{ name, name });
        if (users.len > 0) return fail("{s} is mounted by {s}: take that away first, with `zigsaw override --novolume={s} {s}`", .{
            name, try describeMounts(arena, users), users[0].mount.target, users[0].id orelse "--global",
        });
        const lock = try lockUnused(ctx, v) orelse return fail("volume {s} is in use by a run of an app", .{name});
        defer lock.release(ctx.io);
        if (v.external) {
            try grants.undoPath(ctx, v.path);
            try Io.Dir.cwd().deleteFile(ctx.io, try recordPath(ctx.store, arena, name));
            note("forgot volume {s}; its files stay in {s}", .{ name, v.path });
        } else {
            try delete(ctx, v);
            note("removed volume {s}", .{name});
        }
    }
}

/// What `prune` deleted, or would.
pub const Pruned = struct { count: usize = 0, bytes: u64 = 0 };

/// `zigsaw volume prune [--dry-run]`, and `zigsaw prune --volumes`: deletes
/// the volumes in the store that nothing mounts and no run uses: those no
/// saved mount names, and the data of apps that aren't installed. Never one
/// kept elsewhere: those are folders of yours.
pub fn prune(ctx: *Context, dry_run: bool) !Pruned {
    const arena = ctx.arena;
    const saved = try allSaved(ctx);
    var out: Pruned = .{};
    for (try list(ctx.store, arena)) |v| {
        if (v.external or (try usersOf(ctx, saved, v)).len > 0) continue;
        const lock = try lockUnused(ctx, v) orelse {
            note("kept volume {s}, which a run uses", .{v.name});
            continue;
        };
        defer lock.release(ctx.io);
        const size = (try measure(ctx.io, arena, v.path)).bytes;
        out.bytes += size;
        out.count += 1;
        if (dry_run) {
            note("would remove volume {s} ({Bi:.1})", .{ v.name, size });
            continue;
        }
        try delete(ctx, v);
        note("removed volume {s} ({Bi:.1})", .{ v.name, size });
    }
    return out;
}

/// The volumes in the store that nothing mounts, with their sizes, for what
/// `zigsaw prune` says it kept.
pub fn unmounted(ctx: *Context) !struct { names: []const []const u8, bytes: u64 } {
    const arena = ctx.arena;
    const saved = try allSaved(ctx);
    var names: std.ArrayList([]const u8) = .empty;
    var bytes: u64 = 0;
    for (try list(ctx.store, arena)) |v| {
        if (v.external or (try usersOf(ctx, saved, v)).len > 0) continue;
        const size = (try measure(ctx.io, arena, v.path)).bytes;
        try names.append(arena, try std.fmt.allocPrint(arena, "{s} ({Bi:.1})", .{ v.name, size }));
        bytes += size;
    }
    return .{ .names = names.items, .bytes = bytes };
}

// ---------------------------------------------------------------------------
// Export and import

/// The folders an import keeps in a volume while it goes on: the archive's
/// files, until they're all there, and the ones they replace, until they're
/// deleted. One that's left (zigsaw was killed) goes with the next import,
/// and is never exported.
const import_dir_prefix = ".zigsaw-import-";
const replaced_dir_prefix = ".zigsaw-replaced-";
const leftover_prefix = ".zigsaw-";

const in_use_hint = "is in use, by a run of an app or another export or import: let that end first";

/// `zigsaw volume export [--all] <name> <file>`: the volume's files as a tar
/// (archive.zig), gzip-compressed if the file's name says so, or to stdout
/// for `-`. Of an app's own volume, its data, without its temporary files
/// and cache, as the copy kept for a rollback is (snapshot.zig), unless
/// `all`. Only while no run uses the volume, so that the archive has the
/// files as one moment left them, with the keys the app keeps in HKCU among
/// them.
pub fn exportTo(ctx: *Context, name: []const u8, file: []const u8, all: bool) !void {
    const io = ctx.io;
    const arena = ctx.arena;
    const start = ctx.now();
    const v = try find(ctx.store, arena, name) orelse {
        try failIfMountedAtRoot(ctx, name);
        return fail("there's no volume {s}; `zigsaw volume ls` lists them", .{name});
    };
    if (!try isDir(io, v.path)) return fail("volume {s} is kept in {s}, which isn't there: is its drive plugged in?", .{ name, v.path });
    const target = if (std.mem.eql(u8, file, "-")) null else try snapshot.absolute(io, arena, file);
    if (target) |t| {
        if (isWithin(t, v.path)) return fail("{s} is in the volume itself: give a file somewhere else", .{t});
        if (try Store.exists(io, t)) return fail("{s} is there already: delete it first, or give another name", .{t});
    } else if (try Context.stdout().isTty(io)) {
        return fail("an archive isn't for a console: give a file, or send `-` into a pipe", .{});
    }

    // A rollback's swap that stopped halfway has an app's data elsewhere.
    if (v.own) try snapshot.finishSwap(ctx, v.name);
    const lock = try lockUnused(ctx, v) orelse return fail("volume {s} {s}", .{ name, in_use_hint });
    defer lock.release(io);
    // What a run that didn't end left in HKCU goes back into the data first:
    // the app's own, or the app's whose data this volume is.
    if (v.own) {
        try hkcu.settleLeftovers(ctx, v.name);
    } else for (try usersOf(ctx, try allSaved(ctx), v)) |user| {
        if (user.mount.isRoot()) if (user.id) |id| try hkcu.settleLeftovers(ctx, id);
    }
    try settleImports(ctx, v, .leave);

    var records: std.ArrayList(archive.Record) = .empty;
    try records.append(arena, .{ .key = "ZIGSAW.volume", .value = v.name });
    if (v.own) {
        try records.append(arena, .{ .key = "ZIGSAW.app", .value = v.name });
        if (try ctx.store.readRef(arena, v.name)) |ref| try records.append(arena, .{ .key = "ZIGSAW.version", .value = ref.version });
    }
    try records.append(arena, .{ .key = "ZIGSAW.zigsaw", .value = options.version });
    try records.append(arena, .{ .key = "ZIGSAW.exported", .value = try std.fmt.allocPrint(arena, "{d}", .{Io.Timestamp.now(io, .real).toSeconds()}) });
    const leaves_out = v.own and !all;
    const pack_options: archive.PackOptions = .{
        .global = records.items,
        .left_out = if (leaves_out) &snapshot.left_out else &.{},
        .left_out_prefix = leftover_prefix,
    };

    const gz = isGzipName(file);
    var archive_size: ?u64 = null;
    const tally = if (target) |t| tally: {
        // Under another name until it's whole: an export that stops leaves
        // no archive.
        const partial = try std.fmt.allocPrint(arena, "{s}.partial", .{t});
        var out = Io.Dir.cwd().createFile(io, partial, .{}) catch |err| return fail("making {s}: {t}", .{ partial, err });
        const result = writeArchive(ctx, v.path, out, false, gz, pack_options);
        out.close(io);
        const tally = result catch |err| {
            Io.Dir.cwd().deleteFile(io, partial) catch {};
            return err;
        };
        Io.Dir.rename(.cwd(), partial, .cwd(), t, io) catch |err| {
            Io.Dir.cwd().deleteFile(io, partial) catch {};
            return fail("naming the archive {s}: {t}", .{ t, err });
        };
        if (Io.Dir.cwd().statFile(io, t, .{})) |stat| archive_size = stat.size else |_| {}
        break :tally tally;
    } else try writeArchive(ctx, v.path, Context.stdout(), true, gz, pack_options);

    if (archive_size) |size|
        note("exported volume {s} to {s}: {Bi:.1} in {d} file(s), an archive of {Bi:.1}, in {f}", .{ name, target.?, tally.bytes, tally.files, size, ctx.since(start) })
    else
        note("exported volume {s}: {Bi:.1} in {d} file(s), in {f}", .{ name, tally.bytes, tally.files, ctx.since(start) });
    if (leaves_out) note("  without its temporary files and its cache: --all has those too", .{});
    if (tally.links > 0) note("  passed over {d} link(s): a volume mounted in it is exported by its own name", .{tally.links});
}

/// ".tar.gz" and ".tgz" say gzip; any other name is a plain tar.
fn isGzipName(file: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(file, ".gz") or std.ascii.endsWithIgnoreCase(file, ".tgz");
}

fn writeArchive(ctx: *Context, folder: []const u8, out: Io.File, streaming: bool, gz: bool, pack_options: archive.PackOptions) !archive.Tally {
    var buf: [64 * 1024]u8 = undefined;
    var writer = if (streaming) out.writerStreaming(ctx.io, &buf) else out.writer(ctx.io, &buf);
    const tally = packInto(ctx, folder, &writer.interface, gz, pack_options) catch |err| switch (err) {
        error.WriteFailed => return fail("writing the archive: {t}", .{writer.err orelse error.Unexpected}),
        else => |e| return e,
    };
    writer.interface.flush() catch return fail("writing the archive: {t}", .{writer.err orelse error.Unexpected});
    return tally;
}

fn packInto(ctx: *Context, folder: []const u8, out: *Io.Writer, gz: bool, pack_options: archive.PackOptions) !archive.Tally {
    if (!gz) return archive.pack(ctx.io, ctx.arena, folder, out, pack_options);
    const compress = try layer.gzip(ctx.arena, out);
    const tally = try archive.pack(ctx.io, ctx.arena, folder, &compress.writer, pack_options);
    try compress.finish();
    return tally;
}

/// Fails if `name` is an app whose data is mounted from elsewhere
/// (`--volume=<source>:.`): volumes\<id> is then a link, and no volume.
fn failIfMountedAtRoot(ctx: *Context, name: []const u8) !void {
    const arena = ctx.arena;
    if (!isValidName(name) and !oci.isValidId(name)) return;
    const to = switch (try junction.inspect(ctx.io, arena, try inStorePath(ctx.store, arena, name))) {
        .link => |to| to orelse "elsewhere",
        else => return,
    };
    const settings = override.loadFor(ctx.store, arena, name) catch |err| switch (err) {
        error.Failed => override.Settings{}, // Reported.
        else => |e| return e,
    };
    for (settings.volumes) |value| switch (try parse(arena, value)) {
        .ok => |m| if (m.isRoot()) switch (m.source) {
            .name => |n| return fail("{s}'s data is volume {s}, mounted in place of its own: give that volume's name, {s}", .{ name, n, n }),
            .path => |p| return fail("{s}'s data is {s}, a folder of yours mounted in place of its own volume: that one is yours to copy", .{ name, p }),
        },
        .invalid => {},
    };
    return fail("{s}'s data is {s}, mounted in place of its own volume, which has no name here", .{ name, to });
}

/// `zigsaw volume import [--replace] <name> <file>`: the files of a tar,
/// plain or gzip-compressed, or of stdin for `-`, as the volume's. The
/// volume is made if there is none: a named one in the store, or for an
/// app's id its own, its data, whether the app is installed yet or not.
///
/// One that has files is left alone, unless `replace`: then the archive's
/// files take their place. They're unpacked in a folder inside the volume
/// first, so on its drive and with what its files inherit; only then are the
/// old ones moved aside and the new ones moved up, by renaming, and the old
/// ones deleted. So an archive that turns out cut short, or with a name
/// Windows can't have, leaves the volume as it was. The links among the old
/// files go with them, never what they lead to: the app's next run makes
/// its mounts again.
pub fn importFrom(ctx: *Context, name: []const u8, file: []const u8, replace: bool) !void {
    const io = ctx.io;
    const arena = ctx.arena;
    const store = ctx.store;
    const start = ctx.now();
    if (nameProblem(name)) |why| if (!oci.isValidId(name))
        return fail("\"{s}\": {s}; an app's own volume has the app's id", .{ name, why });
    // An app's data, by its id: as `isOwn` has it, of a volume there or not.
    const is_app = try isOwn(store, arena, name);

    const from_stdin = std.mem.eql(u8, file, "-");
    var in_file = if (from_stdin) Context.stdin() else Io.Dir.cwd().openFile(io, file, .{}) catch |err|
        return fail("reading {s}: {t}", .{ file, err });
    defer if (!from_stdin) in_file.close(io);
    if (from_stdin and try in_file.isTty(io)) return fail("an archive doesn't come from a console: give a file, or pipe one into `-`", .{});
    const in_buf = try arena.alloc(u8, 64 * 1024);
    var file_reader = if (from_stdin) in_file.readerStreaming(io, in_buf) else in_file.reader(io, in_buf);
    const magic = file_reader.interface.peek(2) catch |err| switch (err) {
        error.EndOfStream => return fail("{s} is empty, or shorter than any archive", .{file}),
        error.ReadFailed => return fail("reading {s}: {t}", .{ file, file_reader.err orelse error.Unexpected }),
    };
    const gz = magic[0] == 0x1f and magic[1] == 0x8b;
    var inflate: flate.Decompress = undefined;
    if (gz) inflate = .init(&file_reader.interface, .gzip, try arena.alloc(u8, flate.max_window_len));
    const in: *Io.Reader = if (gz) &inflate.reader else &file_reader.interface;

    if (is_app) try snapshot.finishSwap(ctx, name);
    // Before the volume is looked up or made, as a run takes it.
    const lock_path = if (is_app) try store.runsLockPath(arena, name) else try lockPath(store, arena, name);
    const lock = try Store.tryLock(io, lock_path, .exclusive) orelse return fail("volume {s} {s}", .{ name, in_use_hint });
    defer lock.release(io);

    var made = false;
    const v: Volume = try find(store, arena, name) orelse new: {
        try failIfMountedAtRoot(ctx, name);
        const p = try inStorePath(store, arena, name);
        Io.Dir.cwd().createDirPath(io, p) catch |err| return fail("making {s}: {t}", .{ p, err });
        made = true;
        break :new .{ .name = name, .path = p, .external = false, .own = is_app };
    };
    // One this import made goes with it, if it fails.
    const made_w = try win32.wide(arena, v.path);
    errdefer if (made) {
        _ = win32.RemoveDirectoryW(made_w);
    };
    if (!try isDir(io, v.path)) return fail("volume {s} is kept in {s}, which isn't there: is its drive plugged in?", .{ name, v.path });
    if (!from_stdin and isWithin(try snapshot.absolute(io, arena, file), v.path))
        return fail("{s} is in the volume itself: move it somewhere else first", .{file});
    if (is_app) try hkcu.settleLeftovers(ctx, name);

    try settleImports(ctx, v, .delete);
    const old = try childrenOf(io, arena, v.path);
    if (old.len > 0 and !replace) return fail("volume {s} has files already ({s}{s}): --replace puts the archive's in their place, and deletes them", .{
        name, old[0], if (old.len > 1) try std.fmt.allocPrint(arena, " and {d} more", .{old.len - 1}) else "",
    });

    var random: [8]u8 = undefined;
    io.random(&random);
    const tag = std.fmt.bytesToHex(random, .lower);
    const import_dir = try std.fmt.allocPrint(arena, "{s}\\{s}{s}", .{ v.path, import_dir_prefix, &tag });
    const replaced_dir = try std.fmt.allocPrint(arena, "{s}\\{s}{s}", .{ v.path, replaced_dir_prefix, &tag });
    const unpacked = unpacked: {
        // Until the renames are done, a failure leaves the volume as it was.
        errdefer {
            Store.deleteTree(io, arena, import_dir) catch {};
            if (!made) note("nothing was imported: volume {s} is as it was", .{name});
        }
        Io.Dir.cwd().createDir(io, import_dir, .default_dir) catch |err| return fail("making {s}: {t}", .{ import_dir, err });
        const unpacked = archive.unpack(io, arena, in, import_dir) catch |err| switch (err) {
            error.ReadFailed => {
                if (gz) if (inflate.err) |e|
                    return fail("{s}: its gzip data can't be read ({t}): it was cut short, or is damaged", .{ file, e });
                return fail("reading {s}: {t}", .{ file, file_reader.err orelse error.Unexpected });
            },
            else => |e| return e,
        };
        // A file of zeros reads as a tar with nothing in it: not what to put
        // in the place of a volume's files. An export of an empty volume
        // says what it is.
        if (unpacked.tally.files + unpacked.tally.dirs == 0 and unpacked.get("ZIGSAW.volume") == null)
            return fail("{s} has no files or folders in it, and isn't an archive of zigsaw's", .{file});
        if (is_app) try failIfUnderMount(ctx, name, import_dir);
        try swapIn(io, arena, v.path, import_dir, replaced_dir, old);
        break :unpacked unpacked;
    };
    // The archive's files are the volume's now; the rest only tidies.
    if (old.len > 0) Store.deleteTree(io, arena, replaced_dir) catch |err|
        note("warning: the files replaced are still in {s} ({t}): delete that folder", .{ replaced_dir, err });
    // A copy still owed for a rollback would be of the files just imported.
    if (is_app and old.len > 0 and try store.forgetOwedData(arena, name))
        note("note: no copy of {s}'s data as the version before left it is kept for `zigsaw rollback`: that data was replaced", .{name});

    const tally = unpacked.tally;
    const how = if (made) ", a new one" else if (old.len > 0) ", in place of the files it had" else "";
    note("imported {Bi:.1} in {d} file(s) into volume {s}{s}, in {f}", .{ tally.bytes, tally.files, name, how, ctx.since(start) });
    if (unpacked.get("ZIGSAW.volume")) |of| {
        const version = if (unpacked.get("ZIGSAW.version")) |ver| try std.fmt.allocPrint(arena, ", as {s} left it", .{ver}) else "";
        const when = if (unpacked.get("ZIGSAW.exported")) |text| std.fmt.parseInt(i64, text, 10) catch null else null;
        if (when) |t|
            note("  the archive is of volume {s}{s}, exported {f}", .{ of, version, snapshot.ago(ctx, t) })
        else
            note("  the archive is of volume {s}{s}", .{ of, version });
    }
    if (tally.links > 0) note("  passed over {d} link(s) and the like in the archive: only files and folders are imported", .{tally.links});
    if (is_app and try store.readRef(arena, name) == null) note("  it's the data of {s}, for when that app is installed", .{name});
}

/// Fails if the files unpacked in `import_dir` have any where one of the
/// app's saved mounts goes: they would hide under the volume mounted there,
/// or stop the app's next run.
fn failIfUnderMount(ctx: *Context, id: []const u8, import_dir: []const u8) !void {
    const arena = ctx.arena;
    const settings = override.loadFor(ctx.store, arena, id) catch |err| switch (err) {
        error.Failed => return, // Reported.
        else => |e| return e,
    };
    for (settings.volumes) |value| switch (try parse(arena, value)) {
        .ok => |m| {
            if (m.isRoot()) continue;
            if (try junction.inspect(ctx.io, arena, try std.fs.path.join(arena, &.{ import_dir, m.target })) != .other) continue;
            return fail("the archive has files at {s}, where {s} mounts {f}: import those into that, or take the mount away first with `zigsaw override --novolume={s} {s}`", .{
                m.target, id, m, m.target, id,
            });
        },
        .invalid => {},
    };
}

/// Deletes what an import that didn't finish left in the volume, or leaves
/// it for the next import (an export changes nothing); and fails, if it
/// stopped between its renames, with the volume's files in two folders:
/// only whoever knows which they want can settle that.
fn settleImports(ctx: *Context, v: Volume, leftovers: enum { delete, leave }) !void {
    const io = ctx.io;
    const arena = ctx.arena;
    var unpacked: std.ArrayList([]const u8) = .empty;
    var replaced: std.ArrayList([]const u8) = .empty;
    for (try childrenOf(io, arena, v.path)) |child| {
        const left = if (std.ascii.startsWithIgnoreCase(child, import_dir_prefix))
            &unpacked
        else if (std.ascii.startsWithIgnoreCase(child, replaced_dir_prefix))
            &replaced
        else
            continue;
        try left.append(arena, try std.fs.path.join(arena, &.{ v.path, child }));
    }
    // The folder of the archive's files goes as the renames end: with it
    // there still, the old files aren't all back, or the new ones all in.
    if (unpacked.items.len > 0 and replaced.items.len > 0)
        return fail("an import into volume {s} stopped between its renames: the files it was replacing are in {s}, the archive's in {s}; move the ones you want back into {s}, and delete both folders", .{
            v.name, replaced.items[0], unpacked.items[0], v.path,
        });
    if (leftovers == .leave) return;
    for (unpacked.items) |p| try Store.deleteTree(io, arena, p);
    for (replaced.items) |p| try Store.deleteTree(io, arena, p);
    if (unpacked.items.len + replaced.items.len > 0) note("deleted what an import that didn't finish left in volume {s}", .{v.name});
}

/// The archive's files, in `import_dir`, become the volume's, and the
/// volume's own, `old`, go to `replaced_dir`: all by renaming what's in each
/// folder, so the volume's folder stays what it is, with its label, its
/// grants, and whatever links to it. A rename that fails puts back the ones
/// done.
fn swapIn(io: Io, arena: Allocator, volume: []const u8, import_dir: []const u8, replaced_dir: []const u8, old: []const []const u8) !void {
    const fresh = try childrenOf(io, arena, import_dir);
    // The next import would take one for what this one left.
    for (fresh) |n| if (std.ascii.startsWithIgnoreCase(n, leftover_prefix))
        return fail("the archive has {s}, a name zigsaw keeps in a volume for its own use", .{n});
    const replaced_w = try win32.wide(arena, replaced_dir);
    var moved_old: usize = 0;
    var moved_new: usize = 0;
    errdefer {
        for (fresh[0..moved_new]) |n| moveChild(arena, volume, import_dir, n) catch {};
        for (old[0..moved_old]) |n| moveChild(arena, replaced_dir, volume, n) catch {};
        if (old.len > 0) _ = win32.RemoveDirectoryW(replaced_w);
    }
    if (old.len > 0) {
        if (win32.CreateDirectoryW(replaced_w, null) == 0) return win32.lastErrorFail("CreateDirectoryW");
        for (old) |n| {
            try moveChild(arena, volume, replaced_dir, n);
            moved_old += 1;
        }
    }
    for (fresh) |n| {
        try moveChild(arena, import_dir, volume, n);
        moved_new += 1;
    }
    // Its going says the renames are done (see settleImports).
    if (win32.RemoveDirectoryW(try win32.wide(arena, import_dir)) == 0) return win32.lastErrorFail("RemoveDirectoryW");
}

/// Renames `name` in one folder into another. What scans a file just
/// written (Defender) can hold it a moment, and with it the folder it's in.
fn moveChild(arena: Allocator, from_dir: []const u8, to_dir: []const u8, name: []const u8) !void {
    const from = try std.fs.path.join(arena, &.{ from_dir, name });
    const to = try std.fs.path.join(arena, &.{ to_dir, name });
    const from_w = try snapshot.long(arena, from);
    const to_w = try snapshot.long(arena, to);
    var tries: usize = 0;
    while (true) : (tries += 1) {
        if (win32.MoveFileExW(from_w, to_w, 0) != 0) return;
        const code = win32.GetLastError();
        if ((code == win32.ERROR_ACCESS_DENIED or code == win32.ERROR_SHARING_VIOLATION) and tries < 50) {
            win32.Sleep(100);
            continue;
        }
        return fail("moving {s} to {s}: error {d} ({s}); close what has files open there, then try again", .{ from, to, code, win32.errorName(code) });
    }
}

/// The names of what's in a folder, links and all.
fn childrenOf(io: Io, arena: Allocator, p: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var dir = try Io.Dir.cwd().openDir(io, p, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| try names.append(arena, try arena.dupe(u8, entry.name));
    return names.items;
}

// ---------------------------------------------------------------------------
// Data from before 0.85

/// Moves an app's data from data\<id>, where a zigsaw before 0.85 kept it, to
/// its own volume. Only while no run of the app goes on, an older zigsaw's
/// included: `quiet` leaves it for later then, and a run of the app fails.
/// What a run that didn't end left in HKCU goes back into the data first:
/// its record names the old place.
pub fn adopt(ctx: *Context, id: []const u8, quiet: bool) !void {
    const io = ctx.io;
    const arena = ctx.arena;
    const old = try ctx.store.path(arena, &.{ "data", id });
    if (!try isDir(io, old)) return;
    // One at a time: a second zigsaw then finds it moved.
    const moving = try Store.openLock(io, try ctx.store.path(arena, &.{"volumes.adopt.lock"}), .exclusive, .wait);
    defer moving.release(io);
    const old_place = try junction.inspect(io, arena, old);
    if (old_place == .missing) return;
    const new = try ctx.store.dataDir(arena, id);
    const new_place = try junction.inspect(io, arena, new);
    if (new_place != .missing and new_place != .empty_dir) {
        // An older zigsaw ran the app after its data moved. Folders with
        // nothing in them are what any run makes: they go without a word.
        if (old_place == .empty_dir) {
            _ = win32.RemoveDirectoryW(try win32.wide(arena, old));
        } else if (try removeEmptyTree(io, arena, old)) {
            return;
        } else if (!quiet) {
            note("warning: {s} has files a zigsaw before 0.85 left after {s}'s data moved to {s}; no run uses them: move what you need from there, then delete it", .{ old, id, new });
        }
        return;
    }
    const why: ?[]const u8 = if (try acl.belowMedium())
        "zigsaw runs at low integrity here: run `zigsaw repair` from a prompt that isn't"
    else
        null;
    const alone = if (why == null) try Store.tryLock(io, try ctx.store.runsLockPath(arena, id), .exclusive) else null;
    defer if (alone) |l| l.release(io);
    if (alone == null) {
        if (quiet) return;
        return fail("{s}'s data is still in {s}, where a zigsaw before 0.85 kept it, and can't move to {s}: {s}", .{
            id, old, new, why orelse "a run of the app goes on; let it end first",
        });
    }
    try hkcu.settleLeftovers(ctx, id);
    if (new_place == .empty_dir) _ = win32.RemoveDirectoryW(try win32.wide(arena, new));
    if (win32.MoveFileExW(try win32.wide(arena, old), try win32.wide(arena, new), 0) == 0) {
        const code = win32.GetLastError();
        if (quiet) return;
        return fail("moving {s}'s data from {s} to {s}: error {d} ({s}); close what has files open there, then try again", .{ id, old, new, code, win32.errorName(code) });
    }
    Io.Dir.cwd().deleteFile(io, try std.fmt.allocPrint(arena, "{s}.hkcu.lock", .{old})) catch {};
    note("moved {s}'s data to {s}: an app's data is its own volume from zigsaw 0.85 (`zigsaw volume ls`)", .{ id, new });
}

/// Moves the data of every app from data\, for any command of a zigsaw that
/// finds a store an older one made. Leaves what it can't move yet, without a
/// word: a run of that app says why. Says whether anything moved, as shims
/// and shortcuts that name the old place then need `zigsaw repair`.
pub fn adoptAll(ctx: *Context) !bool {
    const io = ctx.io;
    const arena = ctx.arena;
    const old = try ctx.store.path(arena, &.{"data"});
    var ids: std.ArrayList([]const u8) = .empty;
    {
        var dir = Io.Dir.cwd().openDir(io, old, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return false,
            else => |e| return e,
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory and oci.isValidId(entry.name)) try ids.append(arena, try arena.dupe(u8, entry.name));
        }
    }
    var moved = false;
    for (ids.items) |id| {
        adopt(ctx, id, true) catch |err| switch (err) {
            error.Failed => continue, // Reported.
            else => |e| return e,
        };
        if (!try isDir(io, try std.fs.path.join(arena, &.{ old, id }))) moved = true;
    }
    // Gone once it's empty: the lock files of data that moved go first.
    if (moved) {
        var dir = try Io.Dir.cwd().openDir(io, old, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".hkcu.lock")) dir.deleteFile(io, entry.name) catch {};
        }
    }
    _ = win32.RemoveDirectoryW(try win32.wide(arena, old));
    return moved;
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

/// Deletes a tree with nothing in it but folders, deepest first, and says
/// whether it did. A file or a link anywhere in it (an older zigsaw's mount
/// is a junction) leaves the whole tree, so nothing a link leads to is
/// touched; and RemoveDirectoryW never takes a folder that isn't empty.
fn removeEmptyTree(io: Io, arena: Allocator, p: []const u8) !bool {
    var dirs: std.ArrayList([]const u8) = .empty;
    {
        var dir = try Io.Dir.cwd().openDir(io, p, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .directory) return false;
            try dirs.append(arena, try std.fs.path.join(arena, &.{ p, entry.path }));
        }
    }
    // A walk lists a folder before what's in it.
    var i = dirs.items.len;
    while (i > 0) {
        i -= 1;
        if (win32.RemoveDirectoryW(try win32.wide(arena, dirs.items[i])) == 0) return false;
    }
    return win32.RemoveDirectoryW(try win32.wide(arena, p)) != 0;
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
        "pg:.:ro",                          "pg:a\\\\b",                            "pg:a.",                                "pg:con",
        "pg:registry",                      "pg:registry\\x",                       "pg:home",                              "pg:home\\AppData",
        "pg:home\\AppData\\Local\\Temp\\x", "pg:home\\AppData\\Local\\Packages\\x", "pg:home\\AppData\\Roaming\\Microsoft", "pg:home\\Documents",
        "pg:home\\documents\\notes",        "pg:${data}:ro",
    }) |v| try expectInvalid(v);
    // The data directory itself, which can't be read-only.
    try expectMount("pg:.", .{ .name = "pg" }, root, false);
    try expectMount("D:\\pg:${data}\\", .{ .path = "D:\\pg" }, root, false);
    try expectMount("D:\\pg:.:rw", .{ .path = "D:\\pg" }, root, false);
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
    // The one at the root holds the others' links; there's only one.
    const r: Mount = .{ .source = .{ .path = "D:\\pg" }, .target = root };
    const r2: Mount = .{ .source = .{ .name = "all" }, .target = root };
    try checkApart("t", &.{ r, a, c });
    try std.testing.expectError(error.Failed, checkApart("t", &.{ r, a, r2 }));
}

test rootLast {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try rootLast(arena_state.allocator(), &.{ "a", root, "b\\c" });
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "a", "b\\c", root }), got);
    try std.testing.expectEqual(1, (try rootLast(arena_state.allocator(), &.{"a"})).len);
}

test "volumes in a store: in it, kept elsewhere, and listed" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    try tmp.dir.createDirPath(io, "volumes\\pgdata");
    try tmp.dir.createDirPath(io, "volumes\\org.example.App");
    try tmp.dir.createDirPath(io, "refs");
    try tmp.dir.writeFile(io, .{ .sub_path = "volumes\\org.example.App.hkcu.lock", .data = "" });
    try tmp.dir.createDirPath(io, "elsewhere");
    try tmp.dir.writeFile(io, .{ .sub_path = "volumes\\pgdata.lock", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "volumes\\media.json", .data = try oci.toJson(arena, Record{ .path = try std.fs.path.join(arena, &.{ root_dir, "elsewhere" }) }) });
    const store: Store = .{ .io = io, .root = root_dir };

    const pg = (try find(store, arena, "PGDATA")).?;
    try std.testing.expect(!pg.external);
    const media = (try find(store, arena, "media")).?;
    try std.testing.expect(media.external);
    try std.testing.expect(std.mem.endsWith(u8, media.path, "elsewhere"));
    try std.testing.expectEqual(null, try find(store, arena, "other"));
    try std.testing.expectEqual(null, try find(store, arena, "..\\refs"));
    try std.testing.expect(!pg.own);
    // An app's own, by its id.
    const app = (try find(store, arena, "org.example.App")).?;
    try std.testing.expect(app.own and !app.external);

    // A link at an app's id is a mount at the root, and no volume.
    const linked = try std.fs.path.join(arena, &.{ root_dir, "volumes", "org.example.Linked" });
    try std.testing.expectEqual(junction.Linked.made, try junction.link(io, arena, linked, try std.fs.path.join(arena, &.{ root_dir, "elsewhere" })));
    defer _ = junction.unlink(io, arena, linked) catch {};
    try std.testing.expectEqual(null, try find(store, arena, "org.example.Linked"));

    const all = try list(store, arena);
    try std.testing.expectEqual(3, all.len);
    try std.testing.expectEqualStrings("media", all[0].name);
    try std.testing.expectEqualStrings("org.example.App", all[1].name);
    try std.testing.expectEqualStrings("pgdata", all[2].name);
}
