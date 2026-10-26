//! How long zigsaw's changes to host paths last: the access an app's
//! AppContainer is given to a path, and the low integrity labels its low
//! runs need (see run.zig); and the loopback exemption of its container.
//! Store.zig records them in grants\<id>.txt, and which of them were a
//! run's working directory in grants\<id>.cwd.
//!
//! The loopback exemption (see appcontainer.loopback) lasts only while the
//! app's runs go: an exempt container reaches this machine whatever its
//! capabilities, so a run without the network would too, and making it
//! takes milliseconds.
//!
//! A change to a path stays between runs only while a run of the app with
//! nothing on its command line would make it again: under the sandbox the
//! app's overrides choose, for the paths and user folders its permissions and
//! overrides name, and for the working directories such runs had, while
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
const oci = @import("oci.zig");
const override = @import("override.zig");
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const note = Context.note;

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
    if ((try ctx.store.readGrants(arena, id)).len == 0 and (try ctx.store.readCwdGrants(arena, id)).len == 0) return true;
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
    const arena = ctx.arena;
    const store = ctx.store;
    const changes = try store.lockGrantChanges(arena);
    defer changes.release(ctx.io);
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
    try ctx.store.deleteGrants(arena, id);
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
            if (try ctx.store.grantedToOthers(arena, id, g)) {
                if (tell_kept) note("kept the low integrity label of {s}, which other apps' runs need", .{g.path});
                return true;
            }
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
    sandbox: override.Sandbox = .soft,
    paths: []const Path = &.{},
    /// The access its working directory would have, if it has `cwd`.
    cwd: ?acl.Access = null,

    const Path = struct { path: []const u8, access: acl.Access };

    /// From the installed app's permissions and overrides. An app that
    /// isn't installed would be given nothing.
    fn of(ctx: *Context, id: []const u8) !Standing {
        const arena = ctx.arena;
        const ref = try ctx.store.readRef(arena, id) orelse return .{};
        const image = try ctx.store.readImage(arena, id, ref.manifest);
        const saved = try override.load(ctx.store, arena, id);
        var s: Standing = .{ .sandbox = saved.sandbox orelse .soft };
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
        const a = access orelse return null;
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
    const soft: Standing = .{};
    try std.testing.expectEqual(null, soft.keeps(ac("D:\\rw"), true));
    try std.testing.expectEqual(null, soft.keeps(low("D:\\rw"), true));
    // The loopback exemption never does.
    try std.testing.expectEqual(null, saved_ac.keeps(.loopback, false));
}
