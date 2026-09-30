const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .os_tag = .windows },
    });
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // AppContainer profiles live in userenv; ACL editing lives in advapi32.
    exe_mod.linkSystemLibrary("userenv", .{});
    exe_mod.linkSystemLibrary("advapi32", .{});

    const exe = b.addExecutable(.{
        .name = "zigsaw",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Copied to <store>\bin\<name>.exe for every exported command, so it is
    // always built small. zigsaw expects it next to zigsaw.exe.
    const shim_mod = b.createModule(.{
        .root_source_file = b.path("src/shim.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    b.installArtifact(b.addExecutable(.{
        .name = "zigsaw-shim",
        .root_module = shim_mod,
    }));

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zigsaw");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe_mod })).step);
    const shim_test_mod = b.createModule(.{
        .root_source_file = b.path("src/shim.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = shim_test_mod })).step);
}
