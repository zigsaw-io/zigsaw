//! Hand-written bindings for the Win32 APIs zigsaw needs.
//!
//! `std.os.windows` only covers what the standard library itself uses, so the
//! process, job, AppContainer, and ACL APIs are declared here. Types are kept
//! plain (c_int BOOL, u32 DWORD) to stay independent of std's internal churn.

const std = @import("std");

pub const BOOL = c_int;
pub const DWORD = u32;
pub const WORD = u16;
pub const HRESULT = i32;
pub const HANDLE = *anyopaque;
pub const PSID = *anyopaque;
pub const LPCWSTR = [*:0]const u16;
pub const LPWSTR = [*:0]u16;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const INFINITE: DWORD = 0xFFFFFFFF;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

pub const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
pub const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
pub const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));
pub const HANDLE_FLAG_INHERIT: DWORD = 0x1;

pub const CTRL_C_EVENT: DWORD = 0;
pub const CTRL_BREAK_EVENT: DWORD = 1;

// ---------------------------------------------------------------------------
// Processes

pub const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x00000400;
pub const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
pub const STARTF_USESTDHANDLES: DWORD = 0x00000100;

pub const PROC_THREAD_ATTRIBUTE_HANDLE_LIST: usize = 0x00020002;
pub const PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES: usize = 0x00020009;
pub const PROC_THREAD_ATTRIBUTE_JOB_LIST: usize = 0x0002000D;

pub const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?LPWSTR = null,
    lpDesktop: ?LPWSTR = null,
    lpTitle: ?LPWSTR = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: WORD = 0,
    cbReserved2: WORD = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};

pub const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetStdHandle(which: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetHandleInformation(h: HANDLE, mask: DWORD, flags: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn LocalFree(mem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;
pub extern "kernel32" fn GetCommandLineW() callconv(.winapi) LPWSTR;
pub const GENERIC_READ: DWORD = 0x80000000;
pub const FILE_SHARE_READ: DWORD = 0x1;
pub const OPEN_EXISTING: DWORD = 3;
pub extern "kernel32" fn CreateFileW(
    name: LPCWSTR,
    access: DWORD,
    share: DWORD,
    security: ?*anyopaque,
    disposition: DWORD,
    flags: DWORD,
    template: ?HANDLE,
) callconv(.winapi) HANDLE;
pub extern "kernel32" fn WriteFile(file: HANDLE, buffer: [*]const u8, to_write: DWORD, written: ?*DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadFile(file: HANDLE, buffer: [*]u8, to_read: DWORD, read: ?*DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetModuleFileNameW(module: ?*anyopaque, file_name: [*]u16, size: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn SetEnvironmentVariableW(name: LPCWSTR, value: ?LPCWSTR) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (DWORD) callconv(.winapi) BOOL,
    add: BOOL,
) callconv(.winapi) BOOL;

pub const ENABLE_PROCESSED_INPUT: DWORD = 0x1;
pub const ENABLE_LINE_INPUT: DWORD = 0x2;
pub const ENABLE_ECHO_INPUT: DWORD = 0x4;
pub extern "kernel32" fn GetConsoleMode(console: HANDLE, mode: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleMode(console: HANDLE, mode: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadConsoleW(console: HANDLE, buffer: [*]u16, to_read: DWORD, read: *DWORD, control: ?*anyopaque) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreateProcessW(
    application_name: ?LPCWSTR,
    command_line: ?LPWSTR,
    process_attributes: ?*anyopaque,
    thread_attributes: ?*anyopaque,
    inherit_handles: BOOL,
    creation_flags: DWORD,
    environment: ?*const anyopaque,
    current_directory: ?LPCWSTR,
    startup_info: *STARTUPINFOW,
    process_information: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn InitializeProcThreadAttributeList(
    list: ?*anyopaque,
    attribute_count: DWORD,
    flags: DWORD,
    size: *usize,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn UpdateProcThreadAttribute(
    list: *anyopaque,
    flags: DWORD,
    attribute: usize,
    value: *const anyopaque,
    size: usize,
    previous_value: ?*anyopaque,
    return_size: ?*usize,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;

pub extern "kernel32" fn WaitForSingleObject(h: HANDLE, milliseconds: DWORD) callconv(.winapi) DWORD;
pub const WAIT_ABANDONED: DWORD = 0x80;
pub const WAIT_TIMEOUT: DWORD = 0x102;
pub extern "kernel32" fn CreateMutexW(attributes: ?*anyopaque, initial_owner: BOOL, name: ?LPCWSTR) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn ReleaseMutex(mutex: HANDLE) callconv(.winapi) BOOL;

// DOS devices: drive letters mapped to directories, as `subst` makes.
pub const DDD_RAW_TARGET_PATH: DWORD = 0x1;
pub const DDD_REMOVE_DEFINITION: DWORD = 0x2;
pub const DDD_EXACT_MATCH_ON_REMOVE: DWORD = 0x4;
pub const DDD_NO_BROADCAST_SYSTEM: DWORD = 0x8;
pub const ERROR_FILE_NOT_FOUND: DWORD = 2;
pub extern "kernel32" fn DefineDosDeviceW(flags: DWORD, device: LPCWSTR, target: ?LPCWSTR) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryDosDeviceW(device: ?LPCWSTR, target: [*]u16, max: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetExitCodeProcess(h: HANDLE, exit_code: *DWORD) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// Job objects

pub const JobObjectExtendedLimitInformation: c_int = 9;
pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x00002000;

pub const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64 = 0,
    PerJobUserTimeLimit: i64 = 0,
    LimitFlags: DWORD = 0,
    MinimumWorkingSetSize: usize = 0,
    MaximumWorkingSetSize: usize = 0,
    ActiveProcessLimit: DWORD = 0,
    Affinity: usize = 0,
    PriorityClass: DWORD = 0,
    SchedulingClass: DWORD = 0,
};

pub const IO_COUNTERS = extern struct {
    ReadOperationCount: u64 = 0,
    WriteOperationCount: u64 = 0,
    OtherOperationCount: u64 = 0,
    ReadTransferCount: u64 = 0,
    WriteTransferCount: u64 = 0,
    OtherTransferCount: u64 = 0,
};

pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION = .{},
    IoInfo: IO_COUNTERS = .{},
    ProcessMemoryLimit: usize = 0,
    JobMemoryLimit: usize = 0,
    PeakProcessMemoryUsed: usize = 0,
    PeakJobMemoryUsed: usize = 0,
};

pub extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?LPCWSTR) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn TerminateJobObject(job: HANDLE, exit_code: u32) callconv(.winapi) BOOL;
pub const JobObjectBasicAccountingInformation: c_int = 1;
pub const JOBOBJECT_BASIC_ACCOUNTING_INFORMATION = extern struct {
    TotalUserTime: i64 = 0,
    TotalKernelTime: i64 = 0,
    ThisPeriodTotalUserTime: i64 = 0,
    ThisPeriodTotalKernelTime: i64 = 0,
    TotalPageFaultCount: DWORD = 0,
    TotalProcesses: DWORD = 0,
    ActiveProcesses: DWORD = 0,
    TotalTerminatedProcesses: DWORD = 0,
};
pub extern "kernel32" fn QueryInformationJobObject(
    job: HANDLE,
    class: c_int,
    info: *anyopaque,
    length: DWORD,
    return_length: ?*DWORD,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn Sleep(milliseconds: DWORD) callconv(.winapi) void;
/// Removes an empty directory, or a directory link itself (not its target).
pub extern "kernel32" fn RemoveDirectoryW(path: LPCWSTR) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetInformationJobObject(
    job: HANDLE,
    class: c_int,
    info: *const anyopaque,
    length: DWORD,
) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// AppContainer

pub const SE_GROUP_ENABLED: DWORD = 0x00000004;
/// HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS)
pub const E_ALREADY_EXISTS: HRESULT = @bitCast(@as(u32, 0x800700B7));

pub const SID_AND_ATTRIBUTES = extern struct {
    Sid: PSID,
    Attributes: DWORD,
};

pub const SECURITY_CAPABILITIES = extern struct {
    AppContainerSid: PSID,
    Capabilities: ?[*]SID_AND_ATTRIBUTES,
    CapabilityCount: DWORD,
    Reserved: DWORD = 0,
};

pub extern "userenv" fn CreateAppContainerProfile(
    name: LPCWSTR,
    display_name: LPCWSTR,
    description: LPCWSTR,
    capabilities: ?[*]SID_AND_ATTRIBUTES,
    capability_count: DWORD,
    sid: *?PSID,
) callconv(.winapi) HRESULT;
pub extern "userenv" fn DeriveAppContainerSidFromAppContainerName(name: LPCWSTR, sid: *?PSID) callconv(.winapi) HRESULT;
pub extern "userenv" fn DeleteAppContainerProfile(name: LPCWSTR) callconv(.winapi) HRESULT;

// ---------------------------------------------------------------------------
// Security descriptors and ACLs

pub const SE_FILE_OBJECT: c_int = 1;
pub const DACL_SECURITY_INFORMATION: DWORD = 0x00000004;
pub const GRANT_ACCESS: c_int = 1;
pub const REVOKE_ACCESS: c_int = 4;
pub const SUB_CONTAINERS_AND_OBJECTS_INHERIT: DWORD = 0x3;
pub const NO_MULTIPLE_TRUSTEE: c_int = 0;
pub const TRUSTEE_IS_SID: c_int = 0;
pub const TRUSTEE_IS_UNKNOWN: c_int = 0;
pub const ACCESS_ALLOWED_ACE_TYPE: u8 = 0;

pub const FILE_ALL_ACCESS: DWORD = 0x001F01FF;
/// FILE_GENERIC_READ | FILE_GENERIC_EXECUTE
pub const FILE_GENERIC_READ_EXECUTE: DWORD = 0x001200A9;

pub const ACL = extern struct {
    AclRevision: u8,
    Sbz1: u8,
    AclSize: u16,
    AceCount: u16,
    Sbz2: u16,
};

pub const ACE_HEADER = extern struct {
    AceType: u8,
    AceFlags: u8,
    AceSize: u16,
};

pub const ACCESS_ALLOWED_ACE = extern struct {
    Header: ACE_HEADER,
    Mask: DWORD,
    SidStart: DWORD,
};

pub const TRUSTEE_W = extern struct {
    pMultipleTrustee: ?*TRUSTEE_W = null,
    MultipleTrusteeOperation: c_int = NO_MULTIPLE_TRUSTEE,
    TrusteeForm: c_int = TRUSTEE_IS_SID,
    TrusteeType: c_int = TRUSTEE_IS_UNKNOWN,
    ptstrName: ?*anyopaque,
};

pub const EXPLICIT_ACCESS_W = extern struct {
    grfAccessPermissions: DWORD,
    grfAccessMode: c_int,
    grfInheritance: DWORD,
    Trustee: TRUSTEE_W,
};

pub const DENY_ACCESS: c_int = 3;
pub const ACCESS_DENIED_ACE_TYPE: u8 = 1;
pub const INHERITED_ACE: u8 = 0x10;
/// FILE_WRITE_DATA | FILE_APPEND_DATA | FILE_WRITE_EA | FILE_DELETE_CHILD |
/// FILE_WRITE_ATTRIBUTES | DELETE: everything that changes a file or a directory's entries.
pub const FILE_MODIFY: DWORD = 0x00010156;

pub const TOKEN_QUERY: DWORD = 0x0008;
pub const TokenUser: c_int = 1;
pub const TOKEN_USER = extern struct {
    User: SID_AND_ATTRIBUTES,
};

pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
pub extern "advapi32" fn OpenProcessToken(process: HANDLE, access: DWORD, token: *?HANDLE) callconv(.winapi) BOOL;
pub extern "advapi32" fn GetTokenInformation(
    token: HANDLE,
    class: c_int,
    info: ?*anyopaque,
    length: DWORD,
    return_length: *DWORD,
) callconv(.winapi) BOOL;
pub extern "advapi32" fn DeleteAce(acl: *ACL, index: DWORD) callconv(.winapi) BOOL;

pub extern "advapi32" fn FreeSid(sid: PSID) callconv(.winapi) ?*anyopaque;
pub extern "advapi32" fn EqualSid(a: PSID, b: PSID) callconv(.winapi) BOOL;
pub extern "advapi32" fn ConvertStringSidToSidW(string_sid: LPCWSTR, sid: *?PSID) callconv(.winapi) BOOL;
pub extern "advapi32" fn GetAce(acl: *ACL, index: DWORD, ace: *?*anyopaque) callconv(.winapi) BOOL;
pub extern "advapi32" fn GetNamedSecurityInfoW(
    object_name: LPCWSTR,
    object_type: c_int,
    security_info: DWORD,
    owner: ?*?PSID,
    group: ?*?PSID,
    dacl: ?*?*ACL,
    sacl: ?*?*ACL,
    security_descriptor: *?*anyopaque,
) callconv(.winapi) DWORD;
pub extern "advapi32" fn SetNamedSecurityInfoW(
    object_name: LPCWSTR,
    object_type: c_int,
    security_info: DWORD,
    owner: ?PSID,
    group: ?PSID,
    dacl: ?*ACL,
    sacl: ?*ACL,
) callconv(.winapi) DWORD;
pub extern "advapi32" fn SetEntriesInAclW(
    count: u32,
    entries: [*]EXPLICIT_ACCESS_W,
    old_acl: ?*ACL,
    new_acl: *?*ACL,
) callconv(.winapi) DWORD;

// ---------------------------------------------------------------------------
// Credential Manager

pub const CRED_TYPE_GENERIC: DWORD = 1;
pub const CRED_PERSIST_LOCAL_MACHINE: DWORD = 2;
pub const CRED_MAX_CREDENTIAL_BLOB_SIZE: usize = 5 * 512;
pub const ERROR_NOT_FOUND: DWORD = 1168;

pub const FILETIME = extern struct {
    dwLowDateTime: DWORD = 0,
    dwHighDateTime: DWORD = 0,
};

pub const CREDENTIALW = extern struct {
    Flags: DWORD = 0,
    Type: DWORD,
    TargetName: LPWSTR,
    Comment: ?LPWSTR = null,
    LastWritten: FILETIME = .{},
    CredentialBlobSize: DWORD = 0,
    CredentialBlob: ?[*]u8 = null,
    Persist: DWORD = 0,
    AttributeCount: DWORD = 0,
    Attributes: ?*anyopaque = null,
    TargetAlias: ?LPWSTR = null,
    UserName: ?LPWSTR = null,
};

pub extern "advapi32" fn CredReadW(target: LPCWSTR, type: DWORD, flags: DWORD, credential: *?*CREDENTIALW) callconv(.winapi) BOOL;
pub extern "advapi32" fn CredWriteW(credential: *const CREDENTIALW, flags: DWORD) callconv(.winapi) BOOL;
pub extern "advapi32" fn CredDeleteW(target: LPCWSTR, type: DWORD, flags: DWORD) callconv(.winapi) BOOL;
pub extern "advapi32" fn CredFree(buffer: ?*anyopaque) callconv(.winapi) void;

// ---------------------------------------------------------------------------
// Helpers

/// Converts a WTF-8 string (what Zig uses for Windows paths) to a
/// null-terminated UTF-16 string.
pub fn wide(gpa: std.mem.Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(gpa, s);
}

/// The full path of the running executable, as WTF-8.
pub fn selfExePath(gpa: std.mem.Allocator) ![]u8 {
    var buf: [32 * 1024]u16 = undefined;
    const len = GetModuleFileNameW(null, &buf, buf.len);
    if (len == 0 or len >= buf.len) return lastErrorFail("GetModuleFileNameW");
    return std.unicode.wtf16LeToWtf8Alloc(gpa, buf[0..len]);
}

/// Logs the calling thread's last Win32 error and returns `error.Failed`
/// (see `Context.fail`).
pub fn lastErrorFail(what: []const u8) error{Failed} {
    const code = GetLastError();
    return @import("Context.zig").fail("{s} failed: error {d} ({s})", .{ what, code, errorName(code) });
}

/// Formats a Win32 error code with its symbolic name when std knows it.
pub fn errorName(code: DWORD) []const u8 {
    const E = std.os.windows.Win32Error;
    return std.enums.tagName(E, @enumFromInt(code)) orelse "unknown";
}
