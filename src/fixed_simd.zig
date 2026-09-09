//! Exact four-lane fixed-point kernels. Called only through the checked dispatcher.
const fx = @import("fixed");
pub const Batch = [4]fx.Fixed;
const U = @Vector(4, u64);
const I = @Vector(4, i64);
const Mask = @Vector(4, bool);
const V = struct { m: I, e: I };
fn u(n: u64) U {
    return @splat(n);
}
fn i(n: i64) I {
    return @splat(n);
}
fn sh(n: u6) @Vector(4, u6) {
    return @splat(n);
}
fn splat(x: fx.Fixed) V {
    return .{ .m = i(x.m), .e = i(x.e) };
}
fn pack(xs: Batch) V {
    var out: V = undefined;
    inline for (0..4) |lane| {
        out.m[lane] = xs[lane].m;
        out.e[lane] = xs[lane].e;
    }
    return out;
}
fn unpack(x: V) Batch {
    var out: Batch = undefined;
    inline for (0..4) |lane| out[lane] = .{ .m = x.m[lane], .e = @intCast(x.e[lane]) };
    return out;
}
fn magnitude(m: I) U {
    return @bitCast(@select(i64, m < i(0), -%m, m));
}
fn signed(m: U, negative: Mask) I {
    const mm: I = @bitCast(m);
    return @select(i64, negative, -%mm, mm);
}
fn choose(mask: Mask, a: V, b: V) V {
    return .{ .m = @select(i64, mask, a.m, b.m), .e = @select(i64, mask, a.e, b.e) };
}

/// Normalize each lane without cross-lane branches. Clamp shift counts on
/// inactive zero lanes so ReleaseSafe also validates every evaluated path.
fn norm(m: I, e: I) V {
    const mag = magnitude(m);
    const high = mag >= u(1 << 63);
    const shift: @Vector(4, u6) = @intCast(@max(@as(U, @intCast(@clz(mag))), u(1)) - u(1));
    const normalized = @select(u64, high, mag >> sh(1), mag << shift);
    const ee = e + @select(i64, high, i(1), -@as(I, @intCast(shift)));
    return .{ .m = signed(normalized, m < i(0)), .e = @select(i64, mag == u(0), i(0), ee) };
}

/// Four exact 64x64 products from 32-bit limbs, followed by the scalar
/// kernel's 62/63-bit truncation. AVX2 can multiply four such limbs at once.
fn mul(a: V, b: V) V {
    const aa = magnitude(a.m);
    const bb = magnitude(b.m);
    const mask = u(0xffffffff);
    const a0 = aa & mask;
    const b0 = bb & mask;
    const a1 = aa >> sh(32);
    const b1 = bb >> sh(32);
    const p00 = a0 * b0;
    const t = a1 * b0 + (p00 >> sh(32));
    const middle = a0 * b1 + (t & mask);
    const hi = a1 * b1 + (t >> sh(32)) + (middle >> sh(32));
    const lo = (middle << sh(32)) | (p00 & mask);
    const high = hi >= u(fx.TWO61);
    const mag = @select(u64, high, (hi << sh(1)) | (lo >> sh(63)), (hi << sh(2)) | (lo >> sh(62)));
    return .{ .m = signed(mag, (a.m < i(0)) != (b.m < i(0))), .e = @select(i64, mag == u(0), i(0), a.e + b.e + @select(i64, high, i(1), i(0))) };
}

/// Alignment uses unsigned magnitudes to truncate negatives toward zero.
/// Opposite signs retain the full cancellation precision of the scalar path.
fn add(a: V, b: V) V {
    const x = choose(a.e < b.e, b, a);
    const y = choose(a.e < b.e, a, b);
    const d = x.e - y.e;
    const shift: @Vector(4, u6) = @intCast(@min(d, i(63)));
    const shifted = signed(magnitude(y.m) >> shift, y.m < i(0));
    const same = (x.m < i(0)) == (shifted < i(0));
    const half_sum = signed((magnitude(x.m) >> sh(1)) + (magnitude(shifted) >> sh(1)), x.m < i(0));
    var out = norm(@select(i64, same, half_sum, x.m +% shifted), x.e + @select(i64, same, i(1), i(0)));
    out = choose(d >= i(63), x, out);
    out = choose(b.m == i(0), a, out);
    return choose(a.m == i(0), b, out);
}

pub fn mul4(a: Batch, b: Batch) Batch {
    return unpack(mul(pack(a), pack(b)));
}
pub fn add4(a: Batch, b: Batch) Batch {
    return unpack(add(pack(a), pack(b)));
}

const odd = blk: {
    @setEvalBranchQuota(100000);
    var coefficients: [20]fx.Fixed = undefined;
    for (&coefficients, 0..) |*c, n| c.* = fx.div(fx.fromInt(1), fx.fromInt(@intCast(2 * n + 3)));
    break :blk coefficients;
};
const cosine = blk: {
    @setEvalBranchQuota(100000);
    var coefficients: [14]fx.Fixed = undefined;
    for (&coefficients, 1..) |*c, n| c.* = fx.div(fx.fromInt(1), fx.fromInt(@intCast((2 * n - 1) * 2 * n)));
    break :blk coefficients;
};
const sine = blk: {
    @setEvalBranchQuota(100000);
    var coefficients: [14]fx.Fixed = undefined;
    for (&coefficients, 1..) |*c, n| c.* = fx.div(fx.fromInt(1), fx.fromInt(@intCast(2 * n * (2 * n + 1))));
    break :blk coefficients;
};

/// Keep one scalar division per lane; vectorize the twenty dependent series
/// steps across independent inputs without changing their evaluation order.
pub noinline fn ln4(xs: Batch) Batch {
    var initial: Batch = undefined;
    for (xs, &initial) |x, *t| {
        const f = fx.Fixed{ .m = x.m, .e = 0 };
        t.* = fx.div(fx.sub(f, fx.fromInt(1)), fx.add(f, fx.fromInt(1)));
    }
    const t = pack(initial);
    const t2 = mul(t, t);
    var term = t;
    var acc = t;
    for (odd) |coefficient| {
        term = mul(term, t2);
        acc = add(acc, mul(term, splat(coefficient)));
    }
    var out = unpack(add(acc, acc));
    for (xs, &out) |x, *result| {
        if (x.e != 0) result.* = fx.add(result.*, fx.mul(fx.LN2, fx.fromInt(x.e)));
    }
    return out;
}

/// Scalar exact quadrant reduction, then masked sine/cosine recurrences.
/// Mixed quadrants remain in their original lanes; no RNG bytes are touched.
pub noinline fn cos4(xs: Batch) Batch {
    var angles: Batch = undefined;
    var sin_mask: Mask = undefined;
    var neg_mask: Mask = undefined;
    inline for (0..4) |lane| {
        var f = fx.frac(xs[lane]);
        if (f.m < 0) f = fx.add(f, fx.fromInt(1));
        const q4 = fx.mul(f, fx.fromInt(4));
        const q = fx.toIntTrunc(q4);
        angles[lane] = fx.mul(fx.sub(q4, fx.fromInt(q)), fx.PI_2);
        // Match the scalar default branch even if a tiny negative wrap rounds to 4.
        sin_mask[lane] = q != 0 and q != 2;
        neg_mask[lane] = q == 1 or q == 2;
    }
    const angle = pack(angles);
    const a2 = mul(angle, angle);
    var term = choose(sin_mask, angle, splat(fx.fromInt(1)));
    var acc = term;
    for (cosine, sine) |c, s| {
        term = mul(mul(term, a2), choose(sin_mask, splat(s), splat(c)));
        term.m = -%term.m;
        acc = add(acc, term);
    }
    acc.m = @select(i64, neg_mask, -%acc.m, acc.m);
    return unpack(acc);
}
