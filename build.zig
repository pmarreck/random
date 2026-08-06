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

    // Pure RNG/distribution core and its C ABI. Callers own the DRBG state and
    // supply entropy through a callback; this module performs no I/O.
    const randomz_mod = b.createModule(.{
        .root_source_file = b.path("src/randomz.zig"),
        .target = target,
        .optimize = optimize,
        // A public static C library must link into the PIE executables emitted
        // by default on modern Unix toolchains, not only into randomz itself.
        .pic = true,
        .imports = &.{
            .{ .name = "fixed", .module = fixed_mod },
        },
    });
    const randomz_lib = b.addLibrary(.{
        .name = "randomz",
        .linkage = .static,
        .root_module = randomz_mod,
    });
    b.installArtifact(randomz_lib);
    b.installFile("include/randomz.h", "include/randomz.h");
    b.installFile("LICENSE", "share/licenses/random/LICENSE");
    b.installFile("tests/random_test", "tests/random_test");
    b.installFile("tests/cli_test_setup.sh", "tests/cli_test_setup.sh");

    // The command-line frontend is deliberately C-only and can reach the Zig
    // implementation only through the installed public ABI. This executable
    // therefore dogfoods exactly the boundary available to downstream users.
    const cli_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_mod.addIncludePath(b.path("include"));
    const cli_c_flags: []const []const u8 = if (optimize == .Debug)
        &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DRANDOMZ_DEBUG_BUILD=1" }
    else
        &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" };
    cli_mod.addCSourceFile(.{
        .file = b.path("src/randomz_cli.c"),
        .flags = cli_c_flags,
    });
    cli_mod.addCSourceFile(.{
        .file = b.path("src/distribution_view.c"),
        .flags = cli_c_flags,
    });
    cli_mod.linkLibrary(randomz_lib);
    if (target.result.os.tag == .windows) {
        cli_mod.linkSystemLibrary("bcrypt", .{});
    }
    const cli = b.addExecutable(.{
        .name = "randomz",
        .root_module = cli_mod,
    });
    b.installArtifact(cli);
    // Zig's portable install steps copy rather than symlink. The package
    // derivation replaces these aliases with symlinks on Unix; keeping the
    // aliases here also makes argv[0] dispatch available on Windows.
    const normal_alias = if (target.result.os.tag == .windows) "nrandomz.exe" else "nrandomz";
    const deterministic_alias = if (target.result.os.tag == .windows) "drandomz.exe" else "drandomz";
    b.getInstallStep().dependOn(&b.addInstallBinFile(cli.getEmittedBin(), normal_alias).step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(cli.getEmittedBin(), deterministic_alias).step);

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
    const fixed_test_mod = b.createModule(.{
        .root_source_file = b.path("src/fixed.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const randomz_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/randomz.zig"),
            .target = target,
            .optimize = test_optimize,
            .imports = &.{
                .{ .name = "fixed", .module = fixed_test_mod },
            },
        }),
    });
    const run_randomz_unit_tests = b.addRunArtifact(randomz_unit_tests);
    const test_step = b.step("test", "Run Zig unit tests (ReleaseSafe)");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_randomz_unit_tests.step);
}
