-- MPFR judges stored geometry and compiled arithmetic; statistics are supplemental.
package.path = "experiments/?.lua;" .. package.path
local ffi = require("ffi")
local m = require("mpfr")
m.precision = 512
ffi.cdef[[
typedef struct { int64_t m; int32_t e; } experiment_pair;
void experiment_strip(uint8_t, experiment_pair *, experiment_pair *, uint64_t *);
void experiment_math(uint8_t, experiment_pair, experiment_pair *);
int experiment_words(const uint64_t *, size_t, size_t *, experiment_pair *);
int experiment_samples(uint64_t, uint8_t, uint8_t, size_t, experiment_pair *);
]]
local lib = ffi.load(assert(arg[1], "compiled experiment library required"))
local zero, one, two = m.new(0), m.new(1), m.new(2)
local pi = m.new(); m.c.mpfr_const_pi(pi, 0)
local sqrt_two = m.sqrt(two)
local function pdf(x) return m.exp(m.div(m.sub(zero, m.mul(x, x)), two)) end
local function real(x) return m.fixed(x.m, x.e) end
local function number(x) return tonumber(x.m) * 2^(tonumber(x.e) - 62) end
local function near(actual, expected, tolerance, message)
	local error = m.abs(m.sub(actual, expected))
	assert(m.cmp(error, tolerance) <= 0, message .. ": " .. m.text(error, 24))
	return m.number(error)
end
local x, y, k = {}, {}, {}
for i = 0, 255 do
	local xp, yp, kp = ffi.new("experiment_pair[1]"), ffi.new("experiment_pair[1]"), ffi.new("uint64_t[1]")
	lib.experiment_strip(i, xp, yp, kp)
	x[i], y[i], k[i] = real(xp[0]), real(yp[0]), kp[0]
end
x[256], y[256] = zero, one
-- Corrupt checker inputs, never production code; each must bite its own rule.
if arg[3] == "threshold" then k[0] = k[0] + 1ULL
elseif arg[3] == "geometry" then x[42] = x[41]
elseif arg[3] == "pdf" then y[42] = m.add(y[42], m.new("0.0001"))
else assert(arg[3] == nil, "unknown oracle control") end
local area = m.add(m.mul(x[1], pdf(x[1])), m.mul(m.sqrt(m.div(pi, two)), m.erfc(m.div(x[1], sqrt_two))))
local largest_pdf_error, largest_area_error = 0, 0
for i = 0, 255 do
	assert(m.cmp(x[i], x[i+1]) > 0, "nondecreasing strip width")
	local expected_k = m.floor(m.shift(m.div(x[i+1], x[i]), 55))
	assert(tostring(k[i]):gsub("ULL$", "") == m.text(expected_k), "nonconservative threshold " .. i)
	local a = i == 0 and m.mul(x[0], y[1]) or m.mul(x[i], m.sub(y[i+1], y[i]))
	largest_area_error = math.max(largest_area_error, near(a, area, m.shift(one, -57), "unequal strip area " .. i))
	if i > 0 then
		largest_pdf_error = math.max(largest_pdf_error, near(y[i], pdf(x[i]), m.shift(one, -58), "PDF table " .. i))
	end
end

-- Judge compiled exp at every seam and 17 interior points per wedge. This
-- samples the approximation error; it does not certify its entire domain.
local out = ffi.new("experiment_pair[1]")
local max_exp, max_ln = 0, 0
for i = 1, 255 do
	for j = 0, 16 do
		local coordinate = m.add(x[i+1], m.mul(m.sub(x[i], x[i+1]), m.div(m.new(j), m.new(16))))
		local exponent = m.div(m.sub(zero, m.mul(coordinate, coordinate)), two)
		local negative = m.cmp(exponent, zero) < 0
		local magnitude = m.abs(exponent)
		local im, ie = m.pair(magnitude)
		local input = ffi.new("experiment_pair", {m = m.i64(im), e = ie})
		if negative then input.m = -input.m end
		lib.experiment_math(0, input, out)
		max_exp = math.max(max_exp, near(real(out[0]), m.exp(real(input)), m.shift(one, -55), "fixed exp"))
	end
end
for b = 0, 55 do
	for j = 0,64 do
		local input = ffi.new("experiment_pair", {m = 4611686018427387904LL + 72057594037927935LL*j, e = -b})
		lib.experiment_math(1, input, out)
		max_ln = math.max(max_ln, near(real(out[0]), m.log(real(input)), m.shift(one, -55), "fixed ln"))
	end
end

-- One-seed CDF checks are deterministic diagnostics, not a proof or TestU01.
-- The DKW envelope controls all tested CDF cuts together, conditional on IID
-- ideal inputs; the DRBG is an independent computational assumption.
local n = tonumber(arg[2]) or 100000
local samples = ffi.new("experiment_pair[?]", n)
local epsilon = math.sqrt(math.log(2 / 1e-6) / (2*n))
for algorithm = 0, 2 do
	assert(lib.experiment_samples(42, algorithm, 0, n, samples) == 0)
	local sorted, sum, squares = {}, 0, 0
	for i = 0, n-1 do
		local v = (number(samples[i]) + 0.25) / 1.75
		sorted[i+1], sum, squares = v, sum + v, squares + v*v
	end
	table.sort(sorted)
	local largest = 0
	for j = -48, 48 do
		local cut = j / 8
		local lo, hi = 1, n+1
		while lo < hi do local mid = math.floor((lo+hi)/2); if sorted[mid] and sorted[mid] <= cut then lo = mid+1 else hi = mid end end
		local expected = m.number(m.div(m.erfc(m.div(m.new(-cut), sqrt_two)), two))
		largest = math.max(largest, math.abs((lo-1)/n - expected))
	end
	assert(largest < epsilon, "normal CDF outside DKW envelope")
	assert(math.abs(sum/n) < 0.02 and math.abs(squares/n - 1) < 0.03, "normal moments")
	io.write(("normal algorithm=%d n=%d CDF_error=%.6g envelope=%.6g mean=%.6g second_moment=%.6g\n"):format(algorithm, n, largest, epsilon, sum/n, squares/n))
end
io.write(("MPFR geometry/PDF/exp/ln max absolute errors: %.9g %.9g %.9g %.9g\n"):format(largest_area_error, largest_pdf_error, max_exp, max_ln))
