-- Predeclared large-sample controls; uses independent libm/MPFR CDFs, RAM only.
package.path = "experiments/?.lua;" .. package.path
local ffi = require("ffi")
local m = require("mpfr")
ffi.cdef[[
typedef struct { int64_t m; int32_t e; } experiment_pair;
int experiment_samples(uint64_t, uint8_t, uint8_t, size_t, experiment_pair *);
void experiment_strip(uint8_t, experiment_pair *, experiment_pair *, uint64_t *);
double erfc(double);
]]
local lib = ffi.load(assert(arg[1], "experiment library required"))
local n = tonumber(arg[2]) or 2000000
assert(n >= 1000000, "large-sample analysis requires at least one million per seed")
local seeds = {42, 700, 123456789, 3735928559}
local names = {"Box-Muller", "paired-Box-Muller", "Ziggurat"}
-- Finite paired outputs have no established joint-independence theorem;
-- cached pairs also cross downstream rejection boundaries. Keep their frozen
-- thresholds as diagnostics, outside the IID target-law family calibration.
local alpha, family = 1e-6, 100000
local log_bound = math.log(2*family/alpha)
local epsilon = math.sqrt(math.log(2*48/alpha)/(2*n))
local control = arg[3]
assert(control == nil or control == "shift", "unknown statistical control")
local sqrt_two = math.sqrt(2)
local function cdf(x) return 0.5 * ffi.C.erfc(-x/sqrt_two) end
-- Confirm the faster diagnostic CDF against MPFR independently, including tails.
for j = -80, 80 do
	local x = j/8
	local exact = m.number(m.div(m.erfc(m.div(m.new(-x), m.sqrt(m.new(2)))), m.new(2)))
	assert(math.abs(cdf(x)-exact) < 2e-15, "diagnostic libm CDF disagrees with MPFR")
end
local function value(x) return tonumber(x.m) * 2^(tonumber(x.e)-62) end
local samples = ffi.new("experiment_pair[?]", n)
local zs, bins = ffi.new("double[?]", n), ffi.new("uint32_t[?]", n)
local function binomial(k, p, label)
	local expected = n*p
	local allowance = math.sqrt(2*n*p*(1-p)*log_bound) + 2*log_bound/3
	assert(math.abs(k-expected) <= allowance, label .. " count=" .. k .. " expected=" .. expected .. " bound=" .. allowance)
end
local function lower_bound(sorted, x)
	local lo, hi = 1, #sorted+1
	while lo < hi do local mid = math.floor((lo+hi)/2); if sorted[mid] and sorted[mid] <= x then lo = mid+1 else hi = mid end end
	return lo-1
end
io.write(("Predeclared analysis: n=%d per seed, 4 seeds, 3 algorithms, 4 shapes; DKW_family_alpha=%g; binomial_family_alpha=%g, count_family_bound=%d; combined_calibrated_bound=%g; DKW=%.6g; calibration covers only 32 unpaired cells under IID target-law nulls; 16 paired cells and moments/serial/collisions are uncalibrated diagnostics\n"):format(n, alpha, alpha, family, 2*alpha, epsilon))
for algorithm = 0, 2 do
	for _, seed in ipairs(seeds) do
		assert(lib.experiment_samples(seed, algorithm, 0, n, samples) == 0)
		local sorted, collisions = {}, {}
		local sum, squares, fourth, lag1, lag2, signs, zeros = 0, 0, 0, 0, 0, 0, 0
		for i = 0, n-1 do
			local z = (value(samples[i])+0.25)/1.75 + (control == "shift" and 0.02 or 0)
			assert(z == z and math.abs(z) < 13, "nonfinite/out-of-support sample")
			zs[i], sorted[i+1] = z, z
			sum, squares, fourth = sum+z, squares+z*z, fourth+z^4
			if i >= 1 then lag1 = lag1 + z*zs[i-1] end
			if i >= 2 then lag2 = lag2 + z*zs[i-2] end
			if z < 0 then signs = signs+1 end
			if z == 0 then zeros = zeros+1 end
			-- 32-bit CDF cells: rare occupancy collisions expose fine-grid defects.
			local cell = math.min(4294967295, math.floor(cdf(z)*4294967296))
			bins[i] = cell
		end
		table.sort(sorted)
		local max_cdf = 0
		for j = 1, n do
			local p = cdf(sorted[j])
			max_cdf = math.max(max_cdf, math.abs(j/n-p), math.abs((j-1)/n-p))
		end
		assert(max_cdf <= epsilon, "full normal KS/DKW gate")
		binomial(signs, 0.5, "sign balance")
		assert(math.abs(sum) < math.sqrt(2*n*log_bound), "normal mean")
		assert(math.abs(squares-n) < math.sqrt(4*n*log_bound)+169*2*log_bound/3, "normal second moment")
		assert(math.abs(fourth/n-3) < 0.15, "normal fourth moment (diagnostic threshold)")
		assert(math.abs(lag1/n) < 8/math.sqrt(n) and math.abs(lag2/n) < 8/math.sqrt(n), "serial covariance (diagnostic threshold)")
		local tail4, tail5 = 0,0
		for _, t in ipairs({1,2,3,4,5}) do
			local count = n - lower_bound(sorted,t) + lower_bound(sorted,-t)
			binomial(count, 2*cdf(-t), "two-sided tail " .. t)
			if t == 4 then tail4 = count elseif t == 5 then tail5 = count end
		end
		for i = 1,255 do
			local x, y, k = ffi.new("experiment_pair[1]"), ffi.new("experiment_pair[1]"), ffi.new("uint64_t[1]")
			lib.experiment_strip(i,x,y,k)
			local seam, width = value(x[0]), 0.01
			for _, s in ipairs({-1,1}) do
				for _, offset in ipairs({-width,0}) do
					local a = s*seam+offset
					binomial(lower_bound(sorted,a+width)-lower_bound(sorted,a), cdf(a+width)-cdf(a), "strip seam " .. i)
				end
			end
		end
		-- This is an occupancy diagnostic, not Doornik's 30-dimensional TestU01
		-- collision test. Count repeated 32-bit CDF cells with sparse RAM storage.
		local repeated = 0
		for i = 0,n-1 do local cell = tonumber(bins[i]); local count = collisions[cell] or 0; repeated = repeated+count; collisions[cell] = count+1 end
		local expected = n*(n-1)/(2*4294967296)
		assert(math.abs(repeated-expected) < 8*math.sqrt(expected)+32, "CDF-cell collision diagnostic")
		io.write(("%s seed=%d n=%d KS=%.6g mean=%.6g second=%.6g fourth=%.6g lag1=%.6g lag2=%.6g collisions=%d expected=%.2f zeros=%d tail4=%d tail5=%d\n"):format(names[algorithm+1],seed,n,max_cdf,sum/n,squares/n,fourth/n,lag1/n,lag2/n,repeated,expected,zeros,tail4,tail5))
		io.flush()
		-- Samples remain RAM-only; release Lua sort/hash tables between seeds.
		sorted, collisions = nil, nil
		collectgarbage("collect")
	end
end
-- Independent CDFs for downstream public shapes. These use benchmark defaults,
-- not every parameter in the library's domain. Count laws are judged directly.
local low = cdf((-0.5-127.5)/42.5)
local accepted = cdf((255.5-127.5)/42.5)-low
for algorithm = 0,2 do
	for op = 1,3 do
		for _, seed in ipairs(seeds) do
			assert(lib.experiment_samples(seed,algorithm,op,n,samples) == 0)
			local sorted = {}
			for i = 0,n-1 do
				local x = value(samples[i])
				if op == 1 then
					assert(x >= 0 and x <= 255 and x == math.floor(x), "normalized integer support")
				elseif op == 2 then
					assert(x > 0, "log-normal support")
					x = cdf((math.log(x)+0.25)/1.75)
				else
					assert(x >= 0 and x <= 1, "beta support")
					x = 1-(1-x)^3 -- independent Beta(1,3) CDF
				end
				sorted[i+1] = x
			end
			table.sort(sorted)
			local distance = 0
			if op == 1 then
				for j = 0,255 do
					local expected = (cdf((j+0.5-127.5)/42.5)-low)/accepted
					distance = math.max(distance,math.abs(lower_bound(sorted,j)/n-expected))
				end
			else
				for j = 1,n do distance = math.max(distance,math.abs(j/n-sorted[j]),math.abs((j-1)/n-sorted[j])) end
			end
			assert(distance <= epsilon, "downstream shape DKW gate op=" .. op)
			io.write(("%s op=%d seed=%d n=%d CDF_error=%.6g\n"):format(names[algorithm+1],op,seed,n,distance)); io.flush()
			sorted = nil; collectgarbage("collect")
		end
	end
end
io.write(("PASS: %d outputs across four shapes. This cannot certify sub-sampling-scale error or cryptographic security.\n"):format(48*n))
