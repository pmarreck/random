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
print("============================================")
if fails > 0 then
	io.stderr:write(("fixed test FAILED: %d of %d checks failed\n"):format(fails, checks))
	os.exit(fails)
end
print(("fixed test PASSED: All %d checks passed"):format(checks))
