-- LuaJIT half of the `lib/fixed.lua` <-> `src/fixed.zig` differential.
--
-- Walks the IDENTICAL sweep as src/differential_driver.zig and prints the same
-- `TAG idx m e` format. tests/zig_differential requires the two outputs to be
-- byte-identical.
--
-- lib/fixed.lua is the ORACLE here: it is an independent implementation that
-- already passes 224 kernel checks, a `bc` sweep at 650+ cases per function,
-- 99 golden vectors blessed before it existed, and a four-platform
-- cross-architecture differential. It was not written for this port and cannot
-- be adjusted to agree with it.
--
-- The operand generator below is reimplemented rather than shared with the Zig
-- side -- there is nothing to share it through. Any disagreement in the
-- generator itself is a defect worth failing on, so the duplication is a
-- feature.

package.path = (arg[0] or ""):match("^(.*)/[^/]+$") .. "/../lib/?.lua;" .. package.path
local ffi = require("ffi")
local fx = require("fixed")

local i64 = ffi.typeof("int64_t")
local TWO62 = 0x4000000000000000ULL

-- Formats an int64 cdata as plain decimal digits. tostring() on an int64 cdata
-- yields a VALUE with an "LL" suffix ("-123LL"), which must be stripped to
-- match Zig's "{d}".
--
-- The enclosing parentheses are load-bearing: gsub returns TWO values (the
-- string and a replacement count), and Lua expands multiple returns in the
-- final argument position -- without them this would silently pass an extra
-- argument to whatever consumes it. That exact trap bit this project three
-- times in one session.
--
-- Note also that this is only safe for 64-BIT cdata. tostring() on an int32_t
-- or uint32_t cdata prints a boxed ADDRESS, not a value; hashing those is the
-- mistake behind two retracted LuaJIT bug reports here.
local function i64s(v)
	return (tostring(v):gsub("LL$", ""))
end

-- --- operand generator; must match src/differential_driver.zig exactly ------
local lcg_state = 0x243F6A8885A308D3ULL
local function next_raw()
	lcg_state = lcg_state * 6364136223846793005ULL + 1442695040888963407ULL
	return lcg_state / 4ULL          -- unsigned divide == logical shift right 2
end
local function next_mantissa_magnitude()
	return TWO62 + (next_raw() % TWO62)
end

local E_SET = { 0, 1, -1, 62, -62, 1000, -1000 }
local SHIFTS = { 0, 1, 2, 3, 7, 15, 31, 47, 62, 63 }

-- Powers of two as u64 cdata, built by repeated multiplication. NOT `2ULL ^ n`:
-- Lua's `^` is FLOAT exponentiation, which would round-trip the operand through
-- a double and defeat the entire point of an integer-only comparison. Same
-- reason lib/fixed.lua never uses `^` either.
local POW2 = {}
do
	local p = 1ULL
	for k = 0, 63 do
		POW2[k] = p
		p = p * 2ULL
	end
end

-- Built as cdata rather than Lua number literals: values past 2^53 are not
-- exactly representable as doubles, and -9223372036854775808 cannot be written
-- as a Lua literal at all (it parses as unary minus applied to a value one past
-- the positive range).
local INT_EDGES = {
	ffi.cast(i64, 0), ffi.cast(i64, 1), ffi.cast(i64, -1),
	ffi.cast(i64, 2), ffi.cast(i64, -2), ffi.cast(i64, 3),
	ffi.cast(i64, -3), ffi.cast(i64, 1000000), ffi.cast(i64, -1000000),
	ffi.cast(i64, 2147483647), ffi.cast(i64, -2147483648),
	ffi.cast(i64, 4503599627370496), ffi.cast(i64, -4503599627370496),
	ffi.cast(i64, 9007199254740992), ffi.cast(i64, -9007199254740992),
	ffi.cast(i64, 0x4000000000000000ULL), -ffi.cast(i64, 0x4000000000000000ULL),
	ffi.cast(i64, 0x7FFFFFFFFFFFFFFFULL), ffi.cast(i64, 0x8000000000000000ULL),
}

local MIN_I64 = ffi.cast(i64, 0x8000000000000000ULL)
local MAX_I64 = ffi.cast(i64, 0x7FFFFFFFFFFFFFFFULL)
local TWO62_I = ffi.cast(i64, 0x4000000000000000ULL)

local NORM_EDGES = {
	{ ffi.cast(i64, 0), 0 },   { ffi.cast(i64, 0), 100 },  { ffi.cast(i64, 0), -100 },
	{ MIN_I64, 0 },            { MIN_I64, 5 },             { MIN_I64, -5 },
	{ TWO62_I, 0 },            { -TWO62_I, 0 },
	{ MAX_I64, 0 },            { -MAX_I64, 0 },
	{ ffi.cast(i64, 1), 0 },   { ffi.cast(i64, -1), 0 },
	{ ffi.cast(i64, 1), 62 },  { ffi.cast(i64, -1), -62 },
	{ ffi.cast(i64, 3), 7 },   { ffi.cast(i64, -3), -7 },
}

local count = tonumber(arg[1] or "200") or 200
local out = {}

-- --- A: fromInt ------------------------------------------------------------
local idx = 0
for i = 1, #INT_EDGES do
	local m, e = fx.from_int(INT_EDGES[i])
	out[#out + 1] = string.format("A %d %s %d", idx, i64s(m), e)
	idx = idx + 1
end
for _ = 1, count do
	local v = ffi.cast(i64, next_raw())
	local m, e = fx.from_int(v)
	out[#out + 1] = string.format("A %d %s %d", idx, i64s(m), e)
	idx = idx + 1
end

-- --- B: norm ---------------------------------------------------------------
idx = 0
for i = 1, #NORM_EDGES do
	local m, e = fx.norm(NORM_EDGES[i][1], NORM_EDGES[i][2])
	out[#out + 1] = string.format("B %d %s %d", idx, i64s(m), e)
	idx = idx + 1
end
for i = 0, count - 1 do
	local mag = next_mantissa_magnitude()
	local e = E_SET[(i % #E_SET) + 1]
	for j = 1, #SHIFTS do
		local sh = SHIFTS[j]
		-- Unsigned divide by 2^sh == logical shift right, matching Zig's `>>`
		-- on a u64. LuaJIT's `bit` library is 32-bit-only, so 64-bit shifts go
		-- through arithmetic, exactly as lib/fixed.lua itself does.
		local shifted = ffi.cast(i64, mag / POW2[sh])
		local pm, pe = fx.norm(shifted, e)
		out[#out + 1] = string.format("B %d %s %d", idx, i64s(pm), pe)
		idx = idx + 1
		local nm, ne = fx.norm(-shifted, e)
		out[#out + 1] = string.format("B %d %s %d", idx, i64s(nm), ne)
		idx = idx + 1
	end
end

io.write(table.concat(out, "\n"), "\n")
