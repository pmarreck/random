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
print("============================================")
if fails > 0 then
	io.stderr:write(("fixed test FAILED: %d of %d checks failed\n"):format(fails, checks))
	os.exit(fails)
end
print(("fixed test PASSED: All %d checks passed"):format(checks))
