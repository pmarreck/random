//! Verify actual upstream ELF emission for both native architectures, with
//! positive and negative relocation cases; this is not a simulated writer.
const std = @import("std");
const elf = @import("src/backend/dev/object/elf.zig");

fn integer(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

fn section(bytes: []const u8, name: []const u8) ![]const u8 {
    const table: usize = @intCast(integer(u64, bytes, 40));
    const width = integer(u16, bytes, 58);
    const count = integer(u16, bytes, 60);
    const names_header = table + width * integer(u16, bytes, 62);
    const names: usize = @intCast(integer(u64, bytes, names_header + 24));
    for (0..count) |index| {
        const header = table + width * index;
        const start = names + integer(u32, bytes, header);
        const length = std.mem.indexOfScalar(u8, bytes[start..], 0) orelse return error.InvalidELF;
        if (std.mem.eql(u8, bytes[start..][0..length], name)) return bytes[header..][0..width];
    }
    return error.MissingSection;
}

fn checkCase(arch: elf.Architecture, relocatable: bool) !void {
    var writer = try elf.ElfWriter.init(std.testing.allocator, arch, .none);
    defer writer.deinit();
    const data = [_]u8{0xa5} ** 16;
    writer.setRodata(&data);
    const target = try writer.addSymbol(.{
        .name = "constant",
        .section = .rodata,
        .offset = 8,
        .size = 8,
        .is_global = true,
        .is_function = false,
        .is_hidden = true,
    });
    if (relocatable) try writer.addRodataRelocation(0, target, 8);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try writer.write(&output);
    const bytes = output.items;
    try std.testing.expectEqual(@as(u16, if (arch == .x86_64) 62 else 183), integer(u16, bytes, 18));
    const constants = try section(bytes, if (relocatable) ".data.rel.ro" else ".rodata");
    try std.testing.expectEqual(@as(u64, if (relocatable) 3 else 2), integer(u64, constants, 8));
    try std.testing.expectEqual(@as(u64, 16), integer(u64, constants, 32));
    const offset: usize = @intCast(integer(u64, constants, 24));
    try std.testing.expectEqualSlices(u8, &data, bytes[offset..][0..16]);
    const relocations = try section(bytes, if (relocatable) ".rela.data.rel.ro" else ".rela.rodata");
    try std.testing.expectEqual(@as(u64, if (relocatable) 24 else 0), integer(u64, relocations, 32));
    try std.testing.expectEqual(@as(u32, 2), integer(u32, relocations, 44));
    if (relocatable) {
        const relocation: usize = @intCast(integer(u64, relocations, 24));
        const kind = integer(u64, bytes, relocation + 8) & 0xffffffff;
        try std.testing.expectEqual(@as(u64, if (arch == .x86_64) 1 else 257), kind);
        try std.testing.expectEqual(@as(i64, 8), integer(i64, bytes, relocation + 16));
    }
}

test "Roc ELF constant relocation section policy" {
    try checkCase(.x86_64, false);
    try checkCase(.x86_64, true);
    try checkCase(.aarch64, false);
    try checkCase(.aarch64, true);
}
