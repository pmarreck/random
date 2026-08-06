//! WASI adapter for the pure randomz core.
//!
//! Deterministic exports come from `randomz`; this adapter adds the host's
//! `wasi_snapshot_preview1.random_get` CSPRNG as an explicit, fail-closed byte
//! source. Browser hosts should satisfy the WASI import with Web Crypto rather
//! than substituting an insecure generator.

const std = @import("std");
const randomz = @import("randomz");

comptime {
    // Importing the module makes its `export fn` C ABI part of this artifact.
    _ = randomz;
}

/// Fill exactly `count` bytes from the WASI host CSPRNG. This mirrors a
/// randomz_fill_fn but is directly callable by a WebAssembly host.
export fn randomz_wasi_fill(out: ?[*]u8, count: usize) callconv(.c) c_int {
    if (count == 0) return @intFromEnum(randomz.Status.ok);
    const target = out orelse return @intFromEnum(randomz.Status.invalid_argument);
    while (true) switch (std.os.wasi.random_get(target, count)) {
        .SUCCESS => return @intFromEnum(randomz.Status.ok),
        .INTR => continue,
        else => return @intFromEnum(randomz.Status.entropy_error),
    };
}
