//! The device probe: what Windows lets a program reach of this machine's
//! hardware under each of zigsaw's sandboxes, and tests/devices.sh's test
//! app. Built by `zig build devprobe`.
//!
//!   zigsaw-devprobe report [<check>...]  one line per check and place:
//!                                        `<check> <place> <outcome>`
//!   zigsaw-devprobe check <check>...     runs each check where it is, one
//!                                        line each; exits 0 if all answered
//!   zigsaw-devprobe token                its own integrity level, and a line
//!                                        `capability <SID>` for each one its
//!                                        token holds
//!   zigsaw-devprobe sids                 `<check> <capability> <SID> [<SID>]`:
//!                                        the capability each check tries, as
//!                                        the SIDs below
//!   zigsaw-devprobe tokens <directory>   as `token`, for every other process
//!                                        whose program is under the directory,
//!                                        each after `# process <file name>`
//!   zigsaw-devprobe wait <ms>            exits after <ms> milliseconds
//!
//! The checks (tests/devprobe/checks.c): camera, camera-device (the camera's
//! driver, opened past Media Foundation), microphone, location, bluetooth,
//! hid, usb, serial, speakers, gpu, printer, smartcard. Each opens the device
//! as a desktop program would. THE CAMERA'S LIGHT COMES ON for the camera
//! check, once per place. Nothing a device gives is kept or printed.
//!
//! The report's places:
//!
//!   host                     this user, as the probe was started
//!   low                      at low integrity, as `--sandbox=low` runs
//!   container                an AppContainer with no capability, as
//!                            `--sandbox=appcontainer` runs are today
//!   container+<cap>          one that holds the device's capability, as the
//!                            SID Windows derives from its name
//!                            (S-1-15-3-1024-...)
//!   container+<cap>.class    one that holds it as the SID made from the
//!                            device class's GUID (S-1-15-3- and four numbers):
//!                            the class Windows registers for the capability,
//!                            or else that of the interfaces the check opens
//!   container+<cap>.both     one that holds both
//!
//! The outcomes: `ok`; `none` (no such device, or none seen from there);
//! `denied`; `empty` (opened, and nothing came); `silent` (a microphone that
//! gave only zeros, as Windows gives a program it doesn't let listen);
//! `error 0x...`; `timed out`. Some have a few words after them, in brackets.
//!
//! Before the rows, lines starting with `#` say what Windows' own privacy
//! switches are set to, which the probe reads and never changes. The report
//! uses an AppContainer profile it makes and deletes (zigsaw.test.devprobe),
//! and lets that container read the probe's own file while it runs.

const std = @import("std");
const win32 = @import("win32");

const DWORD = win32.DWORD;
const HANDLE = win32.HANDLE;

extern fn devprobe_check(name: [*:0]const u8, detail: [*]u8, size: c_int) callconv(.c) c_int;

const Check = struct {
    name: [:0]const u8,
    /// The Windows capability that may let a container reach it.
    capability: ?[]const u8 = null,
    /// The device class whose SID to try as well, where Windows registers
    /// none for the capability itself (as it does for webcam): the class of
    /// the interfaces the check opens.
    class: ?[]const u8 = null,
};

const checks = [_]Check{
    .{ .name = "camera", .capability = "webcam" },
    .{ .name = "camera-device", .capability = "webcam" },
    .{ .name = "microphone", .capability = "microphone" },
    .{ .name = "location", .capability = "location" },
    .{ .name = "bluetooth", .capability = "bluetooth", .class = "0850302A-B344-4FDA-9BE9-90576B8D46F0" },
    .{ .name = "hid", .capability = "humanInterfaceDevice", .class = "4D1E55B2-F16F-11CF-88CB-001111000030" },
    .{ .name = "usb", .capability = "usb", .class = "A5DCBF10-6530-11D2-901F-00C04FB951ED" },
    .{ .name = "serial", .capability = "serialCommunication", .class = "86E0D1E0-8089-11D0-9CE4-08003E301F73" },
    .{ .name = "speakers" },
    .{ .name = "gpu" },
    .{ .name = "printer" },
    .{ .name = "smartcard" },
};

const profile_name = "zigsaw.test.devprobe";
/// How long a check gets: a camera takes a few seconds to start.
const timeout_ms = 20_000;
/// A child's exit code once it has printed its outcome.
const printed: DWORD = 10;
const timed_out: DWORD = 0xFFFF_FFFF;

const HKLM: win32.HKEY = @ptrFromInt(0x80000002);
const consent_store = "Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\";
const capabilities_key = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\Capabilities\\";

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};
    if (args.len < 2) return usage();
    const mode = args[1];

    if (std.mem.eql(u8, mode, "report")) {
        for (args[2..]) |name| if (find(name) == null) return usage();
        try report(arena, out, args[2..]);
        return 0;
    }
    if (std.mem.eql(u8, mode, "check") and args.len > 2) {
        var failed = false;
        for (args[2..]) |name| {
            const o = run(arena, name);
            try out.print("{s} {f}\n", .{ name, o });
            if (o.code != 0) failed = true;
        }
        return @intFromBool(failed);
    }
    if (std.mem.eql(u8, mode, "token") and args.len == 2) {
        var token: ?HANDLE = null;
        if (win32.OpenProcessToken(win32.GetCurrentProcess(), win32.TOKEN_QUERY, &token) == 0) return 1;
        try printToken(out, token.?);
        return 0;
    }
    if (std.mem.eql(u8, mode, "tokens") and args.len == 3) return printTokensUnder(arena, out, args[2]);
    if (std.mem.eql(u8, mode, "wait") and args.len == 3) {
        win32.Sleep(try std.fmt.parseInt(DWORD, args[2], 10));
        return 0;
    }
    if (std.mem.eql(u8, mode, "sids") and args.len == 2) {
        for (checks) |c| {
            const cap = c.capability orelse continue;
            try out.print("{s} {s} {s}", .{ c.name, cap, try sidString(arena, try nameSid(arena, cap)) });
            if (try classSidString(arena, c)) |s| try out.print(" {s}", .{s});
            try out.writeByte('\n');
        }
        return 0;
    }
    // The report's children: the outcome, with no line end, on the stdout
    // they were handed.
    if (std.mem.eql(u8, mode, "_check") and args.len == 3) {
        try out.print("{f}", .{run(arena, args[2])});
        try out.flush();
        win32.ExitProcess(printed);
    }
    return usage();
}

fn usage() u8 {
    std.debug.print("usage: zigsaw-devprobe report [<check>...] | check <check>... | token | sids | tokens <directory> | wait <ms>\nchecks:", .{});
    for (checks) |c| std.debug.print(" {s}", .{c.name});
    std.debug.print("\n", .{});
    return 2;
}

fn find(name: []const u8) ?Check {
    for (checks) |c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

const Outcome = struct {
    code: c_int,
    detail: []const u8 = "",

    pub fn format(o: Outcome, w: *std.Io.Writer) !void {
        switch (o.code) {
            0 => try w.writeAll("ok"),
            1 => try w.writeAll("none"),
            2 => try w.writeAll("unknown check"),
            3 => try w.writeAll("empty"),
            4 => try w.writeAll("silent"),
            else => {
                const hr: u32 = @bitCast(o.code);
                if (hr == 0x80070005) try w.writeAll("denied") else try w.print("error 0x{x:0>8}", .{hr});
            },
        }
        if (o.detail.len > 0) try w.print(" ({s})", .{o.detail});
    }
};

fn run(arena: std.mem.Allocator, name: []const u8) Outcome {
    const detail = arena.alloc(u8, 200) catch return .{ .code = 2 };
    const name_z = arena.dupeSentinel(u8, name, 0) catch return .{ .code = 2 };
    const code = devprobe_check(name_z.ptr, detail.ptr, @intCast(detail.len));
    return .{ .code = code, .detail = std.mem.sliceTo(detail, 0) };
}

// ---------------------------------------------------------------------------
// The report

const Where = union(enum) {
    host,
    low,
    /// In the probe's container, with these capabilities.
    container: []win32.SID_AND_ATTRIBUTES,
};

const Spawner = struct {
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    container: win32.PSID,
    low_token: HANDLE,

    fn row(s: Spawner, check: []const u8, place: []const u8, at: Where) !void {
        try s.out.print("{s} {s} ", .{ check, place });
        try s.out.flush();
        const child = s.spawn(at, try std.fmt.allocPrint(s.arena, "_check {s}", .{check})) catch |err| {
            try s.out.print("the probe didn't start: {t}, error {d}\n", .{ err, win32.GetLastError() });
            return s.out.flush();
        };
        const code = finish(child, timeout_ms);
        if (code == printed)
            try s.out.writeByte('\n')
        else if (code == timed_out)
            try s.out.writeAll("timed out\n")
        else
            try s.out.print("the probe ended with 0x{x}\n", .{code});
        try s.out.flush();
    }

    /// Starts this program with `args`, with our stdout as its own.
    fn spawn(s: Spawner, at: Where, args: []const u8) !HANDLE {
        const arena = s.arena;
        const self = try win32.selfExePath(arena);
        const command_line = try win32.wide(arena, try std.fmt.allocPrint(arena, "\"{s}\" {s}", .{ self, args }));
        const stdout = win32.GetStdHandle(win32.STD_OUTPUT_HANDLE) orelse return error.NoStdout;
        _ = win32.SetHandleInformation(stdout, win32.HANDLE_FLAG_INHERIT, win32.HANDLE_FLAG_INHERIT);

        const attr_count: DWORD = 1 + @as(DWORD, @intFromBool(at == .container));
        var size: usize = 0;
        _ = win32.InitializeProcThreadAttributeList(null, attr_count, 0, &size);
        const attrs = try arena.alignedAlloc(u8, .of(usize), size);
        if (win32.InitializeProcThreadAttributeList(attrs.ptr, attr_count, 0, &size) == 0) return error.Spawn;
        var security: win32.SECURITY_CAPABILITIES = undefined;
        switch (at) {
            .host, .low => {},
            .container => |caps| {
                security = .{
                    .AppContainerSid = s.container,
                    .Capabilities = if (caps.len > 0) caps.ptr else null,
                    .CapabilityCount = @intCast(caps.len),
                };
                if (win32.UpdateProcThreadAttribute(attrs.ptr, 0, win32.PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, &security, @sizeOf(win32.SECURITY_CAPABILITIES), null, null) == 0)
                    return error.Spawn;
            },
        }
        var handles = [1]HANDLE{stdout};
        if (win32.UpdateProcThreadAttribute(attrs.ptr, 0, win32.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &handles, @sizeOf(HANDLE), null, null) == 0)
            return error.Spawn;
        var startup: win32.STARTUPINFOEXW = .{
            .StartupInfo = .{
                .cb = @sizeOf(win32.STARTUPINFOEXW),
                .dwFlags = win32.STARTF_USESTDHANDLES,
                .hStdOutput = stdout,
                .hStdError = stdout,
            },
            .lpAttributeList = attrs.ptr,
        };
        var info: win32.PROCESS_INFORMATION = undefined;
        const started = if (at == .low)
            win32.CreateProcessAsUserW(s.low_token, null, command_line.ptr, null, null, 1, win32.EXTENDED_STARTUPINFO_PRESENT, null, null, &startup.StartupInfo, &info)
        else
            win32.CreateProcessW(null, command_line.ptr, null, null, 1, win32.EXTENDED_STARTUPINFO_PRESENT, null, null, &startup.StartupInfo, &info);
        if (started == 0) return error.Spawn;
        _ = win32.CloseHandle(info.hThread);
        return info.hProcess;
    }
};

/// The child's exit code, or `timed_out` if it hadn't exited within `ms`
/// and was ended.
fn finish(process: HANDLE, ms: DWORD) DWORD {
    defer _ = win32.CloseHandle(process);
    if (win32.WaitForSingleObject(process, ms) != win32.WAIT_OBJECT_0) {
        _ = win32.TerminateProcess(process, 1);
        _ = win32.WaitForSingleObject(process, win32.INFINITE);
        return timed_out;
    }
    var code: DWORD = 0;
    _ = win32.GetExitCodeProcess(process, &code);
    return code;
}

fn report(arena: std.mem.Allocator, out: *std.Io.Writer, only: []const []const u8) !void {
    const container = try profile(arena, profile_name);
    defer _ = win32.DeleteAppContainerProfile(win32.wide(arena, profile_name) catch unreachable);
    // The container must be able to read the program it runs.
    const self = try win32.selfExePath(arena);
    setAccess(arena, self, container, win32.GRANT_ACCESS) catch |err|
        try out.print("# letting the container read {s} failed ({t}): its rows may not start\n", .{ self, err });
    defer setAccess(arena, self, container, win32.REVOKE_ACCESS) catch {};
    const s: Spawner = .{ .arena = arena, .out = out, .container = container, .low_token = try lowToken(arena) };

    for ([_][]const u8{ "webcam", "microphone", "location" }) |cap| {
        try out.print("# Windows' switches for {s}: this machine {s}, your apps {s}, your desktop apps {s}\n", .{
            cap,
            regString(arena, HKLM, try std.mem.concat(arena, u8, &.{ "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\", cap }), "Value") orelse "unset",
            regString(arena, win32.HKEY_CURRENT_USER, try std.mem.concat(arena, u8, &.{ consent_store, cap }), "Value") orelse "unset",
            regString(arena, win32.HKEY_CURRENT_USER, try std.mem.concat(arena, u8, &.{ consent_store, cap, "\\NonPackaged" }), "Value") orelse "unset",
        });
    }
    try out.flush();

    for (checks) |c| {
        if (only.len > 0) {
            const wanted = for (only) |name| {
                if (std.mem.eql(u8, name, c.name)) break true;
            } else false;
            if (!wanted) continue;
        }
        try s.row(c.name, "host", .host);
        try s.row(c.name, "low", .low);
        try s.row(c.name, "container", .{ .container = &.{} });
        const cap = c.capability orelse continue;
        var both: [2]win32.SID_AND_ATTRIBUTES = undefined;
        both[0] = .{ .Sid = try nameSid(arena, cap), .Attributes = win32.SE_GROUP_ENABLED };
        try s.row(c.name, try std.fmt.allocPrint(arena, "container+{s}", .{cap}), .{ .container = both[0..1] });
        const class = try classSidString(arena, c) orelse continue;
        var class_sid: ?win32.PSID = null;
        if (win32.ConvertStringSidToSidW(try win32.wide(arena, class), &class_sid) == 0) continue;
        both[1] = .{ .Sid = class_sid.?, .Attributes = win32.SE_GROUP_ENABLED };
        try s.row(c.name, try std.fmt.allocPrint(arena, "container+{s}.class", .{cap}), .{ .container = both[1..2] });
        try s.row(c.name, try std.fmt.allocPrint(arena, "container+{s}.both", .{cap}), .{ .container = both[0..2] });
    }
}

fn profile(arena: std.mem.Allocator, name: []const u8) !win32.PSID {
    const w = try win32.wide(arena, name);
    var sid: ?win32.PSID = null;
    var hr = win32.CreateAppContainerProfile(w, w, w, null, 0, &sid);
    if (hr == win32.E_ALREADY_EXISTS) hr = win32.DeriveAppContainerSidFromAppContainerName(w, &sid);
    if (hr < 0) {
        std.debug.print("AppContainer profile {s}: HRESULT 0x{x}\n", .{ name, @as(u32, @bitCast(hr)) });
        return error.NoProfile;
    }
    return sid.?;
}

/// A copy of our token at low integrity, as process.zig's
/// lowIntegrityToken makes for `--sandbox=low`.
fn lowToken(arena: std.mem.Allocator) !HANDLE {
    var own: ?HANDLE = null;
    const access = win32.TOKEN_ASSIGN_PRIMARY | win32.TOKEN_DUPLICATE | win32.TOKEN_QUERY | win32.TOKEN_ADJUST_DEFAULT;
    if (win32.OpenProcessToken(win32.GetCurrentProcess(), access, &own) == 0) return error.Token;
    defer _ = win32.CloseHandle(own.?);
    var low: ?HANDLE = null;
    if (win32.DuplicateTokenEx(own.?, 0, null, win32.SecurityImpersonation, win32.TokenPrimary, &low) == 0) return error.Token;
    var sid: ?win32.PSID = null;
    if (win32.ConvertStringSidToSidW(try win32.wide(arena, win32.low_integrity_sid), &sid) == 0) return error.BadSid;
    const label: win32.TOKEN_MANDATORY_LABEL = .{ .Label = .{ .Sid = sid.?, .Attributes = win32.SE_GROUP_INTEGRITY } };
    if (win32.SetTokenInformation(low.?, win32.TokenIntegrityLevel, &label, @sizeOf(win32.TOKEN_MANDATORY_LABEL) + win32.GetLengthSid(sid.?)) == 0)
        return error.Token;
    return low.?;
}

/// Adds an entry that lets `sid` read and execute the file `path`, or with
/// REVOKE_ACCESS takes `sid`'s entries away.
fn setAccess(arena: std.mem.Allocator, path: []const u8, sid: win32.PSID, mode: c_int) !void {
    const path_w = try win32.wide(arena, path);
    var sd: ?*anyopaque = null;
    var dacl: ?*win32.ACL = null;
    if (win32.GetNamedSecurityInfoW(path_w, win32.SE_FILE_OBJECT, win32.DACL_SECURITY_INFORMATION, null, null, &dacl, null, &sd) != 0) return error.ReadAcl;
    defer _ = win32.LocalFree(sd);
    var entries = [1]win32.EXPLICIT_ACCESS_W{.{
        .grfAccessPermissions = win32.FILE_GENERIC_READ_EXECUTE,
        .grfAccessMode = mode,
        .grfInheritance = win32.NO_INHERITANCE,
        .Trustee = .{ .ptstrName = sid },
    }};
    var new: ?*win32.ACL = null;
    if (win32.SetEntriesInAclW(1, &entries, dacl, &new) != 0) return error.MakeAcl;
    defer _ = win32.LocalFree(new);
    if (win32.SetNamedSecurityInfoW(path_w, win32.SE_FILE_OBJECT, win32.DACL_SECURITY_INFORMATION, null, null, new, null) != 0) return error.WriteAcl;
}

// ---------------------------------------------------------------------------
// Capabilities

/// The SID Windows derives from a capability's name (S-1-15-3-1024-...).
fn nameSid(arena: std.mem.Allocator, name: []const u8) !win32.PSID {
    var groups: ?[*]win32.PSID = null;
    var group_count: DWORD = 0;
    var sids: ?[*]win32.PSID = null;
    var count: DWORD = 0;
    if (win32.DeriveCapabilitySidsFromName(try win32.wide(arena, name), &groups, &group_count, &sids, &count) == 0 or count == 0)
        return error.NoCapabilitySid;
    return sids.?[0];
}

/// The SID made from the GUID of the device class Windows registers for the
/// check's capability, or else of the check's own class, if it has either:
/// S-1-15-3- and the GUID's sixteen bytes as four numbers.
fn classSidString(arena: std.mem.Allocator, check: Check) !?[]u8 {
    const registered = regString(arena, HKLM, try std.mem.concat(arena, u8, &.{ capabilities_key, check.capability.? }), "LegacyInterfaceClassGuid");
    const text: []const u8 = registered orelse check.class orelse return null;
    const g = std.mem.trim(u8, text, "{} ");
    if (g.len != 36) return null;
    const d1 = std.fmt.parseInt(u32, g[0..8], 16) catch return null;
    const w2 = std.fmt.parseInt(u32, g[9..13], 16) catch return null;
    const w3 = std.fmt.parseInt(u32, g[14..18], 16) catch return null;
    var b: [8]u32 = undefined;
    b[0] = std.fmt.parseInt(u32, g[19..21], 16) catch return null;
    b[1] = std.fmt.parseInt(u32, g[21..23], 16) catch return null;
    for (0..6) |i| b[2 + i] = std.fmt.parseInt(u32, g[24 + 2 * i ..][0..2], 16) catch return null;
    return try std.fmt.allocPrint(arena, "S-1-15-3-{d}-{d}-{d}-{d}", .{
        d1,
        w3 << 16 | w2,
        b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24,
        b[4] | b[5] << 8 | b[6] << 16 | b[7] << 24,
    });
}

fn sidString(arena: std.mem.Allocator, sid: win32.PSID) ![]u8 {
    var text: ?[*:0]u16 = null;
    if (win32.ConvertSidToStringSidW(sid, &text) == 0) return error.BadSid;
    defer _ = win32.LocalFree(text);
    return std.unicode.utf16LeToUtf8Alloc(arena, std.mem.span(text.?));
}

/// A string value of the registry, or null if it isn't there or isn't one.
fn regString(arena: std.mem.Allocator, root: win32.HKEY, path: []const u8, value: []const u8) ?[]u8 {
    var key: win32.HKEY = undefined;
    if (win32.RegOpenKeyExW(root, win32.wide(arena, path) catch return null, 0, win32.KEY_READ, &key) != win32.ERROR_SUCCESS) return null;
    defer _ = win32.RegCloseKey(key);
    var data: [256]u16 = undefined;
    var size: DWORD = @sizeOf(@TypeOf(data));
    var kind: DWORD = 0;
    if (win32.RegQueryValueExW(key, win32.wide(arena, value) catch return null, null, &kind, @ptrCast(&data), &size) != win32.ERROR_SUCCESS) return null;
    if (kind != win32.REG_SZ) return null;
    const chars = std.mem.sliceTo(data[0 .. size / 2], 0);
    return std.unicode.utf16LeToUtf8Alloc(arena, chars) catch null;
}

const TOKEN_GROUPS = extern struct {
    GroupCount: DWORD,
    Groups: [1]win32.SID_AND_ATTRIBUTES,
};
const TokenCapabilities: c_int = 30;

const PROCESSENTRY32W = extern struct {
    dwSize: DWORD = @sizeOf(PROCESSENTRY32W),
    cntUsage: DWORD = 0,
    th32ProcessID: DWORD = 0,
    th32DefaultHeapID: usize = 0,
    th32ModuleID: DWORD = 0,
    cntThreads: DWORD = 0,
    th32ParentProcessID: DWORD = 0,
    pcPriClassBase: i32 = 0,
    dwFlags: DWORD = 0,
    szExeFile: [260]u16 = @splat(0),
};
extern "kernel32" fn CreateToolhelp32Snapshot(flags: DWORD, pid: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn Process32FirstW(snapshot: HANDLE, entry: *PROCESSENTRY32W) callconv(.winapi) win32.BOOL;
extern "kernel32" fn Process32NextW(snapshot: HANDLE, entry: *PROCESSENTRY32W) callconv(.winapi) win32.BOOL;
extern "kernel32" fn QueryFullProcessImageNameW(process: HANDLE, flags: DWORD, name: [*]u16, size: *DWORD) callconv(.winapi) win32.BOOL;

/// The token of every other process whose program is under `prefix`, each
/// after a line `# process <file name>`: 0 if there was one.
fn printTokensUnder(arena: std.mem.Allocator, out: *std.Io.Writer, prefix: []const u8) !u8 {
    const snapshot = CreateToolhelp32Snapshot(0x2, 0);
    if (snapshot == win32.INVALID_HANDLE_VALUE) return 1;
    defer _ = win32.CloseHandle(snapshot);
    var entry: PROCESSENTRY32W = .{};
    var more = Process32FirstW(snapshot, &entry) != 0;
    var found = false;
    while (more) : (more = Process32NextW(snapshot, &entry) != 0) {
        if (entry.th32ProcessID == win32.GetCurrentProcessId()) continue;
        const process = win32.OpenProcess(0x1000, 0, entry.th32ProcessID) orelse continue;
        defer _ = win32.CloseHandle(process);
        var path_w: [1024]u16 = undefined;
        var len: DWORD = path_w.len;
        if (QueryFullProcessImageNameW(process, 0, &path_w, &len) == 0) continue;
        const path = try std.unicode.utf16LeToUtf8Alloc(arena, path_w[0..len]);
        if (!std.ascii.startsWithIgnoreCase(path, prefix)) continue;
        try out.print("# process {s}\n", .{std.fs.path.basename(path)});
        var token: ?HANDLE = null;
        if (win32.OpenProcessToken(process, win32.TOKEN_QUERY, &token) == 0) {
            try out.print("# token unreadable\n", .{});
            continue;
        }
        try printToken(out, token.?);
        found = true;
    }
    return @intFromBool(!found);
}

/// A token's integrity level, whether it's an AppContainer's, and the
/// capabilities it holds. Closes it.
fn printToken(out: *std.Io.Writer, token: HANDLE) !void {
    defer _ = win32.CloseHandle(token);
    var is_ac: DWORD = 0;
    var len: DWORD = 0;
    _ = win32.GetTokenInformation(token, win32.TokenIsAppContainer, &is_ac, @sizeOf(DWORD), &len);
    var label: [256]u8 align(@alignOf(win32.TOKEN_MANDATORY_LABEL)) = undefined;
    if (win32.GetTokenInformation(token, win32.TokenIntegrityLevel, &label, label.len, &len) == 0) return out.print("# integrity unreadable\n", .{});
    const sid = @as(*const win32.TOKEN_MANDATORY_LABEL, @ptrCast(&label)).Label.Sid;
    const rid = win32.GetSidSubAuthority(sid, win32.GetSidSubAuthorityCount(sid).* - 1).*;
    const level = if (rid < 0x1000) "untrusted" else if (rid < 0x2000) "low" else if (rid < 0x3000) "medium" else if (rid < 0x4000) "high" else "system";
    try out.print("# integrity {s}{s}\n", .{ level, if (is_ac != 0) ", in an AppContainer" else "" });

    var groups: [8192]u8 align(@alignOf(TOKEN_GROUPS)) = undefined;
    if (win32.GetTokenInformation(token, TokenCapabilities, &groups, groups.len, &len) == 0) return out.print("# capabilities unreadable\n", .{});
    const list: *const TOKEN_GROUPS = @ptrCast(&groups);
    const entries: [*]const win32.SID_AND_ATTRIBUTES = @ptrCast(&list.Groups);
    for (entries[0..list.GroupCount]) |e| {
        var text: ?[*:0]u16 = null;
        if (win32.ConvertSidToStringSidW(e.Sid, &text) == 0) continue;
        defer _ = win32.LocalFree(text);
        try out.print("capability {f}\n", .{std.unicode.fmtUtf16Le(std.mem.span(text.?))});
    }
}
