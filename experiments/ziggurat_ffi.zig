//! Test-only ABI: external MPFR checks the actual compiled candidate, not a port.
const fx = @import("fixed");
const zig = @import("candidate");
const workload = @import("ziggurat_workload.zig");
const Pair = extern struct { m: i64, e: i32 };
fn pair(x: fx.Fixed) Pair { return .{ .m = x.m, .e = x.e }; }
pub export fn experiment_strip(i: u8, x: *Pair, y: *Pair, k: *u64) void {
	const strip = zig.tables.strips[i];
	x.* = pair(strip.x); y.* = pair(strip.y); k.* = strip.k;
}
pub export fn experiment_math(op: u8, x: Pair, out: *Pair) void {
	const input = fx.Fixed{ .m = x.m, .e = x.e };
	out.* = pair(if (op == 0) fx.exp(input) else fx.ln(input));
}
const Words = struct {
	words: []const u64,
	i: usize = 0,
	pub fn next(self: *@This()) !u64 {
		if (self.i == self.words.len) return error.Exhausted;
		defer self.i += 1;
		return self.words[self.i];
	}
};
pub export fn experiment_words(words: [*]const u64, n: usize, used: *usize, out: *Pair) c_int {
	var source = Words{ .words = words[0..n] };
	defer used.* = source.i;
	out.* = pair(zig.normal(&source) catch return 1);
	return 0;
}
pub export fn experiment_samples(seed: u64, algorithm: u8, op: u8, n: usize, out: [*]Pair) c_int {
	if (algorithm > 2 or op > 3) return 1;
	var state = workload.Workload.init(seed) catch return 1;
	for (out[0..n]) |*x| x.* = pair(state.sample(@enumFromInt(algorithm), @enumFromInt(op)) catch return 1);
	return 0;
}
pub export fn experiment_checksum(algorithm: u8, op: u8, n: usize, seed: u64, format: bool) u64 {
	if (algorithm > 4 or op > 3) return 0;
	return workload.checksum(@enumFromInt(algorithm), @enumFromInt(op), n, seed, format) catch 0;
}
