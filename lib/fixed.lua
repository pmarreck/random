--[[
Integer-only numeric kernel for `random`.

WHY THIS EXISTS
===============
Every function in here replaces a libm call that `bin/random` used to make
(math.log, math.cos, math.exp, math.pow). Those had to go, because THEY ARE
NOT PORTABLE. IEEE-754 pins down + - * / and sqrt, and says essentially
nothing about transcendental functions, so every libc is free to return a
different final ulp — and they do. Measured on one machine, glibc vs musl,
over the exact k/2^32 domain this program feeds them:

    sqrt   identical      (IEEE-754 mandates correct rounding)
    log    differs        0.006% of inputs
    cos    differs        3.06%  of inputs
    exp    differs        8.85%  of inputs

Box-Muller calls log AND cos per variate, so about 3% of seeded "normal"
values differed between a glibc build and a musl build OF THE SAME SOURCE AT
THE SAME SEED. For a tool whose entire purpose is reproducible streams — the
driving use case is deterministic fuzzing, where a corpus must replay a crash
on someone else's machine — that is not a rounding quirk, it is a broken
promise with no error message.

And it is worth saying plainly why this had to be written at all: the industry
tolerates this. The standard response to "your seeded RNG returns different
numbers on my machine" is a shrug and some line about how it's only the last
ulp and floating point is hard. That excuse is nonsense. It is only the last
ulp until it changes a comparison, and then it is a different branch, a
different variate, a different stream, and a bug report nobody can reproduce.
Reproducibility was the entire specification. Shipping math that quietly
depends on which libc got linked, and then calling the resulting
irreproducibility acceptable, is a choice — a lazy one — and everyone has
agreed to keep making it for decades rather than spend an afternoon on integer
arithmetic. This file is that afternoon.

DO NOT "SIMPLIFY" ANY OF THIS BACK INTO A math.* CALL. Doing so silently
destroys the cross-platform guarantee and no test that runs on a single
machine will notice.

REPRESENTATION
==============
Normalized binary soft-float, all integer ops:

    value = m * 2^(e - 62)      with  2^62 <= |m| < 2^63    (m is int64_t)
    zero  = (m = 0, e = 0)                                  (canonical)

Normalizing the mantissa gives ~62 bits of relative precision at EVERY
magnitude. A fixed-point format cannot: covering the range this program needs
(ln down to -22, variates to +/-6.6, user --mean into the thousands, and
log-normal exp() effectively unbounded) costs so many integer bits that the
fraction lands back at double precision having gained nothing.

Rounding is TRUNCATION TOWARD ZERO, everywhere, unconditionally. Not
round-to-nearest. Truncation is trivially reproducible and has no tie-break
rule to get subtly wrong in one of the two implementations.

Never use the `^` operator here: in LuaJIT `^` is floating-point
exponentiation even on integer cdata. Use the POW2 table.
]]

local ffi = require("ffi")

local M = {}

local i64 = ffi.typeof("int64_t")
local u64 = ffi.typeof("uint64_t")

local TWO62 = 0x4000000000000000ULL
local TWO61 = 0x2000000000000000ULL

-- POW2[n] = 2^n as int64, for n in [0, 62]. 2^63 overflows int64, so it stops
-- at 62 and every shift site must keep its shift count below 63.
local POW2 = {}
do
	local v = 1LL
	for n = 0, 62 do POW2[n] = v; v = v * 2LL end
end
M.POW2 = POW2

M.ZERO_M, M.ZERO_E = 0LL, 0

--- Full 64x64 -> 128 unsigned product, returned as (hi, lo).
--- Needed because LuaJIT cannot do __int128 arithmetic: ffi.cdef accepts the
--- typedef but construction fails ("cannot convert 'number' to 'int128_t'").
--- Mike Pall's "box it in the FFI" guidance covers storage; arithmetic tops
--- out at 64 bits. Zig's port of this uses native u128 and must agree exactly.
function M.mul128(a, b)
	local a0, a1 = a % 0x100000000ULL, a / 0x100000000ULL
	local b0, b1 = b % 0x100000000ULL, b / 0x100000000ULL
	local p00, p01, p10, p11 = a0 * b0, a0 * b1, a1 * b0, a1 * b1
	local mid = (p00 / 0x100000000ULL) + (p01 % 0x100000000ULL) + (p10 % 0x100000000ULL)
	local lo = (p00 % 0x100000000ULL) + (mid % 0x100000000ULL) * 0x100000000ULL
	local hi = p11 + (p01 / 0x100000000ULL) + (p10 / 0x100000000ULL) + (mid / 0x100000000ULL)
	return hi, lo
end

--- Renormalize an arbitrary (m, e) back to 2^62 <= |m| < 2^63.
--- Shifts are truncating, matching the global rounding rule.
function M.norm(m, e)
	if m == 0 then return 0LL, 0 end
	local neg = m < 0
	local u = ffi.cast(u64, neg and -m or m)
	while u < TWO62 do u = u * 2ULL; e = e - 1 end
	while u >= 0x8000000000000000ULL do u = u / 2ULL; e = e + 1 end
	local r = ffi.cast(i64, u)
	if neg then r = -r end
	return r, e
end

--- Soft-float multiply. Mantissa product lands in [2^124, 2^126); take 62 or
--- 63 bits off the top depending on which, so the result is normalized without
--- a renormalization loop.
---
--- PRECONDITION: both operands are already normalized (2^62 <= |m| < 2^63) or
--- canonical zero. The branch selection below is only valid under that premise
--- -- an unnormalized mantissa yields a silently wrong product rather than an
--- error -- so it is asserted rather than assumed. Tasks that build on this
--- must never hand `mul` an unrenormalized intermediate.
--- NOTE: the zero short-circuit below returns before either assert runs, so
--- mul(0, e, garbage, e) is accepted without validating the other operand.
--- That is intentional, not a gap: 0 * x = 0 exactly regardless of x, so the
--- check would cost hot-path work for no correctness gain.
function M.mul(m1, e1, m2, e2)
	if m1 == 0 or m2 == 0 then return 0LL, 0 end
	-- Magnitudes are taken by UNSIGNED negation, never `-a`. Negating INT64_MIN
	-- in signed arithmetic is a wraparound coincidence in LuaJIT and a panic in
	-- Zig's safe build modes; `0 - x` in u64 is well-defined in both, so the
	-- eventual port stays bit-identical instead of trapping. (The assert below
	-- rejects INT64_MIN anyway -- |INT64_MIN| is 2^63, outside the invariant --
	-- but the port must not depend on which check fires first.)
	local neg = (m1 < 0) ~= (m2 < 0)
	local a = ffi.cast(u64, m1); if m1 < 0 then a = ffi.cast(u64, 0) - a end
	local b = ffi.cast(u64, m2); if m2 < 0 then b = ffi.cast(u64, 0) - b end
	assert(a >= TWO62 and a < 0x8000000000000000ULL, "fixed.mul: operand 1 not normalized")
	assert(b >= TWO62 and b < 0x8000000000000000ULL, "fixed.mul: operand 2 not normalized")
	local hi, lo = M.mul128(a, b)
	local m, e
	if hi >= TWO61 then           -- product >= 2^125: shift down 63
		m = hi * 2ULL + lo / 0x8000000000000000ULL
		e = e1 + e2 + 1
	else                          -- product in [2^124, 2^125): shift down 62
		m = hi * 4ULL + lo / TWO62
		e = e1 + e2
	end
	local r = ffi.cast(i64, m)
	if neg then r = -r end
	return r, e
end

--- Soft-float addition.
--- Same-sign operands are combined by pre-halving each mantissa one bit
--- before summing: |m1| and |shifted| can each approach 2^63, so a same-sign
--- sum could reach 2^64 and overflow int64. That costs up to one bit of the
--- 62-bit mantissa; norm() reclaims the rest.
--- Opposite-sign operands -- the catastrophic-cancellation path every
--- alternating-sign Taylor series (cos!) depends on -- are combined EXACTLY,
--- with NO pre-halving. A same/opposite-sign combination of two values each
--- under 2^63 in magnitude can never overflow int64 (the result magnitude is
--- bounded by the larger operand's own magnitude), so there is nothing to
--- protect against here, and halving anyway is not merely imprecise, it is
--- wrong: independently truncating m1/2 and shifted/2 toward zero before
--- summing discards the low bit of EACH operand, and when both operands are
--- odd and adjacent (true difference == 1 ULP) the two truncations cancel
--- exactly, producing 0 for a genuinely nonzero difference. (Measured: the
--- brief's original "always pre-halve" version returned canonical zero for
--- fx.sub(X, e, X-1, e) -- see fixed_test.lua's "true 1-ULP difference must
--- not collapse to zero" check.) The exact integer-subtraction path below
--- fixes that and, as a bonus, makes same-exponent subtraction exact
--- whenever the true difference needs no alignment shift (d == 0) --
--- matching the Sterbenz-lemma exactness real floating-point subtraction
--- guarantees, which the original always-halve version violated even for
--- trivial exact-integer inputs.
function M.add(m1, e1, m2, e2)
	if m1 == 0 then return m2, e2 end
	if m2 == 0 then return m1, e1 end
	-- order so e1 is the larger exponent
	if e1 < e2 then m1, e1, m2, e2 = m2, e2, m1, e1 end
	local d = e1 - e2
	if d >= 63 then return m1, e1 end   -- second operand is below the ulp
	local shifted = m2 / POW2[d]
	if shifted == 0 then return m1, e1 end
	local sum, e
	if (m1 < 0) == (shifted < 0) then
		-- same sign: magnitudes add, could overflow int64, halve first
		sum = (m1 / 2LL) + (shifted / 2LL)
		e = e1 + 1
	else
		-- opposite signs: magnitudes only shrink, exact, cannot overflow
		sum = m1 + shifted
		e = e1
	end
	if sum == 0 then return 0LL, 0 end
	return M.norm(sum, e)
end

function M.sub(m1, e1, m2, e2)
	if m2 == 0 then return m1, e1 end
	return M.add(m1, e1, -m2, e2)
end

function M.neg(m, e)
	if m == 0 then return 0LL, 0 end
	return -m, e
end

--- Three-way comparison. Exponents only rank magnitudes once signs agree, so
--- sign is checked first.
function M.cmp(m1, e1, m2, e2)
	local s1 = (m1 > 0 and 1) or (m1 < 0 and -1) or 0
	local s2 = (m2 > 0 and 1) or (m2 < 0 and -1) or 0
	if s1 ~= s2 then return s1 < s2 and -1 or 1 end
	if s1 == 0 then return 0 end
	if e1 ~= e2 then
		local bigger = (e1 > e2) and 1 or -1
		return (s1 > 0) and bigger or -bigger
	end
	if m1 == m2 then return 0 end
	return (m1 < m2) and -1 or 1
end

--- Exact conversion from a Lua integer (|v| < 2^53 for safety) to soft-float.
function M.from_int(v)
	if v == 0 then return 0LL, 0 end
	return M.norm(ffi.cast(i64, v), 62)
end

return M
