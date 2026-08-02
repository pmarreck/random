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
-- Each section below is wrapped in its own `do ... end` block purely to
-- scope its locals out of existence once the section finishes. LuaJIT caps
-- a single function (the whole chunk counts as one) at 200 simultaneously
-- ACTIVE locals; this file's checks are deliberately verbose (many small,
-- readable named locals per assertion, matching the rest of the project's
-- style), and by Section 5 the unscoped total exceeded that cap --
-- "main function has more than 200 local variables" is a real compile
-- error, hit while adding this task's exp tests, not a hypothetical. No
-- section references another section's locals (verified by grep before
-- this change), so the wrap is a pure scoping fix with zero behavior
-- change -- ok()/fails/checks are upvalues captured by closure, unaffected.
do

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

-- M.norm's i32 exponent contract (docs/specs/2026-07-31-deterministic-
-- fixed-point-rng-design.md:121 fixes `e` as i32; see M.norm's own doc
-- comment for the full derivation and the reproduced ULP-loss hazard
-- this closes). pcall + exact-message match, same established style as
-- M.ln/M.sqrt/M.pow's own domain asserts elsewhere in this file, plus
-- boundary pinning (exactly at the i32 edges must NOT raise) so a
-- >= vs > or a wrong-sign mutant on the bound is actually caught, not
-- just "does it ever raise at all".
local function rejects_norm(m, e, want_msg)
	local okc, err = pcall(fx.norm, m, e)
	if okc then return false, "accepted" end
	if not tostring(err):find(want_msg, 1, true) then
		return false, "wrong assert fired: " .. tostring(err)
	end
	return true
end
local norm_r1, norm_why1 = rejects_norm(0x4000000000000000LL, 2147483648, "fixed.norm: exponent outside i32")
ok(norm_r1, "norm: exponent one past the i32 max (2147483648) asserts", norm_why1)
local norm_r2, norm_why2 = rejects_norm(0x4000000000000000LL, -2147483649, "fixed.norm: exponent outside i32")
ok(norm_r2, "norm: exponent one past the i32 min (-2147483649) asserts", norm_why2)
local norm_ok3 = pcall(fx.norm, 0x4000000000000000LL, 2147483647)
ok(norm_ok3, "norm: exponent AT the i32 max (2147483647) does not raise (boundary, not off-by-one)")
local norm_ok4 = pcall(fx.norm, 0x4000000000000000LL, -2147483648)
ok(norm_ok4, "norm: exponent AT the i32 min (-2147483648) does not raise (boundary, not off-by-one)")

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

-- M.mul's i32 exponent contract. Unlike M.norm's assert (which every
-- OTHER caller routes through), M.mul computes e = e1+e2[+1] directly --
-- the coordinator found this REACHABLE from entirely in-contract
-- operands, not hypothetical: mul(e1=2000000000, e2=2000000000) ->
-- e=4000000000, and M.norm accepts each 2000000000 individually. Same
-- pcall + exact-message style as the M.norm tests above, plus boundary
-- pins so a >= vs > or off-by-one on the NEW check itself would be
-- caught, not just "does it ever raise".
local function rejects_mul(m1, e1, m2, e2, want_msg)
	local okc, err = pcall(fx.mul, m1, e1, m2, e2)
	if okc then return false, "accepted" end
	if not tostring(err):find(want_msg, 1, true) then
		return false, "wrong assert fired: " .. tostring(err)
	end
	return true
end
local mul_r1, mul_why1 = rejects_mul(0x4000000000000000LL, 2000000000, 0x4000000000000000LL, 2000000000,
   "fixed.mul: exponent outside i32")
ok(mul_r1, "mul: two in-contract exponents (2000000000 each) whose sum overflows i32 asserts", mul_why1)
-- Exact boundary: e1+e2 landing precisely on 2147483647 must NOT raise.
-- 0x4000000000000000LL * 0x4000000000000000LL lands in the "product
-- >= 2^125, shift down 63, e1+e2+1" branch (mantissa 2^62 squared is
-- exactly 2^124, which is < 2^125 -- use a mantissa just above 2^62 so
-- the product's top bit is actually set and the +1 branch is the one
-- under test, matching what a real boundary call would hit).
local mul_ok_boundary = pcall(fx.mul, 0x7FFFFFFFFFFFFFFFLL, 1073741823, 0x7FFFFFFFFFFFFFFFLL, 1073741823)
ok(mul_ok_boundary, "mul: exponents landing exactly at the i32 max (2147483647) do not raise")
local mul_r2, mul_why2 = rejects_mul(0x4000000000000000LL, -2000000000, 0x4000000000000000LL, -2000000000,
   "fixed.mul: exponent outside i32")
ok(mul_r2, "mul: two in-contract exponents (-2000000000 each) whose sum underflows past i32 min", mul_why2)

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

end

print("")
print("--- Section 2: addition, subtraction, comparison ---")
do

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

end

print("")
print("--- Section 3: divide ---")
do

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

-- div's i32 exponent contract: CHECKED rather than assumed to need a new
-- assert, per instruction ("check rather than assume, and say what you
-- found either way"). Unlike M.mul, BOTH of div's dispatch paths (the
-- fast positive-only path and div_signed) already call
-- `M.norm(result, e1 - e2)` directly -- confirmed by reading, then
-- confirmed by execution below -- so M.norm's own i32 assert already
-- covers div's exponent difference on both paths; no new code was
-- needed here, and none was added (this pins that finding as a
-- regression test, not a change in behavior). Exercises BOTH dispatch
-- paths with two in-contract exponents (M.norm accepts each alone)
-- whose DIFFERENCE underflows past i32's min.
local dr4, dwhy4 = rejects_div(ONEm, -2000000000, ONEm, 2000000000, "fixed.norm: exponent outside i32")
ok(dr4, "div (fast positive path): e1-e2 underflowing past i32 min asserts " ..
   "(already covered by M.norm, not new code)", dwhy4)
local negONEm = fx.neg(ONEm, ONEe)
local dr5, dwhy5 = rejects_div(negONEm, -2000000000, ONEm, 2000000000, "fixed.norm: exponent outside i32")
ok(dr5, "div (div_signed path, negative operand): same e1-e2 underflow asserts " ..
   "(already covered by M.norm, not new code)", dwhy5)

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

-- JIT miscompilation mitigation, split dispatch: LuaJIT 2.1.1774638290's
-- trace compiler miscompiles the combination of a conditional
-- unsigned-negation branch followed by a loop, once warmed. Filed
-- upstream as LuaJIT/LuaJIT#1499. M.div's fix is structural: div_signed
-- (the sign-handling cold path) carries jit.off(div_signed) and never
-- shares a prototype with divmag (the loop), which stays JIT-eligible.
-- See lib/fixed.lua's jit.off(div_signed) doc comment for the full
-- derivation.
--
-- Shared warmup helper for both checks below: mixed-sign div calls,
-- mimicking the pattern the bug was discovered under.
local function jit_warmup_div(n)
	local lcg = 0x9E3779B97F4A7C15ULL
	local TWO62_JIT = 0x4000000000000000ULL
	local function warm_mantissa()
		lcg = lcg * 6364136223846793005ULL + 1ULL
		return TWO62_JIT + ((lcg / 4ULL) % TWO62_JIT)
	end
	for i = 1, n do
		local wa = ffi.cast("int64_t", warm_mantissa())
		local wb = ffi.cast("int64_t", warm_mantissa())
		if i % 2 == 0 then wa = -wa end
		if i % 3 == 0 then wb = -wb end
		fx.div(wa, i, wb, 0)
	end
end

-- PRIMARY, deterministic control: assert the property jit.off(div_signed)
-- actually establishes -- that div_signed is never trace-compiled -- via
-- jit.attach, rather than trying to observe the miscomputed VALUE that
-- results when it is. An earlier version of this test asserted the value
-- directly (fx.div(known bad operands) after warmup should equal the
-- known-correct mantissa). That was NOT reliable: 15 runs of the
-- unmodified suite with jit.off(div_signed) removed caught the regression
-- only 5 of 15 times (a coin flip in the direction that matters), because
-- LuaJIT trace formation is not deterministic and not monotonic in
-- warmup call count -- 20000 warmup calls was measured to sometimes MISS
-- the bug even though 2000 sometimes caught it. A control that fires one
-- time in three is worse than no control: it reads as green. This
-- structural check was independently verified to be fully deterministic
-- in both directions (10/10 correct with the mitigation present, 10/10
-- correct with it removed) before being committed -- see
-- task-6-report.md's deterministic-control verification appendix.
do
	local jutil = require("jit.util")
	local target_info = jutil.funcinfo(fx._div_signed_for_tests)
	local target_line = target_info.linedefined
	local traced = false
	local function cb(what, tr, func, pc)
		if what == "start" and func then
			local okc, finfo = pcall(jutil.funcinfo, func, pc)
			if okc and finfo and finfo.linedefined == target_line then traced = true end
		end
	end
	jit.attach(cb, "trace")
	jit_warmup_div(2000)
	jit.attach(cb)   -- detach (jit.attach with no event removes this callback)
	ok(not traced,
		"div_signed is never trace-compiled (the JIT mitigation for LuaJIT/LuaJIT#1499 is in effect)")
end

-- SECONDARY, PROBABILISTIC check -- kept as an additional, real-world
-- symptom-level sanity check, but it is NOT a control by itself and must
-- never be trusted as one: per the measurement above, it detects the
-- mitigation being removed only ~1 run in 3. If this check alone is ever
-- green, that is NOT evidence the mitigation is working -- only the
-- jit.attach check above is deterministic. Retained because when it DOES
-- fire, it confirms the structural check maps to the real symptom, not
-- just to trace-compilation bookkeeping.
do
	local jit_m1, jit_m2 = -4735866454561506793LL, -6988739120546013429LL
	jit_warmup_div(2000)
	local jrm, jre = fx.div(jit_m1, 5000, jit_m2, 0)
	ok(jrm == 6250148628221868064LL and jre == 4999,
		"div's split dispatch stays correct on the known JIT-miscompilation trigger after 2000 warmup calls (probabilistic, not a control -- see the jit.attach check above)",
		("got m=%s e=%d want m=6250148628221868064 e=4999"):format(tostring(jrm), jre))
end

-- The SAME LuaJIT/LuaJIT#1499 bug as div_signed above, confirmed to reach
-- M.norm through a different code path -- NOT a second, distinct defect.
-- Found during Task 12 (bin/random integration): neither this suite nor
-- kernel_bc_sweep.lua's own call patterns (built across Tasks 1-11,
-- before bin/random had a real caller) ever warmed up a trace through
-- this exact shape.
--
-- CONFIRMED BY DIRECT REPRODUCTION, not inferred from the shape alone:
-- `bin/random --exponential -d --seed 11111 -c 5` crashed with "fixed.ln:
-- argument must be positive" on the 4th draw, on the pinned build
-- (2.1.1774638290). Instrumenting pcg32_uniform showed
-- M.from_int(3830421010) -- a POSITIVE input -- returning
-- (-9223372034939565303LL, 63), a corrupted NEGATIVE mantissa, under the
-- normal JIT; the same call under `luajit -joff` correctly returned
-- (8225766483930644480LL, 31). CONFIRMED to be the identical upstream
-- bug, not a new one: the same invocation against Mike Pall's actual
-- #1499 fix (commit 5ed524c, built as 2.1.1785606157) completes cleanly
-- with correct output (5/5 runs), and a broader differential (every
-- bin/random distribution, 12 seeds, JIT-on vs -joff, mitigation
-- removed) found zero divergence on that build. See lib/fixed.lua's
-- jit.off(M.norm) doc comment and task-12-report.md for the full
-- transcript, the fixed-build verification, and the measured
-- interpreted-vs-compiled cost this mitigation pays until every build
-- this project ships against carries that upstream fix.
--
-- Same PRIMARY (deterministic, jit.attach-based) structure as the
-- div_signed check above -- see that check's own comment for why a
-- value-based check alone is not trustworthy (LuaJIT trace formation is
-- not deterministic in warmup call count).
local function jit_warmup_norm(n)
	local lcg = 0xD1B54A32D192ED03ULL
	local TWO62_JIT = 0x4000000000000000ULL
	local function warm_mantissa()
		lcg = lcg * 6364136223846793005ULL + 1ULL
		return (lcg / 4ULL) % TWO62_JIT + 1ULL   -- sub-2^62: exercises norm's own shift-up loop
	end
	for i = 1, n do
		local wm = ffi.cast("int64_t", warm_mantissa())
		if i % 2 == 0 then wm = -wm end
		fx.norm(wm, i % 40 - 20)
	end
end

do
	local jutil = require("jit.util")
	local target_info = jutil.funcinfo(fx.norm)
	local target_line = target_info.linedefined
	local traced = false
	local function cb(what, tr, func, pc)
		if what == "start" and func then
			local okc, finfo = pcall(jutil.funcinfo, func, pc)
			if okc and finfo and finfo.linedefined == target_line then traced = true end
		end
	end
	jit.attach(cb, "trace")
	jit_warmup_norm(2000)
	jit.attach(cb)   -- detach (jit.attach with no event removes this callback)
	ok(not traced,
		"M.norm is never trace-compiled (the JIT mitigation for the M.norm instance of LuaJIT/LuaJIT#1499 is in effect)")
end

end

print("")
print("--- Section 4: natural log (ln) ---")
do

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

end

print("")
print("--- Section 5: exp ---")
-- NOTE: the brief this task was built from labeled this "Section 4" --
-- stale, since ln (landed in Task 6, after the brief was written) already
-- occupies that slot above. Renumbered for a monotonic file.
do

-- exp(0) == 1 exactly. m == 0 takes M.exp's early-return short circuit, so
-- this ALONE never touches range reduction or the Taylor series -- the same
-- blind spot the ln section's own "CRITICAL" comment warns about for
-- power-of-two inputs. Kept as the base case; the round-trip and
-- metamorphic checks below are what actually exercise the series.
local e1m, e1e = fx.exp(0LL, 0)
ok(fx.cmp(e1m, e1e, fx.from_int(1)) == 0, "exp(0) == 1 exactly")

-- exp(ln(x)) == x round-trip over a sampled set. Every ln(x) here is
-- POSITIVE (all v > 1), so on its own this only exercises exp with a
-- non-negative argument -- see the negative-argument coverage below, the
-- path M.div actually dispatches to div_signed (the JIT-mitigated cold
-- path div's own tests exercise, but exp's tests did not until now).
local rt_ok, rt_worst = true, 0
for _, v in ipairs({2, 3, 5, 10, 100, 1000}) do
	local xm, xe = fx.from_int(v)
	local lm, le = fx.ln(xm, xe)
	local rm, re = fx.exp(lm, le)
	local err = math_abs_rel(rm, re, xm, xe)
	if err > rt_worst then rt_worst = err end
	if err > 1e-15 then rt_ok = false end
end
ok(rt_ok, "exp(ln(x)) == x for sampled x (rel err < 1e-15)", ("worst=%.3e"):format(rt_worst))
-- Printed unconditionally (not just on failure, which is all `ok`'s own
-- detail message gives you) -- matching kernel_bc_sweep's own convention
-- of always surfacing its worst-case metric so a maintainer can see the
-- actual measured number without forcing a failure first.
print(("  worst exp(ln(x)) == x relative error: %.3e"):format(rt_worst))

-- exp of a large positive argument must not overflow: the 2^k factor has to
-- stay in the exponent field, never get folded into the (fixed-width)
-- mantissa. exp(50) ~ 5.18e21 -- if the range-reduction "return acc, e + k"
-- step were dropped (returning exp(r) alone, k discarded), this exponent
-- would stay near 0 instead of far exceeding 62. See "drop the 2^k
-- exponent adjustment" in task-7-report.md's mutation results.
local bm, be = fx.exp(fx.from_int(50))
ok(be > 62, "exp(50) uses the exponent rather than overflowing", ("e=%d"):format(be))

-- exp of a large NEGATIVE argument must not underflow to canonical zero,
-- mirroring the overflow check above. This is also the first check in this
-- section to feed M.exp's range reduction a NEGATIVE mantissa end to end:
-- x = -50 makes the internal M.div(x, ln2, ...) dispatch through
-- div_signed (the jit.off'd cold path) rather than the fast positive-only
-- path -- exactly the scenario this task's brief warned would be exercised
-- "heavily" by real callers (exponential and Poisson both compute -ln(u)).
local nbm, nbe = fx.exp(fx.neg(fx.from_int(50)))
ok(nbm ~= 0 and nbe < -62, "exp(-50) uses the exponent rather than underflowing to zero",
   ("m=%s e=%d"):format(tostring(nbm), nbe))

-- Metamorphic, oracle-free: exp(x) * exp(-x) == 1 for a genuinely
-- fractional, non-power-of-two x (37/10 = 3.7), independently exercising
-- BOTH of M.div's dispatch paths against each other (positive x through
-- the fast path, -x through div_signed) via a property that must hold
-- regardless of which internal path computed which factor.
local n37m, n37e = fx.from_int(37)
local n10m, n10e = fx.from_int(10)
local x37m, x37e = fx.div(n37m, n37e, n10m, n10e)            -- x = 3.7
local negx37m, negx37e = fx.neg(x37m, x37e)
local pexpm, pexpe = fx.exp(x37m, x37e)
local nexpm, nexpe = fx.exp(negx37m, negx37e)
local prodm, prode = fx.mul(pexpm, pexpe, nexpm, nexpe)
ok(math_abs_rel(prodm, prode, fx.from_int(1)) < 1e-15,
   "exp(3.7) * exp(-3.7) == 1 (metamorphic; exercises both div dispatch paths)",
   ("got m=%s e=%d"):format(tostring(prodm), prode))
-- Rules out the vacuous mutant where a broken exp always returns 1: if it
-- did, the product-== -1 property above would pass for the wrong reason.
ok(fx.cmp(pexpm, pexpe, fx.from_int(1)) ~= 0 and fx.cmp(nexpm, nexpe, fx.from_int(1)) ~= 0,
   "exp(3.7) and exp(-3.7) are each individually != 1 (rules out an always-return-1 mutant)")

-- DOMAIN GUARD: exp must raise a clean, immediate error rather than hang
-- for arguments large enough that the correction loop cannot converge --
-- see correction_guard's doc comment in lib/fixed.lua for the full
-- derivation (k is a plain Lua double, and once its magnitude exceeds
-- 2^53 or so, `k +/- 1` inside the loop can become a silent no-op).
-- Fixed post-review, once the coordinator caught (and confirmed by
-- execution) that the committed exp hung for x = 2^61/2^62/2^70 -- the
-- termination proof above the round-trip check only holds while
-- to_int_trunc actually truncates, not once it starts clamping. See
-- task-7-report.md's fix-up appendix.
local function rejects_exp(m, e, want_msg)
	local okc, err = pcall(fx.exp, m, e)
	if okc then return false, "accepted (returned instead of raising)" end
	if not tostring(err):find(want_msg, 1, true) then
		return false, "wrong error fired: " .. tostring(err)
	end
	return true
end

-- 2^62 is constructed directly (mantissa 2^62, exponent 62) rather than
-- via fx.from_int, which only accepts |v| < 2^53 by its own doc comment.
-- This is where to_int_trunc's own explicit clamp branch guarantees
-- non-convergence -- the case the coordinator's review measured directly.
local pow62_m, pow62_e = 0x4000000000000000LL, 62
local r62_ok, r62_why = rejects_exp(pow62_m, pow62_e, "exceeded the bound")
ok(r62_ok, "exp(2^62) raises naming the correction-loop failure, rather than hanging", r62_why)

-- Pin the EXACT attempt count the guard fires at (#4 = EXP_MAX_CORRECTIONS
-- + 1), not just that it fires at all. This is the second, cheaper half of
-- pinning the > vs >= boundary: correction_guard's own doc comment
-- promises it never fires before attempt #4 under the correct `count >
-- EXP_MAX_CORRECTIONS` semantics; a `>=` mutant would fire at #3 instead,
-- and this assertion on the real M.exp's error message (not just the
-- isolated guard call below) catches that the count variable threaded
-- through M.exp's own loop is the one actually reaching correction_guard.
local _, pow62_err = pcall(fx.exp, pow62_m, pow62_e)
ok(tostring(pow62_err):find("#4", 1, true) ~= nil,
   "exp(2^62)'s error reports the actual failing attempt number (#4), pinning > vs >= directly",
   tostring(pow62_err))

-- A SECOND, lower-magnitude case: 2^62 is where to_int_trunc's own clamp
-- branch guarantees non-convergence (verified deterministic above, and
-- re-confirmed over 30 fresh-process runs before this comment was
-- written: 30/30 raised with the correction-guard's own message).
--
-- x = 2^55 is a DIFFERENT boundary, and its history is worth recording
-- precisely because it changed twice in this same task:
--
-- 1. ORIGINALLY (this file's very first version of this check): asserted
--    "it raises" via correction_guard, unconditionally. That is a coin
--    flip in this magnitude's GRADIENT region -- whether the correction
--    loop exceeds EXP_MAX_CORRECTIONS there depends on JIT trace
--    formation, not the mathematics (task 8: ~8% raise at e=52 up to
--    ~72% at e=55). Measured flaking 8 of 30 `./test fixed` runs (27%)
--    once this task's own code growth shifted JIT timing enough to
--    change the odds.
-- 2. REPLACED WITH an invariant check ("never returns a WRONG value:
--    either raises correctly, or agrees with an independent oracle"),
--    since that is the property that actually has to hold regardless of
--    which way the JIT-timing coin lands. The oracle was built entirely
--    in bc's exact arithmetic (the same k*ln2 + r decomposition M.exp
--    itself uses; computing exp(2^55) directly in bc is infeasible, the
--    true value has ~1.6e16 decimal digits, so the oracle uses the
--    small, well-conditioned remainder instead). Finding this oracle
--    ALSO surfaced a second, unrelated hazard: M.sub's own M.norm
--    renormalization silently corrupts its exponent once that exponent
--    itself exceeds ~2^53 -- the SAME disease this whole test is about,
--    hit a second time inside the verification itself. That finding is
--    now what M.norm's own doc comment documents and asserts against.
-- 3. Enforcing the i32 exponent contract (docs/specs/2026-07-31-
--    deterministic-fixed-point-rng-design.md:121, via M.norm's new
--    assert and M.exp's return now routing through it) makes the
--    "succeeds" branch of step 2's check STRUCTURALLY UNREACHABLE for
--    this input: the correction loop's own convergence behavior is
--    UNCHANGED by this (still whatever JIT-timing-dependent thing it
--    always was), but k ~= 5.2e16 for x = 2^55 regardless of how the
--    loop gets there, and the RETURNED exponent is approximately k --
--    six orders of magnitude past the i32 ceiling (2147483647) no matter
--    what. So this input NOW ALWAYS raises, via ONE of two independent
--    checks depending on which the JIT-timing coin flip reaches first:
--    correction_guard mid-loop (if convergence needs more corrections
--    than the bound allows -- unusual, but not impossible for this
--    input) or M.norm's i32 assert at the return (if the loop converges
--    fine, which task 10's own 200-run isolated probe found to be the
--    common case). Confirmed directly, embedded in the real suite where
--    the JIT-timing sensitivity actually lives (not just in isolation):
--    both messages were observed across repeated `luajit
--    tests/fixed_test.lua` runs. The oracle-comparison machinery from
--    step 2 is no longer reachable through this specific input and was
--    removed rather than left as dead code; the derivation is preserved
--    here in prose since it is what caught the M.norm hazard.
local EXP55_M, EXP55_E = 0x4000000000000000LL, 55
local exp55_okc, exp55_err = pcall(fx.exp, EXP55_M, EXP55_E)
local exp55_ok, exp55_why
if exp55_okc then
	exp55_ok, exp55_why = false, "succeeded -- should be unreachable under the i32 contract"
else
	local msg = tostring(exp55_err)
	if msg:find("exceeded the bound", 1, true) or msg:find("exponent outside i32", 1, true) then
		exp55_ok = true
	else
		exp55_ok, exp55_why = false, "raised the WRONG error: " .. msg
	end
end
ok(exp55_ok, "exp(2^55) always raises, via correction_guard or the i32 exponent contract " ..
   "(never silently returns a wrong value)", exp55_why)

-- EXP_MAX_CORRECTIONS' exact boundary, pinned DIRECTLY against
-- correction_guard itself (TEST-ONLY hook, matching
-- fx._div_signed_for_tests' established pattern) rather than via a
-- naturally-occurring M.exp input. That was tried first and does not
-- work: an exhaustive search (600,000+ trials across e in [45, 58], plus
-- neighborhood probing -- see task-7-report.md) found the natural
-- maximum is 2 corrections, never 3, so no real M.exp call can
-- distinguish `count > 3` (correct) from a `count >= 3` off-by-one
-- mutant -- both behave identically on every input that actually occurs.
-- This is a real, previously-missing gap: changing `>` to `>=` survived
-- the entire suite before this check existed (confirmed by the
-- coordinator's review, and reproduced independently below in the
-- mutation-testing section).
local guard_ok3 = pcall(fx._correction_guard_for_tests, 3, 0)
ok(guard_ok3, "correction_guard(3, _) does not raise -- 3 corrections is within EXP_MAX_CORRECTIONS")
local guard_ok4 = pcall(fx._correction_guard_for_tests, 4, 0)
ok(not guard_ok4, "correction_guard(4, _) raises -- 4 corrections exceeds EXP_MAX_CORRECTIONS " ..
   "(this pair is what actually kills a > -> >= off-by-one mutant; see task-7-report.md)")

-- HISTORICAL NOTE, no longer a live "succeeds" check (see below for why):
-- (6978193117490312577LL, 50) -- x ~= 1.7e15 -- was found by search (not
-- analytically constructed -- the idealized "at most 1" proof in M.exp's
-- own doc comment does not by itself predict this) as a REAL M.exp input
-- needing exactly 2 corrections, M.div's own tiny compounding rounding
-- error at this magnitude being what pushes it to 2. That demonstrated
-- EXP_MAX_CORRECTIONS = 3 has real (not just nominal) headroom above the
-- naturally-occurring maximum.
--
-- Superseded by M.norm's i32-exponent assert (added at the coordinator's
-- direction once the reference/spec mismatch was found): this input's
-- correction loop still converges in exactly 2 steps, same as always,
-- but its RESULT exponent is k ~= 2.46e15 -- x/ln2 for x ~= 1.7e15 --
-- five orders of magnitude past the i32 ceiling (2147483647), so it is
-- now correctly REJECTED at the return, not accepted.
--
-- This is not a coincidence of this one input -- it is STRUCTURAL, and
-- was checked directly before writing this comment: 25,500 sampled
-- cases spanning e in [1, 51] (comfortably covering the entire i32-safe
-- output range, e up to ~31, plus a wide margin past it) never needed
-- more than 1 correction; every naturally-occurring 2-correction input
-- found in the original 600,000+-trial search (task-7-report.md) sits in
-- e in [45, 58] specifically BECAUSE that is where k's own double
-- precision degrades (k > ~2^53) -- and any x large enough for that is,
-- by the exact same magnitude relationship, large enough that k (the
-- returned exponent) is already ~2^22 past i32's own ~2^31 ceiling. The
-- "needs 2 corrections" case and "result fits in i32" case cannot
-- co-occur: enforcing the exponent contract makes EXP_MAX_CORRECTIONS'
-- 2-corrections headroom permanently unreachable through any in-contract
-- M.exp call, not merely untested. correction_guard's own `>` vs `>=`
-- boundary remains pinned directly above (guard_ok3/guard_ok4), which
-- covers the property that actually still matters going forward.
local corr2_m, corr2_e = 6978193117490312577LL, 50
local corr2_okc, corr2_err = pcall(fx.exp, corr2_m, corr2_e)
local corr2_ok = (not corr2_okc) and tostring(corr2_err):find("fixed.norm: exponent outside i32", 1, true) ~= nil
ok(corr2_ok, "the former 2-corrections input is now rejected via the i32 exponent contract, " ..
   "not silently accepted with an out-of-contract exponent",
   tostring(corr2_err))

end

print("")
print("--- Section 6: cos (in turns) ---")
-- NOTE: the brief this task was built from labeled this "Section 5" --
-- stale, since exp (landed in Task 7) already occupies that slot above.
-- Renumbered for a monotonic file, same fix Section 5's own header applied
-- for the section before it.
do

local function turns(num, den)   -- num/den as a soft-float
	local nm, ne = fx.from_int(num)
	local dm, de = fx.from_int(den)
	return fx.div(nm, ne, dm, de)
end

-- u = k / 2^32, the REAL domain this function is fed by the RNG (u2 in
-- Box-Muller is exactly a uint32 draw divided by 2^32). 4294967296 fits
-- exactly in a Lua double (well under 2^53), so from_int(k) and
-- from_int(4294967296) are both exact.
local U32_DEN = 4294967296
local function turns32(k)
	local nm, ne = fx.from_int(k)
	local dm, de = fx.from_int(U32_DEN)
	return fx.div(nm, ne, dm, de)
end

-- exact quarter-turn values
local c0m, c0e = fx.cos_turns(0LL, 0)
ok(fx.cmp(c0m, c0e, fx.from_int(1)) == 0, "cos(0 turns) == 1")

local c2m, c2e = fx.cos_turns(turns(1, 2))
ok(math_abs_rel(c2m, c2e, fx.from_int(-1)) < 1e-16, "cos(1/2 turn) == -1")

local c4m, c4e = fx.cos_turns(turns(1, 4))
ok(math_abs_rel(c4m, c4e, fx.from_int(0)) < 1e-15, "cos(1/4 turn) == 0")

local c34m, c34e = fx.cos_turns(turns(3, 4))
ok(math_abs_rel(c34m, c34e, fx.from_int(0)) < 1e-15, "cos(3/4 turn) == 0")

-- result stays within [-1, 1] across a full turn
local bound_ok = true
for i = 0, 199 do
	local rm, re = fx.cos_turns(turns(i, 200))
	if fx.cmp(rm, re, fx.from_int(1)) > 0 or fx.cmp(rm, re, fx.from_int(-1)) < 0 then
		bound_ok = false
	end
end
ok(bound_ok, "cos stays within [-1,1] across 200 points of a full turn")

-- symmetry: cos(u) == cos(1-u)
local sym_ok, sym_worst = true, 0
for i = 1, 99 do
	local am, ae = fx.cos_turns(turns(i, 200))
	local bm, be = fx.cos_turns(turns(200 - i, 200))
	local err = math_abs_rel(am, ae, bm, be)
	if err > sym_worst then sym_worst = err end
	if err > 1e-15 then sym_ok = false end
end
ok(sym_ok, "cos(u) == cos(1-u) across the turn", ("worst=%.3e"):format(sym_worst))

-- === Quadrant-boundary tests (verification item 2 from the task brief) ===
-- "Exact boundaries and just either side of each, where an off-by-one in
-- the quadrant selection shows up as a sign flip." Using u = k/2^32 (the
-- real RNG-fed domain) rather than the arbitrary denominators above --
-- k = 2^30 lands EXACTLY on 1/4 turn (2^30/2^32 = 1/4), and division by a
-- power of two is exact in this binary representation regardless of the
-- numerator, so these are not approximations of the boundary, they ARE
-- the boundary (and its immediate integer-adjacent neighbors) bit-exactly.
--
-- 1/4 turn: cos crosses zero going NEGATIVE as u increases through 1/4
-- (derivative -2*pi*sin(pi/2) = -2*pi < 0). An off-by-one that used the
-- q==0 (cos) formula one step too late, or the q==1 (-sin) formula one
-- step too early, flips this sign.
local just_below_q4m, just_below_q4e = fx.cos_turns(turns32(1073741823))  -- (2^30 - 1)/2^32
local exact_q4m, exact_q4e           = fx.cos_turns(turns32(1073741824))  -- 2^30 / 2^32 == 1/4 exactly
local just_above_q4m, just_above_q4e = fx.cos_turns(turns32(1073741825)) -- (2^30 + 1)/2^32
ok(just_below_q4m > 0, "cos just below 1/4 turn is still positive (pre-boundary quadrant)",
   ("m=%s e=%d"):format(tostring(just_below_q4m), just_below_q4e))
ok(fx.cmp(exact_q4m, exact_q4e, fx.from_int(0)) == 0 or math_abs_rel(exact_q4m, exact_q4e, fx.from_int(0)) < 1e-15,
   "cos at exactly 1/4 turn is 0 (within-quadrant angle reduces to exactly 0)")
ok(just_above_q4m < 0, "cos just above 1/4 turn is negative (post-boundary quadrant, sign flip caught)",
   ("m=%s e=%d"):format(tostring(just_above_q4m), just_above_q4e))

-- 3/4 turn: cos crosses zero going POSITIVE as u increases through 3/4
-- (derivative -2*pi*sin(3*pi/2) = -2*pi*(-1) = +2*pi > 0) -- the opposite
-- sign transition from 1/4 turn, so a quadrant-branch swap that happens to
-- get 1/4 turn right by accident (e.g. swapping BOTH q==1 and q==3) is
-- still caught here.
local just_below_q34m = fx.cos_turns(turns32(3221225471))   -- (3*2^30 - 1)/2^32
local exact_q34m, exact_q34e = fx.cos_turns(turns32(3221225472))  -- 3*2^30 / 2^32 == 3/4 exactly
local just_above_q34m = fx.cos_turns(turns32(3221225473))   -- (3*2^30 + 1)/2^32
ok(just_below_q34m < 0, "cos just below 3/4 turn is still negative (pre-boundary quadrant)",
   ("m=%s"):format(tostring(just_below_q34m)))
ok(fx.cmp(exact_q34m, exact_q34e, fx.from_int(0)) == 0 or math_abs_rel(exact_q34m, exact_q34e, fx.from_int(0)) < 1e-15,
   "cos at exactly 3/4 turn is 0")
ok(just_above_q34m > 0, "cos just above 3/4 turn is positive (post-boundary quadrant, sign flip caught)",
   ("m=%s"):format(tostring(just_above_q34m)))

-- 0 and 1/2 turn are extrema (+1, -1), not zero crossings -- a quadrant mixup
-- here shows up as a VALUE excursion away from the extremum rather than a
-- sign flip, so check magnitude stays pinned near +-1 on both sides instead.
local near0_lo_m, near0_lo_e = fx.cos_turns(turns32(1))            -- 1/2^32, just above 0
local near0_hi_m, near0_hi_e = fx.cos_turns(turns32(4294967295))   -- (2^32-1)/2^32, just below 1 (wraps toward 0)
ok(math_abs_rel(near0_lo_m, near0_lo_e, fx.from_int(1)) < 1e-15, "cos just above 0 turns stays pinned near +1")
ok(math_abs_rel(near0_hi_m, near0_hi_e, fx.from_int(1)) < 1e-15, "cos just below 1 turn (wraps) stays pinned near +1")

local just_below_half_m, just_below_half_e = fx.cos_turns(turns32(2147483647)) -- (2^31-1)/2^32, just below 1/2
local exact_half_m, exact_half_e = fx.cos_turns(turns32(2147483648))           -- 2^31/2^32 == 1/2 exactly
local just_above_half_m, just_above_half_e = fx.cos_turns(turns32(2147483649)) -- (2^31+1)/2^32, just above 1/2
ok(math_abs_rel(just_below_half_m, just_below_half_e, fx.from_int(-1)) < 1e-15, "cos just below 1/2 turn stays pinned near -1")
ok(math_abs_rel(exact_half_m, exact_half_e, fx.from_int(-1)) < 1e-16, "cos at exactly 1/2 turn is -1")
ok(math_abs_rel(just_above_half_m, just_above_half_e, fx.from_int(-1)) < 1e-15, "cos just above 1/2 turn stays pinned near -1")

end

print("")
print("--- Section 7: sqrt and pow ---")
do

-- True fixed-point relative error: computed ENTIRELY in this kernel's own
-- 62-bit arithmetic (fx.sub then fx.div), converting to a Lua double only
-- on the resulting ALREADY-TINY residual. math_abs_rel above converts
-- each operand independently through a double FIRST, which introduces
-- ~2^-53 relative rounding PER CONVERSION -- too coarse to validate this
-- kernel's ~2^-62 precision claim (it cannot tell a true ~6e-19 error from
-- a ~1e-16 one; both round to "0" once each operand is independently cast
-- through tonumber()). See lib/fixed.lua's M.sqrt doc comment for the
-- full derivation of why this distinction matters for sqrt specifically
-- (a single raw-integer Newton stage, with no soft-float refinement, only
-- reaches ~31 bits of precision -- a ~1e-9-scale error that a
-- double-precision check alone cannot distinguish from full 62-bit
-- precision at this file's own tolerances).
local function true_fixed_relerr(m1, e1, m2, e2)
	if m2 == 0 then
		if m1 == 0 then return 0.0 end
		return math.huge
	end
	local dm, de = fx.sub(m1, e1, m2, e2)
	if dm == 0 then return 0.0 end
	local rm, re = fx.div(dm, de, m2, e2)
	return math.abs(tonumber(rm)) * 2 ^ (re - 62)
end

-- Bound for the true-precision round trip checks below. Measured worst
-- case over the sampled list is 4.336809e-19 (x=2, see task-9-report.md);
-- SQRT_RTOL gives ~11.5x margin, matching this file's "single-digit
-- multiple margin" convention (see kernel_bc_sweep.lua's own DIV_RTOL/
-- SQRT_RTOL derivations) rather than a loose bound that would fail to
-- catch a real regression.
local SQRT_RTOL = 5e-18

-- === sqrt: exact squares -- bit-exact, no tolerance needed. ============
-- v=2 (from_int(2) normalizes to e=1, ODD) and v=4 (e=2, EVEN) between
-- them exercise both exponent parities the brief's own Step 4 warned an
-- off-by-one would surface as (though the actual defect found here was
-- far larger than an off-by-one -- see lib/fixed.lua's M.sqrt comment).
local sqrt_exact_ok = true
for _, pair in ipairs({ {4,2}, {9,3}, {16,4}, {100,10}, {10000,100} }) do
	local v, want = pair[1], pair[2]
	local xm, xe = fx.from_int(v)
	local rm, re = fx.sqrt(xm, xe)
	local wm, we = fx.from_int(want)
	if not (rm == wm and re == we) then sqrt_exact_ok = false end
end
ok(sqrt_exact_ok, "sqrt of perfect squares is bit-exact (4,9,16,100,10000)")

-- === sqrt: round trip, brief's own list and tolerance (Step 1) =========
local sq_ok, sq_worst = true, 0
for _, v in ipairs({1, 2, 4, 9, 16, 100, 12345}) do
	local xm, xe = fx.from_int(v)
	local rm, re = fx.sqrt(xm, xe)
	local backm, backe = fx.mul(rm, re, rm, re)
	local err = math_abs_rel(backm, backe, xm, xe)
	if err > sq_worst then sq_worst = err end
	if err > 1e-15 then sq_ok = false end
end
ok(sq_ok, "sqrt(x)^2 == x for sampled x (double-precision check)", ("worst=%.3e"):format(sq_worst))

local em, ee = fx.sqrt(fx.from_int(4))
ok(math_abs_rel(em, ee, fx.from_int(2)) < 1e-16, "sqrt(4) == 2")

-- === sqrt: same round trip, TRUE fixed-point precision (MUTATION TARGET) ==
-- This is one of the two tests task-9's mutation pass targets (see
-- task-9-report.md). It is the only assertion in this file precise
-- enough to distinguish "full 62-bit precision" from "only the ~31-bit
-- precision a single raw-integer Newton stage can give" -- the
-- double-precision check above cannot make that distinction, since a
-- ~1e-9-scale error and a ~1e-19-scale error both read as comfortably
-- "0" once independently rounded through a double.
local sq_true_ok, sq_true_worst, sq_true_worst_label = true, 0, nil
for _, v in ipairs({1, 2, 4, 9, 16, 100, 12345}) do
	local xm, xe = fx.from_int(v)
	local rm, re = fx.sqrt(xm, xe)
	local backm, backe = fx.mul(rm, re, rm, re)
	local err = true_fixed_relerr(backm, backe, xm, xe)
	if err > sq_true_worst then sq_true_worst, sq_true_worst_label = err, v end
	if err > SQRT_RTOL then sq_true_ok = false end
end
ok(sq_true_ok, ("sqrt(x)^2 == x, TRUE fixed-point precision (< %.1e)"):format(SQRT_RTOL),
   ("worst=%.6e at x=%s"):format(sq_true_worst, tostring(sq_true_worst_label)))

-- === sqrt: explicit odd- and even-exponent cases at magnitude extremes ===
-- (verification item 1: "test on both odd and even exponents", beyond
-- what the small-integer list above happens to sample). Oracle-free,
-- metamorphic check (sqrt(x)^2 == x is a property of ANY x -- no
-- reference value needs to be known in advance).
local exp_parity_ok, exp_parity_worst = true, 0
for _, e in ipairs({-999, -1000, 0, 1, 999, 1000}) do
	local xm = 0x5B23A7C9E1F4D680LL   -- an arbitrary normalized mantissa
	local rm, re = fx.sqrt(xm, e)
	local backm, backe = fx.mul(rm, re, rm, re)
	local err = true_fixed_relerr(backm, backe, xm, e)
	if err > exp_parity_worst then exp_parity_worst = err end
	if err > SQRT_RTOL then exp_parity_ok = false end
end
ok(exp_parity_ok, "sqrt(x)^2 == x across odd/even exponents at magnitude extremes",
   ("worst=%.6e"):format(exp_parity_worst))

-- === sqrt: returned exponent is always an INTEGER (representation ======
-- === invariant, checked directly rather than only via a round trip). ===
-- Mutation testing this task's own tests found a real blind spot: a
-- mutant that drops the odd-exponent mantissa-halving step returns a
-- soft-float whose exponent ends in exactly ".5" (confirmed directly:
-- sqrt(2) under that mutant returns e=0.5, not an integer) -- an invalid
-- representation this file's own top-of-file invariant (2^62 <= |m| < 2^63
-- at INTEGER e) forbids. The "square it back and compare" round-trip
-- checks above do NOT catch this: squaring exactly DOUBLES the exponent,
-- and doubling any X.5 lands back on an integer by construction (2*(n +
-- 0.5) = 2n + 1), so the corruption exactly self-cancels under squaring
-- and every round-trip check above still reads as numerically correct.
-- Confirmed empirically (see task-9-report.md's mutation section): only
-- the bit-exact "sqrt of perfect squares" check above happened to catch
-- that mutant, incidentally (it compares fx.sqrt's raw output directly
-- against a genuinely-integer-exponent fx.from_int(want), which a
-- fractional exponent can never bit-match) -- not because any test was
-- actually checking the invariant itself. This check closes that gap
-- directly: it is now a target-of-record for that mutant class, not an
-- accident of a different test's shape.
local int_exp_ok, int_exp_bad_at = true, nil
for _, v in ipairs({1, 2, 4, 9, 16, 100, 12345}) do
	local xm, xe = fx.from_int(v)
	local _, re = fx.sqrt(xm, xe)
	if re ~= math.floor(re) then int_exp_ok = false; int_exp_bad_at = int_exp_bad_at or ("v=" .. v) end
end
for _, e in ipairs({-999, -1000, 0, 1, 999, 1000}) do
	local _, re = fx.sqrt(0x5B23A7C9E1F4D680LL, e)
	if re ~= math.floor(re) then int_exp_ok = false; int_exp_bad_at = int_exp_bad_at or ("e=" .. e) end
end
ok(int_exp_ok, "sqrt always returns an integer exponent (representation invariant)",
   int_exp_bad_at and ("first bad at " .. int_exp_bad_at) or nil)

-- === sqrt: domain -- negative argument asserts (MUTATION TARGET) =======
-- Follows M.ln's own convention (see its "domain: ln(0) and ln(negative)
-- must assert" check above): pcall plus an EXACT message match, not just
-- "does it error". The exact-message requirement matters here specifically
-- for M.sqrt: unlike M.pow (see below), there is no other assert anywhere
-- downstream that would incidentally catch a removed `assert(m >= 0, ...)`
-- -- ffi.cast(u64, mm) on a negative mantissa silently REINTERPRETS the
-- bit pattern as a large unsigned value and returns a wrong, non-erroring
-- result, which is exactly the failure mode this whole file's soft-float
-- kernel exists to eliminate (see the top-of-file comment on why libm was
-- replaced at all). A bare "pcall fails" check would still pass if some
-- unrelated later operation happened to error for a different reason; the
-- message match pins that the SPECIFIC guard fired.
local function rejects_sqrt(m, e, want_msg)
	local okc, err = pcall(fx.sqrt, m, e)
	if okc then return false, "accepted" end
	if not tostring(err):find(want_msg, 1, true) then
		return false, "wrong assert fired: " .. tostring(err)
	end
	return true
end
local negonem_sqrt, negonee_sqrt = fx.from_int(-1)
local sr1, swhy1 = rejects_sqrt(negonem_sqrt, negonee_sqrt, "fixed.sqrt: argument must be non-negative")
ok(sr1, "sqrt(negative) asserts rather than silently reinterpreting the bit pattern", swhy1)

-- === sqrt: domain -- zero is a POSITIVE case, must NOT raise ===========
-- m == 0 is this file's canonical-zero encoding (see M.norm), not a
-- degenerate negative case -- sqrt(0) == 0 exactly, and the function must
-- return it directly rather than falling into the m >= 0 assert or the
-- Newton loop at all.
local sqrt_zero_m, sqrt_zero_e = fx.sqrt(0LL, 0)
ok(sqrt_zero_m == 0LL and sqrt_zero_e == 0, "sqrt(0) returns canonical zero, does not raise")

-- === pow: brief's own case (Step 1), bit-exact ==========================
local base_m, base_e = fx.from_int(2)
local pm, pe = fx.pow(base_m, base_e, fx.from_int(10))
local want1024_m, want1024_e = fx.from_int(1024)
ok(math_abs_rel(pm, pe, fx.from_int(1024)) < 1e-14, "2^10 == 1024")
ok(pm == want1024_m and pe == want1024_e, "2^10 == 1024, bit-exact")

-- === pow: y == 0 and x == 1 identities (oracle-free: from_int(1) is =====
-- === already known-exact, no bc/double comparison needed) ==============
local one_m, one_e = fx.from_int(1)
local pow_y0_m, pow_y0_e = fx.pow(base_m, base_e, fx.from_int(0))
ok(pow_y0_m == one_m and pow_y0_e == one_e, "x^0 == 1 exactly")
local pow_x1_m, pow_x1_e = fx.pow(one_m, one_e, fx.from_int(12345))
ok(pow_x1_m == one_m and pow_x1_e == one_e, "1^y == 1 exactly")

-- === pow: negative y =====================================================
local pow_neg_m, pow_neg_e = fx.pow(base_m, base_e, fx.from_int(-3))
local eighth_m, eighth_e = fx.div(one_m, one_e, fx.from_int(8))
ok(true_fixed_relerr(pow_neg_m, pow_neg_e, eighth_m, eighth_e) < SQRT_RTOL, "2^-3 == 1/8")

-- === pow: differential check against an INDEPENDENT computation path ===
-- (MUTATION TARGET, the second of the two tests task-9's mutation pass
-- targets). Comparing fx.pow against repeated M.mul exercises a
-- completely different code path (mul only, no ln/exp) for the same
-- mathematical quantity -- this catches a formula flip (e.g.
-- exp(ln(x)/y) instead of exp(y*ln(x))) far more reliably than "2^10 ==
-- 1024" alone: with a non-power-of-two base (1/3) and several n, the two
-- formulas diverge by many orders of magnitude rather than by a value
-- that might coincidentally still look plausible for one specific (2,10)
-- pair.
local function pow_by_repeated_mul(xm, xe, n)
	local am, ae = fx.from_int(1)
	for _ = 1, n do am, ae = fx.mul(am, ae, xm, xe) end
	return am, ae
end
local third_m, third_e = fx.div(one_m, one_e, fx.from_int(3))
local pow_diff_ok, pow_diff_worst = true, 0
for _, n in ipairs({1, 2, 5, 10, 20}) do
	local viaexp_m, viaexp_e = fx.pow(third_m, third_e, fx.from_int(n))
	local viamul_m, viamul_e = pow_by_repeated_mul(third_m, third_e, n)
	local err = true_fixed_relerr(viaexp_m, viaexp_e, viamul_m, viamul_e)
	if err > pow_diff_worst then pow_diff_worst = err end
	if err > 1e-14 then pow_diff_ok = false end
end
ok(pow_diff_ok, "pow(1/3, n) matches (1/3)*(1/3)*...*(1/3) via an independent mul-only path",
   ("worst=%.6e"):format(pow_diff_worst))

-- === pow: FRACTIONAL, non-power-of-two exponent (MUTATION TARGET) ======
-- Every y tested above (and in kernel_bc_sweep.lua's POW_Y_VALUES before
-- this fix) is an integer or a power of two -- {1,2,5,10,20} above,
-- {-20,-3,-1,1,3,20} there -- and even the "realistic alpha=0.1" case
-- immediately below has 1/alpha = 10, conveniently exact. But the
-- motivating use (gamma's alpha<1 branch, x^(1/alpha)) gives FRACTIONAL y
-- almost always for a real alpha; that was unproven by the suite until
-- now. Verified via an algebraic identity, not an external oracle (see
-- kernel_bc_sweep.lua's pow_frac_y_10_3 case for the independent bc
-- cross-check of the same y): if y = a/b for integers a, b, then
-- pow(x, y)^b == pow(x, a) -- both sides reachable via the same
-- already-trusted, independent mul-only path used above, so this
-- exercises M.pow's ln/mul/exp machinery at a genuinely fractional,
-- non-power-of-two exponent (y = 10/3, i.e. 1/0.3 -- alpha = 0.3) with no
-- bc dependency in this file. Measured worst relerr 5.861303e-18.
local ten_m, ten_e = fx.from_int(10)
local frac_y_m, frac_y_e = fx.div(ten_m, ten_e, fx.from_int(3))   -- y = 10/3 = 1/0.3
local pow_frac_m, pow_frac_e = fx.pow(third_m, third_e, frac_y_m, frac_y_e)
local frac_lhs_m, frac_lhs_e = pow_by_repeated_mul(pow_frac_m, pow_frac_e, 3)   -- pow(x,y)^3
local frac_rhs_m, frac_rhs_e = pow_by_repeated_mul(third_m, third_e, 10)        -- x^10
local frac_err = true_fixed_relerr(frac_lhs_m, frac_lhs_e, frac_rhs_m, frac_rhs_e)
ok(frac_err < 1e-14,
   "pow(1/3, 10/3)^3 == (1/3)^10 -- fractional, non-power-of-two exponent, via (x^(a/b))^b == x^a",
   ("worst=%.6e"):format(frac_err))

-- === pow: realistic gamma-sampler domain (alpha<1, x in (0,1)) succeeds ==
-- NOTE: this specific case (alpha=0.1, y=1/alpha=10) is an INTEGER y, not
-- representative of a typical fractional alpha -- the fractional case
-- immediately above is what actually validates the general gamma-sampler
-- domain; this one just confirms the pipeline doesn't error for an
-- ordinary alpha.
local realistic_ok = pcall(fx.pow, third_m, third_e, fx.from_int(10))
ok(realistic_ok, "pow succeeds for a realistic alpha=0.1 gamma-sampler case ((1/3)^10)")

-- === pow: pathological alpha raises rather than hanging or returning ===
-- === garbage (documents the inherited M.exp bound -- see M.pow's doc  ===
-- === comment in lib/fixed.lua for the measured boundary this pins).   ===
local tiny_m, tiny_e = fx.div(one_m, one_e, fx.from_int(4294967296))  -- x = 2^-32
local hy_m, hy_e = fx.norm(one_m, 57)                                 -- y = 2^57
local pow_raises_ok = not pcall(fx.pow, tiny_m, tiny_e, hy_m, hy_e)
ok(pow_raises_ok, "pow raises (not hang, not garbage) once y*ln(x) exceeds M.exp's inherited bound")

-- === pow: domain -- non-positive base asserts (MUTATION TARGET) ========
-- Follows M.ln's own convention (pcall + exact message match), same as
-- sqrt's domain test above. The exact-message requirement matters
-- DIFFERENTLY here than for sqrt: if M.pow's own `assert(bm > 0, ...)`
-- were deleted, fx.pow(0, 0, ...) would still fall through to
-- M.ln(0, 0), which asserts on its own -- so a bare "does pcall fail"
-- check would still PASS even with the mutant applied, accidentally
-- saved by ln's guard rather than pow's own. Confirmed directly: a raw
-- call to fx.ln(0, 0) raises "fixed.ln: argument must be positive" --
-- different text from pow's own "fixed.pow: base must be positive". The
-- message match below distinguishes the two, so it is the mutant-killing
-- assertion; a bare error check would not be.
local function rejects_pow(bm, be, ym, ye, want_msg)
	local okc, err = pcall(fx.pow, bm, be, ym, ye)
	if okc then return false, "accepted" end
	if not tostring(err):find(want_msg, 1, true) then
		return false, "wrong assert fired: " .. tostring(err)
	end
	return true
end
local pr1, pwhy1 = rejects_pow(0LL, 0, one_m, one_e, "fixed.pow: base must be positive")
ok(pr1, "pow(0, y) asserts with pow's OWN message, not ln's incidental one", pwhy1)
local negtwo_m, negtwo_e = fx.from_int(-2)
local pr2, pwhy2 = rejects_pow(negtwo_m, negtwo_e, one_m, one_e, "fixed.pow: base must be positive")
ok(pr2, "pow(negative, y) asserts with pow's OWN message", pwhy2)

end

print("")
print("--- Section 8: decimal parse and format ---")
-- NOTE: the brief this task was built from labeled this "Section 7" --
-- already taken by sqrt/pow (see that section's own header comment).
-- Renumbered for a monotonic file, the same fix Section 6's own header
-- applied to an identical brief-inherited collision.
do

-- True fixed-point ABSOLUTE difference, same 62-bit-arithmetic
-- construction as Section 7's true_fixed_relerr (re-defined per-section
-- rather than shared -- see this file's top-of-file comment: no section
-- references another section's locals), but returning the ABSOLUTE
-- residual rather than dividing it by the reference magnitude. Needed
-- for the round-trip sweep below: "recovers x to the printed precision"
-- (the task's own phrasing) means an absolute floor of roughly
-- 10^-places, not a floor relative to x's own magnitude -- fixed-point
-- notation with a bounded digit count cannot carry full RELATIVE
-- precision for a magnitude far below 1 (printing 15 places for a value
-- around 1e-13 spends 13 of those digits on leading zeros, leaving only
-- ~2 significant digits -- an EXPECTED property of fixed-point
-- formatting, not a bug in tostring/parse). Same rationale
-- kernel_bc_sweep.lua's ln/cos sections document for pairing rtol with
-- atol near a genuine near-zero cancellation; this is the same
-- ill-conditioning, caused by tostring's bounded `places` rather than by
-- catastrophic cancellation.
local function true_fixed_absdiff(m1, e1, m2, e2)
	local dm, de = fx.sub(m1, e1, m2, e2)
	if dm == 0 then return 0.0 end
	return math.abs(tonumber(dm)) * 2 ^ (de - 62)
end

-- === parse: baseline cases (from the task brief) =========================
local p1m, p1e = fx.parse("1")
ok(fx.cmp(p1m, p1e, fx.from_int(1)) == 0, "parse('1') == 1")
local p2m, p2e = fx.parse("-42")
ok(fx.cmp(p2m, p2e, fx.from_int(-42)) == 0, "parse('-42') == -42")

-- parse('0.5') doubles as a regression test for a real CRASH in the brief
-- this was built from: `M.div(M.from_int(tonumber(frac_part)),
-- M.from_int(tonumber(den)))` chains a non-final multi-return call as an
-- argument. Lua truncates a non-final multi-return expression to ONE
-- value, so the first M.from_int(...) there hands M.div its mantissa
-- only -- the exponent is silently dropped and M.div's argument list
-- shifts by one. Confirmed directly: that exact line, run with
-- frac_part=5, den=10 (i.e. this exact test case), raises "fixed.div:
-- operand 2 not normalized" -- the brief's own suggested implementation
-- cannot parse "0.5" at all, let alone correctly. See lib/fixed.lua's
-- M.parse doc comment for the fix.
local p3m, p3e = fx.parse("0.5")
local q1m, q1e = fx.from_int(1)
local q2m, q2e = fx.from_int(2)
local halfm, halfe = fx.div(q1m, q1e, q2m, q2e)
ok(fx.cmp(p3m, p3e, halfm, halfe) == 0, "parse('0.5') == 1/2 exactly (does not crash)")
ok(fx.parse("") == nil, "parse('') is nil")
ok(fx.parse("abc") == nil, "parse('abc') is nil")
ok(fx.parse("1.2.3") == nil, "parse('1.2.3') is nil")
ok(fx.parse("  1  ") ~= nil, "parse tolerates surrounding whitespace")
ok(fx.parse(".5") ~= nil, "parse('.5') (no leading integer digit) is accepted")
local p_dot_m, p_dot_e = fx.parse("1.")
ok(fx.cmp(p_dot_m, p_dot_e, fx.from_int(1)) == 0, "parse('1.') (empty fraction after the dot) == 1")

-- === tostring: baseline cases (from the task brief) =======================
local z0m, z0e = fx.from_int(0)
ok(fx.tostring(z0m, z0e, 6) == "0.000000", "tostring(0) == '0.000000'")
local f42m, f42e = fx.from_int(42)
ok(fx.tostring(f42m, f42e, 2) == "42.00", "tostring(42, 2) == '42.00'")
local n7m, n7e = fx.from_int(-7)
ok(fx.tostring(n7m, n7e, 3) == "-7.000", "tostring(-7, 3) == '-7.000'")
ok(fx.tostring(halfm, halfe, 6) == "0.500000", "tostring(1/2, 6) == '0.500000'",
   "got " .. fx.tostring(halfm, halfe, 6))

-- === parse_int: baseline cases (from the task brief) ======================
ok(fx.parse_int("42") == 42, "parse_int('42') == 42")
ok(fx.parse_int("-9") == -9, "parse_int('-9') == -9")
ok(fx.parse_int("1.5") == nil,
   "parse_int('1.5') is nil (fractional bound rejected) [MUTATION TARGET A]")
ok(fx.parse_int("x") == nil, "parse_int('x') is nil")

-- === Verification item 1: parse must not lose the fraction ================
-- den = 10^frac_digits must itself fit exactly in int64 (10^19 does not,
-- 10^18 does) -- the reason frac_digits is capped at 18 -- checked here
-- directly at 18, 19, and 30 digits rather than assumed.
local frac18 = string.rep("3", 18)
local p18m, p18e = fx.parse("0." .. frac18)
-- Independent construction: the same accumulation the kernel does
-- internally, built here without going through fx.parse at all, so this
-- is not simply checking parse against itself.
local frac_ll = 0LL
for _ = 1, 18 do frac_ll = frac_ll * 10LL + 3 end
local den_ll = 1LL
for _ = 1, 18 do den_ll = den_ll * 10LL end
-- NOTE: fx.from_int(...) results are bound to named locals before the
-- fx.div call, not chained directly as arguments -- chaining a non-final
-- multi-return call (fx.div(fx.from_int(a), fx.from_int(b))) hits the
-- exact Lua truncation bug M.parse's own doc comment documents as the
-- brief's defect 1; this test caught itself making the identical mistake
-- on its first run (fx.div: operand 2 not normalized), which is exactly
-- the kind of thing "run the test and watch it fail" is for.
local frac_num_m, frac_num_e = fx.from_int(frac_ll)
local frac_den_m, frac_den_e = fx.from_int(den_ll)
local exp18m, exp18e = fx.div(frac_num_m, frac_num_e, frac_den_m, frac_den_e)
ok(fx.cmp(p18m, p18e, exp18m, exp18e) == 0,
   "parse: 18-digit fraction matches an independently-built int64 division exactly")

local p19m, p19e = fx.parse("0." .. frac18 .. "7")   -- 19th fraction digit
ok(fx.cmp(p19m, p19e, p18m, p18e) == 0,
   "parse: 19th fraction digit is dropped, not misparsed (result unchanged)")

local p30m, p30e = fx.parse("0." .. frac18 .. string.rep("9", 12))  -- 30 digits total
ok(fx.cmp(p30m, p30e, p18m, p18e) == 0,
   "parse: digits past the 18th are still dropped cleanly even at 30 total (no corruption)")

-- Integer part: exactly int64 max (19 digits) parses exactly; any
-- 19-digit value past int64 max is REJECTED, not silently wrapped. The
-- brief's own "digits > 18" check let 19-digit inputs through with no
-- magnitude check at all -- confirmed directly that parsing 19 nines
-- under the brief's literal, unchecked accumulation
-- (`int_part * 10LL + d`) wraps to -8446744073709551616: A NEGATIVE
-- MANTISSA FOR A STRING WITH NO MINUS SIGN ANYWHERE IN IT.
local imaxm, imaxe = fx.parse("9223372036854775807")
ok(fx.cmp(imaxm, imaxe, fx.from_int(9223372036854775807LL)) == 0,
   "parse: int64-max integer part (19 digits) parses exactly")
ok(fx.parse("9999999999999999999") == nil,
   "parse: 19-digit integer part past int64 max is rejected, not silently wrapped [MUTATION TARGET B]")
ok(fx.parse("99999999999999999999999") == nil,
   "parse: a grossly-overflowing integer part (23 digits) is rejected")

-- === Verification item 2: tostring must not produce a wrong digit ========
-- Truncation toward zero, unconditionally: -0.5 formats as "-0.500000",
-- never "-0.499999" (would indicate a floor-toward-negative-infinity
-- rounding-direction bug) and never anything a round-to-nearest mutant
-- would also produce here (0.5 has no closer neighbor to round to, so
-- this specific case alone would NOT distinguish truncate from round --
-- see the just-below-a-boundary cases immediately below, which do).
local neghalfm, neghalfe = fx.neg(halfm, halfe)
ok(fx.tostring(neghalfm, neghalfe, 6) == "-0.500000",
   "tostring(-0.5, 6) == '-0.500000' (truncation toward zero)")

-- Just below 1, at low places: must truncate DOWN to 0.999999, never
-- round up to 1.000000. Needs a value whose (places+1)th digit is
-- unambiguously large -- 999999/1000000 was tried first and REJECTED:
-- that fraction terminates EXACTLY at 6 decimal digits (0.999999,
-- period), so it has no 7th digit to distinguish round from truncate at
-- all, and M.div's own truncation-toward-zero (a real, correct, already-
-- verified property of a value that isn't exactly binary-representable)
-- shaves the computed value a hair below 0.999999, making it print
-- "0.999998" -- a false alarm from a flawed test premise, not a tostring
-- bug (confirmed by hand before writing this comment). 99999999/100000000
-- (8 nines) fixes this: digits 7 and 8 are both a solid "9", far from any
-- binary-truncation-noise boundary, so round-to-nearest would visibly
-- round up to "1.000000" while truncation gives "0.999999" -- the actual
-- mutation target for "tostring rounds instead of truncating".
local n99num_m, n99num_e = fx.from_int(99999999)
local n99den_m, n99den_e = fx.from_int(100000000)
local n99m, n99e = fx.div(n99num_m, n99num_e, n99den_m, n99den_e)
ok(fx.tostring(n99m, n99e, 6) == "0.999999",
   "tostring(99999999/100000000, 6) truncates to 0.999999, does not round up to 1.000000 [MUTATION TARGET C]")

-- Same boundary, negative: truncation toward zero gives -1.99, not -2.00
-- (which floor-toward-negative-infinity, a DIFFERENT rounding-direction
-- bug than round-to-nearest, would produce).
local nbnum_m, nbnum_e = fx.from_int(19999999999LL)
local nbden_m, nbden_e = fx.from_int(10000000000LL)
local nbm, nbe = fx.div(nbnum_m, nbnum_e, nbden_m, nbden_e)
local nbm2, nbe2 = fx.neg(nbm, nbe)
ok(fx.tostring(nbm2, nbe2, 2) == "-1.99",
   "tostring(-1.9999999999, 2) truncates toward zero to -1.99, not -2.00")

-- Large-magnitude integer part: a real defect found while verifying this
-- function, independent of anything the brief called out. LuaJIT's
-- default number formatting (plain `tostring()`, `%.14g`) switches to
-- scientific notation once an integer-valued double's magnitude reaches
-- roughly 1e14 -- confirmed directly, `tostring(1000000000000000)`
-- prints "1e+15", not the 16-digit literal -- which would have spliced
-- garbage like "1e+15.001922" into M.tostring's output for any value
-- with a 15+ digit integer part. 123456789012345 (15 digits) sits
-- comfortably below to_int_trunc's own, unrelated 2^53 clamp
-- (~9.007e15), isolating THIS defect from that pre-existing one.
local bigm, bige = fx.from_int(123456789012345)
ok(fx.tostring(bigm, bige, 2) == "123456789012345.00",
   "tostring of a 15-digit integer part prints plain digits, not scientific notation",
   "got " .. fx.tostring(bigm, bige, 2))

-- === Verification item 3: round-trip, worst case over a sweep, not 3 =====
-- === sample values, per instruction ("measure the worst case rather    ===
-- === than sampling three values").                                     ===
-- Deterministic LCG (same multiplier family as tests/kernel_bc_sweep.lua),
-- fixed seed, reproducible across machines and runs. Generates raw
-- (m, e) pairs at exponents from -40 to 50 -- small fractions through
-- 15-digit integers (the largest exponent deliberately lands past the
-- ~1e14 scientific-notation threshold fixed above, so this sweep also
-- exercises that fix, not just typical-magnitude values), spanning the
-- realistic domain this kernel's own top-of-file comment documents (ln
-- down to -22, variates to +/-6.6, mean into the thousands, log-normal
-- "effectively unbounded").
local RT_TWO62 = 0x4000000000000000ULL
local rt_lcg = 0xA24BAED4963EE407ULL
local function rt_next_mantissa()
	rt_lcg = rt_lcg * 6364136223846793005ULL + 1442695040888963407ULL
	local high = rt_lcg / 4ULL
	return RT_TWO62 + (high % RT_TWO62)
end
local RT_EXPS = {-40, -20, -10, -5, -1, 0, 1, 5, 10, 20, 40, 50}
local RT_PLACES = 15
-- Per-case tolerance, not one flat number for the whole sweep -- TWO
-- earlier, flawed versions of this check are recorded here rather than
-- silently dropped, because both are genuine "verify rather than trust"
-- findings about what "round-trips to the printed precision" has to mean
-- for a FIXED (not floating) number of decimal places:
--   1. A flat RELATIVE bound (< 1e-14) FAILED at e=-40 (|x| ~ 9e-13),
--      reporting "7.3e-04 relative error" -- alarming-looking, but purely
--      an artifact of dividing a ~1.3e-15 absolute (entirely correct)
--      truncation residual by a ~9e-13 true value. 15 fractional places
--      applied to a value that small spends ~12 of those digits on
--      leading zeros, leaving only ~3 significant digits -- an EXPECTED
--      property of fixed-point formatting at small magnitude, not a bug.
--   2. A flat ABSOLUTE bound (< 1e-13) then FAILED at the opposite end,
--      e=50 (|x| ~ 1.1e15), reporting "2.44e-04 absolute error". At that
--      magnitude the INTEGER part alone already spends ~15-16 of this
--      kernel's ~18-19 total decimal digits of precision, leaving almost
--      nothing for the 15 requested FRACTIONAL places -- asking for both
--      simultaneously requests more total precision than a ~62-bit
--      mantissa has to give, regardless of how tostring/parse are coded.
-- The bound that is actually correct combines both: an absolute floor of
-- 10^-places (what a SMALL-magnitude value's round trip can be held to)
-- OR'd with a term scaled to the value's own magnitude by this kernel's
-- real ~2^-62 relative precision, with margin for tostring's own
-- compounding per-digit mul/sub truncation (2^-55 gives ~128x that
-- margin -- similar in spirit to this file's other "N x the measured
-- floor" tolerances, e.g. LN_RTOL in kernel_bc_sweep.lua).
local function rt_tolerance(m, e)
	-- Double precision is fine here: this only SIZES the tolerance band,
	-- unlike the measured error itself (true_fixed_absdiff), which never
	-- leaves fixed-point arithmetic.
	local approx_mag = math.abs(tonumber(m)) * 2 ^ (e - 62)
	return math.max(10 ^ -RT_PLACES, approx_mag * 2 ^ -55)
end
local rt_fail_count = 0
local rt_worst_ratio, rt_worst_ratio_label = 0, nil
local rt_count = 0
for _, e in ipairs(RT_EXPS) do
	for i = 1, 8 do
		local mag = rt_next_mantissa()
		local m = ffi.cast("int64_t", mag)
		if i % 2 == 0 then m = -m end   -- alternate sign
		local s = fx.tostring(m, e, RT_PLACES)
		local pm, pe = fx.parse(s)
		local absdiff = true_fixed_absdiff(pm, pe, m, e)
		local tol = rt_tolerance(m, e)
		rt_count = rt_count + 1
		if absdiff > tol then rt_fail_count = rt_fail_count + 1 end
		local ratio = absdiff / tol
		if ratio > rt_worst_ratio then
			rt_worst_ratio, rt_worst_ratio_label =
				ratio, ("e=%d i=%d absdiff=%.3e tol=%.3e"):format(e, i, absdiff, tol)
		end
	end
end
ok(rt_fail_count == 0,
   ("parse(tostring(x, %d)) recovers x within max(10^-places, |x|*2^-55), over %d swept values"):
      format(RT_PLACES, rt_count),
   ("worst case used %.4fx of its allowed tolerance, at %s"):format(rt_worst_ratio, tostring(rt_worst_ratio_label)))

-- === Verification item 4: parse_int must reject what it should ===========
ok(fx.parse_int("") == nil, "parse_int('') is nil (empty string)")
ok(fx.parse_int("   ") == nil, "parse_int('   ') is nil (whitespace-only)")
ok(fx.parse_int("-") == nil, "parse_int('-') is nil (bare sign)")
ok(fx.parse_int("+") == nil, "parse_int('+') is nil (bare sign)")
ok(fx.parse_int("+5") == 5,
   "parse_int('+5') == 5 (leading + accepted on an otherwise-valid literal, matching the brief's own intent)")
ok(fx.parse_int("++5") == nil, "parse_int('++5') is nil (a second sign is not a digit)")
ok(fx.parse_int("+-5") == nil, "parse_int('+-5') is nil (a second sign is not a digit)")
ok(fx.parse_int("12a34") == nil, "parse_int('12a34') is nil (embedded letters)")

-- 25-digit input: the brief this was built from had NO overflow check at
-- all in M.parse_int (`v = v * 10LL + d`, unchecked) -- confirmed
-- directly it returns 3287003324691717120 for 25 sevens, a plausible-
-- looking but entirely wrong integer, no rejection.
ok(fx.parse_int(string.rep("7", 25)) == nil,
   "parse_int: 25-digit input overflowing int64 is rejected, not silently wrapped")

-- Exact int64 boundary. The result is compared against tonumber() of the
-- same int64 literal, not the literal itself, because parse_int's own
-- documented return type is a plain Lua number (a double) -- at this
-- exact magnitude that is ALREADY the nearest representable double, not
-- the mathematically exact integer; the test makes that explicit rather
-- than relying on the literal happening to round the same way.
local INT64_MAX_LL = 9223372036854775807LL
ok(fx.parse_int("9223372036854775807") == tonumber(INT64_MAX_LL),
   "parse_int: int64 max parses (as the nearest representable double, per its documented contract)")
ok(fx.parse_int("-9223372036854775807") == -tonumber(INT64_MAX_LL),
   "parse_int: negative int64 max parses (same documented double-rounding)")
ok(fx.parse_int("9223372036854775808") == nil,
   "parse_int: int64 max + 1 is rejected")
ok(fx.parse_int("-9223372036854775808") == nil,
   "parse_int: true INT64_MIN's magnitude (2^63) is rejected -- the deliberate symmetric-range " ..
   "simplification documented on accumulate_digits")

end

print("")
print("============================================")
if fails > 0 then
	io.stderr:write(("fixed test FAILED: %d of %d checks failed\n"):format(fails, checks))
	os.exit(fails)
end
print(("fixed test PASSED: All %d checks passed"):format(checks))
