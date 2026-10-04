-- Failures-before-success geometric counts with a caller-provided byte source.
-- Binary block decomposition preserves every result bit without logarithms,
-- cancellation at tiny probabilities, or a fixed-width count ceiling.
local ffi = require("ffi")
local fx = require("fixed")
local counts = require("unsigned_count")
local u64 = ffi.typeof("uint64_t")
local i64 = ffi.typeof("int64_t")
local ONE_M, ONE_E = fx.from_int(1)
local TWO_M, TWO_E = fx.from_int(2)
local HALF_M, HALF_E = fx.parse("0.5")
local M = {}

-- All sampled probabilities lie in [1/3,1), whose fixed dyadic thresholds
-- fit exactly in u64. Multiplication by two keeps all 64 threshold bits.
local function threshold(m, e)
	assert(m > 0 and e >= -2 and e <= -1, "geometric threshold is outside its domain")
	return ffi.new(u64, m) * (e == -1 and 2ULL or 1ULL)
end

-- Validate and prepare once; repeated sampling does not rebuild parameters.
-- For e<-62, the fixed recurrence is exactly q=2p and the low-bit probability
-- is exactly half. Defer those bits to one bounded byte read and one shift.
function M.prepare(m, e)
	assert(ffi.istype(i64, m) and m >= 4611686018427387904LL and
		m <= 9223372036854775807LL, "geometric probability must be canonical and positive")
	assert(type(e) == "number" and e == math.floor(e) and e >= -1000000 and
		e <= 0 and fx.cmp(m, e, ONE_M, ONE_E) <= 0,
		"geometric probability must be in (0,1] with a supported exponent")
	if fx.cmp(m, e, ONE_M, ONE_E) == 0 then return {certain = true, levels = {}, tail_bits = 0} end
	local prepared = {levels = {}, tail_bits = 0}
	if e < -62 then prepared.tail_bits = -62 - e; e = -62 end
	while fx.cmp(m, e, HALF_M, HALF_E) < 0 do
		local numerator_m, numerator_e = fx.sub(ONE_M, ONE_E, m, e)
		local denominator_m, denominator_e = fx.sub(TWO_M, TWO_E, m, e)
		local bit_m, bit_e = fx.div(numerator_m, numerator_e, denominator_m, denominator_e)
		prepared.levels[#prepared.levels + 1] = threshold(bit_m, bit_e)
		-- Exponent adjustment doubles exactly, including odd mantissas; the
		-- general same-sign add discards an odd low bit before normalization.
		local doubled_m, doubled_e = m, e + 1
		local square_m, square_e = fx.mul(m, e, m, e)
		m, e = fx.sub(doubled_m, doubled_e, square_m, square_e)
	end
	prepared.base = threshold(m, e)
	return prepared
end

-- Keep tiny-probability syntax local to this new mode. Ordinary decimal
-- mantissas retain fixed.parse's existing precision; scientific scaling uses
-- integer fixed multiply/divide, and 2^N supplies an exact binary exponent.
-- No existing distribution parser or deterministic stream is changed.
function M.parse_probability(text)
	if type(text) ~= "string" then return nil end
	local ok, m, e = pcall(function()
		local function decimal(value)
			local integer = value:match("^%s*[+-]?(%d*)")
			assert(integer and #integer <= 2000, "geometric decimal mantissa is too long")
			return fx.parse(value)
		end
		local binary_exponent = text:match("^2%^([+-]?%d+)$")
		local mantissa, decimal_exponent = text:match("^([%d.]+)[eE]([+-]?%d+)$")
		local pm, pe
		if binary_exponent then
			local exponent = fx.parse_int_safe(binary_exponent)
			assert(exponent and exponent >= -1000000 and exponent <= 0,
				"geometric binary exponent is outside its domain")
			pm, pe = ONE_M, exponent
		elseif mantissa then
			pm, pe = decimal(mantissa)
			local exponent = fx.parse_int_safe(decimal_exponent)
			assert(pm and exponent and math.abs(exponent) <= 1000000,
				"geometric scientific probability is invalid")
			local factor_m, factor_e = fx.from_int(10)
			local multiplier_m, multiplier_e = ONE_M, ONE_E
			local remaining = math.abs(exponent)
			while remaining > 0 do
				if remaining % 2 == 1 then
					multiplier_m, multiplier_e = fx.mul(multiplier_m, multiplier_e, factor_m, factor_e)
				end
				remaining = math.floor(remaining / 2)
				if remaining > 0 then factor_m, factor_e = fx.mul(factor_m, factor_e, factor_m, factor_e) end
			end
			if exponent < 0 then pm, pe = fx.div(pm, pe, multiplier_m, multiplier_e)
			else pm, pe = fx.mul(pm, pe, multiplier_m, multiplier_e) end
		else
			pm, pe = decimal(text)
		end
		assert(pm, "geometric probability is invalid")
		M.prepare(pm, pe)
		return pm, pe
	end)
	if not ok then return nil end
	return m, e
end

-- Decode explicit big-endian draws; native-endian casts would change streams.
local function draw(read)
	local bytes = read(8)
	assert(type(bytes) == "string" and #bytes == 8, "geometric byte source must fill exactly eight bytes")
	local value = 0ULL
	for index = 1, 8 do value = value * 256ULL + bytes:byte(index) end
	return value
end

-- If G~Geom(p), floor(G/2)~Geom(2p-p²), independently of G mod 2,
-- whose success probability is (1-p)/(2-p). Invert that decomposition.
-- Fixed recurrence rounding is part of the portable distribution contract;
-- these exact integer outputs do not imply exact real-valued probabilities.
function M.sample(prepared, read)
	if prepared.certain then return "" end
	local value = ""
	while draw(read) >= prepared.base do value = counts.increment(value) end
	for index = #prepared.levels, 1, -1 do
		value = counts.double_add(value, draw(read) < prepared.levels[index] and 1 or 0)
	end
	if prepared.tail_bits ~= 0 then
		local length = math.floor((prepared.tail_bits + 7) / 8)
		local low = read(length)
		assert(type(low) == "string" and #low == length,
			"geometric byte source must fill the complete low-bit span")
		value = counts.append_low_bits(value, low, prepared.tail_bits)
	end
	return value
end

return M
