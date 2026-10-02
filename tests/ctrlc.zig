//! Test driver for console events. It runs node alone, through `zigsaw run`
//! and through its shim, each in a pseudoconsole as a terminal hosts console
//! programs, then presses Ctrl+C, sends Ctrl+Break or closes the console, and
//! checks what the app and zigsaw do. It also runs node behind a batch file,
//! alone and through `zigsaw run`, and answers cmd.exe's "Terminate batch
//! job (Y/N)?". Built by `zig build ctrlc-driver`, run by tests/ctrlc.sh.
//!
//!   zigsaw-ctrlc <zigsaw.exe> <store> <work-dir>   run the checks; org.nodejs.node
//!                                                  must be installed in <store>
//!   zigsaw-ctrlc break <pid>                       send Ctrl+Break to <pid>'s console

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const BOOL = win32.BOOL;
const DWORD = win32.DWORD;
const HANDLE = win32.HANDLE;

const HPCON = *anyopaque;
const COORD = extern struct { X: i16, Y: i16 };
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const DETACHED_PROCESS: DWORD = 0x00000008;
const SYNCHRONIZE: DWORD = 0x00100000;
extern "kernel32" fn CreatePipe(read: *HANDLE, write: *HANDLE, attributes: ?*anyopaque, size: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn CreatePseudoConsole(size: COORD, input: HANDLE, output: HANDLE, flags: DWORD, pc: *HPCON) callconv(.winapi) win32.HRESULT;
extern "kernel32" fn ClosePseudoConsole(pc: HPCON) callconv(.winapi) void;
extern "kernel32" fn OpenProcess(access: DWORD, inherit: BOOL, pid: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn TerminateProcess(process: HANDLE, code: u32) callconv(.winapi) BOOL;
extern "kernel32" fn FreeConsole() callconv(.winapi) BOOL;
extern "kernel32" fn AttachConsole(pid: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GenerateConsoleCtrlEvent(event: DWORD, group: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 3 and std.mem.eql(u8, args[1], "break")) {
        win32.ExitProcess(sendBreak(try std.fmt.parseInt(DWORD, args[2], 10)));
    }
    if (args.len != 4) {
        std.debug.print("usage: zigsaw-ctrlc <zigsaw.exe> <store> <work-dir>\n", .{});
        win32.ExitProcess(2);
    }
    // Whoever started us may have turned Ctrl+C off (Git Bash does), and
    // processes inherit that. Turn it back on for the apps, as a terminal would.
    _ = win32.SetConsoleCtrlHandler(null, win32.FALSE);
    var t: Tester = .{
        .arena = arena,
        .io = init.io,
        .zigsaw = args[1],
        .store = args[2],
        .work = args[3],
        .self = try win32.selfExePath(arena),
        .node = try installedNode(init.io, arena, args[2]),
    };
    // Batch files run "node", which zigsaw puts on the app's PATH. Run
    // alone, they find it on ours.
    const path = try std.fmt.allocPrint(arena, "{s};{s}", .{ std.fs.path.dirname(t.node).?, init.environ_map.get("PATH") orelse "" });
    _ = win32.SetEnvironmentVariableW(try win32.wide(arena, "PATH"), try win32.wide(arena, path));
    try t.runAll();
    std.debug.print("\n{d} check(s) failed.\n", .{t.failures});
    win32.ExitProcess(@intFromBool(t.failures > 0));
}

// ---------------------------------------------------------------------------
// The checks

/// Node scripts. They have no double quotes, so simple quoting does.
const script = struct {
    const forever = "setInterval(()=>{},1e3)";
    const sigint = "process.on('SIGINT',()=>{console.log('got-SIGINT');process.exit(3)});console.log('ready');" ++ forever;
    const sigbreak = "process.on('SIGBREAK',()=>{console.log('got-SIGBREAK');process.exit(4)});console.log('ready');" ++ forever;
    const default = "console.log('ready');" ++ forever;
    /// Starts a detached child: outside the console, so console events don't
    /// reach it, and outside node's own job, so node doesn't end it either.
    /// Only zigsaw's job can.
    const child = "const c=require('child_process').spawn(process.execPath,['-e','" ++ forever ++
        "'],{stdio:'ignore',detached:true});c.on('spawn',()=>console.log('ready:'+c.pid));";
    const tree = child ++ "process.on('SIGINT',()=>process.exit(3));" ++ forever;
    /// `tree`, saying when SIGINT arrives.
    const tree_sigint = child ++ "process.on('SIGINT',()=>{console.log('got-SIGINT');process.exit(3)});" ++ forever;
    /// On close, takes a second to clean up: writes the file named by its argument.
    const close = child ++ "process.on('SIGHUP',()=>setTimeout(()=>{require('fs').writeFileSync(process.argv[1],'x');process.exit(0)},1000));" ++ forever;
};

const Way = enum {
    alone,
    zigsaw_run,
    shim,
    /// Node started by a batch file, which runs alone or through `zigsaw run --command`.
    batch_alone,
    batch_zigsaw_run,

    fn isBatch(way: Way) bool {
        return way == .batch_alone or way == .batch_zigsaw_run;
    }
};
const Event = enum { ctrl_c, ctrl_break, close };

const Tester = struct {
    arena: Allocator,
    io: std.Io,
    zigsaw: []const u8,
    store: []const u8,
    work: []const u8,
    self: []const u8,
    /// node.exe in the app's deployment, to run it without zigsaw.
    node: []const u8,
    failures: usize = 0,

    fn runAll(t: *Tester) !void {
        // How node itself behaves, to compare with.
        const alone = try t.run(.alone, script.default, &.{}, .ctrl_c);
        t.check("node alone: Ctrl+C ends it", alone.code != null, "it kept running");
        // The control for the checks below: alone, node leaves its detached child running.
        const alone_tree = try t.run(.alone, script.tree, &.{}, .ctrl_c);
        t.check("node alone: its detached child outlives it", alone_tree.code == 3 and alone_tree.child != null and !alone_tree.child_ended, try alone_tree.describe(t.arena));
        if (alone_tree.child) |c| killIfRunning(c);
        const alone_marker = try t.marker("alone");
        const alone_close = try t.run(.alone, script.close, &.{alone_marker}, .close);
        const alone_cleaned = try exists(t.io, alone_marker);
        t.check("node alone: closing the console lets it clean up first", alone_cleaned, "its SIGHUP handler didn't finish");
        if (alone_close.child) |c| killIfRunning(c);

        for ([_]Way{ .zigsaw_run, .shim }) |way| {
            const name = @tagName(way);
            const sigint = try t.run(way, script.sigint, &.{}, .ctrl_c);
            t.checkf("{s}: Ctrl+C reaches the app, and its exit code comes back", .{name}, sigint.code == 3 and sigint.has("got-SIGINT"), try sigint.describe(t.arena));

            const sigbreak = try t.run(way, script.sigbreak, &.{}, .ctrl_break);
            t.checkf("{s}: so does Ctrl+Break", .{name}, sigbreak.code == 4 and sigbreak.has("got-SIGBREAK"), try sigbreak.describe(t.arena));

            const default = try t.run(way, script.default, &.{}, .ctrl_c);
            t.checkf("{s}: without a handler, the exit code is node's own ({?x})", .{ name, alone.code }, default.code != null and default.code == alone.code, try default.describe(t.arena));

            const tree = try t.run(way, script.tree, &.{}, .ctrl_c);
            t.checkf("{s}: Ctrl+C ends the run, and the app's detached child with it", .{name}, tree.code == 3 and tree.child_ended, try tree.describe(t.arena));

            const marker_path = try t.marker(name);
            const close = try t.run(way, script.close, &.{marker_path}, .close);
            const cleaned = try exists(t.io, marker_path);
            t.checkf("{s}: closing the console ends the run and the child", .{name}, close.code != null and close.child_ended, try close.describe(t.arena));
            t.checkf("{s}: closing the console lets the app clean up first", .{name}, cleaned, "its SIGHUP handler didn't finish");
        }

        // Ctrl+C while a batch file runs node: cmd.exe asks "Terminate batch
        // job (Y/N)?" once node has exited. Through zigsaw, the same should
        // happen as alone, and the run should then end the whole tree.
        const batch_alone = try t.run(.batch_alone, script.tree_sigint, &.{}, .ctrl_c);
        t.check("batch alone: Ctrl+C reaches node, then cmd.exe asks to terminate the batch job", batch_alone.prompted and batch_alone.has("got-SIGINT") and batch_alone.code != null, try batch_alone.describe(t.arena));
        t.check("batch alone: answering Y stops the batch file", !batch_alone.has("after-node"), try batch_alone.describe(t.arena));
        if (batch_alone.child) |c| killIfRunning(c);
        const batch = try t.run(.batch_zigsaw_run, script.tree_sigint, &.{}, .ctrl_c);
        t.check("batch via zigsaw run: the same prompt, after node's handler ran", batch.prompted and batch.has("got-SIGINT"), try batch.describe(t.arena));
        t.checkf("batch via zigsaw run: answering Y stops it, with the same exit code as alone ({?x})", .{batch_alone.code}, !batch.has("after-node") and batch.code != null and batch.code == batch_alone.code, try batch.describe(t.arena));
        t.check("batch via zigsaw run: the run ends node's detached child", batch.child_ended, try batch.describe(t.arena));
    }

    /// A batch file in the work directory that runs node with `code`, then
    /// prints "after-node".
    fn batchFile(t: *Tester, code: []const u8) ![]const u8 {
        const p = try std.fmt.allocPrint(t.arena, "{s}\\node-script.cmd", .{t.work});
        const text = try std.fmt.allocPrint(t.arena, "@node -e \"{s}\"\r\n@echo after-node\r\n", .{code});
        try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = p, .data = text });
        return p;
    }

    const Result = struct {
        /// Null if it didn't exit in time.
        code: ?u32,
        output: []const u8,
        /// The child the app reported, if it started one.
        child: ?HANDLE = null,
        child_ended: bool = false,
        /// For batch files: cmd.exe asked "Terminate batch job (Y/N)?".
        prompted: bool = false,
        problem: ?[]const u8 = null,

        fn has(r: Result, text: []const u8) bool {
            return std.mem.indexOf(u8, r.output, text) != null;
        }

        fn describe(r: Result, arena: Allocator) ![]const u8 {
            const what = r.problem orelse if (r.code) |c| try std.fmt.allocPrint(arena, "exit code 0x{x}", .{c}) else "still running after 15 s";
            return std.fmt.allocPrint(arena, "{s}{s}; output: {s}", .{
                what, if (r.child != null and !r.child_ended) ", child still running" else "", printable(arena, r.output),
            });
        }
    };

    /// Runs `code` with node the given way, waits until it prints "ready",
    /// sends `event`, and waits for it to end. Through a batch file, answers
    /// Y when cmd.exe asks whether to terminate it.
    fn run(t: *Tester, way: Way, code: []const u8, extra: []const []const u8, event: Event) !Result {
        var line: std.ArrayList(u8) = .empty;
        switch (way) {
            .alone => try appendArg(t.arena, &line, t.node),
            .zigsaw_run => {
                try appendArg(t.arena, &line, t.zigsaw);
                try line.appendSlice(t.arena, " run org.nodejs.node");
            },
            .shim => try appendArg(t.arena, &line, try std.fs.path.join(t.arena, &.{ t.store, "bin", "node.exe" })),
            // Windows runs a batch file given as the program through cmd.exe /c.
            .batch_alone => try appendArg(t.arena, &line, try t.batchFile(code)),
            .batch_zigsaw_run => {
                try appendArg(t.arena, &line, t.zigsaw);
                try line.appendSlice(t.arena, " run --command=");
                try appendArg(t.arena, &line, try t.batchFile(code));
                try line.appendSlice(t.arena, " org.nodejs.node");
            },
        }
        if (!way.isBatch()) {
            try line.appendSlice(t.arena, " -e ");
            try appendArg(t.arena, &line, code);
        }
        for (extra) |arg| {
            try line.append(t.arena, ' ');
            try appendArg(t.arena, &line, arg);
        }

        var console = try Console.start(t.arena, line.items);
        defer console.deinit();
        const after_ready = console.waitFor("ready", 30_000) orelse {
            _ = TerminateProcess(console.process, 1);
            return .{ .code = null, .output = console.text.get(), .problem = "it never printed \"ready\"" };
        };
        var result: Result = .{ .code = null, .output = "" };
        // Open the child before anything can end it, so its pid can't be reused.
        if (childPid(after_ready)) |pid| result.child = OpenProcess(SYNCHRONIZE | 0x0001, win32.FALSE, pid);

        switch (event) {
            .ctrl_c => try console.pressCtrlC(),
            .ctrl_break => t.breakConsoleOf(console.pid) catch |err| {
                result.problem = try std.fmt.allocPrint(t.arena, "sending Ctrl+Break: {t}", .{err});
            },
            .close => console.close(),
        }
        if (way.isBatch()) {
            if (console.waitFor("Terminate batch job (Y/N)?", 15_000)) |_| {
                result.prompted = true;
                var written: DWORD = 0;
                _ = win32.WriteFile(console.input, "Y\r", 2, &written, null);
            }
        }
        result.code = console.exitCode(15_000);
        if (result.code == null) _ = TerminateProcess(console.process, 1);
        if (result.child) |c| {
            result.child_ended = win32.WaitForSingleObject(c, 3000) == win32.WAIT_OBJECT_0;
            if (way != .alone) killIfRunning(c);
        }
        console.close();
        result.output = console.text.get();
        return result;
    }

    /// Runs `zigsaw-ctrlc break <pid>`, without a console of its own.
    fn breakConsoleOf(t: *Tester, pid: DWORD) !void {
        var line: std.ArrayList(u8) = .empty;
        try appendArg(t.arena, &line, t.self);
        try line.print(t.arena, " break {d}", .{pid});
        var startup: win32.STARTUPINFOW = .{ .cb = @sizeOf(win32.STARTUPINFOW) };
        var info: win32.PROCESS_INFORMATION = undefined;
        if (win32.CreateProcessW(null, try win32.wide(t.arena, line.items), null, null, win32.FALSE, DETACHED_PROCESS, null, null, &startup, &info) == 0)
            return error.CreateProcessFailed;
        defer _ = win32.CloseHandle(info.hProcess);
        _ = win32.CloseHandle(info.hThread);
        _ = win32.WaitForSingleObject(info.hProcess, 5000);
        var code: DWORD = 1;
        _ = win32.GetExitCodeProcess(info.hProcess, &code);
        if (code != 0) return error.SendBreakFailed;
    }

    fn marker(t: *Tester, name: []const u8) ![]const u8 {
        const p = try std.fmt.allocPrint(t.arena, "{s}\\closed-{s}.txt", .{ t.work, name });
        std.Io.Dir.cwd().deleteFile(t.io, p) catch {};
        return p;
    }

    fn check(t: *Tester, label: []const u8, ok: bool, problem: []const u8) void {
        if (ok) {
            std.debug.print("ok    {s}\n", .{label});
        } else {
            std.debug.print("FAIL  {s}\n      {s}\n", .{ label, problem });
            t.failures += 1;
        }
    }

    fn checkf(t: *Tester, comptime fmt: []const u8, args: anytype, ok: bool, problem: []const u8) void {
        t.check(std.fmt.allocPrint(t.arena, fmt, args) catch fmt, ok, problem);
    }
};

/// The end of a console's output, without escape sequences and line breaks.
fn printable(arena: Allocator, output: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < output.len) : (i += 1) {
        const ch = output[i];
        if (ch == 0x1b) {
            // Skip "ESC [ ... letter" and "ESC ] ... BEL".
            i += 1;
            while (i < output.len and !std.ascii.isAlphabetic(output[i]) and output[i] != 0x07) i += 1;
            continue;
        }
        const shown: u8 = if (ch < 0x20) ' ' else ch;
        out.append(arena, shown) catch return output;
    }
    const trimmed = std.mem.trim(u8, out.items, " ");
    return trimmed[trimmed.len -| 300..];
}

/// The pid in "ready:<pid>", if the app printed one.
fn childPid(after_ready: []const u8) ?DWORD {
    if (!std.mem.startsWith(u8, after_ready, ":")) return null;
    const rest = after_ready[1..];
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    return std.fmt.parseInt(DWORD, rest[0..end], 10) catch null;
}

fn killIfRunning(process: HANDLE) void {
    if (win32.WaitForSingleObject(process, 0) != win32.WAIT_OBJECT_0) _ = TerminateProcess(process, 1);
    _ = win32.CloseHandle(process);
}

/// The Ctrl+Break sender: attaches to the console of `pid` and sends the
/// event to every process in it.
fn sendBreak(pid: DWORD) u32 {
    _ = FreeConsole();
    if (AttachConsole(pid) == 0) return 10;
    _ = win32.SetConsoleCtrlHandler(&ignoreEvent, win32.TRUE);
    if (GenerateConsoleCtrlEvent(win32.CTRL_BREAK_EVENT, 0) == 0) return 11;
    return 0;
}

fn ignoreEvent(_: DWORD) callconv(.winapi) BOOL {
    return win32.TRUE;
}

/// node.exe in the installed app's deployment, found through its ref.
/// node.exe in the deployment of the app's own layer, the manifest's last.
fn installedNode(io: std.Io, arena: Allocator, store: []const u8) ![]const u8 {
    const ref = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ store, "refs", "org.nodejs.node.json" }), arena, .limited(64 << 10));
    const at = std.mem.indexOf(u8, ref, "sha256:") orelse return error.BadRef;
    const manifest = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ store, "blobs", "sha256", ref[at + 7 .. at + 7 + 64] }), arena, .limited(1 << 20));
    const layer = std.mem.lastIndexOf(u8, manifest, "sha256:") orelse return error.BadManifest;
    return std.fs.path.join(arena, &.{ store, "deploy", manifest[layer + 7 .. layer + 7 + 64], "node.exe" });
}

fn exists(io: std.Io, p: []const u8) !bool {
    std.Io.Dir.cwd().access(io, p, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

/// Appends a command-line argument, quoted if it has spaces. (The arguments
/// here never contain quotes.)
fn appendArg(arena: Allocator, line: *std.ArrayList(u8), arg: []const u8) !void {
    std.debug.assert(std.mem.indexOfScalar(u8, arg, '"') == null);
    if (std.mem.indexOfAny(u8, arg, " \t") == null) return line.appendSlice(arena, arg);
    try line.print(arena, "\"{s}\"", .{arg});
}

// ---------------------------------------------------------------------------
// Pseudoconsoles

/// A process running in a pseudoconsole of its own, with its output collected.
const Console = struct {
    pc: HPCON,
    closed: bool = false,
    input: HANDLE,
    output: HANDLE,
    process: HANDLE,
    pid: DWORD,
    text: *Text,
    reader: std.Thread,

    fn start(arena: Allocator, command_line: []const u8) !Console {
        var input_read: HANDLE = undefined;
        var input_write: HANDLE = undefined;
        var output_read: HANDLE = undefined;
        var output_write: HANDLE = undefined;
        if (CreatePipe(&input_read, &input_write, null, 0) == 0) return error.CreatePipeFailed;
        if (CreatePipe(&output_read, &output_write, null, 0) == 0) return error.CreatePipeFailed;
        var pc: HPCON = undefined;
        if (CreatePseudoConsole(.{ .X = 120, .Y = 30 }, input_read, output_write, 0, &pc) < 0) return error.CreatePseudoConsoleFailed;
        // The pseudoconsole has its own copies.
        _ = win32.CloseHandle(input_read);
        _ = win32.CloseHandle(output_write);

        var size: usize = 0;
        _ = win32.InitializeProcThreadAttributeList(null, 1, 0, &size);
        const attrs = try arena.alignedAlloc(u8, .of(usize), size);
        if (win32.InitializeProcThreadAttributeList(attrs.ptr, 1, 0, &size) == 0) return error.AttributeListFailed;
        defer win32.DeleteProcThreadAttributeList(attrs.ptr);
        if (win32.UpdateProcThreadAttribute(attrs.ptr, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, pc, @sizeOf(HPCON), null, null) == 0)
            return error.AttributeListFailed;

        // Standard handles left empty, so the child uses the pseudoconsole's
        // rather than inheriting ours.
        var startup: win32.STARTUPINFOEXW = .{
            .StartupInfo = .{ .cb = @sizeOf(win32.STARTUPINFOEXW), .dwFlags = win32.STARTF_USESTDHANDLES },
            .lpAttributeList = attrs.ptr,
        };
        var info: win32.PROCESS_INFORMATION = undefined;
        if (win32.CreateProcessW(null, try win32.wide(arena, command_line), null, null, win32.FALSE, win32.EXTENDED_STARTUPINFO_PRESENT, null, null, &startup.StartupInfo, &info) == 0)
            return error.CreateProcessFailed;
        _ = win32.CloseHandle(info.hThread);

        const text = try arena.create(Text);
        text.* = .{};
        return .{
            .pc = pc,
            .input = input_write,
            .output = output_read,
            .process = info.hProcess,
            .pid = info.dwProcessId,
            .text = text,
            // The output has to be read all the time, or the pseudoconsole blocks.
            .reader = try std.Thread.spawn(.{}, Text.drain, .{ text, output_read }),
        };
    }

    /// Waits until the output contains `needle`; returns what follows it.
    fn waitFor(c: *Console, needle: []const u8, timeout_ms: u64) ?[]const u8 {
        const deadline = GetTickCount64() + timeout_ms;
        while (GetTickCount64() < deadline) {
            const text = c.text.get();
            if (std.mem.indexOf(u8, text, needle)) |i| {
                // Give the rest of the line a moment to arrive.
                Sleep(100);
                const now = c.text.get();
                const rest = now[i + needle.len ..];
                return rest[0 .. std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len];
            }
            Sleep(20);
        }
        return null;
    }

    /// Types Ctrl+C, as in a terminal.
    fn pressCtrlC(c: *Console) !void {
        var written: DWORD = 0;
        if (win32.WriteFile(c.input, "\x03", 1, &written, null) == 0) return error.WriteFailed;
    }

    /// Waits for the process to end and returns its exit code, or null if
    /// it's still running after `timeout_ms`.
    fn exitCode(c: *Console, timeout_ms: DWORD) ?u32 {
        if (win32.WaitForSingleObject(c.process, timeout_ms) != win32.WAIT_OBJECT_0) return null;
        var code: DWORD = 0;
        _ = win32.GetExitCodeProcess(c.process, &code);
        return code;
    }

    /// Closes the pseudoconsole, like closing a terminal window.
    fn close(c: *Console) void {
        if (c.closed) return;
        ClosePseudoConsole(c.pc);
        c.closed = true;
    }

    fn deinit(c: *Console) void {
        c.close();
        c.reader.join();
        _ = win32.CloseHandle(c.input);
        _ = win32.CloseHandle(c.output);
        _ = win32.CloseHandle(c.process);
    }
};

const Text = struct {
    buf: [64 * 1024]u8 = undefined,
    len: std.atomic.Value(usize) = .init(0),

    fn get(t: *Text) []const u8 {
        return t.buf[0..t.len.load(.acquire)];
    }

    /// Reads `pipe` until it closes. Output beyond the buffer is read and dropped.
    fn drain(t: *Text, pipe: HANDLE) void {
        var spill: [4096]u8 = undefined;
        while (true) {
            const len = t.len.load(.monotonic);
            const room = t.buf[len..];
            const dest = if (room.len > 0) room else spill[0..];
            var got: DWORD = 0;
            if (win32.ReadFile(pipe, dest.ptr, @intCast(dest.len), &got, null) == 0 or got == 0) return;
            if (room.len > 0) t.len.store(len + got, .release);
        }
    }
};
