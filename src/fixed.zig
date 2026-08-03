//! Integer-only normalized soft-float kernel — Zig port of `lib/fixed.lua`.
//!
//! Pure: no I/O, no allocation, no libm. The whole reason this exists is that
//! IEEE-754 pins down `+ - * / sqrt` and says essentially nothing about
//! transcendentals, so a program that calls the platform libm produces
//! different results on different machines. Measured glibc vs musl over this
//! program's own input domain: `log` differs on 0.006% of inputs, `cos` on
//! 3.06%, `exp` on 8.85%. `lib/fixed.lua` removed that dependency for the
//! LuaJIT implementation and `tests/cross_arch_diff` now proves the result is
//! byte-identical across x86_64-glibc, x86_64-musl, aarch64-Linux and native
//! aarch64-macOS. This port must inherit that property, not re-open it.
//!
//! REPRESENTATION, identical to lib/fixed.lua:
//!   value = m · 2^(e−62)
//!   m: i64, normalized so 2^62 ≤ |m| < 2^63 for every nonzero value
//!   canonical zero is exactly (0, 0)
//!   e: i32
//!
//! The i32 exponent is not incidental. The Lua reference has to `assert` that
//! exponents stay in i32 range — on both input and output, because an
//! out-of-contract input exponent could otherwise walk back into range through
//! the shift loops before any output check saw it. Here the type makes an
//! out-of-range exponent unrepresentable at the call site, so the input half of
//! that assert is enforced by the compiler.
//!
//! TRUNCATION TOWARD ZERO, everywhere, unconditionally: `@divTrunc`, never
//! `@divFloor`. They differ exactly on negative inexact operands, and the Lua
//! side carries pinned exact-value tests for that case precisely because a
//! floor-vs-truncate mutant passed its ENTIRE suite including the `bc` accuracy
//! sweep — for random operands the two error distributions are mathematically
//! identical, so no magnitude tolerance can separate them.
//!
//! ASSERTION POLICY: the reference uses Lua `assert`, which is always live.
//! Here the equivalent checks are `std.debug.assert`, which is compiled out in
//! ReleaseFast and active in ReleaseSafe — and the test suite builds
//! ReleaseSafe precisely so they are active where it matters. The kernel's
//! callers are all internal (the C CLI validates user input before it gets
//! here), so a shipped artifact that trusts its own callers is the right
//! trade; a contract violation is a bug in this repository, not a user error.
//!
//! Port status: Tasks 1–2 of docs/plans/2026-08-02-zig-port.md. `norm`,
//! `fromInt`, `mul128`, `mul`, `toIntTrunc`. `frac` is NOT here despite the
//! plan listing it under Task 2: `M.frac` is implemented in terms of `M.sub`,
//! which lands in Task 3, so it goes there with the function it depends on.
//! The rest arrives in Tasks 3–7, each verified against `lib/fixed.lua` by
//! tests/zig_differential as it lands.

const std = @import("std");

/// 2^62 — the lower bound of a normalized mantissa's magnitude.
pub const TWO62: u64 = 0x4000000000000000;
/// 2^61 — the threshold that decides `mul`'s 63-bit vs 62-bit renormalization.
pub const TWO61: u64 = 0x2000000000000000;
/// 2^53 — `toIntTrunc` clamps beyond this. The reference clamps here because
/// its result is a Lua number (an IEEE-754 double), which cannot represent
/// every integer past 2^53. The clamp is part of the documented contract, so it
/// is preserved here even though Zig's i64 return type would not require it.
pub const TO_INT_TRUNC_CLAMP: i64 = 9007199254740992;

/// Powers of two as i64, index 0..62. Built at comptime rather than computed
/// with a shift at the use site so the table is identical to the reference's.
const POW2 = blk: {
    var t: [63]i64 = undefined;
    // Shift rather than a running `p *= 2`: the accumulator form computes one
    // doubling PAST the last slot (2^63), which overflows i64 at comptime and
    // fails the build.
    for (&t, 0..) |*slot, i| slot.* = @as(i64, 1) << @intCast(i);
    break :blk t;
};

/// A normalized soft-float value: `m · 2^(e−62)`.
pub const Fixed = struct {
    m: i64,
    e: i32,

    pub const zero: Fixed = .{ .m = 0, .e = 0 };
};

/// Renormalizes an arbitrary (mantissa, exponent) pair into the canonical form
/// `2^62 ≤ |m| < 2^63`, shifting the mantissa and compensating the exponent.
/// Mirrors `lib/fixed.lua`'s `M.norm`, including its two edge behaviours:
/// a zero mantissa collapses to canonical zero `(0, 0)` regardless of the
/// incoming exponent, and `minInt(i64)` — whose magnitude is not representable
/// as a positive i64 — normalizes to `-2^62` with the exponent incremented.
///
/// The magnitude is taken with wrapping negation (`-%`) rather than `-` or
/// `@abs` on purpose: for `minInt(i64)` ordinary negation overflows (a panic in
/// ReleaseSafe), while wrapping negation reproduces the LuaJIT int64 cdata
/// behaviour the reference relies on — `-%minInt == minInt`, whose bit pattern
/// is 0x8000000000000000, which the second loop then halves back into range.
pub fn norm(m: i64, e: i32) Fixed {
    if (m == 0) return Fixed.zero;

    const neg = m < 0;
    var u: u64 = @bitCast(if (neg) -%m else m);
    var ee = e;

    if (u >= 0x8000000000000000) {
        // Magnitude reached the sign bit. Only reachable from minInt(i64),
        // whose wrapped magnitude is exactly 2^63.
        u >>= 1;
        ee += 1;
    } else if (u < TWO62) {
        // Single @clz shift replacing the reference's `u = u * 2` loop.
        // A normalized magnitude occupies exactly 63 bits, i.e. @clz(u) == 1;
        // u currently occupies 64 - @clz(u), so the deficit is @clz(u) - 1.
        // u != 0 here (handled above), so @clz(u) <= 63 and the shift is
        // in range for a u6. Equivalence with the loop is not assumed --
        // tests/zig_differential sweeps every shift distance including the
        // extremes against the reference.
        const sh: u6 = @intCast(@clz(u) - 1);
        u <<= sh;
        ee -= sh;
    }

    // u < 2^63 here, so this bitcast cannot produce a negative value.
    const r: i64 = @bitCast(u);
    return .{ .m = if (neg) -%r else r, .e = ee };
}

/// Converts an exact integer to normalized soft-float form.
/// Mirrors `lib/fixed.lua`'s `M.from_int`: zero maps to canonical zero, and
/// every other value is `norm(v, 62)` — 62 because the representation places
/// the binary point such that an integer `v` is `v · 2^(62−62)`.
pub fn fromInt(v: i64) Fixed {
    if (v == 0) return Fixed.zero;
    return norm(v, 62);
}

/// Full 64x64 -> 128 bit unsigned product, returned as (high, low) halves.
/// Zig has a native u128 so this is one multiply, where the reference has to
/// synthesize it from four 32-bit partials with explicit carry propagation.
/// The two must agree bit for bit; tests/zig_differential sweeps that rather
/// than taking it on faith, because carry propagation between the partials is
/// exactly where a hand-rolled version goes wrong.
pub fn mul128(a: u64, b: u64) struct { hi: u64, lo: u64 } {
    const p = @as(u128, a) * @as(u128, b);
    return .{ .hi = @truncate(p >> 64), .lo = @truncate(p) };
}

/// Multiplies two normalized soft-floats. Mirrors `lib/fixed.lua`'s `M.mul`.
///
/// Magnitudes are taken by WRAPPING negation rather than `-m`, matching the
/// reference's `0 - a` in u64: negating minInt(i64) in signed arithmetic is a
/// wraparound coincidence in LuaJIT and a panic in Zig's safe modes, so both
/// sides go through unsigned to stay bit-identical instead of trapping. (The
/// normalization assert rejects minInt anyway — its magnitude 2^63 is outside
/// the invariant — but neither implementation may depend on which check fires
/// first.)
///
/// The 128-bit product of two values in [2^62, 2^63) lands in [2^124, 2^126),
/// so exactly one of two renormalizations applies, selected on the high half.
pub fn mul(a: Fixed, b: Fixed) Fixed {
    if (a.m == 0 or b.m == 0) return Fixed.zero;

    const neg = (a.m < 0) != (b.m < 0);
    const ua: u64 = @bitCast(if (a.m < 0) -%a.m else a.m);
    const ub: u64 = @bitCast(if (b.m < 0) -%b.m else b.m);
    std.debug.assert(ua >= TWO62 and ua < 0x8000000000000000); // operand 1 normalized
    std.debug.assert(ub >= TWO62 and ub < 0x8000000000000000); // operand 2 normalized

    const p = mul128(ua, ub);
    var um: u64 = undefined;
    // Exponent arithmetic in i64 so the sum cannot overflow before it is
    // checked. The reference computes in doubles (which cannot overflow here)
    // and then asserts i32 range; doing the addition directly in i32 would
    // make the overflow itself the failure, ahead of the contract check.
    var es: i64 = @as(i64, a.e) + @as(i64, b.e);
    if (p.hi >= TWO61) {
        // Product >= 2^125: shift down 63.
        um = p.hi *% 2 + (p.lo >> 63);
        es += 1;
    } else {
        // Product in [2^124, 2^125): shift down 62.
        um = p.hi *% 4 + (p.lo >> 62);
    }
    std.debug.assert(es >= std.math.minInt(i32) and es <= std.math.maxInt(i32));

    const r: i64 = @bitCast(um);
    return .{ .m = if (neg) -%r else r, .e = @intCast(es) };
}

/// Truncates toward zero to an exact integer, clamping at ±2^53.
/// Mirrors `lib/fixed.lua`'s `M.to_int_trunc`, including the clamp — which
/// exists there because the reference returns a Lua number (a double) that
/// cannot represent every integer past 2^53. An audit found the reference
/// silently ROUNDING instead of clamping past that point (the true integer
/// 2^54+3 came back as 2^54+4), reachable from the CLI via a large `--mean`;
/// the fix compares the still-exact quotient against the threshold before any
/// conversion. Zig's i64 return would not need the clamp, but it is part of the
/// documented contract and the two implementations must agree.
///
/// `@divTrunc`, never `@divFloor`: they differ exactly on negative inexact
/// operands, and no magnitude tolerance can separate them.
pub fn toIntTrunc(x: Fixed) i64 {
    if (x.m == 0) return 0;
    // i64 arithmetic: `x.e - 62` would underflow i32 for a minInt exponent,
    // making the shift computation itself the failure.
    const sh: i64 = @as(i64, x.e) - 62;
    if (sh >= 0) return if (x.m < 0) -TO_INT_TRUNC_CLAMP else TO_INT_TRUNC_CLAMP;
    const s = -sh;
    if (s > 62) return 0;
    const q = @divTrunc(x.m, POW2[@intCast(s)]);
    if (q > TO_INT_TRUNC_CLAMP) return TO_INT_TRUNC_CLAMP;
    if (q < -TO_INT_TRUNC_CLAMP) return -TO_INT_TRUNC_CLAMP;
    return q;
}

test "mul128 agrees with a manual 32-bit partial synthesis" {
    // Independent check of the native u128 path against the shape the
    // reference uses, so this is not just the same expression twice.
    const cases = [_][2]u64{
        .{ 0, 0 },                     .{ 1, 1 },
        .{ 0xFFFFFFFFFFFFFFFF, 1 },    .{ 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF },
        .{ 0x8000000000000000, 2 },    .{ 0x4000000000000000, 0x4000000000000000 },
        .{ 0x123456789ABCDEF0, 0x0FEDCBA987654321 },
    };
    for (cases) |c| {
        const a = c[0];
        const b = c[1];
        const a0 = a & 0xFFFFFFFF;
        const a1 = a >> 32;
        const b0 = b & 0xFFFFFFFF;
        const b1 = b >> 32;
        const p00 = a0 *% b0;
        const p01 = a0 *% b1;
        const p10 = a1 *% b0;
        const p11 = a1 *% b1;
        const mid = (p00 >> 32) +% (p01 & 0xFFFFFFFF) +% (p10 & 0xFFFFFFFF);
        const lo = (p00 & 0xFFFFFFFF) +% (mid & 0xFFFFFFFF) *% 0x100000000;
        const hi = p11 +% (p01 >> 32) +% (p10 >> 32) +% (mid >> 32);
        const got = mul128(a, b);
        try std.testing.expectEqual(hi, got.hi);
        try std.testing.expectEqual(lo, got.lo);
    }
}

test "mul: 1 * x == x for representative x" {
    const one = fromInt(1);
    for ([_]i64{ 1, 2, 3, -1, -7, 1000003, -4503599627370496 }) |v| {
        const x = fromInt(v);
        const got = mul(one, x);
        try std.testing.expectEqual(x.m, got.m);
        try std.testing.expectEqual(x.e, got.e);
    }
}

test "mul: sign is the xor of operand signs" {
    const a = fromInt(6);
    const b = fromInt(7);
    try std.testing.expectEqual(@as(i64, 42), toIntTrunc(mul(a, b)));
    try std.testing.expectEqual(@as(i64, -42), toIntTrunc(mul(fromInt(-6), b)));
    try std.testing.expectEqual(@as(i64, -42), toIntTrunc(mul(a, fromInt(-7))));
    try std.testing.expectEqual(@as(i64, 42), toIntTrunc(mul(fromInt(-6), fromInt(-7))));
}

test "toIntTrunc: truncates toward zero, not toward negative infinity" {
    // The @divTrunc/@divFloor discriminator. 1.5 -> 1 and -1.5 -> -1;
    // @divFloor would give -2 for the second and pass every magnitude-based
    // accuracy check.
    const three = fromInt(3);
    const half = Fixed{ .m = @as(i64, @bitCast(TWO62)), .e = -1 }; // 0.5
    const one_and_half = mul(three, half);
    try std.testing.expectEqual(@as(i64, 1), toIntTrunc(one_and_half));
    try std.testing.expectEqual(@as(i64, -1), toIntTrunc(mul(fromInt(-3), half)));
}

test "toIntTrunc: clamps rather than rounds past 2^53" {
    const big = Fixed{ .m = @as(i64, @bitCast(TWO62)), .e = 200 };
    try std.testing.expectEqual(TO_INT_TRUNC_CLAMP, toIntTrunc(big));
    try std.testing.expectEqual(-TO_INT_TRUNC_CLAMP, toIntTrunc(.{ .m = -big.m, .e = 200 }));
    try std.testing.expectEqual(@as(i64, 0), toIntTrunc(.{ .m = @as(i64, @bitCast(TWO62)), .e = -100 }));
}

test "norm: canonical zero absorbs any exponent" {
    try std.testing.expectEqual(Fixed.zero, norm(0, 0));
    try std.testing.expectEqual(Fixed.zero, norm(0, 1234));
    try std.testing.expectEqual(Fixed.zero, norm(0, -1234));
}

test "norm: already-normalized values are unchanged" {
    const lo: i64 = @bitCast(TWO62);
    try std.testing.expectEqual(Fixed{ .m = lo, .e = 5 }, norm(lo, 5));
    try std.testing.expectEqual(Fixed{ .m = std.math.maxInt(i64), .e = -3 }, norm(std.math.maxInt(i64), -3));
}

test "norm: minInt(i64) normalizes to -2^62 with exponent incremented" {
    const r = norm(std.math.minInt(i64), 0);
    try std.testing.expectEqual(@as(i64, -4611686018427387904), r.m);
    try std.testing.expectEqual(@as(i32, 1), r.e);
}

test "fromInt: representative integers round to normalized form" {
    try std.testing.expectEqual(Fixed.zero, fromInt(0));
    // 1 == 2^62 · 2^(0−62)
    try std.testing.expectEqual(Fixed{ .m = @as(i64, @bitCast(TWO62)), .e = 0 }, fromInt(1));
    try std.testing.expectEqual(Fixed{ .m = -@as(i64, @bitCast(TWO62)), .e = 0 }, fromInt(-1));
    try std.testing.expectEqual(Fixed{ .m = @as(i64, @bitCast(TWO62)), .e = 1 }, fromInt(2));
}
