//! Integer-only 256-strip Ziggurat (Marsaglia–Tsang / Doornik).
//! Disjoint index/sign/coordinate bits avoid the classic RNOR collision defect.
//! Production stream v3: one BE U64 per header, no cached spare.
const fx = @import("fixed");
pub const tables = @import("ziggurat_tables.zig");
pub const scale: u64 = 1 << 55;

pub const Draw = struct { strip: u8, negative: bool, coordinate: u64 };
pub fn decode(word: u64) Draw {
    return .{ .strip = @truncate(word), .negative = (word & 256) != 0, .coordinate = word >> 9 };
}

/// Exact 55-bit [0,1) fraction; callers supply words, never an ambient RNG.
fn unit(word: u64) fx.Fixed {
    const n = word >> 9;
    if (n == 0) return fx.Fixed.zero;
    return fx.norm(@intCast(n), 7);
}

/// (0,1] avoids log(0) without doubling the smallest grid point's mass.
fn openUnit(word: u64) fx.Fixed {
    return fx.norm(@intCast((word >> 9) + 1), 7);
}

/// Sample from a supplied fallible U64 stream. Rejection has no hidden cache,
/// so saving its byte cursor at an output boundary suffices for continuation.
pub fn normal(source: anytype) !fx.Fixed {
    while (true) {
        const draw = decode(try source.next());
        const strip = tables.strips[draw.strip];
        const u = if (draw.coordinate == 0) fx.Fixed.zero else fx.norm(@intCast(draw.coordinate), 7);
        const x = fx.mul(u, strip.x);
        if (draw.coordinate < strip.k) return if (draw.negative) fx.neg(x) else x;
        if (draw.strip == 0) {
            const r = tables.strips[1].x;
            while (true) {
                const t = fx.div(fx.neg(fx.ln(openUnit(try source.next()))), r);
                const y = fx.neg(fx.ln(openUnit(try source.next())));
                if (fx.cmp(fx.add(y, y), fx.mul(t, t)) >= 0) {
                    const result = fx.add(r, t);
                    return if (draw.negative) fx.neg(result) else result;
                }
            }
        }
        const upper = if (draw.strip == 255) fx.fromInt(1) else tables.strips[draw.strip + 1].y;
        const y = fx.add(strip.y, fx.mul(unit(try source.next()), fx.sub(upper, strip.y)));
        var exponent = fx.neg(fx.mul(x, x));
        if (exponent.m != 0) exponent.e -= 1;
        if (fx.cmp(y, fx.exp(exponent)) < 0) return if (draw.negative) fx.neg(x) else x;
        // A failed wedge must select a NEW strip, not retry in this strip.
    }
}
