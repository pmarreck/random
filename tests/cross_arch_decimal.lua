-- Cross-architecture payload for the kernel's DECIMAL I/O and integer paths.
--
-- tests/kernel_jit_diff.lua already sweeps ten kernel functions (div, mul, add,
-- sub, norm, ln, exp, cos_turns, sqrt, pow) and cross_arch_diff reuses it
-- verbatim as its main payload. This file covers the public surface that sweep
-- does NOT touch: parse, tostring, parse_int, parse_int_safe, from_int,
-- to_int_trunc, frac, cmp, mul128.
--
-- That gap matters specifically for a cross-platform claim. Decimal I/O is
-- exactly where a platform-dependent strtod/printf would re-enter a program
-- that had otherwise been made integer-only -- the kernel exists to keep
-- `tonumber` off input and `%f` off output, and this is the payload that would
-- notice if either came back.
--
-- Per-function digests rather than one global digest: a single rolled-up
-- number tells you only THAT something diverged. cross_arch_diff diffs these
-- lines, so a mismatch names the function.
--
-- No math.*, no float literals, no `^` -- same discipline as
-- kernel_jit_diff.lua, walking the same integer-only paths real callers do.

package.path = (arg[0] or ""):match("^(.*)/[^/]+$") .. "/../lib/?.lua;" .. package.path
local ffi = require("ffi")
local fx = require("fixed")

local u64 = ffi.typeof("uint64_t")

-- `FAST=` (set but empty) must mean fast mode: os.getenv returns "" (not nil)
-- for a set-but-empty var and "" is TRUTHY in Lua. Same trap, same fix, as
-- kernel_bc_sweep.lua and kernel_jit_diff.lua -- normalized here rather than
-- re-derived (and possibly re-broken) independently.
local fast = os.getenv("FAST")
if fast == "" then fast = nil end
local COUNT = fast and 4000 or 20000

local DIGEST_SEED = 0xCBF29CE484222325ULL   -- FNV-64 offset basis, used only as
local DIGEST_MULT = 0x100000001B3ULL        -- an arbitrary fixed seed / odd
                                            -- mixing constant. No cryptographic
                                            -- ambition: it only has to make one
                                            -- differing value change the total.
local digest = DIGEST_SEED

local function mix_u64(v)
	digest = (digest + ffi.cast(u64, v)) * DIGEST_MULT
end

-- nil is a real, meaningful result here (parse rejects malformed input, and
-- parse_int_safe rejects magnitudes that would lose precision as a double), so
-- it gets a distinct sentinel rather than being skipped. Skipping would make a
-- toolchain that rejected EVERYTHING digest-identical to one that rejected
-- nothing, which is precisely the vacuous-comparison failure this suite guards.
local NIL_SENTINEL = 0xD1FFD1FFD1FFD1FFULL
local function mix_maybe(v)
	if v == nil then mix_u64(NIL_SENTINEL) else mix_u64(v) end
end

local function mix_str(s)
	if s == nil then mix_u64(NIL_SENTINEL) return end
	mix_u64(#s)
	for i = 1, #s do mix_u64(string.byte(s, i)) end
end

-- Independently-seeded LCG (distinct seed from kernel_jit_diff.lua's and
-- kernel_bc_sweep.lua's, so the three files' streams never coincide). High bits
-- are used since power-of-two-modulus LCGs have weak low bits.
local lcg = 0x0F1E2D3C4B5A6978ULL
local function next_u64()
	lcg = lcg * 6364136223846793005ULL + 1442695040888963407ULL
	return lcg / 4ULL
end

-- Mechanically generated decimal corpus: digit counts sweep 1..25 (straddling
-- both the 2^53 double-precision ceiling and the 2^63 int64 ceiling), the
-- decimal point walks every position within each, and both signs appear. This
-- is a classifier over a swept SET, deliberately not a hand-picked list of
-- examples -- an 8-input hand-picked comparison in this project's history
-- reported "identical" for three libm functions a swept comparison proved
-- diverge.
local DIGITS = "0123456789"
local function decimal_string(n)
	local r = next_u64()
	local int_len = tonumber(r % 25ULL) + 1
	r = r / 25ULL
	local frac_len = tonumber(r % 20ULL)
	r = r / 20ULL
	local neg = (r % 2ULL) == 1ULL
	r = r / 2ULL

	local parts = {}
	if neg then parts[#parts + 1] = "-" end
	for _ = 1, int_len do
		local d = tonumber(r % 10ULL) + 1
		r = r / 10ULL
		if r == 0ULL then r = next_u64() end
		parts[#parts + 1] = DIGITS:sub(d, d)
	end
	if frac_len > 0 then
		parts[#parts + 1] = "."
		for _ = 1, frac_len do
			local d = tonumber(r % 10ULL) + 1
			r = r / 10ULL
			if r == 0ULL then r = next_u64() end
			parts[#parts + 1] = DIGITS:sub(d, d)
		end
	end
	return table.concat(parts)
end

local results = {}
local function record(name)
	results[#results + 1] = string.format("%-16s %s", name, tostring(digest))
	digest = DIGEST_SEED
end

-- parse: decimal string -> (m, e). The one place a platform strtod could hide.
local parsed_m, parsed_e = {}, {}
for i = 1, COUNT do
	local s = decimal_string(i)
	local m, e = fx.parse(s)
	mix_str(s)
	mix_maybe(m)
	mix_maybe(e)
	parsed_m[i], parsed_e[i] = m, e
end
record("parse")

-- tostring: (m, e) -> decimal string, swept across every `places` width the
-- CLI can ask for. The one place a platform printf could hide.
for i = 1, COUNT do
	local m, e = parsed_m[i], parsed_e[i]
	if m ~= nil then
		for places = 0, 12, 3 do
			mix_str(fx.tostring(m, e, places))
		end
	else
		mix_u64(NIL_SENTINEL)
	end
end
record("tostring")

-- parse_int / parse_int_safe: integer-only entry points, including the
-- magnitudes past 2^53 where parse_int_safe deliberately refuses.
for i = 1, COUNT do
	local s = decimal_string(i)
	mix_str(s)
	mix_maybe(fx.parse_int(s))
	mix_maybe(fx.parse_int_safe(s))
end
record("parse_int")

-- from_int / to_int_trunc: the round trip, plus the deliberate clamp past 2^53.
-- to_int_trunc truncates toward zero; @divFloor-vs-@divTrunc is called out in
-- the Zig port plan as the single most likely silent divergence, so the
-- negative operands here are load-bearing, not decoration.
for i = 1, COUNT do
	local r = next_u64()
	local v = tonumber(r % 0x20000000000000ULL)      -- 0 .. 2^53-1
	if (r % 2ULL) == 1ULL then v = -v end
	local m, e = fx.from_int(v)
	mix_maybe(m); mix_maybe(e)
	mix_maybe(fx.to_int_trunc(m, e))
	local fm, fe = fx.frac(m, e)
	mix_maybe(fm); mix_maybe(fe)
end
record("from_int")

-- frac / to_int_trunc on NON-integral values, where truncation direction is
-- actually observable. from_int alone always yields an exact integer, so the
-- loop above could not distinguish truncate from floor at all.
for i = 1, COUNT do
	local m, e = parsed_m[i], parsed_e[i]
	if m ~= nil then
		mix_maybe(fx.to_int_trunc(m, e))
		local fm, fe = fx.frac(m, e)
		mix_maybe(fm); mix_maybe(fe)
	else
		mix_u64(NIL_SENTINEL)
	end
end
record("frac")

-- cmp: ordering must be identical, including across sign and exponent classes.
for i = 2, COUNT do
	local m1, e1 = parsed_m[i - 1], parsed_e[i - 1]
	local m2, e2 = parsed_m[i], parsed_e[i]
	if m1 ~= nil and m2 ~= nil then
		mix_maybe(fx.cmp(m1, e1, m2, e2))
		mix_maybe(fx.cmp(m2, e2, m1, e1))
		mix_maybe(fx.cmp(m1, e1, m1, e1))
	else
		mix_u64(NIL_SENTINEL)
	end
end
record("cmp")

-- mul128: the 64x64->128 primitive every other operation is built on. Swept at
-- the extremes as well as randomly, since carry propagation between the four
-- 32-bit partials is where a wrong answer would come from.
for i = 1, COUNT do
	local a, b = next_u64(), next_u64()
	local hi, lo = fx.mul128(a, b)
	mix_u64(hi); mix_u64(lo)
	local hi2, lo2 = fx.mul128(0xFFFFFFFFFFFFFFFFULL, a)
	mix_u64(hi2); mix_u64(lo2)
	local hi3, lo3 = fx.mul128(b, 0x8000000000000000ULL)
	mix_u64(hi3); mix_u64(lo3)
end
record("mul128")

io.stderr:write(("cross_arch_decimal: %d iterations (FAST=%s)\n")
	:format(COUNT, tostring(fast ~= nil)))
io.write(table.concat(results, "\n"), "\n")
