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

-- --- L: cos_turns ----------------------------------------------------------
local COS_RAW_EDGES = {
	{ ffi.cast(i64, 0), 0 },
	{ TWO62_I, -2 },                                    -- 1/4
	{ TWO62_I, -1 },                                    -- 1/2
	{ ffi.cast(i64, 0x6000000000000000ULL), -1 },       -- 3/4
	{ TWO62_I, 1 },                                     -- 1 -> wraps to 0
	{ ffi.cast(i64, 0x4000000000000001ULL), -2 },       -- just past 1/4
	{ MAX_I64, -3 },                                    -- just under 1/4 (normalized!)
	{ MAX_I64, -1 },                                    -- just under 1
	{ -TWO62_I, -2 },                                   -- negative: frac-wrap
	{ -TWO62_I, -1 },
}
idx = 0
for i = 1, #COS_RAW_EDGES do
	local rm, re = fx.cos_turns(COS_RAW_EDGES[i][1], COS_RAW_EDGES[i][2])
	out[#out + 1] = string.format("L %d %s %d", idx, i64s(rm), re)
	idx = idx + 1
end
for i = 0, count - 1 do
	local mag = ffi.cast(i64, next_mantissa_magnitude())
	local e = (i % 4) - 4
	local pm, pe = fx.cos_turns(mag, e)
	out[#out + 1] = string.format("L %d %s %d", idx, i64s(pm), pe); idx = idx + 1
	local nm2, ne2 = fx.cos_turns(-mag, e)
	out[#out + 1] = string.format("L %d %s %d", idx, i64s(nm2), ne2); idx = idx + 1
	local wm, we = fx.cos_turns(mag, 3)                 -- u well outside [0,1)
	out[#out + 1] = string.format("L %d %s %d", idx, i64s(wm), we); idx = idx + 1
end

-- --- M: sqrt ---------------------------------------------------------------
local SQRT_INT_EDGES = {
	0, 1, 2, 3, 4, 5, 9, 15, 16, 17, 64, 65, 1024, 65536, 65537,
	4503599627370496, 9007199254740992, 9007199254740993LL,
}
local SQRT_E_SET = { -62, -30, -8, -2, 0, 2, 8, 30, 62, 1000, -1000 }
idx = 0
for i = 1, #SQRT_INT_EDGES do
	local am, ae = fx.from_int(SQRT_INT_EDGES[i])
	local rm, re = fx.sqrt(am, ae)
	out[#out + 1] = string.format("M %d %s %d", idx, i64s(rm), re)
	idx = idx + 1
end
for i = 0, count - 1 do
	local mag = ffi.cast(i64, next_mantissa_magnitude())
	local e = SQRT_E_SET[(i % #SQRT_E_SET) + 1]
	local rm, re = fx.sqrt(mag, e)
	out[#out + 1] = string.format("M %d %s %d", idx, i64s(rm), re); idx = idx + 1
	local r2m, r2e = fx.sqrt(mag, e + 1)                -- opposite parity
	out[#out + 1] = string.format("M %d %s %d", idx, i64s(r2m), r2e); idx = idx + 1
end

-- --- N: pow ----------------------------------------------------------------
local POW_INT_EDGES = {
	{ 5, 0 },  { 2, 1 },  { 2, 10 }, { 2, -1 }, { 1, 7 },
	{ 3, 3 },  { 10, 3 }, { 7, -2 }, { 1024, 1 }, { 2, 30 },
}
local POW_B_EXP_SET = { -3, -1, 0, 1, 3, 7 }
local POW_Y_EXP_SET = { -3, -2, -1, 0, 1, 2, 3 }
idx = 0
for i = 1, #POW_INT_EDGES do
	local bm, be = fx.from_int(POW_INT_EDGES[i][1])
	local ym, ye = fx.from_int(POW_INT_EDGES[i][2])
	local rm, re = fx.pow(bm, be, ym, ye)
	out[#out + 1] = string.format("N %d %s %d", idx, i64s(rm), re)
	idx = idx + 1
end
for i = 0, count - 1 do
	local bm = ffi.cast(i64, next_mantissa_magnitude())
	local ym = ffi.cast(i64, next_mantissa_magnitude())
	local be = POW_B_EXP_SET[(i % #POW_B_EXP_SET) + 1]
	local ye = POW_Y_EXP_SET[(i % #POW_Y_EXP_SET) + 1]
	local pm, pe = fx.pow(bm, be, ym, ye)
	out[#out + 1] = string.format("N %d %s %d", idx, i64s(pm), pe); idx = idx + 1
	local nm3, ne3 = fx.pow(bm, be, -ym, ye)
	out[#out + 1] = string.format("N %d %s %d", idx, i64s(nm3), ne3); idx = idx + 1
end

-- --- O: parse --------------------------------------------------------------
local PARSE_EDGES = {
	"0",           "42",          "-42",         "+42",        "  42  ",
	"1.5",         "-1.5",        "+1.5",        ".5",         "5.",
	"",            "   ",         "abc",         "1.2.3",      "-",
	"+",           "1x",          ".",           "1 2",        "- 1",
	"0.000000000000000000001",
	"1.234567890123456789012345",
	"9007199254740992",  "9007199254740993",
	"9223372036854775807", "9223372036854775808",
	"18446744073709551616",
	"99999999999999999999999999999999999999999",
	"-9223372036854775808", "0.0", "-0.0", "000042", "0000.5000",
}
-- Deterministic decimal generator; must match genDecimal in the Zig driver.
local function gen_decimal()
	local r = next_raw()
	local int_len = tonumber(r % 25ULL) + 1
	r = r / 25ULL
	local frac_len = tonumber(r % 20ULL)
	r = r / 20ULL
	local negative = (r % 2ULL) == 1ULL
	r = r / 2ULL
	local p = {}
	if negative then p[#p + 1] = "-" end
	for _ = 1, int_len do
		p[#p + 1] = string.char(48 + tonumber(r % 10ULL))
		r = r / 10ULL
		if r == 0ULL then r = next_raw() end
	end
	if frac_len > 0 then
		p[#p + 1] = "."
		for _ = 1, frac_len do
			p[#p + 1] = string.char(48 + tonumber(r % 10ULL))
			r = r / 10ULL
			if r == 0ULL then r = next_raw() end
		end
	end
	return table.concat(p)
end

idx = 0
for i = 1, #PARSE_EDGES do
	local m, e = fx.parse(PARSE_EDGES[i])
	if m == nil then
		out[#out + 1] = string.format("O %d nil", idx)
	else
		out[#out + 1] = string.format("O %d %s %d", idx, i64s(m), e)
	end
	idx = idx + 1
end
for _ = 1, count do
	local s = gen_decimal()
	local m, e = fx.parse(s)
	if m == nil then
		out[#out + 1] = string.format("O %d nil", idx)
	else
		out[#out + 1] = string.format("O %d %s %d", idx, i64s(m), e)
	end
	idx = idx + 1
end

-- --- P: parse_int / parse_int_safe -----------------------------------------
-- Bounded to |v| <= 2^53: past that the REFERENCE routes its result through a
-- double and rounds, where the Zig port returns the exact i64. That divergence
-- is deliberate and unit-pinned on the Zig side; sweeping it here would only
-- re-measure a defect the port intentionally does not have.
local PARSE_INT_EDGES = {
	"0",   "42",  "-42", "+42", "  42  ", "1.5",  "",    "-",   "+",
	"abc", "1x",  "007", "-007",
	"9007199254740992",  "-9007199254740992",
	"9007199254740991",  "-9007199254740991",
	"4503599627370496", "9223372036854775808",
	"99999999999999999999999",
}
-- parseIntSafe-ONLY edges straddling the 2^53 ceiling. parse_int_safe compares
-- the EXACT int64 before any tonumber, so unlike parse_int it is exact on both
-- sides at every magnitude and can be swept past 2^53. Without these the
-- ceiling itself is untested -- a mutant raising it to 2^54 survived 264k cases.
local PARSE_INT_SAFE_EDGES = {
	"9007199254740992",  "-9007199254740992",
	"9007199254740993",  "-9007199254740993",
	"9007199254740994",  "13510798882111488",
	"18014398509481984", "-18014398509481984",
	"18014398509481983", "9007199254740991",
}
-- Integers bounded to |v| <= 2^53; must match genSafeInt in the Zig driver.
local function gen_safe_int()
	local r = next_raw()
	local negative = (r % 2ULL) == 1ULL
	r = r / 2ULL
	local v = r % 9007199254740993ULL
	return (negative and "-" or "") .. u64s(v)
end
local function emit_int(tag, v)
	if v == nil then
		out[#out + 1] = string.format("%s %d nil", tag, idx)
	else
		-- Route through an int64 cdata: parse_int returns a Lua NUMBER, and
		-- tostring on a double past ~1e14 prints in exponent form, which
		-- would never match Zig's "{d}".
		out[#out + 1] = string.format("%s %d %s", tag, idx, i64s(ffi.cast(i64, v)))
	end
	idx = idx + 1
end

idx = 0
for i = 1, #PARSE_INT_EDGES do
	emit_int("P", fx.parse_int(PARSE_INT_EDGES[i]))
	emit_int("P", fx.parse_int_safe(PARSE_INT_EDGES[i]))
end
for i = 1, #PARSE_INT_SAFE_EDGES do
	emit_int("P", fx.parse_int_safe(PARSE_INT_SAFE_EDGES[i]))
end
for _ = 1, count do
	local s = gen_safe_int()
	emit_int("P", fx.parse_int(s))
	emit_int("P", fx.parse_int_safe(s))
end

-- --- Q: tostring -----------------------------------------------------------
local TOSTRING_EDGES = {
	{ ffi.cast(i64, 0), 0 },
	{ TWO62_I, 0 }, { -TWO62_I, 0 },
	{ TWO62_I, -1 },
	{ TWO62_I, 47 }, { TWO62_I, 62 }, { TWO62_I, 63 }, { TWO62_I, 100 },
	{ MAX_I64, 0 }, { -MAX_I64, -3 },
	{ TWO62_I, -62 }, { TWO62_I, -100 },
}
local TOSTRING_E_SET = { -100, -62, -20, -3, -1, 0, 1, 3, 20, 47, 61, 62, 63, 100 }
local PLACES_SET = { 0, 1, 2, 6, 12, 18 }

idx = 0
for i = 1, #TOSTRING_EDGES do
	for j = 1, #PLACES_SET do
		local okc, s = pcall(fx.tostring, TOSTRING_EDGES[i][1], TOSTRING_EDGES[i][2], PLACES_SET[j])
		out[#out + 1] = string.format("Q %d %s", idx, okc and s or "ERR")
		idx = idx + 1
	end
end
for i = 0, count - 1 do
	local mag = ffi.cast(i64, next_mantissa_magnitude())
	local e = TOSTRING_E_SET[(i % #TOSTRING_E_SET) + 1]
	local p = PLACES_SET[(i % #PLACES_SET) + 1]
	local okp, sp = pcall(fx.tostring, mag, e, p)
	out[#out + 1] = string.format("Q %d %s", idx, okp and sp or "ERR"); idx = idx + 1
	local okn, sn = pcall(fx.tostring, -mag, e, p)
	out[#out + 1] = string.format("Q %d %s", idx, okn and sn or "ERR"); idx = idx + 1
end

-- --- R: parse/tostring round trip ------------------------------------------
idx = 0
for i = 0, count - 1 do
	local mag = ffi.cast(i64, next_mantissa_magnitude())
	local e = TOSTRING_E_SET[(i % #TOSTRING_E_SET) + 1]
	local ok1, first = pcall(fx.tostring, mag, e, 6)
	first = ok1 and first or "ERR"
	local bm, be = fx.parse(first)
	if bm == nil then
		out[#out + 1] = string.format("R %d %s nil", idx, first)
	else
		local ok2, second = pcall(fx.tostring, bm, be, 6)
		out[#out + 1] = string.format("R %d %s %s", idx, first, ok2 and second or "ERR")
	end
	idx = idx + 1
end

io.write(table.concat(out, "\n"), "\n")
