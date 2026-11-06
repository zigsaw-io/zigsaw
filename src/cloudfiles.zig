//! The Cloud Files API (cfapi.h), as much as lazy pulling needs: a folder made
//! a sync root, a placeholder for each of a layer's directories and files, and
//! a provider that Windows asks for a file's bytes when something first reads
//! it (see lazy.zig, and docs/experiment-cloud-files.md for what was measured).
//! No driver is installed: cldflt comes with Windows, and none of this needs
//! admin rights. cldapi.dll is loaded when first needed, from System32, as
//! Zig has no import library for it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const win32 = @import("win32.zig");
const Context = @import("Context.zig");
const fail = Context.fail;

const HANDLE = win32.HANDLE;
const HRESULT = win32.HRESULT;

// ---------------------------------------------------------------------------
// cfapi.h

pub const FsMetadata = extern struct {
    creation: i64,
    access: i64,
    write: i64,
    change: i64,
    attributes: u32,
    size: i64,
};
pub const PlaceholderCreateInfo = extern struct {
    relative_name: [*:0]const u16,
    metadata: FsMetadata,
    identity: ?*const anyopaque,
    identity_len: u32,
    flags: u32,
    result: HRESULT = 0,
    usn: i64 = 0,
};
pub const ProcessInfo = extern struct {
    struct_size: u32,
    pid: u32,
    image_path: ?[*:0]const u16,
    package_name: ?[*:0]const u16,
    application_id: ?[*:0]const u16,
    command_line: ?[*:0]const u16,
    session_id: u32,
};
pub const Guid = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: [8]u8,
};
const SyncRegistration = extern struct {
    struct_size: u32 = @sizeOf(SyncRegistration),
    provider_name: [*:0]const u16,
    provider_version: [*:0]const u16,
    root_identity: ?*const anyopaque,
    root_identity_len: u32,
    file_identity: ?*const anyopaque,
    file_identity_len: u32,
    provider_id: Guid,
};
const SyncPolicies = extern struct {
    struct_size: u32 = @sizeOf(SyncPolicies),
    hydration_primary: u16,
    hydration_modifier: u16 = 0,
    population_primary: u16,
    population_modifier: u16 = 0,
    in_sync: u32 = 0,
    hard_link: u32 = 0,
    placeholder_management: u32 = 0,
};
/// CF_CALLBACK_INFO.
pub const CallbackInfo = extern struct {
    struct_size: u32,
    connection_key: i64,
    context: ?*anyopaque,
    volume_guid_name: ?[*:0]const u16,
    volume_dos_name: ?[*:0]const u16,
    volume_serial: u32,
    root_file_id: i64,
    root_identity: ?*const anyopaque,
    root_identity_len: u32,
    file_id: i64,
    file_size: i64,
    file_identity: ?*const anyopaque,
    file_identity_len: u32,
    normalized_path: ?[*:0]const u16,
    transfer_key: i64,
    priority_hint: u8,
    correlation_vector: ?*const anyopaque,
    process_info: ?*const ProcessInfo,
    request_key: i64,
};
// CF_CALLBACK_PARAMETERS and CF_OPERATION_PARAMETERS: a ULONG, then a union of
// structs with LARGE_INTEGERs, which starts at 8.
pub const FetchDataParams = extern struct {
    param_size: u32,
    union_start: u32,
    flags: u32,
    required_offset: i64,
    required_length: i64,
    optional_offset: i64,
    optional_length: i64,
    last_dehydration_time: i64,
    last_dehydration_reason: u32,
};
pub const CancelParams = extern struct {
    param_size: u32,
    union_start: u32,
    flags: u32,
    offset: i64,
    length: i64,
};
pub const Callback = *const fn (info: *const CallbackInfo, params: *const anyopaque) callconv(.winapi) void;
const CallbackRegistration = extern struct {
    type: u32,
    callback: ?Callback,
};
const OperationInfo = extern struct {
    struct_size: u32 = @sizeOf(OperationInfo),
    type: u32,
    connection_key: i64,
    transfer_key: i64,
    correlation_vector: ?*const anyopaque = null,
    sync_status: ?*const anyopaque = null,
    request_key: i64 = 0,
};
/// CF_OPERATION_PARAMETERS up to its TransferData, which is what its
/// CF_SIZE_OF_OP_PARAM(TransferData) counts.
const TransferParams = extern struct {
    param_size: u32 = @sizeOf(TransferParams),
    union_start: u32 = 0,
    flags: u32 = 0,
    completion_status: i32,
    buffer: ?*const anyopaque,
    offset: i64,
    length: i64,
};
comptime {
    std.debug.assert(@sizeOf(FsMetadata) == 48);
    std.debug.assert(@sizeOf(PlaceholderCreateInfo) == 88);
    std.debug.assert(@offsetOf(CallbackInfo, "request_key") == 144);
    std.debug.assert(@offsetOf(FetchDataParams, "required_offset") == 16);
    std.debug.assert(@offsetOf(CancelParams, "offset") == 16);
    std.debug.assert(@offsetOf(TransferParams, "buffer") == 16);
    std.debug.assert(@sizeOf(TransferParams) == 40);
}

const CF_CALLBACK_TYPE_FETCH_DATA: u32 = 0;
const CF_CALLBACK_TYPE_CANCEL_FETCH_DATA: u32 = 2;
const CF_CALLBACK_TYPE_NONE: u32 = 0xffffffff;
const CF_OPERATION_TYPE_TRANSFER_DATA: u32 = 0;
const CF_HYDRATION_POLICY_PROGRESSIVE: u16 = 1;
const CF_POPULATION_POLICY_ALWAYS_FULL: u16 = 3;
const CF_REGISTER_FLAG_UPDATE: u32 = 1;
const CF_REGISTER_FLAG_DISABLE_ON_DEMAND_POPULATION_ON_ROOT: u32 = 2;
const CF_REGISTER_FLAG_MARK_IN_SYNC_ON_ROOT: u32 = 4;
const CF_CONNECT_FLAG_REQUIRE_PROCESS_INFO: u32 = 2;
const CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH: u32 = 4;
const CF_CONNECT_FLAG_BLOCK_SELF_IMPLICIT_HYDRATION: u32 = 8;
const CF_PLACEHOLDER_CREATE_FLAG_DISABLE_ON_DEMAND_POPULATION: u32 = 1;
const CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC: u32 = 2;
const CF_SYNC_ROOT_INFO_BASIC: u32 = 0;

/// What a fetch that fails says to Windows, which tells whoever was reading.
pub const Status = enum(i32) {
    ok = 0,
    /// A chunk's bytes aren't what the TOC says.
    validation_failed = @bitCast(@as(u32, 0xC000CF0E)),
    unsuccessful = @bitCast(@as(u32, 0xC000CF12)),
};

/// A file's placeholder attributes: its data is in the cloud, as Windows
/// puts it, until it's read. Gone once the deployment is a plain folder.
pub const FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS: u32 = 0x400000;
pub const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;

const Api = struct {
    CfRegisterSyncRoot: *const fn ([*:0]const u16, *const SyncRegistration, *const SyncPolicies, u32) callconv(.winapi) HRESULT,
    CfUnregisterSyncRoot: *const fn ([*:0]const u16) callconv(.winapi) HRESULT,
    CfConnectSyncRoot: *const fn ([*:0]const u16, [*]const CallbackRegistration, ?*const anyopaque, u32, *i64) callconv(.winapi) HRESULT,
    CfDisconnectSyncRoot: *const fn (i64) callconv(.winapi) HRESULT,
    CfExecute: *const fn (*const OperationInfo, *TransferParams) callconv(.winapi) HRESULT,
    CfCreatePlaceholders: *const fn ([*:0]const u16, [*]PlaceholderCreateInfo, u32, u32, ?*u32) callconv(.winapi) HRESULT,
    CfReportProviderProgress: *const fn (i64, i64, i64, i64) callconv(.winapi) HRESULT,
    CfGetSyncRootInfoByPath: *const fn ([*:0]const u16, u32, *anyopaque, u32, ?*u32) callconv(.winapi) HRESULT,
    CfHydratePlaceholder: *const fn (win32.HANDLE, i64, i64, u32, ?*anyopaque) callconv(.winapi) HRESULT,
};

var api_storage: Api = undefined;
var api_state: std.atomic.Value(u8) = .init(0); // 0 not tried, 1 loaded, 2 missing
var api_lock: win32.SRWLOCK = .{};

/// cldapi.dll's functions, or null where there's no such DLL (older Windows,
/// or a server without the feature).
fn api() ?*const Api {
    switch (api_state.load(.acquire)) {
        1 => return &api_storage,
        2 => return null,
        else => {},
    }
    win32.AcquireSRWLockExclusive(&api_lock);
    defer win32.ReleaseSRWLockExclusive(&api_lock);
    if (api_state.load(.acquire) == 0) {
        const loaded = load: {
            const module = win32.LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral("cldapi.dll"), null, win32.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse break :load false;
            inline for (@typeInfo(Api).@"struct".field_names) |name| {
                const address = win32.GetProcAddress(module, name) orelse break :load false;
                @field(api_storage, name) = @ptrCast(@alignCast(address));
            }
            break :load true;
        };
        api_state.store(if (loaded) 1 else 2, .release);
    }
    return if (api_state.load(.acquire) == 1) &api_storage else null;
}

/// The Win32 error in an HRESULT made from one (HRESULT_FROM_WIN32), if it is.
pub fn win32Code(hr: HRESULT) ?u16 {
    const bits: u32 = @bitCast(hr);
    if (bits & 0xFFFF0000 != 0x80070000) return null;
    return @truncate(bits);
}

/// Whether Windows refused because this folder's volume, or this Windows,
/// can't have sync roots at all, rather than because something went wrong:
/// a pull then deploys as it always did.
pub fn meansUnsupported(hr: HRESULT) bool {
    const code = win32Code(hr) orelse return false;
    return switch (code) {
        1, // ERROR_INVALID_FUNCTION: a file system without the feature
        50, // ERROR_NOT_SUPPORTED: a network share, FAT
        379, // ERROR_CLOUD_FILE_NOT_SUPPORTED
        381, // ERROR_CLOUD_FILE_READ_ONLY_VOLUME
        478, // a filter can't attach to the volume: a Dev Drive
        => true,
        else => false,
    };
}

/// What `register` and `connect` refuse with: `Unsupported` where the folder
/// can't be a sync root (see `meansUnsupported`), `Failed` with a message
/// otherwise.
pub const Error = error{ Unsupported, Failed, OutOfMemory, InvalidWtf8 };

fn check(what: []const u8, path: []const u8, hr: HRESULT) Error!void {
    if (hr >= 0) return;
    if (meansUnsupported(hr)) return error.Unsupported;
    if (win32Code(hr)) |code|
        return fail("{s} {s}: Windows error {d} (0x{x:0>8})", .{ what, path, code, @as(u32, @bitCast(hr)) });
    return fail("{s} {s}: 0x{x:0>8}", .{ what, path, @as(u32, @bitCast(hr)) });
}

/// zigsaw's provider, as Windows knows it.
const provider_id: Guid = .{ .a = 0x5b0e7f1d, .b = 0x9c42, .c = 0x4a77, .d = .{ 0x8e, 0x15, 0x2f, 0x63, 0xd0, 0x9a, 0x41, 0xc7 } };

/// Makes `root`, an empty folder, a sync root of zigsaw's, whose identity is
/// the layer's digest. Its files are fetched whole the first time anything
/// reads them, and no directory ever asks: they're all made at once.
/// `again` registers a root Windows has forgotten, or that's already one.
pub fn register(gpa: Allocator, root: []const u8, identity: []const u8, again: bool) Error!void {
    const a = api() orelse return error.Unsupported;
    const root_w = try win32.wide(gpa, root);
    defer gpa.free(root_w);
    const registration: SyncRegistration = .{
        .provider_name = std.unicode.utf8ToUtf16LeStringLiteral("zigsaw"),
        .provider_version = std.unicode.utf8ToUtf16LeStringLiteral("1"),
        .root_identity = identity.ptr,
        .root_identity_len = @intCast(identity.len),
        .file_identity = identity.ptr,
        .file_identity_len = @intCast(identity.len),
        .provider_id = provider_id,
    };
    const policies: SyncPolicies = .{
        .hydration_primary = CF_HYDRATION_POLICY_PROGRESSIVE,
        .population_primary = CF_POPULATION_POLICY_ALWAYS_FULL,
    };
    const flags = CF_REGISTER_FLAG_DISABLE_ON_DEMAND_POPULATION_ON_ROOT | CF_REGISTER_FLAG_MARK_IN_SYNC_ON_ROOT |
        (if (again) CF_REGISTER_FLAG_UPDATE else 0);
    try check("registering", root, a.CfRegisterSyncRoot(root_w, &registration, &policies, flags));
}

/// Stops `root` being a sync root: Windows deletes the files in it that were
/// never read, and keeps the rest. A folder that isn't one is fine.
pub fn unregister(gpa: Allocator, root: []const u8) Error!void {
    const a = api() orelse return;
    const root_w = try win32.wide(gpa, root);
    defer gpa.free(root_w);
    const hr = a.CfUnregisterSyncRoot(root_w);
    if (win32Code(hr)) |code| switch (code) {
        2, 3, 405 => return, // gone, or not a sync root (ERROR_NOT_A_CLOUD_SYNC_ROOT)
        else => {},
    };
    try check("unregistering", root, hr);
}

/// Whether Windows has `path` (or a folder above it) as a sync root.
pub fn isSyncRoot(gpa: Allocator, path: []const u8) bool {
    const a = api() orelse return false;
    const path_w = win32.wide(gpa, path) catch return false;
    defer gpa.free(path_w);
    var info: [64]u8 align(8) = undefined;
    var len: u32 = 0;
    return a.CfGetSyncRootInfoByPath(path_w, CF_SYNC_ROOT_INFO_BASIC, &info, info.len, &len) >= 0;
}

/// Has Windows fetch a placeholder's whole file now, as a read of it would,
/// through the provider's own callbacks. A handle that only reads attributes
/// is what CfHydratePlaceholder takes, and all the provider's own process may
/// open its placeholders with. Returns its HRESULT: negative if it failed.
pub fn hydrate(gpa: Allocator, path: []const u8) !HRESULT {
    const a = api() orelse return error.Unsupported;
    const path_w = try win32.wide(gpa, path);
    defer gpa.free(path_w);
    const FILE_READ_ATTRIBUTES: win32.DWORD = 0x80;
    const h = win32.CreateFileW(path_w, FILE_READ_ATTRIBUTES, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE, null, win32.OPEN_EXISTING, 0, null);
    if (h == win32.INVALID_HANDLE_VALUE) return @bitCast(0x80070000 | @as(u32, win32.GetLastError()));
    defer _ = win32.CloseHandle(h);
    return a.CfHydratePlaceholder(h, 0, -1, 0, null);
}

pub const Connection = struct {
    key: i64,

    pub fn disconnect(c: Connection) void {
        if (api()) |a| _ = a.CfDisconnectSyncRoot(c.key);
    }
};

/// Connects this process to `root` as its provider: Windows calls `fetch`
/// on its own threads, several at once, with `context` in each info. Only one
/// process can be connected to a root (error 378 for a second), and that
/// process can't open the root's placeholders itself (error 395), so it must
/// not run what uses them.
pub fn connect(gpa: Allocator, root: []const u8, context: *anyopaque, fetch: Callback, cancel: Callback) Error!Connection {
    const a = api() orelse return error.Unsupported;
    const root_w = try win32.wide(gpa, root);
    defer gpa.free(root_w);
    const table = [_]CallbackRegistration{
        .{ .type = CF_CALLBACK_TYPE_FETCH_DATA, .callback = fetch },
        .{ .type = CF_CALLBACK_TYPE_CANCEL_FETCH_DATA, .callback = cancel },
        .{ .type = CF_CALLBACK_TYPE_NONE, .callback = null },
    };
    var key: i64 = 0;
    try check("connecting to", root, a.CfConnectSyncRoot(
        root_w,
        &table,
        context,
        CF_CONNECT_FLAG_REQUIRE_PROCESS_INFO | CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH | CF_CONNECT_FLAG_BLOCK_SELF_IMPLICIT_HYDRATION,
        &key,
    ));
    return .{ .key = key };
}

/// A directory's child, to be made a placeholder.
pub const Placeholder = struct {
    name: [:0]const u16,
    dir: bool,
    size: u64,
    /// What a fetch for it carries: an index into the layer's files.
    identity: u32,
};

/// Makes placeholders of `children` in `dir`, which is in a sync root (and
/// a placeholder itself, or the root). Returns how many were made.
pub fn createPlaceholders(gpa: Allocator, dir: []const u8, children: []const Placeholder) Error!usize {
    const a = api() orelse return error.Unsupported;
    if (children.len == 0) return 0;
    const dir_w = try win32.wide(gpa, dir);
    defer gpa.free(dir_w);
    const infos = try gpa.alloc(PlaceholderCreateInfo, children.len);
    defer gpa.free(infos);
    const identities = try gpa.alloc(u32, children.len);
    defer gpa.free(identities);
    var now: i64 = 0;
    win32.GetSystemTimeAsFileTime(&now);
    for (children, infos, identities) |child, *info, *identity| {
        identity.* = child.identity;
        info.* = .{
            .relative_name = child.name,
            .metadata = .{
                .creation = now,
                .access = now,
                .write = now,
                .change = now,
                .attributes = if (child.dir) win32.FILE_ATTRIBUTE_DIRECTORY else 0x80, // FILE_ATTRIBUTE_NORMAL
                .size = @intCast(child.size),
            },
            .identity = identity,
            .identity_len = @sizeOf(u32),
            .flags = CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC |
                (if (child.dir) CF_PLACEHOLDER_CREATE_FLAG_DISABLE_ON_DEMAND_POPULATION else 0),
        };
    }
    var done: u32 = 0;
    try check("making placeholders in", dir, a.CfCreatePlaceholders(dir_w, infos.ptr, @intCast(infos.len), 0, &done));
    for (infos) |info| try check("making a placeholder in", dir, info.result);
    return done;
}

/// The file index a fetch is for, as `createPlaceholders` was given it.
pub fn identityOf(info: *const CallbackInfo) ?u32 {
    if (info.file_identity_len != @sizeOf(u32)) return null;
    const p = info.file_identity orelse return null;
    return @as(*align(1) const u32, @ptrCast(p)).*;
}

/// Hands Windows `data`, a file's bytes from `offset`, for a fetch; or, with
/// a status other than ok and no data, says the fetch of that range failed.
/// A transfer must start and end at multiples of 4 KiB, or at the file's end,
/// which an eStargz chunk does.
pub fn transfer(info: *const CallbackInfo, status: Status, data: ?[]const u8, offset: u64, length: u64) HRESULT {
    const a = api() orelse return @bitCast(@as(u32, 0x80004005)); // E_FAIL
    const op: OperationInfo = .{
        .type = CF_OPERATION_TYPE_TRANSFER_DATA,
        .connection_key = info.connection_key,
        .transfer_key = info.transfer_key,
        .request_key = info.request_key,
    };
    var params: TransferParams = .{
        .completion_status = @backingInt(status),
        .buffer = if (data) |d| d.ptr else null,
        .offset = @intCast(offset),
        .length = @intCast(length),
    };
    return a.CfExecute(&op, &params);
}

/// Tells Windows a slow fetch is still going, which restarts its 60 seconds
/// before it cancels the fetch: `completed` of the file's `total` bytes.
pub fn reportProgress(info: *const CallbackInfo, total: u64, completed: u64) HRESULT {
    const a = api() orelse return @bitCast(@as(u32, 0x80004005)); // E_FAIL
    return a.CfReportProviderProgress(info.connection_key, info.transfer_key, @intCast(total), @intCast(completed));
}

/// The image path of the process a fetch is for, as UTF-8 in `buf`, or "?".
pub fn processImage(info: *const CallbackInfo, buf: []u8) []const u8 {
    const process = info.process_info orelse return "?";
    const path = process.image_path orelse return "?";
    const n = std.unicode.utf16LeToUtf8(buf, std.mem.sliceTo(path, 0)) catch return "?";
    return buf[0..n];
}

test "Win32 errors in HRESULTs, and which mean a volume can't have sync roots" {
    try std.testing.expectEqual(@as(?u16, 478), win32Code(@bitCast(@as(u32, 0x800701de))));
    try std.testing.expectEqual(@as(?u16, null), win32Code(@bitCast(@as(u32, 0xC000CF0E))));
    try std.testing.expect(meansUnsupported(@bitCast(@as(u32, 0x800701de)))); // the Dev Drive here
    try std.testing.expect(meansUnsupported(@bitCast(@as(u32, 0x80070032))));
    try std.testing.expect(!meansUnsupported(@bitCast(@as(u32, 0x80070005)))); // access denied is a failure
    try std.testing.expect(!meansUnsupported(@bitCast(@as(u32, 0x8007017a)))); // 378, already connected
    try std.testing.expect(!meansUnsupported(0));
}
