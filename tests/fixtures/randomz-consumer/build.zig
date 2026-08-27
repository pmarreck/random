const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const random = b.dependency("random", .{
        .target = target,
        .optimize = optimize,
    });
    const consumer = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "randomz", .module = random.module("randomz") },
            },
        }),
    });
    const run_consumer = b.addRunArtifact(consumer);
    const test_step = b.step("test", "Compile and run the downstream randomz consumer");
    test_step.dependOn(&run_consumer.step);
}
