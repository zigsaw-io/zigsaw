const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .os_tag = .windows },
    });
    const chosen = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size (default: ReleaseSafe for zigsaw.exe, Debug otherwise)");
    const optimize = chosen orelse .Debug;

    // zigsaw compresses, hashes and unpacks layers of hundreds of MB, which
    // takes about 8 times as long in Debug: 74 s instead of 9 s to compress
    // zig's layer.
    const exe_mod = zigsawModule(b, target, chosen orelse .ReleaseSafe);

    const exe = b.addExecutable(.{
        .name = "zigsaw",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Copied to <store>\bin\<name>.exe for every exported command, so it is
    // always built small. zigsaw expects it next to zigsaw.exe. zigsaw-shimw
    // is the same program built as a GUI one, for GUI commands.
    for ([_]bool{ false, true }) |gui| {
        const shim = b.addExecutable(.{
            .name = if (gui) "zigsaw-shimw" else "zigsaw-shim",
            .root_module = shimModule(b, target, .ReleaseSmall, gui),
        });
        if (gui) shim.subsystem = .windows;
        b.installArtifact(shim);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zigsaw");
    run_step.dependOn(&run_cmd.step);

    // A driver for testing console events (Ctrl+C, closing the console); see
    // tests/ctrlc.sh. Installed under zig-out\test, away from zigsaw.exe.
    const ctrlc_mod = b.createModule(.{
        .root_source_file = b.path("tests/ctrlc.zig"),
        .target = target,
        .optimize = optimize,
    });
    ctrlc_mod.addImport("win32", b.createModule(.{
        .root_source_file = b.path("src/win32.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const ctrlc = b.addExecutable(.{ .name = "zigsaw-ctrlc", .root_module = ctrlc_mod });
    const ctrlc_step = b.step("ctrlc-driver", "Build the console-event test driver used by tests/ctrlc.sh");
    ctrlc_step.dependOn(&b.addInstallArtifact(ctrlc, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);

    // Prints its arguments, for checking what reaches a program behind a
    // batch file; see tests/batch.sh. Also installed under zig-out\test.
    const argv = b.addExecutable(.{ .name = "zigsaw-argv", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/argv.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const argv_step = b.step("argv-echo", "Build the argument-echo program used by tests/batch.sh");
    argv_step.dependOn(&b.addInstallArtifact(argv, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);

    // Checks what Windows denies AppContainers, from inside one; see
    // tests/matrix.sh and docs/findings.md. Also installed under zig-out\test.
    const acprobe_mod = b.createModule(.{
        .root_source_file = b.path("tests/acprobe.zig"),
        .target = target,
        .optimize = optimize,
    });
    acprobe_mod.addImport("win32", b.createModule(.{
        .root_source_file = b.path("src/win32.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const acprobe = b.addExecutable(.{ .name = "zigsaw-acprobe", .root_module = acprobe_mod });
    const acprobe_step = b.step("acprobe", "Build the AppContainer probe used by tests/matrix.sh");
    acprobe_step.dependOn(&b.addInstallArtifact(acprobe, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);

    // A GUI program that records how it was started and exits with the code
    // it's given, for the GUI shim; see tests/shims.sh. Also installed under
    // zig-out\test.
    const gui_fixture = b.addExecutable(.{ .name = "zigsaw-gui", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/gui.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    gui_fixture.subsystem = .windows;
    const gui_step = b.step("gui-fixture", "Build the GUI test program used by tests/shims.sh");
    gui_step.dependOn(&b.addInstallArtifact(gui_fixture, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);

    // Counts imports the loader wouldn't bind, in Rust programs GNU ld links;
    // see tests/build.sh and tests/published.sh. Also installed under
    // zig-out\test.
    const imports = b.addExecutable(.{ .name = "zigsaw-imports", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/imports.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const imports_step = b.step("imports", "Build the import checker used by tests/build.sh and tests/published.sh");
    imports_step.dependOn(&b.addInstallArtifact(imports, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = zigsawModule(b, target, optimize) })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = shimModule(b, target, optimize, true) })).step);
}

fn shimModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, gui: bool) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/shim.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (optimize == .ReleaseSmall) true else null,
    });
    const options = b.addOptions();
    options.addOption(bool, "gui", gui);
    mod.addOptions("options", options);
    return mod;
}

fn zigsawModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // AppContainer profiles live in userenv; ACL editing lives in advapi32.
    mod.linkSystemLibrary("userenv", .{});
    mod.linkSystemLibrary("advapi32", .{});
    // Start menu shortcuts are COM objects (ole32), in the user's Programs
    // folder (shell32).
    mod.linkSystemLibrary("ole32", .{});
    mod.linkSystemLibrary("shell32", .{});
    return mod;
}
