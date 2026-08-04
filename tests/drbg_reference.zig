//! Independent Zig 0.16 reference check for the LuaJIT DRBG contract.
//!
//! Input is canonical 32-byte seed material as 64 hexadecimal digits plus an
//! output byte count. This derives the key with Zig stdlib BLAKE3 KDF,
//! initializes keyed BLAKE3 over the empty message, and prints XOF bytes as
//! lowercase hex. It shares no implementation code with the original LuaJIT
//! producer. It is an independent control, not the behavioral oracle for the
//! later Zig port; that role belongs to the LuaJIT implementation.

const std = @import("std");

const kdf_context = "random drbg 2026-08-04 v1";
const hex_digits = "0123456789abcdef";

fn nibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len != 3 or argv[1].len != 64) return error.InvalidArguments;

    var seed: [32]u8 = undefined;
    for (0..32) |i| {
        seed[i] = (try nibble(argv[1][i * 2])) << 4 |
            try nibble(argv[1][i * 2 + 1]);
    }

    const count = try std.fmt.parseInt(usize, argv[2], 10);
    if (count > 4096) return error.OutputTooLarge;

    var kdf = std.crypto.hash.Blake3.initKdf(kdf_context, .{});
    kdf.update(&seed);
    var key: [std.crypto.hash.Blake3.key_length]u8 = undefined;
    kdf.final(&key);

    var drbg = std.crypto.hash.Blake3.init(.{ .key = key });
    var bytes: [4096]u8 = undefined;
    drbg.finalizeSeek(0, bytes[0..count]);

    var encoded: [8192]u8 = undefined;
    for (bytes[0..count], 0..) |b, i| {
        encoded[i * 2] = hex_digits[b >> 4];
        encoded[i * 2 + 1] = hex_digits[b & 0x0f];
    }

    var writer_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &writer_buf);
    try stdout_writer.interface.writeAll(encoded[0 .. count * 2]);
    try stdout_writer.interface.flush();
}
