//! Prepared geometric block decomposition and caller-buffer unsigned counts.
//! No allocation, I/O, floating-point math, or native-width result ceiling.
const std = @import("std");
const fx = @import("fixed");

pub const Error = error{ InvalidArgument, BufferTooSmall, NumericError };

/// New-mode probability syntax; ordinary Fixed parsers remain unchanged.
pub fn parseProbability(text: []const u8) ?fx.Fixed {
    var value: fx.Fixed = undefined;
    if (std.mem.startsWith(u8, text, "2^")) {
        if (!integerSyntax(text[2..])) return null;
        const exponent = fx.parseIntSafe(text[2..]) orelse return null;
        if (exponent < -1_000_000 or exponent > 0) return null;
        value = .{ .m = @intCast(fx.TWO62), .e = @intCast(exponent) };
    } else if (std.mem.indexOfAny(u8, text, "eE")) |index| {
        const mantissa = text[0..index];
        for (mantissa) |byte| if (!std.ascii.isDigit(byte) and byte != '.') return null;
        value = parseDecimal(mantissa) orelse return null;
        if (!integerSyntax(text[index + 1 ..])) return null;
        const exponent = fx.parseIntSafe(text[index + 1 ..]) orelse return null;
        if (exponent < -1_000_000 or exponent > 1_000_000) return null;
        var remaining: u32 = @intCast(@abs(exponent));
        var factor = fx.fromInt(10);
        var multiplier = fx.fromInt(1);
        while (remaining != 0) {
            if (remaining & 1 != 0) multiplier = fx.mul(multiplier, factor);
            remaining /= 2;
            if (remaining != 0) factor = fx.mul(factor, factor);
        }
        value = if (exponent < 0) fx.div(value, multiplier) else fx.mul(value, multiplier);
    } else value = parseDecimal(text) orelse return null;
    _ = Prepared.init(value) catch return null;
    return value;
}

fn parseDecimal(text: []const u8) ?fx.Fixed {
    const trimmed = std.mem.trim(u8, text, " \t\r\n\x0b\x0c");
    const unsigned = if (trimmed.len != 0 and (trimmed[0] == '+' or trimmed[0] == '-'))
        trimmed[1..]
    else
        trimmed;
    const integer_length = std.mem.indexOfScalar(u8, unsigned, '.') orelse unsigned.len;
    if (integer_length > 2000) return null;
    return fx.parse(text);
}

fn integerSyntax(text: []const u8) bool {
    if (text.len == 0) return false;
    const digits = if (text[0] == '+' or text[0] == '-') text[1..] else text;
    if (digits.len == 0) return false;
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

/// Immutable parameters; 128 significant levels suffice for every accepted p.
pub const Prepared = struct {
    base: u64 = 0,
    levels: [128]u64 = undefined,
    level_count: usize = 0,
    tail_bits: usize = 0,
    certain: bool = false,

    // Compare u64 draws against exact represented dyadic probabilities.
    fn threshold(value: fx.Fixed) Error!u64 {
        if (value.m <= 0 or value.e < -2 or value.e > -1) return error.NumericError;
        return @as(u64, @intCast(value.m)) << @as(u6, @intCast(value.e + 2));
    }

    /// Validate before sampling, then cache the low-bit Bernoulli thresholds.
    pub fn init(probability: fx.Fixed) Error!Prepared {
        if (probability.m < @as(i64, @intCast(fx.TWO62)) or
            probability.e < -1_000_000 or probability.e > 0 or
            fx.cmp(probability, fx.fromInt(1)) > 0) return error.InvalidArgument;
        var prepared: Prepared = .{};
        if (fx.cmp(probability, fx.fromInt(1)) == 0) {
            prepared.certain = true;
            return prepared;
        }
        var p = probability;
        if (p.e < -62) {
            prepared.tail_bits = @intCast(-62 - p.e);
            p.e = -62;
        }
        const one = fx.fromInt(1);
        const two = fx.fromInt(2);
        while (fx.cmp(p, .{ .m = @intCast(fx.TWO62), .e = -1 }) < 0) {
            if (prepared.level_count == prepared.levels.len) return error.NumericError;
            prepared.levels[prepared.level_count] = try threshold(fx.div(fx.sub(one, p), fx.sub(two, p)));
            prepared.level_count += 1;
            // Exact doubling retains odd mantissas; ordinary add(p,p) does not.
            const doubled: fx.Fixed = .{ .m = p.m, .e = p.e + 1 };
            p = fx.sub(doubled, fx.mul(p, p));
        }
        prepared.base = try threshold(p);
        return prepared;
    }
};

// Increment a little-endian magnitude with checked caller storage.
fn increment(out: []u8, length: *usize) Error!void {
    var index: usize = 0;
    while (index < length.* and out[index] == 255) : (index += 1) {}
    if (index == length.* and length.* == out.len) return error.BufferTooSmall;
    @memset(out[0..index], 0);
    if (index == length.*) {
        out[index] = 1;
        length.* += 1;
    } else out[index] += 1;
}

// Append a bit without narrowing the accumulated integer to a machine word.
fn doubleAdd(out: []u8, length: *usize, bit: u1) Error!void {
    var carry: u16 = bit;
    for (out[0..length.*]) |*byte| {
        const value = @as(u16, byte.*) * 2 + carry;
        byte.* = @truncate(value);
        carry = value >> 8;
    }
    if (carry != 0) {
        if (length.* == out.len) return error.BufferTooSmall;
        out[length.*] = @intCast(carry);
        length.* += 1;
    }
}

/// Sample into magnitude storage. Static errors precede source reads; source
/// or capacity failures after drawing may consume bytes and alter scratch.
/// Tail bytes are little-endian low result bits, with high padding discarded.
pub fn sample(prepared: Prepared, source: anytype, out: []u8) !usize {
    if (prepared.certain) return 0;
    const minimum = (prepared.tail_bits + prepared.level_count + 7) / 8;
    if (out.len < minimum) return error.BufferTooSmall;
    var length: usize = 0;
    while (try source.u64be() >= prepared.base) try increment(out, &length);
    var index = prepared.level_count;
    while (index != 0) {
        index -= 1;
        const bit: u1 = if (try source.u64be() < prepared.levels[index]) 1 else 0;
        try doubleAdd(out, &length, bit);
    }
    if (prepared.tail_bits != 0) {
        const whole = prepared.tail_bits / 8;
        const remainder: u3 = @intCast(prepared.tail_bits % 8);
        const tail_length = (prepared.tail_bits + 7) / 8;
        const extra: usize = if (length != 0 and remainder != 0 and
            (out[length - 1] >> @as(u3, @intCast(8 - @as(u4, remainder)))) != 0) 1 else 0;
        const shifted_length = length + whole + extra;
        if (@max(shifted_length, tail_length) > out.len) return error.BufferTooSmall;
        // Move from high bytes downward so the in-place shift cannot overwrite
        // unread source magnitude bytes. The low tail is filled only afterwards.
        var destination = shifted_length;
        while (destination > whole) {
            destination -= 1;
            const original = destination - whole;
            const high: u16 = if (original < length) @as(u16, out[original]) << remainder else 0;
            const low: u16 = if (remainder != 0 and original != 0 and original - 1 < length)
                @as(u16, out[original - 1]) >> @as(u4, @intCast(8 - @as(u4, remainder)))
            else
                0;
            out[destination] = @truncate(high | low);
        }
        const high_partial: u8 = if (remainder != 0 and length != 0) out[whole] else 0;
        try source.bytes(out[0..tail_length]);
        if (remainder != 0) out[whole] = high_partial |
            (out[whole] & ((@as(u8, 1) << remainder) - 1));
        length = @max(shifted_length, tail_length);
        while (length != 0 and out[length - 1] == 0) length -= 1;
    }
    return length;
}

/// Wrap a magnitude already in `out` with its canonical unsigned LE BLIP.
pub fn encodeInPlace(out: []u8, length: usize) Error!usize {
    if (length == 0 or (length == 1 and out[0] < 128)) {
        if (out.len == 0) return error.BufferTooSmall;
        if (length == 0) out[0] = 0;
        return 1;
    }
    var header: [11]u8 = undefined;
    var header_length: usize = 1;
    header[0] = 0x80 | @as(u8, @intCast(length & 31));
    if (length >= 32) {
        header[0] |= 0x20;
        var remaining = length >> 5;
        while (remaining != 0) {
            const next = remaining >> 7;
            header[header_length] = @as(u8, @intCast(remaining & 127)) |
                (if (next != 0) @as(u8, 128) else 0);
            header_length += 1;
            remaining = next;
        }
    }
    if (length > out.len or header_length > out.len - length) return error.BufferTooSmall;
    std.mem.copyBackwards(u8, out[header_length..][0..length], out[0..length]);
    @memcpy(out[0..header_length], header[0..header_length]);
    return header_length + length;
}

/// Validate one canonical unsigned little-endian BLIP, without decoding it
/// into a machine-width integer. Sentinels and overlong encodings are errors.
pub fn magnitude(input: []const u8) Error![]const u8 {
    if (input.len == 0) return error.InvalidArgument;
    if (input[0] < 128) {
        if (input.len != 1) return error.InvalidArgument;
        return if (input[0] == 0) input[0..0] else input;
    }
    if (input[0] & 0x40 != 0) return error.InvalidArgument;
    var length: usize = input[0] & 31;
    var header: usize = 1;
    if (input[0] & 0x20 != 0) {
        var shift: usize = 5;
        while (true) {
            if (header == input.len or shift >= @bitSizeOf(usize)) return error.InvalidArgument;
            const byte = input[header];
            header += 1;
            const low: usize = byte & 127;
            if (low > @as(usize, std.math.maxInt(usize)) >> @as(std.math.Log2Int(usize), @intCast(shift))) return error.InvalidArgument;
            length |= low << @as(std.math.Log2Int(usize), @intCast(shift));
            if (byte & 128 == 0) {
                if (low == 0) return error.InvalidArgument;
                break;
            }
            shift += 7;
        }
    }
    if (length == 0 or length != input.len - header or input[input.len - 1] == 0 or
        (length == 1 and input[header] < 128)) return error.InvalidArgument;
    return input[header..];
}

/// Exact decimal/hex formatting. Scratch holds base-1e9 limbs; caller buffers
/// bound allocation. Neither the full integer nor its decimal passes via f64.
pub fn formatCount(input: []const u8, radix: u8, scratch: []u32, out: []u8) Error!usize {
    const raw = try magnitude(input);
    if (radix != 10 and radix != 16) return error.InvalidArgument;
    if (raw.len == 0) {
        if (out.len == 0) return error.BufferTooSmall;
        out[0] = '0';
        return 1;
    }
    if (radix == 16) {
        const length = raw.len * 2 - @as(usize, if (raw[raw.len - 1] < 16) 1 else 0);
        if (out.len < length) return error.BufferTooSmall;
        const alphabet = "0123456789abcdef";
        var destination: usize = 0;
        var index = raw.len;
        while (index != 0) {
            index -= 1;
            const byte = raw[index];
            if (destination != 0 or byte >= 16) {
                out[destination] = alphabet[byte >> 4];
                destination += 1;
            }
            out[destination] = alphabet[byte & 15];
            destination += 1;
        }
        return destination;
    }
    if (scratch.len < raw.len) return error.BufferTooSmall;
    var limbs: usize = 0;
    var index = raw.len;
    while (index != 0) {
        index -= 1;
        var carry: u64 = raw[index];
        for (scratch[0..limbs]) |*limb| {
            const value = @as(u64, limb.*) * 256 + carry;
            limb.* = @intCast(value % 1_000_000_000);
            carry = value / 1_000_000_000;
        }
        if (carry != 0) {
            scratch[limbs] = @intCast(carry);
            limbs += 1;
        }
    }
    var written: usize = 0;
    while (limbs != 0) {
        limbs -= 1;
        const part = if (written == 0)
            std.fmt.bufPrint(out[written..], "{d}", .{scratch[limbs]}) catch return error.BufferTooSmall
        else
            std.fmt.bufPrint(out[written..], "{d:0>9}", .{scratch[limbs]}) catch return error.BufferTooSmall;
        written += part.len;
    }
    return written;
}
