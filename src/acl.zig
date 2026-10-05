//! File ACL edits: access grants for AppContainer identities, write
//! protection for deployed app trees, and integrity labels for the low
//! sandbox.

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

/// Whose explicit allow ACEs to remove.
pub const Revoke = union(enum) {
    none,
    sids: []const win32.PSID,
    /// Every AppContainer package SID's (see `isPackageSid`). Only for
    /// directories that nothing but zigsaw grants AppContainers.
    package_sids,
};

/// Grants `sid` access to `path` and, through inheritance, everything below
/// it, unless an ACE already grants at least that access; and removes the
/// allow ACEs `also_revoke` names, in the same change. Returns whether the
/// ACL changed.
///
/// On a large tree a change is slow: Windows rewrites the inherited ACEs of
/// every file below `path`.
pub fn grant(arena: Allocator, path: []const u8, sid: win32.PSID, access: Access, also_revoke: Revoke) !bool {
    var dacl = try Dacl.read(arena, path);
    defer dacl.deinit();
    var entries = try dacl.revocations(arena, also_revoke, sid);
    if (dacl.find(win32.ACCESS_ALLOWED_ACE_TYPE, sid, access.mask(), .any) == null) try entries.append(arena, .{
        .grfAccessPermissions = access.mask(),
        .grfAccessMode = win32.GRANT_ACCESS,
        .grfInheritance = win32.SUB_CONTAINERS_AND_OBJECTS_INHERIT,
        .Trustee = .{ .ptstrName = sid },
    });
    if (entries.items.len == 0) return false;
    try dacl.addEntries(entries.items);
    return true;
}

/// Removes the allow ACEs `which` names from `path`; inherited copies below it
/// go too. Returns whether the ACL changed; reading it is all it costs
/// otherwise.
pub fn revoke(arena: Allocator, path: []const u8, which: Revoke) !bool {
    var dacl = try Dacl.read(arena, path);
    defer dacl.deinit();
    const entries = try dacl.revocations(arena, which, null);
    if (entries.items.len == 0) return false;
    try dacl.addEntries(entries.items);
    return true;
}

/// Whether `sid` is an AppContainer's package SID: S-1-15-2- and seven more
/// numbers. Not ALL APPLICATION PACKAGES (S-1-15-2-1), nor a capability
/// (S-1-15-3-...).
///
/// An allow ACE for a package SID keeps low-integrity processes outside that
/// AppContainer from opening the file at all, though the user may have full
/// access (docs/findings.md), so zigsaw grants capabilities instead.
pub fn isPackageSid(sid: win32.PSID) bool {
    const authority = win32.GetSidIdentifierAuthority(sid).Value;
    if (!std.mem.eql(u8, &authority, &.{ 0, 0, 0, 0, 0, 15 })) return false;
    return win32.GetSidSubAuthorityCount(sid).* == 8 and win32.GetSidSubAuthority(sid, 0).* == 2;
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
    var entries = [1]win32.EXPLICIT_ACCESS_W{.{
        .grfAccessPermissions = win32.FILE_MODIFY,
        .grfAccessMode = win32.DENY_ACCESS,
        .grfInheritance = win32.SUB_CONTAINERS_AND_OBJECTS_INHERIT,
        .Trustee = .{ .ptstrName = user },
    }};
    try dacl.addEntries(&entries);
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

// ---------------------------------------------------------------------------
// Integrity labels

/// Labels `path` low integrity, and through inheritance everything below it,
/// so that low-integrity processes can write there. Does nothing if `path`
/// has a label of its own at low or below already; one it inherits doesn't
/// count, as removing the label above would take it away. Returns whether
/// the label changed.
///
/// Like a grant, the first label of a large tree is slow. It needs the right
/// to change the path's owner, which the user has for their own files.
pub fn labelLow(arena: Allocator, path: []const u8) !bool {
    if (try ownLabel(arena, path)) |rid| if (rid <= win32.SECURITY_MANDATORY_LOW_RID) return false;
    const low = try lowIntegritySid(arena);
    const size = @sizeOf(win32.ACL) + @sizeOf(win32.ACCESS_ALLOWED_ACE) + win32.GetLengthSid(low);
    const buf = try arena.alignedAlloc(u8, .of(win32.ACL), size);
    const sacl: *win32.ACL = @ptrCast(buf.ptr);
    if (win32.InitializeAcl(sacl, @intCast(size), win32.ACL_REVISION) == 0) return win32.lastErrorFail("InitializeAcl");
    const inherit = win32.OBJECT_INHERIT_ACE | win32.CONTAINER_INHERIT_ACE;
    if (win32.AddMandatoryAce(sacl, win32.ACL_REVISION, inherit, win32.SYSTEM_MANDATORY_LABEL_NO_WRITE_UP, low) == 0)
        return win32.lastErrorFail("AddMandatoryAce");
    try writeLabel(arena, path, sacl);
    return true;
}

/// Removes the label of `path`'s own, and the copies inherited below it, so
/// it's medium integrity again, as files are by default.
pub fn unlabel(arena: Allocator, path: []const u8) !void {
    var empty: win32.ACL = undefined;
    if (win32.InitializeAcl(&empty, @sizeOf(win32.ACL), win32.ACL_REVISION) == 0) return win32.lastErrorFail("InitializeAcl");
    try writeLabel(arena, path, &empty);
}

/// The integrity level (as its RID) of `path`'s own label; null when it has
/// none, or only inherits one.
pub fn ownLabel(arena: Allocator, path: []const u8) !?win32.DWORD {
    const path_w = try win32.wide(arena, path);
    var sd: ?*anyopaque = null;
    var sacl: ?*win32.ACL = null;
    const rc = win32.GetNamedSecurityInfoW(path_w, win32.SE_FILE_OBJECT, win32.LABEL_SECURITY_INFORMATION, null, null, null, &sacl, &sd);
    if (rc != 0) return labelFail("reading", path, rc);
    defer _ = win32.LocalFree(sd);
    const acl = sacl orelse return null;
    var i: win32.DWORD = 0;
    while (i < acl.AceCount) : (i += 1) {
        var raw: ?*anyopaque = null;
        if (win32.GetAce(acl, i, &raw) == 0) continue;
        // A mandatory label ACE has an allow ACE's layout.
        const ace: *win32.ACCESS_ALLOWED_ACE = @ptrCast(@alignCast(raw.?));
        if (ace.Header.AceType != win32.SYSTEM_MANDATORY_LABEL_ACE_TYPE) continue;
        if (ace.Header.AceFlags & win32.INHERITED_ACE != 0) continue;
        const sid: win32.PSID = @ptrCast(&ace.SidStart);
        return win32.GetSidSubAuthority(sid, win32.GetSidSubAuthorityCount(sid).* - 1).*;
    }
    return null;
}

fn writeLabel(arena: Allocator, path: []const u8, sacl: *win32.ACL) !void {
    const rc = win32.SetNamedSecurityInfoW(try win32.wide(arena, path), win32.SE_FILE_OBJECT, win32.LABEL_SECURITY_INFORMATION, null, null, null, sacl);
    if (rc != 0) return labelFail("changing", path, rc);
}

fn lowIntegritySid(arena: Allocator) !win32.PSID {
    var sid: ?win32.PSID = null;
    if (win32.ConvertStringSidToSidW(try win32.wide(arena, win32.low_integrity_sid), &sid) == 0)
        return win32.lastErrorFail("ConvertStringSidToSidW");
    return sid.?;
}

// ---------------------------------------------------------------------------

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

    /// Merges entries into the DACL and writes it back to the file.
    fn addEntries(d: *Dacl, entries: []win32.EXPLICIT_ACCESS_W) !void {
        var new_acl: ?*win32.ACL = null;
        const rc = win32.SetEntriesInAclW(@intCast(entries.len), entries.ptr, d.acl, &new_acl);
        if (rc != 0) return aclFail("building", d.path, rc);
        defer _ = win32.LocalFree(new_acl);
        try d.write(new_acl);
    }

    fn write(d: *const Dacl, acl: ?*win32.ACL) !void {
        const rc = win32.SetNamedSecurityInfoW(d.path_w, win32.SE_FILE_OBJECT, win32.DACL_SECURITY_INFORMATION, null, null, acl, null);
        if (rc != 0) return aclFail("updating", d.path, rc);
    }

    /// Entries that revoke the explicit allow ACEs `which` names, except
    /// `keep`'s.
    fn revocations(d: *const Dacl, arena: Allocator, which: Revoke, keep: ?win32.PSID) !std.ArrayList(win32.EXPLICIT_ACCESS_W) {
        var out: std.ArrayList(win32.EXPLICIT_ACCESS_W) = .empty;
        const acl = d.acl orelse return out;
        var i: win32.DWORD = 0;
        while (i < acl.AceCount) : (i += 1) {
            var raw: ?*anyopaque = null;
            if (win32.GetAce(acl, i, &raw) == 0) continue;
            const ace: *win32.ACCESS_ALLOWED_ACE = @ptrCast(@alignCast(raw.?));
            if (ace.Header.AceType != win32.ACCESS_ALLOWED_ACE_TYPE or ace.Header.AceFlags & win32.INHERITED_ACE != 0) continue;
            const sid: win32.PSID = @ptrCast(&ace.SidStart);
            if (keep) |k| if (win32.EqualSid(sid, k) != 0) continue;
            const named = switch (which) {
                .none => false,
                .sids => |sids| for (sids) |s| {
                    if (win32.EqualSid(sid, s) != 0) break true;
                } else false,
                .package_sids => isPackageSid(sid),
            };
            if (!named) continue;
            // REVOKE_ACCESS removes every allow ACE of the SID at once.
            const dupe = for (out.items) |e| {
                if (win32.EqualSid(@ptrCast(e.Trustee.ptstrName.?), sid) != 0) break true;
            } else false;
            if (!dupe) try out.append(arena, .{
                .grfAccessPermissions = 0,
                .grfAccessMode = win32.REVOKE_ACCESS,
                .grfInheritance = 0,
                .Trustee = .{ .ptstrName = sid },
            });
        }
        return out;
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

fn labelFail(what: []const u8, path: []const u8, code: win32.DWORD) error{Failed} {
    return fail("{s} the integrity label of {s}: error {d} ({s})", .{ what, path, code, win32.errorName(code) });
}
