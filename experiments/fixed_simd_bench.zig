//! Release-only scalar/SIMD comparison over identical runtime inputs.
const std = @import("std");
const fx = @import("fixed");
const simd = @import("candidate");

pub fn main(init: std.process.Init) !void {
	if (@import("builtin").mode != .ReleaseFast) return error.BenchmarkRequiresReleaseFast;
	const args = try init.minimal.args.toSlice(init.arena.allocator());
	if (args.len < 2 or args.len > 3) return error.ExpectedScalarOrVectorOperation;
	const verify = args.len == 3;
	if (verify and !std.mem.eql(u8, args[2], "--verify")) return error.UnknownOption;
	const vector = std.mem.startsWith(u8, args[1], "vector-");
	const scalar = std.mem.startsWith(u8, args[1], "scalar-");
	if (!vector and !scalar) return error.ExpectedScalarOrVectorOperation;
	const op = args[1][7..];
	if (!std.mem.eql(u8, op, "ln") and !std.mem.eql(u8, op, "cos") and
		!std.mem.eql(u8, op, "mul")) return error.UnknownOperation;
	const data = try init.arena.allocator().alloc(simd.Batch, 2048);
	for (data, 0..) |*batch, index| for (batch, 0..) |*x, lane| {
		// Same fixed input mixer as the Rust experiment, not an RNG implementation.
		const mixed = @as(u64, @intCast(index * 4 + lane)) *% 0x9e3779b97f4a7c15;
		const k: u32 = @truncate(mixed ^ (mixed >> 29));
		x.* = fx.fromInt(k | 1);
		x.e -= 32;
	};
	var checksum: u64 = 0;
	var buf: [4096]u8 = undefined;
	var writer = std.Io.File.stdout().writer(init.io, &buf);
	const repetitions: usize = if (verify) 1 else if (std.mem.eql(u8, op, "mul")) 4096 else 128;
	for (0..repetitions) |_| {
		for (data, 0..) |batch, idx| {
			var out: simd.Batch = undefined;
			if (vector) {
				out = if (std.mem.eql(u8, op, "ln")) simd.ln4(batch)
					else if (std.mem.eql(u8, op, "cos")) simd.cos4(batch)
					else simd.mul4(batch, data[(idx + 1) % data.len]);
			} else {
				for (batch, &out, data[(idx + 1) % data.len]) |x, *y, z| {
					y.* = if (std.mem.eql(u8, op, "ln")) fx.ln(x)
						else if (std.mem.eql(u8, op, "cos")) fx.cosTurns(x)
						else fx.mul(x, z);
				}
			}
			std.mem.doNotOptimizeAway(out);
			for (out) |x| {
				if (verify) try writer.interface.print("{d} {d}\n", .{ x.m, x.e });
				checksum = std.math.rotl(u64, checksum, 7) +% @as(u64, @bitCast(x.m)) +% @as(u64, @bitCast(@as(i64, x.e)));
			}
		}
	}
	if (!verify) try writer.interface.print("{x}\n", .{checksum});
	try writer.interface.flush();
}
