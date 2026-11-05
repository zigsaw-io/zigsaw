//! `zigsaw updates`: what's waiting to be installed, which a daily check finds out
//! and tells the user about. Nothing here installs anything: that's `zigsaw update`
//! and `zigsaw upgrade`, when the user runs them.
//!
//! The check keeps what it found in <store>\updates\state.json. Explorer saying it
//! showed a notification doesn't mean anyone saw it (a banner lasts seconds, and one
//! that's missed leaves nothing behind), so what's waiting is told again every few
//! days until the user has looked, by `zigsaw updates` or by clicking.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const oci = @import("oci.zig");
const schedule = @import("schedule.zig");
const repeat = @import("testing.zig").repeat;
const update = @import("update.zig");
const upgrade = @import("upgrade.zig");
const note = Context.note;

/// How long until what's waiting and not looked at is told again.
const remind_after_seconds = 3 * 24 * 60 * 60;

const State = struct {
    /// When it last checked, in seconds since 1970; 0 if it never did.
    checked: i64 = 0,
    apps: []const update.Waiting = &.{},
    /// The apps it couldn't check, last time.
    failed: []const []const u8 = &.{},
    /// A newer zigsaw's version, if there is one.
    zigsaw: ?[]const u8 = null,
    zigsaw_failed: bool = false,
    /// What the last notification was about, and when.
    notified: []const []const u8 = &.{},
    notified_at: i64 = 0,
    /// What was waiting when the user last looked.
    seen: []const []const u8 = &.{},

    /// One name per thing waiting, for comparing what's told with what was.
    fn items(s: State, arena: Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (s.apps) |app| try out.append(arena, try std.fmt.allocPrint(arena, "{s}@{s}", .{ app.id, app.to_digest }));
        if (s.zigsaw) |v| try out.append(arena, try std.fmt.allocPrint(arena, "zigsaw@{s}", .{v}));
        return out.items;
    }
};

fn statePath(ctx: *Context) ![]const u8 {
    return ctx.store.path(ctx.arena, &.{ "updates", "state.json" });
}

fn load(ctx: *Context) !State {
    const arena = ctx.arena;
    const bytes = Io.Dir.cwd().readFileAlloc(ctx.io, try statePath(ctx), arena, .limited(4 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => |e| return e,
    };
    // A file from something newer or broken is only ever what a check finds again.
    return std.json.parseFromSliceLeaky(State, arena, bytes, .{ .ignore_unknown_fields = true }) catch .{};
}

fn save(ctx: *Context, state: State) !void {
    const arena = ctx.arena;
    const dest = try statePath(ctx);
    try Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(dest).?);
    const tmp = try ctx.store.tmpPath(arena, "updates");
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tmp, .data = try oci.toJson(arena, state) });
    try Store.renameRetrying(ctx.io, tmp, dest, 2000);
}

/// What the file says that's still so: an app since updated or removed isn't
/// waiting any more, whenever the last check was.
fn stillWaiting(ctx: *Context, state: State) !State {
    const arena = ctx.arena;
    var apps: std.ArrayList(update.Waiting) = .empty;
    for (state.apps) |app| {
        const ref = try ctx.store.readRef(arena, app.id) orelse continue;
        if (std.mem.eql(u8, ref.manifest, app.from_digest)) try apps.append(arena, app);
    }
    var live = state;
    live.apps = apps.items;
    if (state.zigsaw) |v| if (!upgrade.isNewer(v)) {
        live.zigsaw = null;
    };
    return live;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

/// Whether to tell the user now: something's waiting they haven't looked at, and
/// either the last notification wasn't about it, or that was long enough ago.
fn due(state: State, items: []const []const u8, now: i64) bool {
    var unseen = false;
    var new = false;
    for (items) |item| {
        if (!contains(state.seen, item)) unseen = true;
        if (!contains(state.notified, item)) new = true;
    }
    if (!unseen) return false;
    return new or now - state.notified_at >= remind_after_seconds;
}

/// Two lines: a title and a text, for a notification. Short, as Windows cuts off
/// a title at 63 characters and a text at 255; the text can't name everything.
fn writeNotification(w: *Io.Writer, state: State) !void {
    const count = state.apps.len + @intFromBool(state.zigsaw != null);
    try w.print("zigsaw: {d} update{s} waiting\n", .{ count, if (count == 1) "" else "s" });
    if (state.apps.len > 0) {
        const first = state.apps[0];
        try w.print("{s} {s} to {s}", .{ clip(first.id, 80), clip(first.from, 30), clip(first.to, 30) });
        if (count > 1) try w.print(", and {d} more", .{count - 1});
    } else try w.print("zigsaw {s} is out", .{clip(state.zigsaw.?, 30)});
    try w.writeAll(". Click to see what's waiting; nothing gets installed.\n");
}

/// At most `max` bytes of `text`, ending between characters: a version comes from a
/// registry, and half a character would stop the notification being shown at all.
fn clip(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    return text[0..end];
}

pub const CheckOptions = struct {
    /// Writes a notification on stdout if one is due, for zigsaw-notify.
    notify: bool = false,
    /// Writes nothing: for zigsaw-notify, while Windows holds notifications back.
    quiet: bool = false,
};

/// `zigsaw updates check`: finds out what's waiting, and keeps it. Returns the exit
/// code: 1 if something couldn't be checked. An app that can't be checked now, as
/// without a network, keeps what the last check found for it.
pub fn check(ctx: *Context, opts: CheckOptions) !u32 {
    const arena = ctx.arena;
    const before = try load(ctx);
    var state = before;

    var apps: std.ArrayList(update.Waiting) = .empty;
    var failed: std.ArrayList([]const u8) = .empty;
    for (try update.refsOf(ctx, &.{})) |ref| {
        const found = update.newImage(ctx, ref) catch |err| {
            if (err != error.Failed) note("{s}: {t}", .{ ref.id, err });
            try failed.append(arena, ref.id);
            for (before.apps) |app| if (std.mem.eql(u8, app.id, ref.id)) try apps.append(arena, app);
            continue;
        };
        if (found) |app| try apps.append(arena, app);
    }
    state.apps = apps.items;
    state.failed = failed.items;

    state.zigsaw_failed = false;
    if (upgrade.applies(ctx)) {
        if (upgrade.newer(ctx)) |v| {
            state.zigsaw = v;
        } else |err| {
            if (err != error.Failed) note("zigsaw's latest version: {t}", .{err});
            state.zigsaw_failed = true;
        }
    } else state.zigsaw = null;

    state.checked = Io.Timestamp.now(ctx.io, .real).toSeconds();
    state = try stillWaiting(ctx, state);
    const items = try state.items(arena);

    if (opts.notify and due(state, items, state.checked)) {
        state.notified = items;
        state.notified_at = state.checked;
        var buf: [1024]u8 = undefined;
        var stdout = Context.stdout().writerStreaming(ctx.io, &buf);
        try writeNotification(&stdout.interface, state);
        try stdout.interface.flush();
    }
    try save(ctx, state);
    if (!opts.notify and !opts.quiet) try writeList(ctx, state, try schedule.isOn(ctx));
    return @intFromBool(failed.items.len > 0 or state.zigsaw_failed);
}

/// `zigsaw updates`: what the last check found, reading nothing from any network.
/// Having looked, the user isn't told about these again.
pub fn show(ctx: *Context) !void {
    const state = try stillWaiting(ctx, try load(ctx));
    try writeList(ctx, state, try schedule.isOn(ctx));
    const items = try state.items(ctx.arena);
    if (items.len == 0) return;
    var looked = state;
    looked.seen = items;
    try save(ctx, looked);
}

fn writeList(ctx: *Context, state: State, on: bool) !void {
    const arena = ctx.arena;
    var buf: [4096]u8 = undefined;
    var stdout = Context.stdout().writerStreaming(ctx.io, &buf);
    const w = &stdout.interface;
    if (state.checked == 0) {
        try w.writeAll("Nothing has checked for updates yet. `zigsaw updates check` does now.\n");
    } else {
        const ago = Io.Timestamp.now(ctx.io, .real).toSeconds() - state.checked;
        try w.print("Last checked {f}.\n", .{Ago{ .seconds = ago }});
        if (state.apps.len == 0 and state.zigsaw == null) try w.writeAll("Nothing is waiting.\n");
        if (state.apps.len > 0) {
            try w.writeAll("\nWaiting to be installed, with `zigsaw update`:\n");
            for (state.apps) |app| {
                try w.writeAll("  ");
                try app.write(w);
            }
        }
        if (state.zigsaw) |v| {
            try w.print("\nzigsaw {s} is out; this is {s}. `zigsaw upgrade` installs it.\n", .{ v, upgrade.this_version });
        }
        if (state.failed.len > 0) try w.print("\nCouldn't check {s}: `zigsaw update --check` says why.\n", .{try std.mem.join(arena, ", ", state.failed)});
        if (state.zigsaw_failed) try w.writeAll("\nCouldn't find out zigsaw's latest version.\n");
    }
    if (on) {
        try w.writeAll("\nA daily check is on; it installs nothing. `zigsaw updates off` stops it.\n");
    } else {
        try w.writeAll("\nNo daily check is on. `zigsaw updates on` starts one, which installs nothing.\n");
    }
    try w.flush();
}

const Ago = struct {
    seconds: i64,

    pub fn format(a: Ago, w: *Io.Writer) Io.Writer.Error!void {
        const s = @max(a.seconds, 0);
        const unit: struct { n: i64, name: []const u8 } = if (s < 60)
            return w.writeAll("just now")
        else if (s < 60 * 60)
            .{ .n = @divFloor(s, 60), .name = "minute" }
        else if (s < 24 * 60 * 60)
            .{ .n = @divFloor(s, 60 * 60), .name = "hour" }
        else
            .{ .n = @divFloor(s, 24 * 60 * 60), .name = "day" };
        try w.print("{d} {s}{s} ago", .{ unit.n, unit.name, if (unit.n == 1) "" else "s" });
    }
};

/// One line for `zigsaw list`, if anything's waiting.
pub fn noteWaiting(ctx: *Context) !void {
    const state = try stillWaiting(ctx, try load(ctx));
    const count = state.apps.len + @intFromBool(state.zigsaw != null);
    if (count > 0) note("note: {d} update{s} waiting: `zigsaw updates` lists {s}", .{ count, if (count == 1) "" else "s", if (count == 1) "it" else "them" });
}

test due {
    const day = 24 * 60 * 60;
    const a: []const []const u8 = &.{"a@1"};
    const ab: []const []const u8 = &.{ "a@1", "b@1" };
    // Nothing waiting: nothing to tell.
    try std.testing.expect(!due(.{}, &.{}, 100 * day));
    // Never told.
    try std.testing.expect(due(.{}, a, 100 * day));
    // Told today, then not again today, or tomorrow.
    try std.testing.expect(!due(.{ .notified = a, .notified_at = 100 * day }, a, 100 * day));
    try std.testing.expect(!due(.{ .notified = a, .notified_at = 100 * day }, a, 102 * day));
    // A missed banner leaves nothing, so it comes back.
    try std.testing.expect(due(.{ .notified = a, .notified_at = 100 * day }, a, 103 * day));
    // Unless they've looked.
    try std.testing.expect(!due(.{ .notified = a, .notified_at = 100 * day, .seen = a }, a, 200 * day));
    // Something new is told at once.
    try std.testing.expect(due(.{ .notified = a, .notified_at = 100 * day, .seen = a }, ab, 100 * day));
    // One of two updated: what's left was told about and looked at.
    try std.testing.expect(!due(.{ .notified = ab, .notified_at = 100 * day, .seen = ab }, a, 200 * day));
}

test writeNotification {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const app: update.Waiting = .{ .id = "org.a", .from = "1", .to = "2", .from_digest = "sha256:0", .to_digest = "sha256:1" };
    try writeNotification(&out.writer, .{ .apps = &.{app} });
    try std.testing.expectEqualStrings("zigsaw: 1 update waiting\norg.a 1 to 2. Click to see what's waiting; nothing gets installed.\n", out.written());
    out.clearRetainingCapacity();
    try writeNotification(&out.writer, .{ .apps = &.{ app, app }, .zigsaw = "9.0.0" });
    try std.testing.expectEqualStrings("zigsaw: 3 updates waiting\norg.a 1 to 2, and 2 more. Click to see what's waiting; nothing gets installed.\n", out.written());
    out.clearRetainingCapacity();
    try writeNotification(&out.writer, .{ .zigsaw = "9.0.0" });
    try std.testing.expectEqualStrings("zigsaw: 1 update waiting\nzigsaw 9.0.0 is out. Click to see what's waiting; nothing gets installed.\n", out.written());
}

test "what a notification says fits what Windows shows" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const long = repeat("x", 400);
    const app: update.Waiting = .{ .id = long, .from = long, .to = long, .from_digest = "sha256:0", .to_digest = "sha256:1" };
    try writeNotification(&out.writer, .{ .apps = &.{app} });
    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    try std.testing.expect(lines.next().?.len <= 63);
    try std.testing.expect(lines.next().?.len <= 255);
}

test clip {
    try std.testing.expectEqualStrings("abc", clip("abc", 3));
    try std.testing.expectEqualStrings("ab", clip("abc", 2));
    // The two bytes of an e with an acute accent: not one of them.
    try std.testing.expectEqualStrings("a", clip("a\xc3\xa9", 2));
    try std.testing.expectEqualStrings("a\xc3\xa9", clip("a\xc3\xa9b", 3));
}

test Ago {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for ([_]struct { s: i64, want: []const u8 }{
        .{ .s = -5, .want = "just now" },
        .{ .s = 59, .want = "just now" },
        .{ .s = 60, .want = "1 minute ago" },
        .{ .s = 2 * 60 * 60, .want = "2 hours ago" },
        .{ .s = 24 * 60 * 60, .want = "1 day ago" },
    }) |c| {
        out.clearRetainingCapacity();
        try out.writer.print("{f}", .{Ago{ .seconds = c.s }});
        try std.testing.expectEqualStrings(c.want, out.written());
    }
}
