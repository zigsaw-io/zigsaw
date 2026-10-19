// A project for tests/zls.sh: main.zig imports a module that only this file
// names, which ZLS learns by running it.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const greet = b.addModule("greet", .{ .root_source_file = b.path("greet.zig") });
    const exe = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "greet", .module = greet }},
        }),
    });
    b.installArtifact(exe);
}
