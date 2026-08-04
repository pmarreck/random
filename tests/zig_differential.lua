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

-- --- C: mul128 -------------------------------------------------------------
-- mul128 returns UNSIGNED halves; tostring on a uint64 cdata yields a value
-- with a "ULL" suffix, so strip that rather than "LL".
local function u64s(v)
	return (tostring(v):gsub("ULL$", ""))
end

local M128_EDGES = {
	{ 0ULL, 0ULL }, { 1ULL, 1ULL },
	{ 0xFFFFFFFFFFFFFFFFULL, 1ULL }, { 1ULL, 0xFFFFFFFFFFFFFFFFULL },
	{ 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL }, { 0x8000000000000000ULL, 2ULL },
	{ 0x100000000ULL, 0x100000000ULL }, { 0xFFFFFFFFULL, 0xFFFFFFFFULL },
	{ 0x100000000ULL, 0xFFFFFFFFULL }, { TWO62, TWO62 },
}
idx = 0
for i = 1, #M128_EDGES do
	local hi, lo = fx.mul128(M128_EDGES[i][1], M128_EDGES[i][2])
	out[#out + 1] = string.format("C %d %s %s", idx, u64s(hi), u64s(lo))
	idx = idx + 1
end
for _ = 1, count do
	local a = next_raw()
	local b = next_raw()
	local hi, lo = fx.mul128(a, b)
	out[#out + 1] = string.format("C %d %s %s", idx, u64s(hi), u64s(lo))
	idx = idx + 1
end

-- --- D: mul ----------------------------------------------------------------
local SIGN_QUADRANTS = { { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }
idx = 0
for i = 0, count - 1 do
	local ma = ffi.cast(i64, next_mantissa_magnitude())
	local mb = ffi.cast(i64, next_mantissa_magnitude())
	local ea = E_SET[(i % #E_SET) + 1]
	local eb = E_SET[((i + 3) % #E_SET) + 1]
	for q = 1, #SIGN_QUADRANTS do
		local sa, sb = SIGN_QUADRANTS[q][1], SIGN_QUADRANTS[q][2]
		local m1 = (sa < 0) and -ma or ma
		local m2 = (sb < 0) and -mb or mb
		local m, e = fx.mul(m1, ea, m2, eb)
		out[#out + 1] = string.format("D %d %s %d", idx, i64s(m), e)
		idx = idx + 1
	end
end

-- --- E: to_int_trunc -------------------------------------------------------
-- to_int_trunc returns a Lua NUMBER, and tostring() on a double at this
-- magnitude prints in exponent form -- tostring(9007199254740992) yields
-- "9.007199254741e+15", which would never match Zig's "{d}". Route it through
-- an int64 cdata so the printed digits are exact. (%d on the double would also
-- work; the cast keeps the formatting path identical to every other section.)
local function intres(v)
	return i64s(ffi.cast(i64, v))
end

local TO_INT_EDGES = {
	{ ffi.cast(i64, 0), 0 }, { ffi.cast(i64, 0), 500 },
	{ TWO62_I, 62 },  { -TWO62_I, 62 },
	{ TWO62_I, 63 },  { -TWO62_I, 63 },
	{ TWO62_I, 0 },   { -TWO62_I, 0 },
	{ TWO62_I, -62 }, { -TWO62_I, -62 },
	{ TWO62_I, -63 }, { -TWO62_I, -63 },
	{ MAX_I64, 53 },  { MIN_I64, 53 },
	{ MAX_I64, 54 },  { MIN_I64, 54 },
	{ ffi.cast(i64, 0x6000000000000000ULL), 1 },
	{ -ffi.cast(i64, 0x6000000000000000ULL), 1 },
}
idx = 0
for i = 1, #TO_INT_EDGES do
	out[#out + 1] = string.format("E %d %s", idx,
		intres(fx.to_int_trunc(TO_INT_EDGES[i][1], TO_INT_EDGES[i][2])))
	idx = idx + 1
end
for i = 0, count - 1 do
	local mag = ffi.cast(i64, next_mantissa_magnitude())
	local e = (i % 130) - 65
	out[#out + 1] = string.format("E %d %s", idx, intres(fx.to_int_trunc(mag, e)))
	idx = idx + 1
	out[#out + 1] = string.format("E %d %s", idx, intres(fx.to_int_trunc(-mag, e)))
	idx = idx + 1
end

-- --- F: add and sub --------------------------------------------------------
-- Edge list mirrors src/differential_driver.zig's ADD_EDGES in order: the
-- pinned 1-ULP and 2-ULP behaviours, total cancellation, zero operands, the
-- d = 62/63/64 gap boundaries, and sign-mixed extremes.
local ADD_EDGES = {
	{ ffi.cast(i64, 0x4000000000000123ULL), 5, ffi.cast(i64, 0x4000000000000122ULL), 5 },
	{ ffi.cast(i64, 0x4000000000000123ULL), 7, ffi.cast(i64, 0x4000000000000123ULL), 7 },
	{ ffi.cast(i64, 0x4000000000000001ULL), 100, TWO62_I, 38 },
	{ TWO62_I, 0, TWO62_I, -62 },
	{ TWO62_I, 0, TWO62_I, -63 },
	{ TWO62_I, 0, TWO62_I, -64 },
	{ ffi.cast(i64, 0), 0, TWO62_I, 3 },
	{ TWO62_I, 3, ffi.cast(i64, 0), 0 },
	{ ffi.cast(i64, 0), 0, ffi.cast(i64, 0), 0 },
	{ MAX_I64, 10, -MAX_I64, 10 },
	{ MAX_I64, 10, MAX_I64, 10 },
}
local D_GAP_SET = { 0, 1, 2, 31, 61, 62, 63, 64, 120 }

idx = 0
for i = 1, #ADD_EDGES do
	local c = ADD_EDGES[i]
	local am, ae = fx.add(c[1], c[2], c[3], c[4])
	out[#out + 1] = string.format("F %d %s %d", idx, i64s(am), ae)
	idx = idx + 1
	local sm, se = fx.sub(c[1], c[2], c[3], c[4])
	out[#out + 1] = string.format("F %d %s %d", idx, i64s(sm), se)
	idx = idx + 1
end
for i = 0, count - 1 do
	local ma = ffi.cast(i64, next_mantissa_magnitude())
	local mb = ffi.cast(i64, next_mantissa_magnitude())
	local e2 = E_SET[(i % #E_SET) + 1]
	local e1 = e2 + D_GAP_SET[(i % #D_GAP_SET) + 1]
	for q = 1, #SIGN_QUADRANTS do
		local m1 = (SIGN_QUADRANTS[q][1] < 0) and -ma or ma
		local m2 = (SIGN_QUADRANTS[q][2] < 0) and -mb or mb
		local am, ae = fx.add(m1, e1, m2, e2)
		out[#out + 1] = string.format("F %d %s %d", idx, i64s(am), ae)
		idx = idx + 1
		local sm, se = fx.sub(m1, e1, m2, e2)
		out[#out + 1] = string.format("F %d %s %d", idx, i64s(sm), se)
		idx = idx + 1
		-- Reversed operand order: smaller exponent first, exercising the swap
		-- branch exactly as often as the no-swap one.
		local rm, re = fx.add(m2, e2, m1, e1)
		out[#out + 1] = string.format("F %d %s %d", idx, i64s(rm), re)
		idx = idx + 1
	end
end

-- --- G: neg and cmp --------------------------------------------------------
idx = 0
for i = 0, count - 1 do
	local ma = ffi.cast(i64, next_mantissa_magnitude())
	local mb = ffi.cast(i64, next_mantissa_magnitude())
	local e1 = E_SET[(i % #E_SET) + 1]
	local e2 = E_SET[((i + 2) % #E_SET) + 1]
	local q = SIGN_QUADRANTS[(i % #SIGN_QUADRANTS) + 1]
	local m1 = (q[1] < 0) and -ma or ma
	local m2 = (q[2] < 0) and -mb or mb
	local nm, ne = fx.neg(m1, e1)
	out[#out + 1] = string.format("G %d %s %d", idx, i64s(nm), ne)
	idx = idx + 1
	out[#out + 1] = string.format("G %d %d", idx, fx.cmp(m1, e1, m2, e2))
	idx = idx + 1
	out[#out + 1] = string.format("G %d %d", idx, fx.cmp(m2, e2, m1, e1))
	idx = idx + 1
	out[#out + 1] = string.format("G %d %d", idx, fx.cmp(m1, e1, m1, e1))
	idx = idx + 1
end

-- --- H: frac ---------------------------------------------------------------
-- Exponent set spans pure fraction (verbatim return), mixed integer+fraction
-- (truncation direction observable), the 2^53 clamp neighbourhood, and
-- past-integer territory. Mirrors the Zig FRAC_E_SET.
local FRAC_E_SET = { -70, -63, -62, -1, 0, 1, 30, 52, 53, 61, 62, 63, 100 }
idx = 0
for i = 0, count - 1 do
	local mag = ffi.cast(i64, next_mantissa_magnitude())
	local e = FRAC_E_SET[(i % #FRAC_E_SET) + 1]
	local pm, pe = fx.frac(mag, e)
	out[#out + 1] = string.format("H %d %s %d", idx, i64s(pm), pe)
	idx = idx + 1
	local nm2, ne2 = fx.frac(-mag, e)
	out[#out + 1] = string.format("H %d %s %d", idx, i64s(nm2), ne2)
	idx = idx + 1
end

-- --- I: div ----------------------------------------------------------------
-- Mirrors the Zig DIV_INT_EDGES/DIV_RAW_EDGES in order. The dyadic inexact
-- ratios (3/2, 5/2) are load-bearing: they are the only inputs where the
-- bit-serial loop's doubled remainder ever EQUALS the divisor exactly, i.e.
-- the only inputs able to distinguish `rem >= b` from `rem > b`.
local DIV_INT_EDGES = {
	{ -1, 3 },  { 1, -3 },  { -1, -3 },
	{ -7, 11 }, { 7, -11 }, { -7, -11 },
	{ 1, 3 },   { 7, 11 },  { 1023, 1024 }, { 1024, 1023 },
	{ 5, 5 },   { -5, -5 }, { 1, 1 },       { -1, 1 },
	{ 8, 2 },   { 8, -2 },
	{ 3, 2 },   { -3, 2 },  { 5, 2 },       { -5, -2 },
	{ 9007199254740992, -7 }, { -9007199254740992, 7 },
}
local DIV_RAW_EDGES = {
	{ ffi.cast(i64, 0x4000000000000001ULL), 0, MAX_I64, 0 },
	{ MAX_I64, 0, ffi.cast(i64, 0x4000000000000001ULL), 0 },
	{ TWO62_I, 5, TWO62_I, -3 },
	{ -MAX_I64, -1000, TWO62_I, 1000 },
}
idx = 0
for i = 1, #DIV_INT_EDGES do
	-- Separate locals, never chained as arguments: from_int returns TWO
	-- values, and Lua expands multiple returns only in the final argument
	-- position -- fx.div(fx.from_int(a), fx.from_int(b)) silently passes
	-- three arguments, the trap this project hit three times while verifying.
	local am, ae = fx.from_int(DIV_INT_EDGES[i][1])
	local bm, be = fx.from_int(DIV_INT_EDGES[i][2])
	local rm, re = fx.div(am, ae, bm, be)
	out[#out + 1] = string.format("I %d %s %d", idx, i64s(rm), re)
	idx = idx + 1
end
for i = 1, #DIV_RAW_EDGES do
	local c = DIV_RAW_EDGES[i]
	local rm, re = fx.div(c[1], c[2], c[3], c[4])
	out[#out + 1] = string.format("I %d %s %d", idx, i64s(rm), re)
	idx = idx + 1
end
for i = 0, count - 1 do
	local ma = ffi.cast(i64, next_mantissa_magnitude())
	local mb = ffi.cast(i64, next_mantissa_magnitude())
	local e1 = E_SET[(i % #E_SET) + 1]
	local e2 = E_SET[((i + 4) % #E_SET) + 1]
	for q = 1, #SIGN_QUADRANTS do
		local m1 = (SIGN_QUADRANTS[q][1] < 0) and -ma or ma
		local m2 = (SIGN_QUADRANTS[q][2] < 0) and -mb or mb
		local rm, re = fx.div(m1, e1, m2, e2)
		out[#out + 1] = string.format("I %d %s %d", idx, i64s(rm), re)
		idx = idx + 1
	end
end

-- --- J: ln -----------------------------------------------------------------
-- Mirrors the Zig LN_INT_EDGES / LN_RAW_EDGES in order.
local LN_INT_EDGES = { 1, 2, 15, 1024 }
local LN_RAW_EDGES = {
	{ TWO62_I, 0 },
	{ MAX_I64, 0 },
	{ ffi.cast(i64, 0x4000000000000001ULL), 0 },
	{ TWO62_I, 1000 },
	{ TWO62_I, -1000 },
}
idx = 0
for i = 1, #LN_INT_EDGES do
	local am, ae = fx.from_int(LN_INT_EDGES[i])
	local rm, re = fx.ln(am, ae)
	out[#out + 1] = string.format("J %d %s %d", idx, i64s(rm), re)
	idx = idx + 1
end
for i = 1, #LN_RAW_EDGES do
	local rm, re = fx.ln(LN_RAW_EDGES[i][1], LN_RAW_EDGES[i][2])
	out[#out + 1] = string.format("J %d %s %d", idx, i64s(rm), re)
	idx = idx + 1
end
for i = 0, count - 1 do
	local mag = ffi.cast(i64, next_mantissa_magnitude())
	local e = E_SET[(i % #E_SET) + 1]
	local rm, re = fx.ln(mag, e)
	out[#out + 1] = string.format("J %d %s %d", idx, i64s(rm), re)
	idx = idx + 1
end

-- --- K: exp ----------------------------------------------------------------
-- Exponents capped at 29, not 30: at e=30 a mantissa past ~1.49 pushes
-- k = x/ln2 beyond i32 and exp correctly REFUSES (error() here, panic in
-- Zig); the sweep must stay where both implementations return values.
local EXP_INT_EDGES = { 0, 1, -1, 20, -20, 700, -700 }
local EXP_E_SET = { -63, -30, -7, -3, -1, 0, 1, 3, 7, 20, 29 }
idx = 0
for i = 1, #EXP_INT_EDGES do
	local am, ae = fx.from_int(EXP_INT_EDGES[i])
	local rm, re = fx.exp(am, ae)
	out[#out + 1] = string.format("K %d %s %d", idx, i64s(rm), re)
	idx = idx + 1
end
do
	-- Range-reduction boundary operands, built by the kernel's own
	-- arithmetic exactly as the Zig driver builds them.
	local h_m, h_e = fx.div(fx.LN2_M, fx.LN2_E, fx.from_int(2))
	local nh_m, nh_e = fx.neg(h_m, h_e)
	local nl_m, nl_e = fx.neg(fx.LN2_M, fx.LN2_E)
	local EXP_RAW_EDGES = {
		{ fx.LN2_M, fx.LN2_E }, { nl_m, nl_e },
		{ h_m, h_e },           { nh_m, nh_e },
		{ TWO62_I, 29 },        { -TWO62_I, 29 },
		{ TWO62_I, -63 },
	}
	for i = 1, #EXP_RAW_EDGES do
		local rm, re = fx.exp(EXP_RAW_EDGES[i][1], EXP_RAW_EDGES[i][2])
		out[#out + 1] = string.format("K %d %s %d", idx, i64s(rm), re)
		idx = idx + 1
	end
end
for i = 0, count - 1 do
	local mag = ffi.cast(i64, next_mantissa_magnitude())
	local e = EXP_E_SET[(i % #EXP_E_SET) + 1]
	local pm, pe = fx.exp(mag, e)
	out[#out + 1] = string.format("K %d %s %d", idx, i64s(pm), pe)
	idx = idx + 1
	local nm2, ne2 = fx.exp(-mag, e)
	out[#out + 1] = string.format("K %d %s %d", idx, i64s(nm2), ne2)
	idx = idx + 1
end

io.write(table.concat(out, "\n"), "\n")
