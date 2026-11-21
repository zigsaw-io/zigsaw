//! `--format=json`: what the commands that print data print instead of their
//! text, for scripts. One JSON value on stdout, an array for a listing and an
//! object for the rest, with the keys docs/json.md lists. Every key is there,
//! null when there's nothing to say; sizes are bytes, times RFC 3339 in UTC,
//! durations milliseconds, digests whole. Exit codes and stderr are the
//! text's: only stdout changes, and where text says on stderr that there's
//! nothing to list, JSON lists nothing.

const std = @import("std");
const Io = std.Io;
const Context = @import("Context.zig");
const fail = Context.fail;

pub const Format = enum { text, json };

/// The commands that print JSON, for messages.
pub const commands = "list, info, remote-info, remote-info --show-files, search, remote-ls, remotes, ps, mask, update --check, updates, updates check, permissions, volume ls, volume inspect, doctor and version";

/// Takes `--format=<format>` or `--format <format>` out of a command's
/// arguments, into `ctx.format`, and refuses json for a command that prints
/// no JSON. `run` and `enter` keep theirs: what follows the app or the run
/// is its own, whatever it says.
pub fn take(ctx: *Context, command: []const u8, args: []const [:0]const u8) ![]const [:0]const u8 {
    if (std.mem.eql(u8, command, "run") or std.mem.eql(u8, command, "enter")) return args;
    const taken = try strip(ctx.arena, args);
    const format = switch (taken.format) {
        .none => return args,
        .invalid => |value| return fail("--format takes text or json; got \"{s}\"", .{value}),
        .missing => return fail("--format needs a value: text or json", .{}),
        .given => |f| f,
    };
    if (format == .json) if (refused(command, taken.args)) |what|
        return fail("{s} prints no JSON; --format=json is for {s}", .{ what, commands });
    ctx.format = format;
    return taken.args;
}

const Taken = struct {
    args: []const [:0]const u8,
    format: union(enum) { none, given: Format, invalid: []const u8, missing },
};

fn strip(arena: std.mem.Allocator, args: []const [:0]const u8) !Taken {
    var out: std.ArrayList([:0]const u8) = .empty;
    var taken: Taken = .{ .args = &.{}, .format = .none };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const value: []const u8 = if (std.mem.startsWith(u8, arg, "--format="))
            arg["--format=".len..]
        else if (std.mem.eql(u8, arg, "--format")) value: {
            i += 1;
            if (i == args.len) {
                taken.format = .missing;
                break;
            }
            break :value args[i];
        } else {
            try out.append(arena, arg);
            continue;
        };
        const f = std.meta.stringToEnum(Format, value) orelse {
            taken.format = .{ .invalid = value };
            break;
        };
        taken.format = .{ .given = f };
    }
    taken.args = out.items;
    return taken;
}

/// What of the command line prints no JSON, if something doesn't: the
/// command, or its form.
fn refused(command: []const u8, args: []const [:0]const u8) ?[]const u8 {
    const eql = std.mem.eql;
    const always = [_][]const u8{ "list", "info", "remotes", "search", "remote-ls", "ps", "permissions", "doctor", "version" };
    for (always) |c| if (eql(u8, command, c)) return null;
    if (eql(u8, command, "remote-info")) {
        for (args) |a| if (std.mem.startsWith(u8, a, "--file=")) return "remote-info --file";
        return null;
    }
    if (eql(u8, command, "mask")) {
        for (args) |a| {
            if (eql(u8, a, "--remove")) return "mask --remove";
            if (!std.mem.startsWith(u8, a, "-")) return "mask <app-id>";
        }
        return null;
    }
    if (eql(u8, command, "update")) {
        for (args) |a| if (eql(u8, a, "--check")) return null;
        return "update without --check";
    }
    if (eql(u8, command, "updates")) {
        if (args.len == 0) return null;
        if (!eql(u8, args[0], "check")) return "updates on and off";
        for (args[1..]) |a| if (eql(u8, a, "--notify") or eql(u8, a, "--quiet")) return "updates check --notify and --quiet";
        return null;
    }
    if (eql(u8, command, "volume")) {
        if (args.len > 0 and (eql(u8, args[0], "ls") or eql(u8, args[0], "inspect"))) return null;
        return if (args.len > 0) volumeForms(args[0]) else "volume";
    }
    return command;
}

fn volumeForms(sub: []const u8) []const u8 {
    inline for (.{ "create", "rm", "prune", "export", "import" }) |s|
        if (std.mem.eql(u8, sub, s)) return "volume " ++ s;
    return "volume";
}

/// An empty list, for `write`: what a listing with nothing in it prints.
pub const nothing = [0]bool{};

/// Writes `value` on stdout as JSON, indented, and a newline. Quiet if
/// whoever read stdout stopped, as `| head` does.
pub fn write(ctx: *Context, value: anytype) !void {
    var buf: [64 * 1024]u8 = undefined;
    var stdout = Context.stdout().writerStreaming(ctx.io, &buf);
    writeTo(&stdout.interface, value) catch return Context.stdoutFailed(&stdout);
}

pub fn writeTo(w: *Io.Writer, value: anytype) Io.Writer.Error!void {
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, w);
    try w.writeByte('\n');
    try w.flush();
}

/// One JSON object of the fields of several structs, in turn: `info` and
/// `remote-info` put what they share between what's each one's own.
pub fn merged(parts: anytype) Merged(@TypeOf(parts)) {
    return .{ .parts = parts };
}

pub fn Merged(comptime Parts: type) type {
    return struct {
        parts: Parts,

        pub fn jsonStringify(m: @This(), jw: anytype) !void {
            try jw.beginObject();
            inline for (m.parts) |part| {
                inline for (@typeInfo(@TypeOf(part)).@"struct".field_names) |name| {
                    try jw.objectField(name);
                    try jw.write(@field(part, name));
                }
            }
            try jw.endObject();
        }
    };
}

/// A moment, as JSON has it: "2026-11-21T02:32:03Z".
pub const Time = struct {
    /// Seconds since 1970, UTC.
    seconds: i64,

    /// From a FILETIME: 100 ns since 1601.
    pub fn fromFiletime(ft: i64) Time {
        return .{ .seconds = @divFloor(ft - 116_444_736_000_000_000, 10_000_000) };
    }

    /// Null for 0, which the store's files write for never.
    pub fn orNull(seconds: i64) ?Time {
        return if (seconds == 0) null else .{ .seconds = seconds };
    }

    pub fn jsonStringify(t: Time, jw: anytype) !void {
        var buf: [32]u8 = undefined;
        try jw.write(t.text(&buf));
    }

    pub fn text(t: Time, buf: *[32]u8) []const u8 {
        const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(t.seconds, 0)) };
        const year_day = es.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day = es.getDaySeconds();
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            year_day.year,             month_day.month.numeric(),  month_day.day_index + 1,
            day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute(),
        }) catch unreachable;
    }
};

const testing = std.testing;

test Time {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", (Time{ .seconds = 0 }).text(&buf));
    try testing.expectEqualStrings("2026-11-21T02:32:03Z", (Time{ .seconds = 1_795_228_323 }).text(&buf));
    // 2026-11-21T02:32:03Z as a FILETIME, and a leap day.
    try testing.expectEqualStrings("2026-11-21T02:32:03Z", Time.fromFiletime(1_795_228_323 * 10_000_000 + 116_444_736_000_000_000 + 9_999_999).text(&buf));
    try testing.expectEqualStrings("2028-02-29T23:59:59Z", (Time{ .seconds = 1_835_481_599 }).text(&buf));
    try testing.expect(Time.orNull(0) == null);

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(.{ .at = Time{ .seconds = 0 }, .never = Time.orNull(0) }, .{}, &out.writer);
    try testing.expectEqualStrings("{\"at\":\"1970-01-01T00:00:00Z\",\"never\":null}", out.written());
}

test merged {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const tail: struct { b: ?u32, c: []const u8 } = .{ .b = null, .c = "x" };
    try std.json.Stringify.value(merged(.{ .{ .a = @as(u32, 1) }, tail }), .{}, &out.writer);
    try testing.expectEqualStrings("{\"a\":1,\"b\":null,\"c\":\"x\"}", out.written());
}

test take {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Case = struct { command: []const u8, args: []const [:0]const u8, format: ?Format, rest: []const [:0]const u8 = &.{} };
    const cases = [_]Case{
        .{ .command = "list", .args = &.{"--format=json"}, .format = .json },
        .{ .command = "ps", .args = &.{ "--format", "json", "--processes", "org.a.b" }, .format = .json, .rest = &.{ "--processes", "org.a.b" } },
        .{ .command = "install", .args = &.{ "--format=text", "org.a.b" }, .format = .text, .rest = &.{"org.a.b"} },
        .{ .command = "volume", .args = &.{ "inspect", "--format=json", "v" }, .format = .json, .rest = &.{ "inspect", "v" } },
        .{ .command = "updates", .args = &.{ "check", "--format=json" }, .format = .json, .rest = &.{"check"} },
        .{ .command = "update", .args = &.{ "--check", "--format=json" }, .format = .json, .rest = &.{"--check"} },
        .{ .command = "mask", .args = &.{"--format=json"}, .format = .json },
        .{ .command = "remote-info", .args = &.{ "--show-files", "--format=json", "x" }, .format = .json, .rest = &.{ "--show-files", "x" } },
        // Refused.
        .{ .command = "install", .args = &.{ "--format=json", "org.a.b" }, .format = null },
        .{ .command = "update", .args = &.{"--format=json"}, .format = null },
        .{ .command = "mask", .args = &.{ "--format=json", "org.a.b" }, .format = null },
        .{ .command = "mask", .args = &.{ "--remove", "--format=json" }, .format = null },
        .{ .command = "remote-info", .args = &.{ "--file=a", "--format=json", "x" }, .format = null },
        .{ .command = "updates", .args = &.{ "on", "--format=json" }, .format = null },
        .{ .command = "updates", .args = &.{ "check", "--notify", "--format=json" }, .format = null },
        .{ .command = "volume", .args = &.{ "rm", "--format=json", "v" }, .format = null },
        .{ .command = "list", .args = &.{"--format=yaml"}, .format = null },
        .{ .command = "list", .args = &.{"--format"}, .format = null },
    };
    for (cases) |c| {
        var ctx: Context = .{ .io = testing.io, .gpa = testing.allocator, .arena = arena, .env = undefined, .store = undefined };
        const got = take(&ctx, c.command, c.args) catch |err| {
            try testing.expectEqual(error.Failed, err);
            try testing.expect(c.format == null);
            continue;
        };
        try testing.expectEqual(c.format.?, ctx.format);
        try testing.expectEqual(c.rest.len, got.len);
        for (c.rest, got) |want, arg| try testing.expectEqualStrings(want, arg);
    }
    // Without --format, and for run: untouched.
    var ctx: Context = .{ .io = testing.io, .gpa = testing.allocator, .arena = arena, .env = undefined, .store = undefined };
    const run_args = [_][:0]const u8{ "org.a.b", "--format=json" };
    try testing.expectEqual(@as(usize, 2), (try take(&ctx, "run", &run_args)).len);
    try testing.expectEqual(Format.text, ctx.format);
}
