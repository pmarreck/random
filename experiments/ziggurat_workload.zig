//! Matched experimental workloads. Box–Muller calls the real production C ABI;
//! candidate normal draws feed the same fixed-point distribution formulas.
const std = @import("std");
const fx = @import("fixed");
const core = @import("randomz");
const candidate = @import("candidate");
pub const Algorithm = enum { box, paired, ziggurat };
pub const Operation = enum { normal, integer, lognormal, beta };
const one = fx.fromInt(1);
const half = fx.parse("0.5").?;
const mean = fx.parse("-0.25").?;
const sigma = fx.parse("1.75").?;
fn abi(x: fx.Fixed) core.Fixed { return .{ .m = x.m, .e = x.e }; }

pub const Workload = struct {
	state: core.BufferedDrbg,
	spare: ?fx.Fixed = null,
	pub fn init(seed: u64) !@This() {
		var bytes = [_]u8{0} ** 32;
		std.mem.writeInt(u64, bytes[24..32], seed, .big);
		var result: @This() = undefined;
		if (core.randomz_buffered_drbg_init(&result.state, &bytes) != 0) return error.SourceInit;
		result.spare = null;
		return result;
	}
	pub fn fill(context: ?*anyopaque, out: [*]u8, n: usize) callconv(.c) c_int {
		const self: *@This() = @ptrCast(@alignCast(context.?));
		return core.randomz_buffered_drbg_fill(&self.state, out, n);
	}
	pub fn next(self: *@This()) !u64 {
		var out: [8]u8 = undefined;
		if (fill(self, &out, 8) != 0) return error.Source;
		return std.mem.readInt(u64, &out, .big);
	}
	fn uniform(self: *@This()) !fx.Fixed {
		var out: [4]u8 = undefined;
		if (fill(self, &out, 4) != 0) return error.Source;
		return fx.div(fx.fromInt(std.mem.readInt(u32, &out, .big)), fx.fromInt(0x1_0000_0000));
	}
	fn nonzero(self: *@This()) !fx.Fixed {
		const u = try self.uniform();
		return if (u.m == 0) fx.norm(1, 30) else u;
	}
	fn standard(self: *@This(), algorithm: Algorithm) !fx.Fixed {
		if (algorithm == .ziggurat) return candidate.normal(self);
		if (self.spare) |x| { self.spare = null; return x; }
		const r = fx.sqrt(fx.mul(fx.fromInt(-2), fx.ln(try self.nonzero())));
		const u = try self.uniform();
		// Cosine of a quarter-turn shift gives the paired sine output.
		self.spare = fx.mul(r, fx.cosTurns(fx.sub(u, fx.parse("0.25").?)));
		return fx.mul(r, fx.cosTurns(u));
	}
	fn gamma(self: *@This(), algorithm: Algorithm, alpha: fx.Fixed) anyerror!fx.Fixed {
		if (fx.cmp(alpha, one) < 0) {
			const u = try self.nonzero();
			const g = try self.gamma(algorithm, fx.add(one, alpha));
			return fx.mul(g, fx.pow(u, fx.div(one, alpha)));
		}
		const d = fx.sub(alpha, fx.div(one, fx.fromInt(3)));
		const scale = fx.div(one, fx.sqrt(fx.mul(fx.fromInt(9), d)));
		while (true) {
			const x = try self.standard(algorithm);
			const v = fx.add(one, fx.mul(scale, x));
			if (v.m <= 0) continue;
			const v3 = fx.mul(fx.mul(v, v), v);
			const u = try self.uniform();
			const x2 = fx.mul(x, x);
			const quick = fx.sub(one, fx.mul(fx.parse("0.0331").?, fx.mul(x2, x2)));
			if (fx.cmp(u, quick) < 0) return fx.mul(d, v3);
			if (u.m != 0) {
				const correction = fx.add(fx.sub(one, v3), fx.ln(v3));
				if (fx.cmp(fx.ln(u), fx.add(fx.mul(half, x2), fx.mul(d, correction))) < 0)
					return fx.mul(d, v3);
			}
		}
	}
	pub fn sample(self: *@This(), algorithm: Algorithm, op: Operation) !fx.Fixed {
		if (algorithm == .box) {
			var out: core.Fixed = undefined;
			const status = switch (op) {
				.normal => core.randomz_normal(fill, self, abi(mean), abi(sigma), &out),
				.lognormal => core.randomz_log_normal(fill, self, abi(mean), abi(sigma), &out),
				.beta => core.randomz_beta(fill, self, abi(one), abi(fx.fromInt(3)), &out),
				.integer => blk: {
					var n: i64 = undefined;
					const s = core.randomz_normal_int(fill, self, 0, 255, &n);
					out = abi(fx.fromInt(n));
					break :blk s;
				},
			};
			if (status != 0) return error.ProductionSample;
			return .{ .m = out.m, .e = out.e };
		}
		if (op == .beta) {
			const x = try self.gamma(algorithm, one);
			const y = try self.gamma(algorithm, fx.fromInt(3));
			return fx.div(x, fx.add(x, y));
		}
		while (true) {
			const z = try self.standard(algorithm);
			if (op == .integer) {
				const x = fx.add(fx.mul(z, fx.parse("42.5").?), fx.parse("127.5").?);
				const rounded = fx.toIntTrunc(if (x.m < 0) fx.sub(x, half) else fx.add(x, half));
				if (rounded < 0 or rounded > 255) continue;
				return fx.fromInt(rounded);
			}
			const x = fx.add(mean, fx.mul(z, sigma));
			return if (op == .lognormal) fx.exp(x) else x;
		}
	}
};

pub fn checksum(algorithm: Algorithm, op: Operation, count: usize, seed: u64, format: bool) !u64 {
	var workload = try Workload.init(seed);
	var sum: u64 = 0;
	for (0..count) |_| {
		const x = try workload.sample(algorithm, op);
		if (format) {
			var buffer: [512]u8 = undefined;
			const text = try fx.toString(x, 19, &buffer);
			for (text) |byte| sum = std.math.rotl(u64, sum, 7) +% byte;
		} else {
			sum = std.math.rotl(u64, sum, 7) +% @as(u64, @bitCast(x.m)) +% @as(u64, @bitCast(@as(i64, x.e)));
		}
	}
	return sum;
}
