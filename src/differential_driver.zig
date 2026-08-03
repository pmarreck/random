//! Zig half of the `lib/fixed.lua` ⇄ `src/fixed.zig` differential.
//!
//! Prints one line per swept case, `TAG idx m e`, to stdout.
//! `tests/zig_differential.lua` walks the IDENTICAL sweep through the LuaJIT
//! reference and prints the same format; `tests/zig_differential` requires the
//! two to be byte-identical.
//!
//! The operand generator is specified here and reimplemented there rather than
//! shared, because there is nothing to share it through — that duplication is
//! deliberate and cheap (a plain u64 LCG, fully pinned by both languages), and
//! any disagreement in it is itself a defect worth failing on.
//!
//! WHY A ZIG DRIVER RATHER THAN C-THROUGH-THE-FFI: no FFI exists yet (Task 8).
//! This is a TEST driver, not the shipped CLI. The fleet rule that the CLI must
//! be C — so that bypassing the FFI is inexpressible rather than merely
//! discouraged — still stands and is unaffected; `randomz` arrives in Task 9
//! and will go through `include/randomz.h`. Do not repurpose this file into a
//! CLI.

const std = @import("std");
const fx = @import("fixed");

// ---------------------------------------------------------------------------
// Operand generator. Must match tests/zig_differential.lua exactly.
// ---------------------------------------------------------------------------
const LCG_MULT: u64 = 6364136223846793005;
const LCG_INC: u64 = 1442695040888963407;
// Distinct from kernel_jit_diff.lua's and kernel_bc_sweep.lua's seeds so the
// files' operand streams never accidentally coincide.
const LCG_SEED: u64 = 0x243F6A8885A308D3;

var lcg_state: u64 = LCG_SEED;

/// Advances the LCG and returns its high bits. Power-of-two-modulus LCGs have
/// weak low bits, so the low two are discarded rather than used as operands.
fn nextRaw() u64 {
    lcg_state = lcg_state *% LCG_MULT +% LCG_INC;
    return lcg_state >> 2;
}

/// A magnitude in [2^62, 2^63) — i.e. already normalized, so that shifting it
/// right by a known amount produces a DE-normalized input whose correct
/// normalization is known by construction.
fn nextMantissaMagnitude() u64 {
    return fx.TWO62 + (nextRaw() % fx.TWO62);
}

/// Exponents cycled by index rather than drawn from the LCG, so that changing
/// the case count never shifts which exponent a given index sees.
const E_SET = [_]i32{ 0, 1, -1, 62, -62, 1000, -1000 };
/// Right-shift amounts producing de-normalized mantissas. 63 drives the
/// mantissa to zero, exercising the canonical-zero collapse.
const SHIFTS = [_]u6{ 0, 1, 2, 3, 7, 15, 31, 47, 62, 63 };

/// Integer edge cases for fromInt. Straddles the 2^53 double-precision
/// ceiling and both i64 extremes — the reference takes these through LuaJIT
/// int64 cdata, so full 64-bit range is meaningful on both sides.
const INT_EDGES = [_]i64{
    0,                        1,                         -1,
    2,                        -2,                        3,
    -3,                       1000000,                   -1000000,
    2147483647,               -2147483648,               4503599627370496,
    -4503599627370496,        9007199254740992,          -9007199254740992,
    4611686018427387904,      -4611686018427387904,      std.math.maxInt(i64),
    std.math.minInt(i64),
};

/// Sign quadrants, cycled by construction rather than drawn from the LCG, so
/// mixed-sign multiplication is exercised exactly as often as same-sign on
/// every run. A positive-only sweep was blind to half the domain for five
/// consecutive tasks in this project's history.
const SIGN_QUADRANTS = [_][2]i32{ .{ 1, 1 }, .{ -1, 1 }, .{ 1, -1 }, .{ -1, -1 } };

/// (mantissa, exponent) cases for toIntTrunc spanning every branch: canonical
/// zero, the `sh >= 0` clamp, the `s > 62` collapse to zero, and the ordinary
/// truncating divide with both signs.
const TO_INT_EDGES = [_]struct { m: i64, e: i32 }{
    .{ .m = 0, .e = 0 },        .{ .m = 0, .e = 500 },
    .{ .m = 4611686018427387904, .e = 62 },   .{ .m = -4611686018427387904, .e = 62 },
    .{ .m = 4611686018427387904, .e = 63 },   .{ .m = -4611686018427387904, .e = 63 },
    .{ .m = 4611686018427387904, .e = 0 },    .{ .m = -4611686018427387904, .e = 0 },
    .{ .m = 4611686018427387904, .e = -62 },  .{ .m = -4611686018427387904, .e = -62 },
    .{ .m = 4611686018427387904, .e = -63 },  .{ .m = -4611686018427387904, .e = -63 },
    .{ .m = std.math.maxInt(i64), .e = 53 },  .{ .m = std.math.minInt(i64), .e = 53 },
    .{ .m = std.math.maxInt(i64), .e = 54 },  .{ .m = std.math.minInt(i64), .e = 54 },
    .{ .m = 6917529027641081856, .e = 1 },    .{ .m = -6917529027641081856, .e = 1 },
};

/// (mantissa, exponent) edge cases for norm, including canonical zero with a
/// nonzero incoming exponent and minInt(i64), whose magnitude is not
/// representable as a positive i64.
const NORM_EDGES = [_]struct { m: i64, e: i32 }{
    .{ .m = 0, .e = 0 },
    .{ .m = 0, .e = 100 },
    .{ .m = 0, .e = -100 },
    .{ .m = std.math.minInt(i64), .e = 0 },
    .{ .m = std.math.minInt(i64), .e = 5 },
    .{ .m = std.math.minInt(i64), .e = -5 },
    .{ .m = 4611686018427387904, .e = 0 },
    .{ .m = -4611686018427387904, .e = 0 },
    .{ .m = std.math.maxInt(i64), .e = 0 },
    .{ .m = -std.math.maxInt(i64), .e = 0 },
    .{ .m = 1, .e = 0 },
    .{ .m = -1, .e = 0 },
    .{ .m = 1, .e = 62 },
    .{ .m = -1, .e = -62 },
    .{ .m = 3, .e = 7 },
    .{ .m = -3, .e = -7 },
};

// Zig 0.16 entry point: `main` takes `std.process.Init`, which supplies the
// `Io` instance that File.writer now requires, plus an arena. This is NOT the
// `pub fn main() !void` + `std.fs.File.stdout()` shape from 0.15 -- `std.fs`
// has no `File` member in 0.16 at all; it moved to `std.Io.File`.
// ZIG_RECENT_API_CHANGES.md is stale on this specific point; verified against
// the shipped stdlib (std/Random/benchmark.zig) rather than assumed.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var buf: [1 << 16]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout_writer.interface;

    const argv = try init.minimal.args.toSlice(arena);
    const count: usize = if (argv.len > 1)
        std.fmt.parseInt(usize, argv[1], 10) catch 200
    else
        200;

    // --- A: fromInt over edges, then LCG-drawn i64s -------------------------
    var idx: usize = 0;
    for (INT_EDGES) |v| {
        const r = fx.fromInt(v);
        try out.print("A {d} {d} {d}\n", .{ idx, r.m, r.e });
        idx += 1;
    }
    for (0..count) |_| {
        const raw = nextRaw();
        const v: i64 = @bitCast(raw);
        const r = fx.fromInt(v);
        try out.print("A {d} {d} {d}\n", .{ idx, r.m, r.e });
        idx += 1;
    }

    // --- B: norm over edges, then de-normalized LCG mantissas --------------
    idx = 0;
    for (NORM_EDGES) |c| {
        const r = fx.norm(c.m, c.e);
        try out.print("B {d} {d} {d}\n", .{ idx, r.m, r.e });
        idx += 1;
    }
    for (0..count) |i| {
        const mag = nextMantissaMagnitude();
        const e = E_SET[i % E_SET.len];
        for (SHIFTS) |sh| {
            const shifted: i64 = @bitCast(mag >> sh);
            // Both signs: negative operands are load-bearing, not decoration.
            // A positive-only sweep in this project's history was blind to half
            // the domain for five tasks running.
            const r_pos = fx.norm(shifted, e);
            try out.print("B {d} {d} {d}\n", .{ idx, r_pos.m, r_pos.e });
            idx += 1;
            const r_neg = fx.norm(-%shifted, e);
            try out.print("B {d} {d} {d}\n", .{ idx, r_neg.m, r_neg.e });
            idx += 1;
        }
    }

    // --- C: mul128 over the full u64 range plus carry-propagation extremes --
    idx = 0;
    const M128_EDGES = [_][2]u64{
        .{ 0, 0 },                                  .{ 1, 1 },
        .{ 0xFFFFFFFFFFFFFFFF, 1 },                 .{ 1, 0xFFFFFFFFFFFFFFFF },
        .{ 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF }, .{ 0x8000000000000000, 2 },
        .{ 0x100000000, 0x100000000 },              .{ 0xFFFFFFFF, 0xFFFFFFFF },
        .{ 0x100000000, 0xFFFFFFFF },               .{ fx.TWO62, fx.TWO62 },
    };
    for (M128_EDGES) |c| {
        const p = mul128Report(c[0], c[1]);
        try out.print("C {d} {d} {d}\n", .{ idx, p.hi, p.lo });
        idx += 1;
    }
    for (0..count) |_| {
        const a = nextRaw();
        const b = nextRaw();
        const p = mul128Report(a, b);
        try out.print("C {d} {d} {d}\n", .{ idx, p.hi, p.lo });
        idx += 1;
    }

    // --- D: mul over normalized operands, all four sign quadrants -----------
    idx = 0;
    for (0..count) |i| {
        const ma: i64 = @bitCast(nextMantissaMagnitude());
        const mb: i64 = @bitCast(nextMantissaMagnitude());
        const ea = E_SET[i % E_SET.len];
        const eb = E_SET[(i + 3) % E_SET.len];
        for (SIGN_QUADRANTS) |q| {
            const a: fx.Fixed = .{ .m = if (q[0] < 0) -%ma else ma, .e = ea };
            const b: fx.Fixed = .{ .m = if (q[1] < 0) -%mb else mb, .e = eb };
            const r = fx.mul(a, b);
            try out.print("D {d} {d} {d}\n", .{ idx, r.m, r.e });
            idx += 1;
        }
    }

    // --- E: toIntTrunc, including the clamp and the truncation direction ----
    idx = 0;
    for (TO_INT_EDGES) |c| {
        try out.print("E {d} {d}\n", .{ idx, fx.toIntTrunc(.{ .m = c.m, .e = c.e }) });
        idx += 1;
    }
    for (0..count) |i| {
        const mag: i64 = @bitCast(nextMantissaMagnitude());
        // Exponents swept across the whole interesting band: below -62 the
        // result is 0, at/above 62 it clamps, and in between the truncation
        // direction is actually observable -- which is the only place
        // @divTrunc and @divFloor differ.
        const e: i32 = @intCast(@as(i64, @intCast(i % 130)) - 65);
        try out.print("E {d} {d}\n", .{ idx, fx.toIntTrunc(.{ .m = mag, .e = e }) });
        idx += 1;
        try out.print("E {d} {d}\n", .{ idx, fx.toIntTrunc(.{ .m = -%mag, .e = e }) });
        idx += 1;
    }

    // --- F: add and sub — sign quadrants x exponent gaps --------------------
    // Gap set straddles every behavioural boundary: 0 (equal exponents), the
    // last contributing gap (62), the first below-the-ulp gaps (63, 64), and
    // one far past (120).
    idx = 0;
    for (ADD_EDGES) |c| {
        const r = fx.add(.{ .m = c.m1, .e = c.e1 }, .{ .m = c.m2, .e = c.e2 });
        try out.print("F {d} {d} {d}\n", .{ idx, r.m, r.e });
        idx += 1;
        const s = fx.sub(.{ .m = c.m1, .e = c.e1 }, .{ .m = c.m2, .e = c.e2 });
        try out.print("F {d} {d} {d}\n", .{ idx, s.m, s.e });
        idx += 1;
    }
    for (0..count) |i| {
        const ma: i64 = @bitCast(nextMantissaMagnitude());
        const mb: i64 = @bitCast(nextMantissaMagnitude());
        const e2 = E_SET[i % E_SET.len];
        const e1: i32 = e2 + D_GAP_SET[i % D_GAP_SET.len];
        for (SIGN_QUADRANTS) |q| {
            const m1 = if (q[0] < 0) -%ma else ma;
            const m2 = if (q[1] < 0) -%mb else mb;
            const r = fx.add(.{ .m = m1, .e = e1 }, .{ .m = m2, .e = e2 });
            try out.print("F {d} {d} {d}\n", .{ idx, r.m, r.e });
            idx += 1;
            const s = fx.sub(.{ .m = m1, .e = e1 }, .{ .m = m2, .e = e2 });
            try out.print("F {d} {d} {d}\n", .{ idx, s.m, s.e });
            idx += 1;
            // Reversed operand order: the smaller exponent arrives first, so
            // the swap branch is exercised exactly as often as the no-swap one.
            const r2 = fx.add(.{ .m = m2, .e = e2 }, .{ .m = m1, .e = e1 });
            try out.print("F {d} {d} {d}\n", .{ idx, r2.m, r2.e });
            idx += 1;
        }
    }

    // --- G: neg and cmp -----------------------------------------------------
    idx = 0;
    for (0..count) |i| {
        const ma: i64 = @bitCast(nextMantissaMagnitude());
        const mb: i64 = @bitCast(nextMantissaMagnitude());
        const e1 = E_SET[i % E_SET.len];
        const e2 = E_SET[(i + 2) % E_SET.len];
        const q = SIGN_QUADRANTS[i % SIGN_QUADRANTS.len];
        const m1 = if (q[0] < 0) -%ma else ma;
        const m2 = if (q[1] < 0) -%mb else mb;
        const n = fx.neg(.{ .m = m1, .e = e1 });
        try out.print("G {d} {d} {d}\n", .{ idx, n.m, n.e });
        idx += 1;
        try out.print("G {d} {d}\n", .{ idx, fx.cmp(.{ .m = m1, .e = e1 }, .{ .m = m2, .e = e2 }) });
        idx += 1;
        try out.print("G {d} {d}\n", .{ idx, fx.cmp(.{ .m = m2, .e = e2 }, .{ .m = m1, .e = e1 }) });
        idx += 1;
        try out.print("G {d} {d}\n", .{ idx, fx.cmp(.{ .m = m1, .e = e1 }, .{ .m = m1, .e = e1 }) });
        idx += 1;
    }

    // --- H: frac ------------------------------------------------------------
    // Exponent set spans: pure fraction (verbatim return), mixed
    // integer+fraction (where truncation direction is observable), the 2^53
    // clamp neighbourhood (52/53), and past-integer territory (62, 63, 100).
    idx = 0;
    for (0..count) |i| {
        const mag: i64 = @bitCast(nextMantissaMagnitude());
        const e = FRAC_E_SET[i % FRAC_E_SET.len];
        const fp = fx.frac(.{ .m = mag, .e = e });
        try out.print("H {d} {d} {d}\n", .{ idx, fp.m, fp.e });
        idx += 1;
        const fn_ = fx.frac(.{ .m = -%mag, .e = e });
        try out.print("H {d} {d} {d}\n", .{ idx, fn_.m, fn_.e });
        idx += 1;
    }

    try out.flush();
}

/// Deterministic add/sub edge cases: the pinned 1-ULP and 2-ULP behaviours,
/// total cancellation, zero operands, and the d = 62/63/64 gap boundaries.
const ADD_EDGES = [_]struct { m1: i64, e1: i32, m2: i64, e2: i32 }{
    // 1-ULP adjacent mantissas, same exponent (sub recovers exactly 1 ULP).
    .{ .m1 = 0x4000000000000123, .e1 = 5, .m2 = 0x4000000000000122, .e2 = 5 },
    // Total cancellation (sub of identical values).
    .{ .m1 = 0x4000000000000123, .e1 = 7, .m2 = 0x4000000000000123, .e2 = 7 },
    // Same-sign 2-ULP worst case, d = 62.
    .{ .m1 = 0x4000000000000001, .e1 = 100, .m2 = 0x4000000000000000, .e2 = 38 },
    // d boundaries around fromInt(1) (e = 0).
    .{ .m1 = 0x4000000000000000, .e1 = 0, .m2 = 0x4000000000000000, .e2 = -62 },
    .{ .m1 = 0x4000000000000000, .e1 = 0, .m2 = 0x4000000000000000, .e2 = -63 },
    .{ .m1 = 0x4000000000000000, .e1 = 0, .m2 = 0x4000000000000000, .e2 = -64 },
    // Zero operands: each side, both orders.
    .{ .m1 = 0, .e1 = 0, .m2 = 0x4000000000000000, .e2 = 3 },
    .{ .m1 = 0x4000000000000000, .e1 = 3, .m2 = 0, .e2 = 0 },
    .{ .m1 = 0, .e1 = 0, .m2 = 0, .e2 = 0 },
    // Mixed signs at the extremes.
    .{ .m1 = std.math.maxInt(i64), .e1 = 10, .m2 = -std.math.maxInt(i64), .e2 = 10 },
    .{ .m1 = std.math.maxInt(i64), .e1 = 10, .m2 = std.math.maxInt(i64), .e2 = 10 },
};

/// Exponent gaps for the F sweep; see the section comment.
const D_GAP_SET = [_]i32{ 0, 1, 2, 31, 61, 62, 63, 64, 120 };

/// Exponents for the H (frac) sweep; see the section comment.
const FRAC_E_SET = [_]i32{ -70, -63, -62, -1, 0, 1, 30, 52, 53, 61, 62, 63, 100 };

/// Wrapper so the anonymous struct returned by fx.mul128 has a name here.
fn mul128Report(a: u64, b: u64) struct { hi: u64, lo: u64 } {
    const r = fx.mul128(a, b);
    return .{ .hi = r.hi, .lo = r.lo };
}
