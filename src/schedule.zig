//! The daily check for updates: a scheduled task of the user's own, which needs
//! no administrator, starting zigsaw-notify.exe. It's made and removed through
//! Windows' schtasks.exe, by its full path.
//!
//! A store's task has its own name, `Zigsaw update check` for the default store,
//! and that followed by a hash of the store's path for another. ZIGSAW_TASK_NAME
//! replaces the first part, for tests, so that nothing they do touches a real one.
//!
//! `zigsaw updates off` leaves a file in the store saying so, for an install or an
//! upgrade to respect: it's what `--unless-off` reads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const acl = @import("acl.zig");
const process = @import("process.zig");
const shortcuts = @import("shortcuts.zig");
const win32 = @import("win32.zig");
const fail = Context.fail;
const note = Context.note;

const default_base = "Zigsaw update check";
const notify_program = "zigsaw-notify.exe";

fn base(ctx: *Context) []const u8 {
    return ctx.env.get("ZIGSAW_TASK_NAME") orelse default_base;
}

/// The name of this store's task.
pub fn taskName(ctx: *Context) ![]const u8 {
    if (shortcuts.isDefaultStore(ctx.env.get("LOCALAPPDATA"), ctx.store.root)) return base(ctx);
    return nameFor(ctx.arena, base(ctx), ctx.store.fullRoot(ctx.arena));
}

fn nameFor(arena: Allocator, name_base: []const u8, root: []const u8) ![]const u8 {
    const lower = try std.ascii.allocLowerString(arena, std.mem.trimEnd(u8, root, "\\/"));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lower, &digest, .{});
    return std.fmt.allocPrint(arena, "{s} {x}", .{ name_base, digest[0..4] });
}

const Ran = struct { code: u32, stdout: []const u8 };

/// Runs schtasks with no window and with its stderr dropped, as "no such task"
/// is an answer here. Null if it couldn't be run, or took over a minute.
fn schtasks(arena: Allocator, args: []const []const u8) !?Ran {
    const exe = try win32.systemProgram(arena, "schtasks.exe");
    const nul = win32.CreateFileW(try win32.wide(arena, "NUL"), win32.GENERIC_WRITE, win32.FILE_SHARE_WRITE, null, win32.OPEN_EXISTING, 0, null);
    defer if (nul != win32.INVALID_HANDLE_VALUE) {
        _ = win32.CloseHandle(nul);
    };
    const out = process.output(arena, .{
        .exe = exe,
        .command_line = try process.buildCommandLine(arena, exe, args),
        .creation_flags = win32.CREATE_NO_WINDOW,
        .stdio = .{ null, null, nul },
    }, "", 60 * 1000) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return null,
    } orelse return null;
    return .{ .code = out.code, .stdout = out.stdout };
}

pub fn isOn(ctx: *Context) !bool {
    const ran = try schtasks(ctx.arena, &.{ "/query", "/tn", try taskName(ctx) }) orelse return false;
    return ran.code == 0;
}

fn offMarker(ctx: *Context) ![]const u8 {
    return ctx.store.path(ctx.arena, &.{ "updates", "off" });
}

pub fn turnedOff(ctx: *Context) !bool {
    return Store.exists(ctx.io, try offMarker(ctx));
}

/// `zigsaw updates on`.
pub fn turnOn(ctx: *Context) !void {
    Io.Dir.cwd().deleteFile(ctx.io, try offMarker(ctx)) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    try register(ctx);
    note("the daily check is on: it tells you when updates are waiting, and installs nothing. `zigsaw updates off` stops it", .{});
}

/// `zigsaw updates off`: remembered, so that the next install or upgrade doesn't
/// turn it on again.
pub fn turnOff(ctx: *Context) !void {
    const arena = ctx.arena;
    const marker = try offMarker(ctx);
    try Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(marker).?);
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = marker, .data = "`zigsaw updates on` starts the daily check again.\n" });
    const name = try taskName(ctx);
    const ran = try schtasks(arena, &.{ "/delete", "/tn", name, "/f" }) orelse
        return fail("couldn't run schtasks to remove the task \"{s}\"", .{name});
    // Otherwise there was none, unless it's still there.
    if (ran.code != 0 and try isOn(ctx)) return fail("Windows wouldn't remove the task \"{s}\"", .{name});
    note("the daily check is off", .{});
}

/// Makes this store's task say what's true now, as `repair` does after zigsaw has
/// moved; only for a zigsaw in the store's own bin, so that a build elsewhere
/// doesn't take the task over. Removes the tasks of stores since deleted.
pub fn repair(ctx: *Context) !void {
    const arena = ctx.arena;
    const self_dir = std.fs.path.dirname(try win32.selfExePath(arena)).?;
    const bin = try ctx.store.path(arena, &.{"bin"});
    if (std.os.windows.eqlIgnoreCaseWtf8(self_dir, bin) and !try turnedOff(ctx) and try isOn(ctx))
        register(ctx) catch |err| switch (err) {
            error.Failed => {},
            else => |e| return e,
        };
    for (try listTasks(ctx)) |task| if (task.gone) {
        if ((try schtasks(arena, &.{ "/delete", "/tn", task.name, "/f" })) == null) continue;
        note("removed the task \"{s}\", as its store {s} is gone", .{ task.name, task.store orelse "" });
    };
}

fn register(ctx: *Context) !void {
    const arena = ctx.arena;
    const self = try win32.selfExePath(arena);
    const notify = try std.fs.path.join(arena, &.{ std.fs.path.dirname(self).?, notify_program });
    if (!try Store.exists(ctx.io, notify)) return fail("{s} isn't next to zigsaw, so the daily check has nothing to start", .{notify});
    const name = try taskName(ctx);
    const sid = try sidText(arena);
    const xml = try taskXml(arena, sid, notify, name, ctx.store.fullRoot(arena));

    // schtasks takes XML in UTF-16 only: UTF-8 is "unable to switch the encoding".
    const tmp = try ctx.store.tmpPath(arena, "task");
    defer Io.Dir.cwd().deleteFile(ctx.io, tmp) catch {};
    const wide = try std.unicode.wtf8ToWtf16LeAlloc(arena, xml);
    const bytes = try arena.alloc(u8, 2 + wide.len * 2);
    bytes[0] = 0xff;
    bytes[1] = 0xfe;
    @memcpy(bytes[2..], std.mem.sliceAsBytes(wide));
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tmp, .data = bytes });

    const ran = try schtasks(arena, &.{ "/create", "/tn", name, "/xml", tmp, "/f" }) orelse
        return fail("couldn't run schtasks to add the task \"{s}\"", .{name});
    if (ran.code != 0) return fail("Windows wouldn't add the task \"{s}\", so nothing will check for updates by itself", .{name});
}

fn sidText(arena: Allocator) ![]const u8 {
    var text: ?[*:0]u16 = null;
    if (win32.ConvertSidToStringSidW(try acl.currentUserSid(arena), &text) == 0) return win32.lastErrorFail("ConvertSidToStringSidW");
    defer _ = win32.LocalFree(text);
    return std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.span(text.?));
}

/// Daily, within an hour of noon, or as soon as it can be after that if the machine
/// was off; on battery too, as it reads a few small files; not without a network; as
/// the signed-in user, with what rights they have, and only while they're signed in.
fn taskXml(arena: Allocator, sid: []const u8, notify: []const u8, name: []const u8, root: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\<?xml version="1.0" encoding="UTF-16"?>
        \\<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
        \\  <RegistrationInfo><Description>Tells you when updates of zigsaw or its apps are waiting. It installs nothing. `zigsaw updates off` removes it.</Description></RegistrationInfo>
        \\  <Triggers>
        \\    <CalendarTrigger>
        \\      <StartBoundary>2020-01-01T12:00:00</StartBoundary>
        \\      <RandomDelay>PT1H</RandomDelay>
        \\      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
        \\    </CalendarTrigger>
        \\  </Triggers>
        \\  <Principals>
        \\    <Principal id="Author"><UserId>{s}</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal>
        \\  </Principals>
        \\  <Settings>
        \\    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
        \\    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
        \\    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
        \\    <StartWhenAvailable>true</StartWhenAvailable>
        \\    <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>
        \\    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
        \\    <Enabled>true</Enabled>
        \\  </Settings>
        \\  <Actions Context="Author">
        \\    <Exec><Command>{f}</Command><Arguments>{f}</Arguments></Exec>
        \\  </Actions>
        \\</Task>
        \\
    , .{ sid, Escaped{ .text = notify }, Escaped{ .text = try notifyArguments(arena, root, name) } });
}

fn notifyArguments(arena: Allocator, root: []const u8, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "--store ");
    try process.appendQuoted(arena, &out, std.mem.trimEnd(u8, root, "\\/"));
    try out.appendSlice(arena, " --task ");
    try process.appendQuoted(arena, &out, name);
    return out.items;
}

const Escaped = struct {
    text: []const u8,

    pub fn format(e: Escaped, w: *Io.Writer) Io.Writer.Error!void {
        for (e.text) |c| switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            else => try w.writeByte(c),
        };
    }
};

pub const Task = struct {
    name: []const u8,
    /// The store it's for, if its arguments can be read. schtasks writes to a pipe
    /// in the OEM code page, so one with a path outside ASCII can't, and stays.
    store: ?[]const u8,
    gone: bool,
};

/// Every daily check of this user's, whichever store it's for.
pub fn listTasks(ctx: *Context) ![]const Task {
    const arena = ctx.arena;
    var tasks: std.ArrayList(Task) = .empty;
    const all = try schtasks(arena, &.{ "/query", "/fo", "csv", "/nh" }) orelse return tasks.items;
    if (all.code != 0) return tasks.items;
    const prefix = try std.fmt.allocPrint(arena, "\"\\{s}", .{base(ctx)});
    var lines = std.mem.tokenizeAny(u8, all.stdout, "\r\n");
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const end = std.mem.indexOfScalarPos(u8, line, 1, '"') orelse continue;
        const name = line[2..end];
        const store = storeOfTask(arena, try schtasks(arena, &.{ "/query", "/tn", name, "/xml" }));
        const gone = if (store) |s| !try Store.exists(ctx.io, s) else false;
        try tasks.append(arena, .{ .name = name, .store = store, .gone = gone });
    }
    return tasks.items;
}

fn storeOfTask(arena: Allocator, xml: ?Ran) ?[]const u8 {
    const ran = xml orelse return null;
    if (ran.code != 0) return null;
    return parseStore(arena, ran.stdout) catch null;
}

/// The store a task's XML names, or null if it names none, or isn't all ASCII.
fn parseStore(arena: Allocator, xml: []const u8) !?[]const u8 {
    const open = "<Arguments>--store ";
    const start = (std.mem.indexOf(u8, xml, open) orelse return null) + open.len;
    const end = std.mem.indexOfPos(u8, xml, start, " --task ") orelse return null;
    const text = xml[start..end];
    for (text) |c| if (!std.ascii.isAscii(c)) return null;
    // Task Scheduler may write the quotes around a path with a space either way.
    const unquoted = try std.mem.replaceOwned(u8, arena, text, "&quot;", "\"");
    const plain = try std.mem.replaceOwned(u8, arena, unquoted, "&amp;", "&");
    return std.mem.trim(u8, plain, "\"");
}

test nameFor {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try nameFor(arena, default_base, "D:\\Stores\\One");
    try std.testing.expectEqualStrings(a, try nameFor(arena, default_base, "d:\\stores\\one\\"));
    try std.testing.expect(!std.mem.eql(u8, a, try nameFor(arena, default_base, "D:\\Stores\\Two")));
    try std.testing.expect(std.mem.startsWith(u8, a, "Zigsaw update check "));
}

test parseStore {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const start = "<Exec><Command>x</Command><Arguments>--store ";
    const end = " --task \"n\"</Arguments></Exec>";
    try std.testing.expectEqualStrings("D:\\zs\\plain", (try parseStore(arena, start ++ "D:\\zs\\plain" ++ end)).?);
    try std.testing.expectEqualStrings("D:\\zs\\a store", (try parseStore(arena, start ++ "\"D:\\zs\\a store\"" ++ end)).?);
    try std.testing.expectEqualStrings("D:\\zs\\a&b c", (try parseStore(arena, start ++ "&quot;D:\\zs\\a&amp;b c&quot;" ++ end)).?);
    // Through a pipe, a path outside ASCII comes in the OEM code page: not to be trusted.
    try std.testing.expectEqual(@as(?[]const u8, null), try parseStore(arena, start ++ "D:\\caf\xe9" ++ end));
    try std.testing.expectEqual(@as(?[]const u8, null), try parseStore(arena, "<Arguments>other</Arguments>"));
}
