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
//! Port status: Tasks 1–5 of docs/plans/2026-08-02-zig-port.md. `norm`,
//! `fromInt`, `mul128`, `mul`, `toIntTrunc`, `add`, `sub`, `neg`, `cmp`,
//! `frac`, `div`, `ln`, `exp`. The rest arrives in Tasks 6–7, each verified against
//! `lib/fixed.lua` by tests/zig_differential as it lands.

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

    const is_neg = m < 0;
    var u: u64 = @bitCast(if (is_neg) -%m else m);
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
    return .{ .m = if (is_neg) -%r else r, .e = ee };
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

    const is_neg = (a.m < 0) != (b.m < 0);
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
    return .{ .m = if (is_neg) -%r else r, .e = @intCast(es) };
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

/// Adds two soft-floats. Mirrors `lib/fixed.lua`'s `M.add`, whose sign split
/// is load-bearing: opposite-sign addition is EXACT (magnitudes only shrink,
/// cannot overflow), and only same-sign addition pre-halves against overflow.
/// A naive version that pre-halves both operands unconditionally loses the low
/// bit from each side identically and collapses a true 1-ULP difference to a
/// false canonical zero — the reference pins that exact case.
///
/// Every "shift" here is a truncating DIVISION (`@divTrunc`), not `>>`:
/// arithmetic shift right floors, and the two differ on negative odd operands.
/// This is the same floor-vs-truncate divergence the whole plan warns about,
/// in its second habitat.
pub fn add(a: Fixed, b: Fixed) Fixed {
    // A zero operand returns the OTHER operand verbatim, not renormalized —
    // same as the reference.
    if (a.m == 0) return b;
    if (b.m == 0) return a;

    // Order so x carries the larger exponent (strict comparison: equal
    // exponents keep the original order, same as the reference's `e1 < e2`).
    var x = a;
    var y = b;
    if (a.e < b.e) {
        x = b;
        y = a;
    }
    // Gap in i64: maxInt - minInt overflows i32, and the reference computes
    // this in doubles where it cannot overflow.
    const d: i64 = @as(i64, x.e) - @as(i64, y.e);
    if (d >= 63) return x; // second operand is entirely below the ulp

    const shifted = @divTrunc(y.m, POW2[@intCast(d)]);
    // Unreachable under the normalization invariant (|y.m| >= 2^62 and
    // d <= 62 give |shifted| >= 1); kept as defense against an unnormalized
    // caller, mirroring the reference.
    if (shifted == 0) return x;

    var sum: i64 = undefined;
    var es: i64 = undefined;
    if ((x.m < 0) == (shifted < 0)) {
        // Same sign: magnitudes accumulate and could overflow i64, so halve
        // both first (truncating!) and bump the exponent. Error bound 2 ULP,
        // pinned below.
        sum = @divTrunc(x.m, 2) + @divTrunc(shifted, 2);
        es = @as(i64, x.e) + 1;
    } else {
        // Opposite signs: the sum's magnitude can only shrink, so it is exact
        // and cannot overflow.
        sum = x.m + shifted;
        es = x.e;
    }
    if (sum == 0) return Fixed.zero;
    std.debug.assert(es >= std.math.minInt(i32) and es <= std.math.maxInt(i32));
    return norm(sum, @intCast(es));
}

/// Subtraction as negated addition, mirroring `M.sub`. Wrapping negation for
/// the same minInt reason as everywhere else — though a normalized b.m can
/// never be minInt, the zero check must come first exactly as in the
/// reference, and neither side may depend on which guard fires.
pub fn sub(a: Fixed, b: Fixed) Fixed {
    if (b.m == 0) return a;
    return add(a, .{ .m = -%b.m, .e = b.e });
}

/// Negation. Zero stays canonical zero; everything else flips the mantissa.
pub fn neg(x: Fixed) Fixed {
    if (x.m == 0) return Fixed.zero;
    return .{ .m = -%x.m, .e = x.e };
}

/// Three-way comparison: -1, 0, or 1. Mirrors `M.cmp`: sign classes first,
/// then exponents (normalization makes the larger exponent the larger
/// magnitude — inverted for negatives), then mantissas.
pub fn cmp(a: Fixed, b: Fixed) i32 {
    const s1: i32 = if (a.m > 0) 1 else if (a.m < 0) -1 else 0;
    const s2: i32 = if (b.m > 0) 1 else if (b.m < 0) -1 else 0;
    if (s1 != s2) return if (s1 < s2) -1 else 1;
    if (s1 == 0) return 0;
    if (a.e != b.e) {
        const bigger: i32 = if (a.e > b.e) 1 else -1;
        return if (s1 > 0) bigger else -bigger;
    }
    if (a.m == b.m) return 0;
    return if (a.m < b.m) -1 else 1;
}

/// Fractional part: x minus its truncated integer part. Mirrors `M.frac`,
/// including returning x VERBATIM (not renormalized) when the integer part is
/// zero. Inherits `toIntTrunc`'s ±2^53 clamp — for magnitudes past the clamp
/// the "integer part" subtracted is the clamp value, on both implementations
/// identically.
pub fn frac(x: Fixed) Fixed {
    const ip = toIntTrunc(x);
    if (ip == 0) return x;
    return sub(x, fromInt(ip));
}

/// Bit-serial magnitude division: floor((a/b) · 2^62) for normalized u64
/// magnitudes. Mirrors `lib/fixed.lua`'s `divmag` exactly: one integer
/// quotient bit (a/b lies in [1/2, 2) for normalized operands, so q0 is 0 or
/// 1), then 62 restoring-division rounds producing one fraction bit each.
/// The magnitude is FLOORED here; the caller reapplies the sign afterwards,
/// which makes the overall rounding truncation toward zero.
///
/// No step can overflow u64: rem < b < 2^63 so rem*2 < 2^64, frac gains at
/// most one bit per round for 62 rounds, and q0·2^62 + frac < 2^63.
fn divmag(a: u64, b: u64) u64 {
    const q0 = a / b;
    var rem = a % b;
    var fbits: u64 = 0;
    for (0..62) |_| {
        rem *= 2;
        fbits *= 2;
        if (rem >= b) {
            rem -= b;
            fbits += 1;
        }
    }
    return q0 * TWO62 + fbits;
}

/// Divides two normalized soft-floats, truncating toward zero. Mirrors
/// `lib/fixed.lua`'s `M.div`/`div_signed` pair — with one structural
/// difference, deliberate and documented: the reference splits into a
/// positive-only fast path and a sign-handling cold path purely as a
/// LuaJIT#1499 trace-compiler mitigation (the conditional unsigned-negation
/// branch followed by a loop was what the trace compiler miscompiled). The
/// ARITHMETIC on both paths is identical, and Zig has no trace compiler to
/// appease, so one unified path replaces both; the differential sweeps all
/// four sign quadrants to prove the equivalence rather than assume it.
///
/// divmag floors the MAGNITUDE; reapplying the sign afterwards makes the
/// overall rounding truncate toward zero. That is the property the six pinned
/// negative-operand tests hold: a floor-toward-negative-infinity mutant nets a
/// genuinely different mantissa on real input, and historically passed every
/// magnitude-tolerance check in the reference's suite before those pins
/// existed.
pub fn div(a: Fixed, b: Fixed) Fixed {
    // Divisor-zero check BEFORE the dividend shortcut: 0/0 is undefined, not
    // canonical zero — same stance, same order, as the reference.
    std.debug.assert(b.m != 0); // fixed.div: division by zero
    if (a.m == 0) return Fixed.zero;

    const is_neg = (a.m < 0) != (b.m < 0);
    const ua: u64 = @bitCast(if (a.m < 0) -%a.m else a.m);
    const ub: u64 = @bitCast(if (b.m < 0) -%b.m else b.m);
    std.debug.assert(ua >= TWO62 and ua < 0x8000000000000000); // operand 1 normalized
    std.debug.assert(ub >= TWO62 and ub < 0x8000000000000000); // operand 2 normalized

    // divmag's result is < 2^63, so the bitcast cannot go negative and the
    // negation cannot overflow.
    const mag: i64 = @bitCast(divmag(ua, ub));
    const r: i64 = if (is_neg) -%mag else mag;

    // Exponent difference in i64: maxInt - minInt overflows i32, and the
    // reference computes this in doubles then asserts inside norm.
    const es: i64 = @as(i64, a.e) - @as(i64, b.e);
    std.debug.assert(es >= std.math.minInt(i32) and es <= std.math.maxInt(i32));
    return norm(r, @intCast(es));
}

/// ln 2, as a normalized soft-float. ln2 lies in [0.5, 1), so its normalized
/// form sits at exponent -1 and the mantissa is ln2 scaled by 2^63 (not 2^62):
/// floor(l(2) · 2^63), truncated ONCE from full bc precision. Regenerated
/// independently on 2026-08-04 (`echo 'scale=80; v=l(2) * 2^63; scale=0; v/1'
/// | bc -l` → 6393154322601327829) and compared against the reference's
/// constant rather than copied from it, per the plan.
///
/// The reference documents why the truncation must happen at the target
/// scale: 2·floor(l(2)·2^62) ends in ...828, but floor(l(2)·2^63) ends in
/// ...829 — the fractional bit the coarser truncation discards is a 1, so
/// "truncate at 2^62 then renormalize" is wrong by exactly 1 ULP.
pub const LN2: Fixed = .{ .m = 6393154322601327829, .e = -1 };

/// Series lengths, measured in the reference, not assumed: ln's atanh series
/// needs 20 terms (convergence is slowest at f → 2, where t → 1/3; the real
/// kernel's error plateaus from N=17, and 12 — the original brief's claim —
/// leaves a 1.56e-14 relative error, ~4 orders above the kernel's floor).
/// exp's factorial-weighted series reaches ~100x below the kernel's ULP floor
/// at 16 terms over the range-reduced |r| ≤ ln2/2 domain.
const ATANH_TERMS = 20;
const EXP_TERMS = 16;

/// Correction-loop bound for exp's range reduction, with 1 unit of headroom
/// above the empirically confirmed maximum of 2 (600k+ trials in the
/// reference; the idealized exact-arithmetic proof says 1, and div's ~2^-62
/// rounding very rarely compounds to need a second).
pub const EXP_MAX_CORRECTIONS = 3;

/// Reciprocals of the odd denominators 3, 5, ..., 41 for ln's atanh series.
/// Built AT COMPTIME BY THE KERNEL'S OWN div — not pasted decimal constants —
/// exactly as the reference builds them at module load via M.div, so the
/// table inherits the kernel's own rounding and stays bit-identical by
/// construction.
const ODD_RECIP = blk: {
    @setEvalBranchQuota(1_000_000);
    var t: [ATANH_TERMS]Fixed = undefined;
    for (&t, 0..) |*slot, i| {
        slot.* = div(fromInt(1), fromInt(@intCast(2 * (i + 1) + 1)));
    }
    break :blk t;
};

/// Reciprocals of 1!..16! for exp's Taylor series. Same comptime-via-own-
/// arithmetic policy as ODD_RECIP: the running factorial is accumulated with
/// the kernel's mul, then inverted with the kernel's div, mirroring the
/// reference's module-load loop operation for operation.
const FACT_RECIP = blk: {
    @setEvalBranchQuota(1_000_000);
    var t: [EXP_TERMS]Fixed = undefined;
    var f = fromInt(1);
    for (&t, 0..) |*slot, i| {
        f = mul(f, fromInt(@intCast(i + 1)));
        slot.* = div(fromInt(1), f);
    }
    break :blk t;
};

/// ln2/2 and its negation — the range-reduction acceptance window. Built by
/// the kernel's own div/neg, matching the reference's module-load derivation.
const HALF_LN2 = blk: {
    @setEvalBranchQuota(100_000);
    break :blk div(LN2, fromInt(2));
};
const NEG_HALF_LN2 = neg(HALF_LN2);

/// Natural log. The soft-float form IS the decomposition: x = f · 2^e with
/// f = m/2^62 ∈ [1, 2) exactly the mantissa reinterpreted at exponent 0, so
/// ln x = e·ln2 + ln f with no further range reduction. ln f uses
/// 2·atanh((f−1)/(f+1)); f ∈ [1,2) keeps t ∈ [0, 1/3).
/// Key technique: atanh (Gregory) series with precomputed odd-reciprocal
/// coefficients; term counts measured against bc, not assumed.
pub fn ln(x: Fixed) Fixed {
    std.debug.assert(x.m > 0); // fixed.ln: argument must be positive
    const k = x.e;
    const f = Fixed{ .m = x.m, .e = 0 };
    const one = fromInt(1);
    const t = div(sub(f, one), add(f, one));
    const t2 = mul(t, t);
    var term = t;
    var acc = t;
    for (ODD_RECIP) |r| {
        term = mul(term, t2);
        acc = add(acc, mul(term, r));
    }
    // 2·acc + k·ln2, in exactly the reference's operation order.
    var l = add(acc, acc);
    if (k != 0) {
        l = add(l, mul(LN2, fromInt(k)));
    }
    return l;
}

/// r = x − k·ln2, recomputed from x and the CANDIDATE k every time — never
/// accumulated from a running r — so each candidate is evaluated exactly.
/// Single call site for the one arithmetic decision (subtract, not add).
fn reduceR(x: Fixed, k: i64) Fixed {
    return sub(x, mul(LN2, fromInt(k)));
}

/// True when a correction count has exceeded the bound. Factored out (and
/// public) so the boundary — 3 must pass, 4 must trip — can be pinned by a
/// unit test directly: the reference's 600k-trial search found the natural
/// maximum is 2 corrections, so no real exp input can distinguish `>` from a
/// `>=` off-by-one mutant; only a direct test of the predicate can.
pub fn correctionGuardWouldTrip(count: usize) bool {
    return count > EXP_MAX_CORRECTIONS;
}

/// Exponential. Range-reduce x = k·ln2 + r with |r| ≤ ln2/2, evaluate exp(r)
/// by Taylor series, then multiply by 2^k purely in the exponent.
///
/// NOT total, exactly like the reference: the result exponent is ~x/ln2, so
/// the i32 exponent contract fires around |x| ≳ 2^31·ln2 ≈ 1.5e9. Both
/// failure modes are LOUD `@panic`s — live in every build mode including
/// ReleaseFast, deliberately stronger than this file's std.debug.assert
/// policy — because the reference treats them as always-live error() calls
/// and they are reachable from user input (an extreme `--mean` reaches exp
/// with no range validation in bin/random). The C CLI must pre-validate if
/// it ever wants to refuse gracefully instead (note for Task 8/9).
///
/// The reference's correction loop exists because ITS k is a Lua double whose
/// ULP exceeds 1 past 2^53, freezing `k ± 1`. Here k is an i64 and cannot
/// freeze — but the loop, its bound, and its loud failure are preserved
/// anyway: toIntTrunc clamps at ±2^53 identically on both sides, so for huge
/// arguments r never lands inside the window and the guard trips on both
/// implementations alike.
pub fn exp(x: Fixed) Fixed {
    if (x.m == 0) return fromInt(1);
    // k = round(x/ln2): truncate, then nudge by at most
    // EXP_MAX_CORRECTIONS bounded steps.
    var k: i64 = toIntTrunc(div(x, LN2));
    var r = reduceR(x, k);
    var corrections: usize = 0;
    while (cmp(r, HALF_LN2) > 0) {
        k += 1;
        r = reduceR(x, k);
        corrections += 1;
        if (correctionGuardWouldTrip(corrections))
            @panic("fixed.exp: argument too large to range-reduce (correction bound exceeded)");
    }
    while (cmp(r, NEG_HALF_LN2) < 0) {
        k -= 1;
        r = reduceR(x, k);
        corrections += 1;
        if (correctionGuardWouldTrip(corrections))
            @panic("fixed.exp: argument too large to range-reduce (correction bound exceeded)");
    }
    // exp(r) = Σ r^n/n!, n = 0..16, incremental power, early break on a
    // zero term — the reference's loop shape exactly.
    var acc = fromInt(1);
    var pw = fromInt(1);
    for (FACT_RECIP) |fr| {
        pw = mul(pw, r);
        const c = mul(pw, fr);
        if (c.m == 0) break;
        acc = add(acc, c);
    }
    // Multiply by 2^k purely in the exponent, routed through norm so the i32
    // exponent contract is enforced at the point of creation. The range check
    // is a live panic, not a debug assert — see the doc comment.
    const es: i64 = @as(i64, acc.e) + k;
    if (es < std.math.minInt(i32) or es > std.math.maxInt(i32))
        @panic("fixed.exp: result exponent outside i32");
    return norm(acc.m, @intCast(es));
}

test "ln: exact identities — ln(1) is zero, ln(2) is LN2, ln(2^k) is k*ln2" {
    try std.testing.expectEqual(Fixed.zero, ln(fromInt(1)));
    try std.testing.expectEqual(LN2, ln(fromInt(2)));
    // ln(2^10) = 10·ln2 exactly (t = 0, so only the k·ln2 term survives).
    try std.testing.expectEqual(mul(LN2, fromInt(10)), ln(fromInt(1024)));
}

test "exp: exact identities — exp(0) is one, exp(ln2) is exactly 2" {
    try std.testing.expectEqual(fromInt(1), exp(Fixed.zero));
    // k = trunc(ln2/ln2) = 1, r = ln2 − 1·ln2 = 0 exactly, exp(0)·2^1 = 2.
    try std.testing.expectEqual(fromInt(2), exp(LN2));
}

test "exp: correction-guard boundary — 3 passes, 4 trips" {
    // The natural maximum is 2 corrections (600k-trial search in the
    // reference), so no exp input can pin this boundary; only the predicate
    // itself can — same rationale as the reference's test-only export.
    try std.testing.expect(!correctionGuardWouldTrip(3));
    try std.testing.expect(correctionGuardWouldTrip(4));
}

test "constants: LN2 and the comptime tables are normalized" {
    try std.testing.expect(@as(u64, @bitCast(LN2.m)) >= TWO62);
    for (ODD_RECIP) |r| try std.testing.expect(@as(u64, @bitCast(r.m)) >= TWO62);
    for (FACT_RECIP) |r| try std.testing.expect(@as(u64, @bitCast(r.m)) >= TWO62);
    try std.testing.expect(@as(u64, @bitCast(HALF_LN2.m)) >= TWO62);
}

test "div: the six pinned negative-operand truncation cases" {
    // Expected mantissas cross-verified in the reference against bc's exact
    // big-integer floor((|m1|·2^62)/|m2|), not against the kernel's own
    // output. Truncation toward zero == floor on the magnitude, sign after.
    const cases = [_]struct { n: i64, d: i64, m: i64, e: i32 }{
        .{ .n = -1, .d = 3, .m = -6148914691236517204, .e = -2 },
        .{ .n = 1, .d = -3, .m = -6148914691236517204, .e = -2 },
        .{ .n = -1, .d = -3, .m = 6148914691236517204, .e = -2 },
        .{ .n = -7, .d = 11, .m = -5869418568907584605, .e = -1 },
        .{ .n = 7, .d = -11, .m = -5869418568907584605, .e = -1 },
        .{ .n = -7, .d = -11, .m = 5869418568907584605, .e = -1 },
    };
    for (cases) |c| {
        try std.testing.expectEqual(
            Fixed{ .m = c.m, .e = c.e },
            div(fromInt(c.n), fromInt(c.d)),
        );
    }
}

test "div: x/x is exactly one, across signs and magnitudes" {
    const one = fromInt(1);
    for ([_]i64{ 1, -1, 3, -3, 1000003, -4503599627370495, 9007199254740992 }) |v| {
        const x = fromInt(v);
        try std.testing.expectEqual(one, div(x, x));
    }
}

test "div: exact power-of-two ratios carry no fraction bits" {
    // 8 / 2 == 4: quotient mantissa must be exactly 2^62 with e = 2.
    try std.testing.expectEqual(fromInt(4), div(fromInt(8), fromInt(2)));
    try std.testing.expectEqual(fromInt(-4), div(fromInt(8), fromInt(-2)));
}

test "add/sub: a true 1-ULP difference must not collapse to false zero" {
    // The reference's pinned case: two adjacent mantissas at the same
    // exponent. The naive always-halving version reports canonical zero.
    const odd1 = Fixed{ .m = 0x4000000000000123, .e = 5 };
    const odd2 = Fixed{ .m = 0x4000000000000122, .e = 5 };
    const p = sub(odd1, odd2);
    const want = norm(1, 5); // 1 ULP at exponent 5
    try std.testing.expectEqual(want, p);
}

test "add: same-sign worst case is exactly 2 ULP, pinned" {
    // m1 = 2^62+1 at e=100, m2 = 2^62 at e=38 (d=62): true sum is 2^62+2 at
    // e=100; the pre-halving loses exactly 2 from the mantissa.
    const r = add(.{ .m = 0x4000000000000001, .e = 100 }, .{ .m = 0x4000000000000000, .e = 38 });
    try std.testing.expectEqual(Fixed{ .m = 0x4000000000000000, .e = 100 }, r);
}

test "add/sub: d = 62/63/64 exponent-gap boundaries" {
    const one = fromInt(1);
    // d=62: the tiny operand's single bit still contributes (sub is exact on
    // the opposite-sign path).
    const d62 = norm(0x4000000000000000, one.e - 62);
    try std.testing.expectEqual(Fixed{ .m = 0x7FFFFFFFFFFFFFFE, .e = -1 }, sub(one, d62));
    // d=63 and d=64: below the ulp; both add and sub leave the larger operand
    // exactly unchanged.
    const d63 = norm(0x4000000000000000, one.e - 63);
    try std.testing.expectEqual(one, add(one, d63));
    try std.testing.expectEqual(one, sub(one, d63));
    const d64 = norm(0x4000000000000000, one.e - 64);
    try std.testing.expectEqual(one, add(one, d64));
    try std.testing.expectEqual(one, sub(one, d64));
}

test "add: total cancellation yields canonical zero" {
    const x = Fixed{ .m = 0x4000000000000123, .e = 7 };
    try std.testing.expectEqual(Fixed.zero, add(x, neg(x)));
    try std.testing.expectEqual(Fixed.zero, sub(x, x));
}

test "cmp: orders across sign, exponent and mantissa tiers" {
    const p_small = fromInt(2);
    const p_big = fromInt(1000);
    const n_small = fromInt(-2);
    const n_big = fromInt(-1000);
    try std.testing.expectEqual(@as(i32, -1), cmp(p_small, p_big));
    try std.testing.expectEqual(@as(i32, 1), cmp(p_big, p_small));
    try std.testing.expectEqual(@as(i32, 0), cmp(p_big, p_big));
    // For negatives the larger exponent means MORE negative.
    try std.testing.expectEqual(@as(i32, 1), cmp(n_big, p_big) * -1);
    try std.testing.expectEqual(@as(i32, -1), cmp(n_big, n_small));
    try std.testing.expectEqual(@as(i32, 0), cmp(Fixed.zero, Fixed.zero));
}

test "frac: splits value into integer and fractional parts" {
    // 3.5 = 7 * 0.5: frac -> 0.5, toIntTrunc -> 3.
    const half = Fixed{ .m = @as(i64, @bitCast(TWO62)), .e = -1 };
    const three_half = mul(fromInt(7), half);
    try std.testing.expectEqual(@as(i64, 3), toIntTrunc(three_half));
    const f = frac(three_half);
    try std.testing.expectEqual(half, f);
    // Negative: -3.5 -> integer part -3, frac -0.5 (truncation toward zero).
    const neg_f = frac(neg(three_half));
    try std.testing.expectEqual(neg(half), neg_f);
    // Pure fraction returns verbatim.
    try std.testing.expectEqual(half, frac(half));
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
