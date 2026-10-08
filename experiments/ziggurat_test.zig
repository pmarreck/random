//! Directed controls precede the experimental sampler; no production import changes.
const std = @import("std");
const fx = @import("fixed");
const zig = @import("candidate");

const Script = struct {
	words: []const u64,
	i: usize = 0,
	pub fn next(self: *@This()) error{End}!u64 {
		if (self.i == self.words.len) return error.End;
		defer self.i += 1;
		return self.words[self.i];
	}
};
fn word(i: u8, negative: bool, j: u64) u64 {
	return (j << 9) | (@as(u64, @intFromBool(negative)) << 8) | i;
}

test "strip sign and coordinate use disjoint bits" {
	for (0..256) |i| {
		for ([_]bool{ false, true }) |negative| {
			for (0..55) |bit| {
				const j = @as(u64, 1) << @intCast(bit);
				const draw = zig.decode(word(@intCast(i), negative, j));
				try std.testing.expectEqual(i, draw.strip);
				try std.testing.expectEqual(negative, draw.negative);
				try std.testing.expectEqual(j, draw.coordinate);
			}
		}
	}
}

test "every strip fast path consumes one word with exact sign symmetry" {
	for (zig.tables.strips, 0..) |strip, i| {
		if (strip.k == 0) continue;
		const words = [_]u64{word(@intCast(i), false, strip.k - 1)};
		var positive = Script{ .words = &words };
		const a = try zig.normal(&positive);
		const neg_words = [_]u64{word(@intCast(i), true, strip.k - 1)};
		var negative = Script{ .words = &neg_words };
		try std.testing.expectEqual(fx.neg(a), try zig.normal(&negative));
		try std.testing.expectEqual(@as(usize, 1), positive.i);
		try std.testing.expectEqual(@as(usize, 1), negative.i);
		try std.testing.expect(fx.cmp(a, zig.tables.strips[(i + 1) % 256].x) <= 0 or i == 255);
	}
}

test "wedge acceptance consumes another uniform; rejection reselects the strip" {
	for (1..256) |i| {
		const words = [_]u64{ word(@intCast(i), false, zig.scale - 1), 0 };
		var source = Script{ .words = &words };
		_ = try zig.normal(&source);
		try std.testing.expectEqual(@as(usize, 2), source.i);
	}
	const words = [_]u64{ word(255, false, zig.scale - 1), std.math.maxInt(u64), word(42, true, 123) };
	var source = Script{ .words = &words };
	const result = try zig.normal(&source);
	var expected = Script{ .words = words[2..] };
	try std.testing.expectEqual(try zig.normal(&expected), result);
	try std.testing.expectEqual(@as(usize, 3), source.i);
}

test "all threshold neighbors and binary64 integer boundaries retain exact coordinates" {
	for (zig.tables.strips, 0..) |strip, i| {
		const candidates = [_]u64{ 0, 1, strip.k -| 1, strip.k, @min(strip.k + 1, zig.scale - 1),
			(1 << 53) - 1, 1 << 53, (1 << 53) + 1, zig.scale - 1 };
		for (candidates) |j| for ([_]bool{false, true}) |negative| {
			const header = word(@intCast(i), negative, j);
			const tail = i == 0 and j >= strip.k;
			const words = [_]u64{ header, if (tail) std.math.maxInt(u64) else 0, std.math.maxInt(u64) };
			var source = Script{ .words = &words };
			const actual = try zig.normal(&source);
			const magnitude = if (tail) zig.tables.strips[1].x else
				fx.mul(if (j == 0) fx.Fixed.zero else fx.norm(@intCast(j), 7), strip.x);
			try std.testing.expectEqual(if (negative) fx.neg(magnitude) else magnitude, actual);
			const consumed: usize = if (j < strip.k) 1 else if (tail) 3 else 2;
			try std.testing.expectEqual(consumed, source.i);
		};
	}
}

test "tail acceptance and local retry preserve sign and source failures" {
	// U=1 gives -ln(U)=0; the opposite endpoint forces a rejected tail attempt.
	const words = [_]u64{ word(0, true, zig.scale - 1), 0, std.math.maxInt(u64), std.math.maxInt(u64), std.math.maxInt(u64) };
	var source = Script{ .words = &words };
	try std.testing.expectEqual(fx.neg(zig.tables.strips[1].x), try zig.normal(&source));
	try std.testing.expectEqual(@as(usize, 5), source.i);
	for (0..words.len) |length| {
		var truncated = Script{ .words = words[0..length] };
		try std.testing.expectError(error.End, zig.normal(&truncated));
		try std.testing.expectEqual(length, truncated.i);
	}
}
