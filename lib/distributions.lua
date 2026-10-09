-- Pure fixed-point samplers parameterized by a caller-owned byte source.
-- Evaluation and rejection order are shared by the library and CLI.
local fx = require("fixed")
local ziggurat = require("ziggurat")
local TWO32_M, TWO32_E = fx.from_int(4294967296)

local ONE_M, ONE_E = fx.from_int(1)
local TWO_M, TWO_E = fx.from_int(2)
local SIX_M, SIX_E = fx.from_int(6)
local HALF_M, HALF_E = fx.div(ONE_M, ONE_E, TWO_M, TWO_E)

-- Round a soft-float to the nearest integer (ties away from zero), then
-- truncate -- this kernel's ONE rounding rule (truncation toward zero)
-- composed with a SIGN-AWARE half-unit offset so the composite rounds
-- correctly in both directions. "Add 1/2, then truncate toward zero" is
-- round-half-away-from-zero ONLY for a non-negative input; for a negative
-- one it rounds one unit too HIGH (toward zero) instead, e.g.
-- -2.4 + 0.5 = -1.9, trunc = -1, not the correct -2 -- and even an exact
-- negative integer gets bumped: -50 + 0.5 = -49.5, trunc = -49.
--
-- The old, pre-kernel code used math.floor(v + 0.5) -- NOT actually
-- correct in both directions either, despite an earlier version of this
-- comment claiming so: math.floor rounds ties toward +infinity
-- unconditionally, which coincides with "away from zero" only for
-- non-negative v. For a negative tie it rounds one unit too HIGH (toward
-- zero), the identical direction of error the truncate-based formula
-- above has, just reached via a different mechanism: math.floor(-2.5 +
-- 0.5) == math.floor(-2.0) == -2, not the correct ties-away-from-zero -3.
-- Subtracting 1/2 for negative inputs before truncating fixes it: -2.4 -
-- 0.5 = -2.9, trunc = -2 (correct); -50 - 0.5 = -50.5, trunc = -50
-- (correct, exact integers pass through unchanged either way); -2.5 -
-- 0.5 = -3.0, trunc = -3 (correct tie-away-from-zero, unlike math.floor).
local function round_to_int(m, e)
	if m < 0 then
		m, e = fx.sub(m, e, HALF_M, HALF_E)
	else
		m, e = fx.add(m, e, HALF_M, HALF_E)
	end
	return fx.to_int_trunc(m, e)
end

-- Substitute for an exact-zero uniform draw (k=0 out of 2^32), which would
-- otherwise trip fx.ln's positive-argument assertion. The old math.log-based
-- code clamped any draw below 1e-6 (a lazy hack to dodge math.log(0)==-inf,
-- silently biasing roughly 1 in a million draws); ln is well-defined for
-- every OTHER draw all the way down to k=1 (~2.3e-10, ln ~= -22.18, well
-- inside this kernel's documented domain -- see lib/fixed.lua's top-of-file
-- comment), so only the exact-zero case needs a substitute now.
local MIN_UNIFORM_M, MIN_UNIFORM_E = fx.div(ONE_M, ONE_E, TWO32_M, TWO32_E)

-- Range-conditioned Ziggurat, with the same fixed-point scaling order in all ports.
local function normal_random_int(start_val, end_val, next_word)
	assert(type(start_val) == "number" and type(end_val) == "number" and
		start_val >= -9007199254740992 and end_val <= 9007199254740992 and
		start_val <= end_val and start_val == math.floor(start_val) and end_val == math.floor(end_val),
		"normal range bounds must be ordered exact integers within +/-2^53")
	local start_m, start_e = fx.from_int(start_val)
	local end_m, end_e = fx.from_int(end_val)
	-- Subtract in fixed point: widths above 2^53 can be odd, and cannot be
	-- computed exactly by a Lua binary64 subtraction of valid endpoints.
	local rng_m, rng_e = fx.sub(end_m, end_e, start_m, start_e)
	local sixth_m, sixth_e = fx.div(rng_m, rng_e, SIX_M, SIX_E)
	local half_range_m, half_range_e = fx.div(rng_m, rng_e, TWO_M, TWO_E)
	local result
	repeat
		local zm, ze = ziggurat.normal(next_word)
		-- start + z*(range/6) + range/2, rounded to nearest via round_to_int
		-- (sign-aware: see that function's own doc comment for why a plain
		-- "add 1/2, truncate toward zero" is wrong for negative results).
		local vm, ve = fx.mul(zm, ze, sixth_m, sixth_e)
		vm, ve = fx.add(vm, ve, half_range_m, half_range_e)
		vm, ve = fx.add(vm, ve, start_m, start_e)
		-- Canonical |x| >= 2^53+1/2 must not reach the saturating converter.
		if ve > 53 or (ve == 53 and
			(vm >= 4611686018427388160LL or vm <= -4611686018427388160LL)) then
			result = nil
		else result = round_to_int(vm, ve) end
	until result and result >= start_val and result <= end_val
	return result
end

-- Normal distribution with mean/stddev - returns a soft-float (m, e).
local function normal_random_float(mean_m, mean_e, sd_m, sd_e, next_word)
	local zm, ze = ziggurat.normal(next_word)
	local sm, se = fx.mul(zm, ze, sd_m, sd_e)
	return fx.add(mean_m, mean_e, sm, se)
end

-- Exponential distribution (rate given as a soft-float).
local function exponential_random(rate_m, rate_e, uniform_func)
	local um, ue = uniform_func()
	if um == 0 then um, ue = MIN_UNIFORM_M, MIN_UNIFORM_E end
	local lm, le = fx.ln(um, ue)
	local nm, ne = fx.neg(lm, le)
	return fx.div(nm, ne, rate_m, rate_e)
end

-- Poisson by SUM OF EXPONENTIALS rather than the old product form. The
-- product form (multiply uniforms until p <= e^-lambda) underflows any
-- fixed-width fraction: at lambda=20 the threshold is already 2e-9, well
-- past where a 62-bit product still carries any signal. Counting
-- exponential inter-arrivals (k = count of draws where the running sum of
-- -ln(u_i) first exceeds lambda) is the same Poisson distribution and
-- consumes the same number of uniforms per variate as the product form,
-- but stays well-conditioned across the entire useful lambda range.
local function poisson_random(lambda_m, lambda_e, uniform_func)
	local sum_m, sum_e = 0LL, 0
	local k = 0
	while true do
		local um, ue = uniform_func()
		if um == 0 then um, ue = MIN_UNIFORM_M, MIN_UNIFORM_E end
		local lm, le = fx.ln(um, ue)
		local nm, ne = fx.neg(lm, le)
		sum_m, sum_e = fx.add(sum_m, sum_e, nm, ne)
		if fx.cmp(sum_m, sum_e, lambda_m, lambda_e) > 0 then return k end
		k = k + 1
	end
end

-- Log-normal distribution - returns a soft-float (m, e).
local function lognormal_random(mu_m, mu_e, sigma_m, sigma_e, next_word)
	local nm, ne = normal_random_float(mu_m, mu_e, sigma_m, sigma_e, next_word)
	return fx.exp(nm, ne)
end

-- Gamma via Marsaglia-Tsang, with Ahrens-Dieter for alpha < 1. Returns a
-- soft-float (m, e).
local function gamma_random(alpha_m, alpha_e, uniform_func, next_word)
	if fx.cmp(alpha_m, alpha_e, ONE_M, ONE_E) < 0 then
		local um, ue = uniform_func()
		if um == 0 then um, ue = MIN_UNIFORM_M, MIN_UNIFORM_E end
		local am, ae = fx.add(ONE_M, ONE_E, alpha_m, alpha_e)
		local gm, ge = gamma_random(am, ae, uniform_func, next_word)
		local invm, inve = fx.div(ONE_M, ONE_E, alpha_m, alpha_e)
		local pm, pe = fx.pow(um, ue, invm, inve)
		return fx.mul(gm, ge, pm, pe)
	end
	-- Marsaglia and Tsang's method for alpha >= 1
	local third_m, third_e = fx.div(ONE_M, ONE_E, fx.from_int(3))
	local dm, de = fx.sub(alpha_m, alpha_e, third_m, third_e)
	local nine_m, nine_e = fx.from_int(9)
	local nine_d_m, nine_d_e = fx.mul(nine_m, nine_e, dm, de)
	local sq_m, sq_e = fx.sqrt(nine_d_m, nine_d_e)
	local cm, ce = fx.div(ONE_M, ONE_E, sq_m, sq_e)
	local c0331_m, c0331_e = fx.parse("0.0331")
	while true do
		local xm, xe, vm, ve
		repeat
			xm, xe = normal_random_float(0LL, 0, ONE_M, ONE_E, next_word)
			local t1m, t1e = fx.mul(cm, ce, xm, xe)
			vm, ve = fx.add(ONE_M, ONE_E, t1m, t1e)
		until fx.cmp(vm, ve, 0LL, 0) > 0
		local v3m, v3e = fx.mul(vm, ve, vm, ve)
		v3m, v3e = fx.mul(v3m, v3e, vm, ve)
		local um, ue = uniform_func()
		local x2m, x2e = fx.mul(xm, xe, xm, xe)
		local x4m, x4e = fx.mul(x2m, x2e, x2m, x2e)
		local bm, be = fx.mul(c0331_m, c0331_e, x4m, x4e)
		local limm, lime = fx.sub(ONE_M, ONE_E, bm, be)
		if fx.cmp(um, ue, limm, lime) < 0 then
			return fx.mul(dm, de, v3m, v3e)
		end
		if um ~= 0 then
			local lum, lue = fx.ln(um, ue)
			local lvm, lve = fx.ln(v3m, v3e)
			local h1m, h1e = fx.mul(HALF_M, HALF_E, x2m, x2e)
			local t2m, t2e = fx.sub(ONE_M, ONE_E, v3m, v3e)
			t2m, t2e = fx.add(t2m, t2e, lvm, lve)
			local t3m, t3e = fx.mul(dm, de, t2m, t2e)
			local rhs_m, rhs_e = fx.add(h1m, h1e, t3m, t3e)
			if fx.cmp(lum, lue, rhs_m, rhs_e) < 0 then
				return fx.mul(dm, de, v3m, v3e)
			end
		end
	end
end

-- Beta distribution using Gamma variates. Returns a soft-float (m, e).
local function beta_random(alpha_m, alpha_e, beta_m, beta_e, uniform_func, next_word)
	local xm, xe = gamma_random(alpha_m, alpha_e, uniform_func, next_word)
	local ym, ye = gamma_random(beta_m, beta_e, uniform_func, next_word)
	local sm, se = fx.add(xm, xe, ym, ye)
	return fx.div(xm, xe, sm, se)
end


return {
	round_to_int = round_to_int,
	normal_int = normal_random_int,
	normal = normal_random_float,
	exponential = exponential_random,
	poisson = poisson_random,
	log_normal = lognormal_random,
	gamma = gamma_random,
	beta = beta_random,
}
