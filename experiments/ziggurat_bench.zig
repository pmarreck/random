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
	try w.print("\"batch_accelerated\":{},\"rows\":[", .{algorithm == .auto and workload.isAccelerated()});
	var first = true;
	while (sizes.next()) |text| {
		const n = try std.fmt.parseInt(usize, text, 10);
		if (n == 0) return error.EmptyWork;
		const expected = try std.fmt.parseInt(u64, checksums.next() orelse return error.MissingWorkOracle, 10);
		for (0..2) |_| if (try workload.checksum(algorithm, op, n, seed, format) != expected) return error.IncorrectWarmup;
		var cpu: [7]u64 = undefined;
		var wall: [7]u64 = undefined;
		for (&cpu, &wall) |*ct, *wt| {
			const w0 = try clock(.wall); const c0 = try clock(.cpu);
			const actual = try workload.checksum(algorithm, op, n, seed, format);
			const c1 = try clock(.cpu); const w1 = try clock(.wall);
			if (actual != expected) return error.IncorrectWork;
			if (c1 <= c0 or w1 <= w0) return error.Clock;
			ct.* = c1 - c0; wt.* = w1 - w0;
		}
		if (!first) try w.writeByte(',');
		first = false;
		try w.print("{{\"size\":{d},\"checksum\":\"{x}\",\"samples\":{{\"cpu_ns\":[", .{n, expected});
		for (cpu, 0..) |v, i| { if (i != 0) try w.writeByte(','); try w.print("{d}", .{v}); }
		try w.writeAll("],\"wall_ns\":[");
		for (wall, 0..) |v, i| { if (i != 0) try w.writeByte(','); try w.print("{d}", .{v}); }
		try w.writeAll("]}}");
	}
	if (checksums.next() != null) return error.UnusedWorkOracle;
	try w.writeAll("]}\n");
	try w.flush();
}
