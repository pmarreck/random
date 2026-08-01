package.path = (arg[0] or ""):match("^(.*)/[^/]+$") .. "/../lib/?.lua;" .. package.path
local ffi = require("ffi")
local fx = require("fixed")

local fails, checks = 0, 0
local function ok(cond, label, detail)
	checks = checks + 1
	if cond then
		print("✓ " .. label)
	else
		io.stderr:write("✗ " .. label .. (detail and ("  " .. detail) or "") .. "\n")
		fails = fails + 1
	end
end

-- relative difference between two soft-floats, as a Lua number.
-- Test-only convenience; uses floats deliberately, and only to score error.
function math_abs_rel(m1, e1, m2, e2)
	local function tofloat(m, e)
		if m == 0 then return 0.0 end
		return tonumber(m) * 2 ^ (e - 62)
	end
	local a, b = tofloat(m1, e1), tofloat(m2, e2)
	if b == 0 then return math.abs(a) end
	return math.abs((a - b) / b)
end

print("Testing integer-only numeric kernel...")
print("============================================")
print("")
print("--- Section 1: representation and multiply ---")

-- 1.0 is mantissa 2^62 with exponent 0
local ONE_M, ONE_E = fx.from_int(1)
ok(ONE_M == 0x4000000000000000LL and ONE_E == 0, "from_int(1) is normalized",
   ("got m=%s e=%d"):format(tostring(ONE_M), ONE_E))

-- normalization invariant holds for a range of inputs
local inv_ok = true
for _, v in ipairs({1, 2, 3, 7, 100, -1, -2, -12345, 4294967296}) do
	local m, e = fx.from_int(v)
	if m ~= 0 then
		local a = m < 0 and -m or m
		-- Upper bound "a < 2^63" must NOT be written as "a < 0x7FFF...FFLL + 1":
		-- that addition overflows int64_t (INT64_MAX + 1 wraps to INT64_MIN),
		-- making the comparison always false. Since a is itself an int64_t,
		-- "a < 2^63" is equivalent to "a <= INT64_MAX" with no arithmetic.
		if not (a >= 0x4000000000000000LL and a <= 0x7FFFFFFFFFFFFFFFLL) then
			inv_ok = false
		end
	end
end
ok(inv_ok, "from_int keeps 2^62 <= |m| < 2^63 for all sampled inputs")

-- zero is canonical
local zm, ze = fx.from_int(0)
ok(zm == 0LL and ze == 0, "zero is canonical (m=0, e=0)")

-- 2 * 3 == 6, exactly
local am, ae = fx.from_int(2)
local bm, be = fx.from_int(3)
local pm, pe = fx.mul(am, ae, bm, be)
local em, ee = fx.from_int(6)
ok(pm == em and pe == ee, "2 * 3 == 6 exactly",
   ("got m=%s e=%d want m=%s e=%d"):format(tostring(pm), pe, tostring(em), ee))

-- sign handling across all four quadrants
local cases = {{2,3,6},{-2,3,-6},{2,-3,-6},{-2,-3,6}}
local sign_ok = true
for _, c in ipairs(cases) do
	local x1,x2 = fx.from_int(c[1]); local y1,y2 = fx.from_int(c[2])
	local r1,r2 = fx.mul(x1,x2,y1,y2)
	local w1,w2 = fx.from_int(c[3])
	if not (r1 == w1 and r2 == w2) then sign_ok = false end
end
ok(sign_ok, "multiply handles all four sign combinations")

-- The precondition asserts must be tested on BOTH operands and must be
-- distinguishable from each other. Corrupting only operand 1 lets a
-- copy-paste typo in operand 2's assert survive: verified by mutation, a
-- second assert re-checking `a` passes the whole suite while silently
-- accepting the bad operand the guard exists to reject.
local function rejects(m1, e1, m2, e2, want_msg)
	local okc, err = pcall(fx.mul, m1, e1, m2, e2)
	if okc then return false, "accepted" end
	if not tostring(err):find(want_msg, 1, true) then
		return false, "wrong assert fired: " .. tostring(err)
	end
	return true
end
local r1, why1 = rejects(1LL, 0, ONE_M, ONE_E, "operand 1 not normalized")
ok(r1, "mul rejects an unnormalized operand 1", why1)
local r2, why2 = rejects(ONE_M, ONE_E, 1LL, 0, "operand 2 not normalized")
ok(r2, "mul rejects an unnormalized operand 2", why2)
local r3, why3 = rejects(-0x8000000000000000LL, 0, ONE_M, ONE_E, "operand 1 not normalized")
ok(r3, "mul rejects INT64_MIN (magnitude 2^63 is outside the invariant)", why3)

-- multiplying by zero yields canonical zero
local z1, z2 = fx.mul(am, ae, 0LL, 0)
ok(z1 == 0LL and z2 == 0, "x * 0 == canonical zero")

-- mul128 against known values: (2^63) * (2^63) = 2^126 -> hi = 2^62, lo = 0
local hi, lo = fx.mul128(0x8000000000000000ULL, 0x8000000000000000ULL)
ok(hi == 0x4000000000000000ULL and lo == 0ULL, "mul128(2^63, 2^63) == 2^126")

-- mul128 low-word carry: (2^64-1)^2 = 2^128 - 2^65 + 1
local hi2, lo2 = fx.mul128(0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL)
ok(hi2 == 0xFFFFFFFFFFFFFFFEULL and lo2 == 1ULL, "mul128(2^64-1, 2^64-1) carries correctly",
   ("got hi=%s lo=%s"):format(tostring(hi2), tostring(lo2)))

print("")
print("--- Section 2: addition, subtraction, comparison ---")

local function eqint(m, e, want)
	local wm, we = fx.from_int(want)
	return m == wm and e == we
end

-- exact small-integer arithmetic
local a1, a2 = fx.from_int(2)
local b1, b2 = fx.from_int(3)
local s1, s2 = fx.add(a1, a2, b1, b2)
ok(eqint(s1, s2, 5), "2 + 3 == 5 exactly")

local d1, d2 = fx.sub(b1, b2, a1, a2)
ok(eqint(d1, d2, 1), "3 - 2 == 1 exactly")

local n1, n2 = fx.sub(a1, a2, b1, b2)
ok(eqint(n1, n2, -1), "2 - 3 == -1 exactly")

-- identity: x + 0 == x, 0 + x == x
local i1, i2 = fx.add(a1, a2, 0LL, 0)
ok(i1 == a1 and i2 == a2, "x + 0 == x")
local j1, j2 = fx.add(0LL, 0, a1, a2)
ok(j1 == a1 and j2 == a2, "0 + x == x")

-- total cancellation must produce canonical zero, not a denormal
local c1, c2 = fx.sub(a1, a2, a1, a2)
ok(c1 == 0LL and c2 == 0, "x - x == canonical zero", ("got m=%s e=%d"):format(tostring(c1), c2))

-- Mutation-testing note: add()'s own "if sum == 0" short-circuit is provably
-- redundant -- M.norm(0, e) already canonicalizes to (0,0) for ANY e, so
-- deleting add's check is an equivalent mutant (verified: it does not change
-- behavior for any input, so no test should or can "kill" it). What DOES need
-- direct coverage, and had none until this task, is norm()'s own zero guard
-- itself, since every other norm() caller (from_int, mul) short-circuits on
-- zero before ever reaching norm.
for _, e in ipairs({0, 1, -1, 12345, -99999}) do
	local zm, ze = fx.norm(0LL, e)
	ok(zm == 0LL and ze == 0, ("norm(0, %d) canonicalizes to (0, 0)"):format(e),
	   ("got m=%s e=%d"):format(tostring(zm), ze))
end

-- PARTIAL cancellation must NOT be mistaken for total cancellation: two
-- adjacent odd mantissas at the same exponent have a true difference of
-- exactly 1 ULP. A naive implementation that pre-halves EACH operand toward
-- zero before summing loses that 1 ULP from both sides identically and
-- reports canonical zero for a genuinely nonzero difference -- verified by
-- hand-tracing the brief's original arithmetic against this exact case
-- before the fix (see the doc comment on M.add).
local odd1, oe1 = 0x4000000000000123LL, 5
local odd2, oe2 = odd1 - 1LL, 5
local p1, p2 = fx.sub(odd1, oe1, odd2, oe2)
ok(not (p1 == 0LL and p2 == 0), "a true 1-ULP difference must not collapse to false zero",
   ("got m=%s e=%d"):format(tostring(p1), p2))
-- and it must be the RIGHT nonzero value: 1 ULP at exponent 5 is 2^(5-62).
local want1, want2 = fx.norm(1LL, 5)
ok(p1 == want1 and p2 == want2, "a true 1-ULP difference is recovered exactly",
   ("got m=%s e=%d want m=%s e=%d"):format(tostring(p1), p2, tostring(want1), want2))

-- adding a value far below the ulp must not change the larger operand
local big1, big2 = fx.from_int(1)
local tiny1, tiny2 = fx.norm(0x4000000000000000LL, -200)
local u1, u2 = fx.add(big1, big2, tiny1, tiny2)
ok(u1 == big1 and u2 == big2, "1 + 2^-200 == 1 (addend below the ulp)")

-- The d >= 63 threshold (POW2 only covers indices 0..62) needs boundary
-- coverage: d=62 is the last index actually reachable and must still shift
-- and contribute; d=63 and beyond must return the larger operand unchanged.
-- A mutant that loosens the guard to "d > 63" lets d=63 reach POW2[63],
-- which is nil, and would only be caught by a test sitting exactly on that
-- boundary -- the pre-existing "1 + 2^-200" test above has d ~= 200 and
-- does not exercise it.
-- d=62: sub is exact (opposite-sign path), so the tiny operand's single
-- contributed bit is not lost to the same-sign pre-halving. It must move
-- the result off the unchanged value.
local d62_m, d62_e = fx.norm(0x4000000000000000LL, big2 - 62)
local sub62_m, sub62_e = fx.sub(big1, big2, d62_m, d62_e)
ok(not (sub62_m == big1 and sub62_e == big2), "d=62 still shifts and contributes",
   ("got m=%s e=%d"):format(tostring(sub62_m), sub62_e))
ok(sub62_m == 0x7FFFFFFFFFFFFFFELL and sub62_e == -1, "d=62 contributes the exact expected value",
   ("got m=%s e=%d want m=%s e=%d"):format(tostring(sub62_m), sub62_e, tostring(0x7FFFFFFFFFFFFFFELL), -1))

-- d=63: both add and sub must return the larger operand exactly unchanged --
-- this is the case a "d > 63" mutant reaches POW2[63] (nil) and crashes on.
local d63_m, d63_e = fx.norm(0x4000000000000000LL, big2 - 63)
local add63_m, add63_e = fx.add(big1, big2, d63_m, d63_e)
ok(add63_m == big1 and add63_e == big2, "d=63 add leaves the larger operand unchanged",
   ("got m=%s e=%d"):format(tostring(add63_m), add63_e))
local sub63_m, sub63_e = fx.sub(big1, big2, d63_m, d63_e)
ok(sub63_m == big1 and sub63_e == big2, "d=63 sub leaves the larger operand unchanged",
   ("got m=%s e=%d"):format(tostring(sub63_m), sub63_e))

-- d=64: further past the boundary, same requirement, extra margin.
local d64_m, d64_e = fx.norm(0x4000000000000000LL, big2 - 64)
local add64_m, add64_e = fx.add(big1, big2, d64_m, d64_e)
ok(add64_m == big1 and add64_e == big2, "d=64 add leaves the larger operand unchanged",
   ("got m=%s e=%d"):format(tostring(add64_m), add64_e))

-- Same-sign worst case: BOTH operands are truncated independently before
-- summing (m1/2 and shifted/2), so the error bound is up to 2 ULP, not 1.
-- Pinned deterministically rather than left in a scratchpad fuzz script: if
-- the same-sign path regresses to a wider error tomorrow, this must catch
-- it. m1 = 2^62+1 at e=100, m2 = 2^62 at e=38 (d=62): the true sum is
-- 2^62+2 at exponent 100 (no renormalization needed at all, since 2^62+2 is
-- still < 2^63); the kernel's pre-halving loses exactly 2 from the mantissa.
local ss_m1, ss_e1 = 0x4000000000000001LL, 100
local ss_m2, ss_e2 = 0x4000000000000000LL, 38
local ss_rm, ss_re = fx.add(ss_m1, ss_e1, ss_m2, ss_e2)
ok(ss_rm == 0x4000000000000000LL and ss_re == 100, "same-sign worst case is exactly 2 ULP, pinned",
   ("got m=%s e=%d want m=%s e=%d"):format(tostring(ss_rm), ss_re, tostring(0x4000000000000000LL), 100))

-- commutativity over a sampled set (add is order-independent by construction)
local comm_ok = true
for _, p in ipairs({{1,2},{7,-3},{-5,-9},{1000000,1},{3,-3}}) do
	local x1,x2 = fx.from_int(p[1]); local y1,y2 = fx.from_int(p[2])
	local r1,r2 = fx.add(x1,x2,y1,y2)
	local q1,q2 = fx.add(y1,y2,x1,x2)
	if not (r1 == q1 and r2 == q2) then comm_ok = false end
end
ok(comm_ok, "addition is commutative over the sampled set")

-- comparison
ok(fx.cmp(a1, a2, b1, b2) == -1, "cmp(2, 3) == -1")
ok(fx.cmp(b1, b2, a1, a2) == 1, "cmp(3, 2) == 1")
ok(fx.cmp(a1, a2, a1, a2) == 0, "cmp(2, 2) == 0")
ok(fx.cmp(n1, n2, 0LL, 0) == -1, "cmp(-1, 0) == -1")
ok(fx.cmp(0LL, 0, 0LL, 0) == 0, "cmp(0, 0) == 0")

-- comparison must invert the exponent ordering for negative operands: a
-- bigger exponent means a bigger MAGNITUDE, which is a SMALLER value once the
-- sign is negative. -8 < -2 even though |−8| > |−2|.
local neg8_1, neg8_2 = fx.from_int(-8)
local neg2_1, neg2_2 = fx.from_int(-2)
ok(fx.cmp(neg8_1, neg8_2, neg2_1, neg2_2) == -1, "cmp(-8, -2) == -1 (bigger magnitude, more negative)")
ok(fx.cmp(neg2_1, neg2_2, neg8_1, neg8_2) == 1, "cmp(-2, -8) == 1")

-- negation: exact sign flip, zero stays canonical, double negation round-trips
local nz1, nz2 = fx.neg(0LL, 0)
ok(nz1 == 0LL and nz2 == 0, "neg(0) == canonical zero")

local five1, five2 = fx.from_int(5)
local negfive_want1, negfive_want2 = fx.from_int(-5)
local negfive1, negfive2 = fx.neg(five1, five2)
ok(negfive1 == negfive_want1 and negfive2 == negfive_want2, "neg(5) == -5 exactly")

local rt1, rt2 = fx.neg(negfive1, negfive2)
ok(rt1 == five1 and rt2 == five2, "neg(neg(5)) == 5 (double negation round-trips)")

local zsum1, zsum2 = fx.add(five1, five2, negfive1, negfive2)
ok(zsum1 == 0LL and zsum2 == 0, "x + neg(x) == canonical zero")

print("")
print("--- Section 3: divide ---")

-- division by zero must assert, not silently produce garbage
local function rejects_div(m1, e1, m2, e2, want_msg)
	local okc, err = pcall(fx.div, m1, e1, m2, e2)
	if okc then return false, "accepted" end
	if not tostring(err):find(want_msg, 1, true) then
		return false, "wrong assert fired: " .. tostring(err)
	end
	return true
end
-- NOTE: rejects_div(fx.from_int(1), 0LL, 0, "...") would be the same
-- non-last-argument multi-return truncation bug flagged below near
-- ln1o3_m -- from_int(1) is not the final argument here, so it would
-- silently collapse to just its mantissa and shift every later argument
-- over by one. Capture the return values into locals first.
local ONEm, ONEe = fx.from_int(1)
local dr1, dwhy1 = rejects_div(ONEm, ONEe, 0LL, 0, "fixed.div: division by zero")
ok(dr1, "div by zero asserts", dwhy1)

-- 0/0 must ALSO assert, not silently return canonical zero: the divisor
-- check has to run before the m1==0 shortcut, or 0/0 slips through. This
-- pins the ordering bug directly (an earlier version had the shortcut
-- first, which returned (0LL, 0) for 0/0 -- unreachable from any current
-- call site, but a live footgun, and a direct contradiction of the domain
-- stance M.ln takes on its own undefined point at 0).
local dr0, dwhy0 = rejects_div(0LL, 0, 0LL, 0, "fixed.div: division by zero")
ok(dr0, "0 / 0 asserts rather than returning canonical zero", dwhy0)

-- div carries the same normalization precondition as mul, checked on both
-- operands and distinguishably (see mul's identical mutation-testing note
-- above -- a copy-pasted assert on the wrong operand must not survive).
local dr2, dwhy2 = rejects_div(1LL, 0, ONEm, ONEe, "operand 1 not normalized")
ok(dr2, "div rejects an unnormalized operand 1", dwhy2)
local dr3, dwhy3 = rejects_div(ONEm, ONEe, 1LL, 0, "operand 2 not normalized")
ok(dr3, "div rejects an unnormalized operand 2", dwhy3)

-- 0 / x == canonical zero
local zd1, zd2 = fx.div(0LL, 0, ONEm, ONEe)
ok(zd1 == 0LL and zd2 == 0, "0 / x == canonical zero")

-- x / x == 1 exactly (no tolerance needed: a == b means q0=1, remainder 0,
-- so the fractional loop contributes nothing and the result is exactly the
-- soft-float form of 1 -- a genuine exactness guarantee, not an artifact of
-- a generous tolerance).
local selfdiv_ok = true
for _, v in ipairs({1, 2, 3, 7, -5, 1000000, -99999}) do
	local vm, ve = fx.from_int(v)
	local qm, qe = fx.div(vm, ve, vm, ve)
	if not (qm == ONEm and qe == ONEe) then selfdiv_ok = false end
end
ok(selfdiv_ok, "x / x == 1 exactly for a sampled set")

-- x / 1 == x exactly
local divone_ok = true
for _, v in ipairs({1, 2, 3, 7, -5, 1000000, -99999}) do
	local vm, ve = fx.from_int(v)
	local qm, qe = fx.div(vm, ve, ONEm, ONEe)
	if not (qm == vm and qe == ve) then divone_ok = false end
end
ok(divone_ok, "x / 1 == x exactly for a sampled set")

-- Regression pin for the overflow bug described in M.div's doc comment: the
-- brief's original two-31-bit-jump refinement computed r0 * 2^31 where r0
-- (a mod b) can be up to just under 2^63 whenever the dividend's mantissa is
-- smaller than the divisor's -- true for roughly half of all normalized
-- pairs, not a contrived edge case. That silently wrapped mod 2^64 and
-- returned canonical zero for a division whose true value is ~0.5.
-- Verified independently against `bc -l`: (2^62+1)/(2^63-1) truncates to
-- exactly 0.5 at 62-bit precision (the true value's excess over 0.5, about
-- 1.626e-19, sits below the 2^-62 ~= 2.168e-19 ulp at this scale) -- see
-- tests/kernel_bc_sweep for the general sweep this pins one case of.
local ov_m, ov_e = fx.div(0x4000000000000001LL, 0, 0x7FFFFFFFFFFFFFFFLL, 0)
ok(not (ov_m == 0LL and ov_e == 0), "div does not collapse (2^62+1)/(2^63-1) to zero",
   ("got m=%s e=%d"):format(tostring(ov_m), ov_e))
local half_m, half_e = fx.norm(0x4000000000000000LL, -1)
ok(ov_m == half_m and ov_e == half_e, "(2^62+1)/(2^63-1) truncates to exactly 0.5",
   ("got m=%s e=%d want m=%s e=%d"):format(tostring(ov_m), ov_e, tostring(half_m), half_e))

-- sign handling across all four quadrants
local div_sign_ok = true
for _, c in ipairs({{6,3,2},{-6,3,-2},{6,-3,-2},{-6,-3,2}}) do
	local x1,x2 = fx.from_int(c[1]); local y1,y2 = fx.from_int(c[2])
	local q1,q2 = fx.div(x1,x2,y1,y2)
	local w1,w2 = fx.from_int(c[3])
	if not (q1 == w1 and q2 == w2) then div_sign_ok = false end
end
ok(div_sign_ok, "divide handles all four sign combinations")

-- CRITICAL GAP the above did not close: {6,3},{-6,3},{6,-3},{-6,-3} are all
-- EXACT integer divisions (rem == 0 in div's fractional loop every time),
-- so they never touch the sign/rounding decision at all. The kernel commits
-- to truncation TOWARD ZERO unconditionally (see the file's own top-of-file
-- doc comment) -- for an INEXACT negative quotient, that means the
-- magnitude must be floor()'d (rounding the result closer to zero, not
-- further from it) before the sign is reapplied. A mutant that instead
-- rounds the magnitude UP when inexact-and-negative silently switches to
-- floor-toward-negative-infinity (Zig's @divFloor, not @divTrunc) and nets
-- a genuinely different mantissa on real input -- and every test above,
-- including the sign-quadrant one, was blind to it (confirmed: inserting
-- that exact mutation left all four suites green before these checks
-- existed; see task-6-report.md's mutation-testing appendix). Values below
-- are cross-verified independently against bc's own exact big-integer
-- floor((|m1|*2^62)/|m2|), not just against this kernel's own output.
local neg1_m, neg1_e = fx.neg(ONEm, ONEe)
local three_m, three_e = fx.from_int(3)
local neg3_m, neg3_e = fx.neg(three_m, three_e)
local seven_m, seven_e = fx.from_int(7)
local neg7_m, neg7_e = fx.neg(seven_m, seven_e)
local eleven_m, eleven_e = fx.from_int(11)
local neg11_m, neg11_e = fx.neg(eleven_m, eleven_e)

local function check_div(m1, e1, m2, e2, want_m, want_e, label)
	local rm, re = fx.div(m1, e1, m2, e2)
	ok(rm == want_m and re == want_e, label,
	   ("got m=%s e=%d want m=%s e=%d"):format(tostring(rm), re, tostring(want_m), want_e))
end

-- -1/3: bc floor(|−1|*2^62 / |3|) = 3074457345618258602 (pre-norm); norm
-- doubles it (< 2^62) to 6148914691236517204 at e=-2. Truncating toward
-- zero means the NEGATIVE result's magnitude is <= the true magnitude
-- (closer to zero), which is exactly what a floor on the magnitude gives.
check_div(neg1_m, neg1_e, three_m, three_e, -6148914691236517204LL, -2,
	"-1 / 3 truncates toward zero (inexact, negative result)")
check_div(ONEm, ONEe, neg3_m, neg3_e, -6148914691236517204LL, -2,
	"1 / -3 gives the same magnitude as -1/3 (sign lives in the divisor instead)")
check_div(neg1_m, neg1_e, neg3_m, neg3_e, 6148914691236517204LL, -2,
	"-1 / -3 == 1/3: double negation, positive inexact result, same magnitude")

-- A second, less power-of-two-adjacent pair for broader coverage: -7/11.
-- bc floor(7*2^62/11) = 5869418568907584605, already normalized (no
-- doubling needed, e = 2-3 = -1 directly).
check_div(neg7_m, neg7_e, eleven_m, eleven_e, -5869418568907584605LL, -1,
	"-7 / 11 truncates toward zero (inexact, negative result)")
check_div(seven_m, seven_e, neg11_m, neg11_e, -5869418568907584605LL, -1,
	"7 / -11 gives the same magnitude as -7/11")
check_div(neg7_m, neg7_e, neg11_m, neg11_e, 5869418568907584605LL, -1,
	"-7 / -11 == 7/11: double negation, positive inexact result")

-- JIT miscompilation regression, split dispatch (warmed): discovered
-- while extending tests/kernel_bc_sweep.lua to cover negative operands (a
-- positive-only sweep can NEVER see this -- it only manifests through the
-- sign-handling branches). LuaJIT 2.1.1774638290's trace compiler returns
-- the WRONG mantissa for fx.div(-4735866454561506793, e,
-- -6988739120546013429, 0) once its trace has been JIT-warmed by ~500+
-- prior calls -- verified against bc's exact big-integer
-- floor((|m1|*2^62)/|m2|), and against `luajit -joff` on the identical
-- script, both of which agree on 6250148628221868064 (e adjusts by the
-- usual normalization step). Filed upstream as LuaJIT/LuaJIT#1499. This
-- is a LANGUAGE-RUNTIME bug, not a logic bug in this file.
--
-- M.div now dispatches negative operands to div_signed (which carries
-- `jit.off(div_signed)`) and positive operands to a fast path that calls
-- divmag directly, with no sign branches of its own -- see the
-- jit.off(div_signed) doc comment in lib/fixed.lua for why that split,
-- not a blanket jit.off(M.div), is what neutralizes the bug. This test
-- exercises fx.div's PUBLIC entry point (not div_signed directly), so it
-- guards the split dispatch as actually wired up, not just the
-- lower-level pieces in isolation: it warms the JIT the same way the
-- bug's discovery did (many prior varied div calls, mixing signs, routed
-- through the same M.div every real caller uses) and then checks the
-- known-bad case. 2000 warmup calls is 4x the ~500 observed to reliably
-- trigger the bug when unprotected. Verified this test fails if
-- jit.off(div_signed) is removed, and passes with it restored -- see
-- task-6-report.md's split-dispatch verification appendix for both runs.
do
	local jit_m1, jit_m2 = -4735866454561506793LL, -6988739120546013429LL
	local lcg = 0x9E3779B97F4A7C15ULL
	local TWO62_JIT = 0x4000000000000000ULL
	local function warm_mantissa()
		lcg = lcg * 6364136223846793005ULL + 1ULL
		return TWO62_JIT + ((lcg / 4ULL) % TWO62_JIT)
	end
	for i = 1, 2000 do
		local wa = ffi.cast("int64_t", warm_mantissa())
		local wb = ffi.cast("int64_t", warm_mantissa())
		if i % 2 == 0 then wa = -wa end
		if i % 3 == 0 then wb = -wb end
		fx.div(wa, i, wb, 0)
	end
	local jrm, jre = fx.div(jit_m1, 5000, jit_m2, 0)
	ok(jrm == 6250148628221868064LL and jre == 4999,
		"div's split dispatch stays correct on the known JIT-miscompilation trigger after 2000 warmup calls",
		("got m=%s e=%d want m=6250148628221868064 e=4999"):format(tostring(jrm), jre))
end

print("")
print("--- Section 4: natural log (ln) ---")

-- ln(1) == 0 exactly
local l1, l2 = fx.ln(fx.from_int(1))
ok(l1 == 0LL and l2 == 0, "ln(1) == 0 exactly")

-- ln(2) matches the stored constant exactly (same code path, same value)
local t1, t2 = fx.ln(fx.from_int(2))
ok(fx.cmp(t1, t2, fx.LN2_M, fx.LN2_E) == 0 or
   math_abs_rel(t1, t2, fx.LN2_M, fx.LN2_E) < 1e-17, "ln(2) == the ln2 constant")

-- ln is exact enough on powers of two: ln(2^k) == k * ln2
local pow_ok = true
for k = 1, 20 do
	local xm, xe = fx.norm(0x4000000000000000LL, k)   -- 2^k
	local rm, re = fx.ln(xm, xe)
	local wm, we = fx.mul(fx.LN2_M, fx.LN2_E, fx.from_int(k))
	if math_abs_rel(rm, re, wm, we) > 1e-16 then pow_ok = false end
end
ok(pow_ok, "ln(2^k) == k*ln2 for k in 1..20 (rel err < 1e-16)")

-- and negative powers of two, exercising k < 0 (from_int(k) with k negative)
local negpow_ok = true
for k = -1, -20, -1 do
	local xm, xe = fx.norm(0x4000000000000000LL, k)   -- 2^k
	local rm, re = fx.ln(xm, xe)
	local wm, we = fx.mul(fx.LN2_M, fx.LN2_E, fx.from_int(k))
	if math_abs_rel(rm, re, wm, we) > 1e-16 then negpow_ok = false end
end
ok(negpow_ok, "ln(2^k) == k*ln2 for k in -1..-20 (rel err < 1e-16)")

-- ln(0.5) == -ln2 exactly (power of two with negative k=-1; distinct from
-- the k=1 identity-multiply path exercised by ln(2) above)
local halfm, halfe = fx.norm(0x4000000000000000LL, -1)
local lh1, lh2 = fx.ln(halfm, halfe)
local negln2m, negln2e = fx.neg(fx.LN2_M, fx.LN2_E)
ok(lh1 == negln2m and lh2 == negln2e, "ln(0.5) == -ln2 exactly")

-- CRITICAL: every check above has f == 1 exactly (mantissa exactly 2^62),
-- because every input is a pure power of two. That means t = (f-1)/(f+1) is
-- exactly 0 in every single case above, so the atanh series loop -- the
-- actual transcendental computation -- multiplies and adds zeros the entire
-- time and is never really exercised. A broken ODD_RECIP index, a dropped
-- term, or a flipped sign in the series would pass every test above
-- unchanged. (Confirmed by mutation testing -- see task-6-report.md.)
--
-- These checks use genuinely non-power-of-two mantissas, verified with
-- ORACLE-FREE metamorphic properties (ln(a) + ln(1/a) == 0,
-- ln(a*b) == ln(a) + ln(b)) rather than an external bc call, so this file
-- stays fast and dependency-free; independent verification against `bc -l`
-- lives in tests/kernel_bc_sweep, the right layer for a process dependency.
-- Metamorphic alone would not catch every bug class (a series scaled by a
-- constant factor could cancel out of ln(a)+ln(1/a)), which is exactly why
-- the bc sweep exists too -- these two checks are complementary, not
-- redundant.
local ln3_m, ln3_e = fx.ln(fx.from_int(3))          -- f = 1.5, t = 0.2
-- NOTE: fx.div(fx.from_int(1), fx.from_int(3)) would be a classic Lua
-- multi-return bug -- only the LAST argument in a call fully expands, so
-- from_int(1) would silently truncate to just its mantissa, leaving div's
-- e1 argument nil. Locals sidestep it; confirmed the truncation is real
-- with a standalone probe before relying on this pattern anywhere here.
local one_m, one_e = fx.from_int(1)
local three_m, three_e = fx.from_int(3)
local oneo3_m, oneo3_e = fx.div(one_m, one_e, three_m, three_e)
local ln1o3_m, ln1o3_e = fx.ln(oneo3_m, oneo3_e)     -- f = 4/3, t = 1/7
local lnsum_m, lnsum_e = fx.add(ln3_m, ln3_e, ln1o3_m, ln1o3_e)
ok(math_abs_rel(lnsum_m, lnsum_e, 0LL, 0) < 1e-16 or lnsum_m == 0,
   "ln(3) + ln(1/3) == 0 (exercises the atanh series with a non-trivial t)",
   ("got m=%s e=%d"):format(tostring(lnsum_m), lnsum_e))
ok(ln3_m ~= 0 and ln1o3_m ~= 0,
   "ln(3) and ln(1/3) are each individually nonzero (rules out the vacuous 0+0==0 mutant)")

local ln5_m, ln5_e = fx.ln(fx.from_int(5))          -- f = 1.25, t = 1/9
local ln15_m, ln15_e = fx.ln(fx.from_int(15))       -- f = 1.875, t = 7/23
local lnprod_m, lnprod_e = fx.add(ln3_m, ln3_e, ln5_m, ln5_e)
ok(math_abs_rel(lnprod_m, lnprod_e, ln15_m, ln15_e) < 1e-16,
   "ln(3) + ln(5) == ln(15) (independent series evaluations agree via the log identity)",
   ("got sum m=%s e=%d, ln(15) m=%s e=%d"):format(
      tostring(lnprod_m), lnprod_e, tostring(ln15_m), ln15_e))

-- domain: ln(0) and ln(negative) must assert, never silently return garbage
-- or -inf. m == 0 is the canonical-zero encoding; m < 0 encodes any negative
-- value; both are excluded by the same `m > 0` guard.
local function rejects_ln(m, e, want_msg)
	local okc, err = pcall(fx.ln, m, e)
	if okc then return false, "accepted" end
	if not tostring(err):find(want_msg, 1, true) then
		return false, "wrong assert fired: " .. tostring(err)
	end
	return true
end
local lr1, lwhy1 = rejects_ln(0LL, 0, "fixed.ln: argument must be positive")
ok(lr1, "ln(0) asserts rather than returning -inf or garbage", lwhy1)
local negonem, negonee = fx.from_int(-1)
local lr2, lwhy2 = rejects_ln(negonem, negonee, "fixed.ln: argument must be positive")
ok(lr2, "ln(negative) asserts", lwhy2)

-- domain: values just below 1.0 (not to be confused with f just below 1,
-- which the normalization invariant makes impossible -- f is always in
-- [1, 2). A value just below 1.0 as a whole normalizes to f just below 2,
-- the OTHER end of the series' domain, at t just below its max of 1/3 --
-- the slowest-converging case the 12-term truncation has to cover. Checked
-- metamorphically: ln(1023/1024) + ln(1024/1023) == 0, and the result must
-- be negative (1023/1024 < 1).
local n1023m, n1023e = fx.from_int(1023)
local n1024m, n1024e = fx.from_int(1024)
local below1_m, below1_e = fx.div(n1023m, n1023e, n1024m, n1024e)
local above1_m, above1_e = fx.div(n1024m, n1024e, n1023m, n1023e)
local lnbelow_m, lnbelow_e = fx.ln(below1_m, below1_e)
local lnabove_m, lnabove_e = fx.ln(above1_m, above1_e)
local belowsum_m, belowsum_e = fx.add(lnbelow_m, lnbelow_e, lnabove_m, lnabove_e)
ok(lnbelow_m < 0, "ln(1023/1024) is negative (value just below 1.0)",
   ("got m=%s e=%d"):format(tostring(lnbelow_m), lnbelow_e))
ok(math_abs_rel(belowsum_m, belowsum_e, 0LL, 0) < 1e-16 or belowsum_m == 0,
   "ln(1023/1024) + ln(1024/1023) == 0",
   ("got m=%s e=%d"):format(tostring(belowsum_m), belowsum_e))

print("")
print("============================================")
if fails > 0 then
	io.stderr:write(("fixed test FAILED: %d of %d checks failed\n"):format(fails, checks))
	os.exit(fails)
end
print(("fixed test PASSED: All %d checks passed"):format(checks))
