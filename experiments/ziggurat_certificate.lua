-- Finite directed-interval checks, independent of the table generator.
-- This certifies constants and point decisions, not a global distribution law.
package.path = "experiments/?.lua;" .. package.path
local ffi = require("ffi")
local m = require("mpfr")
m.precision = 512
local library = assert(arg[1], "freshly compiled experiment library required")
local control = arg[2]
assert(control == nil or control == "threshold" or control == "height", "unknown certificate control")

ffi.cdef[[
const char *mpfr_get_version(void);
typedef struct { int64_t m; int32_t e; } certificate_pair;
typedef int (*certificate_fill)(void *, uint8_t *, size_t);
void experiment_strip(uint8_t, certificate_pair *, certificate_pair *, uint64_t *);
int experiment_words(const uint64_t *, size_t, size_t *, certificate_pair *);
void experiment_math(uint8_t, certificate_pair, certificate_pair *);
int randomz_normal(certificate_fill, void *, certificate_pair, certificate_pair, certificate_pair *);
]]
print("MPFR", ffi.string(m.c.mpfr_get_version()), "precision", m.precision)
local lib = ffi.load(library)
local DOWN, UP = 3, 2
local function op(name, a, b, mode)
	local z = m.new()
	m.c["mpfr_" .. name](z, a, b, mode)
	return z
end
local function unary(name, a, mode)
	local z = m.new()
	m.c["mpfr_" .. name](z, a, mode)
	return z
end
local function exact(name, a, b)
	local z = m.new()
	assert(m.c["mpfr_" .. name](z, a, b, 0) == 0, "inexact rational precomputation: " .. name)
	return z
end
local function absdiff_upper(a, b)
	local x, y = op("sub", a, b, UP), op("sub", b, a, UP)
	return m.cmp(x, y) > 0 and x or y
end
local function hex(a)
	local b = ffi.new("char[2048]")
	assert(m.c.mpfr_snprintf(b, 2048, "%Ra", a) < 2048)
	return ffi.string(b)
end
local zero, one, two = m.new(0), m.new(1), m.new(2)
local C, S = m.new(256), 36028797018963968ULL
local x, y, k, sumk = {}, {}, {}, 0ULL
for i = 0,255 do
	local a, b, c = ffi.new("certificate_pair[1]"), ffi.new("certificate_pair[1]"), ffi.new("uint64_t[1]")
	lib.experiment_strip(i, a, b, c)
	x[i], y[i], k[i] = m.fixed(a[0].m, a[0].e), m.fixed(b[0].m, b[0].e), c[0]
	sumk = sumk + k[i] -- Sum is below 2^63: no U64 wrap.
end
x[256], y[256] = zero, one
-- Corrupt checker inputs only: prove the bounds are actually enforced.
if control == "threshold" then k[73] = k[73]+1ULL end
if control == "height" then y[73] = m.add(y[73], m.new("1e-9")) end
-- These are finite dyadic comparisons, not sampled kernel extrema.
for i = 0,255 do
	assert(k[i] < S and m.cmp(x[i], zero) > 0 and m.cmp(x[i], m.new(4)) < 0)
	assert(m.cmp(y[i], zero) >= 0 and m.cmp(y[i], one) < 0)
	local target = i == 0 and x[1] or x[i+1]
	local scaled = exact("mul", m.new(S), target)
	assert(m.cmp(exact("mul", m.new(k[i]), x[i]), scaled) <= 0, "threshold floor lower: " .. i)
	assert(m.cmp(scaled, exact("mul", m.new(k[i]+1ULL), x[i])) < 0, "threshold floor upper: " .. i)
end
assert(m.cmp(x[255], m.shift(one,-3)) > 0)
assert(m.cmp(exact("mul", x[1], m.new(5)), m.new(18)) > 0)
assert(m.cmp(exact("mul", x[1], m.new(10)), m.new(37)) < 0)
assert(m.cmp(exact("mul", x[1], m.new(S)), exact("mul", m.new(4), m.new(k[0]))) < 0)
print("CERTIFIED all 256 threshold floors; 0<X_i<4; X_255>1/8; 18/5<R<37/10; 0<=Y_i<1")
print("CERTIFIED R/k_0 < 4h for base conditional-coordinate coupling")
assert(tostring(sumk) == "9085768088181066670ULL")
local den = m.shift(one, 63)
assert(m.cmp(exact("mul", m.new(sumk), m.new(1000)), exact("mul", den, m.new(985))) > 0)
local tail_numerator = S - k[0]
assert(tostring(tail_numerator) == "2364035879175382ULL")
assert(m.cmp(exact("mul", m.new(tail_numerator), m.new(10000)), exact("mul", den, m.new(3))) < 0)
print("CERTIFIED p_fast > 0.985", tostring(sumk), "/ 9223372036854775808")
print("CERTIFIED tail-entry < 0.0003", tostring(tail_numerator), "/ 9223372036854775808")

local G = m.new(0)
for i = 1,255 do
	assert(m.cmp(x[i], x[i+1]) > 0 and m.cmp(y[i+1], y[i]) > 0)
	local slow = exact("sub", one, m.shift(m.new(k[i]), -55))
	local height = exact("sub", y[i+1], y[i])
	G = op("add", G, op("div", slow, height, UP), UP)
end
G = op("div", G, C, UP)
assert(m.cmp(G, m.new(3)) < 0)
print("CERTIFIED G < 3; upper endpoint", hex(G))

local slivers, largest = m.new(0), m.new(0)
for i = 1,255 do
	local exponent = m.shift(exact("sub", zero, exact("mul", x[i], x[i])), -1)
	local flo, fhi = unary("exp", exponent, DOWN), unary("exp", exponent, UP)
	assert(m.cmp(y[i], flo) <= 0, "stored height above certified PDF: " .. i)
	local eps = op("sub", fhi, y[i], UP)
	if m.cmp(eps, largest) > 0 then largest = eps end
	if i >= 2 then
		slivers = op("add", slivers, op("mul", exact("sub", x[i-1], x[i]), eps, UP), UP)
	end
end
print("CERTIFIED stored heights <= true PDF; maximum residual upper endpoint", hex(largest))
local piLo, piHi = m.new(), m.new()
m.c.mpfr_const_pi(piLo, DOWN); m.c.mpfr_const_pi(piHi, UP)
local Hlo, Hhi = unary("sqrt", m.shift(piLo, -1), DOWN), unary("sqrt", m.shift(piHi, -1), UP)
local sqrt2Lo, sqrt2Hi = unary("sqrt", two, DOWN), unary("sqrt", two, UP)
local zLo, zHi = op("div", x[1], sqrt2Hi, DOWN), op("div", x[1], sqrt2Lo, UP)
-- erfc decreases, so its interval arguments reverse.
local Tlo = op("mul", Hlo, unary("erfc", zHi, DOWN), DOWN)
local Thi = op("mul", Hhi, unary("erfc", zLo, UP), UP)
local body = exact("mul", x[1], y[1])
local Alo, Ahi = {}, {}
Alo[0], Ahi[0] = op("add", body, Tlo, DOWN), op("add", body, Thi, UP)
local totalLo, totalHi = Alo[0], Ahi[0]
for i = 1,255 do
	Alo[i] = exact("mul", x[i], exact("sub", y[i+1], y[i]))
	Ahi[i] = Alo[i]
	totalLo = op("add", totalLo, Alo[i], DOWN)
	totalHi = op("add", totalHi, Ahi[i], UP)
end
local tv, weight = m.new(0), m.shift(one, -8)
for i = 0,255 do
	local lo, hi = op("div", Alo[i], totalHi, DOWN), op("div", Ahi[i], totalLo, UP)
	local a, b = absdiff_upper(weight, lo), absdiff_upper(weight, hi)
	tv = op("add", tv, m.cmp(a, b) > 0 and a or b, UP)
end
tv = m.shift(tv, -1)
assert(m.cmp(tv, m.shift(one, -53)) < 0)
local hole = op("div", slivers, Hlo, UP)
assert(m.cmp(hole, m.shift(one, -60)) < 0)
print("CERTIFIED area-weight TV < 2^-53; upper endpoint", hex(tv))
print("CERTIFIED missing-cover/H < 2^-60; upper endpoint", hex(hole))
local fracLo, fracHi = op("div", body, Ahi[0], DOWN), op("div", body, Alo[0], UP)
local actual = m.shift(m.new(k[0]), -55)
local a, b = absdiff_upper(actual, fracLo), absdiff_upper(actual, fracHi)
local mix = m.cmp(a, b) > 0 and a or b
assert(m.cmp(mix, m.shift(one, -54)) < 0)
print("CERTIFIED base conditional mixture discrepancy < 2^-54; upper endpoint", hex(mix))

local ln2Lo, ln2Hi = unary("log", two, DOWN), unary("log", two, UP)
-- ln(2) reduces to 0 + 1*LN2, exposing the actual compiled constant.
local ln2Pair = ffi.new("certificate_pair[1]")
lib.experiment_math(1, ffi.new("certificate_pair", {4611686018427387904LL,1}), ln2Pair)
local storedLn2 = m.fixed(ln2Pair[0].m, ln2Pair[0].e)
assert(m.cmp(storedLn2, ln2Lo) <= 0)
assert(m.cmp(ln2Hi, exact("add", storedLn2, m.shift(one, -63))) < 0)
assert(m.cmp(exact("mul", storedLn2, m.new(100)), m.new(69)) > 0)
assert(m.cmp(exact("mul", storedLn2, m.new(10)), m.new(7)) < 0)
assert(m.cmp(op("mul", ln2Hi, m.new(55), UP), m.new(39)) < 0)
print("CERTIFIED LN2 <= ln(2) < LN2+2^-63")
print("CERTIFIED .69<LN2<.70 and 55*ln(2)<39")
local function pow_integer(base, n)
	local z = m.new(1)
	for _ = 1,n do z = exact("mul", z, m.new(base)) end
	return z
end
assert(m.cmp(exact("mul", m.new(9), m.shift(one, 62)), exact("mul", m.new(172), pow_integer(3, 43))) < 0)
local factorial = m.new(1)
for n = 1,17 do factorial = exact("mul", factorial, m.new(n)) end
local expLeft = exact("mul", exact("mul", pow_integer(7, 17), m.new(360)), m.shift(one, 62))
local expRight = exact("mul", exact("mul", m.new(353), pow_integer(20, 17)), factorial)
assert(m.cmp(expLeft, expRight) < 0)
print("CERTIFIED atanh and Taylor analytic remainder inequalities < 2^-62")

local function header(i, negative, j) return j*512ULL+i+(negative and 256ULL or 0ULL) end
local words, out, used = ffi.new("uint64_t[5]"), ffi.new("certificate_pair[1]"), ffi.new("size_t[1]")
local mismatch_strips = {[73]=true,[206]=true,[213]=true,[223]=true}
local excluded, disagreements, classes = 0,0,{}
for i = 1,255 do
	for ji,j in ipairs({k[i], (k[i]+S-1ULL)/2ULL, S-1ULL}) do
		for vi,v in ipairs({0ULL,S/4ULL,S/2ULL,3ULL*(S/4ULL),S-1ULL}) do
			local xx = exact("mul", m.shift(m.new(j), -55), x[i])
			local yy = exact("add", y[i], exact("mul", m.shift(m.new(v), -55), exact("sub", y[i+1], y[i])))
			local exponent = m.shift(exact("sub", zero, exact("mul", xx, xx)), -1)
			local center = unary("exp", exponent, 0)
			if m.cmp(m.abs(exact("sub", center, yy)), m.new("1e-15")) < 0 then
				local lower, upper = unary("exp", exponent, DOWN), unary("exp", exponent, UP)
				local gapLo, gapHi = exact("sub", lower, yy), exact("sub", upper, yy)
				local ideal
				if m.cmp(gapLo, zero) > 0 then ideal = true
				elseif m.cmp(gapHi, zero) <= 0 then ideal = false
				else error("unresolved directed wedge interval: " .. i) end
				local label = "j" .. ji .. "-v" .. vi
				classes[label] = (classes[label] or 0)+2
				for _,negative in ipairs({false,true}) do
					words[0],words[1],words[2] = header(i,negative,j),header(0,false,v),63018ULL
					assert(lib.experiment_words(words,3,used,out) == 0)
					local accepted = tonumber(used[0]) == 2
					assert(tonumber(used[0]) == 2 or tonumber(used[0]) == 3)
					if accepted ~= ideal then
						assert(mismatch_strips[i] and ji==1 and vi==5 and ideal and not accepted)
						disagreements = disagreements+1
						print("COMPILED-DIFFERENCE",i,tostring(words[0]),tostring(words[1]),tostring(words[2]),"used=3","gapLo="..hex(gapLo),"gapHi="..hex(gapHi))
					end
					excluded = excluded+1
				end
			end
		end
	end
end
assert(excluded==1020 and disagreements==8)
assert(classes["j1-v5"]==510 and classes["j3-v1"]==510)
print("CERTIFIED excluded wedge signs",excluded,"compiled ideal-real deviations",disagreements)
for _,negative in ipairs({false,true}) do
	words[0],words[1],words[2] = header(0,negative,S-1ULL),18446744073709551615ULL,18446744073709551615ULL
	assert(lib.experiment_words(words,3,used,out)==0 and tonumber(used[0])==3)
	assert(out[0].m==(negative and -8425902885307730888LL or 8425902885307730888LL) and out[0].e==1)
	print("CERTIFIED exact tail equality acceptance",tostring(words[0]),tostring(out[0].m),tonumber(out[0].e))
end
-- Actual production ABI, not only the Lua arithmetic helper. U32 draws are BE.
for _,second_first_byte in ipairs({64,192}) do
	local bytes = ffi.new("uint8_t[8]", {128,0,0,0,second_first_byte,0,0,0})
	local consumed, requests = 0, {}
	local callback = ffi.cast("certificate_fill", function(_, destination, count)
		count = tonumber(count)
		requests[#requests+1] = count
		if count ~= 4 or consumed+count > 8 then return 2 end
		ffi.copy(destination,bytes+consumed,count)
		consumed = consumed+count
		return 0
	end)
	local mean = ffi.new("certificate_pair", {0,0})
	local stddev = ffi.new("certificate_pair", {4611686018427387904LL,0})
	local status = lib.randomz_normal(callback,nil,mean,stddev,out)
	callback:free()
	assert(status==0 and out[0].m==0LL and out[0].e==0)
	assert(consumed==8 and #requests==2 and requests[1]==4 and requests[2]==4)
	print("CERTIFIED production standard-normal zero; U1=0x80000000; U2="..(second_first_byte==64 and "0x40000000" or "0xc0000000"),"requests=4,4 consumed=8")
end
print("FINITE CERTIFICATES PASS. Global primitive rounding, kernel propagation, and coupling lemmas remain uncertified; this is not a machine-proof of D_K < 1e-11.")
