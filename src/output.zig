//! `--format=json`: what commands print instead of their text, for scripts.
//! One JSON value on stdout, an array for a listing and an object for the
//! rest, with the keys docs/json.md lists. Every key is there, null when
//! there's nothing to say; sizes are bytes, times RFC 3339 in UTC, durations
//! milliseconds, digests whole. Exit codes and stderr are the text's: only
//! stdout changes, and where text says on stderr that there's nothing to
//! list, JSON lists nothing.
//!
//! A command that changes something prints what it did, once it's done; one
//! that stops at its first failure prints nothing then, and one that goes on
//! past failures (`update`, `repair`, `kill`, `down`) prints what it did
//! with what failed. Library functions return what they did, and the
//! command writes it, so that an install inside an update writes nothing.

const std = @import("std");
const Io = std.Io;
const Context = @import("Context.zig");
const fail = Context.fail;

pub const Format = enum { text, json };

/// Takes `--format=<format>` or `--format <format>` out of a command's
/// arguments, into `ctx.format`, and refuses json for what prints no JSON.
/// `run` and `enter` keep theirs: what follows the app or the run is its
/// own, whatever it says, so they take `--format` among their own options
/// (see `parse`).
pub fn take(ctx: *Context, command: []const u8, args: []const [:0]const u8) ![]const [:0]const u8 {
    if (std.mem.eql(u8, command, "run") or std.mem.eql(u8, command, "enter")) return args;
    const taken = try strip(ctx.arena, args);
    const format = switch (taken.format) {
        .none => return args,
        .invalid => |value| return invalid(value),
        .missing => return fail("--format needs a value: text or json", .{}),
        .given => |f| f,
    };
    if (format == .json) if (refused(command, taken.args)) |r|
        return fail("{s} prints no JSON: {s}", .{ r.what, r.why });
    ctx.format = format;
    return taken.args;
}

/// A value of `--format`, as `run` and `enter` take it among their options.
pub fn parse(value: []const u8) error{Failed}!Format {
    return std.meta.stringToEnum(Format, value) orelse invalid(value);
}

fn invalid(value: []const u8) error{Failed} {
    return fail("--format takes text or json; got \"{s}\"", .{value});
}

/// For `run` and `enter`, once their options are read: JSON only detached,
/// when what they print is the run's number, not the app's output.
pub fn checkDetached(ctx: *const Context, command: []const u8, detached: bool) error{Failed}!void {
    if (ctx.format == .json and !detached)
        return fail("{s} prints no JSON without -d: what it prints is the app's", .{command});
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

const Refusal = struct { what: []const u8, why: []const u8 };

/// What of the command line prints no JSON, if something doesn't, and why:
/// what it prints on stdout is something else's, or there is nothing.
fn refused(command: []const u8, args: []const [:0]const u8) ?Refusal {
    const eql = std.mem.eql;
    const has = struct {
        fn f(list: []const [:0]const u8, name: []const u8) bool {
            for (list) |a| if (eql(u8, a, name)) return true;
            return false;
        }
    }.f;
    if (eql(u8, command, "logs"))
        return .{ .what = "logs", .why = "what it prints is the runs' logs" };
    if (eql(u8, command, "up") and !has(args, "-d") and !has(args, "--detach"))
        return .{ .what = "up without -d", .why = "it prints the apps' logs as they come" };
    if (eql(u8, command, "remote-info")) for (args) |a| if (std.mem.startsWith(u8, a, "--file="))
        return .{ .what = "remote-info --file", .why = "what it prints is the file" };
    if (eql(u8, command, "build-sign") and has(args, "--print-payload"))
        return .{ .what = "build-sign --print-payload", .why = "what it prints is the payload to sign" };
    if (eql(u8, command, "updates") and args.len > 0 and eql(u8, args[0], "check")) {
        if (has(args, "--notify")) return .{ .what = "updates check --notify", .why = "what it prints is for zigsaw-notify" };
        if (has(args, "--quiet")) return .{ .what = "updates check --quiet", .why = "it prints nothing" };
    }
    // `volume export <volume> -`: stdout is the archive.
    if (eql(u8, command, "volume") and args.len > 0 and eql(u8, args[0], "export")) {
        var words: usize = 0;
        for (args[1..]) |a| {
            if (std.mem.startsWith(u8, a, "--")) continue;
            words += 1;
            if (words == 2 and eql(u8, a, "-")) return .{ .what = "volume export to -", .why = "what it prints is the archive" };
        }
    }
    if (eql(u8, command, "build-check") or eql(u8, command, "lazy-helper"))
        return .{ .what = command, .why = "it's zigsaw's own" };
    return null;
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
            year_day.year,         month_day.month.numeric(), month_day.day_index + 1,
            day.getHoursIntoDay(), day.getMinutesIntoHour(),  day.getSecondsIntoMinute(),
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
        // What changes something, since 0.108.
        .{ .command = "install", .args = &.{ "--format=json", "org.a.b" }, .format = .json, .rest = &.{"org.a.b"} },
        .{ .command = "update", .args = &.{"--format=json"}, .format = .json },
        .{ .command = "mask", .args = &.{ "--remove", "--format=json", "org.a.b" }, .format = .json, .rest = &.{ "--remove", "org.a.b" } },
        .{ .command = "updates", .args = &.{ "on", "--format=json" }, .format = .json, .rest = &.{"on"} },
        .{ .command = "volume", .args = &.{ "rm", "--format=json", "v" }, .format = .json, .rest = &.{ "rm", "v" } },
        .{ .command = "volume", .args = &.{ "export", "v", "--format=json", "v.tar" }, .format = .json, .rest = &.{ "export", "v", "v.tar" } },
        .{ .command = "volume", .args = &.{ "import", "v", "-", "--format=json" }, .format = .json, .rest = &.{ "import", "v", "-" } },
        .{ .command = "up", .args = &.{ "-d", "--format=json" }, .format = .json, .rest = &.{"-d"} },
        // Refused.
        .{ .command = "logs", .args = &.{ "--format=json", "1" }, .format = null },
        .{ .command = "up", .args = &.{"--format=json"}, .format = null },
        .{ .command = "remote-info", .args = &.{ "--file=a", "--format=json", "x" }, .format = null },
        .{ .command = "build-sign", .args = &.{ "--print-payload", "--format=json", "x" }, .format = null },
        .{ .command = "updates", .args = &.{ "check", "--notify", "--format=json" }, .format = null },
        .{ .command = "updates", .args = &.{ "check", "--quiet", "--format=json" }, .format = null },
        .{ .command = "volume", .args = &.{ "export", "--all", "v", "-", "--format=json" }, .format = null },
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
    // Which they take among their own options, detached only.
    try testing.expectEqual(Format.json, try parse("json"));
    try testing.expectError(error.Failed, parse("yaml"));
    try checkDetached(&ctx, "run", false);
    ctx.format = .json;
    try checkDetached(&ctx, "run", true);
    try testing.expectError(error.Failed, checkDetached(&ctx, "run", false));
}
