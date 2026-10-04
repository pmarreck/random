-- Independent unsigned-BLIP fixtures pin large geometric counts without a
-- floating-point conversion or the signed interpretation used by blip_mp.
local count = require("unsigned_count")
local function hex(bytes)
	return (bytes:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
end
local fixtures = {
	{"0", "00"},
	{"1", "01"},
	{"127", "7f"},
	{"128", "8180"},
	{"255", "81ff"},
	{"256", "820001"},
	{"1000", "82e803"},
	{"18446744073709551615", "88" .. string.rep("ff", 8)},
	{"18446744073709551616", "89" .. string.rep("00", 8) .. "01"},
	{"340282366920938463463374607431768211456", "91" .. string.rep("00", 16) .. "01"},
}
for _, fixture in ipairs(fixtures) do
	local value = count.from_decimal(fixture[1])
	assert(count.to_decimal(value) == fixture[1], fixture[1])
	assert(hex(count.to_blip(value)) == fixture[2], fixture[1])
end
assert(count.to_hex(count.from_decimal("0")) == "0")
assert(count.to_hex(count.from_decimal("256")) == "100")
assert(count.to_hex(count.from_decimal("18446744073709551616")) == "10000000000000000")
-- Thirty-two payload bytes exercise BLIP's five-bit length continuation.
local wide = count.from_bytes(string.rep("\0", 31) .. "\1")
assert(hex(count.to_blip(wide)) == "a001" .. string.rep("00", 31) .. "01")
assert(count.from_bytes("\0\0") == count.from_decimal("0"))
assert(count.from_bytes("\1\0\0") == count.from_decimal("1"))
assert(count.to_decimal(count.double_add(count.from_decimal("18446744073709551615"), 1)) ==
	"36893488147419103231")
assert(count.to_decimal(count.increment(count.from_decimal("18446744073709551615"))) ==
	"18446744073709551616")
assert(count.to_decimal(count.append_low_bits(count.from_decimal("1"), "\255", 1)) == "3")
assert(count.to_decimal(count.append_low_bits(count.from_decimal("1"), "\1\255", 9)) == "769")
assert(count.to_decimal(count.append_low_bits(count.from_decimal("1"), string.rep("\0", 8), 64)) ==
	"18446744073709551616")
assert(count.append_low_bits(count.from_decimal("255"), "", 0) == count.from_decimal("255"))
for _, text in ipairs({"", "-1", "1.5", "1e3", " 1", "1 ", "0x10"}) do
	assert(not pcall(count.from_decimal, text), "accepted invalid decimal: " .. text)
end
assert(not pcall(count.double_add, count.from_decimal("1"), 2))
assert(not pcall(count.append_low_bits, "\1", "", 1))
assert(not pcall(count.append_low_bits, "\1", "\0", 0.5))
print("Unsigned count and BLIP fixtures passed")
