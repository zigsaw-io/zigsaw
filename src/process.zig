//! Starting processes: command-line quoting, and running a child inside a
//! job object while forwarding stdio, Ctrl+C and the exit code.

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");

/// Quotes arguments the way the Microsoft C runtime (and CommandLineToArgvW)
/// parses them back.
pub fn buildCommandLine(arena: Allocator, exe: []const u8, args: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendQuoted(arena, &out, exe);
    for (args) |arg| {
        try out.append(arena, ' ');
        try appendQuoted(arena, &out, arg);
    }
    return out.items;
}

pub fn appendQuoted(arena: Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
    if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\n\x0b\"") == null) {
        return out.appendSlice(arena, arg);
    }
    try out.append(arena, '"');
    var backslashes: usize = 0;
    for (arg) |c| {
        switch (c) {
            '\\' => backslashes += 1,
            '"' => {
                // Backslashes before a quote are escapes, and so is the quote.
                try out.appendNTimes(arena, '\\', backslashes * 2 + 1);
                try out.append(arena, '"');
                backslashes = 0;
            },
            else => {
                try out.appendNTimes(arena, '\\', backslashes);
                try out.append(arena, c);
                backslashes = 0;
            },
        }
    }
    // Backslashes before the closing quote must be doubled.
    try out.appendNTimes(arena, '\\', backslashes * 2);
    try out.append(arena, '"');
}

/// Builds a command line that runs a batch file through `cmd_exe`, such that
/// the batch file's %1, %2... and %* get the arguments exactly as given, and
/// no argument can make cmd.exe run anything else. Modelled on Rust's fix for
/// CVE-2024-24576 ("BatBadBut"):
///
///   "<cmd.exe>" /d /e:ON /v:OFF /c ""<script>" args..."
///
/// /d skips the user's AutoRun commands, /v:OFF keeps `!var!` literal, and
/// /e:ON enables the substring syntax that escaping `%` relies on. cmd.exe
/// strips the outer pair of quotes after /c and runs the rest.
pub fn buildBatchCommandLine(
    arena: Allocator,
    cmd_exe: []const u8,
    script: []const u8,
    args: []const []const u8,
) error{ OutOfMemory, InvalidBatchScript, InvalidBatchArgument }![]u8 {
    // Windows file names can't contain '"' or end in '\'.
    if (script.len == 0 or std.mem.indexOfScalar(u8, script, '"') != null or script[script.len - 1] == '\\')
        return error.InvalidBatchScript;
    var out: std.ArrayList(u8) = .empty;
    try appendQuoted(arena, &out, cmd_exe);
    try out.appendSlice(arena, " /d /e:ON /v:OFF /c \"\"");
    for (script) |c| try appendBatchChar(arena, &out, c);
    try out.append(arena, '"');
    for (args) |arg| {
        try out.append(arena, ' ');
        try appendBatchArg(arena, &out, arg);
    }
    try out.append(arena, '"');
    return out.items;
}

fn appendBatchArg(arena: Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
    // A line break ends the command, whatever the quoting.
    if (std.mem.indexOfAny(u8, arg, "\r\n\x00") != null) return error.InvalidBatchArgument;
    // An argument ending in '\' is quoted too, or a batch file's "%~1" would
    // put its own closing quote after an escaping backslash.
    const quote = arg.len == 0 or arg[arg.len - 1] == '\\' or needsBatchQuotes(arg);
    if (quote) try out.append(arena, '"');
    var backslashes: usize = 0;
    for (arg) |c| {
        if (c == '\\') {
            backslashes += 1;
        } else {
            // Inside quotes, '"' becomes '""', which leaves cmd.exe's quoting
            // as it was and which programs read as one quote; the
            // backslashes before it are doubled, as they are for programs.
            if (c == '"') try out.appendNTimes(arena, '\\', backslashes);
            backslashes = 0;
        }
        try appendBatchChar(arena, out, c);
    }
    if (quote) {
        try out.appendNTimes(arena, '\\', backslashes);
        try out.append(arena, '"');
    }
}

/// Appends `c`, doubling '"' and escaping '%'. cmd.exe expands %VAR% even
/// inside quotes, so each '%' becomes "%%cd:~,%": cmd.exe keeps the first '%',
/// and the rest is an empty substring of %cd%, which leaves no '%' to pair
/// with a later one.
fn appendBatchChar(arena: Allocator, out: *std.ArrayList(u8), c: u8) !void {
    switch (c) {
        '"' => try out.appendSlice(arena, "\"\""),
        '%' => try out.appendSlice(arena, "%%cd:~,%"),
        else => try out.append(arena, c),
    }
}

/// Rather than list what cmd.exe treats specially, quote every argument with
/// an ASCII character outside a known-safe set, or a control character.
fn needsBatchQuotes(arg: []const u8) bool {
    for (arg, 0..) |c, i| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '#', '$', '*', '+', '-', '.', '/', ':', '?', '@', '\\', '_' => {},
        // U+0080 to U+009F, the C1 control characters, are C2 80 to C2 9F.
        0x80...0xff => if (c == 0xc2 and i + 1 < arg.len and arg[i + 1] <= 0x9f) return true,
        else => return true,
    };
    return false;
}

pub const SpawnSpec = struct {
    exe: []const u8,
    /// WTF-8; see `buildCommandLine`.
    command_line: []const u8,
    /// UTF-16 "NAME=VALUE", each null-terminated, then a final null; null inherits ours.
    env_block: ?[]const u16 = null,
    /// Null inherits ours.
    cwd: ?[]const u8 = null,
    security: ?*const win32.SECURITY_CAPABILITIES = null,
    /// The child's token, such as `lowIntegrityToken`'s; null gives it ours.
    token: ?win32.HANDLE = null,
    /// More CreateProcess flags, such as DETACHED_PROCESS.
    creation_flags: win32.DWORD = 0,
    /// Let the child start processes outside its job (see `newJobAllowing`).
    breakaway_ok: bool = false,
    /// What the child and everything it starts may use together.
    limits: Limits = .{},
    /// The child's stdin, stdout and stderr; null hands it ours.
    stdio: ?[3]?win32.HANDLE = null,
    /// Handles the child inherits besides those, such as the relay's
    /// sockets (see services.zig).
    inherit: []const win32.HANDLE = &.{},
    /// The shortcut (.lnk) the child counts as started from, as a program
    /// Explorer starts from one does: Windows keeps it in the child's
    /// start-up information, where the shell can tell what started it.
    shortcut: ?[]const u8 = null,
};

/// A copy of zigsaw's token labelled low integrity, which a process can make
/// of its own without privileges. Processes with it can't write to anything
/// whose integrity label is higher (medium, by default), and can still read.
/// Left to be closed at process exit.
pub fn lowIntegrityToken(arena: Allocator) !win32.HANDLE {
    var own: ?win32.HANDLE = null;
    const access = win32.TOKEN_ASSIGN_PRIMARY | win32.TOKEN_DUPLICATE | win32.TOKEN_QUERY | win32.TOKEN_ADJUST_DEFAULT;
    if (win32.OpenProcessToken(win32.GetCurrentProcess(), access, &own) == 0) return win32.lastErrorFail("OpenProcessToken");
    defer _ = win32.CloseHandle(own.?);
    var low: ?win32.HANDLE = null;
    if (win32.DuplicateTokenEx(own.?, 0, null, win32.SecurityImpersonation, win32.TokenPrimary, &low) == 0)
        return win32.lastErrorFail("DuplicateTokenEx");
    var sid: ?win32.PSID = null;
    if (win32.ConvertStringSidToSidW(try win32.wide(arena, win32.low_integrity_sid), &sid) == 0)
        return win32.lastErrorFail("ConvertStringSidToSidW");
    const label: win32.TOKEN_MANDATORY_LABEL = .{ .Label = .{ .Sid = sid.?, .Attributes = win32.SE_GROUP_INTEGRITY } };
    if (win32.SetTokenInformation(low.?, win32.TokenIntegrityLevel, &label, @sizeOf(win32.TOKEN_MANDATORY_LABEL) + win32.GetLengthSid(sid.?)) == 0)
        return win32.lastErrorFail("SetTokenInformation");
    return low.?;
}

/// The variables this user's programs start with, as a block for
/// `SpawnSpec.env_block`, whatever this process's own are: what Windows
/// builds from the registry for a new sign-in, with their real profile.
pub fn userEnvironmentBlock(arena: Allocator) ![]const u16 {
    var token: ?win32.HANDLE = null;
    if (win32.OpenProcessToken(win32.GetCurrentProcess(), win32.TOKEN_QUERY, &token) == 0)
        return win32.lastErrorFail("OpenProcessToken");
    defer _ = win32.CloseHandle(token.?);
    var block: ?[*:0]u16 = null;
    if (win32.CreateEnvironmentBlock(&block, token, 0) == 0)
        return win32.lastErrorFail("CreateEnvironmentBlock");
    defer _ = win32.DestroyEnvironmentBlock(block.?);
    // It ends with an empty string: two nulls in a row.
    var len: usize = 0;
    while (block.?[len] != 0 or block.?[len + 1] != 0) len += 1;
    return arena.dupe(u16, block.?[0 .. len + 2]);
}

/// Runs a process to completion and returns its exit code. The child gets
/// our stdio handles (or `spec.stdio`) and nothing else, and runs in a job
/// object, so its whole process tree ends when it does, or when we do.
pub fn spawn(arena: Allocator, spec: SpawnSpec) !u32 {
    const child = try start(arena, spec);
    return child.wait();
}

/// What the processes of a job may use together. Windows asks no privilege
/// for either, and a job inside another gets the tighter of the two.
pub const Limits = struct {
    /// Bytes of memory they may commit. Past it, Windows refuses a process
    /// more, as it does when the page file is full ("The paging file is too
    /// small", error 1455), and the program does what it does then.
    memory: ?u64 = null,
    /// How many processors they run on (see `chooseProcessors`). As many as
    /// zigsaw has, or more, is no limit.
    cpus: ?u32 = null,

    /// The processors a job with these gets, if fewer than zigsaw has: for
    /// the variables that tell programs which don't ask Windows, or ask it
    /// for the machine's (see `job_count_vars`).
    pub fn fewerCpus(l: Limits) ?u32 {
        const n = l.cpus orelse return null;
        const own = ownCpus();
        return if (own != 0 and n < own) n else null;
    }
};

/// How many processors zigsaw itself may run on, which is the most a job of
/// its own can have; 0 if Windows doesn't say.
pub fn ownCpus() u32 {
    var own: usize = 0;
    var system: usize = 0;
    if (win32.GetProcessAffinityMask(win32.GetCurrentProcess(), &own, &system) == 0) return 0;
    return @popCount(own);
}

/// The variables a run or a build with fewer processors gets their number
/// in, unless it has them set already. Measured under a job with 4 of 16:
/// Go, Node and BusyBox's nproc count 4 by the affinity, and Ninja by the
/// CPU rate; Rust's `available_parallelism`, so cargo, zig, CMake and
/// Python count 16 whatever the job says.
pub const job_count_vars = [_][]const u8{ "NUMBER_OF_PROCESSORS", "CARGO_BUILD_JOBS" };

/// A job object, and the port that hears of its memory limit, if it has one.
pub const Job = struct {
    handle: win32.HANDLE,
    port: ?win32.HANDLE = null,
    memory_limit: ?u64 = null,
};

/// How a job's process tree ended.
pub const Report = struct {
    code: u32,
    /// The most memory its processes had committed together, in bytes; what
    /// one was refused counts, so a tree that reached its limit shows more.
    peak_memory: u64 = 0,
    /// The limit its processes asked for memory past, if they did.
    memory_limit_reached: ?u64 = null,
};

/// A process `start` started, in its job object.
pub const Child = struct {
    job: win32.HANDLE,
    process: win32.HANDLE,
    /// As `Job`'s.
    port: ?win32.HANDLE = null,
    memory_limit: ?u64 = null,

    pub fn in(job: Job, process: win32.HANDLE) Child {
        return .{ .job = job.handle, .process = process, .port = job.port, .memory_limit = job.memory_limit };
    }

    /// Waits for the process to exit, ends what's left of its tree, and
    /// returns its exit code.
    pub fn wait(child: Child) !u32 {
        return (try child.waitReport()).code;
    }

    /// As `wait`, also saying what the tree used.
    pub fn waitReport(child: Child) !Report {
        defer _ = win32.CloseHandle(child.job);
        defer _ = win32.CloseHandle(child.process);
        defer if (child.port) |p| {
            _ = win32.CloseHandle(p);
        };
        var told = false;
        if (child.port) |port| {
            // The job also tells its port of every process that starts and
            // ends, which a long build has many of: taken off as they come.
            while (true) {
                const waited = win32.WaitForSingleObject(child.process, 250);
                if (drain(port)) told = true;
                if (waited == win32.WAIT_OBJECT_0) break;
                if (waited != win32.WAIT_TIMEOUT) return win32.lastErrorFail("WaitForSingleObject");
            }
        } else if (win32.WaitForSingleObject(child.process, win32.INFINITE) != win32.WAIT_OBJECT_0)
            return win32.lastErrorFail("WaitForSingleObject");
        var code: win32.DWORD = 0;
        if (win32.GetExitCodeProcess(child.process, &code) == 0)
            return win32.lastErrorFail("GetExitCodeProcess");
        endJob(child.job);
        if (child.port) |port| {
            if (drain(port)) told = true;
        }
        var report: Report = .{ .code = code };
        var info: win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};
        if (win32.QueryInformationJobObject(child.job, win32.JobObjectExtendedLimitInformation, &info, @sizeOf(@TypeOf(info)), null) != 0)
            report.peak_memory = info.PeakJobMemoryUsed;
        // Windows doesn't promise the port every message; the peak, which
        // counts what was refused, says it too.
        if (child.memory_limit) |limit| {
            if (told or report.peak_memory >= limit) report.memory_limit_reached = limit;
        }
        return report;
    }

    /// As `wait`, for at most `ms`: then ends the process tree, and
    /// returns null.
    pub fn waitFor(child: Child, ms: win32.DWORD) !?u32 {
        switch (win32.WaitForSingleObject(child.process, ms)) {
            win32.WAIT_OBJECT_0 => return try child.wait(),
            win32.WAIT_TIMEOUT => {
                endJob(child.job);
                _ = win32.CloseHandle(child.job);
                _ = win32.CloseHandle(child.process);
                if (child.port) |p| _ = win32.CloseHandle(p);
                return null;
            },
            else => return win32.lastErrorFail("WaitForSingleObject"),
        }
    }
};

/// Takes what a job told its port off it, without waiting. Whether it said
/// that its memory limit was reached.
fn drain(port: win32.HANDLE) bool {
    var reached = false;
    while (true) {
        var message: win32.DWORD = 0;
        var key: usize = 0;
        var overlapped: ?*win32.OVERLAPPED = null;
        if (win32.GetQueuedCompletionStatus(port, &message, &key, &overlapped, 0) == 0) return reached;
        if (message == win32.JOB_OBJECT_MSG_JOB_MEMORY_LIMIT) reached = true;
    }
}

pub const Output = struct {
    code: u32,
    stdout: []const u8,
};

/// Runs a process with `input` on its stdin, for what it writes on its
/// stdout, as a credential helper answers; its stderr is `spec.stdio`'s last,
/// or ours. For short
/// exchanges: one that writes more than 64 KiB, or takes longer than `ms`,
/// is ended, and the result is null.
pub fn output(arena: Allocator, spec: SpawnSpec, input: []const u8, ms: win32.DWORD) !?Output {
    const pipe_size = 64 * 1024;
    var in_read: win32.HANDLE = undefined;
    var in_write: win32.HANDLE = undefined;
    if (win32.CreatePipe(&in_read, &in_write, null, pipe_size) == 0) return win32.lastErrorFail("CreatePipe");
    var out_read: win32.HANDLE = undefined;
    var out_write: win32.HANDLE = undefined;
    if (win32.CreatePipe(&out_read, &out_write, null, pipe_size) == 0) {
        _ = win32.CloseHandle(in_read);
        _ = win32.CloseHandle(in_write);
        return win32.lastErrorFail("CreatePipe");
    }
    defer _ = win32.CloseHandle(out_read);
    var with_pipes = spec;
    // `start` makes the child's ends inheritable; ours stay ours.
    with_pipes.stdio = .{ in_read, out_write, if (spec.stdio) |s| s[2] else win32.GetStdHandle(win32.STD_ERROR_HANDLE) };
    const started = start(arena, with_pipes);
    // `start` ignores Ctrl+C, for an app that shares the console; zigsaw
    // itself should still stop for it once this is done.
    defer _ = win32.SetConsoleCtrlHandler(&ignoreCtrlC, win32.FALSE);
    _ = win32.CloseHandle(in_read);
    _ = win32.CloseHandle(out_write);
    const child = started catch |err| {
        _ = win32.CloseHandle(in_write);
        return err;
    };
    // The input fits in the pipe, so the write doesn't wait for the child.
    const wrote = win32.WriteFile(in_write, input.ptr, @intCast(input.len), null, null);
    _ = win32.CloseHandle(in_write);
    const code = try child.waitFor(ms) orelse return null;
    if (wrote == 0) return null;
    // The child is gone, so the pipe has all it wrote, then its end.
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        var n: win32.DWORD = 0;
        if (win32.ReadFile(out_read, &buf, buf.len, &n, null) == 0 or n == 0) break;
        try out.appendSlice(arena, buf[0..n]);
    }
    return .{ .code = code, .stdout = out.items };
}

/// Starts a process as `spawn` does, without waiting for it.
pub fn start(arena: Allocator, spec: SpawnSpec) !Child {
    const job = try newJobAllowing(arena, spec.breakaway_ok, spec.limits);
    errdefer _ = win32.CloseHandle(job.handle);
    return .in(job, try startIn(arena, job.handle, spec));
}

/// A job object whose processes end when it's closed, as when we end, and
/// use no more than `limits` together. For `startIn`, when another process
/// has to be in the job before the one a `Child` waits for.
pub fn newJob(arena: Allocator, limits: Limits) !Job {
    return newJobAllowing(arena, false, limits);
}

/// The same, letting its processes start one outside it if they ask
/// (CREATE_BREAKAWAY_FROM_JOB): a shim's job, whose zigsaw may start a lazy
/// pull's helper that must outlive it (see lazy.zig). An app's job never
/// does, so nothing an app starts gets out of it.
fn newJobAllowing(arena: Allocator, breakaway: bool, limits: Limits) !Job {
    const handle = win32.CreateJobObjectW(null, null) orelse return win32.lastErrorFail("CreateJobObjectW");
    errdefer _ = win32.CloseHandle(handle);
    var job: Job = .{ .handle = handle };
    var info: win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};
    info.BasicLimitInformation.LimitFlags = win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
        (if (breakaway) win32.JOB_OBJECT_LIMIT_BREAKAWAY_OK else 0);
    if (limits.memory) |bytes| {
        info.BasicLimitInformation.LimitFlags |= win32.JOB_OBJECT_LIMIT_JOB_MEMORY;
        info.JobMemoryLimit = std.math.cast(usize, bytes) orelse std.math.maxInt(usize);
        job.memory_limit = bytes;
    }
    const processors: ?Processors = if (limits.cpus) |n| try ownProcessors(arena, n) else null;
    if (processors) |p| {
        info.BasicLimitInformation.LimitFlags |= win32.JOB_OBJECT_LIMIT_AFFINITY;
        info.BasicLimitInformation.Affinity = p.mask;
    }
    if (win32.SetInformationJobObject(handle, win32.JobObjectExtendedLimitInformation, &info, @sizeOf(@TypeOf(info))) == 0)
        return win32.lastErrorFail("SetInformationJobObject");
    if (processors) |p| {
        // The same share of the machine as a cap on processor time, which
        // the affinity keeps the job from reaching anyway: some programs
        // count their processors by it (Ninja does), and none of those
        // tried counts by the affinity alone. Only a hint, so one Windows
        // refuses, as inside a job that has its own, is left out.
        const rate: win32.JOBOBJECT_CPU_RATE_CONTROL_INFORMATION = .{
            .ControlFlags = win32.JOB_OBJECT_CPU_RATE_CONTROL_ENABLE | win32.JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP,
            .CpuRate = cpuRate(p.count, win32.GetActiveProcessorCount(win32.ALL_PROCESSOR_GROUPS)),
        };
        _ = win32.SetInformationJobObject(handle, win32.JobObjectCpuRateControlInformation, &rate, @sizeOf(@TypeOf(rate)));
    }
    if (job.memory_limit != null) {
        const port = win32.CreateIoCompletionPort(win32.INVALID_HANDLE_VALUE, null, 0, 1) orelse return win32.lastErrorFail("CreateIoCompletionPort");
        errdefer _ = win32.CloseHandle(port);
        const of_job: win32.JOBOBJECT_ASSOCIATE_COMPLETION_PORT = .{ .CompletionPort = port };
        if (win32.SetInformationJobObject(handle, win32.JobObjectAssociateCompletionPortInformation, &of_job, @sizeOf(@TypeOf(of_job))) == 0)
            return win32.lastErrorFail("SetInformationJobObject");
        job.port = port;
    }
    return job;
}

/// `n` processors as a job's CPU rate: hundredths of a percent of `all`,
/// rounded up, so that a program which multiplies it back gets `n`.
fn cpuRate(n: u32, all: u32) u32 {
    const total: u64 = @max(all, 1);
    return @intCast(@min(10000, @max(1, (@as(u64, n) * 10000 + total - 1) / total)));
}

/// A core's logical processors, as bits of the group's mask, and its
/// efficiency class: higher is faster, on a machine with two kinds.
const Core = struct { mask: usize, class: u8 = 0 };

const Processors = struct { mask: usize, count: u32 };

/// `n` of the processors zigsaw itself may run on, for a job's affinity,
/// which must be among them; null if that's all of them, or more.
fn ownProcessors(arena: Allocator, n: u32) !?Processors {
    var own: usize = 0;
    var system: usize = 0;
    if (win32.GetProcessAffinityMask(win32.GetCurrentProcess(), &own, &system) == 0)
        return win32.lastErrorFail("GetProcessAffinityMask");
    if (n >= @popCount(own)) return null;
    const mask = chooseProcessors(own, coresOfOwnGroup(arena) catch &.{}, n);
    return .{ .mask = mask, .count = @popCount(mask) };
}

/// The cores of the processor group zigsaw's in: a machine has more than
/// one group only with more than 64 processors, and a job's affinity is
/// within one.
fn coresOfOwnGroup(arena: Allocator) ![]const Core {
    var group: win32.GROUP_AFFINITY = .{};
    if (win32.GetThreadGroupAffinity(win32.GetCurrentThread(), &group) == 0) return error.Unknown;
    var len: win32.DWORD = 0;
    _ = win32.GetLogicalProcessorInformationEx(win32.RelationProcessorCore, null, &len);
    if (len == 0) return error.Unknown;
    const buf = try arena.alignedAlloc(u8, .of(usize), len);
    if (win32.GetLogicalProcessorInformationEx(win32.RelationProcessorCore, buf.ptr, &len) == 0) return error.Unknown;
    // Each record: Relationship and Size (4 bytes each), then for a core its
    // Flags, EfficiencyClass, 20 reserved bytes, GroupCount (2 bytes), and
    // GROUP_AFFINITY entries, of which a core has one.
    var cores: std.ArrayList(Core) = .empty;
    var at: usize = 0;
    while (at + 8 <= len) {
        const size = std.mem.readInt(u32, buf[at + 4 ..][0..4], .little);
        if (size < 48 or at + size > len) break;
        const entry = buf[at + 32 ..][0..@sizeOf(win32.GROUP_AFFINITY)];
        const of_group = std.mem.readInt(u16, entry[@sizeOf(usize)..][0..2], .little);
        if (of_group == group.Group) try cores.append(arena, .{
            .mask = std.mem.readInt(usize, entry[0..@sizeOf(usize)], .little),
            .class = buf[at + 9],
        });
        at += size;
    }
    return cores.items;
}

/// `n` of the processors in `own`: one of each core before a second of any,
/// as two on one core do less than two cores, and the faster cores first.
/// Every job gets the same ones, so two limited trees share them. Without
/// `cores`, the lowest.
fn chooseProcessors(own: usize, cores: []const Core, n: u32) usize {
    var chosen: usize = 0;
    var left = n;
    var class: u16 = 256;
    // Classes from the fastest down; within one, a round per processor of a
    // core.
    while (left > 0) {
        var next: ?u8 = null;
        for (cores) |c| {
            if (c.class < class and (next == null or c.class > next.?)) next = c.class;
        }
        class = next orelse break;
        while (left > 0) {
            var took = false;
            for (cores) |c| {
                if (c.class != class or left == 0) continue;
                const free = c.mask & own & ~chosen;
                if (free == 0) continue;
                chosen |= free & (~free +% 1);
                left -= 1;
                took = true;
            }
            if (!took) break;
        }
    }
    // What no core accounted for.
    while (left > 0) : (left -= 1) {
        const free = own & ~chosen;
        if (free == 0) break;
        chosen |= free & (~free +% 1);
    }
    return chosen;
}

test chooseProcessors {
    // Eight processors, two to a core: one of each core first.
    const smt = [_]Core{ .{ .mask = 0b11 }, .{ .mask = 0b1100 }, .{ .mask = 0b110000 }, .{ .mask = 0b11000000 } };
    try std.testing.expectEqual(0b00000001, chooseProcessors(0xff, &smt, 1));
    try std.testing.expectEqual(0b01010101, chooseProcessors(0xff, &smt, 4));
    try std.testing.expectEqual(0b01010111, chooseProcessors(0xff, &smt, 5));
    try std.testing.expectEqual(0xff, chooseProcessors(0xff, &smt, 8));
    try std.testing.expectEqual(0xff, chooseProcessors(0xff, &smt, 99));
    // Only among zigsaw's own, as inside a job that has fewer.
    try std.testing.expectEqual(0b00110000, chooseProcessors(0b00111100 & ~@as(usize, 0b1100), &smt, 2));
    try std.testing.expectEqual(0b00010100, chooseProcessors(0b00111100, &smt, 2));
    try std.testing.expectEqual(0b00011100, chooseProcessors(0b00111100, &smt, 3));
    // Two fast cores of two processors, then four slower ones: the fast
    // cores' second processors before any slow core.
    const hybrid = [_]Core{
        .{ .mask = 0b1 << 4, .class = 0 }, .{ .mask = 0b1 << 5, .class = 0 }, .{ .mask = 0b1 << 6, .class = 0 }, .{ .mask = 0b1 << 7, .class = 0 },
        .{ .mask = 0b0011, .class = 1 },   .{ .mask = 0b1100, .class = 1 },
    };
    try std.testing.expectEqual(0b00000101, chooseProcessors(0xff, &hybrid, 2));
    try std.testing.expectEqual(0b00001111, chooseProcessors(0xff, &hybrid, 4));
    try std.testing.expectEqual(0b00111111, chooseProcessors(0xff, &hybrid, 6));
    // Nothing known of the cores: the lowest.
    try std.testing.expectEqual(0b0111, chooseProcessors(0xff, &.{}, 3));
    try std.testing.expectEqual(0b101010, chooseProcessors(0b101010, &.{}, 5));
}

test cpuRate {
    try std.testing.expectEqual(2500, cpuRate(4, 16));
    // Rounded up: 12 * 4167 / 10000 is 5, and 12 * 4166 / 10000 is 4.
    try std.testing.expectEqual(4167, cpuRate(5, 12));
    try std.testing.expectEqual(10000, cpuRate(8, 8));
    try std.testing.expectEqual(10000, cpuRate(9, 8));
    try std.testing.expectEqual(79, cpuRate(1, 128));
}

/// A process started by `startDetached`.
pub const Detached = struct {
    process: win32.HANDLE,
    pid: u32,
    /// Whether it's out of every job we're in. When one of them refuses, it's
    /// in those, and ends as they do.
    broke_away: bool,
};

/// Starts a program that outlives us: no console, none of our handles
/// (a GUI shim reads our output until every holder of its pipe has ended),
/// and out of our jobs if they let it. A low or AppContainer token, or a job
/// that doesn't allow it, keeps it in.
pub fn startDetached(arena: Allocator, exe: []const u8, command_line: []const u8, cwd: []const u8) !Detached {
    const exe_w = try win32.wide(arena, exe);
    const cwd_w = try win32.wide(arena, cwd);
    for ([_]bool{ true, false }) |breakaway| {
        const line = try win32.wide(arena, command_line);
        var startup: win32.STARTUPINFOW = .{ .cb = @sizeOf(win32.STARTUPINFOW) };
        var info: win32.PROCESS_INFORMATION = undefined;
        const flags = win32.DETACHED_PROCESS | win32.CREATE_UNICODE_ENVIRONMENT |
            (if (breakaway) win32.CREATE_BREAKAWAY_FROM_JOB else 0);
        if (win32.CreateProcessW(exe_w, line, null, null, win32.FALSE, flags, null, cwd_w, &startup, &info) == 0) {
            if (breakaway and win32.GetLastError() == win32.ERROR_ACCESS_DENIED) continue;
            return win32.lastErrorFail("CreateProcessW");
        }
        _ = win32.CloseHandle(info.hThread);
        return .{ .process = info.hProcess, .pid = info.dwProcessId, .broke_away = breakaway };
    }
    unreachable;
}

/// Starts a process in `job`, another process's, which ends it with that
/// one (see `Child.wait`). Returns its process handle.
pub fn startIn(arena: Allocator, job: win32.HANDLE, spec: SpawnSpec) !win32.HANDLE {
    // Hand the child our stdio handles, or the ones given, and nothing else
    // but `spec.inherit`.
    var std_handles: [3]?win32.HANDLE = .{ null, null, null };
    var inherit: std.ArrayList(win32.HANDLE) = .empty;
    for ([_]win32.DWORD{ win32.STD_INPUT_HANDLE, win32.STD_OUTPUT_HANDLE, win32.STD_ERROR_HANDLE }, 0..) |which, i| {
        const given = if (spec.stdio) |s| s[i] else win32.GetStdHandle(which);
        const h = given orelse continue;
        if (h == win32.INVALID_HANDLE_VALUE) continue;
        if (win32.SetHandleInformation(h, win32.HANDLE_FLAG_INHERIT, win32.HANDLE_FLAG_INHERIT) == 0) continue;
        std_handles[i] = h;
        if (std.mem.indexOfScalar(win32.HANDLE, inherit.items, h) == null) try inherit.append(arena, h);
    }
    for (spec.inherit) |h| {
        if (win32.SetHandleInformation(h, win32.HANDLE_FLAG_INHERIT, win32.HANDLE_FLAG_INHERIT) == 0)
            return win32.lastErrorFail("SetHandleInformation");
        try inherit.append(arena, h);
    }
    const inherit_count = inherit.items.len;

    const attr_count: win32.DWORD = 1 + @as(win32.DWORD, @intFromBool(inherit_count > 0)) + @intFromBool(spec.security != null);
    var attr_size: usize = 0;
    _ = win32.InitializeProcThreadAttributeList(null, attr_count, 0, &attr_size);
    const attrs = try arena.alignedAlloc(u8, .of(usize), attr_size);
    if (win32.InitializeProcThreadAttributeList(attrs.ptr, attr_count, 0, &attr_size) == 0)
        return win32.lastErrorFail("InitializeProcThreadAttributeList");
    defer win32.DeleteProcThreadAttributeList(attrs.ptr);

    // Assigning the job at creation means no child process can start outside it.
    const jobs = [1]win32.HANDLE{job};
    if (win32.UpdateProcThreadAttribute(attrs.ptr, 0, win32.PROC_THREAD_ATTRIBUTE_JOB_LIST, &jobs, @sizeOf(win32.HANDLE), null, null) == 0)
        return win32.lastErrorFail("UpdateProcThreadAttribute(JOB_LIST)");
    if (inherit_count > 0) {
        if (win32.UpdateProcThreadAttribute(attrs.ptr, 0, win32.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, @ptrCast(inherit.items.ptr), inherit_count * @sizeOf(win32.HANDLE), null, null) == 0)
            return win32.lastErrorFail("UpdateProcThreadAttribute(HANDLE_LIST)");
    }
    if (spec.security) |security| {
        if (win32.UpdateProcThreadAttribute(attrs.ptr, 0, win32.PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, security, @sizeOf(win32.SECURITY_CAPABILITIES), null, null) == 0)
            return win32.lastErrorFail("UpdateProcThreadAttribute(SECURITY_CAPABILITIES)");
    }

    var startup: win32.STARTUPINFOEXW = .{
        .StartupInfo = .{ .cb = @sizeOf(win32.STARTUPINFOEXW) },
        .lpAttributeList = attrs.ptr,
    };
    if (std_handles[0] != null or std_handles[1] != null or std_handles[2] != null) {
        startup.StartupInfo.dwFlags |= win32.STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdInput = std_handles[0];
        startup.StartupInfo.hStdOutput = std_handles[1];
        startup.StartupInfo.hStdError = std_handles[2];
    }
    if (spec.shortcut) |lnk| {
        startup.StartupInfo.dwFlags |= win32.STARTF_TITLEISLINKNAME;
        startup.StartupInfo.lpTitle = try win32.wide(arena, lnk);
    }

    // The app shares our console, so it receives Ctrl+C too and decides what
    // to do; we keep waiting so we can report its exit code. Set before the
    // app starts, so an early Ctrl+C can't end us (and, through the job, the
    // app) first. A handler function isn't inherited, unlike ignoring Ctrl+C.
    _ = win32.SetConsoleCtrlHandler(&ignoreCtrlC, win32.TRUE);

    var info: win32.PROCESS_INFORMATION = undefined;
    const exe = try win32.wide(arena, spec.exe);
    const command_line = try win32.wide(arena, spec.command_line);
    const inherit_handles: win32.BOOL = @intFromBool(inherit_count > 0);
    const flags = win32.EXTENDED_STARTUPINFO_PRESENT | win32.CREATE_UNICODE_ENVIRONMENT | spec.creation_flags;
    const env: ?*const anyopaque = if (spec.env_block) |b| b.ptr else null;
    const cwd: ?win32.LPCWSTR = if (spec.cwd) |c| try win32.wide(arena, c) else null;
    if (spec.token) |token| {
        if (win32.CreateProcessAsUserW(token, exe, command_line, null, null, inherit_handles, flags, env, cwd, &startup.StartupInfo, &info) == 0)
            return win32.lastErrorFail("CreateProcessAsUserW");
    } else {
        if (win32.CreateProcessW(exe, command_line, null, null, inherit_handles, flags, env, cwd, &startup.StartupInfo, &info) == 0)
            return win32.lastErrorFail("CreateProcessW");
    }
    _ = win32.CloseHandle(info.hThread);
    return info.hProcess;
}

/// Ends whatever is left in the job, and waits a while for it to be gone.
/// Closing the job would end it too, but without waiting, and what's ending
/// can still hold files open: a build's tools, say, whose directory is
/// deleted next.
fn endJob(job: win32.HANDLE) void {
    _ = win32.TerminateJobObject(job, 1);
    var info: win32.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION = .{};
    var waited: u32 = 0;
    while (waited < 5000) : (waited += 10) {
        if (win32.QueryInformationJobObject(job, win32.JobObjectBasicAccountingInformation, &info, @sizeOf(@TypeOf(info)), null) == 0) return;
        if (info.ActiveProcesses == 0) return;
        win32.Sleep(10);
    }
}

fn ignoreCtrlC(event: win32.DWORD) callconv(.winapi) win32.BOOL {
    return if (event == win32.CTRL_C_EVENT or event == win32.CTRL_BREAK_EVENT) win32.TRUE else win32.FALSE;
}

test buildCommandLine {
    const cases = [_]struct { args: []const []const u8, want: []const u8 }{
        .{ .args = &.{"plain"}, .want = "C:\\app\\x.exe plain" },
        .{ .args = &.{"two words"}, .want = "C:\\app\\x.exe \"two words\"" },
        .{ .args = &.{""}, .want = "C:\\app\\x.exe \"\"" },
        .{ .args = &.{"say \"hi\""}, .want = "C:\\app\\x.exe \"say \\\"hi\\\"\"" },
        .{ .args = &.{"C:\\dir with space\\"}, .want = "C:\\app\\x.exe \"C:\\dir with space\\\\\"" },
        .{ .args = &.{"a\\\\b"}, .want = "C:\\app\\x.exe a\\\\b" },
    };
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    for (cases) |c| {
        try std.testing.expectEqualStrings(c.want, try buildCommandLine(arena_state.allocator(), "C:\\app\\x.exe", c.args));
    }
}

test buildBatchCommandLine {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cmd = "C:\\Windows\\System32\\cmd.exe";
    const prefix = cmd ++ " /d /e:ON /v:OFF /c \"\"C:\\app\\run.cmd\"";

    const cases = [_]struct { arg: []const u8, want: []const u8 }{
        .{ .arg = "plain-1.2/x:y@z", .want = "plain-1.2/x:y@z" },
        .{ .arg = "a\\b", .want = "a\\b" },
        .{ .arg = "", .want = "\"\"" },
        .{ .arg = "two words", .want = "\"two words\"" },
        .{ .arg = "C:\\dir\\", .want = "\"C:\\dir\\\\\"" },
        .{ .arg = "say \"hi\"", .want = "\"say \"\"hi\"\"\"" },
        .{ .arg = "a\\\"b", .want = "\"a\\\\\"\"b\"" },
        .{ .arg = "%PATH%", .want = "\"%%cd:~,%PATH%%cd:~,%\"" },
        .{ .arg = "!x!", .want = "\"!x!\"" },
        .{ .arg = "& | < > ^ ( )", .want = "\"& | < > ^ ( )\"" },
        .{ .arg = "\"&calc&\"", .want = "\"\"\"&calc&\"\"\"" },
        .{ .arg = "--flag=a,b;c", .want = "\"--flag=a,b;c\"" },
        .{ .arg = "tab\there", .want = "\"tab\there\"" },
        // Text beyond ASCII is safe, except for control characters.
        .{ .arg = "héllo-wörld", .want = "héllo-wörld" },
        .{ .arg = "next\u{85}line", .want = "\"next\u{85}line\"" },
    };
    inline for (cases) |c| {
        const line = try buildBatchCommandLine(arena, cmd, "C:\\app\\run.cmd", &.{c.arg});
        try std.testing.expectEqualStrings(prefix ++ " " ++ c.want ++ "\"", line);
    }
    try std.testing.expectEqualStrings(prefix ++ " a \"b c\"\"", try buildBatchCommandLine(arena, cmd, "C:\\app\\run.cmd", &.{ "a", "b c" }));
    try std.testing.expectEqualStrings(prefix ++ "\"", try buildBatchCommandLine(arena, cmd, "C:\\app\\run.cmd", &.{}));

    // A '%' in the script's path is escaped too; a quote or a trailing '\' can't be in one.
    try std.testing.expectEqualStrings(
        cmd ++ " /d /e:ON /v:OFF /c \"\"C:\\100%%cd:~,%\\run.cmd\"\"",
        try buildBatchCommandLine(arena, cmd, "C:\\100%\\run.cmd", &.{}),
    );
    try std.testing.expectError(error.InvalidBatchScript, buildBatchCommandLine(arena, cmd, "C:\\a\"b.cmd", &.{}));
    try std.testing.expectError(error.InvalidBatchScript, buildBatchCommandLine(arena, cmd, "C:\\dir\\", &.{}));
    for ([_][]const u8{ "a\nb", "a\rb", "a\x00b" }) |bad| {
        try std.testing.expectError(error.InvalidBatchArgument, buildBatchCommandLine(arena, cmd, "C:\\app\\run.cmd", &.{bad}));
    }
}
