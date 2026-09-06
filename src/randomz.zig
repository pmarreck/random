//! Pure RNG/distribution core and C ABI.
//!
//! I/O belongs to callers. The only entropy boundary is a caller-supplied fill
//! callback; deterministic state is caller-owned `(key, byte_position)`.

const std = @import("std");
const fixed = @import("fixed");

const Blake3 = std.crypto.hash.Blake3;
const kdf_context = "random drbg 2026-08-04 v1";
const max_exact_position: u64 = 9007199254740992;
const curve_max_samples: usize = 4096;

pub const Fixed = extern struct {
    m: i64,
    e: i32,

    fn fromInternal(value: fixed.Fixed) Fixed {
        return .{ .m = value.m, .e = value.e };
    }

    fn internal(value: Fixed) fixed.Fixed {
        return .{ .m = value.m, .e = value.e };
    }
};

pub const Drbg = extern struct {
    key: [32]u8,
    position: u64,
};

/// Optional small-draw cache; the original 40-byte Drbg ABI is unchanged.
/// Use buffered setters to invalidate prefetched bytes when seeking or rekeying.
pub const BufferedDrbg = extern struct {
    state: Drbg,
    cache: [1024]u8,
    cache_start: u64,
    cache_len: u64,
};

pub const FillFn = *const fn (
    context: ?*anyopaque,
    out: [*]u8,
    count: usize,
) callconv(.c) c_int;

pub const Status = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    entropy_error = 2,
    position_overflow = 3,
    buffer_too_small = 4,
    numeric_error = 5,
};

const Distribution = enum(c_int) {
    normal = 1,
    exponential = 2,
    poisson = 3,
    log_normal = 4,
    beta = 5,
};

const RngError = error{
    InvalidArgument,
    FillFailed,
    PositionOverflow,
    BufferTooSmall,
    NumericError,
};

fn errorStatus(err: RngError) c_int {
    return @intFromEnum(switch (err) {
        error.InvalidArgument => Status.invalid_argument,
        error.FillFailed => Status.entropy_error,
        error.PositionOverflow => Status.position_overflow,
        error.BufferTooSmall => Status.buffer_too_small,
        error.NumericError => Status.numeric_error,
    });
}

fn validFixed(value: Fixed) bool {
    if (value.m == 0) return value.e == 0;
    const magnitude: u64 = @bitCast(if (value.m < 0) -%value.m else value.m);
    return magnitude >= fixed.TWO62 and magnitude < 0x8000_0000_0000_0000;
}

fn exponentIn(value: Fixed, minimum: i32, maximum: i32) bool {
    return validFixed(value) and (value.m == 0 or
        (value.e >= minimum and value.e <= maximum));
}

const Source = struct {
    fill: FillFn,
    context: ?*anyopaque,

    fn bytes(self: Source, out: []u8) RngError!void {
        return switch (self.fill(self.context, out.ptr, out.len)) {
            0 => {},
            1 => error.InvalidArgument,
            2 => error.FillFailed,
            3 => error.PositionOverflow,
            4 => error.BufferTooSmall,
            5 => error.NumericError,
            else => error.FillFailed,
        };
    }

    fn u32be(self: Source) RngError!u32 {
        var bytes_out: [4]u8 = undefined;
        try self.bytes(&bytes_out);
        return (@as(u32, bytes_out[0]) << 24) |
            (@as(u32, bytes_out[1]) << 16) |
            (@as(u32, bytes_out[2]) << 8) |
            @as(u32, bytes_out[3]);
    }

    fn u64be(self: Source) RngError!u64 {
        var bytes_out: [8]u8 = undefined;
        try self.bytes(&bytes_out);
        var value: u64 = 0;
        for (bytes_out) |byte| value = (value << 8) | byte;
        return value;
    }
};

fn drbgFill(state: *Drbg, out: []u8) RngError!void {
    const count: u64 = std.math.cast(u64, out.len) orelse
        return error.PositionOverflow;
    if (state.position > max_exact_position or
        count > max_exact_position - state.position)
    {
        return error.PositionOverflow;
    }

    var hasher = Blake3.init(.{ .key = state.key });
    defer std.crypto.secureZero(u8, std.mem.asBytes(&hasher));
    hasher.finalizeSeek(state.position, out);
    state.position += count;
}

fn range(source: Source, start: i64, end: i64) RngError!i64 {
    if (start > end) return error.InvalidArgument;
    const span_i128 = @as(i128, end) - @as(i128, start) + 1;
    if (span_i128 <= 0 or span_i128 > max_exact_position) {
        return error.InvalidArgument;
    }
    const span: u64 = @intCast(span_i128);
    if (span <= 1) return start;

    if (span <= 0x1_0000_0000) {
        const universe: u64 = 0x1_0000_0000;
        const bound = universe - (universe % span);
        while (true) {
            const draw: u64 = try source.u32be();
            if (draw < bound) {
                return start + @as(i64, @intCast(draw % span));
            }
        }
    }

    const remainder = (0 -% span) % span;
    const exact_divides = remainder == 0;
    const bound = 0 -% remainder;
    while (true) {
        const draw = try source.u64be();
        if (exact_divides or draw < bound) {
            return start + @as(i64, @intCast(draw % span));
        }
    }
}

fn uniform(source: Source) RngError!fixed.Fixed {
    const draw = try source.u32be();
    return fixed.div(fixed.fromInt(draw), fixed.fromInt(0x1_0000_0000));
}

fn constants() struct {
    one: fixed.Fixed,
    two: fixed.Fixed,
    neg_two: fixed.Fixed,
    six: fixed.Fixed,
    half: fixed.Fixed,
    min_uniform: fixed.Fixed,
} {
    const one = fixed.fromInt(1);
    const two = fixed.fromInt(2);
    return .{
        .one = one,
        .two = two,
        .neg_two = fixed.fromInt(-2),
        .six = fixed.fromInt(6),
        .half = fixed.div(one, two),
        .min_uniform = fixed.div(one, fixed.fromInt(0x1_0000_0000)),
    };
}

fn roundToInt(value: fixed.Fixed) i64 {
    const c = constants();
    const shifted = if (value.m < 0)
        fixed.sub(value, c.half)
    else
        fixed.add(value, c.half);
    return fixed.toIntTrunc(shifted);
}

fn nonzeroUniform(source: Source) RngError!fixed.Fixed {
    const value = try uniform(source);
    return if (value.m == 0) constants().min_uniform else value;
}

fn normalFloat(
    source: Source,
    mean: fixed.Fixed,
    stddev: fixed.Fixed,
) RngError!fixed.Fixed {
    const c = constants();
    const uniform_one = try nonzeroUniform(source);
    const uniform_two = try uniform(source);
    const radius = fixed.sqrt(fixed.mul(c.neg_two, fixed.ln(uniform_one)));
    const z = fixed.mul(radius, fixed.cosTurns(uniform_two));
    return fixed.add(mean, fixed.mul(z, stddev));
}

fn normalInt(source: Source, start: i64, end: i64) RngError!i64 {
    if (start > end) return error.InvalidArgument;
    const c = constants();
    const width_i128 = @as(i128, end) - @as(i128, start);
    if (width_i128 > std.math.maxInt(i64)) return error.InvalidArgument;
    const width = fixed.fromInt(@intCast(width_i128));
    const sixth = fixed.div(width, c.six);
    const half_width = fixed.div(width, c.two);
    const start_fixed = fixed.fromInt(start);
    const million = fixed.fromInt(1_000_000);

    while (true) {
        const n1 = fixed.fromInt(try range(source, 1, 1_000_000));
        const n2 = fixed.fromInt(try range(source, 1, 1_000_000));
        const uniform_one = fixed.div(n1, million);
        const uniform_two = fixed.div(n2, million);
        const radius = fixed.sqrt(fixed.mul(c.neg_two, fixed.ln(uniform_one)));
        const z = fixed.mul(radius, fixed.cosTurns(uniform_two));
        var value = fixed.mul(z, sixth);
        value = fixed.add(value, half_width);
        value = fixed.add(value, start_fixed);
        const result = roundToInt(value);
        if (result >= start and result <= end) return result;
    }
}

fn exponential(
    source: Source,
    rate: fixed.Fixed,
) RngError!fixed.Fixed {
    if (rate.m <= 0) return error.InvalidArgument;
    return fixed.div(fixed.neg(fixed.ln(try nonzeroUniform(source))), rate);
}

fn poisson(source: Source, lambda: fixed.Fixed) RngError!i64 {
    if (lambda.m <= 0) return error.InvalidArgument;
    var sum = fixed.Fixed.zero;
    var count: i64 = 0;
    while (true) {
        const interval = fixed.neg(fixed.ln(try nonzeroUniform(source)));
        sum = fixed.add(sum, interval);
        if (fixed.cmp(sum, lambda) > 0) return count;
        if (count == std.math.maxInt(i64)) return error.InvalidArgument;
        count += 1;
    }
}

fn gamma(source: Source, alpha: fixed.Fixed) RngError!fixed.Fixed {
    const c = constants();
    if (alpha.m <= 0) return error.InvalidArgument;
    if (fixed.cmp(alpha, c.one) < 0) {
        const u = try nonzeroUniform(source);
        const g = try gamma(source, fixed.add(c.one, alpha));
        return fixed.mul(g, fixed.pow(u, fixed.div(c.one, alpha)));
    }

    const third = fixed.div(c.one, fixed.fromInt(3));
    const d = fixed.sub(alpha, third);
    const sqrt_nine_d = fixed.sqrt(fixed.mul(fixed.fromInt(9), d));
    const scale = fixed.div(c.one, sqrt_nine_d);
    const coefficient = fixed.parse("0.0331").?;

    while (true) {
        var x: fixed.Fixed = undefined;
        var v: fixed.Fixed = undefined;
        while (true) {
            x = try normalFloat(source, fixed.Fixed.zero, c.one);
            v = fixed.add(c.one, fixed.mul(scale, x));
            if (fixed.cmp(v, fixed.Fixed.zero) > 0) break;
        }

        var v3 = fixed.mul(v, v);
        v3 = fixed.mul(v3, v);
        const u = try uniform(source);
        const x2 = fixed.mul(x, x);
        const x4 = fixed.mul(x2, x2);
        const quick_limit = fixed.sub(c.one, fixed.mul(coefficient, x4));
        if (fixed.cmp(u, quick_limit) < 0) return fixed.mul(d, v3);

        if (u.m != 0) {
            const lhs = fixed.ln(u);
            const half_x2 = fixed.mul(c.half, x2);
            var correction = fixed.sub(c.one, v3);
            correction = fixed.add(correction, fixed.ln(v3));
            const rhs = fixed.add(half_x2, fixed.mul(d, correction));
            if (fixed.cmp(lhs, rhs) < 0) return fixed.mul(d, v3);
        }
    }
}

fn beta(
    source: Source,
    alpha: fixed.Fixed,
    beta_parameter: fixed.Fixed,
) RngError!fixed.Fixed {
    if (alpha.m <= 0 or beta_parameter.m <= 0) return error.InvalidArgument;
    const x = try gamma(source, alpha);
    const y = try gamma(source, beta_parameter);
    return fixed.div(x, fixed.add(x, y));
}

fn curveFraction(index: usize, denominator: usize) fixed.Fixed {
    return fixed.div(
        fixed.fromInt(@intCast(index)),
        fixed.fromInt(@intCast(denominator)),
    );
}

fn curveHeight(relative: fixed.Fixed) u16 {
    if (relative.m <= 0) return 0;
    const one = fixed.fromInt(1);
    if (fixed.cmp(relative, one) >= 0) return std.math.maxInt(u16);
    const scaled = fixed.mul(relative, fixed.fromInt(std.math.maxInt(u16)));
    const value = fixed.toIntTrunc(scaled);
    if (value <= 0) return 0;
    if (value >= std.math.maxInt(u16)) return std.math.maxInt(u16);
    return @intCast(value);
}

fn curveRelative(score: fixed.Fixed, maximum: fixed.Fixed) fixed.Fixed {
    const difference = fixed.sub(score, maximum);
    if (difference.m >= 0) return fixed.fromInt(1);
    // Anything below exp(-64) is far below one 16-bit chart-height unit.
    // Returning exact zero also keeps extreme-but-valid user parameters away
    // from fixed.exp's intentionally bounded range reduction.
    if (fixed.cmp(difference, fixed.fromInt(-64)) < 0) return fixed.Fixed.zero;
    return fixed.exp(difference);
}

fn normalCurve(
    mean: fixed.Fixed,
    stddev: fixed.Fixed,
    heights: []u16,
    x_min: *Fixed,
    x_max: *Fixed,
) void {
    const four = fixed.fromInt(4);
    const eight = fixed.fromInt(8);
    const two = fixed.fromInt(2);
    const spread = fixed.mul(four, stddev);
    x_min.* = Fixed.fromInternal(fixed.sub(mean, spread));
    x_max.* = Fixed.fromInternal(fixed.add(mean, spread));
    for (heights, 0..) |*height, i| {
        const fraction = curveFraction(i, heights.len - 1);
        const z = fixed.sub(fixed.mul(eight, fraction), four);
        const score = fixed.neg(fixed.div(fixed.mul(z, z), two));
        height.* = curveHeight(fixed.exp(score));
    }
}

fn exponentialCurve(
    rate: fixed.Fixed,
    heights: []u16,
    x_min: *Fixed,
    x_max: *Fixed,
) void {
    const six = fixed.fromInt(6);
    x_min.* = Fixed.fromInternal(fixed.Fixed.zero);
    x_max.* = Fixed.fromInternal(fixed.div(six, rate));
    for (heights, 0..) |*height, i| {
        const fraction = curveFraction(i, heights.len - 1);
        const score = fixed.neg(fixed.mul(six, fraction));
        height.* = curveHeight(fixed.exp(score));
    }
}

fn poissonCurve(
    lambda: fixed.Fixed,
    heights: []u16,
    written: *usize,
    x_min: *Fixed,
    x_max: *Fixed,
) void {
    const mode = fixed.toIntTrunc(lambda);
    const radius = fixed.toIntTrunc(fixed.mul(
        fixed.fromInt(6),
        fixed.sqrt(lambda),
    )) + 1;
    const minimum = @max(@as(i64, 0), mode - radius);
    const maximum = mode + radius;
    const integer_count: usize = @intCast(maximum - minimum + 1);
    const count = @min(integer_count, heights.len);
    written.* = count;
    x_min.* = Fixed.fromInternal(fixed.fromInt(minimum));
    x_max.* = Fixed.fromInternal(fixed.fromInt(maximum));

    var probability = fixed.fromInt(1);
    var current = mode;
    while (current > minimum) : (current -= 1) {
        probability = fixed.mul(probability, fixed.div(fixed.fromInt(current), lambda));
    }

    const x_span: u64 = @intCast(maximum - minimum);
    const denominator: u64 = @intCast(count - 1);
    for (heights[0..count], 0..) |*height, i| {
        const numerator = @as(u64, @intCast(i)) * x_span + denominator / 2;
        const target = minimum + @as(i64, @intCast(numerator / denominator));
        while (current < target) {
            current += 1;
            probability = fixed.mul(
                probability,
                fixed.div(lambda, fixed.fromInt(current)),
            );
        }
        height.* = curveHeight(probability);
    }
}

fn logNormalScore(
    sigma_squared: fixed.Fixed,
    x_max_scaled: fixed.Fixed,
    index: usize,
    denominator: usize,
) fixed.Fixed {
    const x = fixed.mul(x_max_scaled, curveFraction(index, denominator));
    const log_x = fixed.ln(x);
    const shifted = fixed.add(log_x, sigma_squared);
    return fixed.neg(fixed.div(
        fixed.mul(shifted, shifted),
        fixed.mul(fixed.fromInt(2), sigma_squared),
    ));
}

fn logNormalCurve(
    mean: fixed.Fixed,
    stddev: fixed.Fixed,
    heights: []u16,
    x_min: *Fixed,
    x_max: *Fixed,
) void {
    const span_unbounded = fixed.div(
        fixed.mul(stddev, fixed.fromInt(13)),
        fixed.fromInt(8),
    );
    const twenty = fixed.fromInt(20);
    const span = if (fixed.cmp(span_unbounded, twenty) < 0) span_unbounded else twenty;
    const x_max_scaled = fixed.exp(span);
    x_min.* = Fixed.fromInternal(fixed.Fixed.zero);
    x_max.* = Fixed.fromInternal(fixed.exp(fixed.add(mean, span)));

    const sigma_squared = fixed.mul(stddev, stddev);
    var maximum = logNormalScore(sigma_squared, x_max_scaled, 1, heights.len - 1);
    for (2..heights.len) |i| {
        const score = logNormalScore(sigma_squared, x_max_scaled, i, heights.len - 1);
        if (fixed.cmp(score, maximum) > 0) maximum = score;
    }
    heights[0] = 0;
    for (heights[1..], 1..) |*height, i| {
        height.* = curveHeight(curveRelative(
            logNormalScore(sigma_squared, x_max_scaled, i, heights.len - 1),
            maximum,
        ));
    }
}

fn betaScore(
    alpha_minus_one: fixed.Fixed,
    beta_minus_one: fixed.Fixed,
    index: usize,
    count: usize,
) fixed.Fixed {
    const numerator = fixed.fromInt(@intCast(index * 2 + 1));
    const denominator = fixed.fromInt(@intCast(count * 2));
    const x = fixed.div(numerator, denominator);
    const one_minus_x = fixed.sub(fixed.fromInt(1), x);
    return fixed.add(
        fixed.mul(alpha_minus_one, fixed.ln(x)),
        fixed.mul(beta_minus_one, fixed.ln(one_minus_x)),
    );
}

fn betaCurve(
    alpha: fixed.Fixed,
    beta_parameter: fixed.Fixed,
    heights: []u16,
    x_min: *Fixed,
    x_max: *Fixed,
) void {
    x_min.* = Fixed.fromInternal(fixed.Fixed.zero);
    x_max.* = Fixed.fromInternal(fixed.fromInt(1));
    const alpha_minus_one = fixed.sub(alpha, fixed.fromInt(1));
    const beta_minus_one = fixed.sub(beta_parameter, fixed.fromInt(1));
    var maximum = betaScore(alpha_minus_one, beta_minus_one, 0, heights.len);
    for (1..heights.len) |i| {
        const score = betaScore(alpha_minus_one, beta_minus_one, i, heights.len);
        if (fixed.cmp(score, maximum) > 0) maximum = score;
    }
    for (heights, 0..) |*height, i| {
        height.* = curveHeight(curveRelative(
            betaScore(alpha_minus_one, beta_minus_one, i, heights.len),
            maximum,
        ));
    }
}

pub export fn randomz_drbg_init(
    state: ?*Drbg,
    seed_material: ?[*]const u8,
) callconv(.c) c_int {
    const target = state orelse return @intFromEnum(Status.invalid_argument);
    const seed = seed_material orelse return @intFromEnum(Status.invalid_argument);
    var kdf = Blake3.initKdf(kdf_context, .{});
    defer std.crypto.secureZero(u8, std.mem.asBytes(&kdf));
    kdf.update(seed[0..32]);
    kdf.final(&target.key);
    target.position = 0;
    return @intFromEnum(Status.ok);
}

pub export fn randomz_drbg_set_state(
    state: ?*Drbg,
    key: ?[*]const u8,
    position: u64,
) callconv(.c) c_int {
    const target = state orelse return @intFromEnum(Status.invalid_argument);
    const source_key = key orelse return @intFromEnum(Status.invalid_argument);
    if (position > max_exact_position) return @intFromEnum(Status.position_overflow);
    @memcpy(&target.key, source_key[0..32]);
    target.position = position;
    return @intFromEnum(Status.ok);
}

pub export fn randomz_drbg_get_state(
    state: ?*const Drbg,
    key: ?[*]u8,
    position: ?*u64,
) callconv(.c) c_int {
    const source = state orelse return @intFromEnum(Status.invalid_argument);
    const target_key = key orelse return @intFromEnum(Status.invalid_argument);
    const target_position = position orelse return @intFromEnum(Status.invalid_argument);
    @memcpy(target_key[0..32], &source.key);
    target_position.* = source.position;
    return @intFromEnum(Status.ok);
}

pub export fn randomz_drbg_seek(state: ?*Drbg, position: u64) callconv(.c) c_int {
    const target = state orelse return @intFromEnum(Status.invalid_argument);
    if (position > max_exact_position) return @intFromEnum(Status.position_overflow);
    target.position = position;
    return @intFromEnum(Status.ok);
}

pub export fn randomz_drbg_fill(
    state: ?*Drbg,
    out: ?[*]u8,
    count: usize,
) callconv(.c) c_int {
    const target = state orelse return @intFromEnum(Status.invalid_argument);
    if (count == 0) return @intFromEnum(Status.ok);
    const output = out orelse return @intFromEnum(Status.invalid_argument);
    drbgFill(target, output[0..count]) catch |err| return errorStatus(err);
    return @intFromEnum(Status.ok);
}

pub export fn randomz_drbg_u32(
    state: ?*Drbg,
    out: ?*u32,
) callconv(.c) c_int {
    const target = state orelse return @intFromEnum(Status.invalid_argument);
    const output = out orelse return @intFromEnum(Status.invalid_argument);
    var bytes_out: [4]u8 = undefined;
    drbgFill(target, &bytes_out) catch |err| return errorStatus(err);
    output.* = (@as(u32, bytes_out[0]) << 24) |
        (@as(u32, bytes_out[1]) << 16) |
        (@as(u32, bytes_out[2]) << 8) |
        bytes_out[3];
    return @intFromEnum(Status.ok);
}

pub export fn randomz_drbg_u64(
    state: ?*Drbg,
    out: ?*u64,
) callconv(.c) c_int {
    const target = state orelse return @intFromEnum(Status.invalid_argument);
    const output = out orelse return @intFromEnum(Status.invalid_argument);
    var bytes_out: [8]u8 = undefined;
    drbgFill(target, &bytes_out) catch |err| return errorStatus(err);
    var value: u64 = 0;
    for (bytes_out) |byte| value = (value << 8) | byte;
    output.* = value;
    return @intFromEnum(Status.ok);
}

pub export fn randomz_drbg_zeroize(state: ?*Drbg) callconv(.c) void {
    const target = state orelse return;
    std.crypto.secureZero(u8, @as([*]volatile u8, @ptrCast(target))[0..@sizeOf(Drbg)]);
}

fn invalidateCache(target: *BufferedDrbg) void {
    std.crypto.secureZero(u8, &target.cache);
    target.cache_start = 0;
    target.cache_len = 0;
}

pub export fn randomz_buffered_drbg_init(state: ?*BufferedDrbg, seed: ?[*]const u8) callconv(.c) c_int {
    const target = state orelse return errorStatus(error.InvalidArgument);
    const status = randomz_drbg_init(&target.state, seed);
    if (status == 0) invalidateCache(target);
    return status;
}

pub export fn randomz_buffered_drbg_set_state(state: ?*BufferedDrbg, key: ?[*]const u8, position: u64) callconv(.c) c_int {
    const target = state orelse return errorStatus(error.InvalidArgument);
    const status = randomz_drbg_set_state(&target.state, key, position);
    if (status == 0) invalidateCache(target);
    return status;
}

pub export fn randomz_buffered_drbg_get_state(state: ?*const BufferedDrbg, key: ?[*]u8, position: ?*u64) callconv(.c) c_int {
    const target = state orelse return errorStatus(error.InvalidArgument);
    return randomz_drbg_get_state(&target.state, key, position);
}

pub export fn randomz_buffered_drbg_seek(state: ?*BufferedDrbg, position: u64) callconv(.c) c_int {
    const target = state orelse return errorStatus(error.InvalidArgument);
    const status = randomz_drbg_seek(&target.state, position);
    if (status == 0) invalidateCache(target);
    return status;
}

/// Amortize small deterministic draws while advancing only the logical cursor.
/// Bulk requests bypass the cache. Validate the complete request before writes.
pub export fn randomz_buffered_drbg_fill(state: ?*BufferedDrbg, out: ?[*]u8, count: usize) callconv(.c) c_int {
    const target = state orelse return errorStatus(error.InvalidArgument);
    if (count == 0) return 0;
    const output = out orelse return errorStatus(error.InvalidArgument);
    if (target.state.position > max_exact_position or count > max_exact_position - target.state.position)
        return errorStatus(error.PositionOverflow);
    if (count >= target.cache.len) {
        drbgFill(&target.state, output[0..count]) catch |err| return errorStatus(err);
        invalidateCache(target);
        return 0;
    }
    if (target.cache_len > target.cache.len) return errorStatus(error.InvalidArgument);
    var written: usize = 0;
    while (written < count) {
        if (target.cache_len == 0 or target.state.position < target.cache_start or
            target.state.position - target.cache_start >= target.cache_len)
        {
            invalidateCache(target);
            target.cache_start = target.state.position / target.cache.len * target.cache.len;
            target.cache_len = @min(target.cache.len, max_exact_position - target.cache_start);
            var hasher = Blake3.init(.{ .key = target.state.key });
            defer std.crypto.secureZero(u8, std.mem.asBytes(&hasher));
            hasher.finalizeSeek(target.cache_start, target.cache[0..@intCast(target.cache_len)]);
        }
        const offset: usize = @intCast(target.state.position - target.cache_start);
        const take = @min(count - written, @as(usize, @intCast(target.cache_len)) - offset);
        @memcpy(output[written..][0..take], target.cache[offset..][0..take]);
        written += take;
        target.state.position += take;
    }
    return 0;
}

pub export fn randomz_buffered_drbg_zeroize(state: ?*BufferedDrbg) callconv(.c) void {
    const target = state orelse return;
    std.crypto.secureZero(u8, @as([*]volatile u8, @ptrCast(target))[0..@sizeOf(BufferedDrbg)]);
}

fn sourceFrom(fill: ?FillFn, context: ?*anyopaque) RngError!Source {
    return .{ .fill = fill orelse return error.InvalidArgument, .context = context };
}

pub export fn randomz_range(
    fill: ?FillFn,
    context: ?*anyopaque,
    start: i64,
    end: i64,
    out: ?*i64,
) callconv(.c) c_int {
    const output = out orelse return @intFromEnum(Status.invalid_argument);
    const source = sourceFrom(fill, context) catch |err| return errorStatus(err);
    output.* = range(source, start, end) catch |err|
        return errorStatus(err);
    return @intFromEnum(Status.ok);
}

pub export fn randomz_uniform(
    fill: ?FillFn,
    context: ?*anyopaque,
    out: ?*Fixed,
) callconv(.c) c_int {
    const output = out orelse return @intFromEnum(Status.invalid_argument);
    const source = sourceFrom(fill, context) catch |err| return errorStatus(err);
    output.* = Fixed.fromInternal(uniform(source) catch |err|
        return errorStatus(err));
    return @intFromEnum(Status.ok);
}

pub export fn randomz_normal_int(
    fill: ?FillFn,
    context: ?*anyopaque,
    start: i64,
    end: i64,
    out: ?*i64,
) callconv(.c) c_int {
    const output = out orelse return @intFromEnum(Status.invalid_argument);
    const source = sourceFrom(fill, context) catch |err| return errorStatus(err);
    output.* = normalInt(source, start, end) catch |err|
        return errorStatus(err);
    return @intFromEnum(Status.ok);
}

pub export fn randomz_normal(
    fill: ?FillFn,
    context: ?*anyopaque,
    mean: Fixed,
    stddev: Fixed,
    out: ?*Fixed,
) callconv(.c) c_int {
    if (!validFixed(mean) or !validFixed(stddev) or stddev.m <= 0)
        return @intFromEnum(Status.invalid_argument);
    if (!exponentIn(mean, -1_000_000, 1_000_000) or
        !exponentIn(stddev, -1_000_000, 1_000_000))
        return @intFromEnum(Status.numeric_error);
    const output = out orelse return @intFromEnum(Status.invalid_argument);
    const source = sourceFrom(fill, context) catch |err| return errorStatus(err);
    output.* = Fixed.fromInternal(normalFloat(
        source,
        mean.internal(),
        stddev.internal(),
    ) catch |err| return errorStatus(err));
    return @intFromEnum(Status.ok);
}

pub export fn randomz_exponential(
    fill: ?FillFn,
    context: ?*anyopaque,
    rate: Fixed,
    out: ?*Fixed,
) callconv(.c) c_int {
    if (!validFixed(rate) or rate.m <= 0) return @intFromEnum(Status.invalid_argument);
    if (!exponentIn(rate, -1_000_000, 1_000_000))
        return @intFromEnum(Status.numeric_error);
    const output = out orelse return @intFromEnum(Status.invalid_argument);
    const source = sourceFrom(fill, context) catch |err| return errorStatus(err);
    output.* = Fixed.fromInternal(exponential(
        source,
        rate.internal(),
    ) catch |err| return errorStatus(err));
    return @intFromEnum(Status.ok);
}

pub export fn randomz_poisson(
    fill: ?FillFn,
    context: ?*anyopaque,
    lambda: Fixed,
    out: ?*i64,
) callconv(.c) c_int {
    if (!validFixed(lambda) or lambda.m <= 0) return @intFromEnum(Status.invalid_argument);
    // The exact sum-of-exponentials algorithm is linear in lambda. Keep the
    // one-shot API bounded until the planned large-lambda algorithm lands.
    if (!exponentIn(lambda, -1_000_000, 19))
        return @intFromEnum(Status.numeric_error);
    const output = out orelse return @intFromEnum(Status.invalid_argument);
    const source = sourceFrom(fill, context) catch |err| return errorStatus(err);
    output.* = poisson(source, lambda.internal()) catch |err|
        return errorStatus(err);
    return @intFromEnum(Status.ok);
}

pub export fn randomz_log_normal(
    fill: ?FillFn,
    context: ?*anyopaque,
    mean: Fixed,
    stddev: Fixed,
    out: ?*Fixed,
) callconv(.c) c_int {
    if (!validFixed(mean) or !validFixed(stddev) or stddev.m <= 0)
        return @intFromEnum(Status.invalid_argument);
    // These conservative bounds keep every possible 32-bit-uniform
    // Box-Muller draw inside fixed.exp's total representable domain.
    if (!exponentIn(mean, -1_000_000, 27) or
        !exponentIn(stddev, -1_000_000, 23))
        return @intFromEnum(Status.numeric_error);
    const output = out orelse return @intFromEnum(Status.invalid_argument);
    const source = sourceFrom(fill, context) catch |err| return errorStatus(err);
    const normal_value = normalFloat(
        source,
        mean.internal(),
        stddev.internal(),
    ) catch |err| return errorStatus(err);
    if (normal_value.m != 0 and normal_value.e > 28)
        return @intFromEnum(Status.numeric_error);
    output.* = Fixed.fromInternal(fixed.exp(normal_value));
    return @intFromEnum(Status.ok);
}

pub export fn randomz_beta(
    fill: ?FillFn,
    context: ?*anyopaque,
    alpha: Fixed,
    beta_parameter: Fixed,
    out: ?*Fixed,
) callconv(.c) c_int {
    if (!validFixed(alpha) or !validFixed(beta_parameter) or
        alpha.m <= 0 or beta_parameter.m <= 0)
        return @intFromEnum(Status.invalid_argument);
    // alpha < 2^-20 can drive u^(1/alpha) beyond exp's total domain;
    // the upper limit also bounds intermediate exponents and resource use.
    if (!exponentIn(alpha, -20, 20) or !exponentIn(beta_parameter, -20, 20))
        return @intFromEnum(Status.numeric_error);
    const output = out orelse return @intFromEnum(Status.invalid_argument);
    const source = sourceFrom(fill, context) catch |err| return errorStatus(err);
    output.* = Fixed.fromInternal(beta(
        source,
        alpha.internal(),
        beta_parameter.internal(),
    ) catch |err| return errorStatus(err));
    return @intFromEnum(Status.ok);
}

pub export fn randomz_distribution_curve(
    distribution_value: c_int,
    first: Fixed,
    second: Fixed,
    heights: ?[*]u16,
    capacity: usize,
    written: ?*usize,
    x_min: ?*Fixed,
    x_max: ?*Fixed,
) callconv(.c) c_int {
    const distribution: Distribution = switch (distribution_value) {
        1 => .normal,
        2 => .exponential,
        3 => .poisson,
        4 => .log_normal,
        5 => .beta,
        else => return @intFromEnum(Status.invalid_argument),
    };
    if (!validFixed(first) or !validFixed(second) or
        capacity < 2 or capacity > curve_max_samples)
        return @intFromEnum(Status.invalid_argument);
    const output = heights orelse return @intFromEnum(Status.invalid_argument);
    const output_count = written orelse return @intFromEnum(Status.invalid_argument);
    const minimum = x_min orelse return @intFromEnum(Status.invalid_argument);
    const maximum = x_max orelse return @intFromEnum(Status.invalid_argument);
    const samples = output[0..capacity];
    output_count.* = capacity;

    switch (distribution) {
        .normal => {
            if (second.m <= 0) return @intFromEnum(Status.invalid_argument);
            if (!exponentIn(first, -1_000_000, 1_000_000) or
                !exponentIn(second, -1_000_000, 1_000_000))
                return @intFromEnum(Status.numeric_error);
            normalCurve(first.internal(), second.internal(), samples, minimum, maximum);
        },
        .exponential => {
            if (first.m <= 0 or second.m != 0)
                return @intFromEnum(Status.invalid_argument);
            if (!exponentIn(first, -1_000_000, 1_000_000))
                return @intFromEnum(Status.numeric_error);
            exponentialCurve(first.internal(), samples, minimum, maximum);
        },
        .poisson => {
            if (first.m <= 0 or second.m != 0)
                return @intFromEnum(Status.invalid_argument);
            if (!exponentIn(first, -1_000_000, 19))
                return @intFromEnum(Status.numeric_error);
            poissonCurve(first.internal(), samples, output_count, minimum, maximum);
        },
        .log_normal => {
            if (second.m <= 0) return @intFromEnum(Status.invalid_argument);
            if (!exponentIn(first, -1_000_000, 27) or
                !exponentIn(second, -1_000_000, 23))
                return @intFromEnum(Status.numeric_error);
            logNormalCurve(first.internal(), second.internal(), samples, minimum, maximum);
        },
        .beta => {
            if (first.m <= 0 or second.m <= 0)
                return @intFromEnum(Status.invalid_argument);
            if (!exponentIn(first, -20, 20) or !exponentIn(second, -20, 20))
                return @intFromEnum(Status.numeric_error);
            betaCurve(first.internal(), second.internal(), samples, minimum, maximum);
        },
    }
    return @intFromEnum(Status.ok);
}

pub export fn randomz_fixed_from_int(value: i64) callconv(.c) Fixed {
    return Fixed.fromInternal(fixed.fromInt(value));
}

pub export fn randomz_fixed_to_int_trunc(value: Fixed, out: ?*i64) callconv(.c) c_int {
    if (!validFixed(value)) return @intFromEnum(Status.invalid_argument);
    const output = out orelse return @intFromEnum(Status.invalid_argument);
    output.* = fixed.toIntTrunc(value.internal());
    return @intFromEnum(Status.ok);
}

pub export fn randomz_fixed_to_int_round(value: Fixed, out: ?*i64) callconv(.c) c_int {
    if (!validFixed(value)) return @intFromEnum(Status.invalid_argument);
    const output = out orelse return @intFromEnum(Status.invalid_argument);
    output.* = roundToInt(value.internal());
    return @intFromEnum(Status.ok);
}

pub export fn randomz_fixed_parse(
    text: ?[*]const u8,
    length: usize,
    out: ?*Fixed,
) callconv(.c) c_int {
    const input = text orelse return @intFromEnum(Status.invalid_argument);
    const output = out orelse return @intFromEnum(Status.invalid_argument);
    const parsed = fixed.parse(input[0..length]) orelse
        return @intFromEnum(Status.invalid_argument);
    output.* = Fixed.fromInternal(parsed);
    return @intFromEnum(Status.ok);
}

pub export fn randomz_fixed_parse_int_safe(
    text: ?[*]const u8,
    length: usize,
    out: ?*i64,
) callconv(.c) c_int {
    const input = text orelse return @intFromEnum(Status.invalid_argument);
    const output = out orelse return @intFromEnum(Status.invalid_argument);
    output.* = fixed.parseIntSafe(input[0..length]) orelse
        return @intFromEnum(Status.invalid_argument);
    return @intFromEnum(Status.ok);
}

pub export fn randomz_fixed_format(
    value: Fixed,
    decimal_places: usize,
    out: ?[*]u8,
    capacity: usize,
    written: ?*usize,
) callconv(.c) c_int {
    if (!validFixed(value)) return @intFromEnum(Status.invalid_argument);
    const output = out orelse return @intFromEnum(Status.invalid_argument);
    const output_length = written orelse return @intFromEnum(Status.invalid_argument);
    if (decimal_places > capacity) return @intFromEnum(Status.buffer_too_small);
    const rendered = fixed.toString(
        value.internal(),
        decimal_places,
        output[0..capacity],
    ) catch |err| return switch (err) {
        error.BufferTooSmall => @intFromEnum(Status.buffer_too_small),
        error.IntegerPartTooLong => @intFromEnum(Status.numeric_error),
    };
    output_length.* = rendered.len;
    return @intFromEnum(Status.ok);
}

test "buffered DRBG preserves XOF bytes, logical position, seeks, and wiping" {
    var buffered: BufferedDrbg = undefined;
    const seed = [_]u8{0x39} ** 32;
    try std.testing.expectEqual(@as(c_int, 0), randomz_buffered_drbg_init(&buffered, &seed));
    var plain: Drbg = undefined;
    try std.testing.expectEqual(@as(c_int, 0), randomz_drbg_init(&plain, &seed));
    const starts = [_]u64{ 0, 1, 63, 64, 1023, 1024, 1025, max_exact_position - 5000 };
    const counts = [_]usize{ 0, 1, 4, 8, 63, 64, 1023, 1024, 2049 };
    for (starts) |start| {
        try std.testing.expectEqual(@as(c_int, 0), randomz_buffered_drbg_seek(&buffered, start));
        try std.testing.expectEqual(@as(c_int, 0), randomz_drbg_seek(&plain, start));
        for (counts) |count| {
            var expected: [2049]u8 = undefined;
            var actual: [2049]u8 = undefined;
            try std.testing.expectEqual(@as(c_int, 0), randomz_drbg_fill(&plain, &expected, count));
            try std.testing.expectEqual(@as(c_int, 0), randomz_buffered_drbg_fill(&buffered, &actual, count));
            try std.testing.expectEqualSlices(u8, expected[0..count], actual[0..count]);
            try std.testing.expectEqual(plain.position, buffered.state.position);
        }
    }
    try std.testing.expectEqual(@as(c_int, 0), randomz_buffered_drbg_seek(&buffered, 0));
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), randomz_buffered_drbg_fill(&buffered, &byte, 1));
    try std.testing.expectEqual(@as(u64, 1), buffered.state.position);
    try std.testing.expectEqual(@as(u64, 1024), buffered.cache_len);
    var key: [32]u8 = undefined;
    var position: u64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), randomz_buffered_drbg_get_state(&buffered, &key, &position));
    try std.testing.expectEqual(@as(u64, 1), position);
    try std.testing.expectEqual(@as(c_int, 0), randomz_buffered_drbg_set_state(&buffered, &key, 0));
    try std.testing.expectEqual(@as(u64, 0), buffered.cache_len);
    for (buffered.cache) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try std.testing.expectEqual(@as(c_int, 0), randomz_buffered_drbg_seek(&buffered, max_exact_position - 1));
    var untouched = [_]u8{0xa5} ** 2;
    try std.testing.expectEqual(@as(c_int, 3), randomz_buffered_drbg_fill(&buffered, &untouched, 2));
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5 }, &untouched);
    try std.testing.expectEqual(max_exact_position - 1, buffered.state.position);
    try std.testing.expectEqual(@as(c_int, 0), randomz_buffered_drbg_fill(&buffered, &byte, 1));
    try std.testing.expectEqual(max_exact_position, buffered.state.position);
    try std.testing.expectEqual(@as(c_int, 0), randomz_buffered_drbg_fill(&buffered, null, 0));
    try std.testing.expectEqual(@as(c_int, 3), randomz_buffered_drbg_fill(&buffered, &byte, 1));
    randomz_buffered_drbg_zeroize(&buffered);
    for (std.mem.asBytes(&buffered)) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "distribution curves are normalized, parameter-aware, and bounded" {
    const zero = Fixed.fromInternal(fixed.Fixed.zero);
    const one = Fixed.fromInternal(fixed.fromInt(1));
    const two = Fixed.fromInternal(fixed.fromInt(2));
    const three = Fixed.fromInternal(fixed.fromInt(3));
    var heights: [64]u16 = undefined;
    var written: usize = 0;
    var x_min: Fixed = undefined;
    var x_max: Fixed = undefined;

    try std.testing.expectEqual(@as(c_int, 0), randomz_distribution_curve(
        @intFromEnum(Distribution.exponential),
        two,
        zero,
        &heights,
        heights.len,
        &written,
        &x_min,
        &x_max,
    ));
    try std.testing.expectEqual(heights.len, written);
    try std.testing.expectEqual(std.math.maxInt(u16), heights[0]);
    try std.testing.expect(heights[heights.len - 1] < heights[0]);
    try std.testing.expectEqual(@as(i64, 0), fixed.toIntTrunc(x_min.internal()));
    try std.testing.expectEqual(@as(i64, 3), fixed.toIntTrunc(x_max.internal()));

    try std.testing.expectEqual(@as(c_int, 0), randomz_distribution_curve(
        @intFromEnum(Distribution.poisson),
        one,
        zero,
        &heights,
        heights.len,
        &written,
        &x_min,
        &x_max,
    ));
    try std.testing.expectEqual(@as(usize, 9), written);
    try std.testing.expectEqual(std.math.maxInt(u16), heights[0]);
    try std.testing.expectEqual(std.math.maxInt(u16), heights[1]);

    try std.testing.expectEqual(@as(c_int, 0), randomz_distribution_curve(
        @intFromEnum(Distribution.beta),
        one,
        three,
        &heights,
        heights.len,
        &written,
        &x_min,
        &x_max,
    ));
    try std.testing.expect(heights[0] > heights[heights.len - 1]);
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.invalid_argument)),
        randomz_distribution_curve(
            @intFromEnum(Distribution.normal),
            zero,
            one,
            &heights,
            1,
            &written,
            &x_min,
            &x_max,
        ),
    );
}

fn testDrbgFill(context: ?*anyopaque, out: [*]u8, count: usize) callconv(.c) c_int {
    const state: *Drbg = @ptrCast(@alignCast(context.?));
    drbgFill(state, out[0..count]) catch |err| return errorStatus(err);
    return 0;
}

const ScriptedDraws = struct {
    draws: []const u64,
    calls: usize = 0,
    fail_on_call: ?usize = null,
};

fn scriptedFill(context: ?*anyopaque, out: [*]u8, count: usize) callconv(.c) c_int {
    const script: *ScriptedDraws = @ptrCast(@alignCast(context.?));
    script.calls += 1;
    if (script.fail_on_call == script.calls or script.calls > script.draws.len) return 2;
    const draw = script.draws[script.calls - 1];
    if (count == 4) {
        const value: u32 = @truncate(draw);
        out[0] = @truncate(value >> 24);
        out[1] = @truncate(value >> 16);
        out[2] = @truncate(value >> 8);
        out[3] = @truncate(value);
        return 0;
    }
    if (count == 8) {
        for (0..8) |i| out[i] = @truncate(draw >> @intCast(56 - i * 8));
        return 0;
    }
    return 2;
}

test "C ABI DRBG reproduces the Lua oracle's seed-42 stream" {
    var seed = [_]u8{0} ** 32;
    seed[31] = 42;
    var state: Drbg = undefined;
    try std.testing.expectEqual(@as(c_int, 0), randomz_drbg_init(&state, &seed));

    var actual: [64]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), randomz_drbg_fill(&state, &actual, actual.len));
    var expected_buffer: [64]u8 = undefined;
    const expected = try std.fmt.hexToBytes(
        &expected_buffer,
        "69dfe2e9b579cf6dfe3d71b11024db6eb49d5b9861505b3ecfc3d379a6dc8f04" ++
            "b6900db333d20760661226da010db589c5080aaf5f6068fc0874ce62aca36f60",
    );
    try std.testing.expectEqualSlices(u8, expected, &actual);
    try std.testing.expectEqual(@as(u64, 64), state.position);
}

test "generic callback range dogfoods the exported DRBG state" {
    var seed = [_]u8{0} ** 32;
    seed[31] = 42;
    var state: Drbg = undefined;
    _ = randomz_drbg_init(&state, &seed);
    const source = Source{ .fill = testDrbgFill, .context = &state };
    const expected = [_]i64{ 97, 53, 65, 26, 80, 90, 69, 88, 3, 64 };
    for (expected) |want| try std.testing.expectEqual(want, try range(source, 0, 99));
}

test "bounded sampling forces u32/u64 rejection, exact divisors, and retry failure" {
    var u32_reject = ScriptedDraws{ .draws = &.{ 0xffff_ffff, 123 } };
    try std.testing.expectEqual(
        @as(i64, 23),
        try range(.{ .fill = scriptedFill, .context = &u32_reject }, 0, 99),
    );
    try std.testing.expectEqual(@as(usize, 2), u32_reject.calls);

    const wide_span: u64 = 0x1_0000_0001;
    var u64_reject = ScriptedDraws{ .draws = &.{ std.math.maxInt(u64), wide_span + 7 } };
    try std.testing.expectEqual(
        @as(i64, 7),
        try range(.{ .fill = scriptedFill, .context = &u64_reject }, 0, wide_span - 1),
    );
    try std.testing.expectEqual(@as(usize, 2), u64_reject.calls);

    var u32_exact = ScriptedDraws{ .draws = &.{0xffff_ffff} };
    try std.testing.expectEqual(
        @as(i64, 255),
        try range(.{ .fill = scriptedFill, .context = &u32_exact }, 0, 255),
    );
    try std.testing.expectEqual(@as(usize, 1), u32_exact.calls);

    const power_two_span: u64 = 0x2_0000_0000;
    var u64_exact = ScriptedDraws{ .draws = &.{std.math.maxInt(u64)} };
    try std.testing.expectEqual(
        @as(i64, @intCast(power_two_span - 1)),
        try range(.{ .fill = scriptedFill, .context = &u64_exact }, 0, power_two_span - 1),
    );
    try std.testing.expectEqual(@as(usize, 1), u64_exact.calls);

    var failed_retry = ScriptedDraws{
        .draws = &.{ 0xffff_ffff, 0 },
        .fail_on_call = 2,
    };
    try std.testing.expectError(
        error.FillFailed,
        range(.{ .fill = scriptedFill, .context = &failed_retry }, 0, 99),
    );
    try std.testing.expectEqual(@as(usize, 2), failed_retry.calls);
}

test "C ABI state seek, chunking, overflow, and null callback contracts" {
    var seed = [_]u8{0} ** 32;
    seed[31] = 42;
    var initial: Drbg = undefined;
    try std.testing.expectEqual(@as(c_int, 0), randomz_drbg_init(&initial, &seed));

    var first: [17]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), randomz_drbg_fill(&initial, &first, first.len));
    var key: [32]u8 = undefined;
    var position: u64 = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        randomz_drbg_get_state(&initial, &key, &position),
    );
    try std.testing.expectEqual(@as(u64, 17), position);

    var resumed: Drbg = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        randomz_drbg_set_state(&resumed, &key, position),
    );
    var rest: [47]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), randomz_drbg_fill(&resumed, &rest, rest.len));

    var one_shot_state: Drbg = undefined;
    _ = randomz_drbg_init(&one_shot_state, &seed);
    var one_shot: [64]u8 = undefined;
    _ = randomz_drbg_fill(&one_shot_state, &one_shot, one_shot.len);
    try std.testing.expectEqualSlices(u8, one_shot[0..17], &first);
    try std.testing.expectEqualSlices(u8, one_shot[17..], &rest);

    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.ok)),
        randomz_drbg_set_state(&resumed, &key, max_exact_position),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.ok)),
        randomz_drbg_fill(&resumed, null, 0),
    );
    var byte: u8 = undefined;
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.position_overflow)),
        randomz_drbg_fill(&resumed, @ptrCast(&byte), 1),
    );
    try std.testing.expectEqual(max_exact_position, resumed.position);

    var sampled: i64 = undefined;
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.invalid_argument)),
        randomz_range(null, null, 0, 1, &sampled),
    );
}
