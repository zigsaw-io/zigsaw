//! File ACL edits: access grants for AppContainer identities, and write
//! protection for deployed app trees.

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");
const Context = @import("Context.zig");
const fail = Context.fail;

pub const Access = enum {
    read_execute,
    full,

    fn mask(a: Access) win32.DWORD {
        return switch (a) {
            .read_execute => win32.FILE_GENERIC_READ_EXECUTE,
            .full => win32.FILE_ALL_ACCESS,
        };
    }
};

/// Grants `sid` access to `path` and, through inheritance, everything below
/// it. Does nothing if an ACE already grants at least that access. Returns
/// whether the ACL changed.
///
/// On a large tree the first grant is slow: Windows rewrites the inherited
/// ACEs of every file below `path`.
pub fn grant(arena: Allocator, path: []const u8, sid: win32.PSID, access: Access) !bool {
    var dacl = try Dacl.read(arena, path);
    defer dacl.deinit();
    if (dacl.find(win32.ACCESS_ALLOWED_ACE_TYPE, sid, access.mask(), .any) != null) return false;
    try dacl.addEntry(.{
        .grfAccessPermissions = access.mask(),
        .grfAccessMode = win32.GRANT_ACCESS,
        .grfInheritance = win32.SUB_CONTAINERS_AND_OBJECTS_INHERIT,
        .Trustee = .{ .ptstrName = sid },
    });
    return true;
}

/// Removes every allow ACE for `sid` from `path`; inherited copies below it go too.
pub fn revoke(arena: Allocator, path: []const u8, sid: win32.PSID) !void {
    var dacl = try Dacl.read(arena, path);
    defer dacl.deinit();
    try dacl.addEntry(.{
        .grfAccessPermissions = 0,
        .grfAccessMode = win32.REVOKE_ACCESS,
        .grfInheritance = 0,
        .Trustee = .{ .ptstrName = sid },
    });
}

/// Denies the current user the right to modify `path` or anything below it,
/// so nothing running as the user (including apps in the soft sandbox) can
/// change an installed app. The owner keeps the implicit right to edit the
/// ACL, which `unprotect` relies on.
pub fn protect(arena: Allocator, path: []const u8) !void {
    const user = try currentUserSid(arena);
    var dacl = try Dacl.read(arena, path);
    defer dacl.deinit();
    if (dacl.find(win32.ACCESS_DENIED_ACE_TYPE, user, win32.FILE_MODIFY, .explicit) != null) return;
    try dacl.addEntry(.{
        .grfAccessPermissions = win32.FILE_MODIFY,
        .grfAccessMode = win32.DENY_ACCESS,
        .grfInheritance = win32.SUB_CONTAINERS_AND_OBJECTS_INHERIT,
        .Trustee = .{ .ptstrName = user },
    });
}

/// Undoes `protect`.
pub fn unprotect(arena: Allocator, path: []const u8) !void {
    const user = try currentUserSid(arena);
    var dacl = try Dacl.read(arena, path);
    defer dacl.deinit();
    const index = dacl.find(win32.ACCESS_DENIED_ACE_TYPE, user, win32.FILE_MODIFY, .explicit) orelse return;
    if (win32.DeleteAce(dacl.acl.?, index) == 0) return win32.lastErrorFail("DeleteAce");
    try dacl.write(dacl.acl);
}

/// The SID of the user zigsaw runs as. Allocated in `arena`.
pub fn currentUserSid(arena: Allocator) !win32.PSID {
    var token: ?win32.HANDLE = null;
    if (win32.OpenProcessToken(win32.GetCurrentProcess(), win32.TOKEN_QUERY, &token) == 0)
        return win32.lastErrorFail("OpenProcessToken");
    defer _ = win32.CloseHandle(token.?);
    var len: win32.DWORD = 0;
    _ = win32.GetTokenInformation(token.?, win32.TokenUser, null, 0, &len);
    const buf = try arena.alignedAlloc(u8, .of(win32.TOKEN_USER), len);
    if (win32.GetTokenInformation(token.?, win32.TokenUser, buf.ptr, len, &len) == 0)
        return win32.lastErrorFail("GetTokenInformation");
    const info: *const win32.TOKEN_USER = @ptrCast(buf.ptr);
    return info.User.Sid;
}

/// The DACL of a file or directory, as returned by GetNamedSecurityInfoW.
const Dacl = struct {
    path: []const u8,
    path_w: [:0]const u16,
    security_descriptor: ?*anyopaque,
    acl: ?*win32.ACL,

    fn read(arena: Allocator, path: []const u8) !Dacl {
        var d: Dacl = .{ .path = path, .path_w = try win32.wide(arena, path), .security_descriptor = null, .acl = null };
        const rc = win32.GetNamedSecurityInfoW(d.path_w, win32.SE_FILE_OBJECT, win32.DACL_SECURITY_INFORMATION, null, null, &d.acl, null, &d.security_descriptor);
        if (rc != 0) return aclFail("reading", path, rc);
        return d;
    }

    fn deinit(d: *Dacl) void {
        _ = win32.LocalFree(d.security_descriptor);
    }

    /// Merges one entry into the DACL and writes it back to the file.
    fn addEntry(d: *Dacl, entry: win32.EXPLICIT_ACCESS_W) !void {
        var entries = [1]win32.EXPLICIT_ACCESS_W{entry};
        var new_acl: ?*win32.ACL = null;
        const rc = win32.SetEntriesInAclW(1, &entries, d.acl, &new_acl);
        if (rc != 0) return aclFail("building", d.path, rc);
        defer _ = win32.LocalFree(new_acl);
        try d.write(new_acl);
    }

    fn write(d: *const Dacl, acl: ?*win32.ACL) !void {
        const rc = win32.SetNamedSecurityInfoW(d.path_w, win32.SE_FILE_OBJECT, win32.DACL_SECURITY_INFORMATION, null, null, acl, null);
        if (rc != 0) return aclFail("updating", d.path, rc);
    }

    /// Index of an ACE of `ace_type` for `sid` covering at least `mask`.
    fn find(d: *const Dacl, ace_type: u8, sid: win32.PSID, mask: win32.DWORD, origin: enum { any, explicit }) ?win32.DWORD {
        const acl = d.acl orelse return null;
        var i: win32.DWORD = 0;
        while (i < acl.AceCount) : (i += 1) {
            var raw: ?*anyopaque = null;
            if (win32.GetAce(acl, i, &raw) == 0) continue;
            // Allow and deny ACEs share this layout.
            const ace: *win32.ACCESS_ALLOWED_ACE = @ptrCast(@alignCast(raw.?));
            if (ace.Header.AceType != ace_type) continue;
            if (origin == .explicit and ace.Header.AceFlags & win32.INHERITED_ACE != 0) continue;
            if (ace.Mask & mask != mask) continue;
            if (win32.EqualSid(@ptrCast(&ace.SidStart), sid) != 0) return i;
        }
        return null;
    }
};

fn aclFail(what: []const u8, path: []const u8, code: win32.DWORD) error{Failed} {
    return fail("{s} the ACL of {s}: error {d} ({s})", .{ what, path, code, win32.errorName(code) });
}
