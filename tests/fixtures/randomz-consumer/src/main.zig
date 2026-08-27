const std = @import("std");
const randomz = @import("randomz");

test "a downstream Zig package consumes the public randomz module" {
    var seed = [_]u8{0} ** 32;
    seed[31] = 42;
    var state: randomz.Drbg = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        randomz.randomz_drbg_init(&state, &seed),
    );

    var actual: [64]u8 = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        randomz.randomz_drbg_fill(&state, &actual, actual.len),
    );
    var expected_buffer: [64]u8 = undefined;
    const expected = try std.fmt.hexToBytes(
        &expected_buffer,
        "69dfe2e9b579cf6dfe3d71b11024db6eb49d5b9861505b3ecfc3d379a6dc8f04" ++
            "b6900db333d20760661226da010db589c5080aaf5f6068fc0874ce62aca36f60",
    );
    try std.testing.expectEqualSlices(u8, expected, &actual);
}
