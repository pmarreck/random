-- Caller-owned BLAKE3 keyed-XOF streams, compatible with Zig, Rust and Lean.
-- Instances capture private stream state; importing the module performs no I/O.
local ffi = require("ffi")
local b3 = require("blake3")
local fx = require("fixed")
local distributions = require("distributions")
local geometric = require("geometric")
local u64 = ffi.typeof("uint64_t")
local i64 = ffi.typeof("int64_t")
local LIMIT = 9007199254740992
local CONTEXT = "random drbg 2026-08-04 v1"
local TWO32_M, TWO32_E = fx.from_int(4294967296)
local M = {version = "0.3.0", max_position = LIMIT}

local function exact_position(value)
	assert(type(value) == "number" and value >= 0 and value <= LIMIT and
		value == math.floor(value), "DRBG position/count must be an exact integer in [0, 2^53]")
	return value
end

local function key_bytes(value)
	assert(type(value) == "string" and #value == 32, "DRBG key/seed material must contain exactly 32 bytes")
	return value
end

local function fixed_parameter(m, e, positive)
	-- Reject malformed inputs before normalization (fractional mantissas can
	-- truncate to zero inside the kernel's normalization loop).
	assert(ffi.istype(i64, m) or (type(m) == "number" and m == 0),
		"distribution mantissa must be int64_t (or numeric zero)")
	assert(type(e) == "number" and e == math.floor(e), "distribution exponent must be an integer")
	assert((m == 0 and e == 0) or (m ~= (-9223372036854775807LL - 1LL) and
		(m >= 4611686018427387904LL or m <= -4611686018427387904LL)),
		"distribution parameter must be canonical")
	assert(not positive or m > 0, "distribution scale/shape/rate must be positive")
	assert(e >= -1000000 and e <= 1000000, "distribution exponent is outside the supported domain")
end

local function range_span(first, last)
	assert(type(first) == "number" and type(last) == "number" and
		math.abs(first) <= LIMIT and math.abs(last) <= LIMIT and
		first == math.floor(first) and last == math.floor(last) and first <= last,
		"range bounds must be ordered exact integers within +/-2^53")
	-- Every accepted difference is an exact binary64 integer. A difference
	-- >= 2^53 cannot round below that threshold, so reject before adding one.
	local width = last - first
	assert(width < LIMIT, "an inclusive integer range may contain at most 2^53 values")
	return width + 1
end

-- Restoration copies the caller's fields; later draws never mutate its table.
function M.from_state(state)
	assert(type(state) == "table", "DRBG state must be a table")
	local key = key_bytes(state.key)
	local position = exact_position(state.position)
	local stream = b3.blake3("", key, -1)
	if position ~= 0 then stream("seek", position) end
	local rng = {}

	function rng:position() return position end
	function rng:state() return {key = key, position = position} end
	function rng:clone() return M.from_state(self:state()) end
	function rng:with_position(next_position)
		return M.from_state({key = key, position = next_position})
	end

	-- Validate before touching the XOF, including zero-length reads at the cap.
	function rng:bytes(count)
		exact_position(count)
		assert(position <= LIMIT - count,
			"BLAKE3 DRBG byte position exceeds the Lua oracle's exact-integer limit")
		local bytes = b3.hex_to_bin(stream(count))
		position = position + count
		return bytes
	end

	function rng:u32()
		local bytes, value = self:bytes(4), 0
		for i = 1, 4 do value = value * 256 + bytes:byte(i) end
		return value
	end

	function rng:u64()
		local bytes, value = self:bytes(8), ffi.new(u64, 0)
		for i = 1, 8 do value = value * 256 + bytes:byte(i) end
		return value
	end

	-- Rejection preserves unbiased mapping and the portable byte-consumption order.
	function rng:range(first, last)
		local span = range_span(first, last)
		if span == 1 then return first end
		if span <= 4294967296 then
			local bound = 4294967296 - (4294967296 % span)
			while true do
				local draw = self:u32()
				if draw < bound then return first + draw % span end
			end
		end
		local width = ffi.new(u64, span)
		local remainder = (ffi.new(u64, 0) - width) % width
		local bound = ffi.new(u64, 0) - remainder
		while true do
			local draw = self:u64()
			if remainder == 0 or draw < bound then return first + tonumber(draw % width) end
		end
	end

	-- Fixed-point pairs retain the library's integer-only distribution precision.
	function rng:uniform()
		local m, e = fx.from_int(self:u32())
		return fx.div(m, e, TWO32_M, TWO32_E)
	end

	-- k/2^32 is exactly representable as a Lua number, without decimal rounding.
	function rng:uniform_number() return self:u32() / 4294967296 end

	function rng:normal_int(first, last)
		range_span(first, last)
		return distributions.normal_int(first, last, function(a, b) return self:range(a, b) end)
	end

	function rng:normal(mm, me, sm, se)
		fixed_parameter(mm, me, false)
		fixed_parameter(sm, se, true)
		return distributions.normal(mm, me, sm, se, function() return self:uniform() end)
	end
	function rng:exponential(m, e)
		fixed_parameter(m, e, true)
		return distributions.exponential(m, e, function() return self:uniform() end)
	end
	function rng:poisson(m, e)
		fixed_parameter(m, e, true)
		assert(e <= 19, "poisson lambda is outside the supported domain")
		return distributions.poisson(m, e, function() return self:uniform() end)
	end
	function rng:log_normal(mm, me, sm, se)
		fixed_parameter(mm, me, false)
		fixed_parameter(sm, se, true)
		assert(me <= 27 and se <= 23, "log-normal parameters are outside the supported domain")
		return distributions.log_normal(mm, me, sm, se, function() return self:uniform() end)
	end
	function rng:beta(am, ae, bm, be)
		fixed_parameter(am, ae, true)
		fixed_parameter(bm, be, true)
		assert(ae >= -20 and ae <= 20 and be >= -20 and be <= 20,
			"beta parameters are outside the supported domain")
		return distributions.beta(am, ae, bm, be, function() return self:uniform() end)
	end
	-- Return canonical unsigned magnitude bytes; decimal/BLIP formatting is a
	-- separate pure operation, so large gaps never pass through Lua numbers.
	function rng:geometric(m, e)
		local prepared = geometric.prepare(m, e)
		return geometric.sample(prepared, function(count) return self:bytes(count) end)
	end
	return rng
end

-- Seed material is the canonical 32-byte unsigned big-endian value used by all ports.
function M.new(seed_material, position)
	if position == nil then position = 0 end
	key_bytes(seed_material)
	exact_position(position)
	local key = b3.hex_to_bin(b3.blake3_derive_key(seed_material, CONTEXT, 32))
	return M.from_state({key = key, position = position})
end

return M
