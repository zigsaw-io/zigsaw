//! AppContainer profiles for the `appcontainer` sandbox.
//!
//! Each app gets one persistent profile named "zigsaw.<id>". Windows derives
//! the profile's SID from that name, so the SID stays stable across runs and
//! reinstalls. The app can reach only what its runs' SIDs are granted in ACLs
//! (see acl.zig), plus what Windows grants all AppContainers, such as System32.
//!
//! zigsaw grants an app's files, data and host paths to a capability of the
//! app's own, also named "zigsaw.<id>", which only that app's runs hold, rather
//! than to the profile's (package) SID: an ACE for a package SID would keep
//! low-integrity processes out of the file (see `acl.isPackageSid`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");
const Context = @import("Context.zig");
const fail = Context.fail;

pub const Profile = struct {
    name: []const u8,
    /// The profile's package SID.
    sid: win32.PSID,
    /// The app's capability, which zigsaw grants access to.
    capability: win32.PSID,

    /// Creates the app's profile, or opens it if it already exists. The SIDs
    /// are left to be freed at process exit.
    pub fn ensure(arena: Allocator, id: []const u8) !Profile {
        const name = try profileName(arena, id);
        const name_w = try win32.wide(arena, name);
        var sid: ?win32.PSID = null;
        var hr = win32.CreateAppContainerProfile(name_w, name_w, name_w, null, 0, &sid);
        if (hr == win32.E_ALREADY_EXISTS) hr = win32.DeriveAppContainerSidFromAppContainerName(name_w, &sid);
        if (hr < 0) return fail("AppContainer profile {s}: HRESULT 0x{x}", .{ name, @as(u32, @bitCast(hr)) });
        return .{ .name = name, .sid = sid.?, .capability = try capabilitySid(arena, name) };
    }
};

/// The package SID of the app's profile, whether or not the profile exists.
/// zigsaw granted it access before it granted capabilities. Left to be freed
/// at process exit.
pub fn packageSid(arena: Allocator, id: []const u8) !win32.PSID {
    const name = try profileName(arena, id);
    var sid: ?win32.PSID = null;
    const hr = win32.DeriveAppContainerSidFromAppContainerName(try win32.wide(arena, name), &sid);
    if (hr < 0) return fail("AppContainer SID of {s}: HRESULT 0x{x}", .{ name, @as(u32, @bitCast(hr)) });
    return sid.?;
}

pub fn deleteProfile(arena: Allocator, id: []const u8) !void {
    const hr = win32.DeleteAppContainerProfile(try win32.wide(arena, try profileName(arena, id)));
    if (hr < 0) return fail("deleting AppContainer profile for {s}: HRESULT 0x{x}", .{ id, @as(u32, @bitCast(hr)) });
}

fn profileName(arena: Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "zigsaw.{s}", .{id});
}

/// The capability SID Windows derives from a name (S-1-15-3-1024-...). Left
/// to be freed at process exit.
fn capabilitySid(arena: Allocator, name: []const u8) !win32.PSID {
    var groups: ?[*]win32.PSID = null;
    var group_count: win32.DWORD = 0;
    var sids: ?[*]win32.PSID = null;
    var count: win32.DWORD = 0;
    if (win32.DeriveCapabilitySidsFromName(try win32.wide(arena, name), &groups, &group_count, &sids, &count) == 0)
        return win32.lastErrorFail("DeriveCapabilitySidsFromName");
    if (count == 0) return fail("Windows derived no capability SID from {s}", .{name});
    return sids.?[0];
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
