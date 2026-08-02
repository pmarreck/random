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

-- LuaJIT/LuaJIT#1499 ("Don't fold -a / -b for unsigned operands", fixed
-- upstream in commit 5ed524c, first released as 2.1.1785577137)
-- miscompiles this kernel's unsigned negate-then-branch shape -- see
-- jit.off(div_signed) and jit.off(M.norm) below for the two confirmed
-- instances (the second found and verified during Task 12; see
-- task-12-report.md for both the original finding and the
-- coordinator-requested confirmation against the actual upstream fix).
-- We found and reported it; it is fixed upstream, but users will be on
-- pre-fix builds for a long time, so the mitigation is kept --
-- CONDITIONALLY, gated on the running LuaJIT's own version, rather than
-- paid unconditionally forever. Measured cost when active: ~5.7x on the
-- soft-float distributions (hyperfine, `--log-normal -c 20000`: 6.178s
-- vs 1.079s on a build where toggling the mitigation is safe to compare
-- either way) and nothing on the integer-only paths, which never enter
-- this file at all.
--
-- jit.version carries a rolling build timestamp as the third dotted
-- component (e.g. "LuaJIT 2.1.1774638290" on the toolchain this
-- project's flake.nix currently pins, "LuaJIT 2.1.1785606157" on a
-- build of the fix commit). Below LUAJIT_1499_FIXED_IN, #1499 is
-- present; at or above it, the running LuaJIT carries the fix and
-- jit.off is unnecessary overhead.
--
-- FAIL SAFE: if the version string cannot be parsed at all (a future
-- LuaJIT release changing its version format, or this code somehow
-- running under something whose jit.version doesn't match the expected
-- shape), ASSUME THE MITIGATION IS STILL NEEDED. A slow correct build
-- beats a fast wrong one. Do NOT invert this — see
-- tests/fixed_test.lua's dedicated fail-safe-inversion mutation check,
-- which exists specifically to catch that class of edit and runs
-- against synthetic version strings, not the live runtime (the real
-- jit.version is never actually unparseable in practice, so only a
-- synthetic-input test can exercise this branch at all).
--
-- Factored into a standalone function, not inlined at the two jit.off
-- call sites, for exactly that reason: tests/fixed_test.lua needs to
-- exercise the parsing/fail-safe logic directly against strings that
-- were never real jit.version output.
local LUAJIT_1499_FIXED_IN = 1785577137
local function needs_1499_mitigation(version_string)
	local roll = tonumber(tostring(version_string):match("2%.1%.(%d+)"))
	if roll == nil then return true end   -- FAIL SAFE: unparseable => needed
	return roll < LUAJIT_1499_FIXED_IN
end
-- TEST-ONLY, matching M._div_signed_for_tests' established pattern --
-- exposes the pure parsing function so fixed_test.lua can probe the
-- fail-safe branch with synthetic input, independent of whichever real
-- LuaJIT is running the suite.
M._needs_1499_mitigation_fn_for_tests = needs_1499_mitigation

local NEEDS_1499_MITIGATION = needs_1499_mitigation(jit.version)
-- TEST-ONLY. Lets fixed_test.lua branch its jit.attach checks on
-- whether THIS runtime actually needs the mitigation, rather than
-- asserting a fixed expectation that would fail the moment the suite
-- runs on a build that already carries the upstream fix -- see that
-- file's own comment on why "never traced" is only the right assertion
-- when the mitigation is active.
M._needs_1499_mitigation_for_tests = NEEDS_1499_MITIGATION

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
---
--- EXPONENT CONTRACT: docs/specs/2026-07-31-deterministic-fixed-point-rng-
--- design.md:121 fixes the representation as `{ m : u64, e : i32, sign }`.
--- Lua has no i32, so nothing enforced that bound here -- which let
--- exponents reach magnitudes where `e` (a Lua double) has an ULP that
--- exceeds 1, so a +/-1 renormalization step can silently no-op. Verified
--- directly: normalizing a mantissa needing exactly 7 doublings at
--- e = 2^53+10 (9007199254741002, itself exactly representable) needs
--- seven individual `e = e - 1` steps; the loop DOES run all seven
--- iterations (the mantissa shift itself, done in exact u64 arithmetic,
--- is never at risk) but the accumulated exponent lands on
--- 9007199254741000, not the -7 (9007199254740995) a correct per-step
--- decrement would give -- a discrepancy the coordinator's own
--- independent reproduction landed on this identical number for and
--- reasonably called "completely unchanged" (moved by 2 out of
--- 9+trillion, imperceptible at that scale, and nowhere near a real -7).
--- The identical shift at a normal-range e (e.g. 1000, decreasing to 993)
--- is exact every time -- the loop's own iteration count is always
--- right; only the per-step EXPONENT bookkeeping breaks down, and only
--- once e's own magnitude passes ~2^53. Asserting
--- the i32 bound here makes that unreachable rather than merely
--- undocumented, and makes the Lua reference and the eventual Zig port
--- (where `e` is a real `i32` and this range is unrepresentable by
--- construction) agree on exponent range BY CONSTRUCTION rather than by
--- Lua happening not to exercise the gap -- the actual reason this
--- matters: a reference implementation must never be MORE permissive
--- than the port it exists to validate.
---
--- 2147483647 (2^31-1) is comfortably above any legitimate exponent this
--- program produces -- the largest observed is exp(500)'s result
--- exponent, 721 -- six orders of magnitude of headroom, not a bound
--- picked to just barely fit current usage.
-- LuaJIT/LuaJIT#1499 MITIGATION -- CONFIRMED to be the SAME upstream bug
-- already documented for div_signed below, reaching M.norm through a
-- different code path, NOT a second distinct defect. Verified directly
-- against Mike Pall's actual #1499 fix (commit 5ed524c, built as
-- 2.1.1785606157), not just inferred from the shared "negate based on a
-- runtime-computed sign flag, then branch on it later" shape: with this
-- jit.off removed, `bin/random --exponential -d --seed 11111 -c 5`
-- crashes on the pinned build (2.1.1774638290, confirmed 3/3 runs) but
-- completes cleanly and correctly on 5ed524c (confirmed 5/5 runs,
-- identical output to `luajit -joff` on the pinned build). A broader
-- differential -- every bin/random distribution, 12 seeds, mitigation
-- removed, JIT-on vs -joff -- found zero divergence on 5ed524c (0/72
-- invocations, plus tests/kernel_jit_diff.lua's own 60000-iteration
-- digest). DISCOVERED DURING TASK 12 (bin/random integration): neither
-- fixed_test.lua nor kernel_bc_sweep.lua's own call patterns (built and
-- reviewed across Tasks 1-11, before bin/random had a real caller) ever
-- warmed up a trace through this exact shape -- a hand-extracted
-- standalone repro script (same PCG32 + exponential_random logic,
-- lifted verbatim) did NOT reproduce it either; only the real
-- bin/random call site, with its own bytecode/warm-up context, does.
-- That fragility is itself informative: it is consistent with a
-- warm-up-pattern-sensitive trace-compiler bug, not a deterministic
-- logic error, and is exactly why the deterministic jit.attach check
-- below (not a value-based probe) is the right regression control.
--
-- CONFIRMED BY DIRECT REPRODUCTION on the pinned build, not inferred
-- from the shape alone: the crash above happens on the 4th draw.
-- Instrumented pcg32_uniform to print M.from_int's return for raw PCG32
-- output 3830421010 (the exact draw that crashed): under the normal
-- JIT, M.from_int(3830421010) returned (-9223372034939565303LL, 63) --
-- a NEGATIVE mantissa for a POSITIVE input, i.e. M.norm itself corrupted
-- the sign. Re-running the identical invocation under `luajit -joff`
-- (JIT fully disabled) returned the correct (8225766483930644480LL, 31)
-- for that same input, and the whole run completed with no crash. JIT
-- on/off was the only variable that changed. See task-12-report.md for
-- the full instrumented transcript and the fixed-build verification.
--
-- This is the more dangerous half of the bug, worse than the crash that
-- exposed it: a caller whose corrupted value happens NOT to hit a
-- downstream assert (M.ln's m>0 check here was pure luck) would get a
-- silently wrong answer with no error at all, in a kernel whose entire
-- purpose is bit-exact reproducibility.
--
-- FIX: same mitigation as div_signed -- jit.off(M.norm) below keeps this
-- function permanently interpreted, never trace-compiled, so the
-- miscompilation can never fire on any pre-fix build. This is a KNOWN-
-- TEMPORARY tax, not a permanent one: it can be lifted once every build
-- this project ships against carries Mike Pall's #1499 fix, which as of
-- this writing is not yet in the pinned toolchain (2.1.1774638290) --
-- but users will be on pre-fix builds for a long time, so it stays.
-- Measured cost (hyperfine, 10 runs, `--log-normal -d --seed 1 -c 20000`,
-- same 5ed524c build with jit.off(M.norm) present vs removed -- an
-- apples-to-apples A/B on a build where it is safe to compare either
-- way): 6.178s +/- 0.131s WITH the mitigation vs 1.079s +/- 0.028s
-- WITHOUT it, roughly 5.7x. That cost is confined to the soft-float
-- distributions (--normalized/--exponential/--poisson/--log-normal/
-- --beta) that actually call into this kernel -- confirmed separately
-- (same A/B, plain uniform mode, `-c 20000`): 14.8ms +/- 1.1ms vs
-- 13.3ms +/- 1.0ms, no attributable difference, because pcg32_range (the
-- default uniform path) makes zero calls into lib/fixed.lua at all.
-- M.norm's own body (a couple of bounded shift loops) being interpreted
-- is not free on the paths that DO use it, but a wrong answer in this
-- kernel is strictly worse than a slower right one.
function M.norm(m, e)
	if m == 0 then return 0LL, 0 end
	local neg = m < 0
	local u = ffi.cast(u64, neg and -m or m)
	while u < TWO62 do u = u * 2ULL; e = e - 1 end
	while u >= 0x8000000000000000ULL do u = u / 2ULL; e = e + 1 end
	assert(e >= -2147483648 and e <= 2147483647, "fixed.norm: exponent outside i32")
	local r = ffi.cast(i64, u)
	if neg then r = -r end
	return r, e
end
-- Gated on NEEDS_1499_MITIGATION (defined near the top of this file,
-- computed once from jit.version) rather than applied unconditionally --
-- see that predicate's own doc comment for the version threshold, the
-- fail-safe direction, and the measured cost of paying this when it
-- isn't needed.
if NEEDS_1499_MITIGATION then jit.off(M.norm) end

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
---
--- EXPONENT CONTRACT (i32, see M.norm's own doc comment): this function
--- computes `e = e1 + e2 [+ 1]` directly rather than through M.norm --
--- the whole point of the "take hi and e1+e2(+1)" optimization above is
--- to avoid an unnecessary renormalization search, since the product's
--- magnitude bucket is already known from `hi` alone. That optimization
--- is exactly what let this bypass M.norm's i32 assert -- and the
--- coordinator found it is REACHABLE from entirely in-contract operands,
--- not just a theoretical gap: mul(e1=2000000000, e2=2000000000) ->
--- e=4000000000, both operands individually within i32 (norm accepts
--- each alone), the sum is not. Confirmed the Zig-port argument this
--- whole contract rests on applies identically here: `e1 + e2` on two
--- i32s this close to the max PANICS in Zig's Debug/ReleaseSafe modes --
--- silently producing 4e9 in Lua is the exact reference/port disagreement
--- on a reachable input this kernel exists to prevent, not a hypothetical.
--- Checked directly, not assumed a priori.
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
	assert(e >= -2147483648 and e <= 2147483647, "fixed.mul: exponent outside i32")
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

--- Fractional part, truncating toward zero (so frac(-1.25) == -0.25), matching
--- the file's global truncation-toward-zero rule. Domain-independent: any
--- (m, e) works, not just [0, 1) inputs -- M.cos_turns below relies on this
--- to reduce an arbitrary turns argument into [0, 1) (well, (-1, 1)) before
--- its own quadrant logic runs.
function M.frac(m, e)
	local ip = M.to_int_trunc(m, e)
	if ip == 0 then return m, e end
	return M.sub(m, e, M.from_int(ip))
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
--
-- Gated on NEEDS_1499_MITIGATION (defined near the top of this file,
-- computed once from jit.version) rather than applied unconditionally --
-- see that predicate's own doc comment for the version threshold, the
-- fail-safe direction, and the measured cost of paying this when it
-- isn't needed.
if NEEDS_1499_MITIGATION then jit.off(div_signed) end

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
-- M.exp has NO live callers in this program as of this writing --
-- bin/random still calls math.exp directly for --exponential/--poisson/
-- --log-normal, and is scheduled to switch to this kernel in Task 12, not
-- before. So there is no currently-enforced argument bound to cite here:
-- the design spec allows --mean "up to +/-1000 and beyond", and
-- bin/random performs NO numeric range validation on --mean at all. Do
-- not read anything below as a guarantee that large arguments won't
-- happen -- they might, once a caller exists. What IS true regardless of
-- what a future caller passes: raising loudly here is strictly safer than
-- either of the two failure modes this fix replaces (silently hanging
-- forever, or silently returning a JIT-artifact-dependent wrong answer).
--
-- FIX: bound the loop instead of trying to make it converge for arguments
-- this large. The IDEALIZED proof this file used to rely on ("at most 1
-- combined adjustment," assuming exact arithmetic throughout) is not the
-- proven maximum in REAL execution: M.div's own tiny (~2^-62 relative)
-- rounding error, though negligible almost everywhere, can very rarely
-- compound enough near this failure boundary to need a SECOND correction.
-- An exhaustive search (over 600,000 trials across e in [45, 58], plus
-- neighborhood probing around every case found) confirms 2 is the true
-- observed maximum -- it happens in roughly 1 in 1,600 to 1 in 4,700
-- otherwise-successful large-|x| calls near the boundary (rate varies by
-- exponent), never more, and
-- 3 never occurred naturally in that search (see task-7-report.md's
-- fix-up appendix for the full sweep and two concrete m,e examples that
-- reproducibly need exactly 2, confirmed against the real M.exp, not just
-- a standalone reproduction). EXP_MAX_CORRECTIONS = 3 is therefore
-- deliberately 1 unit of headroom ABOVE the empirically-confirmed
-- maximum, not a number that was picked because it happened to pass --
-- and correction_guard's own boundary (3 must succeed, 4 must fail) is
-- pinned directly in the test suite (see M._correction_guard_for_tests
-- below), independent of whether a natural exactly-3 input exists (none
-- was found; if one did, this bound would still need to reject it, since
-- letting the loop run indefinitely is exactly the bug being fixed). A
-- loud, immediate error is the right behavior once the bound is hit, the
-- same way M.ln refuses a non-positive argument outright rather than
-- trying to return something for it -- exp is not meant to be total
-- either.
local EXP_MAX_CORRECTIONS = 3
local function correction_guard(count, e)
	if count > EXP_MAX_CORRECTIONS then
		error(("fixed.exp: argument too large to range-reduce (e=%d): correction attempt " ..
			"#%d exceeded the bound of %d without converging -- k has grown too large for " ..
			"Lua's double-precision arithmetic to nudge by +/-1 (see the comment above " ..
			"this function), so this range reduction cannot correct for it. See M.exp's " ..
			"doc comment."):format(e, count, EXP_MAX_CORRECTIONS))
	end
end

-- TEST-ONLY. Not part of the public API -- matches M._div_signed_for_tests'
-- established pattern. Exposed so the test suite can pin
-- EXP_MAX_CORRECTIONS' EXACT boundary directly (correction_guard(3, _)
-- must not raise, correction_guard(4, _) must raise), rather than relying
-- on a naturally-occurring M.exp input to happen to need precisely
-- EXP_MAX_CORRECTIONS corrections. That reliance would not have worked:
-- an exhaustive search (600,000+ trials, see task-7-report.md) found the
-- natural maximum is 2 corrections, never 3 -- so no real M.exp call can
-- distinguish `count > 3` from a `count >= 3` off-by-one mutant; only a
-- direct test of the guard's own boundary can.
M._correction_guard_for_tests = correction_guard

--- Exponential. Range-reduce x = k*ln2 + r with |r| <= ln2/2, evaluate
--- exp(r) by Taylor series, and return (exp(r), k) directly -- adding k to
--- exp(r)'s own exponent IS multiplying by 2^k, so no renormalization is
--- needed and no fold-back into a fixed-width mantissa ever happens (that
--- fold is exactly what would overflow log-normal's exp() for a large mu,
--- the reason this soft-float representation exists at all -- see the
--- file's top-of-file REPRESENTATION note).
---
--- DOMAIN: NOT total. The limit is now the i32 EXPONENT CONTRACT (see
--- M.norm's own doc comment) -- docs/specs/2026-07-31-deterministic-
--- fixed-point-rng-design.md:121 fixes `e` as i32, and this function's
--- own return statement is routed through M.norm specifically so that
--- contract is enforced at its point of creation, not left to whatever
--- the caller happens to do with the result next. Since the returned
--- exponent is approximately k = x/ln2, this fires around |x| >~
--- 2^31 * ln2 ~= 1.5e9 (e ~= 31) -- an argument this function was NEVER
--- meant to accept in the first place, per the spec.
---
--- correction_guard (see above) still independently raises if range
--- reduction cannot converge within EXP_MAX_CORRECTIONS steps -- kept
--- as its own defense, not superseded, since it guards the LOOP itself
--- (which runs before the i32 check ever gets a chance to see a result),
--- and remains reachable in principle for any |x| the i32 check has not
--- yet rejected.
---
--- HISTORICAL CONTEXT for why correction_guard exists at all (no longer
--- this function's PRIMARY domain limit, since the i32 check above now
--- fires first for any |x| large enough to matter here): before the i32
--- contract was enforced, |x| beyond roughly 2^52 sat in a measured
--- GRADIENT, not a sharp cutoff (500-2000 trials per exponent, see
--- task-7-report.md): failure rate 0 for |x| < 2^52ish, rising roughly
--- monotonically (~8% at e=52, ~72% at e=55, still ~7.5% SUCCEEDING even
--- at e=57) before reaching certainty at |x/ln2| >= 2^62. The cause: `k`
--- is a plain Lua double, and once its magnitude crosses ~2^53 the
--- double's ULP exceeds 1, so `k +/- 1` can stop moving `k` at all (see
--- correction_guard's comment above for the full derivation). That
--- entire gradient region is now UNREACHABLE through this function's
--- public path -- the i32 check rejects everything from e ~= 31 onward,
--- a factor of ~2^21 (about six decimal orders of magnitude) below where
--- the gradient even begins -- but correction_guard is kept regardless,
--- both as defense in depth and because it protects the loop's OWN
--- termination independent of what the final exponent check does with
--- whatever the loop produces.
---
--- M.exp has no live callers in this program as of this writing (see
--- correction_guard's comment above) -- raising loudly rather than
--- hanging or returning a wrong answer is the safety property that
--- matters here, independent of what any future caller's argument range
--- turns out to be.
function M.exp(m, e)
	if m == 0 then return M.from_int(1) end
	-- k = round(x / ln2): truncate first, then nudge by a small number of
	-- steps (bounded below by correction_guard). IDEALIZED proof, assuming
	-- exact arithmetic throughout: at most ONE combined adjustment across
	-- both while loops, not "at most one each" -- to_int_trunc truncates
	-- TOWARD ZERO, so |x/ln2 - k| < 1 strictly right after the initial
	-- truncation, i.e. the untruncated r/ln2 always starts inside the OPEN
	-- interval (-1, 1), and firing one correction shifts r by exactly one
	-- ln2, landing it inside [-ln2/2, ln2/2].
	--
	-- REAL execution does not always match that idealized bound: M.div's
	-- own small (~2^-62 relative) rounding error can very rarely compound
	-- enough, near the failure boundary described above, to need a SECOND
	-- correction -- confirmed empirically (2 is the observed maximum
	-- across 600,000+ trials; see correction_guard's comment and
	-- task-7-report.md). This is exactly why the loops below are bounded
	-- by correction_guard rather than trusted to always terminate at 1 on
	-- their own -- the idealized proof is real and useful (it is why
	-- EXP_MAX_CORRECTIONS can be a SMALL constant instead of a large one),
	-- but it is not, by itself, a termination guarantee.
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
	--
	-- Routed through M.norm rather than returned directly (acc_m, acc_e+k):
	-- acc_m is already normalized here (every M.add call above renormalizes
	-- its own result), so this is a NO-OP for any in-contract result -- the
	-- while loops in M.norm see u already in range and never iterate -- but
	-- it is also this function's ONLY point of contact with M.norm's new
	-- i32-exponent assert (see that function's own doc comment). Without
	-- this, a huge |x| whose range reduction happens to CONVERGE (k itself
	-- can be astronomically large, e.g. ~5.2e16 for x=2^55, yet still
	-- satisfy the correction loop's own bound) would return a mantissa/
	-- exponent pair with no check ever applied to it -- M.exp's own return
	-- statement bypasses M.norm exactly like M.mul's does (both construct
	-- their exponent via direct arithmetic, e1+e2 there and acc_e+k here,
	-- as a deliberate optimization avoiding an unnecessary shift search),
	-- so "M.norm asserts the i32 bound" alone does not, by itself, reject
	-- this at its actual point of creation. This one-line change closes
	-- that gap for M.exp specifically, matching the exponent contract this
	-- was added to enforce (docs/specs/2026-07-31-deterministic-fixed-
	-- point-rng-design.md:121) rather than leaving it to whatever the
	-- caller happens to do with the result next.
	return M.norm(acc_m, acc_e + k)
end

-- pi/2, generated by:  echo 'scale=50; 4*a(1)/2' | bc -l  ->
--   1.57079632679489661923132169163975144209858469968754...
-- (matches the brief's cited 40-digit truncation exactly). pi/2 lies in
-- [1, 2), so its normalized soft-float form sits at exponent 0 (the
-- mantissa IS the value scaled by 2^62, no extra shift needed):
-- floor(pi/2 * 2^62), computed at scale=60 via
--   echo 'scale=60; (4*a(1)/2)*4611686018427387904' | bc -l
-- gives 7244019458077122842.3843..., truncating (this constant's own
-- fractional remainder is discarded once, same as every other precomputed
-- constant in this file) to 7244019458077122842 -- VERIFIED to match the
-- brief's committed value exactly; unlike LN2 in Task 6, this constant in
-- the brief was already correct. (The brief's own comment mislabeled the
-- derivation as "times 2^62 / 2" -- pi/2 was already computed via 4*a(1)/2
-- before scaling by 2^62 with no additional /2 -- but the COMMITTED
-- NUMBER matches the correct computation regardless of how the comment
-- explained it, confirmed independently above.)
M.PI_2_M, M.PI_2_E = 7244019458077122842LL, 0

-- Term count for the cos/sin Taylor series below. The brief specified 8
-- (loop n=1..8); measured directly against `bc -l` (scale=80) and found
-- insufficient, the same class of error as ln's brief-claimed 12 (Task 6,
-- wrong by ~46x) and exp's brief-claimed convergence assumption (Task 7).
--
-- IDEALIZED series error (bc's own arbitrary-precision arithmetic, no
-- simulated 62-bit truncation), at x = pi/2 -- the worst point in the
-- reduced domain [0, pi/2), since both series' truncation error grows
-- monotonically with |x| over this range:
--   terms= 8: cos abs err = 5.2602e-13   sin abs err = 4.3515e-14
--   terms=10: cos abs err = 1.8278e-17   sin abs err = 1.2488e-18
--   terms=11: cos abs err = 8.1757e-20   sin abs err = 5.1384e-21
--   terms=12: cos abs err = 3.1051e-22   sin abs err = 1.8069e-23
-- The kernel's own ULP floor is 2^-62 ~= 2.168e-19. At the brief's N=8,
-- cos's error (5.26e-13) is ~2.4 MILLION times that floor -- not a rounding
-- quirk, a mathematically unconverged series masquerading as a precise
-- result. (This also means the brief's own Section 5 test tolerances,
-- 1e-15/1e-16, would have been violated by several orders of magnitude on
-- the "cos(u) == cos(1-u)" symmetry check the moment it sampled a point
-- near a quadrant boundary -- confirmed by actually setting COS_TERMS = 8
-- and running this file's real fixed_test.lua Section 6 (task-8-report.md
-- has the full transcript): 3 of the section's checks FAIL, including the
-- symmetry check at worst=1.164e-11 vs its 1e-15 bound -- ~11,600x over.
-- Never assume from the boundary-value checks alone; they all land at
-- within-quadrant angle exactly 0, where BOTH an 8-term and a
-- correctly-sized series agree trivially and say nothing about N.
--
-- REAL kernel error (actual M.mul/M.add/M.div, 62-bit truncation and all),
-- measured the same way task-6/7 measured ln/exp's real-vs-idealized gap --
-- swept N from 1 to 20 at x = pi/2 through the genuine cos_rad/sin_rad
-- recurrence below, each N's output compared to bc's c()/s():
--   N=10: cos abs err = 1.838e-17     sin abs err = 1.735e-18
--   N=11: cos abs err = 1.634e-20     sin abs err = 6.505e-19
--   N=12: cos abs err = 9.840e-20     sin abs err = 6.505e-19  (plateau)
--   N=13..20: bit-identical to N=12 (cos ~9.81e-20, sin ~6.51e-19) --
--   the dominant error source has shifted entirely to this kernel's own
--   ~62-bit mul/add truncation compounding across the ~2*N operations per
--   series, exactly the N=17 ln plateau and N=16 exp plateau pattern.
-- COS_TERMS = 14 gives 2 terms of margin past the N=12 plateau (matching
-- ln's "3 terms past the N=17 plateau" convention; sin's own plateau
-- arrives even earlier, at N=11, so 14 covers it with room to spare).
-- Reproduce: see the scratch sweep referenced in task-8-report.md.
local COS_TERMS = 14

-- Reciprocals of the Taylor denominators for cos and sin, precomputed once
-- at module load (same ODD_RECIP/FACT_RECIP pattern as ln/exp above) --
-- keeps division out of the hot per-call loop.
local COS_RECIP, SIN_RECIP = {}, {}
do
	for n = 1, COS_TERMS do
		local om, oe = M.from_int(1)
		COS_RECIP[n] = { M.div(om, oe, M.from_int((2*n-1) * (2*n))) }
		SIN_RECIP[n] = { M.div(om, oe, M.from_int((2*n) * (2*n+1))) }
	end
end

--- cos(a) via Taylor series, a in [0, pi/2). Recurrence: term starts at 1
--- (the n=0 contribution), and each iteration multiplies by a^2 then by
--- 1/((2n-1)(2n)) -- i.e. term_n = term_{n-1} * a^2 / ((2n-1)*2n) -- then
--- negates. Reusing the ALREADY-NEGATED term_m as next iteration's base
--- (rather than tracking sign separately) is what makes the alternating
--- (-1)^n land correctly with no extra bookkeeping: term_n ends up equal
--- to (-1)^n * a^(2n) / (2n)!, matching the standard cos series exactly.
local function cos_rad(am, ae)
	local a2m, a2e = M.mul(am, ae, am, ae)
	local term_m, term_e = M.from_int(1)
	local acc_m, acc_e = M.from_int(1)
	for n = 1, COS_TERMS do
		term_m, term_e = M.mul(term_m, term_e, a2m, a2e)
		term_m, term_e = M.mul(term_m, term_e, COS_RECIP[n][1], COS_RECIP[n][2])
		term_m = -term_m
		acc_m, acc_e = M.add(acc_m, acc_e, term_m, term_e)
	end
	return acc_m, acc_e
end

--- sin(a) via Taylor series, a in [0, pi/2). Same recurrence shape as
--- cos_rad, seeded with term_0 = a (not 1) so term_n = (-1)^n * a^(2n+1) /
--- (2n+1)!, matching the standard sin series.
local function sin_rad(am, ae)
	local a2m, a2e = M.mul(am, ae, am, ae)
	local term_m, term_e = am, ae
	local acc_m, acc_e = am, ae
	for n = 1, COS_TERMS do
		term_m, term_e = M.mul(term_m, term_e, a2m, a2e)
		term_m, term_e = M.mul(term_m, term_e, SIN_RECIP[n][1], SIN_RECIP[n][2])
		term_m = -term_m
		acc_m, acc_e = M.add(acc_m, acc_e, term_m, term_e)
	end
	return acc_m, acc_e
end

--- cos(2*pi*u), with u given in TURNS rather than radians.
---
--- The caller always wants cos of 2*pi*something (Box-Muller's z = r *
--- cos(2*pi*u2), and every other transcendental caller in this file's
--- broader design), so quadrant reduction is done on u DIRECTLY and is
--- therefore EXACT -- no 2*pi multiply participates in the reduction at
--- all. That multiply was the single largest rounding source in the float
--- version this kernel replaces. Only the within-quadrant remainder (at
--- most 1/4 turn) is converted to radians, once, for the Taylor series.
---
--- quadrant = floor(4u); within = 4u - quadrant, so within in [0, 1) turns
--- maps to an angle in [0, pi/2) radians -- exactly the domain cos_rad and
--- sin_rad above are sized for. Mapping: 0 -> cos(a), 1 -> -sin(a),
--- 2 -> -cos(a), 3 -> sin(a) (standard quadrant identities for
--- cos(a + k*pi/2)).
function M.cos_turns(m, e)
	if m == 0 then return M.from_int(1) end
	-- fractional part of u, in (-1, 1); u is documented to arrive in
	-- [0, 1) (this program's RNG output domain), but frac's own truncating
	-- semantics can hand back a negative remainder for a negative input --
	-- normalize into [0, 1) the same way a real turns-based angle would
	-- wrap, rather than assuming every caller already range-checked u.
	local fm, fe = M.frac(m, e)
	if fm < 0 then fm, fe = M.add(fm, fe, M.from_int(1)) end
	-- quadrant = floor(4u); within = 4u - quadrant
	local q4m, q4e = M.mul(fm, fe, M.from_int(4))
	local q = M.to_int_trunc(q4m, q4e)
	local wm, we = M.sub(q4m, q4e, M.from_int(q))
	-- angle in [0, pi/2)
	local am, ae = M.mul(wm, we, M.PI_2_M, M.PI_2_E)
	if q == 0 then return cos_rad(am, ae) end
	if q == 1 then local sm, se = sin_rad(am, ae); return M.neg(sm, se) end
	if q == 2 then local cm, ce = cos_rad(am, ae); return M.neg(cm, ce) end
	return sin_rad(am, ae)
end

--- Refinement count for M.sqrt's soft-float Newton stage. See M.sqrt's doc
--- comment for the full derivation; summary: 1 iteration already reaches
--- this kernel's ~2^-62 precision floor (measured worst true fixed-point
--- relative error 6.3e-19 over a 20000-sample sweep of the FULL normalized
--- mantissa range at 1 iteration), and 2-4 iterations do not improve on
--- that -- the plateau every other iterative series/refinement in this
--- file hits once its own ~62-bit mul/add/div truncation dominates (same
--- shape as ATANH_TERMS/FACT_RECIP/COS_TERMS). 3 keeps 2 iterations of
--- margin past the measured plateau, matching this file's "N + margin"
--- convention (e.g. ln's 3 terms past its own N=17 plateau).
local SQRT_REFINE = 3

--- Square root. Two-stage: a fast ~31-bit-accurate integer-Newton starting
--- guess on the raw mantissa, then SQRT_REFINE soft-float Newton
--- iterations (y' = (y + v/y) / 2, via M.div/M.add) to reach this kernel's
--- full ~62-bit precision.
---
--- WHY TWO STAGES, NOT JUST THE BRIEF'S SINGLE INTEGER-NEWTON LOOP: pure
--- integer Newton directly on the 62-bit mantissa (mm cast to uint64,
--- iterating in raw u64 arithmetic with no soft-float division) can only
--- ever converge to floor(sqrt(mantissa)) -- an integer around 2^31, i.e.
--- roughly HALF the input's bits of precision, no matter how many
--- iterations run. That is an information-theoretic ceiling of the
--- method, not a tuning problem: a ~31-bit integer has ~31 bits to give.
--- Confirmed directly: the brief's literal algorithm (single integer-
--- Newton stage, no refinement) measured against a true fixed-point
--- oracle (sqrt(x)^2 compared to x via M.sub/M.div in 62-bit arithmetic,
--- NOT through a lossy double conversion -- see the comment below on why
--- that distinction matters) gives a worst relative error of 1.3e-09 over
--- the same 20000-sample sweep this file's SQRT_REFINE derivation uses --
--- about 9-10 orders of magnitude above this kernel's ~2.17e-19 floor and
--- the fixed_test.lua "sqrt(x)^2 == x" check's own 1e-15 bound (which the
--- single-stage version DOES still fail, since 1.3e-9 > 1e-15).
---
--- FIX: use the integer-Newton loop only to get a fast starting point (its
--- ~31 bits of accuracy make it an excellent seed -- Newton's method
--- converges quadratically, roughly doubling correct bits per iteration,
--- so a ~31-bit-accurate start needs only ONE more soft-float iteration to
--- clear 62 bits), then refine with SQRT_REFINE soft-float Newton steps
--- using M.div/M.add, both already ~62-bit precise. The "/2" each
--- iteration is done as an exact exponent decrement (v*2^(e-62) halved is
--- v*2^(e-1-62)), never a lossy divide -- the mantissa is untouched, so it
--- stays normalized with no renormalization call needed.
---
--- No sign handling anywhere in this function (m >= 0 is asserted below),
--- so it cannot exhibit the negation-then-loop pattern LuaJIT#1499
--- miscompiles (see M.div's comment) -- no jit.off dispatch is needed.
---
--- EXPONENT BOOKKEEPING (the second, independent defect in the brief):
--- value = m*2^(e-62) = f*2^e with f = m/2^62 in [1,2) always (m is
--- already normalized). If e is odd, rewrite as f' = f/2 (in [0.5,1)) at
--- exponent e+1, so the working exponent ee (= e, or e+1 if e was odd) is
--- always even and value = f_or_f'*2^ee. Let mm = m or m/2 (matching
--- which f the ee adjustment picked); mm/2^62 = f_or_f' by construction,
--- so u = mm represents f_or_f' scaled by 2^62, and integer-Newton's
--- result x approximates sqrt(u) = sqrt(f_or_f') * 2^31. Since
--- sqrt(value) = sqrt(f_or_f') * 2^(ee/2) (ee even, so this is exact),
--- dividing out the shared sqrt(f_or_f') factor gives
--- sqrt(value) = x * 2^(ee/2 - 31). M.norm's own e parameter means
--- "x * 2^(e-62)", so e - 62 = ee/2 - 31, i.e. e = ee/2 + 31 -- NOT the
--- brief's "(ee - 62) / 2 + 62 - 31", which algebraically reduces to
--- exactly ee/2, 31 short. Confirmed directly: the brief's formula run
--- verbatim on sqrt(4) returns 9.3132257461547852e-10 (== 2 * 2^-31), not
--- 2 -- a factor of 2^31 out, not the "sqrt(2) or 2" off-by-one the
--- brief's own Step 4 anticipated as the failure mode for a mistake here.
---
--- PRECISION MEASUREMENT CAVEAT: comparing two soft-floats by converting
--- each independently to a Lua double (as fixed_test.lua's math_abs_rel
--- helper and this comment's own worked numeric examples do) introduces
--- ~2^-53 relative rounding PER CONVERSION -- far coarser than this
--- kernel's ~2^-62 claim. That floor is too coarse to validate 62-bit
--- precision (it would not distinguish this fix's ~6e-19 true error from,
--- say, ~1e-16), but it IS fine for catching the two defects above: both
--- produce errors many orders of magnitude above that ~1e-16 double noise
--- floor (1.0 for the exponent bug, ~1e-9 for the missing refinement
--- stage). True 62-bit-level validation is done by comparing entirely in
--- fixed-point arithmetic (M.sub/M.div on the two soft-floats, converting
--- to double only the resulting ALREADY-TINY residual) and, independently,
--- by tests/kernel_bc_sweep.lua's sweep against `bc -l`'s arbitrary-
--- precision sqrt() -- see task-9-report.md for both measurements.
function M.sqrt(m, e)
	assert(m >= 0, "fixed.sqrt: argument must be non-negative")
	if m == 0 then return 0LL, 0 end
	local mm, ee = m, e
	if (ee % 2) ~= 0 then
		mm = mm / 2LL
		ee = ee + 1
	end
	-- mantissa is in [2^61, 2^63) (halved above if e was odd); its square
	-- root is in [2^30.5, 2^31.5) -- 2^32 is a safe, always-above starting
	-- point for the monotonically-decreasing branch of integer Newton.
	local u = ffi.cast(u64, mm)
	local x = ffi.cast(u64, 0x100000000ULL)   -- 2^32, a safe starting point
	for _ = 1, 40 do
		local nx = (x + u / x) / 2ULL
		if nx == x then break end
		x = nx
	end
	local rm = ffi.cast(i64, x)
	local ym, ye = M.norm(rm, ee / 2 + 31)
	for _ = 1, SQRT_REFINE do
		local qm, qe = M.div(m, e, ym, ye)
		local sm, se = M.add(ym, ye, qm, qe)
		ym, ye = sm, se - 1
	end
	return ym, ye
end

--- x^y via exp(y * ln x). Only defined for x > 0, which is all this
--- program needs (the gamma sampler's alpha<1 branch, applied to a
--- uniform-random base in (0,1)). y == 0 and y's sign both fall out of
--- the general M.mul/M.exp composition with no special-casing needed here:
--- y == 0 makes M.mul short-circuit to canonical zero, and M.exp(0,0)
--- returns 1 exactly, so x^0 == 1 for any valid x with no extra branch.
---
--- DOMAIN, inherited from M.exp: M.exp raises if range-reduction can't
--- converge within a bounded number of corrections -- see M.exp's own doc
--- comment for the exact mechanism (a Lua double's ULP exceeding 1 once
--- the range-reduced k grows past ~2^52-2^53). For this program's real use
--- (x a uniform (0,1) RNG draw, y = 1/alpha for the gamma sampler's
--- alpha<1 branch), ln x is bounded by the RNG's own smallest
--- representable nonzero draw (down to roughly -22, per this file's
--- top-of-file comment). MEASURED DIRECTLY (not derived from a naive
--- "y * 22 ~= 2^52" linear estimate, which undercounts by roughly 2^10 --
--- an earlier version of this comment claimed alpha < ~2^-47 on exactly
--- that flawed basis; what actually governs the boundary is the exponent
--- of the y*ln(x) PRODUCT after M.mul's own normalization, not a simple
--- decimal-magnitude comparison): with ln(x) at its documented floor
--- (x = 2^-32, ln(x) = -22.1807...), M.pow first raises at y = 2^57
--- (alpha = 2^-57), succeeding for every y = 2^40..2^56 tried below that.
--- alpha = 2^-57 is pathological, not a realistic sampler input (even
--- alpha = 1e-10 gives y ~ 2^33, twenty-four orders of magnitude below
--- this boundary), but M.pow does not clamp or special-case it: it raises
--- the same loud error M.exp would, rather than silently returning a
--- wrong answer. See task-9-report.md for the full sweep.
function M.pow(bm, be, ym, ye)
	assert(bm > 0, "fixed.pow: base must be positive")
	local lm, le = M.ln(bm, be)
	local pm, pe = M.mul(ym, ye, lm, le)
	return M.exp(pm, pe)
end

--- Maximum magnitude an int64-based decimal accumulator can hold. Symmetric
--- around zero (rejects the single asymmetric two's-complement edge value,
--- INT64_MIN, magnitude 2^63) rather than tracking sign during
--- accumulation -- simpler, and no realistic caller of M.parse/M.parse_int
--- (CLI counts, range bounds) needs that one extra representable value.
local INT64_MAX_MAG = 0x7FFFFFFFFFFFFFFFLL

--- Accumulate consecutive ASCII decimal digits from byte index i of s into
--- an unsigned magnitude held in an int64 (v is 0LL, count is 0 if none are
--- present), stopping at the first non-digit byte or end of string.
--- Returns (v, count, next_i) on success, or nil if the magnitude would
--- overflow int64 -- the brief this was built from had NO such check at
--- all in its M.parse_int (`v = v * 10LL + d`, wrapping silently on
--- overflow with no error). Confirmed directly: a 25-digit input under
--- that unchecked accumulation returns 3287003324691717120 -- a plausible-
--- looking but entirely wrong integer, no rejection. Shared by M.parse's
--- integer part and M.parse_int so both get the identical protection
--- rather than duplicating (and risking divergence in) the check.
local function accumulate_digits(s, i)
	local v, count = 0LL, 0
	while i <= #s do
		local ch = s:byte(i)
		if ch < 48 or ch > 57 then break end
		local d = ch - 48
		if v > (INT64_MAX_MAG - d) / 10LL then return nil end
		v = v * 10LL + d
		count = count + 1
		i = i + 1
	end
	return v, count, i
end

--- Parse a decimal string to soft-float by integer accumulation.
--- Deliberately NOT tonumber/strtod: those go through a hardware double,
--- which reintroduces exactly the platform dependence this file exists to
--- remove. Returns nil on malformed input rather than raising, so callers
--- can produce their own error message.
---
--- Two real defects in the brief this was built from, both confirmed by
--- direct probe before being fixed here, not assumed from reading the code:
---
--- 1. CRASH, not just imprecision: the brief's fractional-division line,
---    `M.div(M.from_int(tonumber(frac_part)), M.from_int(tonumber(den)))`,
---    chains a non-final multi-return call as an argument. Lua truncates a
---    non-final multi-return expression to exactly ONE value, so the FIRST
---    M.from_int(...) there hands M.div its mantissa only -- the exponent
---    is silently dropped, and M.div actually receives
---    (frac_mantissa, den_mantissa, den_exponent, nil), not
---    (frac_m, frac_e, den_m, den_e). Confirmed directly: running that
---    exact line with frac_part=5, den=10 -- i.e. M.parse("0.5"), the
---    FIRST case in the brief's own Step 1 test snippet -- raises
---    "fixed.div: operand 2 not normalized" every time. The brief's own
---    suggested implementation cannot parse "0.5" at all. Fixed below by
---    binding each M.from_int result to its own named (m, e) pair before
---    the M.div call, never chaining a non-final multi-return into another
---    call.
--- 2. `tonumber(int_part)` / `tonumber(frac_part)` / `tonumber(den)` route
---    an int64 through a Lua double on the way into M.from_int, silently
---    losing precision past 2^53 -- exactly the platform-dependent
---    boundary this whole task exists to close, reintroduced by parse
---    itself, and a direct violation of this file's "no tonumber on any
---    value that flows into the kernel" rule. Confirmed directly:
---    parse("123456789012345678") (18 digits) via tonumber() first lands
---    128 ULP away from the exact from_int(123456789012345678LL) result.
---    Fixed by never calling tonumber() on a value headed into the kernel:
---    M.from_int accepts an int64 cdata directly (ffi.cast(i64, v) is an
---    identity cast on cdata of the same width, unlike on a Lua number, so
---    there is no precision to lose), and the accumulated LL is passed
---    straight through.
function M.parse(s)
	if type(s) ~= "string" then return nil end
	s = s:gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then return nil end
	local sign, i = 1, 1
	local c = s:sub(1, 1)
	if c == "-" then sign = -1; i = 2 elseif c == "+" then i = 2 end
	local int_v, int_digits
	int_v, int_digits, i = accumulate_digits(s, i)
	if int_v == nil then return nil end   -- integer part overflows int64
	local frac_v, frac_digits = 0LL, 0
	if i <= #s and s:byte(i) == 46 then    -- '.'
		i = i + 1
		while i <= #s do
			local ch = s:byte(i)
			if ch < 48 or ch > 57 then break end
			if frac_digits < 18 then       -- 10^18 still fits int64 exactly
				-- as den below; digits past the 18th are DROPPED, not
				-- misparsed -- verified against an independent int64
				-- division at 18/19/30 digits in fixed_test.lua, and this
				-- kernel's own ~62-bit mantissa (~18-19 decimal digits of
				-- precision) cannot represent more than this anyway, so
				-- nothing representable is lost.
				frac_v = frac_v * 10LL + (ch - 48)
				frac_digits = frac_digits + 1
			end
			i = i + 1
		end
	end
	if i <= #s then return nil end          -- trailing garbage, e.g. a 2nd '.'
	if int_digits == 0 and frac_digits == 0 then return nil end
	local m, e = M.from_int(int_v)
	if frac_digits > 0 then
		local den = 1LL
		for _ = 1, frac_digits do den = den * 10LL end
		-- Each M.from_int result bound to its own (m, e) pair BEFORE the
		-- M.div call -- see this function's doc comment, defect 1, for why
		-- chaining two M.from_int calls straight into M.div's argument
		-- list (as the brief did) is a genuine crash, not a style nit.
		local fnm, fne = M.from_int(frac_v)
		local dm, de = M.from_int(den)
		local fm, fe = M.div(fnm, fne, dm, de)
		m, e = M.add(m, e, fm, fe)
	end
	if sign < 0 then m, e = M.neg(m, e) end
	return m, e
end

--- Parse a decimal string to a plain integer. Fractional input is rejected
--- rather than silently floored: a fractional range bound has no meaning.
--- Shares accumulate_digits' overflow check with M.parse -- the brief this
--- was built from had NO such check in M.parse_int at all (see
--- accumulate_digits' doc comment for the measured 25-digit failure).
---
--- The returned value is a Lua number (a double), per this function's own
--- documented interface -- so magnitudes between 2^53 and int64 max parse
--- EXACTLY internally (accumulate_digits never touches a double) but round
--- on the way out through the final tonumber(), the same documented
--- caveat M.from_int itself carries for a plain Lua-number input.
--- Realistic callers (CLI counts, range bounds) never approach that
--- boundary; nothing currently in this file needs the full int64 range
--- out of this function.
function M.parse_int(s)
	if type(s) ~= "string" then return nil end
	s = s:gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then return nil end
	local sign, i = 1, 1
	local c = s:sub(1, 1)
	if c == "-" then sign = -1; i = 2 elseif c == "+" then i = 2 end
	if i > #s then return nil end           -- bare sign, nothing after it
	local v, count, next_i = accumulate_digits(s, i)
	if v == nil then return nil end         -- int64 overflow
	if count == 0 then return nil end       -- no digits after the sign
	if next_i <= #s then return nil end     -- trailing garbage, e.g. "1.5"
	return sign * tonumber(v)
end

--- Render a soft-float as a fixed-point decimal string with `places`
--- digits. Integer-only: the fraction is advanced by repeated
--- multiply-by-ten, never by string.format("%f") -- see this file's
--- top-of-file comment for why that boundary matters as much as the one
--- M.parse closes on the way in.
---
--- A real defect found while verifying this function, independent of
--- anything the brief called out: the integer part was originally
--- rendered via plain Lua `tostring(ip)`. LuaJIT's default number
--- formatting (`%.14g`) switches to scientific notation once an
--- integer-valued double's magnitude reaches roughly 1e14 -- confirmed
--- directly, `tostring(1000000000000000)` prints "1e+15", not the 16-digit
--- literal -- which would have spliced something like "1e+15.001922"
--- into this function's output for any value with a 15+ digit integer
--- part, well inside this kernel's realistic range (this program's own
--- log-normal --mean/--stddev outputs are documented as "effectively
--- unbounded") and well below to_int_trunc's own unrelated 2^53 clamp.
--- Fixed by using string.format("%.0f", ip) instead, which always renders
--- a whole-number double in plain decimal regardless of magnitude.
function M.tostring(m, e, places)
	places = places or 6
	if m == 0 then
		if places == 0 then return "0" end
		return "0." .. string.rep("0", places)
	end
	local neg = m < 0
	local am, ae = m, e
	if neg then am, ae = M.neg(m, e) end
	local ip = M.to_int_trunc(am, ae)
	local fm, fe = M.sub(am, ae, M.from_int(ip))
	local out = {}
	for _ = 1, places do
		fm, fe = M.mul(fm, fe, M.from_int(10))
		local d = M.to_int_trunc(fm, fe)
		-- Defensive only, not live under the invariant: fm stays in [0, 1)
		-- after each subtraction below, so to_int_trunc(fm*10, fe) is
		-- always in [0, 9]. Kept in case an upstream bug ever hands this
		-- function an out-of-invariant intermediate, matching this file's
		-- established "keep the guard, document it as unreachable" style
		-- (see e.g. M.add's shifted == 0 comment).
		if d < 0 then d = 0 end
		if d > 9 then d = 9 end
		out[#out + 1] = tostring(d)
		fm, fe = M.sub(fm, fe, M.from_int(d))
	end
	local s = string.format("%.0f", ip)
	if places > 0 then s = s .. "." .. table.concat(out) end
	if neg then s = "-" .. s end
	return s
end

return M
