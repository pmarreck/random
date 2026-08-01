-- Minimal reproduction: LuaJIT trace-compiler miscompilation.
--
--
-- Filed upstream: https://github.com/LuaJIT/LuaJIT/issues/1499
-- LuaJIT 2.1.1774638290 (also the newest in nixpkgs-unstable as of 2026-08-01).
-- Run:  luajit docs/luajit-div-miscompilation.lua
--       luajit -joff docs/luajit-div-miscompilation.lua
--
-- `div` is a PURE function of (m1, m2). Called with identical arguments it
-- returns one value cold and a different, WRONG value once the JIT has warmed
-- up on mixed-sign operands. Under -joff it is correct in both cases.
--
-- Ground truth from bc (arbitrary precision):
--   floor(4735866454561506793 * 2^62 / 6988739120546013429) = 3125074314110934032
-- The cold / -joff answer matches. The JIT-warmed answer does not.
--
-- Narrowing notes:
--   * A positives-only warmup does NOT reproduce it. The trigger is a warmup
--     that MIXES signs, after which a negative/negative call takes a trace
--     specialized for a different sign pattern.
--   * Removing the result negation (`if neg then r = -r end`) does not help:
--     the wrong value is already present in the unsigned magnitude `q`.
--   * `ffi.cast(u64, 0) - a` and `m1 < 0 and -m1 or m1` both reproduce, so it
--     is not one particular negation idiom -- it is the sign branch itself.
--   * Splitting the division loop into its own function does NOT help, because
--     LuaJIT inlines it into the same trace. Only routing the negative case to
--     a separately jit.off'd function avoids it.

local ffi = require("ffi")
local u64, i64 = ffi.typeof("uint64_t"), ffi.typeof("int64_t")
local TWO62 = 0x4000000000000000ULL

-- floor(|m1| * 2^62 / |m2|), sign applied at the end.
-- Restoring bit-serial division; operands are always normalized to
-- 2^62 <= |m| < 2^63, so the quotient needs exactly 62 fractional bits.
local function div(m1, m2)
	local neg = (m1 < 0) ~= (m2 < 0)
	local a = ffi.cast(u64, m1); if m1 < 0 then a = ffi.cast(u64, 0) - a end
	local b = ffi.cast(u64, m2); if m2 < 0 then b = ffi.cast(u64, 0) - b end
	local q0, rem = a / b, a % b
	local frac = 0ULL
	for _ = 1, 62 do
		rem = rem * 2ULL
		frac = frac * 2ULL
		if rem >= b then
			rem = rem - b
			frac = frac + 1ULL
		end
	end
	local r = ffi.cast(i64, q0 * TWO62 + frac)
	if neg then r = -r end
	return r
end

local A, B = -4735866454561506793LL, -6988739120546013429LL
local EXPECT = 3125074314110934032LL

local cold = div(A, B)

-- Warm the trace with varied, MIXED-SIGN operands. 500 is comfortably above
-- the threshold; it begins failing at a few hundred on this build.
local lcg = 0x9E3779B97F4A7C15ULL
for i = 1, 500 do
	lcg = lcg * 6364136223846793005ULL + 1ULL
	local wa = ffi.cast(i64, TWO62 + ((lcg / 4ULL) % TWO62))
	lcg = lcg * 6364136223846793005ULL + 1ULL
	local wb = ffi.cast(i64, TWO62 + ((lcg / 4ULL) % TWO62))
	if i % 2 == 0 then wa = -wa end
	if i % 3 == 0 then wb = -wb end
	div(wa, wb)
end

local warm = div(A, B)

print(("cold     = %s"):format(tostring(cold)))
print(("warm     = %s"):format(tostring(warm)))
print(("expected = %s"):format(tostring(EXPECT)))
print(("MISCOMPILED = %s"):format(tostring(warm ~= EXPECT)))
os.exit(warm == EXPECT and 0 or 1)
