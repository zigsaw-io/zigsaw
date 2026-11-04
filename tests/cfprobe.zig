//! The Cloud Files experiment's provider (see docs/experiment-cloud-files.md):
//! turns a folder into a sync root whose files are placeholders for an eStargz
//! layer's, and fetches each one from the blob when something first reads it.
//! No zigsaw code runs here. A `zigsaw run` started below `mount` finds the
//! folder where a deployment belongs, and uses it as it would any other.
//!
//!   zigsaw-cfprobe mount <root> <blob> [options] -- <command line>
//!       registers <root>, connects, makes the placeholders if <root> is
//!       empty, runs the command, disconnects, prints what was fetched.
//!         --hydration full|progressive   the root's policy (progressive)
//!         --net-ms <n> --net-mbps <n>    a slower source: a wait per request,
//!                                        and a rate
//!         --block-kib <n>                read blocks of this size, and keep them
//!         --size <n>                     the blob's length, when <blob> is a URL
//!         --log <file>                   one line per fetch
//!         --placeholders-only            exit once they're made
//!         --hydrate-first <threads>      hydrate them all, before the command
//!         --revert-first <threads>       then make them plain files
//!         --revert-after <threads>       the same, after the command
//!         --prefetch <log>               before the command, hydrate and open
//!         --prefetch-threads <n>         the files an earlier --log lists
//!   zigsaw-cfprobe unregister <root>
//!   zigsaw-cfprobe state <path>...       what Windows says each path is
//!   zigsaw-cfprobe read <path>...        opens and reads each, with times
//!   zigsaw-cfprobe map <path>...         maps each and reads its first page
//!   zigsaw-cfprobe load <dll>...         LoadLibrary, with times
//!   zigsaw-cfprobe section <path> [hold-ms]  an image load's steps, with times
//!   zigsaw-cfprobe uncache <path>...     a non-buffered open
//!   zigsaw-cfprobe hydrate <threads> <root or file>
//!   zigsaw-cfprobe revert <threads> <root or file>   back to plain files
//!
//! cldapi.dll is loaded when needed, as zig has no import library for it.

const std = @import("std");
const stargazer = @import("stargazer");
const estargz = stargazer.estargz;
const flate = std.compress.flate;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Allocator = std.mem.Allocator;

const HANDLE = *anyopaque;
const BOOL = i32;
const HRESULT = i32;
const INVALID_HANDLE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

// ---------------------------------------------------------------------------
// Windows

const Overlapped = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: u32 = 0,
    offset_high: u32 = 0,
    event: ?HANDLE = null,
};
const StartupInfo = extern struct {
    cb: u32 = @sizeOf(StartupInfo),
    reserved: ?[*:0]u16 = null,
    desktop: ?[*:0]u16 = null,
    title: ?[*:0]u16 = null,
    x: u32 = 0,
    y: u32 = 0,
    x_size: u32 = 0,
    y_size: u32 = 0,
    x_chars: u32 = 0,
    y_chars: u32 = 0,
    fill: u32 = 0,
    flags: u32 = 0,
    show: u16 = 0,
    reserved2_len: u16 = 0,
    reserved2: ?*u8 = null,
    stdin: ?HANDLE = null,
    stdout: ?HANDLE = null,
    stderr: ?HANDLE = null,
};
const ProcessInformation = extern struct {
    process: HANDLE,
    thread: HANDLE,
    pid: u32,
    tid: u32,
};

const ProcessMemoryCounters = extern struct {
    cb: u32 = @sizeOf(ProcessMemoryCounters),
    page_fault_count: u32 = 0,
    peak_working_set_size: usize = 0,
    working_set_size: usize = 0,
    quota_peak_paged_pool_usage: usize = 0,
    quota_paged_pool_usage: usize = 0,
    quota_peak_non_paged_pool_usage: usize = 0,
    quota_non_paged_pool_usage: usize = 0,
    pagefile_usage: usize = 0,
    peak_pagefile_usage: usize = 0,
    private_usage: usize = 0,
};
const LOAD_WITH_ALTERED_SEARCH_PATH: u32 = 8;
const SrwLock = extern struct { state: ?*anyopaque = null };

extern "kernel32" fn AcquireSRWLockExclusive(lock: *SrwLock) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(lock: *SrwLock) callconv(.winapi) void;
extern "winhttp" fn WinHttpOpen(agent: [*:0]const u16, access: u32, proxy: ?[*:0]const u16, bypass: ?[*:0]const u16, flags: u32) callconv(.winapi) ?HANDLE;
extern "winhttp" fn WinHttpConnect(session: HANDLE, server: [*:0]const u16, port: u16, reserved: u32) callconv(.winapi) ?HANDLE;
extern "winhttp" fn WinHttpOpenRequest(connection: HANDLE, verb: [*:0]const u16, object: [*:0]const u16, version: ?[*:0]const u16, referrer: ?[*:0]const u16, accept: ?*const anyopaque, flags: u32) callconv(.winapi) ?HANDLE;
extern "winhttp" fn WinHttpAddRequestHeaders(request: HANDLE, headers: [*]const u16, len: u32, modifiers: u32) callconv(.winapi) BOOL;
extern "winhttp" fn WinHttpSendRequest(request: HANDLE, headers: ?[*]const u16, headers_len: u32, optional: ?*anyopaque, optional_len: u32, total: u32, context: usize) callconv(.winapi) BOOL;
extern "winhttp" fn WinHttpReceiveResponse(request: HANDLE, reserved: ?*anyopaque) callconv(.winapi) BOOL;
extern "winhttp" fn WinHttpQueryHeaders(request: HANDLE, level: u32, name: ?[*:0]const u16, buffer: *anyopaque, len: *u32, index: ?*u32) callconv(.winapi) BOOL;
extern "winhttp" fn WinHttpReadData(request: HANDLE, buffer: [*]u8, len: u32, read: *u32) callconv(.winapi) BOOL;
extern "winhttp" fn WinHttpCloseHandle(handle: HANDLE) callconv(.winapi) BOOL;

extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?HANDLE, flags: u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn K32GetProcessMemoryInfo(process: HANDLE, counters: *ProcessMemoryCounters, size: u32) callconv(.winapi) BOOL;
extern "kernel32" fn FreeLibrary(module: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetProcAddress(module: HANDLE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, attrs: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn ReadFile(file: HANDLE, buffer: [*]u8, len: u32, read: ?*u32, overlapped: ?*Overlapped) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(file: HANDLE, buffer: [*]const u8, len: u32, written: ?*u32, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetFileSizeEx(file: HANDLE, size: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]u16;
extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmdline: [*:0]u16, pa: ?*anyopaque, ta: ?*anyopaque, inherit: BOOL, flags: u32, env: ?*anyopaque, cwd: ?[*:0]const u16, si: *StartupInfo, pi: *ProcessInformation) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(process: HANDLE, code: *u32) callconv(.winapi) BOOL;
extern "kernel32" fn QueryPerformanceCounter(value: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn QueryPerformanceFrequency(value: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn GetCompressedFileSizeW(name: [*:0]const u16, high: *u32) callconv(.winapi) u32;
extern "kernel32" fn GetFinalPathNameByHandleW(file: HANDLE, path: [*]u16, len: u32, flags: u32) callconv(.winapi) u32;
extern "kernel32" fn CreateFileMappingW(file: HANDLE, attrs: ?*anyopaque, protect: u32, high: u32, low: u32, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn MapViewOfFile(mapping: HANDLE, access: u32, high: u32, low: u32, size: usize) callconv(.winapi) ?[*]const u8;
extern "kernel32" fn UnmapViewOfFile(base: *const anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GetSystemTimeAsFileTime(time: *i64) callconv(.winapi) void;

const GENERIC_READ: u32 = 0x80000000;
const FILE_SHARE_ALL: u32 = 7;
const OPEN_EXISTING: u32 = 3;
const CREATE_ALWAYS: u32 = 2;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
const STARTF_USESTDHANDLES: u32 = 0x100;
const ERROR_HANDLE_EOF: u32 = 38;
const PAGE_READONLY: u32 = 2;
const FILE_MAP_READ: u32 = 4;
const INFINITE: u32 = 0xFFFFFFFF;

// ---------------------------------------------------------------------------
// cfapi.h

const FsMetadata = extern struct {
    creation: i64,
    access: i64,
    write: i64,
    change: i64,
    attributes: u32,
    size: i64,
};
const PlaceholderCreateInfo = extern struct {
    relative_name: [*:0]const u16,
    metadata: FsMetadata,
    identity: ?*const anyopaque,
    identity_len: u32,
    flags: u32,
    result: HRESULT = 0,
    usn: i64 = 0,
};
const ProcessInfo = extern struct {
    struct_size: u32,
    pid: u32,
    image_path: ?[*:0]const u16,
    package_name: ?[*:0]const u16,
    application_id: ?[*:0]const u16,
    command_line: ?[*:0]const u16,
    session_id: u32,
};
const Guid = extern struct {
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
const CallbackInfo = extern struct {
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
const FetchDataParams = extern struct {
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
const CancelParams = extern struct {
    param_size: u32,
    union_start: u32,
    flags: u32,
    offset: i64,
    length: i64,
};
const Callback = *const fn (info: *const CallbackInfo, params: *const anyopaque) callconv(.winapi) void;
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
const CF_HYDRATION_POLICY_FULL: u16 = 2;
const CF_POPULATION_POLICY_ALWAYS_FULL: u16 = 3;
const CF_REGISTER_FLAG_DISABLE_ON_DEMAND_POPULATION_ON_ROOT: u32 = 2;
const CF_REGISTER_FLAG_MARK_IN_SYNC_ON_ROOT: u32 = 4;
const CF_CONNECT_FLAG_REQUIRE_PROCESS_INFO: u32 = 2;
const CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH: u32 = 4;
const CF_CONNECT_FLAG_BLOCK_SELF_IMPLICIT_HYDRATION: u32 = 8;
const CF_PLACEHOLDER_CREATE_FLAG_DISABLE_ON_DEMAND_POPULATION: u32 = 1;
const CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC: u32 = 2;
const STATUS_CLOUD_FILE_UNSUCCESSFUL: i32 = @bitCast(@as(u32, 0xC000CF12));
const STATUS_CLOUD_FILE_VALIDATION_FAILED: i32 = @bitCast(@as(u32, 0xC000CF0E));

const Api = struct {
    CfRegisterSyncRoot: *const fn ([*:0]const u16, *const SyncRegistration, *const SyncPolicies, u32) callconv(.winapi) HRESULT,
    CfUnregisterSyncRoot: *const fn ([*:0]const u16) callconv(.winapi) HRESULT,
    CfConnectSyncRoot: *const fn ([*:0]const u16, [*]const CallbackRegistration, ?*const anyopaque, u32, *i64) callconv(.winapi) HRESULT,
    CfDisconnectSyncRoot: *const fn (i64) callconv(.winapi) HRESULT,
    CfExecute: *const fn (*const OperationInfo, *TransferParams) callconv(.winapi) HRESULT,
    CfCreatePlaceholders: *const fn ([*:0]const u16, [*]PlaceholderCreateInfo, u32, u32, ?*u32) callconv(.winapi) HRESULT,
    CfRevertPlaceholder: *const fn (HANDLE, u32, ?*anyopaque) callconv(.winapi) HRESULT,
    CfHydratePlaceholder: *const fn (HANDLE, i64, i64, u32, ?*anyopaque) callconv(.winapi) HRESULT,
};
var api: Api = undefined;

fn loadApi() !void {
    const module = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("cldapi.dll")) orelse {
        print("cldapi.dll isn't here: error {d}\n", .{GetLastError()});
        return error.Failed;
    };
    inline for (@typeInfo(Api).@"struct".field_names) |name| {
        const address = GetProcAddress(module, name) orelse {
            print("cldapi.dll has no {s}\n", .{name});
            return error.Failed;
        };
        @field(api, name) = @ptrCast(@alignCast(address));
    }
}

// ---------------------------------------------------------------------------
// Printing and time. Callbacks run on Windows' threads, so these use nothing
// but kernel32.

fn print(comptime format: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, format, args) catch return;
    const h = GetStdHandle(@bitCast(@as(i32, -11))) orelse return;
    _ = WriteFile(h, text.ptr, @intCast(text.len), null, null);
}

var counter_frequency: i64 = 1;

fn nowUs() u64 {
    var value: i64 = 0;
    _ = QueryPerformanceCounter(&value);
    return @intCast(@divTrunc(@as(i128, value) * 1_000_000, counter_frequency));
}

fn ms(us: u64) f64 {
    return @as(f64, @floatFromInt(us)) / 1000.0;
}

fn toWide(gpa: Allocator, text: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(gpa, text);
}

fn hresult(what: []const u8, hr: HRESULT) !void {
    if (hr >= 0) return;
    print("{s} failed: 0x{x:0>8}\n", .{ what, @as(u32, @bitCast(hr)) });
    return error.Failed;
}

// ---------------------------------------------------------------------------
// The blob, which any number of callbacks read at once.

const Blob = struct {
    /// A local file, or null when `http` reads it from a URL.
    handle: ?HANDLE = null,
    http: ?Http = null,
    size: u64 = 0,
    net_ms: u32 = 0,
    net_mbps: u32 = 0,
    /// Read whole blocks of this size, and keep the last ones in memory: a
    /// registry's storage takes about as long for 4 KiB as for megabytes, and
    /// files that are used together are often neighbours. 0: read what's asked.
    block_size: usize = 0,
    slots: []Slot = &.{},
    /// Requests for ranges, as a registry would see them.
    requests: std.atomic.Value(u64) = .init(0),
    bytes: std.atomic.Value(u64) = .init(0),

    const Slot = struct {
        lock: SrwLock = .{},
        block: u64 = std.math.maxInt(u64),
        data: ?[]u8 = null,
    };

    fn source(b: *Blob) stargazer.Source {
        return .{ .context = b, .readAtFn = readAt, .size = b.size };
    }

    fn readAt(context: *const anyopaque, offset: u64, buffer: []u8) anyerror!usize {
        const b: *Blob = @ptrCast(@alignCast(@constCast(context)));
        if (b.block_size == 0 or offset >= b.size) return b.readRaw(offset, buffer);
        const block = offset / b.block_size;
        const slot = &b.slots[block % b.slots.len];
        AcquireSRWLockExclusive(&slot.lock);
        defer ReleaseSRWLockExclusive(&slot.lock);
        const start = block * b.block_size;
        const len: usize = @intCast(@min(b.block_size, b.size - start));
        if (slot.block != block) {
            const data = slot.data orelse try std.heap.smp_allocator.alloc(u8, b.block_size);
            slot.data = data;
            slot.block = std.math.maxInt(u64);
            var done: usize = 0;
            while (done < len) {
                const n = try b.readRaw(start + done, data[done..len]);
                if (n == 0) return error.EndOfStream;
                done += n;
            }
            slot.block = block;
        }
        const within: usize = @intCast(offset - start);
        const n = @min(buffer.len, len - within);
        @memcpy(buffer[0..n], slot.data.?[within..][0..n]);
        return n;
    }

    fn readRaw(b: *Blob, offset: u64, buffer: []u8) !usize {
        var got: usize = 0;
        if (b.http) |*http| {
            got = try http.read(offset, buffer);
        } else {
            var overlapped: Overlapped = .{ .offset = @truncate(offset), .offset_high = @truncate(offset >> 32) };
            var n: u32 = 0;
            const want: u32 = @intCast(@min(buffer.len, 1 << 30));
            if (ReadFile(b.handle.?, buffer.ptr, want, &n, &overlapped) == 0) {
                if (GetLastError() == ERROR_HANDLE_EOF) return 0;
                return error.ReadFailed;
            }
            got = n;
        }
        _ = b.requests.fetchAdd(1, .monotonic);
        _ = b.bytes.fetchAdd(got, .monotonic);
        var wait = b.net_ms;
        if (b.net_mbps != 0) wait += @intCast(@as(u64, got) * 8 / 1000 / b.net_mbps);
        if (wait != 0) Sleep(wait);
        return got;
    }
};

/// Ranges of a URL, over connections WinHTTP keeps for reuse. For the
/// experiment, the storage's URL is given (after ghcr.io's redirect), so that
/// no credentials or redirects are involved; zigsaw's own client has those.
const Http = struct {
    session: HANDLE,
    connection: HANDLE,
    object: [:0]const u16,
    secure: bool,

    fn open(gpa: Allocator, url: []const u8) !Http {
        const secure = std.mem.startsWith(u8, url, "https://");
        const rest = url[(if (secure) "https://".len else "http://".len)..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const authority = rest[0..slash];
        const colon = std.mem.indexOfScalar(u8, authority, ':');
        const host = if (colon) |c| authority[0..c] else authority;
        const port: u16 = if (colon) |c| try std.fmt.parseInt(u16, authority[c + 1 ..], 10) else if (secure) 443 else 80;
        const session = WinHttpOpen(std.unicode.utf8ToUtf16LeStringLiteral("zigsaw-cfprobe"), 4, null, null, 0) orelse return error.HttpFailed;
        const connection = WinHttpConnect(session, try toWide(gpa, host), port, 0) orelse return error.HttpFailed;
        return .{ .session = session, .connection = connection, .object = try toWide(gpa, rest[slash..]), .secure = secure };
    }

    fn read(h: *const Http, offset: u64, buffer: []u8) !usize {
        const request = WinHttpOpenRequest(h.connection, std.unicode.utf8ToUtf16LeStringLiteral("GET"), h.object.ptr, null, null, null, if (h.secure) 0x00800000 else 0) orelse return error.HttpFailed;
        defer _ = WinHttpCloseHandle(request);
        var header_utf8: [64]u8 = undefined;
        const header_text = try std.fmt.bufPrint(&header_utf8, "Range: bytes={d}-{d}", .{ offset, offset + buffer.len - 1 });
        var header: [64]u16 = undefined;
        const header_len = try std.unicode.utf8ToUtf16Le(&header, header_text);
        if (WinHttpAddRequestHeaders(request, &header, @intCast(header_len), 0x20000000) == 0) return error.HttpFailed;
        if (WinHttpSendRequest(request, null, 0, null, 0, 0, 0) == 0) return error.HttpFailed;
        if (WinHttpReceiveResponse(request, null) == 0) return error.HttpFailed;
        var status: u32 = 0;
        var status_len: u32 = @sizeOf(u32);
        if (WinHttpQueryHeaders(request, 19 | 0x20000000, null, &status, &status_len, null) == 0) return error.HttpFailed;
        if (status != 206) {
            print("a range request got status {d}\n", .{status});
            return error.HttpFailed;
        }
        var done: usize = 0;
        while (done < buffer.len) {
            var n: u32 = 0;
            const want: u32 = @intCast(@min(buffer.len - done, 1 << 24));
            if (WinHttpReadData(request, buffer.ptr + done, want, &n) == 0) return error.HttpFailed;
            if (n == 0) break;
            done += n;
        }
        return done;
    }
};

// ---------------------------------------------------------------------------
// The provider

const Provider = struct {
    gpa: Allocator,
    reader: *const estargz.Reader,
    blob: *Blob,
    log: ?HANDLE,
    seen: []std.atomic.Value(bool),
    started_us: u64,

    fetches: std.atomic.Value(u64) = .init(0),
    files: std.atomic.Value(u64) = .init(0),
    served: std.atomic.Value(u64) = .init(0),
    failures: std.atomic.Value(u64) = .init(0),
    cancels: std.atomic.Value(u64) = .init(0),
    inflight: std.atomic.Value(u64) = .init(0),
    max_inflight: std.atomic.Value(u64) = .init(0),
    us_source: std.atomic.Value(u64) = .init(0),
    us_inflate: std.atomic.Value(u64) = .init(0),
    us_transfer: std.atomic.Value(u64) = .init(0),

    lock: std.atomic.Value(bool) = .init(false),
    by_process: [32]ProcessRow = @splat(.{}),
    process_rows: usize = 0,

    const ProcessRow = struct {
        name: [64]u8 = undefined,
        name_len: usize = 0,
        fetches: u64 = 0,
        bytes: u64 = 0,
    };

    fn account(p: *Provider, image: []const u8, bytes: u64) void {
        const base = if (std.mem.lastIndexOfScalar(u8, image, '\\')) |i| image[i + 1 ..] else image;
        while (p.lock.swap(true, .acquire)) std.atomic.spinLoopHint();
        defer p.lock.store(false, .release);
        for (p.by_process[0..p.process_rows]) |*row| {
            if (std.mem.eql(u8, row.name[0..row.name_len], base)) {
                row.fetches += 1;
                row.bytes += bytes;
                return;
            }
        }
        if (p.process_rows == p.by_process.len) return;
        const row = &p.by_process[p.process_rows];
        p.process_rows += 1;
        row.name_len = @min(base.len, row.name.len);
        @memcpy(row.name[0..row.name_len], base[0..row.name_len]);
        row.fetches = 1;
        row.bytes = bytes;
    }

    fn logLine(p: *Provider, comptime format: []const u8, args: anytype) void {
        const h = p.log orelse return;
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, format, args) catch return;
        _ = WriteFile(h, text.ptr, @intCast(text.len), null, null);
    }
};

fn transfer(info: *const CallbackInfo, status: i32, buffer: ?[*]const u8, offset: i64, length: i64) HRESULT {
    const op: OperationInfo = .{
        .type = CF_OPERATION_TYPE_TRANSFER_DATA,
        .connection_key = info.connection_key,
        .transfer_key = info.transfer_key,
        .request_key = info.request_key,
    };
    var params: TransferParams = .{ .completion_status = status, .buffer = buffer, .offset = offset, .length = length };
    return api.CfExecute(&op, &params);
}

/// One chunk's bytes, checked against its digest before Windows sees them.
fn inflateChunk(p: *Provider, chunk: estargz.Reader.Chunk, compressed: []u8, window: []u8, out: []u8) !void {
    const t0 = nowUs();
    try p.reader.source.readAll(chunk.offset, compressed);
    const t1 = nowUs();
    _ = p.us_source.fetchAdd(t1 - t0, .monotonic);
    var in: std.Io.Reader = .fixed(compressed);
    var d: flate.Decompress = .init(&in, .gzip, window);
    try d.reader.discardAll64(chunk.inner_offset);
    try d.reader.readSliceAll(out);
    if (chunk.digest) |want| {
        var got: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(out, &got, .{});
        if (!std.mem.eql(u8, &got, &want)) return error.DigestMismatch;
    }
    _ = p.us_inflate.fetchAdd(nowUs() - t1, .monotonic);
}

fn serve(p: *Provider, info: *const CallbackInfo, file: *const estargz.Reader.File, first: u64, last: u64) !u64 {
    const window = try p.gpa.alloc(u8, flate.max_window_len);
    defer p.gpa.free(window);
    var served: u64 = 0;
    for (file.chunks) |chunk| {
        if (chunk.file_offset + chunk.size <= first or chunk.file_offset >= last) continue;
        const compressed = try p.gpa.alloc(u8, @intCast(chunk.end - chunk.offset));
        defer p.gpa.free(compressed);
        const out = try p.gpa.alloc(u8, @intCast(chunk.size));
        defer p.gpa.free(out);
        try inflateChunk(p, chunk, compressed, window, out);
        const t0 = nowUs();
        // A chunk starts at a multiple of the chunk size, and ends at one or
        // at the end of the file, which is what a transfer has to be.
        const hr = transfer(info, 0, out.ptr, @intCast(chunk.file_offset), @intCast(chunk.size));
        _ = p.us_transfer.fetchAdd(nowUs() - t0, .monotonic);
        try hresult("CfExecute (transfer)", hr);
        served += chunk.size;
    }
    return served;
}

fn onFetchData(info: *const CallbackInfo, raw: *const anyopaque) callconv(.winapi) void {
    const p: *Provider = @ptrCast(@alignCast(info.context.?));
    const params: *const FetchDataParams = @ptrCast(@alignCast(raw));
    const t0 = nowUs();
    const inflight = p.inflight.fetchAdd(1, .monotonic) + 1;
    _ = p.max_inflight.fetchMax(inflight, .monotonic);
    defer _ = p.inflight.fetchSub(1, .monotonic);
    _ = p.fetches.fetchAdd(1, .monotonic);

    var image_buf: [512]u8 = undefined;
    var image: []const u8 = "?";
    if (info.process_info) |process| if (process.image_path) |path| {
        const n = std.unicode.utf16LeToUtf8(&image_buf, std.mem.sliceTo(path, 0)) catch 0;
        image = image_buf[0..n];
    };

    const index = @as(*align(1) const u32, @ptrCast(info.file_identity.?)).*;
    const file = &p.reader.files[index];
    const first: u64 = @intCast(params.required_offset);
    const last: u64 = first + @as(u64, @intCast(params.required_length));
    if (!p.seen[index].swap(true, .monotonic)) _ = p.files.fetchAdd(1, .monotonic);

    const served = serve(p, info, file, first, last) catch |err| {
        _ = p.failures.fetchAdd(1, .monotonic);
        print("fetch of {s} failed: {t}\n", .{ file.name, err });
        const status = if (err == error.DigestMismatch) STATUS_CLOUD_FILE_VALIDATION_FAILED else STATUS_CLOUD_FILE_UNSUCCESSFUL;
        _ = transfer(info, status, null, params.required_offset, params.required_length);
        return;
    };
    _ = p.served.fetchAdd(served, .monotonic);
    p.account(image, served);
    p.logLine("{d:.1}\t{d:.1}\t{s}\t{d}\t{d}\t{d}\t{s}\n", .{ ms(t0 - p.started_us), ms(nowUs() - t0), file.name, first, last - first, served, image });
}

fn onCancel(info: *const CallbackInfo, raw: *const anyopaque) callconv(.winapi) void {
    const p: *Provider = @ptrCast(@alignCast(info.context.?));
    const params: *const CancelParams = @ptrCast(@alignCast(raw));
    _ = p.cancels.fetchAdd(1, .monotonic);
    p.logLine("cancel\tflags={d}\t{d}\t{d}\n", .{ params.flags, params.offset, params.length });
}

// ---------------------------------------------------------------------------
// Placeholders

const Child = struct {
    name: [:0]const u16,
    is_dir: bool,
    size: u64,
    /// Into the reader's files; which file a fetch is for.
    index: u32,
};

const Tree = struct {
    gpa: Allocator,
    /// Each directory's children, by its name in the layer ("" for the root).
    dirs: std.StringArrayHashMapUnmanaged(std.ArrayList(Child)) = .empty,

    fn addDir(t: *Tree, name: []const u8) anyerror!void {
        const entry = try t.dirs.getOrPut(t.gpa, name);
        if (entry.found_existing) return;
        entry.value_ptr.* = .empty;
        if (name.len == 0) return;
        const parent = std.fs.path.dirnamePosix(name) orelse "";
        try t.addDir(parent);
        try t.dirs.getPtr(parent).?.append(t.gpa, .{
            .name = try toWide(t.gpa, std.fs.path.basenamePosix(name)),
            .is_dir = true,
            .size = 0,
            .index = 0,
        });
    }

    fn addFile(t: *Tree, name: []const u8, size: u64, index: u32) !void {
        const parent = std.fs.path.dirnamePosix(name) orelse "";
        try t.addDir(parent);
        try t.dirs.getPtr(parent).?.append(t.gpa, .{
            .name = try toWide(t.gpa, std.fs.path.basenamePosix(name)),
            .is_dir = false,
            .size = size,
            .index = index,
        });
    }
};

fn depth(name: []const u8) usize {
    if (name.len == 0) return 0;
    return std.mem.count(u8, name, "/") + 1;
}

/// Makes a placeholder of each directory and regular file, directories first,
/// as a directory's children go in one batch with it as their base.
fn makePlaceholders(gpa: Allocator, root: []const u8, reader: *const estargz.Reader) !usize {
    var tree: Tree = .{ .gpa = gpa };
    try tree.addDir("");
    for (reader.files, 0..) |*file, i| {
        if (estargz.isReserved(file.name)) continue;
        switch (file.entry.type) {
            .dir => try tree.addDir(file.name),
            .reg => try tree.addFile(file.name, file.size, @intCast(i)),
            else => {
                print("{s}: a kind of entry this can't make\n", .{file.name});
                return error.Failed;
            },
        }
    }
    const names = tree.dirs.keys();
    const order = try gpa.alloc(usize, names.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, names, struct {
        fn less(n: [][]const u8, a: usize, b: usize) bool {
            return depth(n[a]) < depth(n[b]);
        }
    }.less);

    var now: i64 = 0;
    GetSystemTimeAsFileTime(&now);
    var made: usize = 0;
    for (order) |o| {
        const children = tree.dirs.values()[o].items;
        if (children.len == 0) continue;
        const relative = try gpa.dupe(u8, names[o]);
        std.mem.replaceScalar(u8, relative, '/', '\\');
        const base = try toWide(gpa, if (relative.len == 0) root else try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root, relative }));
        const infos = try gpa.alloc(PlaceholderCreateInfo, children.len);
        const identities = try gpa.alloc(u32, children.len);
        for (children, infos, identities) |child, *info, *identity| {
            identity.* = child.index;
            info.* = .{
                .relative_name = child.name,
                .metadata = .{
                    .creation = now,
                    .access = now,
                    .write = now,
                    .change = now,
                    .attributes = if (child.is_dir) FILE_ATTRIBUTE_DIRECTORY else FILE_ATTRIBUTE_NORMAL,
                    .size = @intCast(child.size),
                },
                .identity = identity,
                .identity_len = @sizeOf(u32),
                .flags = CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC |
                    (if (child.is_dir) CF_PLACEHOLDER_CREATE_FLAG_DISABLE_ON_DEMAND_POPULATION else 0),
            };
        }
        var done: u32 = 0;
        try hresult("CfCreatePlaceholders", api.CfCreatePlaceholders(base, infos.ptr, @intCast(infos.len), 0, &done));
        for (infos) |info| try hresult("a placeholder", info.result);
        made += done;
    }
    return made;
}

// ---------------------------------------------------------------------------
// Commands

const provider_id: Guid = .{ .a = 0x7a1f0c55, .b = 0x3b1e, .c = 0x4f8a, .d = .{ 0x9d, 0x21, 0x5e, 0x0a, 0x6c, 0x44, 0x71, 0x8b } };

fn register(root: [:0]const u16, policy: u16) !void {
    const identity = "zigsaw-cfprobe";
    const registration: SyncRegistration = .{
        .provider_name = std.unicode.utf8ToUtf16LeStringLiteral("zigsaw-cfprobe"),
        .provider_version = std.unicode.utf8ToUtf16LeStringLiteral("0"),
        .root_identity = identity,
        .root_identity_len = identity.len,
        .file_identity = identity,
        .file_identity_len = identity.len,
        .provider_id = provider_id,
    };
    const policies: SyncPolicies = .{
        .hydration_primary = policy,
        .population_primary = CF_POPULATION_POLICY_ALWAYS_FULL,
    };
    try hresult("CfRegisterSyncRoot", api.CfRegisterSyncRoot(
        root,
        &registration,
        &policies,
        CF_REGISTER_FLAG_DISABLE_ON_DEMAND_POPULATION_ON_ROOT | CF_REGISTER_FLAG_MARK_IN_SYNC_ON_ROOT,
    ));
}

fn isEmptyDir(io: std.Io, path: []const u8) !bool {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    return (try it.next(io)) == null;
}

/// The command line after " -- ", quoted as it was given.
fn commandAfterDashes(gpa: Allocator) ![:0]u16 {
    const line = std.mem.sliceTo(GetCommandLineW(), 0);
    const dashes = std.unicode.utf8ToUtf16LeStringLiteral(" -- ");
    const at = std.mem.indexOf(u16, line, dashes) orelse {
        print("mount: no command after --\n", .{});
        return error.Failed;
    };
    return gpa.dupeSentinel(u16, line[at + dashes.len ..], 0);
}

fn runCommand(command: [:0]u16) !u32 {
    var startup: StartupInfo = .{
        .flags = STARTF_USESTDHANDLES,
        .stdin = GetStdHandle(@bitCast(@as(i32, -10))),
        .stdout = GetStdHandle(@bitCast(@as(i32, -11))),
        .stderr = GetStdHandle(@bitCast(@as(i32, -12))),
    };
    var process: ProcessInformation = undefined;
    if (CreateProcessW(null, command.ptr, null, null, 1, 0, null, null, &startup, &process) == 0) {
        print("starting the command failed: error {d}\n", .{GetLastError()});
        return error.Failed;
    }
    _ = CloseHandle(process.thread);
    _ = WaitForSingleObject(process.process, INFINITE);
    var code: u32 = 1;
    _ = GetExitCodeProcess(process.process, &code);
    _ = CloseHandle(process.process);
    return code;
}

fn mount(gpa: Allocator, io: std.Io, args: []const [:0]const u8) !u8 {
    if (args.len < 2) return usage();
    const root_text = args[0];
    const blob_text = args[1];
    var policy = CF_HYDRATION_POLICY_PROGRESSIVE;
    var blob: Blob = .{};
    var block_kib: usize = 0;
    var url_size: u64 = 0;
    var log: ?HANDLE = null;
    var placeholders_only = false;
    var hydrate_first: usize = 0;
    var revert_first: usize = 0;
    var revert_after: usize = 0;
    var prefetch_list: ?[]const u8 = null;
    var prefetch_threads: usize = 8;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) break;
        if (std.mem.eql(u8, a, "--placeholders-only")) {
            placeholders_only = true;
            continue;
        }
        i += 1;
        if (i == args.len) return usage();
        if (std.mem.eql(u8, a, "--prefetch")) {
            prefetch_list = args[i];
        } else if (std.mem.eql(u8, a, "--prefetch-threads")) {
            prefetch_threads = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--hydrate-first")) {
            hydrate_first = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--revert-first")) {
            revert_first = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--revert-after")) {
            revert_after = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--hydration")) {
            policy = if (std.mem.eql(u8, args[i], "full")) CF_HYDRATION_POLICY_FULL else CF_HYDRATION_POLICY_PROGRESSIVE;
        } else if (std.mem.eql(u8, a, "--block-kib")) {
            block_kib = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--size")) {
            url_size = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--net-ms")) {
            blob.net_ms = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--net-mbps")) {
            blob.net_mbps = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--log")) {
            log = CreateFileW(try toWide(gpa, args[i]), 0x40000000, FILE_SHARE_ALL, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
        } else return usage();
    }

    const t_start = nowUs();
    if (std.mem.startsWith(u8, blob_text, "http")) {
        blob.http = try Http.open(gpa, blob_text);
        blob.size = url_size;
    } else {
        const h = CreateFileW(try toWide(gpa, blob_text), GENERIC_READ, FILE_SHARE_ALL, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
        if (h == INVALID_HANDLE) {
            print("opening the blob failed: error {d}\n", .{GetLastError()});
            return error.Failed;
        }
        blob.handle = h;
        var size: i64 = 0;
        _ = GetFileSizeEx(h, &size);
        blob.size = @intCast(size);
    }
    // The TOC goes by itself, at the end of the blob: not through the blocks.
    const reader = try estargz.Reader.open(gpa, blob.source(), .{});
    const toc_bytes = blob.bytes.swap(0, .monotonic);
    const toc_requests = blob.requests.swap(0, .monotonic);
    const t_toc = nowUs();
    if (block_kib != 0) {
        blob.block_size = block_kib * 1024;
        // Up to 256 MiB of blocks.
        const slots = @max(1, (256 * 1024) / block_kib);
        blob.slots = try gpa.alloc(Blob.Slot, slots);
        for (blob.slots) |*s| s.* = .{};
    }

    const root_wide = try toWide(gpa, root_text);
    try std.Io.Dir.cwd().createDirPath(io, root_text);
    const fresh = try isEmptyDir(io, root_text);
    if (fresh) try register(root_wide, policy);
    const t_registered = nowUs();

    const seen = try gpa.alloc(std.atomic.Value(bool), reader.files.len);
    for (seen) |*s| s.* = .init(false);
    const provider = try gpa.create(Provider);
    provider.* = .{ .gpa = gpa, .reader = reader, .blob = &blob, .log = log, .seen = seen, .started_us = t_start };

    const table = [_]CallbackRegistration{
        .{ .type = CF_CALLBACK_TYPE_FETCH_DATA, .callback = onFetchData },
        .{ .type = CF_CALLBACK_TYPE_CANCEL_FETCH_DATA, .callback = onCancel },
        .{ .type = CF_CALLBACK_TYPE_NONE, .callback = null },
    };
    var key: i64 = 0;
    try hresult("CfConnectSyncRoot", api.CfConnectSyncRoot(
        root_wide,
        &table,
        provider,
        CF_CONNECT_FLAG_REQUIRE_PROCESS_INFO | CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH | CF_CONNECT_FLAG_BLOCK_SELF_IMPLICIT_HYDRATION,
        &key,
    ));
    const t_connected = nowUs();

    var made: usize = 0;
    if (fresh) made = try makePlaceholders(gpa, root_text, reader);
    const t_made = nowUs();

    // Windows lets the connected provider's process revert, and no other. And
    // this process sees placeholders as what they are, reparse points, so a
    // walk of the tree wouldn't take them for files: the TOC lists them.
    const toc_files = try filesOfToc(gpa, root_text, reader);
    if (hydrate_first != 0) overFiles("hydrate", hydrateOne, hydrate_first, toc_files);
    if (revert_first != 0) overFiles("revert", revertOne, revert_first, toc_files);
    if (prefetch_list) |list| overFiles("prefetch", prefetchOne, prefetch_threads, try filesOfLog(gpa, io, root_text, list));
    const t_before_command = nowUs();

    var code: u32 = 0;
    if (!placeholders_only) code = try runCommand(try commandAfterDashes(gpa));
    const t_ran = nowUs();

    if (revert_after != 0) overFiles("revert", revertOne, revert_after, toc_files);

    _ = api.CfDisconnectSyncRoot(key);
    print(
        \\cfprobe: toc {d:.0} ms ({d} KB in {d} reads), register {d:.0} ms, connect {d:.0} ms, {d} placeholders {d:.0} ms
        \\cfprobe: command {d:.0} ms, exit {d}
        \\cfprobe: {d} fetches of {d} files (at most {d} at once), {d:.1} MB served, {d:.1} MB of {d:.1} MB of the blob in {d} requests, {d} failed, {d} cancelled
        \\cfprobe: in callbacks: source {d:.0} ms, inflate+check {d:.0} ms, transfer {d:.0} ms
        \\
    , .{
        ms(t_toc - t_start),                       toc_bytes / 1024,
        toc_requests,                              ms(t_registered - t_toc),
        ms(t_connected - t_registered),            made,
        ms(t_made - t_connected),                  ms(t_ran - t_before_command),
        code,                                      provider.fetches.load(.monotonic),
        provider.files.load(.monotonic),           provider.max_inflight.load(.monotonic),
        mb(provider.served.load(.monotonic)),      mb(blob.bytes.load(.monotonic)),
        mb(blob.size),                             blob.requests.load(.monotonic),
        provider.failures.load(.monotonic),        provider.cancels.load(.monotonic),
        ms(provider.us_source.load(.monotonic)),   ms(provider.us_inflate.load(.monotonic)),
        ms(provider.us_transfer.load(.monotonic)),
    });
    for (provider.by_process[0..provider.process_rows]) |row|
        print("cfprobe:   {s}: {d} fetches, {d:.1} MB\n", .{ row.name[0..row.name_len], row.fetches, mb(row.bytes) });
    return @truncate(code);
}

fn mb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

fn state(gpa: Allocator, paths: []const [:0]const u8) !u8 {
    for (paths) |path| {
        const wide = try toWide(gpa, path);
        const attributes = GetFileAttributesW(wide);
        if (attributes == 0xFFFFFFFF) {
            print("{s}: error {d}\n", .{ path, GetLastError() });
            continue;
        }
        var high: u32 = 0;
        const low = GetCompressedFileSizeW(wide, &high);
        print("{s}: attributes 0x{x:0>8}{s}{s}{s}{s}{s}{s}, on disk {d}\n", .{
            path,
            attributes,
            if (attributes & 0x400 != 0) " reparse" else "",
            if (attributes & 0x1000 != 0) " offline" else "",
            if (attributes & 0x200 != 0) " sparse" else "",
            if (attributes & 0x40000 != 0) " recall-on-open" else "",
            if (attributes & 0x400000 != 0) " recall-on-data-access" else "",
            if (attributes & 0x80000 != 0) " pinned" else "",
            (@as(u64, high) << 32) | low,
        });
    }
    return 0;
}

fn read(gpa: Allocator, paths: []const [:0]const u8) !u8 {
    const buffer = try gpa.alloc(u8, 1 << 20);
    var failed: u8 = 0;
    for (paths) |path| {
        const t0 = nowUs();
        const h = CreateFileW(try toWide(gpa, path), GENERIC_READ, FILE_SHARE_ALL, null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, null);
        const t1 = nowUs();
        if (h == INVALID_HANDLE) {
            print("{s}: open: error {d}\n", .{ path, GetLastError() });
            failed = 1;
            continue;
        }
        var final: [1024]u16 = undefined;
        const final_len = GetFinalPathNameByHandleW(h, &final, final.len, 0);
        var total: u64 = 0;
        var error_code: u32 = 0;
        const t2 = nowUs();
        var first_us: ?u64 = null;
        while (true) {
            var n: u32 = 0;
            if (ReadFile(h, buffer.ptr, @intCast(buffer.len), &n, null) == 0) {
                error_code = GetLastError();
                break;
            }
            first_us = first_us orelse nowUs();
            if (n == 0) break;
            total += n;
        }
        const t3 = nowUs();
        _ = CloseHandle(h);
        if (error_code != 0) failed = 1;
        var final_utf8: [2048]u8 = undefined;
        const final_n = std.unicode.utf16LeToUtf8(&final_utf8, final[0..@min(final_len, final.len)]) catch 0;
        print("{s}: open {d:.1} ms, first read {d:.1} ms, all {d:.1} ms, {d} bytes, error {d}, final path {s}\n", .{ path, ms(t1 - t0), ms((first_us orelse t3) - t2), ms(t3 - t2), total, error_code, final_utf8[0..final_n] });
    }
    return failed;
}

fn map(gpa: Allocator, paths: []const [:0]const u8) !u8 {
    var failed: u8 = 0;
    for (paths) |path| {
        const t0 = nowUs();
        const h = CreateFileW(try toWide(gpa, path), GENERIC_READ, FILE_SHARE_ALL, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
        if (h == INVALID_HANDLE) {
            print("{s}: open: error {d}\n", .{ path, GetLastError() });
            failed = 1;
            continue;
        }
        const mapping = CreateFileMappingW(h, null, PAGE_READONLY, 0, 0, null) orelse {
            print("{s}: mapping: error {d}\n", .{ path, GetLastError() });
            failed = 1;
            _ = CloseHandle(h);
            continue;
        };
        const t1 = nowUs();
        const view = MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 4096) orelse {
            print("{s}: view: error {d}\n", .{ path, GetLastError() });
            failed = 1;
            continue;
        };
        const first = @as(*const volatile u8, &view[0]).*;
        const t2 = nowUs();
        _ = UnmapViewOfFile(view);
        _ = CloseHandle(mapping);
        _ = CloseHandle(h);
        print("{s}: mapped in {d:.1} ms, first page in {d:.1} ms, first byte 0x{x:0>2}\n", .{ path, ms(t1 - t0), ms(t2 - t1), first });
    }
    return failed;
}

fn privateBytes() u64 {
    var counters: ProcessMemoryCounters = .{};
    _ = K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, @sizeOf(ProcessMemoryCounters));
    return counters.private_usage;
}

/// The base address a DLL's headers ask for.
fn preferredBase(module: HANDLE) u64 {
    const bytes: [*]const u8 = @ptrCast(module);
    const pe: u32 = std.mem.readInt(u32, bytes[0x3c..][0..4], .little);
    return std.mem.readInt(u64, bytes[pe + 24 + 24 ..][0..8], .little);
}

fn load(gpa: Allocator, paths: []const [:0]const u8) !u8 {
    var failed: u8 = 0;
    for (paths) |path| {
        const before = privateBytes();
        const t0 = nowUs();
        const module = LoadLibraryExW(try toWide(gpa, path), null, LOAD_WITH_ALTERED_SEARCH_PATH);
        const t1 = nowUs();
        if (module) |m| {
            print("{s}: loaded in {d:.1} ms at 0x{x} (it asks for 0x{x}), private memory +{d:.1} MB\n", .{ path, ms(t1 - t0), @intFromPtr(m), preferredBase(m), mb(privateBytes() - before) });
            _ = FreeLibrary(m);
        } else {
            print("{s}: error {d} after {d:.1} ms\n", .{ path, GetLastError(), ms(t1 - t0) });
            failed = 1;
        }
    }
    return failed;
}

/// Every regular file below `root`, as absolute paths.
fn listFiles(gpa: Allocator, io: std.Io, root: []const u8) ![][:0]const u16 {
    var out: std.ArrayList([:0]const u16) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try out.append(gpa, try toWide(gpa, try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root, entry.path })));
    }
    return out.toOwnedSlice(gpa);
}

const Work = struct {
    files: []const [:0]const u16,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(usize) = .init(0),
    first_error: std.atomic.Value(i32) = .init(0),
    action: *const fn ([*:0]const u16) i32,

    fn run(w: *Work) void {
        while (true) {
            const i = w.next.fetchAdd(1, .monotonic);
            if (i >= w.files.len) return;
            const hr = w.action(w.files[i].ptr);
            if (hr < 0) {
                _ = w.failed.fetchAdd(1, .monotonic);
                _ = w.first_error.cmpxchgStrong(0, hr, .monotonic, .monotonic);
            }
        }
    }
};

fn hydrateOne(path: [*:0]const u16) i32 {
    const h = CreateFileW(path, 0x80, FILE_SHARE_ALL, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE) return @bitCast(0x80070000 | GetLastError());
    defer _ = CloseHandle(h);
    return api.CfHydratePlaceholder(h, 0, -1, 0, null);
}

/// Hydrates a file, then opens and reads it, as whatever scans a file on its
/// first open then has its answer before the app comes to it.
fn prefetchOne(path: [*:0]const u16) i32 {
    const hr = hydrateOne(path);
    if (hr < 0) return hr;
    const h = CreateFileW(path, GENERIC_READ, FILE_SHARE_ALL, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE) return @bitCast(0x80070000 | GetLastError());
    defer _ = CloseHandle(h);
    var byte: [1]u8 = undefined;
    var n: u32 = 0;
    _ = ReadFile(h, &byte, 1, &n, null);
    return 0;
}

/// The files a previous run's --log says it fetched, below `root`.
fn filesOfLog(gpa: Allocator, io: std.Io, root: []const u8, log_path: []const u8) ![][:0]const u16 {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .limited(1 << 28));
    var out: std.ArrayList([:0]const u16) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var columns = std.mem.splitScalar(u8, line, '\t');
        _ = columns.next();
        _ = columns.next() orelse continue;
        const name = columns.next() orelse continue;
        const relative = try gpa.dupe(u8, name);
        std.mem.replaceScalar(u8, relative, '/', '\\');
        try out.append(gpa, try toWide(gpa, try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root, relative })));
    }
    return out.toOwnedSlice(gpa);
}

/// Turns a hydrated placeholder back into a plain file. Windows asks for
/// WRITE_DATA or WRITE_DAC, and a deployment's deny entry only takes the first.
fn revertOne(path: [*:0]const u16) i32 {
    const WRITE_DAC: u32 = 0x00040000;
    const h = CreateFileW(path, WRITE_DAC | 0x80, FILE_SHARE_ALL, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE) return @bitCast(0x80070000 | GetLastError());
    defer _ = CloseHandle(h);
    return api.CfRevertPlaceholder(h, 0, null);
}

/// `hydrate|revert <threads> <root or file>`: over every file of a tree, or
/// the one file.
fn overTree(gpa: Allocator, io: std.Io, name: []const u8, action: *const fn ([*:0]const u16) i32, args: []const [:0]const u8) !u8 {
    if (args.len != 2) return usage();
    const threads = try std.fmt.parseInt(usize, args[0], 10);
    const attributes = GetFileAttributesW(try toWide(gpa, args[1]));
    const files = if (attributes != 0xFFFFFFFF and attributes & FILE_ATTRIBUTE_DIRECTORY == 0)
        try gpa.dupe([:0]const u16, &.{try toWide(gpa, args[1])})
    else
        try listFiles(gpa, io, args[1]);
    overFiles(name, action, threads, files);
    return 0;
}

fn overFiles(name: []const u8, action: *const fn ([*:0]const u16) i32, threads: usize, files: []const [:0]const u16) void {
    const t0 = nowUs();
    var work: Work = .{ .files = files, .action = action };
    var pool: [64]std.Thread = undefined;
    const count = @min(threads, pool.len);
    for (pool[0..count]) |*t| t.* = std.Thread.spawn(.{}, Work.run, .{&work}) catch unreachable;
    for (pool[0..count]) |t| t.join();
    print("{s}: {d} files in {d:.0} ms with {d} threads, {d} failed (first 0x{x:0>8})\n", .{ name, files.len, ms(nowUs() - t0), count, work.failed.load(.monotonic), @as(u32, @bitCast(work.first_error.load(.monotonic))) });
}

/// The layer's regular files, as absolute paths below `root`.
fn filesOfToc(gpa: Allocator, root: []const u8, reader: *const estargz.Reader) ![][:0]const u16 {
    var out: std.ArrayList([:0]const u16) = .empty;
    for (reader.files) |*file| {
        if (file.entry.type != .reg or estargz.isReserved(file.name)) continue;
        const relative = try gpa.dupe(u8, file.name);
        std.mem.replaceScalar(u8, relative, '/', '\\');
        try out.append(gpa, try toWide(gpa, try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root, relative })));
    }
    return out.toOwnedSlice(gpa);
}

/// `section <path> [hold-ms]`: an image load's steps, one by one. Holds the
/// mapping for hold-ms before letting it go.
fn section(gpa: Allocator, args: []const [:0]const u8) !u8 {
    if (args.len == 0) return usage();
    const SEC_IMAGE: u32 = 0x01000000;
    const FILE_EXECUTE: u32 = 0x20;
    const FILE_SHARE_READ_DELETE: u32 = 5;
    const FILE_MAP_EXECUTE: u32 = 0x20;
    const PAGE_EXECUTE_READ: u32 = 0x20;
    const hold: u32 = if (args.len > 1) try std.fmt.parseInt(u32, args[1], 10) else 0;
    const t0 = nowUs();
    const h = CreateFileW(try toWide(gpa, args[0]), GENERIC_READ | FILE_EXECUTE, FILE_SHARE_READ_DELETE, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE) {
        print("open: error {d}\n", .{GetLastError()});
        return 1;
    }
    const t1 = nowUs();
    const mapping = CreateFileMappingW(h, null, PAGE_EXECUTE_READ | SEC_IMAGE, 0, 0, null) orelse {
        print("section: error {d}\n", .{GetLastError()});
        return 1;
    };
    const t2 = nowUs();
    const view = MapViewOfFile(mapping, FILE_MAP_READ | FILE_MAP_EXECUTE, 0, 0, 0) orelse {
        print("view: error {d}\n", .{GetLastError()});
        return 1;
    };
    const t3 = nowUs();
    const first = @as(*const volatile u8, &view[0]).*;
    const t4 = nowUs();
    print("open {d:.2} ms, section {d:.2} ms, map {d:.2} ms, first page {d:.2} ms (0x{x:0>2})\n", .{ ms(t1 - t0), ms(t2 - t1), ms(t3 - t2), ms(t4 - t3), first });
    if (hold != 0) Sleep(hold);
    _ = UnmapViewOfFile(view);
    _ = CloseHandle(mapping);
    _ = CloseHandle(h);
    return 0;
}

/// `uncache <path>...`: a non-buffered open, which has the file system purge a
/// file's cached data when nothing else has it open, so that what's in memory
/// about the file can go.
fn uncache(gpa: Allocator, paths: []const [:0]const u8) !u8 {
    const FILE_FLAG_NO_BUFFERING: u32 = 0x20000000;
    const buffer = try gpa.alignedAlloc(u8, .fromByteUnits(4096), 4096);
    for (paths) |path| {
        const h = CreateFileW(try toWide(gpa, path), GENERIC_READ, FILE_SHARE_ALL, null, OPEN_EXISTING, FILE_FLAG_NO_BUFFERING, null);
        if (h == INVALID_HANDLE) {
            print("{s}: error {d}\n", .{ path, GetLastError() });
            return 1;
        }
        var n: u32 = 0;
        _ = ReadFile(h, buffer.ptr, 4096, &n, null);
        _ = CloseHandle(h);
    }
    return 0;
}

fn usage() u8 {
    print("usage: zigsaw-cfprobe mount|unregister|state|read|map|load|section|uncache|hydrate|revert ... (see tests/cfprobe.zig)\n", .{});
    return 2;
}

pub fn main(init: std.process.Init) !u8 {
    _ = QueryPerformanceFrequency(&counter_frequency);
    const gpa = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return usage();
    const command = args[1];
    const rest = args[2..];
    if (std.mem.eql(u8, command, "state")) return state(gpa, rest);
    if (std.mem.eql(u8, command, "read")) return read(gpa, rest);
    if (std.mem.eql(u8, command, "map")) return map(gpa, rest);
    if (std.mem.eql(u8, command, "load")) return load(gpa, rest);
    if (std.mem.eql(u8, command, "section")) return section(gpa, rest);
    if (std.mem.eql(u8, command, "uncache")) return uncache(gpa, rest);

    try loadApi();
    if (std.mem.eql(u8, command, "mount")) return mount(gpa, init.io, rest);
    if (std.mem.eql(u8, command, "hydrate")) return overTree(gpa, init.io, "hydrate", hydrateOne, rest);
    if (std.mem.eql(u8, command, "revert")) return overTree(gpa, init.io, "revert", revertOne, rest);
    if (std.mem.eql(u8, command, "unregister")) {
        if (rest.len != 1) return usage();
        try hresult("CfUnregisterSyncRoot", api.CfUnregisterSyncRoot(try toWide(gpa, rest[0])));
        return 0;
    }
    return usage();
}
