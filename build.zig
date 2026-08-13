const std = @import("std");

pub fn build(b: *std.Build) void {
    // On a native macOS build, Zig stamps every object with the HOST SDK
    // version (e.g. 26.6). A C consumer that links our static librandomz.a at a
    // lower deployment target -- the nixpkgs apple-sdk floor is 14.0, which the
    // C-ABI conformance harness (tests/randomz_abi_test) links against -- then
    // trips ld's "object file was built for newer macOS version than being
    // linked" warning. Pin an explicit, reproducible macOS minimum so the
    // artifact's platform floor is a property of the project, not of whatever
    // SDK happens to sit on the build host. Only used when no -Dtarget was
    // given; explicit cross targets (incl. aarch64-macos) set their own.
    const default_target: std.Target.Query = if (@import("builtin").target.os.tag == .macos)
        .{ .os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } } }
    else
        .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });

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
    cli_mod.addCSourceFile(.{
        .file = b.path("src/state_json.c"),
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

    // A host-neutral WASI module: the deterministic C ABI remains the same,
    // while randomz_wasi_fill obtains nondeterministic bytes through WASI's
    // required random_get import. It is built independently of the requested
    // native/cross target so every package includes one portable .wasm artifact.
    const wasi_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });
    const wasi_fixed_mod = b.addModule("fixed-wasi", .{
        .root_source_file = b.path("src/fixed.zig"),
        .target = wasi_target,
        .optimize = optimize,
    });
    const wasi_randomz_mod = b.createModule(.{
        .root_source_file = b.path("src/randomz.zig"),
        .target = wasi_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fixed", .module = wasi_fixed_mod },
        },
    });
    const wasi_adapter_mod = b.createModule(.{
        .root_source_file = b.path("src/randomz_wasi.zig"),
        .target = wasi_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "randomz", .module = wasi_randomz_mod },
        },
    });
    const wasi = b.addExecutable(.{
        .name = "randomz-wasi",
        .root_module = wasi_adapter_mod,
    });
    wasi.entry = .disabled;
    wasi.export_memory = true;
    wasi.rdynamic = true;
    b.installArtifact(wasi);

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
