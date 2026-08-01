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
--- sum could reach 2^64 and overflow int64. Both m1 and shifted are
--- truncated independently, each losing up to 1 unit at the halved scale, so
--- the worst-case error is up to 2 ULP of the 62-bit mantissa, not 1 --
--- measured exactly via fx.add(2^62+1, 100, 2^62, 38): the true sum is
--- 2^62+2 at exponent 100, the kernel returns 2^62, an error of exactly 2
--- ULP (see fixed_test.lua's "same-sign worst case" check). norm() still
--- reclaims everything above that.
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
	-- Unreachable under the normalization invariant: for any normalized m2
	-- (2^62 <= |m2| < 2^63) and any d in [0,62], |shifted| >= 1 always (the
	-- extreme case, d=62, gives exactly |m2|/2^62 = 1). Kept as defense
	-- against a caller that hands in an unnormalized m2 -- not live logic
	-- under the invariant this file otherwise guarantees.
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

--- Truncate a soft-float toward zero into a Lua integer. Values whose
--- magnitude exceeds 2^53 are clamped, since beyond that a Lua number
--- (a double) cannot represent consecutive integers exactly.
---
--- PRECONDITION-derived shortcut: e >= 62 (sh >= 0) means the shift is a
--- LEFT shift or none at all, and since |m| is already >= 2^62 by the
--- normalization invariant, the true magnitude is already >= 2^62 -- past
--- the 2^53 clamp threshold -- before any shift is even applied. So this
--- branch clamps immediately rather than computing `m * POW2[sh]`, which
--- the brief this was built from did NOT: for sh in [1, 62] that product
--- overflows int64 and silently wraps (m alone occupies bits 62-63,
--- leaving no headroom for a left shift of even 1 more bit), returning
--- garbage instead of the documented clamp. Confirmed directly: probing
--- the brief's version at m=2^62 (minimum normalized mantissa), e=70
--- (sh=8) returned -9223372036854775808 (INT64_MIN, a wrapped negative
--- garbage value) instead of the documented +2^53 clamp for a genuinely
--- huge POSITIVE value -- silently wrong sign included. Unreachable by
--- exp() for any argument in this program's real domain (would need
--- |x| ~ 2^62 * ln2 ~= 3.2e18), but a latent bug in a function this task
--- introduces is still a bug.
function M.to_int_trunc(m, e)
	if m == 0 then return 0 end
	local sh = e - 62
	if sh >= 0 then
		return (m < 0) and -9007199254740992 or 9007199254740992
	end
	local s = -sh
	if s > 62 then return 0 end
	return tonumber(m / POW2[s])
end

--- Magnitude-only division: q = floor(a * 2^62 / b), via restoring binary
--- long division, one bit at a time. q0 = floor(a/b) gives the integer
--- part (0 or 1, since normalized a,b are within a factor of 2 of each
--- other), then 62 more quotient bits come from repeatedly doubling the
--- remainder and subtracting b whenever it exceeds b.
---
--- The brief this was built from tried to extract those 62 bits in two
--- 31-bit jumps (t1 = (r0 * 2^31) / b, then t2 from the leftover remainder),
--- reasoning that this alone avoided the overflow of a naive
--- (m1 << 62) / m2. It does not: r0 = a mod b is bounded only by b, and
--- whenever a < b (q0 = 0) r0 = a itself, which can sit anywhere up to just
--- under 2^63 -- true for roughly HALF of all normalized operand pairs, not
--- a rare edge case. r0 * 2^31 then silently wraps mod 2^64. Measured:
--- dividing 2^62+1 by 2^63-1 (true ratio ~0.5) returned mantissa 0 -- a
--- nonzero division collapsing to a wrong zero, the exact bug class the
--- brief's own comment warns about, just relocated one level down. A jump
--- is only overflow-safe here if remainder * jump < 2^64 for a remainder up
--- to just under 2^63, which forces jump <= 2, i.e. one bit at a time --
--- there is no larger uniformly-safe chunk. See tests/kernel_bc_sweep for
--- the sweep against `bc -l` that caught this.
---
--- PRECONDITION: both a and b are already-extracted magnitudes of
--- normalized operands (2^62 <= a,b < 2^63) -- checked by every caller
--- below, not here (see M.div and div_signed). q0 = floor(a/b) is only
--- guaranteed to be 0 or 1 (so q0 * 2^62 cannot overflow) when a and b are
--- within a factor of 2 of each other, which normalization guarantees and
--- nothing else does.
---
--- DELIBERATELY has no sign handling at all -- not even a comment
--- mentioning it. This function must never gain a negation branch: see the
--- jit.off(div_signed) note below for why the JIT-safety of this whole
--- module now depends on that separation.
local function divmag(a, b)
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
	return q0 * TWO62 + frac
end

--- Cold path for M.div: any operand with a negative sign. Extracts
--- magnitudes and reapplies the sign around a call to divmag. This
--- function, not divmag or M.div, is the one disabled below --
--- see that comment for why.
local function div_signed(m1, e1, m2, e2)
	-- Magnitudes taken by UNSIGNED negation, matching M.mul's rationale:
	-- signed `-a` on INT64_MIN is a wraparound coincidence in LuaJIT and a
	-- panic in Zig's safe build modes.
	local neg = (m1 < 0) ~= (m2 < 0)
	local a = ffi.cast(u64, m1); if m1 < 0 then a = ffi.cast(u64, 0) - a end
	local b = ffi.cast(u64, m2); if m2 < 0 then b = ffi.cast(u64, 0) - b end
	assert(a >= TWO62 and a < 0x8000000000000000ULL, "fixed.div: operand 1 not normalized")
	assert(b >= TWO62 and b < 0x8000000000000000ULL, "fixed.div: operand 2 not normalized")
	local r = ffi.cast(i64, divmag(a, b))
	if neg then r = -r end
	return M.norm(r, e1 - e2)
end

-- LuaJIT/LuaJIT#1499 (https://github.com/LuaJIT/LuaJIT/issues/1499):
-- LuaJIT 2.1.1774638290's trace compiler JIT-COMPILES the combination of
-- a conditional unsigned-negation branch followed by a loop INCORRECTLY,
-- once warmed (~500+ prior calls, any operands). Reproduced with hard
-- evidence: dividing -4735866454561506793 by -6988739120546013429 once
-- returned the WRONG mantissa 7736760332538321936 (vs. the correct
-- 6250148628221868064, verified independently against bc's exact
-- floor((|m1|*2^62)/|m2|) big-integer division, and against `luajit
-- -joff`). Filed upstream and confirmed by the coordinator's own
-- reproduction on both upstream HEAD (4886b676a698acc4bbdf54adfabb3e33
-- a8c020e8) and the nixpkgs build; bisects to the `fwd` (store-forwarding)
-- optimization specifically -- `-O2 -O+fwd` reproduces, `-O3 -O-fwd`
-- does not. Positive-only operands never reproduce it.
--
-- MITIGATION: `divmag` (the loop) and `div_signed` (the negation
-- branches) were split into separate functions specifically so the
-- negation-then-loop pattern LuaJIT#1499 miscompiles never appears in one
-- prototype. Only `div_signed` is disabled below -- `divmag` and `M.norm`
-- are NOT covered by this call (an earlier version of this file
-- mistakenly believed `jit.off(f, true)`'s recursive flag reached
-- callees; it does not -- it only descends into LEXICALLY NESTED CHILD
-- PROTOTYPES, and neither div_signed nor M.div has any). `divmag` stays
-- fully JIT-eligible, including when called from this disabled function:
-- since it contains no sign branches of its own, it never exhibits the
-- pattern LuaJIT#1499 miscompiles regardless of who calls it. This was
-- verified directly (see tests/fixed_test.lua's "JIT miscompilation
-- regression, split dispatch" check and task-6-report.md), not assumed
-- from the theory above -- the instruction that produced this split was
-- explicit that if the separation didn't hold in this file, the correct
-- response was to revert to disabling M.div wholesale, not to trust the
-- reasoning.
--
-- M.norm's and M.mul's own apparent safety remains NOT a property of any
-- jit.off call -- it rests entirely on the same empirical check given to
-- M.mul elsewhere in this file: 200000 iterations of mul/add/sub/norm/ln
-- with mixed-sign operands, JIT-on output compared against `-joff` output
-- by digest, identical across the run. That is evidence the blast radius
-- observed so far is confined to this exact pattern, not proof any other
-- function using unsigned negation is immune.
--
-- DO NOT inline div_signed's body back into M.div, and do not inline
-- divmag's loop back into div_signed. Either merge puts the negation
-- branches and the loop back in the SAME prototype, which is precisely
-- the shape LuaJIT#1499 miscompiles -- collapsing this split back to one
-- function silently VOIDS the mitigation, and jit.off(div_signed) alone
-- would then no longer be covering the loop at all.
jit.off(div_signed)

-- TEST-ONLY. Not part of the public API -- nothing outside
-- tests/fixed_test.lua should read this field. Exposed so the test suite
-- can locate div_signed's `linedefined` via jit.util.funcinfo and assert,
-- via jit.attach, that it is NEVER trace-compiled -- the actual property
-- jit.off(div_signed) establishes, and a deterministic one. (Observing the
-- miscomputed VALUE instead, as an earlier version of that test did, is
-- NOT deterministic: trace formation is not monotonic in warmup call
-- count, and the value-based check was measured to detect the mitigation
-- being removed in only ~1 of 3 runs. See LuaJIT/LuaJIT#1499 and
-- tests/fixed_test.lua's own comment on the check that uses this field.)
M._div_signed_for_tests = div_signed

--- Soft-float divide. See divmag for the algorithm and div_signed for the
--- sign-handling cold path this dispatches negative operands to.
---
--- PRECONDITION: both operands normalized (2^62 <= |m| < 2^63) or
--- canonical zero, matching M.mul's precondition and asserted the same
--- way -- on BOTH the fast (positive) path below and inside div_signed,
--- deliberately duplicated rather than factored into one shared check, so
--- the fast path's own bytecode stays free of the sign-handling code that
--- div_signed exists to isolate (see the jit.off(div_signed) note above).
function M.div(m1, e1, m2, e2)
	-- Divisor-zero check MUST come before the m1==0 shortcut: 0/0 is
	-- undefined, not canonical zero, and M.ln takes exactly this stance on
	-- its own domain (asserts on m<=0 rather than returning -inf). An
	-- earlier ordering let `div(0, e, 0, e)` return (0LL, 0) silently,
	-- unreachable from any current call site but a live footgun for
	-- anything that isn't guaranteed to have already ruled out a zero
	-- divisor by construction.
	assert(m2 ~= 0, "fixed.div: division by zero")
	if m1 == 0 then return 0LL, 0 end
	if m1 > 0 and m2 > 0 then
		-- Fast path: both operands already known positive, so the
		-- magnitude is a direct cast -- no conditional negation, no
		-- branch LuaJIT#1499 can miscompile. Stays fully JIT-compiled.
		local a = ffi.cast(u64, m1)
		local b = ffi.cast(u64, m2)
		assert(a >= TWO62 and a < 0x8000000000000000ULL, "fixed.div: operand 1 not normalized")
		assert(b >= TWO62 and b < 0x8000000000000000ULL, "fixed.div: operand 2 not normalized")
		return M.norm(ffi.cast(i64, divmag(a, b)), e1 - e2)
	end
	return div_signed(m1, e1, m2, e2)
end

-- ln 2, generated by:  echo 'scale=60; l(2)' | bc -l  ->
--   .693147180559945309417232121458176568075500134360255254120680...
-- ln2 lies in [0.5, 1), so its normalized soft-float form sits at exponent
-- -1 (mantissa is ln2 scaled by 2^63, not 2^62): floor(l(2) * 2^63),
-- truncated ONCE from full bc precision, is 6393154322601327829.
--
-- An earlier version of this constant (3196577161300663808LL, e=0) was
-- wrong in two independent ways: (1) it truncated l(2) * 2^62 instead of
-- * 2^63, landing on 3196577161300663914 even before the exponent problem
-- -- 106 ULP off a correct bc computation, a ~2.3e-17 relative error against
-- a kernel meant to carry ~2.2e-19; and (2) more seriously,
-- 3196577161300663914 < 2^62, so paired with e=0 it was not a NORMALIZED
-- soft-float value at all -- it violated the same 2^62 <= |m| < 2^63
-- invariant M.mul asserts on its operands. Confirmed by running that
-- constant verbatim: M.ln(2) crashed immediately with "fixed.mul: operand 1
-- not normalized" the moment k ~= 0 pulled LN2 into a M.mul call -- the
-- brief's own worked example never actually ran. (Renormalizing the
-- truncated e=0 value by doubling it, rather than truncating directly at
-- e=-1, would ALSO be wrong, by exactly 1 ULP: 2 * floor(l(2)*2^62) ends in
-- ...828, but floor(l(2)*2^63) ends in ...829, because the fractional bit
-- the first truncation discarded was a 1.)
M.LN2_M, M.LN2_E = 6393154322601327829LL, -1

-- Reciprocals of the odd denominators 3, 5, 7, ... 41 used by the atanh
-- series, as soft-floats. Multiplying by a reciprocal keeps division out of
-- the loop. Must be built after M.div is defined above -- Lua executes top
-- to bottom, and this loop calls M.div at module-load time.
--
-- ATANH_TERMS = 20, not the brief's 12: the brief claimed "12 terms
-- converge well past the 62-bit precision this kernel carries," which is
-- false at the domain's own worst case. t = (f-1)/(f+1) approaches 1/3 as
-- f approaches 2 (e.g. any value just below a power of two, or -- as
-- ln(15) below demonstrates -- plenty of ordinary integers), and the atanh
-- series converges slowly there.
--
-- Measured TWO independent ways at the worst-case f = (2^63-1)/2^62 (the
-- largest representable mantissa, f closest to 2), both against `bc -l`'s
-- l() as the oracle:
--   (1) the real kernel, running M.ln's actual mul/add/div primitives at
--       N=12 -- relative error 1.5633e-14;
--   (2) an idealized atanh series computed entirely in bc at 80-digit
--       precision (no simulated 62-bit truncation anywhere) -- relative
--       error 1.5632e-14, matching (1) to 4 significant figures. This
--       confirms the error at N=12 is the mathematical series truncation
--       itself, not an artifact of the kernel's own arithmetic.
-- (An earlier version of this comment claimed ~3.4e-16 here, sourced from
-- measuring ln(15) -- t=(1.875-1)/(1.875+1)~=0.304 -- rather than the true
-- worst case t=(f-1)/(f+1) with f=(2^63-1)/2^62~=1.9999999999999998
-- (t~=0.33333333333333331). That was 46x too optimistic: 1.5633e-14 /
-- 3.4e-16 ~= 46.0. Caught by a coordinator review re-deriving the figure
-- independently, not by this file's own tests, which is itself a gap --
-- see tests/kernel_bc_sweep.lua's per-case comment for how the sweep's
-- own error reporting was strengthened as a result.)
--
-- At N=20, the picture flips: the idealized (arithmetic-noise-free) series
-- error drops to 2.287e-22 -- the mathematical truncation is now
-- negligible -- while the real kernel's error is 2.017e-18, roughly 4
-- orders of magnitude larger. Beyond N=20 the real-kernel error stops
-- improving at all (bit-identical mantissa from N=17 through at least
-- N=30 in testing): the dominant error source has shifted entirely to the
-- kernel's own ~62-bit mul/add truncation compounding across roughly 40
-- operations, which more atanh terms cannot fix. 20 gives 3 terms of
-- margin past that N=17 plateau. See tests/kernel_bc_sweep.
--
-- Reproduce: run M.ln's series loop standalone with N parameterized (or
-- see the scratch script referenced in task-6-report.md's correction
-- appendix) against `echo 'scale=80; val=(9223372036854775807/
-- 4611686018427387904); l(val)' | bc -l` as the oracle.
local ATANH_TERMS = 20
local ODD_RECIP = {}
do
	for k = 1, ATANH_TERMS do
		local dm, de = M.from_int(2 * k + 1)
		local om, oe = M.from_int(1)
		ODD_RECIP[k] = { M.div(om, oe, dm, de) }
	end
end

--- Natural log. The soft-float form IS the decomposition: x = m * 2^(e-62)
--- with m in [2^62, 2^63), i.e. x = f * 2^e where f = m/2^62 is already
--- exactly the mantissa reinterpreted as a value in [1, 2) (soft-float form
--- (m, 0)). So ln x = e*ln2 + ln(f), with no extra range reduction needed.
--- ln(f) uses 2*atanh((f-1)/(f+1)); f in [1,2) keeps t = (f-1)/(f+1) in
--- [0, 1/3). See ATANH_TERMS above for why this needs 20 terms, not 12, to
--- actually reach the kernel's own precision floor at every f, not just
--- typical ones.
function M.ln(m, e)
	assert(m > 0, "fixed.ln: argument must be positive")
	local k = e
	local fm, fe = m, 0
	local onem, onee = M.from_int(1)
	local num_m, num_e = M.sub(fm, fe, onem, onee)
	local den_m, den_e = M.add(fm, fe, onem, onee)
	local tm, te = M.div(num_m, num_e, den_m, den_e)
	local t2m, t2e = M.mul(tm, te, tm, te)
	local term_m, term_e = tm, te
	local acc_m, acc_e = tm, te
	for j = 1, ATANH_TERMS do
		term_m, term_e = M.mul(term_m, term_e, t2m, t2e)
		local rm, re = ODD_RECIP[j][1], ODD_RECIP[j][2]
		local cm, ce = M.mul(term_m, term_e, rm, re)
		acc_m, acc_e = M.add(acc_m, acc_e, cm, ce)
	end
	-- 2*acc + k*ln2
	local lm, le = M.add(acc_m, acc_e, acc_m, acc_e)
	if k ~= 0 then
		local km, ke = M.from_int(k)
		local sm, se = M.mul(M.LN2_M, M.LN2_E, km, ke)
		lm, le = M.add(lm, le, sm, se)
	end
	return lm, le
end

-- ln2 / 2, precomputed once: it never depends on exp's argument, so
-- computing it fresh via M.div on every M.exp call (as the brief's inline
-- version did) would be wasted work re-derived from a constant every time.
-- Same "precompute once at module load" pattern as ODD_RECIP/FACT_RECIP.
local HALF_LN2_M, HALF_LN2_E = M.div(M.LN2_M, M.LN2_E, M.from_int(2))
local NEG_HALF_LN2_M, NEG_HALF_LN2_E = M.neg(HALF_LN2_M, HALF_LN2_E)

--- r = x - k*ln2, recomputed from x and a candidate k (never from a running
--- r), so each candidate k in M.exp's correction loop is evaluated exactly,
--- not by accumulating a drifting adjustment. Factored out so the range
--- reduction's one arithmetic decision -- SUBTRACT k*ln2, not add it --
--- exists at a single call site instead of being copy-pasted at each of
--- the three places (initial estimate, +1 correction, -1 correction) that
--- need it, which would otherwise let a sign typo survive in one of three
--- near-identical blocks undetected.
local function reduce_r(m, e, k)
	local km, ke = M.from_int(k)
	local sm, se = M.mul(M.LN2_M, M.LN2_E, km, ke)
	return M.sub(m, e, sm, se)
end

-- Reciprocals of 1!..16! as soft-floats, for the exp Taylor series below.
-- Built at module load via M.mul/M.div, same pattern as ODD_RECIP above for
-- ln's atanh series -- keeps division out of exp's hot loop.
--
-- "16 terms" is measured, not assumed from the brief (see
-- task-7-report.md): at the worst case this series ever sees, |r| = ln2/2,
-- the bc-computed idealized n=16 term is ~2.07e-21 -- already ~100x below
-- this kernel's own ~62-bit ULP floor (2^-62 ~= 2.168e-19) -- and the tail
-- beyond n=16 is ~4.2e-23, negligible. Unlike ln's atanh series (which
-- needed 20 terms, not the brief's claimed 12, because convergence depends
-- on t up to 1/3 with no factorial in the denominator), exp's
-- factorial-weighted Taylor series converges far faster over the bounded
-- |r| <= ln2/2 range reduction guarantees -- 16 terms here is independently
-- the right number for THIS series, not a coincidence of matching the
-- brief. No overflow risk despite growing factorials: every intermediate
-- is a normalized soft-float (2^62 <= |mantissa| < 2^63), where magnitude
-- lives entirely in the exponent field -- unlike a fixed-point format,
-- 16! growing large costs nothing but a bigger exponent.
local FACT_RECIP = {}
do
	local fm, fe = M.from_int(1)
	for n = 1, 16 do
		local nm, ne = M.from_int(n)
		fm, fe = M.mul(fm, fe, nm, ne)          -- fm, fe = n!
		local om, oe = M.from_int(1)
		FACT_RECIP[n] = { M.div(om, oe, fm, fe) }
	end
end

-- Correction-loop bound for M.exp's range reduction. The termination proof
-- in M.exp's own doc comment ("at most one combined adjustment") holds ONLY
-- while `k` stays small enough for `k = k +/- 1` to actually change `k`.
-- `k` is a plain Lua NUMBER (a double), not an int64 -- and a double's ULP
-- (its smallest representable step) exceeds 1 once magnitude passes 2^53:
-- at k ~= 2^55, the ULP is 8, so `k + 1` rounds right back to `k` --
-- CONFIRMED DIRECTLY: `(51978566788454384 + 1) == 51978566788454384` is
-- `true` in this exact runtime. Two distinct things can then go wrong, and
-- EITHER one on its own is enough to break the termination proof:
--   (a) to_int_trunc's own sh>=0 branch (see its doc comment) explicitly
--       CLAMPS to +/-2^53 once |x/ln2| >= 2^62, rather than truncating;
--   (b) even OUTSIDE that clamp branch (sh<0, i.e. to_int_trunc still
--       truncates a real value), the truncated k can itself already
--       exceed 2^53 in magnitude -- to_int_trunc's `tonumber()` return
--       does not clamp there, it just silently hands back a k the
--       correction loop can no longer nudge.
-- Whichever mechanism applies, once a correction is actually needed and
-- `k +/- 1` is a no-op, `r` never changes, so the loop's own naive
-- termination condition never changes truth value either.
--
-- CONFIRMED BY EXECUTION, not just by this derivation, and the two ways of
-- confirming it disagree with each other in a way worth recording: under
-- normal JIT execution, exp(2^55) (mechanism (b) -- k ~= 5.2e16, not yet
-- past to_int_trunc's own 2^62 clamp threshold) "returns" after 17 loop
-- iterations with `r` jumping to a completely different value on that
-- 17th iteration despite `k` never having changed on ANY of the prior 16
-- -- not real convergence, an artifact. Under `luajit -joff` (no JIT at
-- all), the SAME code, SAME input, loops forever: `r` stays bit-identical
-- run after run, exactly as the frozen-`k` analysis above predicts.
-- exp(2^61)/exp(2^62)/exp(2^70) (mechanism (a), the explicit clamp) hang
-- under the JIT too -- there is no lucky JIT-artifact escape for those.
-- This program's real callers stay nowhere near either mechanism:
-- exponential/Poisson need |x| in the low tens (-ln(u)); log-normal's mu
-- is documented as reaching "into the thousands," not 2^52+.
--
-- FIX: bound the loop instead of trying to make it converge for arguments
-- this large. The proven invariant is "at most 1" in the regime where the
-- proof holds; EXP_MAX_CORRECTIONS = 3 gives a small margin above that
-- without ever letting the loop run away -- and empirically stops WAY
-- before iteration 17, so the JIT-artifact-vs-`-joff`-hang discrepancy
-- above is moot: the bound below never lets the loop run long enough to
-- reach it. A loud, immediate error is the right behavior here, the same
-- way M.ln refuses a non-positive argument outright rather than trying to
-- return something for it -- exp is not meant to be total either.
local EXP_MAX_CORRECTIONS = 3
local function correction_guard(count, e)
	if count > EXP_MAX_CORRECTIONS then
		error(("fixed.exp: argument too large to range-reduce (e=%d): correction loop " ..
			"exceeded %d iteration(s) without converging -- k has grown too large for " ..
			"Lua's double-precision arithmetic to nudge by +/-1 (see the comment above " ..
			"this function), so this range reduction cannot correct for it. See M.exp's " ..
			"doc comment."):format(e, EXP_MAX_CORRECTIONS))
	end
end

--- Exponential. Range-reduce x = k*ln2 + r with |r| <= ln2/2, evaluate
--- exp(r) by Taylor series, and return (exp(r), k) directly -- adding k to
--- exp(r)'s own exponent IS multiplying by 2^k, so no renormalization is
--- needed and no fold-back into a fixed-width mantissa ever happens (that
--- fold is exactly what would overflow log-normal's exp() for a large mu,
--- the reason this soft-float representation exists at all -- see the
--- file's top-of-file REPRESENTATION note).
---
--- DOMAIN: NOT total. Raises via correction_guard (see above) if range
--- reduction cannot converge within EXP_MAX_CORRECTIONS steps whenever a
--- correction is actually needed and k has grown too large for double
--- arithmetic to nudge by +/-1 -- in practice this can start as early as
--- |x| in the mid-2^10^15 range (empirically: e=54 still works, e=55
--- reliably raises) and is guaranteed once |x/ln2| >= 2^62 (~3.2e18,
--- to_int_trunc's own explicit clamp threshold). This program's real
--- callers stay far below either: exponential/Poisson need |x| in the low
--- tens (-ln(u)), and log-normal's mu is documented as reaching "into the
--- thousands," not 10^15+.
function M.exp(m, e)
	if m == 0 then return M.from_int(1) end
	-- k = round(x / ln2): truncate first, then nudge by at most one step.
	-- Provably at most ONE combined adjustment across both while loops, not
	-- "at most one each": to_int_trunc truncates TOWARD ZERO, so
	-- |x/ln2 - k| < 1 strictly right after the initial truncation --  i.e.
	-- the untruncated r/ln2 always starts inside the OPEN interval (-1, 1).
	-- At most one of the two loops below can therefore ever fire, and
	-- firing once shifts r by exactly one ln2, landing it inside
	-- [-ln2/2, ln2/2] immediately. See task-7-report.md for the empirical
	-- confirmation (large |x|, both signs, WITHIN the domain this proof
	-- actually covers) that neither loop ever iterates more than once.
	-- This proof holds ONLY while to_int_trunc truncates rather than
	-- clamps -- see correction_guard's comment above for the regime where
	-- it breaks down, and why the loops below are bounded rather than
	-- trusted to always terminate on their own.
	local qm, qe = M.div(m, e, M.LN2_M, M.LN2_E)
	local k = M.to_int_trunc(qm, qe)
	local rm, re = reduce_r(m, e, k)
	local corrections = 0
	while M.cmp(rm, re, HALF_LN2_M, HALF_LN2_E) > 0 do
		k = k + 1
		rm, re = reduce_r(m, e, k)
		corrections = corrections + 1
		correction_guard(corrections, e)
	end
	while M.cmp(rm, re, NEG_HALF_LN2_M, NEG_HALF_LN2_E) < 0 do
		k = k - 1
		rm, re = reduce_r(m, e, k)
		corrections = corrections + 1
		correction_guard(corrections, e)
	end
	-- exp(r) = sum_{n=0..16} r^n / n!, computed incrementally: pow_m/pow_e
	-- tracks r^n, updated by one multiply per term rather than recomputed
	-- from scratch each time.
	local acc_m, acc_e = M.from_int(1)
	local pow_m, pow_e = M.from_int(1)
	for n = 1, 16 do
		pow_m, pow_e = M.mul(pow_m, pow_e, rm, re)
		local cm, ce = M.mul(pow_m, pow_e, FACT_RECIP[n][1], FACT_RECIP[n][2])
		if cm == 0 then break end
		acc_m, acc_e = M.add(acc_m, acc_e, cm, ce)
	end
	-- multiply by 2^k purely in the exponent -- see the doc comment above.
	return acc_m, acc_e + k
end

return M
