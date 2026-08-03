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
//! Port status: Task 1 of docs/plans/2026-08-02-zig-port.md. `norm` and
//! `fromInt` only; the rest arrives in Tasks 2–7, each verified against
//! `lib/fixed.lua` by tests/zig_differential as it lands.

const std = @import("std");

/// 2^62 — the lower bound of a normalized mantissa's magnitude.
pub const TWO62: u64 = 0x4000000000000000;

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

    // Shift up until normalized. Mirrors the reference's `u = u * 2` loop
    // rather than using @clz; Task 2 replaces this with @clz and must
    // re-verify equivalence at the extremes rather than assume it.
    while (u < TWO62) {
        u *= 2;
        ee -= 1;
    }
    // Shift down if the magnitude reached the sign bit (only reachable from
    // minInt(i64), whose wrapped magnitude is exactly 2^63).
    while (u >= 0x8000000000000000) {
        u /= 2;
        ee += 1;
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
