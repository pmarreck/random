-- Sweeps M.div, M.ln, and M.exp against `bc -l` (arbitrary precision) as an
-- independent oracle. This exists because a Lua-double comparison CANNOT
-- validate this kernel's ~2^-62 (~2.2e-19) precision claim: tonumber() on a
-- 63-bit mantissa collapses it into an IEEE double's 53-bit mantissa,
-- which is itself only accurate to ~1.1e-16 -- discovered directly while
-- writing this task's unit tests, where two mathematically-identical ln
-- computations (ln(3)+ln(5) vs ln(15)) disagreed at the 1e-16 level purely
-- from that lossy conversion, before bc's exact rational arithmetic showed
-- the REAL error was three orders of magnitude smaller. Only bc's
-- arbitrary-precision decimal arithmetic can actually measure error down
-- at the scale this kernel claims to carry. (Task 7 hit the identical trap
-- again independently, in fixed_test.lua's own exp(ln(x))==x round-trip
-- check: it reports a flat 0.000e+00 worst-case error because
-- math_abs_rel's double-precision scoring cannot resolve the ~1e-18-scale
-- error that is actually there -- see this file's exp sweep below for the
-- real number, and task-7-report.md for the mantissa-level proof it is
-- not bit-exact.)
--
-- No `math.*`, no float literals, never `^` -- except here, deliberately:
-- this file is test-only infrastructure that talks to bc, not kernel code.
package.path = (arg[0] or ""):match("^(.*)/[^/]+$") .. "/../lib/?.lua;" .. package.path
local ffi = require("ffi")
local fx = require("fixed")

local i64 = ffi.typeof("int64_t")
local u64 = ffi.typeof("uint64_t")
local TWO62 = 0x4000000000000000ULL

-- `FAST=` (set but empty) is how ./test requests the deep sweep -- its own
-- wrapper unconditionally does `export FAST="${FAST-1}"`, which can never
-- leave FAST literally unset for a child process, only empty or "1". Lua's
-- os.getenv returns "" (not nil) for a set-but-empty var, and "" is
-- TRUTHY in Lua (only nil/false are falsy) -- so a bare `fast and X or Y`
-- truthiness test silently stayed in fast mode for BOTH `FAST=1` and
-- `FAST=`, and there was no way to reach deep mode through ./test at all.
-- Confirmed directly before this fix: `FAST=1` and `FAST=` both measured
-- exactly 1783 cases (identical -- deep mode never engaged). Normalize the
-- empty-string case to nil before testing it.
local fast = os.getenv("FAST")
if fast == "" then fast = nil end
-- FAST (./test's default) still comfortably clears "a few hundred operand
-- pairs" per the task brief; unsetting FAST runs a deeper statistical sweep.
local MANTISSA_COUNT = fast and 20 or 60
local EXP_MANTISSA_COUNT = fast and 5 or 10
local EXP_DIFFS = {-5000, -500, -50, -7, -1, 0, 1, 7, 50, 500, 5000}
local LN_MANTISSA_COUNT = fast and 12 or 40
local LN_EXPS = {-50, -5, -1, 0, 1, 5, 50}
-- "EXPFN" (never "EXP", already taken above by div's EXPONENT sweep) is
-- the exp() FUNCTION sweep count, split into two domains that stress
-- different things: RDOMAIN samples |r| <= ln2/2 directly (k forced to 0
-- by construction), isolating the Taylor series' own convergence from any
-- range-reduction arithmetic -- this is the domain task-7-report.md's
-- "worst-case series error" figure is measured over. XDOMAIN instead
-- samples whole integers x, exercising the FULL pipeline (div-based k
-- estimate, the +/-1 correction loop, and the series) exactly as a real
-- caller would.
local EXPFN_RDOMAIN_COUNT = fast and 40 or 150
-- x = -700 and x = -5000 are EXPECTED to print "SKIP" (ref == 0), same as
-- any ln case near ref == 0: e(-700) ~= 1e-304 and e(-5000) ~= 1e-2172,
-- both far below what `scale=90` can represent (bc rounds anything under
-- ~1e-90 to exactly 0 at this scale) -- not a bug in add_exp_case or in
-- M.exp, just bc's own fixed decimal precision running out at extreme
-- magnitudes. Their positive counterparts (700, 5000) are NOT skipped:
-- e(x) for large positive x is merely a huge integer, and scale (which
-- only bounds FRACTIONAL digits) does not limit integer-part magnitude at
-- all. Confirmed by direct A/B measurement at FAST=1: 21 skips for
-- div+ln alone (this file's state before this task) vs. 23 after adding
-- the exp sweep -- exactly the +2 these two labels predict, not more.
local EXPFN_XDOMAIN_VALUES = {1, -1, 2, -2, 7, -7, 22, -22, 50, -50, 100, -100,
                               700, -700, 5000, -5000}

-- Deterministic LCG (Knuth/PCG multiplier), fixed seed: reproducible across
-- machines and runs, no dependency on wall-clock time. High bits are used
-- (shift right before masking) since power-of-two-modulus LCGs have weak
-- low bits -- irrelevant for cryptography here, just for decent spread
-- across the mantissa range without a short visible cycle in the bits we
-- actually keep.
local lcg_state = 0x9E3779B97F4A7C15ULL
local function next_mantissa()
	lcg_state = lcg_state * 6364136223846793005ULL + 1ULL
	local high = lcg_state / 4ULL
	return TWO62 + (high % TWO62)
end

-- A SECOND, independently-seeded LCG for cos's k-domain sampling (u = k/2^32,
-- k in [0, 2^32)) -- deliberately not sharing lcg_state above, so adding or
-- resizing the cos sweep can never shift how many next_mantissa() calls the
-- div/ln/exp sections above have already consumed (and vice versa).
local cos_lcg_state = 0xC2B2AE3D27D4EB4FULL
local function next_k32()
	cos_lcg_state = cos_lcg_state * 6364136223846793005ULL + 1442695040888963407ULL
	local high = cos_lcg_state / 4ULL
	return tonumber(high % 4294967296ULL)
end

local function mantissa_set(n)
	local set = { 0x4000000000000000ULL, 0x4000000000000001ULL,
	              0x7FFFFFFFFFFFFFFFULL, 0x7FFFFFFFFFFFFFFEULL,
	              0x6000000000000000ULL }
	for _ = 1, n do set[#set + 1] = next_mantissa() end
	return set
end

-- bc program accumulation: one `print` statement per case, each producing
-- exactly one line "<label> <relerr>\n". scale=90 gives ~90 decimal digits
-- of precision, comfortably covering both very large and very small
-- 2^exponent scale factors for the modest exponent ranges tested here
-- (|e| <= 5000) while resolving relative error far below the 2^-62 floor
-- we're trying to measure.
-- GNU bc has no ternary operator; define abs() once instead of inlining
-- `x < 0 ? -x : x` per case (which is not valid bc syntax at all).
local bc_lines = { "scale=90", "define abs(x) { if (x < 0) return -x; return x; }" }
local labels = {}

local function i64dec(v)
	-- MUST go through tostring(), never tonumber(): tonumber() on a 63-bit
	-- mantissa converts through an IEEE double (53-bit mantissa), silently
	-- rounding it -- exactly the double-precision-floor trap this whole
	-- sweep exists to route around (see the top-of-file comment). Confirmed
	-- by direct probe: tonumber(0x7FFFFFFFFFFFFFFEULL) formatted as "%.0f"
	-- prints 9223372036854775808, two off from the true
	-- 9223372036854775806 that tostring() gives exactly. This was caught
	-- by the sweep itself (a spuriously large "kernel" error that traced
	-- back to a wrong reference operand, not a wrong kernel result).
	--
	-- Takes a SIGNED int64_t cdata directly (never ffi.cast(u64, ...) it
	-- first): div's operands can be negative, and bc's decimal literals
	-- handle a leading "-" natively, so there is no reason to detour
	-- through an unsigned bit-pattern reinterpretation -- doing that on a
	-- negative m1/m2 would silently hand bc the WRONG (huge positive)
	-- reference operand. This was the shape of the negative-operand
	-- coverage gap: the sweep only ever generated positive mantissas, so
	-- this latent bug in the conversion itself was never exercised either.
	return (tostring(v):gsub("LL$", ""))
end

-- Each case prints "<label> <relerr> <absdiff>". Both are needed: relative
-- error is the right signal in general, but it is an ILL-CONDITIONED metric
-- whenever the true reference value is itself close to zero -- discovered
-- directly here, not theoretically: ln(v) for v just below 1.0 decomposes
-- as k*ln2 + ln(f) with k=-1 and f close to 2, so ln(f) and -ln2 (each
-- ~0.693, each individually accurate to a few ULP) nearly CANCEL, leaving a
-- true result near 1e-19 whose relative error balloons to >10x even though
-- the absolute error stays at the same few-ULP level the rest of the sweep
-- sees. That is real, unavoidable catastrophic cancellation inherent to
-- computing ln via k*ln2 + ln(mantissa) with no dedicated log1p-style path
-- for arguments near 1 -- not a coding bug, and not something more series
-- terms can fix (see task-6-report.md). Tracking absdiff lets the pass/fail
-- check use whichever bound is actually meaningful per case, the same way
-- e.g. numpy's isclose combines atol and rtol instead of relying on either
-- alone.
local function add_div_case(m1, e1, m2, e2, label)
	local rm, re = fx.div(m1, e1, m2, e2)
	assert(not (rm == 0LL and m1 ~= 0), "div collapsed a nonzero division to zero: " .. label)
	-- reference = (m1/m2) * 2^(e1-e2) computed directly in bc; our =
	-- rm * 2^(re-62). All exponent scaling is expressed via bc's own
	-- (negative-exponent-capable) ^, so nothing is pre-scaled in Lua.
	local m1s, m2s = i64dec(m1), i64dec(m2)
	local rms = tostring(rm):gsub("LL$", "")
	local expr = ("ref = (%s/%s) * 2^(%d); our = %s * 2^(%d); " ..
		"if (ref == 0) print \"%s SKIP\\n\"; " ..
		"if (ref != 0) print \"%s \", (our - ref) / abs(ref), \" \", abs(our - ref), \"\\n\""):format(
		m1s, m2s, e1 - e2, rms, re - 62, label, label)
	bc_lines[#bc_lines + 1] = expr
	labels[#labels + 1] = label
end

local function add_ln_case(m, e, label)
	local rm, re = fx.ln(m, e)
	local ms = tostring(m):gsub("LL$", "")
	local rms = tostring(rm):gsub("LL$", "")
	-- value = m * 2^(e-62); bc's l() is natural log, the same oracle
	-- function this file's whole existence is about not diverging from
	-- (this is the one place we WANT to lean on libm bc links against --
	-- as ground truth for a test, never inside the shipped kernel).
	local expr = ("val = %s * 2^(%d); ref = l(val); our = %s * 2^(%d); " ..
		"if (ref == 0) print \"%s SKIP\\n\"; " ..
		"if (ref != 0) print \"%s \", (our - ref) / abs(ref), \" \", abs(our - ref), \"\\n\""):format(
		ms, e - 62, rms, re - 62, label, label)
	bc_lines[#bc_lines + 1] = expr
	labels[#labels + 1] = label
end

local function add_exp_case(m, e, label)
	local rm, re = fx.exp(m, e)
	local ms = tostring(m):gsub("LL$", "")
	local rms = tostring(rm):gsub("LL$", "")
	-- bc -l's e() is its built-in exponential -- the natural oracle
	-- counterpart to l() above, same rationale: lean on bc's arbitrary-
	-- precision e() as ground truth for THIS TEST, never inside the
	-- shipped kernel (see the file's top-of-file comment).
	local expr = ("val = %s * 2^(%d); ref = e(val); our = %s * 2^(%d); " ..
		"if (ref == 0) print \"%s SKIP\\n\"; " ..
		"if (ref != 0) print \"%s \", (our - ref) / abs(ref), \" \", abs(our - ref), \"\\n\""):format(
		ms, e - 62, rms, re - 62, label, label)
	bc_lines[#bc_lines + 1] = expr
	labels[#labels + 1] = label
end

-- Sweeps M.cos_turns over the REAL domain it is actually fed: u = k/2^32
-- for integer k in [0, 2^32) -- exactly one uint32 RNG draw, the same
-- domain the top-of-file comment's "cos differs 3.06% of inputs" figure
-- was measured over. k/4294967296 is always exact in this binary
-- representation (division by a power of two is a pure exponent shift,
-- no truncation, regardless of k), so `bc`'s reference angle
-- twopi*k/4294967296 is computed from k directly -- never from our own
-- (um, ue) -- keeping the oracle fully independent of the code under test.
-- `twopi` is computed once (bc_lines[3] below, via 8*a(1) = 2*(4*a(1)) =
-- 2*pi) and reused across every case rather than recomputed per print.
local function add_cos_case(k, label)
	local km, ke = fx.from_int(k)
	local dm, de = fx.from_int(4294967296)
	local um, ue = fx.div(km, ke, dm, de)
	local rm, re = fx.cos_turns(um, ue)
	local rms = tostring(rm):gsub("LL$", "")
	local expr = ("ref = c(twopi*%d/4294967296); our = %s * 2^(%d); " ..
		"if (ref == 0) print \"%s SKIP\\n\"; " ..
		"if (ref != 0) print \"%s \", (our - ref) / abs(ref), \" \", abs(our - ref), \"\\n\""):format(
		k, rms, re - 62, label, label)
	bc_lines[#bc_lines + 1] = expr
	labels[#labels + 1] = label
end

-- Sign quadrants cycle deterministically across the sweep so it exercises
-- the negative/inexact truncation path (M.div computes a magnitude via
-- floor, then reapplies the sign) exactly as often as the positive path.
-- This is the coverage gap that let a truncate-vs-floor rounding-mode
-- mutant (add 1 to the magnitude when negative-and-inexact, silently
-- switching from truncate-toward-zero to floor-toward-negative-infinity)
-- pass every suite undetected: mantissa_set/next_mantissa previously
-- produced only positive u64 magnitudes cast straight to i64, so ALL
-- generated div cases were non-negative on both sides. Index-based, not
-- randomized -- every case still cross-checks against bc regardless of
-- which quadrant it lands in, so there's no need for extra randomness on
-- top of the mantissa LCG already in play.
local SIGN_QUADRANTS = { { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }
local function signed_i64(v, sign)
	local r = ffi.cast(i64, v)
	if sign < 0 then r = -r end
	return r
end

-- === div: mantissa sweep (e1 = e2 = 0), the part directly at risk from ===
-- === the overflow bug this file exists to catch.                      ===
local mset = mantissa_set(MANTISSA_COUNT)
local div_pair_count = 0
for i = 1, #mset do
	for j = 1, #mset do
		local q = SIGN_QUADRANTS[((i + j) % 4) + 1]
		add_div_case(signed_i64(mset[i], q[1]), 0, signed_i64(mset[j], q[2]), 0,
			("div_mant_%d_%d_%d_%d"):format(i, j, q[1], q[2]))
		div_pair_count = div_pair_count + 1
	end
end

-- === div: exponent sweep, confirming e1-e2 bookkeeping over a spread ===
-- === of magnitudes without depending on the mantissa sweep above.    ===
local eset = mantissa_set(EXP_MANTISSA_COUNT)
for i = 1, #eset do
	for di, d in ipairs(EXP_DIFFS) do
		local q = SIGN_QUADRANTS[((i + di) % 4) + 1]
		add_div_case(signed_i64(eset[i], q[1]), d, signed_i64(eset[(i % #eset) + 1], q[2]), 0,
			("div_exp_%d_%d_%d_%d"):format(i, d, q[1], q[2]))
		div_pair_count = div_pair_count + 1
	end
end

-- === ln: mantissa sweep at a spread of exponents, including the ===
-- === near-worst-case t (mantissa close to 2^63-1).               ===
local lnset = mantissa_set(LN_MANTISSA_COUNT)
local ln_case_count = 0
for i = 1, #lnset do
	for _, e in ipairs(LN_EXPS) do
		add_ln_case(ffi.cast(i64, lnset[i]), e, ("ln_%d_%d"):format(i, e))
		ln_case_count = ln_case_count + 1
	end
end

-- === exp: r-domain sweep, |r| <= ln2/2 (k forced to 0), isolating the ===
-- === Taylor series' own convergence -- see task-7-report.md's         ===
-- === "worst-case series error" figure, measured exactly over this     ===
-- === same domain.                                                     ===
local HALF_LN2_M, HALF_LN2_E = fx.div(fx.LN2_M, fx.LN2_E, fx.from_int(2))
local NEG_HALF_LN2_M, NEG_HALF_LN2_E = fx.neg(HALF_LN2_M, HALF_LN2_E)
local expfn_r_count = 0
for _, e in ipairs({ -1, -2, -3 }) do
	local rset = mantissa_set(EXPFN_RDOMAIN_COUNT)
	for i = 1, #rset do
		local mm = ffi.cast(i64, rset[i])
		local rm, re = fx.norm(mm, e)
		if (i % 2) == 0 then rm, re = fx.neg(rm, re) end
		-- Only keep cases actually inside the series' documented domain --
		-- a case outside |r| <= ln2/2 here would still get exp()'d
		-- correctly (range reduction handles any x), but would no longer
		-- isolate series-only error, which is the point of this sweep.
		if fx.cmp(rm, re, HALF_LN2_M, HALF_LN2_E) <= 0 and
		   fx.cmp(rm, re, NEG_HALF_LN2_M, NEG_HALF_LN2_E) >= 0 then
			add_exp_case(rm, re, ("expfn_r_%d_%d"):format(e, i))
			expfn_r_count = expfn_r_count + 1
		end
	end
end
-- Exact boundary: r = +ln2/2 and r = -ln2/2, the edges the series has to
-- cover per M.exp's own documented range-reduction guarantee.
add_exp_case(HALF_LN2_M, HALF_LN2_E, "expfn_r_boundary_pos")
add_exp_case(NEG_HALF_LN2_M, NEG_HALF_LN2_E, "expfn_r_boundary_neg")
expfn_r_count = expfn_r_count + 2

-- === exp: x-domain sweep, whole integers through the FULL pipeline ===
-- === (div-based k estimate, +/-1 correction loop, series) -- both   ===
-- === signs, small and large |x|, matching real callers             ===
-- === (exponential/Poisson: -ln(u); log-normal: mu + sigma*z).       ===
local expfn_x_count = 0
for _, v in ipairs(EXPFN_XDOMAIN_VALUES) do
	local m, e = fx.from_int(v)
	add_exp_case(m, e, ("expfn_x_%d"):format(v))
	expfn_x_count = expfn_x_count + 1
end

-- === cos: sweep over the REAL u = k/2^32 domain (task-8 verification    ===
-- === items 2-4: quadrant reduction exactness at boundaries, series      ===
-- === term-count adequacy across the full domain, and cancellation near  ===
-- === cos's zeros). `twopi` (bc's own 2*pi, via 8*a(1)) is computed once ===
-- === and reused by every add_cos_case call below.                      ===
bc_lines[#bc_lines + 1] = "twopi = 8*a(1)"
local COS_UNIFORM_COUNT = fast and 60 or 200
local cos_case_count = 0

-- Uniform coverage: k drawn from the dedicated LCG above, spread across the
-- entire [0, 2^32) domain -- this is the check that actually validates
-- COS_TERMS is sufficient EVERYWHERE in [0, pi/2), not just at the single
-- worst-case point x = pi/2 the term-count derivation above was measured
-- at.
for i = 1, COS_UNIFORM_COUNT do
	local k = next_k32()
	add_cos_case(k, ("cos_uniform_%d"):format(i))
	cos_case_count = cos_case_count + 1
end

-- Exact quadrant boundaries: division by 2^32 (a power of two) is exact
-- regardless of numerator, so these k values put u at EXACTLY 0, 1/4, 1/2,
-- and 3/4 turn -- not approximations of the boundary, the boundary itself,
-- bit-for-bit. Verification item 2 from the task brief, cross-checked here
-- against an independent oracle (bc) rather than only fixed_test.lua's own
-- self-consistency checks.
local COS_BOUNDARY_KS = {0, 1073741824, 2147483648, 3221225472}
for _, k in ipairs(COS_BOUNDARY_KS) do
	add_cos_case(k, ("cos_boundary_%d"):format(k))
	cos_case_count = cos_case_count + 1
end

-- Near-zero cancellation probe (verification item 4): cos's only ZEROS in
-- [0, 1) turns are at 1/4 and 3/4 (0 and 1/2 turn are extrema, +-1, not
-- zeros -- cancellation there is not a concern the same way). Offsets are
-- in units of k, the finest step this k/2^32 domain can express, so k = zk
-- +/- 1 is literally the closest this program's real RNG-fed input can
-- ever land next to the boundary without landing ON it. As true |cos|
-- shrinks toward 0, the SAME small absolute error that is invisible
-- everywhere else becomes a large RELATIVE error -- exactly the dynamic
-- LN_RTOL/LN_ATOL above exists to separate for ln's own near-1
-- cancellation case.
local COS_ZERO_KS = {1073741824, 3221225472}   -- 1/4 turn, 3/4 turn
local COS_OFFSETS = {1, 2, 3, 5, 10, 100, 1000, 1000000}
for _, zk in ipairs(COS_ZERO_KS) do
	for _, off in ipairs(COS_OFFSETS) do
		add_cos_case(zk - off, ("cos_nearzero_%d_m%d"):format(zk, off))
		add_cos_case(zk + off, ("cos_nearzero_%d_p%d"):format(zk, off))
		cos_case_count = cos_case_count + 2
	end
end

-- === sqrt: mantissa x exponent sweep against bc's own arbitrary-        ===
-- === precision sqrt() builtin (task-9 verification items 1 and 3: the   ===
-- === exponent bookkeeping and the true round-trip precision, here       ===
-- === cross-checked against an INDEPENDENT oracle rather than only this  ===
-- === kernel's own M.sub/M.div-based self-check in fixed_test.lua).      ===
--
-- A dedicated LCG (own seed), same rationale as cos's cos_lcg_state
-- above: adding or resizing this sweep must never shift how many
-- next_mantissa() calls the div/ln/exp sections above have already
-- consumed.
local sqrt_lcg_state = 0x9E6B4A7F1C2D3E5FULL
local function next_sqrt_mantissa()
	sqrt_lcg_state = sqrt_lcg_state * 6364136223846793005ULL + 1442695040888963407ULL
	local high = sqrt_lcg_state / 4ULL
	return TWO62 + (high % TWO62)
end

local function add_sqrt_case(m, e, label)
	local rm, re = fx.sqrt(m, e)
	local ms = i64dec(m)
	local rms = tostring(rm):gsub("LL$", "")
	-- bc's sqrt() is a builtin (available with or without -l), the natural
	-- independent oracle for this section -- same rationale as l()/e()/c()
	-- above: ground truth for THIS TEST, never inside the shipped kernel.
	local expr = ("val = %s * 2^(%d); ref = sqrt(val); our = %s * 2^(%d); " ..
		"if (ref == 0) print \"%s SKIP\\n\"; " ..
		"if (ref != 0) print \"%s \", (our - ref) / abs(ref), \" \", abs(our - ref), \"\\n\""):format(
		ms, e - 62, rms, re - 62, label, label)
	bc_lines[#bc_lines + 1] = expr
	labels[#labels + 1] = label
end

-- Mantissa set: same edge-value baseline mantissa_set() uses (min/max/
-- min+1/max-1/midpoint), all non-negative since M.sqrt's domain is m >= 0
-- (mantissa_set's own defaults are already all non-negative u64 literals
-- cast straight to i64, so no sign filtering is needed here), plus
-- SQRT_MANTISSA_COUNT more from the dedicated LCG above.
local SQRT_MANTISSA_COUNT = fast and 30 or 100
local sqrtset = { 0x4000000000000000LL, 0x4000000000000001LL,
                  0x7FFFFFFFFFFFFFFELL, 0x7FFFFFFFFFFFFFFFLL,
                  0x6000000000000000LL }
for _ = 1, SQRT_MANTISSA_COUNT do
	sqrtset[#sqrtset + 1] = ffi.cast(i64, next_sqrt_mantissa())
end
-- Exponents spanning a wide magnitude range with BOTH parities explicitly
-- represented at each scale (verification item 1: "test on both odd and
-- even exponents") -- e.g. -1000/-999 sit right next to each other so a
-- parity-dependent bug at large |e| can't hide behind only testing one
-- parity per magnitude.
local SQRT_EXPS = {-1000, -999, -501, -500, -50, -49, -5, -4, -1, 0, 1, 4, 5,
                    49, 50, 500, 501, 999, 1000}
local sqrt_case_count = 0
for i = 1, #sqrtset do
	for _, e in ipairs(SQRT_EXPS) do
		add_sqrt_case(sqrtset[i], e, ("sqrt_%d_%d"):format(i, e))
		sqrt_case_count = sqrt_case_count + 1
	end
end

-- === pow: x^y via bc's own e(y*l(x)) as an INDEPENDENT reference -- same ===
-- === arbitrary-precision l()/e() this file already trusts as the ln/exp ===
-- === oracle, composed the same way M.pow itself is, but with bc's OWN   ===
-- === big-decimal l()/e() rather than this kernel's ~62-bit versions, so ===
-- === it is not simply re-checking M.pow against its own arithmetic.     ===
-- Domain deliberately kept well inside M.exp's convergence bound (see
-- M.pow's doc comment for the measured boundary, ~2^57 for this program's
-- worst-case ln(x)) -- this sweep validates ORDINARY pow correctness, not
-- the boundary, which fixed_test.lua's pcall-based check already covers.
local pow_lcg_state = 0xB5297A4D3C9E7F21ULL
local function next_pow_mantissa()
	pow_lcg_state = pow_lcg_state * 6364136223846793005ULL + 1ULL
	local high = pow_lcg_state / 4ULL
	return TWO62 + (high % TWO62)
end
local function add_pow_case(bm, be, ym, ye, label)
	local rm, re = fx.pow(bm, be, ym, ye)
	local bms, yms = i64dec(bm), i64dec(ym)
	local rms = tostring(rm):gsub("LL$", "")
	local expr = ("base = %s * 2^(%d); ypow = %s * 2^(%d); ref = e(ypow*l(base)); our = %s * 2^(%d); " ..
		"if (ref == 0) print \"%s SKIP\\n\"; " ..
		"if (ref != 0) print \"%s \", (our - ref) / abs(ref), \" \", abs(our - ref), \"\\n\""):format(
		bms, be - 62, yms, ye - 62, rms, re - 62, label, label)
	bc_lines[#bc_lines + 1] = expr
	labels[#labels + 1] = label
end
local POW_MANTISSA_COUNT = fast and 15 or 40
local powset = {}
for _ = 1, POW_MANTISSA_COUNT do
	powset[#powset + 1] = ffi.cast(i64, next_pow_mantissa())
end
-- base exponents kept small (x roughly in [2^-5, 2^5]) and y drawn from
-- small integers of both signs, so |y * ln x| stays comfortably under
-- ~200 -- nowhere near the ~2^57 boundary M.pow inherits from M.exp.
-- CORRECTION: an earlier version of this comment claimed y was "drawn
-- from both small integers and fractional (negative-exponent) soft-
-- floats" -- false; POW_Y_VALUES below are all plain integers via
-- fx.from_int, so this sweep exercised INTEGER y exclusively. That is a
-- real gap: the motivating use (gamma's alpha<1 branch, x^(1/alpha)) gives
-- FRACTIONAL y almost always for a real alpha -- POW_Y_VALUES = {-20,-3,
-- -1,1,3,20} are all integers or powers of two, and even the differential
-- pow test in fixed_test.lua only ever used integer n before this fix.
-- See the pow_frac_y case immediately below, which closes that gap with a
-- genuinely fractional, non-power-of-two y.
local POW_BASE_EXPS = {-5, -1, 0, 1, 5}
local POW_Y_VALUES = {-20, -3, -1, 1, 3, 20}
local pow_case_count = 0
for i = 1, #powset do
	local bexp = POW_BASE_EXPS[((i - 1) % #POW_BASE_EXPS) + 1]
	for _, yv in ipairs(POW_Y_VALUES) do
		local ym, ye = fx.from_int(yv)
		add_pow_case(powset[i], bexp, ym, ye, ("pow_%d_%d_%d"):format(i, bexp, yv))
		pow_case_count = pow_case_count + 1
	end
end

-- Explicit fractional, non-power-of-two y = 10/3 (== 1/0.3 -- the
-- motivating case: gamma's alpha<1 branch computes x^(1/alpha), and a
-- real alpha gives a fractional y almost always; alpha = 0.3 here). Every
-- y elsewhere in this sweep, and in fixed_test.lua's differential check
-- before this fix, was an integer or a power of two -- this is the first
-- case anywhere in the suite that actually exercises M.pow's ln/mul/exp
-- pipeline at a fractional exponent. x is the first sampled base mantissa
-- (bexp = -1, x roughly in [0.5, 1)) so this sits squarely in the gamma
-- sampler's real domain (a uniform (0,1) draw raised to a fractional
-- power).
local frac_y_num, frac_y_den = 10, 3
local frac_y_num_m, frac_y_num_e = fx.from_int(frac_y_num)
local frac_ym, frac_ye = fx.div(frac_y_num_m, frac_y_num_e, fx.from_int(frac_y_den))
add_pow_case(powset[1], -1, frac_ym, frac_ye, "pow_frac_y_10_3")
pow_case_count = pow_case_count + 1

-- === tostring: exact truncated-decimal-string sweep against bc's own    ===
-- === arbitrary-precision division-at-scale=0 truncation -- confirmed    ===
-- === DIRECTLY, via a standalone probe before relying on it here, to     ===
-- === truncate TOWARD ZERO for negative operands exactly like this       ===
-- === kernel's global rounding rule (`scale=20; a=-3.7; scale=0; b=a/1`  ===
-- === gives b=-3, not -4, matching C's truncating integer division, not  ===
-- === floor). This is a genuinely INDEPENDENT oracle: bc never sees      ===
-- === fx.tostring's own multiply-by-ten digit-extraction loop, only the  ===
-- === raw (m, e) value and the target `places` -- and the expected       ===
-- === STRING is reconstructed here by plain zero-pad/split/prefix on     ===
-- === bc's own truncated big-integer digit string, not by re-running any ===
-- === version of fx.tostring's own algorithm, so a bug shared between    ===
-- === test and code cannot hide from this sweep the way it could from a  ===
-- === self-referential check.                                            ===
local TOSTRING_PLACES = 15
-- NOT named `tostring`: that would shadow the Lua builtin this entire
-- file (like every case-adding function above) calls on every m/rm to
-- avoid the exact tonumber() precision trap i64dec's own doc comment
-- warns about.
local tostr_cases = {}
local function add_tostring_case(m, e, label)
	local got = fx.tostring(m, e, TOSTRING_PLACES)
	local ms = i64dec(m)
	-- tv = |value| * 10^places, computed at the script's ambient scale=90;
	-- tt = floor(tv), forced by a LOCAL scale=0 division-by-1. bc has no
	-- block-scoped `scale` -- `sv = scale` / `scale = sv` save and restore
	-- the ONE global scale around just this truncation, so this case
	-- cannot perturb the precision any LATER case in this same shared
	-- script depends on (every add_*_case function above shares one scale).
	local expr = ("sv = scale; tv = abs(%s * 2^(%d)) * 10^%d; scale = 0; tt = tv / 1; scale = sv; " ..
		"print \"%s \", tt, \"\\n\""):format(ms, e - 62, TOSTRING_PLACES, label)
	bc_lines[#bc_lines + 1] = expr
	labels[#labels + 1] = label
	tostr_cases[label] = { got = got, neg = (m < 0) }
end

-- Reconstructs the expected fixed-point string directly from bc's own
-- truncated big-integer digit string (left-padded so the last
-- TOSTRING_PLACES digits are always the fraction, even when the
-- truncated magnitude is all zero or has fewer digits than `places`).
-- The "-" prefix is applied whenever the ORIGINAL m was negative, even if
-- every visible digit truncates to zero -- matching fx.tostring's own
-- documented convention (same as e.g. C's "%.2f" printing -0.001 as
-- "-0.00", not "0.00").
local function expected_tostring_str(tt_digits, neg)
	local s = tt_digits
	while #s < TOSTRING_PLACES + 1 do s = "0" .. s end
	local ip = s:sub(1, #s - TOSTRING_PLACES)
	local frac = TOSTRING_PLACES > 0 and s:sub(#s - TOSTRING_PLACES + 1) or ""
	local out = (TOSTRING_PLACES > 0) and (ip .. "." .. frac) or ip
	if neg then out = "-" .. out end
	return out
end

-- Mantissa set: mantissa_set()'s own 5 fixed edge values (min/max/
-- min+1/max-1/midpoint) plus TOSTRING_MANTISSA_COUNT more from the
-- shared LCG, same pattern as the div sweep above. Sign alternates by
-- mantissa INDEX, not by exponent -- index-based, not randomized, same
-- rationale as SIGN_QUADRANTS' own comment: deterministic and still
-- exercises the negative-truncation path exactly as often as positive.
local TOSTRING_MANTISSA_COUNT = fast and 15 or 45
local tostrset = mantissa_set(TOSTRING_MANTISSA_COUNT)
-- Exponents from ~1e-18 magnitude through ~1e15 -- the low end deep in
-- "all requested places are leading zeros" territory (a real property of
-- fixed-point formatting, not a bug -- see fixed_test.lua's round-trip
-- tolerance comment for the same finding measured a different way), the
-- high end past the ~1e14 scientific-notation threshold M.tostring's own
-- fix (string.format("%.0f", ip) instead of plain tostring(ip)) targets.
local TOSTRING_EXPS = {-60, -40, -20, -10, -5, -1, 0, 1, 5, 10, 20, 40, 50}
local tostring_case_count = 0
for i = 1, #tostrset do
	local sign = ((i - 1) % 2 == 0) and 1 or -1
	local sm = signed_i64(tostrset[i], sign)
	for _, e in ipairs(TOSTRING_EXPS) do
		add_tostring_case(sm, e, ("tostr_%d_%d"):format(i, e))
		tostring_case_count = tostring_case_count + 1
	end
end

io.stderr:write(("kernel_bc_sweep: %d div cases, %d ln cases, %d exp cases " ..
	"(%d r-domain + %d x-domain), %d cos cases, %d sqrt cases, %d pow cases, %d tostring cases (FAST=%s)\n"):format(
	div_pair_count, ln_case_count, expfn_r_count + expfn_x_count,
	expfn_r_count, expfn_x_count, cos_case_count, sqrt_case_count, pow_case_count, tostring_case_count,
	tostring(fast ~= nil)))

local bc_script = table.concat(bc_lines, "\n") .. "\n"
local tmp = os.tmpname()
local f = io.open(tmp, "w")
f:write(bc_script)
f:close()

-- BC_LINE_LENGTH=0 disables GNU bc's default ~70-column output wrapping.
-- Without it, `print` splits any long decimal (this script's whole point:
-- ~90-digit relative errors) across multiple physical lines joined by a
-- trailing backslash, which silently broke the one-value-per-line parser
-- below -- caught because only 49 of 854 cases were producing a parseable
-- result, not because of an obvious crash.
local h = io.popen("BC_LINE_LENGTH=0 bc -l < " .. tmp)
local out = h:read("*a")
local ok_close = h:close()
os.remove(tmp)

if not out or out == "" then
	io.stderr:write("kernel_bc_sweep FAILED: bc produced no output (is `bc` installed?)\n")
	os.exit(1)
end

-- div is a single exact truncating division (see M.div's doc comment for
-- the proof it's exact up to the final 62-bit truncation); its error must
-- sit strictly under 1 ULP at the 62-bit mantissa scale, and div has no
-- cancellation dynamics (nothing subtracts two close large numbers), so a
-- pure relative bound is the right and sufficient check.
--
-- ln compounds a 20-term series plus ~40 mul/add truncations (a few ULP of
-- headroom is budgeted for that alone), AND for arguments near 1.0 suffers
-- genuine catastrophic cancellation in k*ln2 + ln(mantissa) (see the
-- add_ln_case comment above) -- so a case is accepted if EITHER its
-- relative error is tight OR its absolute error is tiny, matching the
-- standard numerical-analysis practice of combining atol and rtol (e.g.
-- numpy's isclose) rather than trusting either bound alone. A genuine bug
-- -- like the original div overflow, or the original 12-term series gap --
-- fails BOTH bounds simultaneously (relative error near 1, absolute error
-- comparable to ln2 itself), so this does not paper over real defects.
-- LIMITATION, stated precisely rather than left implicit: no tolerance
-- defined below, however tight, can detect a rounding-DIRECTION
-- regression in div (e.g. truncate-toward-zero silently becoming
-- floor-toward-negative-infinity for negative, inexact results -- the
-- exact mutant this project's own review process caught once). For random
-- operands, floor-toward-negative-infinity's error magnitude is `1 - f`,
-- where `f` is the true fractional remainder in [0, 1) at the mantissa's
-- own scale; truncate-toward-zero's error magnitude is `f` itself. Both
-- `f` and `1 - f` are uniformly distributed over [0, 1) for the same
-- input distribution -- they have the SAME distribution, just mirrored.
-- Any magnitude-only relative-error bound wide enough to accept the
-- CORRECT algorithm's own ordinary truncation error therefore necessarily
-- accepts the mutant's error too; there is no DIV_RTOL, tight or loose,
-- that admits one distribution and rejects the other, because they are
-- the same distribution. This is not a tuning problem -- it is what a
-- magnitude-only control can and cannot see, structurally. Rounding-
-- direction regressions are caught EXCLUSIVELY by fixed_test.lua's pinned
-- exact-value tests (six negative-operand cases, hand-verified against
-- bc's own exact big-integer division, asserting the precise expected
-- mantissa with zero tolerance) -- never by this sweep. This matters most
-- for the eventual Zig port: `@divTrunc` vs `@divFloor` is exactly this
-- divergence, and a reader who believes this sweep already covers
-- rounding direction will under-test that port.
--
-- DIV_RTOL is 2^-61, not 2^-62: div's PRE-normalization quotient
-- q = floor((a/b) * 2^62) can be as small as just above 2^61 (whenever
-- a/b is close to its minimum of 0.5, i.e. a < b and nearly equal), and a
-- floor's absolute error (< 1) relative to a base near 2^61 is up to
-- ~2^-61, not ~2^-62. M.norm's subsequent doubling does not tighten this:
-- relative error is scale-invariant under doubling, so whatever coarseness
-- the truncation had at the pre-norm scale survives unchanged. Confirmed
-- against bc's exact big-integer floor((a*2^62)/b): the kernel's raw q
-- matched bc's exact integer result bit-for-bit for the sweep's worst case
-- (div_mant_12_18, relative error 4.000536e-19 < 2^-61 = 4.336809e-19) --
-- this is div behaving exactly as designed, not an implementation defect.
-- An earlier version of this threshold was 3e-19 (based on the wrong
-- 2^-62 assumption) and flagged 29 genuinely-correct cases as failures.
local DIV_RTOL = 5e-19
local LN_RTOL = 5e-18     -- ~23x the 2^-62 ULP, budget for series + compounding
local LN_ATOL = 1e-15     -- ~350x the observed cancellation-case absolute error
-- exp's r-domain (|r| <= ln2/2, k=0) isolates the Taylor series' own
-- convergence: measured worst case (task-7-report.md) 3.32e-18 -- roughly
-- 3x this bound, giving margin without hiding a real regression the way
-- an order-of-magnitude-looser bound would.
local EXPFN_R_RTOL = 1e-17
-- exp's x-domain (full pipeline, |x| up to 5000) additionally compounds
-- M.LN2_M's own fixed ~1e-19-scale truncation error, AMPLIFIED linearly by
-- k = round(x/ln2) -- k ~ 7213 at x=5000 -- exactly the same mechanism
-- M.ln's own k*ln2 term is documented to suffer from (see M.ln's doc
-- comment and this file's LN_ATOL note above), not a series or
-- range-reduction defect. Measured worst case 1.51e-15 at x=5000; unlike
-- ln, exp(x) is never zero for finite x, so there is no near-zero
-- cancellation blind spot here and a pure relative bound is sufficient
-- (no atol needed).
local EXPFN_X_RTOL = 4e-15
-- cos uses an rtol/atol pair for the SAME structural reason ln does
-- (catastrophic cancellation near a zero makes relative error ill-
-- conditioned), but the ATOL escape hatch is deliberately NOT applied to
-- every cos_ label the way LN_ATOL is applied to every ln_ label.
--
-- WHY NOT: a first version of this bound used a single universal
-- (COS_RTOL, COS_ATOL) pair, COS_ATOL = 5e-15, applied to every cos_
-- label. Mutation-tested by perturbing M.PI_2_M by +1000 (a ~1.4e-16
-- relative error) and re-running: kernel_bc_sweep still PASSED, 10/10
-- runs -- the mutant SURVIVED. Root cause: the ATOL check has no idea
-- WHY a case's absolute error is small. On a well-conditioned point
-- (|cos| ~ O(1), the cos_uniform_ cases), a ~1.4e-16 relative PI_2 error
-- shows up as a ~1e-16 ABSOLUTE error too (error scales with the
-- reference magnitude when the reference isn't near zero) -- comfortably
-- under a 5e-15 ATOL, so the "OR absolute error is tiny" branch silently
-- rescued a real, detectable bug on cases where nothing was actually
-- ill-conditioned. A universal ATOL doesn't just cover the cancellation
-- case it was sized for, it accidentally covers ANY sufficiently-subtle
-- bug on EVERY case, because every cos/sin value in this domain is
-- already O(1) or smaller -- exactly the shotgun-without-a-specificity-
-- corpus trap.
--
-- FIX: restrict the ATOL rescue to the labels that are STRUCTURALLY
-- ill-conditioned by construction -- cos_nearzero_ (the near-1/4/3/4-turn
-- cancellation probes) and cos_boundary_ (bc's own l()/c() near an exact
-- zero can report a nonzero-but-tiny reference purely from scale=90
-- rounding) -- see the parsing loop below. cos_uniform_ gets COS_RTOL
-- ONLY, no escape hatch, so a subtle whole-domain bug like the PI_2
-- mutant above cannot hide behind it. See task-8-report.md's mutation
-- section for the re-run transcript confirming this actually catches it.
--
-- Values: a first COS_RTOL guess of 5e-18 (23x the 2^-62 floor, copying
-- LN_RTOL's own margin without re-measuring for cos) turned out too
-- tight -- it FAILED THE CORRECT, UNMUTATED kernel: a standalone sweep of
-- just the 236 cos_uniform_ cases (same LCG stream this file uses) found
-- a real worst case of 6.140488e-18 (cos_uniform_67), above 5e-18 by
-- construction, not a bug -- 28 mul/add ops per series compounding to
-- ~28x the ULP floor is the same order of magnitude ln's own ~40-op
-- series lands at. COS_RTOL = 2e-17 gives ~3.3x margin above that
-- measured worst case (matching EXPFN_R_RTOL's own ~3x margin practice)
-- while staying ~7x tighter than the PI_2-class mutant's ~1.4e-16
-- relative error, so it still catches that mutant on cos_uniform_ (see
-- below). COS_ATOL = 1e-16 is ~90x the worst measured absolute error on
-- the correct kernel across BOTH rescued categories (cos_nearzero_ and
-- cos_boundary_ combined, measured worst 1.1e-18) -- enough margin for
-- ordinary noise, tight enough that the same mutant's ~1e-16 absolute
-- error still trips it on the rescued labels too, not just on
-- cos_uniform_.
local COS_RTOL = 2e-17
local COS_ATOL = 1e-16

-- sqrt is a single Newton refinement stage on top of an already-normalized
-- operand -- no cancellation dynamics (like div, not like ln/cos), so a
-- pure relative bound is sufficient, no atol escape hatch needed. Measured
-- worst case over the FULL (non-FAST) sweep of 1995 cases spanning the
-- full mantissa range and both exponent parities at 19 magnitudes:
-- 2.262778e-19 (sqrt_12_-49) -- already AT this kernel's ~2^-62
-- (2.168e-19) floor, consistent with SQRT_REFINE's own derivation in
-- lib/fixed.lua (measured worst 6.3e-19 to 8.6e-19 over a separate
-- 20000-sample Lua-side sweep; this bc-oracle sweep, independent of that
-- one, lands in the same order of magnitude). SQRT_RTOL = 2e-18 gives
-- ~8.8x margin above the measured worst case -- between DIV_RTOL's tight
-- ~1.2x (a single exact truncation, no compounding) and LN_RTOL's ~23x
-- (a 20-term series plus ~40 compounding mul/add ops), reflecting sqrt's
-- own small, bounded number of compounding operations (SQRT_REFINE=3
-- div+add pairs on top of the integer-Newton seed).
local SQRT_RTOL = 2e-18
-- pow compounds THREE kernel operations (ln, mul, exp), each with its own
-- error budget, so its floor is necessarily looser than sqrt's or div's.
-- Measured worst case over the full sweep (240 cases, x in roughly
-- [2^-5, 2^5], y in {-20,-3,-1,1,3,20}): 5.253608e-17 (pow_20_5_20).
-- POW_RTOL = 3e-16 gives ~5.7x margin, in the same range as EXPFN_R_RTOL's
-- own ~3x margin over ITS measured worst case -- pow's compounding is
-- similar in kind (a kernel op feeding a kernel op), not looser by an
-- order of magnitude the way exp's x-domain (which additionally
-- compounds LN2's own fixed truncation, amplified by a potentially large
-- k) is.
local POW_RTOL = 3e-16

local worst_div_rel, worst_div_label = 0, nil
local worst_ln_rel, worst_ln_rel_label = 0, nil
local worst_ln_abs, worst_ln_abs_label = 0, nil
local worst_expfn_r_rel, worst_expfn_r_label = 0, nil
local worst_expfn_x_rel, worst_expfn_x_label = 0, nil
local worst_cos_rel, worst_cos_rel_label = 0, nil
local worst_cos_abs, worst_cos_abs_label = 0, nil
local worst_cos_nearzero_rel, worst_cos_nearzero_rel_label = 0, nil
local worst_sqrt_rel, worst_sqrt_rel_label = 0, nil
local worst_pow_rel, worst_pow_rel_label = 0, nil
local div_bad, ln_bad, expfn_bad, cos_bad, sqrt_bad, pow_bad = 0, 0, 0, 0, 0, 0
local tostr_bad, tostr_seen = 0, 0
local tostr_mismatches = {}   -- capped list of "label: got vs want" for the fail report
local skipped = 0
local seen = 0
for line in out:gmatch("[^\n]+") do
	local label, rest = line:match("^(%S+)%s+(.*)$")
	if label and label:match("^tostr_") then
		-- Single-token line (the truncated big integer `tt`, as an
		-- arbitrary-precision STRING) rather than the "<relerr> <absdiff>"
		-- shape every other case below emits -- handled in its OWN branch,
		-- ahead of the generic two-float parse, so it is never silently
		-- swallowed by that parse failing to match and falling through
		-- unnoticed.
		tostr_seen = tostr_seen + 1
		local tt = rest:gsub("%s+$", "")
		local case = tostr_cases[label]
		local want = expected_tostring_str(tt, case.neg)
		if want ~= case.got then
			tostr_bad = tostr_bad + 1
			if #tostr_mismatches < 5 then
				tostr_mismatches[#tostr_mismatches + 1] =
					("%s: got %q want %q (bc tt=%s)"):format(label, case.got, want, tt)
			end
		end
	elseif label and rest == "SKIP" then
		skipped = skipped + 1
	elseif label then
		local relstr, absstr = rest:match("^(%S+)%s+(%S+)$")
		local relerr, absdiff = tonumber(relstr), tonumber(absstr)
		if relerr and absdiff then
			seen = seen + 1
			local arel = relerr < 0 and -relerr or relerr
			local aabs = absdiff < 0 and -absdiff or absdiff
			if label:match("^div_") then
				if arel > worst_div_rel then worst_div_rel, worst_div_label = arel, label end
				if arel > DIV_RTOL then div_bad = div_bad + 1 end
			elseif label:match("^ln_") then
				if arel > worst_ln_rel then worst_ln_rel, worst_ln_rel_label = arel, label end
				if aabs > worst_ln_abs then worst_ln_abs, worst_ln_abs_label = aabs, label end
				if arel > LN_RTOL and aabs > LN_ATOL then ln_bad = ln_bad + 1 end
			elseif label:match("^expfn_r_") then
				if arel > worst_expfn_r_rel then worst_expfn_r_rel, worst_expfn_r_label = arel, label end
				if arel > EXPFN_R_RTOL then expfn_bad = expfn_bad + 1 end
			elseif label:match("^expfn_x_") then
				if arel > worst_expfn_x_rel then worst_expfn_x_rel, worst_expfn_x_label = arel, label end
				if arel > EXPFN_X_RTOL then expfn_bad = expfn_bad + 1 end
			elseif label:match("^cos_") then
				if arel > worst_cos_rel then worst_cos_rel, worst_cos_rel_label = arel, label end
				if aabs > worst_cos_abs then worst_cos_abs, worst_cos_abs_label = aabs, label end
				if label:match("^cos_nearzero_") and arel > worst_cos_nearzero_rel then
					worst_cos_nearzero_rel, worst_cos_nearzero_rel_label = arel, label
				end
				-- ATOL rescue restricted to labels that are STRUCTURALLY
				-- ill-conditioned (near a genuine zero of cos) -- see the
				-- COS_RTOL/COS_ATOL comment above for the mutation-tested
				-- reason cos_uniform_ must NOT get this escape hatch.
				local ill_conditioned = label:match("^cos_nearzero_") or label:match("^cos_boundary_")
				if arel > COS_RTOL and not (ill_conditioned and aabs <= COS_ATOL) then
					cos_bad = cos_bad + 1
				end
			elseif label:match("^sqrt_") then
				if arel > worst_sqrt_rel then worst_sqrt_rel, worst_sqrt_rel_label = arel, label end
				if arel > SQRT_RTOL then sqrt_bad = sqrt_bad + 1 end
			elseif label:match("^pow_") then
				if arel > worst_pow_rel then worst_pow_rel, worst_pow_rel_label = arel, label end
				if arel > POW_RTOL then pow_bad = pow_bad + 1 end
			end
		end
	end
end

local expected = div_pair_count + ln_case_count + expfn_r_count + expfn_x_count + cos_case_count +
	sqrt_case_count + pow_case_count
print(("bc sweep: %d/%d cases measured (%d skipped as ref==0)"):format(seen, expected, skipped))
-- Separate line, not folded into `seen`/`expected` above: tostring cases
-- are an exact-string match against bc's own truncated integer, not a
-- relative/absolute-error tolerance check, and have no SKIP concept (bc's
-- truncating division at scale=0 always produces SOME integer, including
-- exactly 0), so mixing the two counts would blur what each is actually
-- measuring.
print(("tostring sweep: %d/%d cases measured, %d mismatched"):format(
	tostr_seen, tostring_case_count, tostr_bad))
print(("worst div relative error: %.6e (%s)"):format(worst_div_rel, tostring(worst_div_label)))
print(("worst ln  relative error: %.6e (%s)"):format(worst_ln_rel, tostring(worst_ln_rel_label)))
print(("worst ln  absolute error: %.6e (%s)"):format(worst_ln_abs, tostring(worst_ln_abs_label)))
print(("worst exp r-domain (k=0, series-only) relative error: %.6e (%s)"):format(
	worst_expfn_r_rel, tostring(worst_expfn_r_label)))
print(("worst exp x-domain (full pipeline)     relative error: %.6e (%s)"):format(
	worst_expfn_x_rel, tostring(worst_expfn_x_label)))
print(("worst cos relative error (all cases):   %.6e (%s)"):format(worst_cos_rel, tostring(worst_cos_rel_label)))
print(("worst cos absolute error (all cases):   %.6e (%s)"):format(worst_cos_abs, tostring(worst_cos_abs_label)))
print(("worst cos relative error (near-zero cancellation probe only): %.6e (%s)"):format(
	worst_cos_nearzero_rel, tostring(worst_cos_nearzero_rel_label)))
print(("worst sqrt relative error: %.6e (%s)"):format(worst_sqrt_rel, tostring(worst_sqrt_rel_label)))
print(("worst pow  relative error: %.6e (%s)"):format(worst_pow_rel, tostring(worst_pow_rel_label)))

local fails = 0
if seen == 0 then
	io.stderr:write("kernel_bc_sweep FAILED: no cases were actually measured\n")
	fails = fails + 1
end
if div_bad > 0 then
	io.stderr:write(("kernel_bc_sweep FAILED: %d div case(s) exceeded rtol %.1e (worst %.6e, %s)\n"):format(
		div_bad, DIV_RTOL, worst_div_rel, tostring(worst_div_label)))
	fails = fails + 1
end
if ln_bad > 0 then
	io.stderr:write(("kernel_bc_sweep FAILED: %d ln case(s) exceeded BOTH rtol %.1e and atol %.1e\n"):format(
		ln_bad, LN_RTOL, LN_ATOL))
	fails = fails + 1
end
if expfn_bad > 0 then
	io.stderr:write(("kernel_bc_sweep FAILED: %d exp case(s) exceeded rtol (r-domain %.1e / x-domain %.1e) " ..
		"(worst r=%.6e %s, worst x=%.6e %s)\n"):format(
		expfn_bad, EXPFN_R_RTOL, EXPFN_X_RTOL,
		worst_expfn_r_rel, tostring(worst_expfn_r_label),
		worst_expfn_x_rel, tostring(worst_expfn_x_label)))
	fails = fails + 1
end
if cos_bad > 0 then
	io.stderr:write(("kernel_bc_sweep FAILED: %d cos case(s) exceeded BOTH rtol %.1e and atol %.1e " ..
		"(worst rel %.6e %s, worst abs %.6e %s)\n"):format(
		cos_bad, COS_RTOL, COS_ATOL,
		worst_cos_rel, tostring(worst_cos_rel_label),
		worst_cos_abs, tostring(worst_cos_abs_label)))
	fails = fails + 1
end
if sqrt_bad > 0 then
	io.stderr:write(("kernel_bc_sweep FAILED: %d sqrt case(s) exceeded rtol %.1e (worst %.6e, %s)\n"):format(
		sqrt_bad, SQRT_RTOL, worst_sqrt_rel, tostring(worst_sqrt_rel_label)))
	fails = fails + 1
end
if pow_bad > 0 then
	io.stderr:write(("kernel_bc_sweep FAILED: %d pow case(s) exceeded rtol %.1e (worst %.6e, %s)\n"):format(
		pow_bad, POW_RTOL, worst_pow_rel, tostring(worst_pow_rel_label)))
	fails = fails + 1
end
if tostr_seen == 0 then
	io.stderr:write("kernel_bc_sweep FAILED: no tostring cases were actually measured\n")
	fails = fails + 1
end
if tostr_bad > 0 then
	io.stderr:write(("kernel_bc_sweep FAILED: %d tostring case(s) did not exactly match bc's own " ..
		"truncated-decimal oracle\n"):format(tostr_bad))
	for _, msg in ipairs(tostr_mismatches) do
		io.stderr:write("  " .. msg .. "\n")
	end
	fails = fails + 1
end

if fails > 0 then
	os.exit(fails)
end
print("kernel_bc_sweep PASSED")
