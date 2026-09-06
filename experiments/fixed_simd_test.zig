//! Exact existing scalar kernels are the oracle; no numerical tolerances.
const std = @import("std");
const fx = @import("fixed");
const simd = @import("candidate");

test "negative turns whose wrap rounds to quadrant four retain the scalar fallback" {
	for ([_]i32{ -60, -61, -62, -63, -64, -65, -1000 }) |exponent| {
		const xs: simd.Batch = .{
			.{ .m = -@as(i64, @intCast(fx.TWO62)), .e = exponent },
			.{ .m = -@as(i64, @intCast(fx.TWO62 + 1)), .e = exponent },
			.{ .m = -@as(i64, @intCast(fx.TWO62)), .e = -32 },
			fx.Fixed.zero,
		};
		const out = simd.cos4(xs);
		for (xs, out) |x, y| try std.testing.expectEqual(fx.cosTurns(x), y);
	}
}

test "SIMD arithmetic agrees for mixed signs, zeros, cancellation, and exponent gaps" {
	var prng = std.Random.DefaultPrng.init(0x700a);
	const rng = prng.random();
	for (0..10000) |n| {
		var a: simd.Batch = undefined;
		var b: simd.Batch = undefined;
		for (&a, &b, 0..) |*x, *y, lane| {
			const magnitude = fx.TWO62 | (rng.int(u64) >> 2);
			x.* = .{ .m = @intCast(magnitude), .e = @as(i32, @intCast(n % 129)) - 64 };
			y.* = .{ .m = @intCast(fx.TWO62 | (rng.int(u64) >> 2)), .e = -1 };
			if (n % 2 == 0) x.m = -x.m;
			if (lane % 2 == 0) y.m = -y.m;
			switch (n % 7) {
				0 => x.* = fx.Fixed.zero,
				1 => y.* = fx.Fixed.zero,
				2 => y.* = fx.neg(x.*),
				3 => y.* = .{ .m = -x.m + 1, .e = x.e },
				else => {},
			}
		}
		const products = simd.mul4(a, b);
		const sums = simd.add4(a, b);
		for (a, b, products, sums) |x, y, product, sum| {
			try std.testing.expectEqual(fx.mul(x, y), product);
			try std.testing.expectEqual(fx.add(x, y), sum);
		}
	}
}

test "SIMD logarithm and turns cosine preserve exact pairs including lane-divergent quadrants" {
	var prng = std.Random.DefaultPrng.init(0xdeadbeef);
	const rng = prng.random();
	for (0..10000) |n| {
		var positive: simd.Batch = undefined;
		var turns: simd.Batch = undefined;
		for (&positive, &turns, 0..) |*x, *y, lane| {
			const k = if (n < 32) @as(u32, 1) << @intCast(n) else rng.int(u32) | 1;
			x.* = fx.fromInt(k);
			x.e -= 32;
			y.* = fx.fromInt(if (n < 5) @as(u32, @intCast(lane)) << 30 else rng.int(u32));
			y.e -= 32;
			if (y.m == 0) y.e = 0;
			if (n % 3 == 0) y.* = fx.neg(y.*);
		}
		const logs = simd.ln4(positive);
		const cosines = simd.cos4(turns);
		for (positive, turns, logs, cosines) |x, y, logarithm, cosine| {
			try std.testing.expectEqual(fx.ln(x), logarithm);
			try std.testing.expectEqual(fx.cosTurns(y), cosine);
		}
	}
}
