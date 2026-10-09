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

/// The child gets no console, rather than ours or a new one.
pub const DETACHED_PROCESS: DWORD = 0x00000008;
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
pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD = @sizeOf(SECURITY_ATTRIBUTES),
    lpSecurityDescriptor: ?*anyopaque = null,
    bInheritHandle: BOOL = FALSE,
};
pub extern "kernel32" fn CreatePipe(read: *HANDLE, write: *HANDLE, attributes: ?*const SECURITY_ATTRIBUTES, size: DWORD) callconv(.winapi) BOOL;
pub const ERROR_BROKEN_PIPE: DWORD = 109;
pub const FILE_TYPE_UNKNOWN: DWORD = 0;
pub const FILE_TYPE_DISK: DWORD = 1;
pub const FILE_TYPE_CHAR: DWORD = 2;
pub const FILE_TYPE_PIPE: DWORD = 3;
pub extern "kernel32" fn GetFileType(file: HANDLE) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetEnvironmentVariableW(name: LPCWSTR, buffer: ?[*]u16, size: DWORD) callconv(.winapi) DWORD;
pub const CREATE_ALWAYS: DWORD = 2;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const MB_OK: c_uint = 0x0;
pub const MB_ICONERROR: c_uint = 0x10;
pub extern "user32" fn MessageBoxW(window: ?HANDLE, text: LPCWSTR, caption: LPCWSTR, kind: c_uint) callconv(.winapi) c_int;
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
/// CreateProcessW with another token: a copy of ours, here, which needs no
/// privileges.
pub extern "advapi32" fn CreateProcessAsUserW(
    token: HANDLE,
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
/// The capability SIDs for a capability name, as S-1-15-3-1024-..., and the
/// group SIDs Windows also derives from it. The arrays and SIDs are LocalAlloc'd.
pub extern "api-ms-win-security-base-l1-2-2" fn DeriveCapabilitySidsFromName(
    name: LPCWSTR,
    group_sids: *?[*]PSID,
    group_sid_count: *DWORD,
    sids: *?[*]PSID,
    sid_count: *DWORD,
) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// Integrity levels

pub const TOKEN_ASSIGN_PRIMARY: DWORD = 0x0001;
pub const TOKEN_DUPLICATE: DWORD = 0x0002;
pub const TOKEN_ADJUST_DEFAULT: DWORD = 0x0080;
pub const TokenIntegrityLevel: c_int = 25;
pub const TokenIsAppContainer: c_int = 29;
pub const SecurityImpersonation: c_int = 2;
pub const TokenPrimary: c_int = 1;
pub const SE_GROUP_INTEGRITY: DWORD = 0x00000020;
/// The low integrity level's SID, and the RID that ends it.
pub const low_integrity_sid = "S-1-16-4096";
pub const SECURITY_MANDATORY_LOW_RID: DWORD = 0x1000;

pub const TOKEN_MANDATORY_LABEL = extern struct {
    Label: SID_AND_ATTRIBUTES,
};

pub const LABEL_SECURITY_INFORMATION: DWORD = 0x00000010;
pub const SYSTEM_MANDATORY_LABEL_ACE_TYPE: u8 = 0x11;
pub const SYSTEM_MANDATORY_LABEL_NO_WRITE_UP: DWORD = 0x1;
pub const OBJECT_INHERIT_ACE: u8 = 0x1;
pub const CONTAINER_INHERIT_ACE: u8 = 0x2;
pub const ACL_REVISION: DWORD = 2;

pub extern "advapi32" fn DuplicateTokenEx(
    existing: HANDLE,
    access: DWORD,
    attributes: ?*anyopaque,
    impersonation_level: c_int,
    token_type: c_int,
    new_token: *?HANDLE,
) callconv(.winapi) BOOL;
pub extern "advapi32" fn SetTokenInformation(token: HANDLE, class: c_int, info: *const anyopaque, length: DWORD) callconv(.winapi) BOOL;
pub extern "advapi32" fn InitializeAcl(acl: *ACL, length: DWORD, revision: DWORD) callconv(.winapi) BOOL;
pub extern "advapi32" fn AddMandatoryAce(acl: *ACL, revision: DWORD, flags: DWORD, policy: DWORD, label: PSID) callconv(.winapi) BOOL;

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
pub const WRITE_OWNER: DWORD = 0x00080000;
pub const ERROR_ACCESS_DENIED: DWORD = 5;

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
pub extern "advapi32" fn GetLengthSid(sid: PSID) callconv(.winapi) DWORD;
pub const SID_IDENTIFIER_AUTHORITY = extern struct {
    Value: [6]u8,
};
pub extern "advapi32" fn GetSidIdentifierAuthority(sid: PSID) callconv(.winapi) *SID_IDENTIFIER_AUTHORITY;
pub extern "advapi32" fn GetSidSubAuthorityCount(sid: PSID) callconv(.winapi) *u8;
pub extern "advapi32" fn GetSidSubAuthority(sid: PSID, index: DWORD) callconv(.winapi) *DWORD;
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
pub const SE_KERNEL_OBJECT: c_int = 6;
/// The medium integrity level's SID, every process's of a standard user.
pub const medium_integrity_sid = "S-1-16-8192";
pub extern "advapi32" fn SetSecurityInfo(
    handle: HANDLE,
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
// COM and the shell: shortcuts (.lnk files) and known folders

pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;
pub const COINIT_APARTMENTTHREADED: DWORD = 0x2;
pub const CLSCTX_INPROC_SERVER: DWORD = 0x1;
pub const STGM_READ: DWORD = 0x0;
/// IShellLinkW.GetPath: the path as stored, without expanding variables.
pub const SLGP_RAWPATH: DWORD = 0x4;
pub const MAX_PATH = 260;
pub const INFOTIPSIZE = 1024;

pub const CLSID_ShellLink: GUID = .{ .Data1 = 0x00021401, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
pub const IID_IShellLinkW: GUID = .{ .Data1 = 0x000214F9, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
pub const IID_IPersistFile: GUID = .{ .Data1 = 0x0000010B, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
/// The user's Start menu Programs folder.
pub const FOLDERID_Programs: GUID = .{ .Data1 = 0xA77F5D77, .Data2 = 0x2E2B, .Data3 = 0x44C3, .Data4 = .{ 0xA6, 0xA2, 0xAB, 0xA6, 0x01, 0x05, 0x4A, 0x51 } };

/// IShellLinkW's methods, in vtable order. Only those zigsaw calls are typed.
pub const IShellLinkW = extern struct {
    vtable: *const extern struct {
        QueryInterface: *const fn (*IShellLinkW, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IShellLinkW) callconv(.winapi) u32,
        Release: *const fn (*IShellLinkW) callconv(.winapi) u32,
        GetPath: *const fn (*IShellLinkW, [*]u16, c_int, ?*anyopaque, DWORD) callconv(.winapi) HRESULT,
        GetIDList: *const anyopaque,
        SetIDList: *const anyopaque,
        GetDescription: *const anyopaque,
        SetDescription: *const fn (*IShellLinkW, LPCWSTR) callconv(.winapi) HRESULT,
        GetWorkingDirectory: *const anyopaque,
        SetWorkingDirectory: *const fn (*IShellLinkW, LPCWSTR) callconv(.winapi) HRESULT,
        GetArguments: *const anyopaque,
        SetArguments: *const anyopaque,
        GetHotkey: *const anyopaque,
        SetHotkey: *const anyopaque,
        GetShowCmd: *const anyopaque,
        SetShowCmd: *const anyopaque,
        GetIconLocation: *const anyopaque,
        SetIconLocation: *const fn (*IShellLinkW, LPCWSTR, c_int) callconv(.winapi) HRESULT,
        SetRelativePath: *const anyopaque,
        Resolve: *const anyopaque,
        SetPath: *const fn (*IShellLinkW, LPCWSTR) callconv(.winapi) HRESULT,
    },
};

/// IPersistFile's methods, in vtable order.
pub const IPersistFile = extern struct {
    vtable: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IPersistFile) callconv(.winapi) u32,
        GetClassID: *const anyopaque,
        IsDirty: *const anyopaque,
        Load: *const fn (*IPersistFile, LPCWSTR, DWORD) callconv(.winapi) HRESULT,
        Save: *const fn (*IPersistFile, ?LPCWSTR, BOOL) callconv(.winapi) HRESULT,
        SaveCompleted: *const anyopaque,
        GetCurFile: *const anyopaque,
    },
};

pub extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: DWORD) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
pub extern "ole32" fn CoCreateInstance(clsid: *const GUID, outer: ?*anyopaque, context: DWORD, iid: *const GUID, object: *?*anyopaque) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoTaskMemFree(mem: ?*anyopaque) callconv(.winapi) void;
pub extern "shell32" fn SHGetKnownFolderPath(id: *const GUID, flags: DWORD, token: ?HANDLE, path: *?LPWSTR) callconv(.winapi) HRESULT;

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
