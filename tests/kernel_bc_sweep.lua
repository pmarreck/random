-- Sweeps M.div and M.ln against `bc -l` (arbitrary precision) as an
-- independent oracle. This exists because a Lua-double comparison CANNOT
-- validate this kernel's ~2^-62 (~2.2e-19) precision claim: tonumber() on a
-- 63-bit mantissa collapses it into an IEEE double's 53-bit mantissa,
-- which is itself only accurate to ~1.1e-16 -- discovered directly while
-- writing this task's unit tests, where two mathematically-identical ln
-- computations (ln(3)+ln(5) vs ln(15)) disagreed at the 1e-16 level purely
-- from that lossy conversion, before bc's exact rational arithmetic showed
-- the REAL error was three orders of magnitude smaller. Only bc's
-- arbitrary-precision decimal arithmetic can actually measure error down
-- at the scale this kernel claims to carry.
--
-- No `math.*`, no float literals, never `^` -- except here, deliberately:
-- this file is test-only infrastructure that talks to bc, not kernel code.
package.path = (arg[0] or ""):match("^(.*)/[^/]+$") .. "/../lib/?.lua;" .. package.path
local ffi = require("ffi")
local fx = require("fixed")

local i64 = ffi.typeof("int64_t")
local u64 = ffi.typeof("uint64_t")
local TWO62 = 0x4000000000000000ULL

local fast = os.getenv("FAST")
-- FAST (./test's default) still comfortably clears "a few hundred operand
-- pairs" per the task brief; unsetting FAST runs a deeper statistical sweep.
local MANTISSA_COUNT = fast and 20 or 60
local EXP_MANTISSA_COUNT = fast and 5 or 10
local EXP_DIFFS = {-5000, -500, -50, -7, -1, 0, 1, 7, 50, 500, 5000}
local LN_MANTISSA_COUNT = fast and 12 or 40
local LN_EXPS = {-50, -5, -1, 0, 1, 5, 50}

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

local function u64dec(v)
	-- MUST go through tostring(), never tonumber(): tonumber() on a u64
	-- cdata converts through an IEEE double (53-bit mantissa), silently
	-- rounding any value above 2^53 -- exactly the double-precision-floor
	-- trap this whole sweep exists to route around (see the top-of-file
	-- comment). Confirmed by direct probe: tonumber(0x7FFFFFFFFFFFFFFEULL)
	-- formatted as "%.0f" prints 9223372036854775808, two off from the
	-- true 9223372036854775806 that tostring() gives exactly. This was
	-- caught by the sweep itself (a spuriously large "kernel" error that
	-- traced back to a wrong reference operand, not a wrong kernel result).
	return (tostring(v):gsub("ULL$", ""))
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
	local m1s, m2s = u64dec(ffi.cast(u64, m1)), u64dec(ffi.cast(u64, m2))
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

-- === div: mantissa sweep (e1 = e2 = 0), the part directly at risk from ===
-- === the overflow bug this file exists to catch.                      ===
local mset = mantissa_set(MANTISSA_COUNT)
local div_pair_count = 0
for i = 1, #mset do
	for j = 1, #mset do
		add_div_case(ffi.cast(i64, mset[i]), 0, ffi.cast(i64, mset[j]), 0,
			("div_mant_%d_%d"):format(i, j))
		div_pair_count = div_pair_count + 1
	end
end

-- === div: exponent sweep, confirming e1-e2 bookkeeping over a spread ===
-- === of magnitudes without depending on the mantissa sweep above.    ===
local eset = mantissa_set(EXP_MANTISSA_COUNT)
for i = 1, #eset do
	for _, d in ipairs(EXP_DIFFS) do
		add_div_case(ffi.cast(i64, eset[i]), d, ffi.cast(i64, eset[(i % #eset) + 1]), 0,
			("div_exp_%d_%d"):format(i, d))
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

io.stderr:write(("kernel_bc_sweep: %d div cases, %d ln cases (FAST=%s)\n"):format(
	div_pair_count, ln_case_count, tostring(fast ~= nil)))

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

local worst_div_rel, worst_div_label = 0, nil
local worst_ln_rel, worst_ln_rel_label = 0, nil
local worst_ln_abs, worst_ln_abs_label = 0, nil
local div_bad, ln_bad = 0, 0
local skipped = 0
local seen = 0
for line in out:gmatch("[^\n]+") do
	local label, rest = line:match("^(%S+)%s+(.*)$")
	if label and rest == "SKIP" then
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
			end
		end
	end
end

local expected = div_pair_count + ln_case_count
print(("bc sweep: %d/%d cases measured (%d skipped as ref==0)"):format(seen, expected, skipped))
print(("worst div relative error: %.6e (%s)"):format(worst_div_rel, tostring(worst_div_label)))
print(("worst ln  relative error: %.6e (%s)"):format(worst_ln_rel, tostring(worst_ln_rel_label)))
print(("worst ln  absolute error: %.6e (%s)"):format(worst_ln_abs, tostring(worst_ln_abs_label)))

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

if fails > 0 then
	os.exit(fails)
end
print("kernel_bc_sweep PASSED")
