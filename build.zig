const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // NOT b.standardOptimizeOption(.{}) -- that defaults to Debug, and a debug
    // binary silently benchmarked is a documented way to lose hours here.
    // Shipped artifacts default to ReleaseFast; `-Doptimize=` still overrides.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    // Tests build ReleaseSafe regardless of the shipped mode, and deliberately
    // do NOT inherit `optimize`. A ReleaseFast test binary compiles out the
    // safety checks and therefore cannot observe UB -- fleet-wide floor since
    // 2026-07-01, after a ReleaseFast suite hid three real crashers in `rarz`
    // and a u32 underflow in `tiffz` that produced the right answer by
    // accident. Overridable for deliberate investigation only.
    const test_optimize = b.option(
        std.builtin.OptimizeMode,
        "test-optimize",
        "Optimization mode for tests (default: ReleaseSafe)",
    ) orelse .ReleaseSafe;

    // The pure kernel: no I/O, no allocation, no libm. Everything else depends
    // on this and nothing is allowed to make it impure.
    const fixed_mod = b.addModule("fixed", .{
        .root_source_file = b.path("src/fixed.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Differential driver. A TEST harness, not the CLI -- see its header. The
    // shipped `randomz` CLI (Task 9) is C and reaches the kernel only through
    // include/randomz.h, so that bypassing the FFI is inexpressible rather than
    // merely discouraged.
    const driver = b.addExecutable(.{
        .name = "differential-driver",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/differential_driver.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fixed", .module = fixed_mod },
            },
        }),
    });
    b.installArtifact(driver);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fixed.zig"),
            .target = target,
            .optimize = test_optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run Zig unit tests (ReleaseSafe)");
    test_step.dependOn(&run_unit_tests.step);
}
