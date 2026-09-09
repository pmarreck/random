//! Checked sampler-domain boundary and portable CPU dispatch.
const std = @import("std");
const builtin = @import("builtin");
const fx = @import("fixed");
const vector = @import("fixed_vector");
pub const Batch = [4]fx.Fixed;
pub const Results = struct { ln: Batch, cos: Batch };
pub const Error = error{UnsupportedDomain};

var detected = std.atomic.Value(u8).init(0);
const CpuLeaf = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };
fn cpuid(leaf: u32) CpuLeaf {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf),
          [_] "{ecx}" (@as(u32, 0)),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}
fn detectAvx2() bool {
    if (cpuid(0).eax < 7) return false;
    // Include the SSE dependencies enabled by Zig's baseline+avx2 target.
    const required = (1 << 0) | (1 << 9) | (1 << 19) | (1 << 20) |
        (1 << 26) | (1 << 27) | (1 << 28);
    if ((cpuid(1).ecx & required) != required) return false;
    const xcr0 = asm volatile ("xgetbv"
        : [_] "={eax}" (-> u32),
        : [_] "{ecx}" (@as(u32, 0)),
        : .{ .edx = true });
    return (xcr0 & 6) == 6 and (cpuid(7).ebx & (1 << 5)) != 0;
}
/// Cache machine capability, never random state. Require OS XMM/YMM state
/// saving as well as CPUID before entering the AVX2-targeted module.
pub fn isAccelerated() bool {
    if (comptime builtin.cpu.arch != .x86_64) return false;
    const cached = detected.load(.monotonic);
    if (cached != 0) return cached == 2;
    const yes = detectAvx2();
    detected.store(if (yes) 2 else 1, .monotonic);
    return yes;
}
fn validLane(x: fx.Fixed, zero: bool) bool {
    if (x.m == 0) return zero and x.e == 0;
    return x.m >= fx.TWO62 and x.e >= -64 and
        (x.e < 0 or (x.e == 0 and x.m == fx.TWO62));
}
fn validate(xs: Batch, ys: Batch) Error!void {
    for (xs, ys) |x, y| if (!validLane(x, false) or !validLane(y, true)) return error.UnsupportedDomain;
}
/// Four independently evaluated lanes; no stream position or rejection state.
pub fn lnCos4(xs: Batch, ys: Batch) Error!Results {
    try validate(xs, ys);
    if (isAccelerated()) return .{ .ln = vector.ln4(xs), .cos = vector.cos4(ys) };
    return scalarUnchecked(xs, ys);
}
pub fn lnCos4Scalar(xs: Batch, ys: Batch) Error!Results {
    try validate(xs, ys);
    return scalarUnchecked(xs, ys);
}
fn scalarUnchecked(xs: Batch, ys: Batch) Results {
    var result: Results = undefined;
    for (xs, ys, 0..) |x, y, lane| {
        result.ln[lane] = fx.ln(x);
        result.cos[lane] = fx.cosTurns(y);
    }
    return result;
}

test "sampler lanes match scalar exact pairs including endpoints and quadrants" {
    const xs: Batch = .{ fx.fromInt(1), fx.div(fx.fromInt(1), fx.fromInt(1000000)), fx.div(fx.fromInt(1), fx.fromInt(2)), .{ .m = @intCast(fx.TWO62), .e = -64 } };
    const ys: Batch = .{ fx.fromInt(0), fx.div(fx.fromInt(1), fx.fromInt(4)), fx.div(fx.fromInt(3), fx.fromInt(4)), fx.fromInt(1) };
    const actual = try lnCos4(xs, ys);
    const scalar = try lnCos4Scalar(xs, ys);
    for (xs, ys, 0..) |x, y, lane| {
        try std.testing.expectEqualDeep(fx.ln(x), actual.ln[lane]);
        try std.testing.expectEqualDeep(fx.cosTurns(y), actual.cos[lane]);
    }
    try std.testing.expectEqualDeep(scalar, actual);
}

test "malformed and out-of-domain lanes fail before arithmetic" {
    const valid: Batch = @splat(fx.fromInt(1));
    const invalid = [_]fx.Fixed{ fx.fromInt(-1), fx.fromInt(2), .{ .m = 1, .e = 0 }, .{ .m = 0, .e = 1 }, .{ .m = @intCast(fx.TWO62), .e = -65 }, .{ .m = std.math.minInt(i64), .e = 0 }, .{ .m = @intCast(fx.TWO62), .e = std.math.maxInt(i32) } };
    for (invalid) |x| {
        for (0..4) |lane| {
            var bad = valid;
            bad[lane] = x;
            try std.testing.expectError(error.UnsupportedDomain, lnCos4(bad, valid));
            try std.testing.expectError(error.UnsupportedDomain, lnCos4(valid, bad));
            try std.testing.expectError(error.UnsupportedDomain, lnCos4Scalar(bad, valid));
        }
    }
    try std.testing.expectError(error.UnsupportedDomain, lnCos4(@splat(fx.fromInt(0)), valid));
}

test "ten thousand mixed sampler batches equal scalar pairs" {
    var mixer: u64 = 0x082efa98ec4e6c89;
    for (0..10000) |_| {
        var xs: Batch = undefined;
        var ys: Batch = undefined;
        for (&xs, &ys) |*x, *y| {
            mixer = mixer *% 0xd1342543de82ef95 +% 1;
            x.* = fx.div(fx.fromInt(@intCast(mixer % 1000000 + 1)), fx.fromInt(1000000));
            mixer = mixer *% 0xd1342543de82ef95 +% 1;
            y.* = fx.div(fx.fromInt(@intCast(mixer % 1000000 + 1)), fx.fromInt(1000000));
        }
        try std.testing.expectEqualDeep(try lnCos4Scalar(xs, ys), try lnCos4(xs, ys));
    }
}
