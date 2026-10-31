const std = @import("std");

pub fn build(b: *std.Build) void {
    // For the x86-64 baseline, not for the CPU that builds: a build for the
    // builder's CPU differs from machine to machine, and uses instructions
    // other CPUs lack (v0.18.0, built on GitHub's runner, has AVX2 and SHA
    // instructions). Pulling zig takes about 3% longer than with a build for
    // this machine's CPU.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .windows },
    });
    const chosen = b.option(std.lang.Optimize, "optimize", "Prioritize performance, safety, or binary size (default: safe for zigsaw.exe, debug otherwise)");
    const optimize = chosen orelse .debug;

    // zigsaw compresses, hashes and unpacks layers of hundreds of MB, which
    // takes about 8 times as long in Debug: 74 s instead of 9 s to compress
    // zig's layer.
    // Debug information names the directory zigsaw was built in, so releases
    // leave it out: zigsaw.exe then builds the same anywhere.
    const strip = b.option(bool, "strip", "Omit debug information from zigsaw.exe, as releases do");
    const exe_mod = zigsawModule(b, target, chosen orelse .safe, strip);

    const exe = b.addExecutable(.{
        .name = "zigsaw",
        .root_module = exe_mod,
    });
    addWindowsResources(b, exe, "zigsaw");
    b.installArtifact(exe);

    // Copied to <store>\bin\<name>.exe for every exported command, so it is
    // always built small. zigsaw expects it next to zigsaw.exe. zigsaw-shimw
    // is the same program built as a GUI one, for GUI commands.
    for ([_]bool{ false, true }) |gui| {
        const shim = b.addExecutable(.{
            .name = if (gui) "zigsaw-shimw" else "zigsaw-shim",
            .root_module = shimModule(b, target, .small, gui),
        });
        if (gui) shim.subsystem = .windows;
        addWindowsResources(b, shim, if (gui) "zigsaw GUI command shim" else "zigsaw command shim");
        b.installArtifact(shim);
    }

    // Publishes an app's services from inside its AppContainer, from a copy
    // in the store; small too. zigsaw expects it next to zigsaw.exe.
    const relay = b.addExecutable(.{
        .name = "zigsaw-relay",
        .root_module = relayModule(b, target, .small),
    });
    addWindowsResources(b, relay, "zigsaw service relay");
    b.installArtifact(relay);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
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
    // What Windows lets AppContainers do on the loopback, and the test app
    // of tests/network.sh. Also installed under zig-out\test.
    const netprobe_mod = b.createModule(.{
        .root_source_file = b.path("tests/netprobe.zig"),
        .target = target,
        .optimize = optimize,
    });
    // net.zig brings win32.zig, which a file can't be in two modules for.
    netprobe_mod.addImport("net", b.createModule(.{
        .root_source_file = b.path("src/net.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const netprobe = b.addExecutable(.{ .name = "zigsaw-netprobe", .root_module = netprobe_mod });
    const netprobe_step = b.step("netprobe", "Build the network probe used by tests/network.sh");
    netprobe_step.dependOn(&b.addInstallArtifact(netprobe, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);
    const acprobe_step = b.step("acprobe", "Build the AppContainer probe used by tests/matrix.sh");
    acprobe_step.dependOn(&b.addInstallArtifact(acprobe, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);

    // Asks Windows where the user's folders are and what the registry allows,
    // as desktop programs do; see docs/findings.md. Also installed under
    // zig-out\test.
    const hostprobe_mod = b.createModule(.{
        .root_source_file = b.path("tests/hostprobe.zig"),
        .target = target,
        .optimize = optimize,
    });
    hostprobe_mod.addImport("win32", b.createModule(.{
        .root_source_file = b.path("src/win32.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const hostprobe = b.addExecutable(.{ .name = "zigsaw-hostprobe", .root_module = hostprobe_mod });
    const hostprobe_step = b.step("hostprobe", "Build the known-folder and registry probe");
    hostprobe_step.dependOn(&b.addInstallArtifact(hostprobe, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);

    // What keeping an app's registry settings with its data needs: an app
    // hive, and keys that low-integrity and AppContainer runs may write
    // (docs/findings.md). Also installed under zig-out\test.
    const regprobe_mod = b.createModule(.{
        .root_source_file = b.path("tests/regprobe.zig"),
        .target = target,
        .optimize = optimize,
    });
    regprobe_mod.addImport("win32", b.createModule(.{
        .root_source_file = b.path("src/win32.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const regprobe = b.addExecutable(.{ .name = "zigsaw-regprobe", .root_module = regprobe_mod });
    const regprobe_step = b.step("regprobe", "Build the registry probe");
    regprobe_step.dependOn(&b.addInstallArtifact(regprobe, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);

    // Waits for a window by its title, and closes it; see tests/guiapps.sh.
    // Also installed under zig-out\test.
    const winwait = b.addExecutable(.{ .name = "zigsaw-winwait", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/winwait.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const winwait_step = b.step("winwait", "Build the window waiter used by tests/guiapps.sh");
    winwait_step.dependOn(&b.addInstallArtifact(winwait, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);

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

    // A Docker credential helper that answers from environment variables;
    // see tests/registry.sh. Installed under zig-out\test by the name Docker
    // looks for, docker-credential-<name>.
    const cred_helper = b.addExecutable(.{ .name = "docker-credential-zigsaw-test", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/credhelper.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const cred_helper_step = b.step("cred-helper", "Build the Docker credential helper used by tests/registry.sh");
    cred_helper_step.dependOn(&b.addInstallArtifact(cred_helper, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = zigsawModule(b, target, optimize, null) })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = shimModule(b, target, optimize, true) })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = relayModule(b, target, optimize) })).step);
}

fn relayModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/relay.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (optimize == .small) true else null,
    });
}

/// Version information, which Explorer shows in the file's properties, and an
/// application manifest (src/windows/): programs without either look more
/// like malware to antivirus heuristics (docs/findings.md). Task Manager
/// names a process by its description, so it's short.
fn addWindowsResources(b: *std.Build, exe: *std.Build.Step.Compile, description: []const u8) void {
    const version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch @panic("build.zig.zon's version isn't x.y.z");
    exe.root_module.addWin32ResourceFile(.{
        .file = b.path("src/windows/zigsaw.rc"),
        .flags = &.{
            "/:auto-includes", // no headers: see zigsaw.rc
            "none",
            b.fmt("/dZIGSAW_VERSION=\"{d}.{d}.{d}\"", .{ version.major, version.minor, version.patch }),
            b.fmt("/dZIGSAW_VERSION_NUMBERS={d},{d},{d},0", .{ version.major, version.minor, version.patch }),
            b.fmt("/dZIGSAW_DESCRIPTION=\"{s}\"", .{description}),
            b.fmt("/dZIGSAW_FILE_NAME=\"{s}.exe\"", .{exe.name}),
        },
    });
    exe.win32_manifest = b.path("src/windows/zigsaw.manifest");
}

fn shimModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, gui: bool) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/shim.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (optimize == .small) true else null,
    });
    const options = b.addOptions();
    options.addOption(bool, "gui", gui);
    mod.addOptions("options", options);
    return mod;
}

fn zigsawModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, strip: ?bool) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    // What `zigsaw version` prints: the package's version.
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    mod.addOptions("options", options);
    // eStargz layers (see format.zig).
    const stargazer = b.dependency("stargazer", .{ .target = target, .optimize = optimize });
    mod.addImport("stargazer", stargazer.module("stargazer"));
    // AppContainer profiles live in userenv; ACL editing lives in advapi32.
    mod.linkSystemLibrary("userenv", .{});
    mod.linkSystemLibrary("advapi32", .{});
    // Start menu shortcuts are COM objects (ole32), in the user's Programs
    // folder (shell32).
    mod.linkSystemLibrary("ole32", .{});
    mod.linkSystemLibrary("shell32", .{});
    return mod;
}
