//! The build drive. While a recipe's build commands run, the build's root is
//! mapped to B:, so the paths compilers write into what they build (source
//! file names in asserts, debug info) are the same on every machine, whatever
//! the user's name or where the store is. The mapping is a DOS device of the
//! user's logon session, as `subst` makes, which needs no admin rights.
//!
//! The whole logon session sees the mapping, so builds take turns: a named
//! mutex, also per session, makes each wait for the one before it. A mapping
//! a crashed build left behind is replaced. One that zigsaw didn't make is
//! left alone, and the build fails.

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");
const Context = @import("Context.zig");
const fail = Context.fail;
const note = Context.note;

pub const letter = "B:";

/// Build roots are directories with this prefix, which is how a stale mapping
/// is told from someone else's.
pub const dir_prefix = "zigsaw-build-";

const mutex_name = "Local\\zigsaw-build-drive";

pub const Drive = struct {
    mutex: win32.HANDLE,
    /// The mapping as Windows keeps it, to remove exactly that one.
    raw_target: [:0]const u16,

    /// Removes the mapping and lets the next build have the drive.
    pub fn release(d: Drive) void {
        _ = win32.DefineDosDeviceW(remove_flags, std.unicode.utf8ToUtf16LeStringLiteral(letter), d.raw_target);
        _ = win32.ReleaseMutex(d.mutex);
        _ = win32.CloseHandle(d.mutex);
    }
};

const remove_flags = win32.DDD_REMOVE_DEFINITION | win32.DDD_EXACT_MATCH_ON_REMOVE | win32.DDD_RAW_TARGET_PATH | win32.DDD_NO_BROADCAST_SYSTEM;

/// Maps the build drive to `dir`, a directory named `dir_prefix...`, waiting
/// for other builds to finish with it first.
pub fn acquire(arena: Allocator, dir: []const u8) !Drive {
    const device = std.unicode.utf8ToUtf16LeStringLiteral(letter);
    const mutex = win32.CreateMutexW(null, win32.FALSE, std.unicode.utf8ToUtf16LeStringLiteral(mutex_name)) orelse
        return win32.lastErrorFail("CreateMutexW");
    errdefer _ = win32.CloseHandle(mutex);
    switch (win32.WaitForSingleObject(mutex, 0)) {
        // Abandoned: the build that had it ended without releasing it.
        win32.WAIT_OBJECT_0, win32.WAIT_ABANDONED => {},
        win32.WAIT_TIMEOUT => {
            note("waiting for another zigsaw build to finish with {s}...", .{letter});
            const got = win32.WaitForSingleObject(mutex, win32.INFINITE);
            if (got != win32.WAIT_OBJECT_0 and got != win32.WAIT_ABANDONED) return win32.lastErrorFail("WaitForSingleObject");
        },
        else => return win32.lastErrorFail("WaitForSingleObject"),
    }
    errdefer _ = win32.ReleaseMutex(mutex);

    // No other build is running, so a mapping of zigsaw's is stale.
    if (try query(arena)) |existing| {
        const target = try std.unicode.wtf16LeToWtf8Alloc(arena, existing);
        if (!isBuildRoot(target))
            return fail("{s} is in use ({s}). zigsaw builds on {s}, so that paths in what it builds are the same on every machine; free it to build", .{ letter, target, letter });
        if (win32.DefineDosDeviceW(remove_flags, device, existing) == 0)
            return win32.lastErrorFail("removing a stale build drive mapping");
    }
    if (win32.DefineDosDeviceW(win32.DDD_NO_BROADCAST_SYSTEM, device, try win32.wide(arena, dir)) == 0)
        return win32.lastErrorFail("mapping the build drive");
    return .{ .mutex = mutex, .raw_target = (try query(arena)) orelse return fail("{s} vanished right after it was mapped", .{letter}) };
}

/// The current target of the build drive, as Windows keeps it, or null if
/// it isn't mapped.
fn query(arena: Allocator) !?[:0]const u16 {
    var buf: [32 * 1024]u16 = undefined;
    const len = win32.QueryDosDeviceW(std.unicode.utf8ToUtf16LeStringLiteral(letter), &buf, buf.len);
    if (len == 0) {
        if (win32.GetLastError() == win32.ERROR_FILE_NOT_FOUND) return null;
        return win32.lastErrorFail("QueryDosDeviceW");
    }
    // The result is a list of null-terminated strings; the first is current.
    const first = std.mem.indexOfScalar(u16, buf[0..len], 0) orelse len;
    return try arena.dupeZ(u16, buf[0..first]);
}

/// Whether a mapping's target, such as "\??\C:\...\tmp\zigsaw-build-1f2e",
/// is a build root.
fn isBuildRoot(target: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, target, "\\");
    const name = trimmed[if (std.mem.lastIndexOfScalar(u8, trimmed, '\\')) |i| i + 1 else 0..];
    return std.mem.startsWith(u8, name, dir_prefix);
}

test isBuildRoot {
    try std.testing.expect(isBuildRoot("\\??\\C:\\Users\\me\\AppData\\Local\\zigsaw\\tmp\\zigsaw-build-0a1b2c3d4e5f6a7b"));
    try std.testing.expect(isBuildRoot("\\??\\D:\\z\\tmp\\zigsaw-build-0a1b\\"));
    try std.testing.expect(!isBuildRoot("\\Device\\HarddiskVolume3"));
    try std.testing.expect(!isBuildRoot("\\??\\C:\\work"));
}
