//! How long zigsaw's changes to host paths last: the access an app's
//! AppContainer is given to a path, and the low integrity labels its low
//! runs need (see run.zig); and the loopback exemption of its container.
//! Store.zig records them in grants\<id>.txt, and which of them were a
//! run's working directory in grants\<id>.cwd. The programs the app's runs
//! wrote, which lose their low label as the app's last run ends, are in
//! grants\<id>.programs (see written.zig).
//!
//! The loopback exemption (see appcontainer.loopback) lasts only while the
//! app's runs go: an exempt container reaches this machine whatever its
//! capabilities, so a run without the network would too, and making it
//! takes milliseconds.
//!
//! A change to a path stays between runs only while a run of the app with
//! nothing on its command line would make it again: under the sandbox its
//! overrides choose, or its image asks for, or low, for the paths and user
//! folders its permissions and overrides name, and for the working directories such runs had, while
//! the app keeps `cwd` (granting a large directory takes a while, so they
//! aren't granted afresh on each run). What a run's command line asked for,
//! with `--file`, `--filesystem` or `--sandbox`, goes when the app's last
//! run ends; so does what its permissions or overrides no longer name, or
//! at once when `zigsaw override` or an install changes them while no run
//! of it is going. `zigsaw rm` takes back everything.
//!
//! Each run holds grants\<id>.txt.lock shared while it goes: the run that
//! can lock it exclusively at its end is the last, and settles what the
//! app's runs were given. The store's grants.lock is held while a host
//! path's ACL or a grants file changes, so that two zigsaw processes never
//! decide about one label at once.

const std = @import("std");
const Io = std.Io;
const win32 = @import("win32.zig");
const acl = @import("acl.zig");
const appcontainer = @import("appcontainer.zig");
const folders = @import("folders.zig");
const ledger = @import("ledger.zig");
const schedule = @import("schedule.zig");
const oci = @import("oci.zig");
const override = @import("override.zig");
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const volumes = @import("volumes.zig");
const written = @import("written.zig");
const fail = Context.fail;
const note = Context.note;

/// What no run may write, nor make writable to other programs: zigsaw's
/// store, with every app's files, and the folder of the zigsaw running. A
/// low label on a folder that holds them reaches them all, and Windows
/// starts a program whose file is labelled low at low integrity, whoever
/// starts it (php.exe in Kanboard's soft runs, in iteration 55's CI); write
/// access for an AppContainer would let the app change other apps.
pub const Own = struct {
    store: []const u8,
    self_dir: ?[]const u8,

    pub fn of(ctx: *Context) !Own {
        const store = Io.Dir.cwd().realPathFileAlloc(ctx.io, ctx.store.root, ctx.arena) catch ctx.store.root;
        const self = win32.selfExePath(ctx.arena) catch null;
        return .{ .store = store, .self_dir = if (self) |s| std.fs.path.dirname(s) else null };
    }

    /// Why no run may write `path`, if none may. A run's own data directory,
    /// in the store, is the caller's to leave out; a volume's folder in it,
    /// and what's in that, are the apps' (see volumes.zig).
    pub fn refusal(own: Own, path: []const u8) ?[]const u8 {
        if (own.inVolume(path)) return null;
        if (isWithin(own.store, path)) return "zigsaw's store is in it";
        if (isWithin(path, own.store)) return "it's in zigsaw's store";
        const d = own.self_dir orelse return null;
        if (isWithin(d, path)) return "zigsaw is in it";
        if (isWithin(path, d)) return "it's in zigsaw's folder";
        return null;
    }

    /// Whether `path` is in the store or zigsaw's folder, where no folder
    /// will do.
    pub fn contains(own: Own, path: []const u8) bool {
        return isWithin(path, own.store) or (if (own.self_dir) |d| isWithin(path, d) else false);
    }

    /// Whether `path` is a volume's folder in the store, <store>\volumes\<name>,
    /// or in one; not volumes\ itself, nor the files beside the folders,
    /// whose names have a dot that a volume's can't.
    fn inVolume(own: Own, path: []const u8) bool {
        const store = std.mem.trimEnd(u8, own.store, "\\/");
        if (!isWithin(path, store)) return false;
        const rest = std.mem.trimStart(u8, path[store.len..], "\\/");
        var parts = std.mem.tokenizeAny(u8, rest, "\\/");
        const first = parts.next() orelse return false;
        if (!std.ascii.eqlIgnoreCase(first, "volumes")) return false;
        return volumes.isValidName(parts.next() orelse return false);
    }
};

/// A run's part among the app's runs.
pub const Session = struct {
    id: []const u8,
    lock_path: []const u8,
    lock: Store.Lock,
};

/// Joins the app's runs, before the run grants anything. Waits while
/// another zigsaw takes back what the app's runs were given.
pub fn begin(ctx: *Context, id: []const u8) !Session {
    const lock_path = try ctx.store.runsLockPath(ctx.arena, id);
    const lock = try Store.tryLock(ctx.io, lock_path, .shared) orelse wait: {
        note("waiting for another zigsaw to take back what {s} was granted...", .{id});
        break :wait try Store.openLock(ctx.io, lock_path, .shared, .wait);
    };
    return .{ .id = id, .lock_path = lock_path, .lock = lock };
}

/// Leaves the app's runs once the run is over: the last one settles what
/// they were given. Only warns if that fails; the run itself went fine.
pub fn end(ctx: *Context, s: Session) void {
    s.lock.release(ctx.io);
    const last = (Store.tryLock(ctx.io, s.lock_path, .exclusive) catch null) orelse return;
    defer last.release(ctx.io);
    settle(ctx, s.id) catch note("warning: what {s}'s runs were granted stays until its next run ends, `zigsaw repair` or `zigsaw rm`", .{s.id});
}

/// Settles the app's grants after what it may reach changed (its overrides,
/// or an install), unless a run of it is going, whose end will. Returns
/// false if one is, and the app has grants to settle.
pub fn settleUnlessRunning(ctx: *Context, id: []const u8) !bool {
    const arena = ctx.arena;
    if ((try ctx.store.readGrants(arena, id)).len == 0 and (try ctx.store.readCwdGrants(arena, id)).len == 0 and
        (try ctx.store.readPrograms(arena, id)).len == 0 and (try ctx.store.readMounts(arena, id)).len == 0) return true;
    const l = try Store.tryLock(ctx.io, try ctx.store.runsLockPath(arena, id), .exclusive) orelse return false;
    defer l.release(ctx.io);
    try settle(ctx, id);
    return true;
}

/// Settles the grants of every app whose runs have all ended, those of apps
/// no longer installed too, for `zigsaw repair`: what an older zigsaw kept
/// until `rm` goes then. Returns how many failed (reported).
pub fn settleAll(ctx: *Context) !usize {
    var failed: usize = 0;
    for (try ctx.store.listGrantIds(ctx.arena)) |id| _ = settleUnlessRunning(ctx, id) catch |err| switch (err) {
        error.Failed => failed += 1,
        else => |e| return e,
    };
    return failed;
}

/// Takes back what the app's runs were given that doesn't stand any more
/// (see the top), and from what stays, what no run would give it now: its
/// package SID's access, from before iteration 9, and write access to what
/// it may only read. The caller holds the runs' lock exclusively, so no run
/// of the app is going.
pub fn settle(ctx: *Context, id: []const u8) !void {
    // A zigsaw below medium integrity (a low run's shim started it) leaves
    // them to the next one that isn't: what it may change, it would make low.
    if (try acl.belowMedium()) return;
    const arena = ctx.arena;
    const store = ctx.store;
    const changes = try store.lockGrantChanges(arena);
    defer changes.release(ctx.io);
    try written.settle(ctx, id);
    // The junctions of mounts that no longer stand, under any sandbox.
    try volumes.settle(ctx, id);
    const recorded = try store.readGrants(arena, id);
    const cwds = try store.readCwdGrants(arena, id);
    if (recorded.len == 0 and cwds.len == 0) return;
    const standing = try Standing.of(ctx, id);
    const sids: Sids = try .of(arena, id);

    var kept: std.ArrayList(Store.Grant) = .empty;
    for (recorded) |g| {
        // A deleted path took its ACL with it.
        if (g.kind != .loopback and !try Store.exists(ctx.io, g.path)) continue;
        if (standing.keeps(g, containsPath(cwds, g.path))) |access| {
            try kept.append(arena, g);
            tidy(ctx, g, access, sids) catch |err| switch (err) {
                error.Failed => {}, // Reported; what the app needs is there.
                else => |e| return e,
            };
        } else if (!try undo(ctx, id, g, sids, ctx.verbose)) try kept.append(arena, g);
    }
    var kept_cwds: std.ArrayList([]const u8) = .empty;
    for (cwds) |p| for (kept.items) |g| {
        if (samePath(g.path, p)) {
            try kept_cwds.append(arena, p);
            break;
        }
    };
    try store.writeGrants(arena, id, kept.items);
    try store.writeCwdGrants(arena, id, kept_cwds.items);
}

/// Takes back everything the app's runs were given, for `zigsaw rm`.
pub fn undoAll(ctx: *Context, id: []const u8) !void {
    const arena = ctx.arena;
    const changes = try ctx.store.lockGrantChanges(arena);
    defer changes.release(ctx.io);
    const recorded = try ctx.store.readGrants(arena, id);
    if (recorded.len > 0) {
        const sids: Sids = try .of(arena, id);
        for (recorded) |g| {
            if (g.kind != .loopback and !try Store.exists(ctx.io, g.path)) continue;
            _ = try undo(ctx, id, g, sids, true);
        }
    }
    try volumes.unmountAll(ctx, id);
    try ctx.store.deleteGrants(arena, id);
}

/// Takes back what any app's runs were given on `path`, for `zigsaw volume
/// rm` as the volume there goes: its folder may stay, one kept outside the
/// store.
pub fn undoPath(ctx: *Context, path: []const u8) !void {
    const arena = ctx.arena;
    const changes = try ctx.store.lockGrantChanges(arena);
    defer changes.release(ctx.io);
    for (try ctx.store.listGrantIds(arena)) |id| {
        const recorded = try ctx.store.readGrants(arena, id);
        var kept: std.ArrayList(Store.Grant) = .empty;
        for (recorded) |g| {
            if (g.kind == .loopback or !samePath(g.path, path)) {
                try kept.append(arena, g);
                continue;
            }
            // Every app's goes, a label too: none may mount the volume now. A
            // deleted folder took its ACL with it.
            if (try Store.exists(ctx.io, g.path) and !try takeBack(ctx, g, try .of(arena, id), true)) try kept.append(arena, g);
        }
        if (kept.items.len != recorded.len) try ctx.store.writeGrants(arena, id, kept.items);
    }
}

// ---------------------------------------------------------------------------
// What's recorded outside the store (see ledger.zig)

/// What the record has, and what it doesn't explain.
const Survey = struct {
    /// Other stores', that stand or may be back.
    others: []const ledger.Entry = &.{},
    /// Those no store stands behind, on paths that still exist.
    orphans: []const ledger.Entry = &.{},
    /// The user's folders with a low label no record has.
    unexplained: []const []const u8 = &.{},

    fn of(ctx: *Context) !Survey {
        const arena = ctx.arena;
        const entries = try entriesOf(ctx);
        const root = ctx.store.fullRoot(arena);
        var others: std.ArrayList(ledger.Entry) = .empty;
        var orphans: std.ArrayList(ledger.Entry) = .empty;
        for (entries) |e| switch (try ledger.stateOf(ctx.io, arena, e)) {
            .live => if (!e.ofStore(root)) try others.append(arena, e),
            .away => try others.append(arena, e),
            .orphan => if (e.grant.kind == .loopback or try Store.exists(ctx.io, e.grant.path)) try orphans.append(arena, e),
        };
        var unexplained: std.ArrayList([]const u8) = .empty;
        for (try folders.allHostPaths(ctx)) |p| {
            const rid = acl.ownLabel(arena, p) catch |err| switch (err) {
                error.Failed => continue,
                else => |e| return e,
            } orelse continue;
            if (rid > win32.SECURITY_MANDATORY_LOW_RID or try recordedLow(ctx, entries, p) != null) continue;
            try unexplained.append(arena, p);
        }
        return .{ .others = others.items, .orphans = orphans.items, .unexplained = unexplained.items };
    }
};

fn entriesOf(ctx: *Context) ![]const ledger.Entry {
    const key = ctx.store.ledger_key orelse return &.{};
    return ledger.list(ctx.arena, key) catch |err| switch (err) {
        error.Failed => &.{},
        else => |e| return e,
    };
}

/// Who has a low label on `path` recorded, this store's files first, which an
/// app that hasn't changed its grants since zigsaw 0.70 has only there.
fn recordedLow(ctx: *Context, entries: []const ledger.Entry, path: []const u8) !?ledger.Entry {
    const arena = ctx.arena;
    const root = ctx.store.fullRoot(arena);
    for (try ctx.store.listGrantIds(arena)) |id| for (try ctx.store.readGrants(arena, id)) |g| {
        if (g.kind == .low and samePath(g.path, path)) return .{ .store = root, .id = id, .grant = g };
    };
    for (entries) |e| if (e.grant.kind == .low and samePath(e.grant.path, path)) return e;
    return null;
}

/// One line on stderr if something's left that no store will take back.
pub fn noteLeftovers(ctx: *Context) !void {
    const s = try Survey.of(ctx);
    if (s.orphans.len > 0) note("note: {d} change(s) outside the store by stores since deleted are still in place: `zigsaw grants` lists them, `zigsaw repair` takes them back", .{s.orphans.len});
    if (s.unexplained.len > 0) note("note: {s} labelled low, which no record explains: `zigsaw grants` says more", .{try std.mem.join(ctx.arena, ", ", s.unexplained)});
}

/// `zigsaw grants`: what's changed outside the store, this store's from its
/// files, the rest from the record.
pub fn show(ctx: *Context, only: ?[]const u8) !void {
    const arena = ctx.arena;
    var buf: [4096]u8 = undefined;
    var stdout = Context.stdout().writerStreaming(ctx.io, &buf);
    const w = &stdout.interface;
    var any = false;

    var heading = false;
    for (try ctx.store.listGrantIds(arena)) |id| {
        if (only) |o| if (!std.os.windows.eqlIgnoreCaseWtf8(o, id)) continue;
        const recorded = try ctx.store.readGrants(arena, id);
        if (recorded.len == 0) continue;
        if (!heading) try w.print("This store, {s}\n", .{ctx.store.root});
        heading = true;
        any = true;
        try w.print("  {s}\n", .{id});
        const standing = try Standing.of(ctx, id);
        const cwds = try ctx.store.readCwdGrants(arena, id);
        for (recorded) |g| try w.print("    {f}: {s}\n", .{ Line{ .grant = g }, why(standing, g, containsPath(cwds, g.path)) });
    }
    const s = try Survey.of(ctx);
    any = try showEntries(w, "Other stores", "", s.others, only) or any;
    any = try showEntries(w, "Stores since deleted", " (`zigsaw repair` takes these back)", s.orphans, only) or any;
    if (only == null and s.unexplained.len > 0) {
        any = true;
        try w.writeAll("Not explained: labelled low, in no store's record (`zigsaw grants --take-back <path>` removes one)\n");
        for (s.unexplained) |p| try w.print("  {s}\n", .{p});
    }
    if (only == null) {
        const tasks = try schedule.listTasks(ctx);
        if (tasks.len > 0) {
            any = true;
            try w.writeAll("Daily checks for updates, which install nothing (`zigsaw updates off` removes a store's)\n");
        }
        for (tasks) |t| try w.print("  scheduled task \"{s}\", for {s}{s}\n", .{
            t.name, t.store orelse "a store whose path can't be read here", if (t.gone) ", since deleted (`zigsaw repair` removes it)" else "",
        });
    }
    if (!any) try w.writeAll(if (only != null) "Nothing recorded for that app.\n" else "zigsaw has changed nothing outside its stores.\n");
    try w.flush();
}

fn showEntries(w: *Io.Writer, title: []const u8, hint: []const u8, entries: []const ledger.Entry, only: ?[]const u8) !bool {
    var any = false;
    for (entries) |e| {
        if (only) |o| if (!std.os.windows.eqlIgnoreCaseWtf8(o, e.id)) continue;
        if (!any) try w.print("{s}{s}\n", .{ title, hint });
        any = true;
        try w.print("  {s}, {s}: {f}\n", .{ e.store, e.id, Line{ .grant = e.grant } });
    }
    return any;
}

/// A change as `zigsaw grants` says it.
const Line = struct {
    grant: Store.Grant,

    pub fn format(l: Line, w: *Io.Writer) Io.Writer.Error!void {
        switch (l.grant.kind) {
            .low => try w.print("low label on {s}", .{l.grant.path}),
            .appcontainer => try w.print("its container may use {s}", .{l.grant.path}),
            .loopback => try w.writeAll("its container is exempt from loopback isolation"),
        }
    }
};

/// How long a change of this store's lasts.
fn why(standing: Standing, g: Store.Grant, was_cwd: bool) []const u8 {
    if (g.kind == .loopback) return "while its runs go";
    if (standing.keeps(g, was_cwd) == null) return "goes when its last run ends, or at `zigsaw repair`";
    return if (was_cwd) "a working directory, kept while it has cwd" else "its permissions name it, kept until they don't";
}

/// Takes back what no store stands behind, for `zigsaw repair`, unless a store
/// that stands has the same. Returns how many failed (reported).
pub fn settleOrphans(ctx: *Context) !usize {
    const key = ctx.store.ledger_key orelse return 0;
    if (try acl.belowMedium()) return 0;
    const arena = ctx.arena;
    const changes = try ctx.store.lockGrantChanges(arena);
    defer changes.release(ctx.io);
    const entries = try entriesOf(ctx);
    var failed: usize = 0;
    for (entries) |e| {
        if (try ledger.stateOf(ctx.io, arena, e) != .orphan) continue;
        const present = e.grant.kind == .loopback or try Store.exists(ctx.io, e.grant.path);
        if (present and !try wantedElsewhere(ctx, entries, e)) {
            note("{s} is no longer there to take this back: {f} ({s})", .{ e.store, Line{ .grant = e.grant }, e.id });
            if (!try takeBack(ctx, e.grant, try .of(arena, e.id), true)) {
                failed += 1;
                continue;
            }
        }
        try ledger.remove(arena, key, e);
    }
    ledger.dropIfEmpty(arena, key) catch {};
    return failed;
}

/// Whether a store that stands has this change too: any app, for a label, as
/// there's one to a path; the same app, for what's granted to its identities.
fn wantedElsewhere(ctx: *Context, entries: []const ledger.Entry, orphan: ledger.Entry) !bool {
    // This store's files, for an app that hasn't changed its grants since 0.70.
    if (orphan.grant.kind == .low and try ctx.store.grantedToOthers(ctx.arena, "", orphan.grant)) return true;
    for (entries) |e| {
        if (!e.grant.eql(orphan.grant)) continue;
        if (orphan.grant.kind != .low and !std.os.windows.eqlIgnoreCaseWtf8(e.id, orphan.id)) continue;
        if (try ledger.stateOf(ctx.io, ctx.arena, e) != .orphan) return true;
    }
    return false;
}

/// `zigsaw grants --take-back <path>`: removes a low label that no record
/// explains. One that a record has goes the way it's recorded, or the app
/// would only make it again.
pub fn takeBackLabel(ctx: *Context, path: []const u8) !void {
    const arena = ctx.arena;
    if (!std.fs.path.isAbsolute(path)) return fail("--take-back takes an absolute path; got \"{s}\"", .{path});
    const changes = try ctx.store.lockGrantChanges(arena);
    defer changes.release(ctx.io);
    const entries = try entriesOf(ctx);
    if (try recordedLow(ctx, entries, path)) |e| switch (try ledger.stateOf(ctx.io, arena, e)) {
        .orphan => return fail("{s} was labelled for {s} by a store since deleted, {s}: `zigsaw repair` takes it back", .{ path, e.id, e.store }),
        else => return fail("{s} is labelled for {s} in {s}: `zigsaw rm {s}` there takes it back, or an override that takes the permission away", .{ path, e.id, e.store, e.id }),
    };
    // Windows' own, for low-integrity programs to write in.
    if (ctx.env.get("USERPROFILE")) |home| {
        if (samePath(path, try std.fs.path.join(arena, &.{ home, "AppData", "LocalLow" })))
            return fail("{s} is labelled low by Windows, for programs at low integrity", .{path});
    }
    const rid = try acl.ownLabel(arena, path) orelse return note("{s} has no label of its own", .{path});
    if (rid > win32.SECURITY_MANDATORY_LOW_RID) return note("{s} isn't labelled low", .{path});
    const start = Io.Timestamp.now(ctx.io, .awake);
    try acl.unlabel(arena, path);
    note("removed the low integrity label of {s} ({d} ms)", .{ path, millis(ctx, start) });
}

/// The app's AppContainer identities, whether or not its profile exists.
const Sids = struct {
    /// The profile's name, as messages call it.
    name: []const u8,
    capability: win32.PSID,
    package: win32.PSID,

    fn of(arena: std.mem.Allocator, id: []const u8) !Sids {
        return .{
            .name = try appcontainer.profileName(arena, id),
            .capability = try appcontainer.appCapability(arena, id),
            .package = try appcontainer.packageSid(arena, id),
        };
    }
};

/// Takes back one change. False if that failed (and was reported), so it
/// stays recorded, to be tried again. A label other apps need stays, which
/// is told only when `tell_kept`: `rm` asked for it to go, a run's end didn't.
/// So is the loopback exemption's end, which every run's end would tell.
fn undo(ctx: *Context, id: []const u8, g: Store.Grant, sids: Sids, tell_kept: bool) !bool {
    if (g.kind == .low and try ctx.store.grantedToOthers(ctx.arena, id, g)) {
        if (tell_kept) note("kept the low integrity label of {s}, which other apps' runs need", .{g.path});
        return true;
    }
    return takeBack(ctx, g, sids, tell_kept);
}

/// Takes back one change, whoever else may want it.
fn takeBack(ctx: *Context, g: Store.Grant, sids: Sids, tell_kept: bool) !bool {
    const arena = ctx.arena;
    const start = Io.Timestamp.now(ctx.io, .awake);
    switch (g.kind) {
        .appcontainer => {
            // The package SID is what zigsaw granted before capabilities.
            const changed = acl.revoke(arena, g.path, .{ .sids = &.{ sids.capability, sids.package } }) catch |err| switch (err) {
                error.Failed => return false,
                else => |e| return e,
            };
            if (changed) note("revoked {s} access to {s} ({d} ms)", .{ sids.name, g.path, millis(ctx, start) });
        },
        .low => {
            const label = acl.ownLabel(arena, g.path) catch |err| switch (err) {
                error.Failed => return false,
                else => |e| return e,
            };
            // Gone already, or not low: nothing of zigsaw's to take back.
            const rid = label orelse return true;
            if (rid > win32.SECURITY_MANDATORY_LOW_RID) return true;
            acl.unlabel(arena, g.path) catch |err| switch (err) {
                error.Failed => return false,
                else => |e| return e,
            };
            note("removed the low integrity label of {s} ({d} ms)", .{ g.path, millis(ctx, start) });
        },
        .loopback => {
            const was = appcontainer.loopback.unexempt(arena, sids.package) catch |err| switch (err) {
                error.Failed => return false,
                else => |e| return e,
            };
            if (was and (tell_kept or ctx.verbose))
                note("took back the loopback exemption of {s} ({d} ms)", .{ sids.name, millis(ctx, start) });
        },
    }
    return true;
}

/// What stays loses what no run would give the app now: its package SID's
/// access, which keeps low-integrity processes out (see appcontainer.zig),
/// and write access to a path it may now only read, which its next
/// AppContainer run grants again as read access.
fn tidy(ctx: *Context, g: Store.Grant, access: acl.Access, sids: Sids) !void {
    const arena = ctx.arena;
    const start = Io.Timestamp.now(ctx.io, .awake);
    if (g.kind == .appcontainer and access == .read_execute and try acl.grants(arena, g.path, sids.capability, .full)) {
        _ = try acl.revoke(arena, g.path, .{ .sids = &.{ sids.capability, sids.package } });
        note("revoked {s}'s write access to {s}, which it may only read now ({d} ms)", .{ sids.name, g.path, millis(ctx, start) });
        return;
    }
    if (try acl.revoke(arena, g.path, .{ .sids = &.{sids.package} }) and ctx.verbose)
        note("revoked the access of {s}'s package SID to {s} ({d} ms)", .{ sids.name, g.path, millis(ctx, start) });
}

fn millis(ctx: *Context, start: Io.Timestamp) i64 {
    return start.untilNow(ctx.io, .awake).toMilliseconds();
}

/// What a run of the app with nothing on its command line would be given.
const Standing = struct {
    sandbox: override.Sandbox,
    paths: []const Path = &.{},
    /// The access its working directory would have, if it has `cwd`.
    cwd: ?acl.Access = null,
    /// What no run may write: a recorded change that lets the app write
    /// there doesn't stand, as zigsaw from 0.56 on doesn't make it.
    own: ?Own = null,

    const Path = struct { path: []const u8, access: acl.Access };

    /// From the installed app's permissions and overrides, as run.zig has
    /// them. An app that isn't installed would be given nothing.
    fn of(ctx: *Context, id: []const u8) !Standing {
        const arena = ctx.arena;
        const ref = try ctx.store.readRef(arena, id) orelse return .{ .sandbox = .soft };
        const image = try ctx.store.readImage(arena, id, ref.manifest);
        const saved = try override.loadFor(ctx.store, arena, id);
        var s: Standing = .{ .sandbox = override.sandboxOf(saved, image.config.permissions), .own = try .of(ctx) };
        // A soft run changes no ACL.
        if (s.sandbox == .soft) return s;
        var paths: std.ArrayList(Path) = .empty;
        for (try saved.filesystemFor(arena, image.config.permissions.filesystem)) |spec| {
            const g = oci.parseFsGrant(spec) orelse continue;
            const access: acl.Access = if (g.read_only) .read_execute else .full;
            switch (g.where) {
                .cwd => s.cwd = wider(s.cwd, access),
                .path => |p| try paths.append(arena, .{ .path = p, .access = access }),
                .folder => |f| if (try folders.hostPathOf(ctx, f)) |p| try paths.append(arena, .{ .path = p, .access = access }),
                .unknown => {},
            }
        }
        // The folders its saved mounts reach (see volumes.zig).
        for (try volumes.standing(ctx, saved.volumes)) |m|
            try paths.append(arena, .{ .path = m.host, .access = if (m.mount.read_only) .read_execute else .full });
        s.paths = paths.items;
        return s;
    }

    /// The access a recorded change stands for, if it stands: `was_cwd`
    /// if it was a run's working directory.
    fn keeps(s: Standing, g: Store.Grant, was_cwd: bool) ?acl.Access {
        // Only while runs go (see the top).
        if (g.kind == .loopback) return null;
        var access: ?acl.Access = if (was_cwd) s.cwd else null;
        for (s.paths) |p| if (samePath(p.path, g.path)) {
            access = wider(access, p.access);
        };
        var a = access orelse return null;
        if (s.own) |own| if (own.refusal(g.path) != null) {
            a = .read_execute;
        };
        return switch (g.kind) {
            .appcontainer => if (s.sandbox == .appcontainer) a else null,
            // Low runs label only what they may write.
            .low => if (s.sandbox == .low and a == .full) a else null,
            .loopback => unreachable,
        };
    }
};

/// Writable wins.
fn wider(a: ?acl.Access, b: acl.Access) acl.Access {
    const either_full = b == .full or (if (a) |x| x == .full else false);
    return if (either_full) .full else .read_execute;
}

/// Whether two paths name the same place: ignoring ASCII case, '/' for '\',
/// and separators at the end.
fn samePath(a: []const u8, b: []const u8) bool {
    const x = std.mem.trimEnd(u8, a, "\\/");
    const y = std.mem.trimEnd(u8, b, "\\/");
    if (x.len != y.len) return false;
    for (x, y) |c, d| {
        if ((c == '\\' or c == '/') and (d == '\\' or d == '/')) continue;
        if (std.ascii.toLower(c) != std.ascii.toLower(d)) return false;
    }
    return true;
}

/// Whether `path` is `dir` or inside it, alike as samePath has them.
pub fn isWithin(path: []const u8, dir: []const u8) bool {
    const p = std.mem.trimEnd(u8, path, "\\/");
    const d = std.mem.trimEnd(u8, dir, "\\/");
    if (p.len < d.len or !samePath(p[0..d.len], d)) return false;
    return p.len == d.len or p[d.len] == '\\' or p[d.len] == '/';
}

fn containsPath(list: []const []const u8, p: []const u8) bool {
    for (list) |x| if (samePath(x, p)) return true;
    return false;
}

test samePath {
    try std.testing.expect(samePath("D:\\Src\\", "d:/src"));
    try std.testing.expect(samePath("C:\\Users\\Ann\\Documents", "c:\\users\\ann\\documents\\"));
    try std.testing.expect(!samePath("D:\\src", "D:\\src2"));
    try std.testing.expect(!samePath("D:\\src\\a", "D:\\src"));
}

test "Standing.keeps: under the saved sandbox, for what the app may reach without its command line" {
    const low = struct {
        fn of(p: []const u8) Store.Grant {
            return .{ .kind = .low, .path = p };
        }
    }.of;
    const ac = struct {
        fn of(p: []const u8) Store.Grant {
            return .{ .kind = .appcontainer, .path = p };
        }
    }.of;
    const paths = [_]Standing.Path{
        .{ .path = "D:\\rw", .access = .full },
        .{ .path = "D:\\ro", .access = .read_execute },
        .{ .path = "C:\\Users\\Ann\\Documents", .access = .read_execute },
        .{ .path = "c:\\users\\ann\\documents\\", .access = .full },
    };

    const saved_low: Standing = .{ .sandbox = .low, .paths = &paths, .cwd = .full };
    try std.testing.expectEqual(.full, saved_low.keeps(low("d:\\RW\\"), false).?);
    // Low runs don't label what they may only read.
    try std.testing.expectEqual(null, saved_low.keeps(low("D:\\ro"), false));
    // Granted twice, writable wins.
    try std.testing.expectEqual(.full, saved_low.keeps(low("C:\\Users\\Ann\\Documents"), false).?);
    // A --file, or a command-line --filesystem.
    try std.testing.expectEqual(null, saved_low.keeps(low("D:\\docs\\a.txt"), false));
    // A working directory, while the app keeps cwd; not as some other path.
    try std.testing.expectEqual(.full, saved_low.keeps(low("D:\\proj"), true).?);
    // An AppContainer grant from a command-line --sandbox.
    try std.testing.expectEqual(null, saved_low.keeps(ac("D:\\rw"), false));

    const saved_ac: Standing = .{ .sandbox = .appcontainer, .paths = &paths, .cwd = .read_execute };
    try std.testing.expectEqual(.read_execute, saved_ac.keeps(ac("D:\\ro"), false).?);
    try std.testing.expectEqual(.full, saved_ac.keeps(ac("D:\\rw"), false).?);
    try std.testing.expectEqual(.read_execute, saved_ac.keeps(ac("D:\\proj"), true).?);
    // A cwd that is also a writable path.
    try std.testing.expectEqual(.full, saved_ac.keeps(ac("D:\\rw"), true).?);
    try std.testing.expectEqual(null, saved_ac.keeps(low("D:\\rw"), false));

    // Without cwd, working directories go.
    const no_cwd: Standing = .{ .sandbox = .appcontainer, .paths = &paths };
    try std.testing.expectEqual(null, no_cwd.keeps(ac("D:\\proj"), true));
    // Nothing stands under soft, or for an app that isn't installed.
    const soft: Standing = .{ .sandbox = .soft };
    try std.testing.expectEqual(null, soft.keeps(ac("D:\\rw"), true));
    try std.testing.expectEqual(null, soft.keeps(low("D:\\rw"), true));
    // The loopback exemption never does.
    try std.testing.expectEqual(null, saved_ac.keeps(.loopback, false));

    // A folder that holds zigsaw's store: no label, and read access only.
    const own: Own = .{ .store = "D:\\zs\\store", .self_dir = null };
    const with_own: Standing = .{ .sandbox = .low, .paths = &paths, .cwd = .full, .own = own };
    try std.testing.expectEqual(null, with_own.keeps(low("D:\\zs"), true));
    try std.testing.expectEqual(.full, with_own.keeps(low("D:\\proj"), true).?);
    const ac_own: Standing = .{ .sandbox = .appcontainer, .paths = &paths, .cwd = .full, .own = own };
    try std.testing.expectEqual(.read_execute, ac_own.keeps(ac("D:\\zs"), true).?);

    // A volume's folder in the store stands as any other path.
    const volume = [_]Standing.Path{.{ .path = "D:\\zs\\store\\volumes\\pg", .access = .full }};
    const with_volume: Standing = .{ .sandbox = .low, .paths = &volume, .own = own };
    try std.testing.expectEqual(.full, with_volume.keeps(low("d:/zs/store/volumes/pg"), false).?);
    try std.testing.expectEqual(null, with_volume.keeps(low("D:\\zs\\store\\volumes\\other"), false));
}

test "Own.refusal: a volume's folder in the store, and what's in it, are the apps'" {
    const own: Own = .{ .store = "C:\\Users\\Ann\\AppData\\Local\\zigsaw", .self_dir = "C:\\Users\\Ann\\AppData\\Local\\zigsaw\\bin" };
    for ([_][]const u8{
        "C:\\Users\\Ann\\AppData\\Local\\zigsaw\\volumes\\pgdata",
        "c:/users/ann/appdata/local/zigsaw/Volumes/pgdata/base/1",
        "C:\\Users\\Ann\\AppData\\Local\\zigsaw\\volumes\\pgdata\\",
    }) |p| try std.testing.expectEqual(null, own.refusal(p));
    for ([_][]const u8{
        "C:\\Users\\Ann\\AppData\\Local\\zigsaw",
        "C:\\Users\\Ann\\AppData\\Local\\zigsaw\\volumes",
        "C:\\Users\\Ann\\AppData\\Local\\zigsaw\\volumes\\",
        // The files beside the folders.
        "C:\\Users\\Ann\\AppData\\Local\\zigsaw\\volumes\\pgdata.json",
        "C:\\Users\\Ann\\AppData\\Local\\zigsaw\\volumes\\pgdata.lock",
        "C:\\Users\\Ann\\AppData\\Local\\zigsaw\\data\\app",
        "C:\\Users\\Ann\\AppData\\Local\\zigsaw\\bin\\volumes\\pg",
    }) |p| try std.testing.expect(own.refusal(p) != null);
    // Still in the store, which no folder will do for `--path`.
    try std.testing.expect(own.contains("C:\\Users\\Ann\\AppData\\Local\\zigsaw\\volumes\\pgdata"));
}

test "Own.refusal" {
    const own: Own = .{ .store = "D:\\zs\\Store", .self_dir = "C:\\tools\\zigsaw" };
    for ([_][]const u8{ "D:\\zs\\store", "d:/zs/STORE/", "D:\\zs", "D:\\" }) |p|
        try std.testing.expectEqualStrings("zigsaw's store is in it", own.refusal(p).?);
    try std.testing.expectEqualStrings("it's in zigsaw's store", own.refusal("D:\\zs\\Store\\deploy\\0123").?);
    for ([_][]const u8{ "C:\\tools\\zigsaw", "C:\\tools" }) |p|
        try std.testing.expectEqualStrings("zigsaw is in it", own.refusal(p).?);
    try std.testing.expectEqualStrings("it's in zigsaw's folder", own.refusal("c:/tools/zigsaw/x").?);
    for ([_][]const u8{ "D:\\zs\\store2", "D:\\z", "C:\\tools\\zigsaw2", "E:\\src" }) |p|
        try std.testing.expectEqual(null, own.refusal(p));
    // Where a folder inside the path would do, and where none would.
    try std.testing.expect(own.contains("D:\\zs\\Store\\cache") and own.contains("C:\\tools\\zigsaw"));
    try std.testing.expect(!own.contains("D:\\zs") and !own.contains("D:\\"));
}

test isWithin {
    const data = "D:\\zs\\data\\org.example.app";
    for ([_][]const u8{ data, data ++ "\\", "d:/zs/DATA/org.example.app/home" }) |in| try std.testing.expect(isWithin(in, data));
    for ([_][]const u8{ "D:\\zs\\data\\org.example.app2", "D:\\zs\\data", "D:\\zs\\data\\org.example" }) |out| try std.testing.expect(!isWithin(out, data));
}
