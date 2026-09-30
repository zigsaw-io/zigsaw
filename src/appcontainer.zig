//! AppContainer profiles and file ACL grants for the `appcontainer` sandbox.
//!
//! Each app gets one persistent profile named "zigsaw.<id>". Windows derives
//! the profile's SID from that name, so the SID stays stable across runs and
//! reinstalls. The app can reach only what that SID is granted in ACLs (plus
//! what Windows grants all AppContainers, such as System32).

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");
const Context = @import("Context.zig");
const fail = Context.fail;

pub const Profile = struct {
    name: []const u8,
    sid: win32.PSID,

    /// Creates the app's profile, or opens it if it already exists. The SID is
    /// left to be freed at process exit.
    pub fn ensure(arena: Allocator, id: []const u8) !Profile {
        const name = try profileName(arena, id);
        const name_w = try win32.wide(arena, name);
        var sid: ?win32.PSID = null;
        var hr = win32.CreateAppContainerProfile(name_w, name_w, name_w, null, 0, &sid);
        if (hr == win32.E_ALREADY_EXISTS) hr = win32.DeriveAppContainerSidFromAppContainerName(name_w, &sid);
        if (hr < 0) return fail("AppContainer profile {s}: HRESULT 0x{x}", .{ name, @as(u32, @bitCast(hr)) });
        return .{ .name = name, .sid = sid.? };
    }
};

pub fn deleteProfile(arena: Allocator, id: []const u8) !void {
    const hr = win32.DeleteAppContainerProfile(try win32.wide(arena, try profileName(arena, id)));
    if (hr < 0) return fail("deleting AppContainer profile for {s}: HRESULT 0x{x}", .{ id, @as(u32, @bitCast(hr)) });
}

fn profileName(arena: Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "zigsaw.{s}", .{id});
}

/// Well-known capability SIDs.
pub const capability = struct {
    pub const internet_client = "S-1-15-3-1";
    pub const private_network_client_server = "S-1-15-3-3";
};

/// Converts a string SID. The result is left to be freed at process exit.
pub fn sidFromString(arena: Allocator, s: []const u8) !win32.PSID {
    var sid: ?win32.PSID = null;
    if (win32.ConvertStringSidToSidW(try win32.wide(arena, s), &sid) == 0) return win32.lastErrorFail("ConvertStringSidToSidW");
    return sid.?;
}

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
    const path_w = try win32.wide(arena, path);
    var sd: ?*anyopaque = null;
    var dacl: ?*win32.ACL = null;
    const rc = win32.GetNamedSecurityInfoW(path_w, win32.SE_FILE_OBJECT, win32.DACL_SECURITY_INFORMATION, null, null, &dacl, null, &sd);
    if (rc != 0) return aclFail("reading", path, rc);
    defer _ = win32.LocalFree(sd);

    if (dacl) |acl| if (hasAllowAce(acl, sid, access.mask())) return false;

    var entry = [1]win32.EXPLICIT_ACCESS_W{.{
        .grfAccessPermissions = access.mask(),
        .grfAccessMode = win32.GRANT_ACCESS,
        .grfInheritance = win32.SUB_CONTAINERS_AND_OBJECTS_INHERIT,
        .Trustee = .{ .ptstrName = sid },
    }};
    return setEntries(path, path_w, dacl, &entry);
}

/// Removes every ACE for `sid` from `path`; inherited copies below it go too.
pub fn revoke(arena: Allocator, path: []const u8, sid: win32.PSID) !void {
    const path_w = try win32.wide(arena, path);
    var sd: ?*anyopaque = null;
    var dacl: ?*win32.ACL = null;
    const rc = win32.GetNamedSecurityInfoW(path_w, win32.SE_FILE_OBJECT, win32.DACL_SECURITY_INFORMATION, null, null, &dacl, null, &sd);
    if (rc != 0) return aclFail("reading", path, rc);
    defer _ = win32.LocalFree(sd);

    var entry = [1]win32.EXPLICIT_ACCESS_W{.{
        .grfAccessPermissions = 0,
        .grfAccessMode = win32.REVOKE_ACCESS,
        .grfInheritance = 0,
        .Trustee = .{ .ptstrName = sid },
    }};
    _ = try setEntries(path, path_w, dacl, &entry);
}

fn setEntries(path: []const u8, path_w: [:0]const u16, dacl: ?*win32.ACL, entries: []win32.EXPLICIT_ACCESS_W) !bool {
    var new_acl: ?*win32.ACL = null;
    var rc = win32.SetEntriesInAclW(@intCast(entries.len), entries.ptr, dacl, &new_acl);
    if (rc != 0) return aclFail("building", path, rc);
    defer _ = win32.LocalFree(new_acl);
    rc = win32.SetNamedSecurityInfoW(path_w, win32.SE_FILE_OBJECT, win32.DACL_SECURITY_INFORMATION, null, null, new_acl, null);
    if (rc != 0) return aclFail("updating", path, rc);
    return true;
}

fn hasAllowAce(acl: *win32.ACL, sid: win32.PSID, mask: win32.DWORD) bool {
    var i: win32.DWORD = 0;
    while (i < acl.AceCount) : (i += 1) {
        var raw: ?*anyopaque = null;
        if (win32.GetAce(acl, i, &raw) == 0) continue;
        const ace: *win32.ACCESS_ALLOWED_ACE = @ptrCast(@alignCast(raw.?));
        if (ace.Header.AceType != win32.ACCESS_ALLOWED_ACE_TYPE) continue;
        if (ace.Mask & mask != mask) continue;
        if (win32.EqualSid(@ptrCast(&ace.SidStart), sid) != 0) return true;
    }
    return false;
}

fn aclFail(what: []const u8, path: []const u8, code: win32.DWORD) error{Failed} {
    return fail("{s} the ACL of {s}: error {d} ({s})", .{ what, path, code, win32.errorName(code) });
}
