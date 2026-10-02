//! MSVC as a host toolchain, for recipes with `"host": ["msvc"]`. Visual
//! Studio can't be an image (its license doesn't allow redistributing it), so
//! the build uses the one installed on the machine: vswhere finds it, and its
//! vcvars64.bat says what the build environment needs. Images built this way
//! record the versions used, and aren't expected to reproduce elsewhere.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const environment = @import("environment.zig");
const process = @import("process.zig");
const fail = Context.fail;

pub const Toolchain = struct {
    /// Directories vcvars puts on PATH, in its order.
    path: []const []const u8,
    /// The other variables it sets, such as INCLUDE and LIB.
    vars: []const environment.Var,
    /// VCToolsVersion, e.g. "14.51.36231".
    tools_version: []const u8,
    /// WindowsSDKVersion, e.g. "10.0.26100.0".
    sdk_version: []const u8,
};

const vc_component = "Microsoft.VisualStudio.Component.VC.Tools.x86.x64";

/// Finds the newest Visual Studio with the C++ tools, prereleases included,
/// and returns the environment its vcvars64.bat sets up. `scratch` is a
/// directory for the output of the commands that tell.
pub fn find(ctx: *Context, scratch: []const u8) !Toolchain {
    const io = ctx.io;
    const arena = ctx.arena;
    const program_files = ctx.env.get("ProgramFiles(x86)") orelse ctx.env.get("ProgramFiles") orelse "C:\\Program Files (x86)";
    const vswhere = try std.fmt.allocPrint(arena, "{s}\\Microsoft Visual Studio\\Installer\\vswhere.exe", .{program_files});
    if (!try Store.exists(io, vswhere))
        return fail("the recipe builds with MSVC (\"host\": [\"msvc\"]), but Visual Studio isn't installed: there's no {s}", .{vswhere});

    const where_out = try std.fs.path.join(arena, &.{ scratch, "vswhere.txt" });
    try runCmd(ctx, scratch, try std.fmt.allocPrint(arena, "\"{s}\" -latest -prerelease -products * -requires {s} -property installationPath > \"{s}\"", .{ vswhere, vc_component, where_out }));
    const install_dir = std.mem.trim(u8, try readUtf16(io, arena, where_out), " \r\n");
    if (install_dir.len == 0)
        return fail("the recipe builds with MSVC, but no Visual Studio installation has the C++ tools ({s})", .{vc_component});
    const vcvars = try std.fmt.allocPrint(arena, "{s}\\VC\\Auxiliary\\Build\\vcvars64.bat", .{install_dir});
    if (!try Store.exists(io, vcvars))
        return fail("{s} has no {s}", .{ install_dir, vcvars });

    // vcvars calls vswhere by name, and sends telemetry unless told not to.
    const set_out = try std.fs.path.join(arena, &.{ scratch, "vcvars.txt" });
    try runCmd(ctx, scratch, try std.fmt.allocPrint(arena, "set \"PATH={s};%PATH%\" && set \"VSCMD_SKIP_SENDTELEMETRY=1\" && \"{s}\" > nul && set > \"{s}\"", .{
        std.fs.path.dirname(vswhere).?, vcvars, set_out,
    }));
    return try fromSetOutput(arena, ctx.env, try readUtf16(io, arena, set_out)) orelse
        fail("{s} didn't set up MSVC (no VCToolsVersion)", .{vcvars});
}

/// Runs a command line in cmd.exe with our own environment. `/u` makes cmd
/// write its own commands' output (`set`) as UTF-16, so names outside the
/// ANSI code page survive.
fn runCmd(ctx: *Context, cwd: []const u8, command: []const u8) !void {
    const arena = ctx.arena;
    const cmd = try std.fmt.allocPrint(arena, "{s}\\System32\\cmd.exe", .{ctx.env.get("SystemRoot") orelse "C:\\Windows"});
    var line: std.ArrayList(u8) = .empty;
    try process.appendQuoted(arena, &line, cmd);
    try line.print(arena, " /d /u /s /c \"{s}\"", .{command});
    const code = try process.spawn(arena, .{ .exe = cmd, .command_line = line.items, .cwd = cwd });
    if (code != 0) return fail("finding MSVC: `{s}` exited with code {d}", .{ command, code });
}

/// A file cmd.exe wrote: UTF-16 when it starts with a byte-order mark or
/// looks like it, otherwise taken as is.
fn readUtf16(io: Io, arena: Allocator, p: []const u8) ![]const u8 {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(16 << 20));
    const utf16 = (bytes.len >= 2 and bytes[1] == 0) or std.mem.startsWith(u8, bytes, "\xff\xfe");
    if (!utf16) return bytes;
    const start: usize = if (std.mem.startsWith(u8, bytes, "\xff\xfe")) 2 else 0;
    const units = try arena.alloc(u16, (bytes.len - start) / 2);
    for (units, 0..) |*u, i| u.* = std.mem.readInt(u16, bytes[start + 2 * i ..][0..2], .little);
    return std.unicode.wtf16LeToWtf8Alloc(arena, units);
}

/// What vcvars changed, from `set` output: the PATH entries it added, and the
/// variables that are new or different from `host`.
fn fromSetOutput(arena: Allocator, host: *const std.process.Environ.Map, text: []const u8) !?Toolchain {
    var path: std.ArrayList([]const u8) = .empty;
    var vars: std.ArrayList(environment.Var) = .empty;
    var tools_version: ?[]const u8 = null;
    var sdk_version: ?[]const u8 = null;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (eq == 0) continue;
        const name = line[0..eq];
        const value = line[eq + 1 ..];
        if (std.ascii.eqlIgnoreCase(name, "PATH")) {
            const before = host.get("PATH") orelse host.get("Path") orelse "";
            var entries = std.mem.tokenizeScalar(u8, value, ';');
            while (entries.next()) |entry| if (!hasPathEntry(before, entry)) try path.append(arena, entry);
            continue;
        }
        if (host.get(name)) |old| if (std.mem.eql(u8, old, value)) continue;
        try vars.append(arena, .{ .name = name, .value = value });
        if (std.ascii.eqlIgnoreCase(name, "VCToolsVersion")) tools_version = std.mem.trimEnd(u8, value, "\\");
        if (std.ascii.eqlIgnoreCase(name, "WindowsSDKVersion")) sdk_version = std.mem.trimEnd(u8, value, "\\");
    }
    return .{
        .path = path.items,
        .vars = vars.items,
        .tools_version = tools_version orelse return null,
        .sdk_version = sdk_version orelse "unknown",
    };
}

fn hasPathEntry(path_var: []const u8, dir: []const u8) bool {
    const want = std.mem.trimEnd(u8, dir, "\\");
    var it = std.mem.tokenizeScalar(u8, path_var, ';');
    while (it.next()) |entry| {
        if (std.os.windows.eqlIgnoreCaseWtf8(std.mem.trimEnd(u8, entry, "\\"), want)) return true;
    }
    return false;
}

test fromSetOutput {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var host: std.process.Environ.Map = .init(arena);
    try host.put("Path", "C:\\Windows\\System32;C:\\Tools");
    try host.put("TEMP", "C:\\Temp");
    const out =
        "INCLUDE=C:\\VS\\include;C:\\SDK\\include\r\n" ++
        "Path=C:\\VS\\bin;C:\\SDK\\bin\\;C:\\Windows\\System32;C:\\Tools\\\r\n" ++
        "TEMP=C:\\Temp\r\n" ++
        "VCToolsVersion=14.51.36231\r\n" ++
        "WindowsSDKVersion=10.0.26100.0\\\r\n";
    const t = (try fromSetOutput(arena, &host, out)).?;
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "C:\\VS\\bin", "C:\\SDK\\bin\\" }), t.path);
    try std.testing.expectEqual(3, t.vars.len);
    try std.testing.expectEqualStrings("INCLUDE", t.vars[0].name);
    try std.testing.expectEqualStrings("14.51.36231", t.tools_version);
    try std.testing.expectEqualStrings("10.0.26100.0", t.sdk_version);
    try std.testing.expectEqual(null, try fromSetOutput(arena, &host, "TEMP=C:\\Temp\r\n"));
}
