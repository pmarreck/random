//! Matched workloads. Box–Muller is now a frozen historical experimental control;
//! candidate normal draws feed the same fixed-point distribution formulas.
const std = @import("std");
const fx = @import("fixed");
const core = @import("randomz");
const candidate = @import("candidate");
const dispatcher = @import("fixed_simd");
pub const isAccelerated = dispatcher.isAccelerated;
pub const Algorithm = enum { box, paired, ziggurat, auto, scalar, simd };
pub const Operation = enum { normal, integer, lognormal, beta };
const one = fx.fromInt(1);
const half = fx.parse("0.5").?;
const mean = fx.parse("-0.25").?;
const sigma = fx.parse("1.75").?;

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
        if (self.spare) |x| {
            self.spare = null;
            return x;
        }
        const r = fx.sqrt(fx.mul(fx.fromInt(-2), fx.ln(try self.nonzero())));
        const u = try self.uniform();
        if (algorithm == .box) return fx.mul(r, fx.cosTurns(u));
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
        if (algorithm == .auto or algorithm == .scalar or algorithm == .simd) return error.BatchIntegerOnly;
        // Historical control only. Production intentionally has no legacy sampler.
        if (algorithm == .box and op == .integer) {
            while (true) {
                var n1: i64 = undefined;
                var n2: i64 = undefined;
                if (core.randomz_range(fill, self, 1, 1_000_000, &n1) != 0 or
                    core.randomz_range(fill, self, 1, 1_000_000, &n2) != 0) return error.Source;
                const first_uniform = fx.div(fx.fromInt(n1), fx.fromInt(1_000_000));
                const second_uniform = fx.div(fx.fromInt(n2), fx.fromInt(1_000_000));
                const z = fx.mul(fx.sqrt(fx.mul(fx.fromInt(-2), fx.ln(first_uniform))), fx.cosTurns(second_uniform));
                const x = fx.add(fx.mul(z, fx.parse("42.5").?), fx.parse("127.5").?);
                const rounded = fx.toIntTrunc(if (x.m < 0) fx.sub(x, half) else fx.add(x, half));
                if (rounded >= 0 and rounded <= 255) return fx.fromInt(rounded);
            }
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

fn fold(sum: *u64, x: fx.Fixed, format: bool) !void {
    if (format) {
        var buffer: [512]u8 = undefined;
        const text = try fx.toString(x, 19, &buffer);
        for (text) |byte| sum.* = std.math.rotl(u64, sum.*, 7) +% byte;
    } else {
        sum.* = std.math.rotl(u64, sum.*, 7) +% @as(u64, @bitCast(x.m)) +% @as(u64, @bitCast(@as(i64, x.e)));
    }
}

pub fn checksum(algorithm: Algorithm, op: Operation, count: usize, seed: u64, format: bool) !u64 {
    if ((algorithm == .auto or algorithm == .scalar or algorithm == .simd) and op != .integer) return error.BatchIntegerOnly;
    var workload = try Workload.init(seed);
    var sum: u64 = 0;
    if (algorithm == .auto or algorithm == .scalar or algorithm == .simd) {
        // The actual production batch ABI, with caller-owned bounded storage.
        // AUTO currently keeps scalar; SIMD explicitly selects the dispatcher.
        var values: [1024]i64 = undefined;
        var remaining = count;
        while (remaining != 0) {
            const n = @min(remaining, values.len);
            var written: usize = 0;
            const mode: c_int = switch (algorithm) {
                .auto => 0,
                .scalar => 1,
                .simd => 2,
                else => unreachable,
            };
            if (core.randomz_normal_int_batch(Workload.fill, &workload, 0, 255, &values, n, &written, mode) != 0 or written != n) return error.ProductionBatch;
            for (values[0..n]) |value| try fold(&sum, fx.fromInt(value), format);
            remaining -= n;
        }
    } else {
        for (0..count) |_| try fold(&sum, try workload.sample(algorithm, op), format);
    }
    return sum;
}
