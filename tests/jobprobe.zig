//! Job objects, for tests/lazy.sh: whether a process can start one outside
//! its job, and a job that lets nothing out, as some terminals' do. Built by
//! `zig build jobprobe`.
//!
//!   zigsaw-jobprobe breakaway
//!       starts itself with CREATE_BREAKAWAY_FROM_JOB and says what happened:
//!       "refused" (Windows said no: the job keeps what it starts), "left" (the
//!       child is in no job), or "kept" (it's in one still); exit 0
//!   zigsaw-jobprobe injob [--memory=<MiB>] [--cpus=<n>] [--rate=<n>] [--report] <command line>
//!       runs the command in a new job that ends its processes when it's
//!       closed and lets none break away, waits for it, and exits with its
//!       code once the job's gone. --memory caps the job's committed memory,
//!       --cpus gives it the first n of this process's processors, --rate
//!       caps its CPU time at n processors' worth of the machine's; one that
//!       Windows refuses says so and exits 125. --report says afterwards, on
//!       stderr, the job's peak memory and what the job told its port
//!   zigsaw-jobprobe cpus
//!       says how many processors this process counts, each way a program
//!       may: "affinity=<n> system=<n> active=<n> rate=<none|n/10000>"
//!   zigsaw-jobprobe alloc <MiB> [<command line>]
//!       commits and writes that much memory, 16 MiB at a time, says how far
//!       it got, and exits 1 if Windows refused some; else runs the command,
//!       if there's one, still holding the memory, and exits with its code

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
extern "kernel32" fn GetProcessAffinityMask(process: HANDLE, own: *usize, system: *usize) callconv(.winapi) BOOL;
extern "kernel32" fn GetSystemInfo(info: *SystemInfo) callconv(.winapi) void;
extern "kernel32" fn GetActiveProcessorCount(group: u16) callconv(.winapi) u32;
extern "kernel32" fn QueryInformationJobObject(job: ?HANDLE, class: c_int, info: *anyopaque, len: u32, ret: ?*u32) callconv(.winapi) BOOL;
extern "kernel32" fn VirtualAlloc(address: ?*anyopaque, size: usize, kind: u32, protect: u32) callconv(.winapi) ?[*]u8;
extern "kernel32" fn CreateIoCompletionPort(file: HANDLE, existing: ?HANDLE, key: usize, threads: u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetQueuedCompletionStatus(port: HANDLE, bytes: *u32, key: *usize, overlapped: *?*anyopaque, ms: u32) callconv(.winapi) BOOL;

const SystemInfo = extern struct {
    arch: u16 = 0,
    reserved: u16 = 0,
    page_size: u32 = 0,
    min_address: ?*anyopaque = null,
    max_address: ?*anyopaque = null,
    active_mask: usize = 0,
    processors: u32 = 0,
    processor_type: u32 = 0,
    granularity: u32 = 0,
    level: u16 = 0,
    revision: u16 = 0,
};
const CpuRate = extern struct { flags: u32 = 0, rate: u32 = 0 };
const PortOfJob = extern struct { key: ?*anyopaque, port: HANDLE };

const CREATE_SUSPENDED: u32 = 0x4;
const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x01000000;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x2000;
const JOB_OBJECT_LIMIT_AFFINITY: u32 = 0x10;
const JOB_OBJECT_LIMIT_JOB_MEMORY: u32 = 0x200;
const JobObjectAssociateCompletionPortInformation: c_int = 7;
const JobObjectCpuRateControlInformation: c_int = 15;
const JOB_OBJECT_CPU_RATE_CONTROL_ENABLE: u32 = 0x1;
const JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP: u32 = 0x4;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
const INFINITE: u32 = 0xFFFFFFFF;

/// The lowest `n` set bits of `mask`.
fn firstBits(mask: usize, n: u32) usize {
    var out: usize = 0;
    var left = n;
    var bit: usize = 1;
    while (left > 0 and bit != 0) : (bit <<= 1) {
        if (mask & bit != 0) {
            out |= bit;
            left -= 1;
        }
    }
    return out;
}

fn refused(what: []const u8) u8 {
    print("refused: {s} (error {d})\n", .{ what, GetLastError() });
    return 125;
}

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
    if (std.mem.eql(u8, args[1], "cpus")) {
        var own: usize = 0;
        var system: usize = 0;
        _ = GetProcessAffinityMask(GetCurrentProcess(), &own, &system);
        var info: SystemInfo = .{};
        GetSystemInfo(&info);
        var rate: CpuRate = .{};
        const capped = QueryInformationJobObject(null, JobObjectCpuRateControlInformation, &rate, @sizeOf(CpuRate), null) != 0 and
            rate.flags & JOB_OBJECT_CPU_RATE_CONTROL_ENABLE != 0 and rate.flags & JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP != 0;
        var rate_buf: [32]u8 = undefined;
        print("affinity={d} system={d} active={d} rate={s}\n", .{
            @popCount(own),
            info.processors,
            GetActiveProcessorCount(0xffff),
            if (capped) std.fmt.bufPrint(&rate_buf, "{d}/10000", .{rate.rate}) catch "?" else "none",
        });
        return 0;
    }
    if (std.mem.eql(u8, args[1], "alloc")) {
        if (args.len < 3) return 2;
        const want = std.fmt.parseInt(usize, args[2], 10) catch return 2;
        const step = 16;
        var got: usize = 0;
        while (got < want) {
            const mib: usize = @min(step, want - got);
            const p = VirtualAlloc(null, mib << 20, 0x3000, 0x4) orelse {
                print("failed at {d} of {d} MiB (error {d})\n", .{ got, want, GetLastError() });
                return 1;
            };
            // Committed is what a job counts; written, so it's real too.
            var at: usize = 0;
            while (at < mib << 20) : (at += 4096) p[at] = 1;
            got += mib;
        }
        print("allocated {d} MiB\n", .{got});
        const then = rest(line, 3);
        if (then.len == 0) return 0;
        const pi = start(then, 0) orelse return refused("CreateProcessW");
        _ = WaitForSingleObject(pi.process, INFINITE);
        var code: u32 = 1;
        _ = GetExitCodeProcess(pi.process, &code);
        ExitProcess(code);
    }
    if (std.mem.eql(u8, args[1], "injob")) {
        var memory: ?usize = null;
        var cpus: ?u32 = null;
        var cpu_rate: ?u32 = null;
        var report = false;
        var skip: usize = 2;
        while (skip < args.len and std.mem.startsWith(u8, args[skip], "--")) : (skip += 1) {
            const arg = args[skip];
            if (std.mem.startsWith(u8, arg, "--memory=")) {
                memory = std.fmt.parseInt(usize, arg["--memory=".len..], 10) catch return 2;
            } else if (std.mem.startsWith(u8, arg, "--cpus=")) {
                cpus = std.fmt.parseInt(u32, arg["--cpus=".len..], 10) catch return 2;
            } else if (std.mem.startsWith(u8, arg, "--rate=")) {
                cpu_rate = std.fmt.parseInt(u32, arg["--rate=".len..], 10) catch return 2;
            } else if (std.mem.eql(u8, arg, "--report")) {
                report = true;
            } else return 2;
        }
        const job = CreateJobObjectW(null, null) orelse return 125;
        var limits: ExtendedLimits = .{};
        limits.basic.flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (memory) |mib| {
            limits.basic.flags |= JOB_OBJECT_LIMIT_JOB_MEMORY;
            limits.job_memory = mib << 20;
        }
        if (cpus) |n| {
            var own: usize = 0;
            var system: usize = 0;
            if (GetProcessAffinityMask(GetCurrentProcess(), &own, &system) == 0) return refused("GetProcessAffinityMask");
            limits.basic.flags |= JOB_OBJECT_LIMIT_AFFINITY;
            limits.basic.affinity = firstBits(own, n);
        }
        if (SetInformationJobObject(job, 9, &limits, @sizeOf(ExtendedLimits)) == 0) return refused("the job's limits");
        if (cpu_rate) |n| {
            const all = GetActiveProcessorCount(0xffff);
            const rate: CpuRate = .{
                .flags = JOB_OBJECT_CPU_RATE_CONTROL_ENABLE | JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP,
                .rate = @max(1, @min(10000, n * 10000 / all)),
            };
            if (SetInformationJobObject(job, JobObjectCpuRateControlInformation, &rate, @sizeOf(CpuRate)) == 0) return refused("the job's CPU rate");
        }
        var port: ?HANDLE = null;
        if (report) {
            port = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 1) orelse return refused("CreateIoCompletionPort");
            const of_job: PortOfJob = .{ .key = null, .port = port.? };
            if (SetInformationJobObject(job, JobObjectAssociateCompletionPortInformation, &of_job, @sizeOf(PortOfJob)) == 0) return refused("the job's port");
        }
        const pi = start(rest(line, skip), CREATE_SUSPENDED) orelse return refused("CreateProcessW");
        if (AssignProcessToJobObject(job, pi.process) == 0) return refused("AssignProcessToJobObject");
        _ = ResumeThread(pi.thread);
        _ = WaitForSingleObject(pi.process, INFINITE);
        var code: u32 = 1;
        _ = GetExitCodeProcess(pi.process, &code);
        if (report) {
            var after: ExtendedLimits = .{};
            _ = QueryInformationJobObject(job, 9, &after, @sizeOf(ExtendedLimits), null);
            var said: [64]u8 = undefined;
            var w: std.Io.Writer = .fixed(&said);
            while (true) {
                var message: u32 = 0;
                var key: usize = 0;
                var overlapped: ?*anyopaque = null;
                if (GetQueuedCompletionStatus(port.?, &message, &key, &overlapped, 0) == 0) break;
                w.print(" {d}", .{message}) catch break;
            }
            var buf: [160]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "job: peak={d}MiB messages={s}\n", .{ after.peak_job_memory >> 20, if (w.end == 0) " none" else w.buffered() }) catch "";
            std.Io.File.stderr().writeStreamingAll(std.Options.debug_io, text) catch {};
        }
        // Closing the job ends what's left in it, as such a terminal's would.
        _ = CloseHandle(job);
        ExitProcess(code);
    }
    return 2;
}
