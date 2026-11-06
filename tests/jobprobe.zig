//! Job objects, for tests/lazy.sh: whether a process can start one outside
//! its job, and a job that lets nothing out, as some terminals' do. Built by
//! `zig build jobprobe`.
//!
//!   zigsaw-jobprobe breakaway
//!       starts itself with CREATE_BREAKAWAY_FROM_JOB and says what happened:
//!       "refused" (Windows said no: the job keeps what it starts), "left" (the
//!       child is in no job), or "kept" (it's in one still); exit 0
//!   zigsaw-jobprobe injob <command line>
//!       runs the command in a new job that ends its processes when it's
//!       closed and lets none break away, waits for it, and exits with its
//!       code once the job's gone

const std = @import("std");

const HANDLE = *anyopaque;
const BOOL = c_int;

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
const BasicLimits = extern struct {
    per_process_user_time: i64 = 0,
    per_job_user_time: i64 = 0,
    flags: u32 = 0,
    min_ws: usize = 0,
    max_ws: usize = 0,
    active_processes: u32 = 0,
    affinity: usize = 0,
    priority: u32 = 0,
    scheduling: u32 = 0,
};
const ExtendedLimits = extern struct {
    basic: BasicLimits = .{},
    io: [6]u64 = @splat(0),
    process_memory: usize = 0,
    job_memory: usize = 0,
    peak_process_memory: usize = 0,
    peak_job_memory: usize = 0,
};

extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]u16;
extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmdline: [*:0]u16, pa: ?*anyopaque, ta: ?*anyopaque, inherit: BOOL, flags: u32, env: ?*anyopaque, cwd: ?[*:0]const u16, si: *StartupInfo, pi: *ProcessInformation) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(process: HANDLE, code: *u32) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn IsProcessInJob(process: HANDLE, job: ?HANDLE, result: *BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn CreateJobObjectW(attrs: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetInformationJobObject(job: HANDLE, class: c_int, info: *const anyopaque, len: u32) callconv(.winapi) BOOL;
extern "kernel32" fn AssignProcessToJobObject(job: HANDLE, process: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ResumeThread(thread: HANDLE) callconv(.winapi) u32;
extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;

const CREATE_SUSPENDED: u32 = 0x4;
const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x01000000;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x2000;
const INFINITE: u32 = 0xFFFFFFFF;

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, text) catch {};
}

/// The command line after the first `skip` arguments, as it was given.
fn rest(line: []const u16, skip: usize) []const u16 {
    var i: usize = 0;
    var left = skip;
    while (left > 0) : (left -= 1) {
        while (i < line.len and line[i] == ' ') i += 1;
        var quoted = false;
        while (i < line.len and (quoted or line[i] != ' ')) : (i += 1) {
            if (line[i] == '"') quoted = !quoted;
        }
    }
    while (i < line.len and line[i] == ' ') i += 1;
    return line[i..];
}

fn start(line: []const u16, flags: u32) ?ProcessInformation {
    var buf: [4096]u16 = undefined;
    if (line.len + 1 > buf.len) return null;
    @memcpy(buf[0..line.len], line);
    buf[line.len] = 0;
    var si: StartupInfo = .{};
    var pi: ProcessInformation = undefined;
    if (CreateProcessW(null, buf[0..line.len :0].ptr, null, null, 1, flags, null, null, &si, &pi) == 0) return null;
    return pi;
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return 2;
    const line = std.mem.sliceTo(GetCommandLineW(), 0);
    if (std.mem.eql(u8, args[1], "breakaway-child")) {
        var in_job: BOOL = 0;
        _ = IsProcessInJob(GetCurrentProcess(), null, &in_job);
        print("{s}\n", .{if (in_job != 0) "kept" else "left"});
        return 0;
    }
    if (std.mem.eql(u8, args[1], "breakaway")) {
        // Ourselves again, by the path we were started by.
        const exe = line[0 .. line.len - rest(line, 1).len];
        var child_line: [1024]u16 = undefined;
        const suffix = std.unicode.utf8ToUtf16LeStringLiteral("breakaway-child");
        if (exe.len + suffix.len > child_line.len) return 2;
        @memcpy(child_line[0..exe.len], exe);
        @memcpy(child_line[exe.len..][0..suffix.len], suffix);
        const pi = start(child_line[0 .. exe.len + suffix.len], CREATE_BREAKAWAY_FROM_JOB) orelse {
            print("refused (error {d})\n", .{GetLastError()});
            return 0;
        };
        _ = WaitForSingleObject(pi.process, INFINITE);
        _ = CloseHandle(pi.thread);
        _ = CloseHandle(pi.process);
        return 0;
    }
    if (std.mem.eql(u8, args[1], "injob")) {
        const job = CreateJobObjectW(null, null) orelse return 125;
        var limits: ExtendedLimits = .{};
        limits.basic.flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (SetInformationJobObject(job, 9, &limits, @sizeOf(ExtendedLimits)) == 0) return 125;
        const pi = start(rest(line, 2), CREATE_SUSPENDED) orelse return 125;
        if (AssignProcessToJobObject(job, pi.process) == 0) return 125;
        _ = ResumeThread(pi.thread);
        _ = WaitForSingleObject(pi.process, INFINITE);
        var code: u32 = 1;
        _ = GetExitCodeProcess(pi.process, &code);
        // Closing the job ends what's left in it, as such a terminal's would.
        _ = CloseHandle(job);
        ExitProcess(code);
    }
    return 2;
}
