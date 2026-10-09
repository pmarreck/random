//! Test-only ABI: external MPFR checks the actual compiled candidate, not a port.
const fx = @import("fixed");
const zig = @import("candidate");
const workload = @import("ziggurat_workload.zig");
const Pair = extern struct { m: i64, e: i32 };
const core = @import("randomz");

/// Historical zero-atom witness; deliberately separate from the new production ABI.
pub export fn experiment_box_normal(fill: core.FillFn, ctx: ?*anyopaque, mean: Pair, sigma: Pair, out: *Pair) c_int {
    var first: [4]u8 = undefined;
    var second: [4]u8 = undefined;
    if (fill(ctx, &first, 4) != 0 or fill(ctx, &second, 4) != 0) return 2;
    const std = @import("std");
    const n = std.mem.readInt(u32, &first, .big);
    const first_uniform = fx.div(fx.fromInt(if (n == 0) 1 else n), fx.fromInt(0x1_0000_0000));
    const second_uniform = fx.div(fx.fromInt(std.mem.readInt(u32, &second, .big)), fx.fromInt(0x1_0000_0000));
    const radius = fx.sqrt(fx.mul(fx.fromInt(-2), fx.ln(first_uniform)));
    const z = fx.mul(radius, fx.cosTurns(second_uniform));
    out.* = pair(fx.add(.{ .m = mean.m, .e = mean.e }, fx.mul(z, .{ .m = sigma.m, .e = sigma.e })));
    return 0;
}
fn pair(x: fx.Fixed) Pair {
    return .{ .m = x.m, .e = x.e };
}
pub export fn experiment_strip(i: u8, x: *Pair, y: *Pair, k: *u64) void {
    const strip = zig.tables.strips[i];
    x.* = pair(strip.x);
    y.* = pair(strip.y);
    k.* = strip.k;
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
/// Direct production sampler comparison, not the experimental composition.
pub export fn production_samples(seed: u64, op: u8, n: usize, out: [*]Pair) c_int {
    if (op > 3) return 1;
    var state = workload.Workload.init(seed) catch return 1;
    const mean = fx.parse("-0.25").?;
    const sigma = fx.parse("1.75").?;
    const first = core.Fixed{ .m = mean.m, .e = mean.e };
    const second = core.Fixed{ .m = sigma.m, .e = sigma.e };
    for (out[0..n]) |*x| {
        var value: core.Fixed = undefined;
        const status = switch (op) {
            0 => core.randomz_normal(workload.Workload.fill, &state, first, second, &value),
            1 => blk: {
                var integer: i64 = undefined;
                const status = core.randomz_normal_int(workload.Workload.fill, &state, 0, 255, &integer);
                if (status == 0) {
                    const v = fx.fromInt(integer);
                    value = .{ .m = v.m, .e = v.e };
                }
                break :blk status;
            },
            2 => core.randomz_log_normal(workload.Workload.fill, &state, first, second, &value),
            3 => blk: {
                const one = fx.fromInt(1);
                const three = fx.fromInt(3);
                break :blk core.randomz_beta(workload.Workload.fill, &state, .{ .m = one.m, .e = one.e }, .{ .m = three.m, .e = three.e }, &value);
            },
            else => unreachable,
        };
        if (status != 0) return status;
        x.* = .{ .m = value.m, .e = value.e };
    }
    return 0;
}
pub export fn experiment_checksum(algorithm: u8, op: u8, n: usize, seed: u64, format: bool) u64 {
    if (algorithm > 5 or op > 3) return 0;
    return workload.checksum(@enumFromInt(algorithm), @enumFromInt(op), n, seed, format) catch 0;
}
