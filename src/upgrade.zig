//! `zigsaw upgrade`: installs zigsaw's latest release over this one, as install.ps1
//! does, and only when the user runs it. A release's files are the zip, VERSION, one
//! line saying which release it is, SHA256SUMS, which lists both, and SHA256SUMS.sig,
//! a signature of that by a key built into this zigsaw. So, unlike install.ps1, this
//! doesn't trust the place the files come from. The signature is made by hand after a
//! release is published (scripts/sign-release.sh), so until then, there's no release
//! to tell anyone about.
//!
//! ZIGSAW_UPGRADE_FROM names a URL or a directory with those files, and
//! ZIGSAW_UPGRADE_KEY a key that counts too, for tests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Context = @import("Context.zig");
const Registry = @import("Registry.zig");
const Store = @import("Store.zig");
const options = @import("options");
const process = @import("process.zig");
const prompt = @import("prompt.zig");
const remote = @import("remote.zig");
const repeat = @import("testing.zig").repeat;
const trust = @import("trust.zig");
const win32 = @import("win32.zig");
const zipfile = @import("zipfile.zig");
const fail = Context.fail;
const note = Context.note;

pub const this_version = options.version;
const default_from = "https://github.com/zigsaw-io/zigsaw/releases/latest/download";
const archive = "zigsaw-x86_64-windows.zip";
const reinstall = "irm https://github.com/zigsaw-io/zigsaw/releases/latest/download/install.ps1 | iex";

/// zigsaw.exe last, so that a zigsaw is there to run again until the end.
const programs = [_][]const u8{ "zigsaw-shim.exe", "zigsaw-shimw.exe", "zigsaw-relay.exe", "zigsaw-host.exe", "zigsaw-notify.exe", "zigsaw.exe" };

fn from(ctx: *Context) []const u8 {
    return std.mem.trimEnd(u8, ctx.env.get("ZIGSAW_UPGRADE_FROM") orelse default_from, "/\\");
}

fn isUrl(where: []const u8) bool {
    return std.mem.startsWith(u8, where, "https://") or std.mem.startsWith(u8, where, "http://");
}

/// Whether this zigsaw is one `upgrade` would replace: in its store's bin, as
/// install.ps1 puts it, and not a build elsewhere.
pub fn applies(ctx: *Context) bool {
    if (ctx.env.get("ZIGSAW_UPGRADE_FROM") != null) return true;
    return inStoreBin(ctx) catch false;
}

fn inStoreBin(ctx: *Context) !bool {
    const arena = ctx.arena;
    const self_dir = std.fs.path.dirname(try win32.selfExePath(arena)).?;
    return std.os.windows.eqlIgnoreCaseWtf8(self_dir, try ctx.store.path(arena, &.{"bin"}));
}

/// Whether `version` is later than this zigsaw. What isn't a version isn't.
pub fn isNewer(version: []const u8) bool {
    const theirs = std.SemanticVersion.parse(version) catch return false;
    const ours = std.SemanticVersion.parse(this_version) catch return false;
    return theirs.order(ours) == .gt;
}

/// The latest release's version, if it's later than this zigsaw and signed. One not
/// signed yet is on its way, or isn't what it says, and either way isn't worth telling
/// anyone about. A signature that's wrong fails, as any failed check does.
pub fn newer(ctx: *Context) !?[]const u8 {
    const latest = try latestVersion(ctx);
    if (!isNewer(latest)) return null;
    return switch ((try readSums(ctx, latest)).state) {
        .signed => latest,
        .not_signed_yet => null,
    };
}

const Sums = struct { state: enum { signed, not_signed_yet }, text: []const u8 = "" };

/// The SHA256SUMS of the release at `from`, if it has a good signature of it, and it
/// says the release is `version`.
fn readSums(ctx: *Context, version: []const u8) !Sums {
    const arena = ctx.arena;
    const io = ctx.io;
    const sums_path = try ctx.store.tmpPath(arena, "sums");
    const sig_path = try ctx.store.tmpPath(arena, "sums-sig");
    defer Io.Dir.cwd().deleteFile(io, sums_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, sig_path) catch {};
    if (!try getIfThere(ctx, "SHA256SUMS.sig", sig_path)) return .{ .state = .not_signed_yet };
    try get(ctx, "SHA256SUMS", sums_path);
    const sums = try Io.Dir.cwd().readFileAlloc(io, sums_path, arena, .limited(64 << 10));
    const text = try Io.Dir.cwd().readFileAlloc(io, sig_path, arena, .limited(4096));
    const keys = try trust.forRelease(ctx);
    for (keys) |key| {
        if (!key.verifies(sums, text)) continue;
        // Signed, so what it lists is what the release is: VERSION can't be from another.
        const listed = try listedHash(arena, sums, "VERSION") orelse
            return fail("the signed SHA256SUMS from {s} doesn't list VERSION. Nothing was changed", .{from(ctx)});
        const version_line = try std.fmt.allocPrint(arena, "{s}\n", .{version});
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(version_line, &hash, .{});
        if (!std.mem.eql(u8, listed, &std.fmt.bytesToHex(hash, .lower)))
            return fail("the VERSION from {s} says {s}, which isn't what the release's signed SHA256SUMS lists. Nothing was changed", .{ from(ctx), version });
        return .{ .state = .signed, .text = sums };
    }
    return fail("the signature of SHA256SUMS from {s} isn't by any key this zigsaw knows. Nothing was changed", .{from(ctx)});
}

fn latestVersion(ctx: *Context) ![]const u8 {
    const arena = ctx.arena;
    const tmp = try ctx.store.tmpPath(arena, "version");
    defer Io.Dir.cwd().deleteFile(ctx.io, tmp) catch {};
    try get(ctx, "VERSION", tmp);
    const text = std.mem.trim(u8, try Io.Dir.cwd().readFileAlloc(ctx.io, tmp, arena, .limited(256)), " \t\r\n");
    _ = std.SemanticVersion.parse(text) catch return fail("{s}/VERSION isn't a version: \"{s}\"", .{ from(ctx), text });
    return text;
}

/// Gets a file of the release into `dest`.
fn get(ctx: *Context, name: []const u8, dest: []const u8) !void {
    if (!try getIfThere(ctx, name, dest)) return fail("downloading {s}/{s}: HTTP 404", .{ from(ctx), name });
}

/// As `get`, or false if the release has no such file. Anything else going wrong is
/// an error: a network that's down says nothing about whether it's there.
fn getIfThere(ctx: *Context, name: []const u8, dest: []const u8) !bool {
    const arena = ctx.arena;
    const where = from(ctx);
    if (!isUrl(where)) {
        const src = try std.fs.path.join(arena, &.{ where, name });
        const bytes = Io.Dir.cwd().readFileAlloc(ctx.io, src, arena, .limited(256 << 20)) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return fail("reading {s}: {t}", .{ src, err }),
        };
        try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = dest, .data = bytes });
        return true;
    }
    const url = try std.fmt.allocPrint(arena, "{s}/{s}", .{ where, name });
    var client: std.http.Client = .{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();
    try client.initDefaultProxies(arena, ctx.env);
    var file = try Io.Dir.cwd().createFile(ctx.io, dest, .{});
    defer file.close(ctx.io);
    var buf: [64 * 1024]u8 = undefined;
    var writer = file.writer(ctx.io, &buf);
    const status = Registry.getTo(&client, url, &writer.interface) catch |err| return fail("downloading {s}: {t}", .{ url, err });
    try writer.interface.flush();
    if (status == .not_found) return false;
    if (status != .ok) return fail("downloading {s}: HTTP {d}", .{ url, @backingInt(status) });
    return true;
}

/// The hash SHA256SUMS lists for `name`, in lower case.
fn listedHash(arena: Allocator, sums: []const u8, name: []const u8) !?[]const u8 {
    var lines = std.mem.tokenizeAny(u8, sums, "\r\n");
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const hash = fields.next() orelse continue;
        const file = std.mem.trimStart(u8, fields.next() orelse continue, "*");
        if (fields.next() != null or !std.mem.eql(u8, file, name)) continue;
        if (hash.len != 64) continue;
        for (hash) |c| if (!std.ascii.isHex(c)) return null;
        return try std.ascii.allocLowerString(arena, hash);
    }
    return null;
}

/// `zigsaw upgrade`. Returns the exit code.
pub fn upgrade(ctx: *Context, consent: remote.Consent) !u32 {
    const arena = ctx.arena;
    const io = ctx.io;
    const self = try win32.selfExePath(arena);
    const bin = std.fs.path.dirname(self).?;
    if (!try inStoreBin(ctx))
        return fail("this zigsaw, {s}, isn't in its store's bin, so upgrade won't replace it. To install the latest one, in PowerShell:\n  {s}", .{ self, reinstall });

    const latest = try latestVersion(ctx);
    if (!isNewer(latest)) {
        note("zigsaw {s} is up to date (the latest release is {s})", .{ this_version, latest });
        return 0;
    }
    // Before asking, and before the download: whether there's anything to agree to.
    const release = try readSums(ctx, latest);
    if (release.state == .not_signed_yet)
        return fail("zigsaw {s} is out, but isn't signed yet, so zigsaw stays at {s}. Nothing was changed; try again later", .{ latest, this_version });
    if (consent != .given) switch (try prompt.askYesNo(ctx, try std.fmt.allocPrint(arena, "Upgrade zigsaw {s} to {s}?", .{ this_version, latest }))) {
        .yes => {},
        .no => return fail("zigsaw stays at {s}", .{this_version}),
        .none => return fail("zigsaw stays at {s}: nothing answered whether to go on. Run it at a console, or add --yes", .{this_version}),
    };
    deleteLeftovers(ctx, bin);

    // Everything checked before anything changes.
    const tmp = try ctx.store.makeTmpDir(arena, "upgrade");
    defer Store.deleteTree(io, arena, tmp) catch {};
    const zip_path = try std.fs.path.join(arena, &.{ tmp, archive });
    try get(ctx, archive, zip_path);
    const want = try listedHash(arena, release.text, archive) orelse return fail("SHA256SUMS from {s} doesn't list {s}. Nothing was changed", .{ from(ctx), archive });
    const got = try Store.sha256File(io, zip_path);
    if (!std.mem.eql(u8, want, &got.hex))
        return fail("{s} from {s} isn't the file its SHA256SUMS lists: expected {s}, got {s}. Nothing was changed", .{ archive, from(ctx), want, &got.hex });

    // Written in bin, so that they get its permissions, whatever tmp's are.
    var suffix_bytes: [4]u8 = undefined;
    io.random(&suffix_bytes);
    const suffix = std.fmt.bytesToHex(suffix_bytes, .lower);
    var new_paths: [programs.len][]const u8 = undefined;
    var unpacked: usize = 0;
    defer for (new_paths[0..unpacked]) |p| Io.Dir.cwd().deleteFile(io, p) catch {};
    {
        var file = try Io.Dir.cwd().openFile(io, zip_path, .{});
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var reader = file.reader(io, &buf);
        const entries = zipfile.list(arena, &reader) catch |err| return fail("reading {s}: {t}. Nothing was changed", .{ archive, err });
        const content = try arena.create(zipfile.Content);
        for (programs) |name| {
            const entry = for (entries) |e| {
                if (std.mem.eql(u8, e.name, name)) break e;
            } else return fail("{s} has no {s}. Nothing was changed", .{ archive, name });
            const bytes = try (try content.open(&reader, entry)).readAlloc(arena, @intCast(entry.size));
            const path = try std.fmt.allocPrint(arena, "{s}\\{s}.new-{s}", .{ bin, name, &suffix });
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
            new_paths[unpacked] = path;
            unpacked += 1;
        }
    }

    // That it starts here, and is what it says: Windows may refuse to start a
    // file Defender flags, and this is the moment to find out.
    const new_zigsaw = new_paths[programs.len - 1];
    const says = process.output(arena, .{
        .exe = new_zigsaw,
        .command_line = try process.buildCommandLine(arena, new_zigsaw, &.{"version"}),
    }, "", 60 * 1000) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return fail("the new zigsaw wouldn't start here ({t}); if Windows Security says it found a threat, that's why. Nothing was changed", .{err}),
    } orelse return fail("the new zigsaw didn't answer. Nothing was changed", .{});
    const expected = try std.fmt.allocPrint(arena, "zigsaw {s}", .{latest});
    if (says.code != 0 or !std.mem.eql(u8, std.mem.trim(u8, says.stdout, " \t\r\n"), expected))
        return fail("the new zigsaw says \"{s}\", but this release is {s}. Nothing was changed", .{ std.mem.trim(u8, says.stdout, " \t\r\n"), latest });

    try swap(ctx, bin, &new_paths, &suffix);
    unpacked = 0;
    note("upgraded zigsaw {s} to {s}", .{ this_version, latest });

    // As install.ps1 does: apps' commands name the zigsaw that wrote them, and the
    // new one decides about the daily check.
    const installed = try std.fs.path.join(arena, &.{ bin, "zigsaw.exe" });
    const repaired = try process.spawn(arena, .{
        .exe = installed,
        .command_line = try process.buildCommandLine(arena, installed, &.{"repair"}),
    });
    if (repaired != 0) note("warning: some apps' commands are still those of the zigsaw before. Close the apps and run `zigsaw repair`", .{});
    if (@import("shortcuts.zig").isDefaultStore(ctx.env.get("LOCALAPPDATA"), ctx.store.root)) {
        _ = try process.spawn(arena, .{
            .exe = installed,
            .command_line = try process.buildCommandLine(arena, installed, &.{ "updates", "on", "--unless-off" }),
        });
    }
    return 0;
}

/// Puts the new programs in place, moving the old ones aside: Windows lets a running
/// program be renamed, not deleted. Should one fail, those done so far go back.
fn swap(ctx: *Context, bin: []const u8, new_paths: []const []const u8, suffix: []const u8) !void {
    const arena = ctx.arena;
    const io = ctx.io;
    const Done = struct { dest: []const u8, aside: ?[]const u8, new: []const u8 };
    // MoveFileEx, as std's rename answers "busy" for a program that's running.
    const move = struct {
        fn move(a: Allocator, src: []const u8, dst: []const u8) !bool {
            return win32.MoveFileExW(try win32.wide(a, src), try win32.wide(a, dst), 0) != 0;
        }
    }.move;
    var done: std.ArrayList(Done) = .empty;
    errdefer {
        var i = done.items.len;
        while (i > 0) {
            i -= 1;
            const d = done.items[i];
            _ = move(arena, d.dest, d.new) catch false;
            if (d.aside) |a| _ = move(arena, a, d.dest) catch false;
        }
    }
    for (programs, new_paths) |name, new| {
        const dest = try std.fs.path.join(arena, &.{ bin, name });
        const aside = try std.fmt.allocPrint(arena, "{s}.old-{s}", .{ dest, suffix });
        const there = try Store.exists(io, dest);
        if (there and !try move(arena, dest, aside)) return win32.lastErrorFail("moving a program aside (MoveFileExW)");
        const moved: ?[]const u8 = if (there) aside else null;
        if (!try move(arena, new, dest)) {
            const failure = win32.lastErrorFail("putting a new program in place (MoveFileExW)");
            if (moved) |a| _ = move(arena, a, dest) catch false;
            return failure;
        }
        try done.append(arena, .{ .dest = dest, .aside = moved, .new = new });
    }
}

/// What earlier upgrades moved aside, where nothing's running it any more.
fn deleteLeftovers(ctx: *Context, bin: []const u8) void {
    const io = ctx.io;
    var dir = Io.Dir.cwd().openDir(io, bin, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        for (programs) |name| {
            if (!std.mem.startsWith(u8, entry.name, name)) continue;
            const rest = entry.name[name.len..];
            if (std.mem.startsWith(u8, rest, ".old-") or std.mem.startsWith(u8, rest, ".new-"))
                dir.deleteFile(io, entry.name) catch {};
        }
    }
}

test isNewer {
    try std.testing.expect(isNewer("999.0.0"));
    try std.testing.expect(!isNewer(this_version));
    try std.testing.expect(!isNewer("0.1.0"));
    try std.testing.expect(!isNewer("not a version"));
}

test listedHash {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = repeat("a", 64);
    const b = repeat("B", 64);
    const sums = a ++ "  install.ps1\n" ++ b ++ " *" ++ archive ++ "\r\n";
    try std.testing.expectEqualStrings(repeat("b", 64), (try listedHash(arena, sums, archive)).?);
    try std.testing.expectEqualStrings(a, (try listedHash(arena, sums, "install.ps1")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try listedHash(arena, sums, "other"));
    try std.testing.expectEqual(@as(?[]const u8, null), try listedHash(arena, "abc  " ++ archive, archive));
    try std.testing.expectEqual(@as(?[]const u8, null), try listedHash(arena, repeat("z", 64) ++ "  " ++ archive, archive));
}
