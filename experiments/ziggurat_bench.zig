//! Shared performance-profile protocol: verified work, warmup, checked clocks.
const std = @import("std");
const workload = @import("ziggurat_workload.zig");
fn clock(kind: enum { cpu, wall }) !u64 {
    // The pinned std.c supplies each OS's clock IDs and timespec layout.
    var out: std.c.timespec = undefined;
    if (std.c.clock_gettime(if (kind == .cpu) .PROCESS_CPUTIME_ID else .MONOTONIC, &out) != 0) return error.Clock;
    if (out.sec < 0 or out.nsec < 0 or out.nsec >= 1_000_000_000) return error.Clock;
    return @as(u64, @intCast(out.sec)) * 1_000_000_000 + @as(u64, @intCast(out.nsec));
}
fn measureBatch(algorithm: workload.Algorithm, op: workload.Operation, n: usize, seed: u64, format: bool, oracle: u64) !struct { cpu: u64, wall: u64 } {
    var checks: [8]u64 = undefined;
    const w0 = try clock(.wall);
    const c0 = try clock(.cpu);
    for (&checks) |*sum| sum.* = try workload.checksum(algorithm, op, n, seed, format);
    const c1 = try clock(.cpu);
    const w1 = try clock(.wall);
    for (checks) |sum| if (sum != oracle) return error.IncorrectWork;
    if (c1 <= c0 or w1 <= w0) return error.Clock;
    return .{ .cpu = (c1 - c0) / 8, .wall = (w1 - w0) / 8 };
}
pub fn main(init: std.process.Init) !void {
    if (@import("builtin").mode != .ReleaseFast) return error.BenchmarkRequiresReleaseFast;
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.UnsupportedClockPlatform;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5) return error.ExpectedCaseSizesSeedIndependentChecksums;
    var fields = std.mem.splitScalar(u8, args[1], '-');
    const algorithm = std.meta.stringToEnum(workload.Algorithm, fields.next().?) orelse return error.Algorithm;
    const op = std.meta.stringToEnum(workload.Operation, fields.next().?) orelse return error.Operation;
    const format = std.mem.eql(u8, fields.next() orelse return error.Format, "format");
    _ = fields.next(); // core affinity is enforced by the shared runner, no hidden threads.
    const seed = try std.fmt.parseInt(u64, args[3], 10);
    var sizes = std.mem.splitScalar(u8, args[2], ',');
    var checksums = std.mem.splitScalar(u8, args[4], ',');
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const w = &writer.interface;
    try w.writeAll("{\"schema\":\"performance-measurement/v1\",\"correct\":true,\"build_mode\":\"ReleaseFast\",\"allocator_coverage\":\"no per-sample allocation; fixed DRBG, batch and formatting buffers\",\"clock\":\"clock_gettime process CPU and CLOCK_MONOTONIC, checked\",\"threads\":1,");
    try w.print("\"batch_accelerated\":{},\"rows\":[", .{algorithm == .simd and workload.isAccelerated()});
    var first = true;
    while (sizes.next()) |text| {
        const n = try std.fmt.parseInt(usize, text, 10);
        if (n == 0) return error.EmptyWork;
        const expected = try std.fmt.parseInt(u64, checksums.next() orelse return error.MissingWorkOracle, 10);
        for (0..2) |_| if (try workload.checksum(algorithm, op, n, seed, format) != expected) return error.IncorrectWarmup;
        const batching = algorithm == .auto or algorithm == .scalar or algorithm == .simd;
        const measured: workload.Algorithm = if (algorithm == .auto) .scalar else algorithm;
        const control: workload.Algorithm = if (measured == .simd) .scalar else .simd;
        if (batching) for (0..2) |_| {
            if (try workload.checksum(control, op, n, seed, format) != expected) return error.IncorrectWarmup;
        };
        var cpu: [24]u64 = undefined;
        var wall: [24]u64 = undefined;
        var control_cpu: [24]u64 = undefined;
        var control_wall: [24]u64 = undefined;
        const samples: usize = if (batching) 24 else 7;
        for (cpu[0..samples], wall[0..samples], 0..) |*ct, *wt, round| {
            if (batching) {
                // Balanced order within each process limits grouped-case drift.
                const first_algorithm: workload.Algorithm = if (round % 2 == 0) .scalar else .simd;
                const a = try measureBatch(first_algorithm, op, n, seed, format, expected);
                const b = try measureBatch(if (first_algorithm == .simd) .scalar else .simd, op, n, seed, format, expected);
                const selected = if (first_algorithm == measured) a else b;
                const other = if (first_algorithm == measured) b else a;
                ct.* = selected.cpu;
                wt.* = selected.wall;
                control_cpu[round] = other.cpu;
                control_wall[round] = other.wall;
            } else {
                const w0 = try clock(.wall);
                const c0 = try clock(.cpu);
                const actual = try workload.checksum(algorithm, op, n, seed, format);
                const c1 = try clock(.cpu);
                const w1 = try clock(.wall);
                if (actual != expected) return error.IncorrectWork;
                if (c1 <= c0 or w1 <= w0) return error.Clock;
                ct.* = c1 - c0;
                wt.* = w1 - w0;
            }
        }
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("{{\"size\":{d},\"checksum\":\"{x}\",\"samples\":{{\"cpu_ns\":[", .{ n, expected });
        for (cpu[0..samples], 0..) |v, i| {
            if (i != 0) try w.writeByte(',');
            try w.print("{d}", .{v});
        }
        try w.writeAll("],\"wall_ns\":[");
        for (wall[0..samples], 0..) |v, i| {
            if (i != 0) try w.writeByte(',');
            try w.print("{d}", .{v});
        }
        try w.writeAll("]}");
        if (batching) {
            try w.print(",\"paired_control\":{{\"mode\":\"{s}\",\"repetitions_per_sample\":8,\"balanced_pairs\":24,\"normalization\":\"duration / 8 fresh-state workloads; SCALAR first on even rounds\",\"cpu_ns\":[", .{@tagName(control)});
            for (control_cpu, 0..) |v, i| {
                if (i != 0) try w.writeByte(',');
                try w.print("{d}", .{v});
            }
            try w.writeAll("],\"wall_ns\":[");
            for (control_wall, 0..) |v, i| {
                if (i != 0) try w.writeByte(',');
                try w.print("{d}", .{v});
            }
            try w.writeAll("]}");
        }
        try w.writeByte('}');
    }
    if (checksums.next() != null) return error.UnusedWorkOracle;
    try w.writeAll("]}\n");
    try w.flush();
}
