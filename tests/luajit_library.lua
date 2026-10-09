local drbg = require("drbg")
local b3 = require("blake3")
local fx = require("fixed")
local seed = string.rep("\0", 31) .. string.char(42)

if arg[1] == "--samples" or arg[1] == "--samples-pos" then
	local rng = drbg.new(seed)
	local emit = arg[1] == "--samples-pos" and function() end or print
	local op = arg[2]
	local p = {fx.from_int(tonumber(arg[3]))}
	local q = arg[4] and {fx.from_int(tonumber(arg[4]))} or nil
	for _ = 1, 8 do
		if op == "range" or op == "normal_int" then
			emit(string.format("%.0f", rng[op](rng, tonumber(arg[3]), tonumber(arg[4]))))
		elseif op == "poisson" then
			emit(string.format("%.0f", rng:poisson(p[1], p[2])))
		else
			local m, e
			if q then m, e = rng[op](rng, p[1], p[2], q[1], q[2])
			else m, e = rng[op](rng, p[1], p[2]) end
			if op == "normal" then
				emit(string.format("%.0f", require("distributions").round_to_int(m, e)))
			else emit(fx.tostring(m, e, 18)) end
		end
	end
	if arg[1] == "--samples-pos" then print(string.format("%.0f", rng:position())) end
	return
end

local function rejects(f) assert(not pcall(f)) end
local a, b = drbg.new(seed), drbg.new(seed)
local frozen = "69dfe2e9b579cf6dfe3d71b11024db6eb49d5b9861505b3ecfc3d379a6dc8f04" ..
	"b6900db333d20760661226da010db589c5080aaf5f6068fc0874ce62aca36f60"
assert(b3.bin_to_hex(a:bytes(64)) == frozen)
assert(b3.bin_to_hex(b:bytes(64)) == frozen)
assert(a:position() == 64 and b:position() == 64)
local parts = b:bytes(1) .. b:bytes(63) .. b:bytes(1023) .. b:bytes(1025)
assert(parts == a:bytes(2112))
local snapshot = a:state()
local resumed = drbg.from_state(snapshot)
snapshot.position = 0 -- exported tables cannot alter the original or resumed object
snapshot.key = string.rep("x", 32)
assert(a:bytes(131) == resumed:bytes(131))
local clone = a:clone()
assert(a:bytes(11) == clone:bytes(11))
local jumped = a:with_position(0)
assert(b3.bin_to_hex(jumped:bytes(64)) == frozen)
assert(a:position() == 2318)
assert(drbg.new(seed, 63):bytes(65) == drbg.new(seed):bytes(128):sub(64))
local exact = drbg.new(seed):uniform_number()
assert(exact == 0x69dfe2e9 / 4294967296)
assert(drbg.new(seed):u32() == 0x69dfe2e9)
local m, e = drbg.new(seed):uniform()
local am, ae = fx.from_int(0x69dfe2e9)
local bm, be = fx.from_int(4294967296)
local rm, re = fx.div(am, ae, bm, be)
assert(m == rm and e == re)
rejects(function() drbg.new(string.rep("\0", 31)) end)
rejects(function() drbg.new(seed, -1) end)
rejects(function() drbg.new(seed, 1.5) end)
rejects(function() drbg.new(seed, 9007199254740994) end)
rejects(function() drbg.new(seed, false) end)
local capped = drbg.new(seed, 9007199254740991)
assert(capped:bytes(0) == "")
for _, count in ipairs({-1, 0.5, math.huge, "4", 2}) do
	rejects(function() capped:bytes(count) end)
	assert(capped:position() == 9007199254740991)
end
assert(#capped:bytes(1) == 1)
assert(capped:position() == 9007199254740992)
rejects(function() capped:bytes(1) end)
local bounds = drbg.new(seed)
for _, interval in ipairs({{2, 1}, {0, 1.5}, {0, 9007199254740992}, {-9007199254740992, 9007199254740992}}) do
	rejects(function() bounds:range(interval[1], interval[2]) end)
	assert(bounds:position() == 0)
	if interval[1] == 2 or interval[2] == 1.5 then
		rejects(function() bounds:normal_int(interval[1], interval[2]) end)
		assert(bounds:position() == 0)
	end
end
for _, interval in ipairs({{-9007199254740994,0}, {0,9007199254740994},
	{9007199254740994,9007199254740994}}) do
	rejects(function() bounds:normal_int(interval[1], interval[2]) end)
	assert(bounds:position() == 0)
end
for _, interval in ipairs({{0,9007199254740992}, {-9007199254740992,9007199254740992},
	{-9007199254740992,1}}) do
	local value = drbg.new(seed):normal_int(interval[1], interval[2])
	assert(value >= interval[1] and value <= interval[2])
end
assert(bounds:range(7, 7) == 7 and bounds:position() == 0)
local one_m, one_e = fx.from_int(1)
local two_m, two_e = fx.from_int(2)
-- Independently frozen Ziggurat vectors pin full mantissas, not CLI rounding.
for _, vector in ipairs({
	{"normal", {0LL, 0, one_m, one_e}, -6358178992748390005LL, -1, 8},
	{"exponential", {one_m, one_e}, 8143522549336293876LL, -1, 4},
	{"log_normal", {0LL, 0, one_m, one_e}, 4629206882204335086LL, -1, 8},
	{"beta", {two_m, two_e, two_m, two_e}, 6877416081729278562LL, -2, 24},
}) do
	local rng = drbg.new(seed)
	local vm, ve = rng[vector[1]](rng, unpack(vector[2]))
	assert(vm == vector[3] and ve == vector[4], vector[1])
	assert(rng:position() == vector[5], vector[1])
end
for _, parameter in ipairs({{0.5, 0}, {"1", 0}, {one_m, 0.5}, {one_m, "0"},
	{1LL, 0}, {0LL, 1}, {-9223372036854775807LL - 1LL, 0},
	{one_m, 1000001}, {one_m, -1000001}, {one_m, 0/0}}) do
	rejects(function() bounds:exponential(parameter[1], parameter[2]) end)
	assert(bounds:position() == 0)
end
for _, invalid_call in ipairs({
	function() bounds:normal(0LL, 0, 0LL, 0) end,
	function() bounds:poisson(one_m, 20) end,
	function() bounds:log_normal(one_m, 28, one_m, one_e) end,
	function() bounds:log_normal(0LL, 0, one_m, 24) end,
	function() bounds:beta(one_m, -21, one_m, one_e) end,
	function() bounds:beta(one_m, one_e, one_m, 21) end,
}) do
	rejects(invalid_call)
	assert(bounds:position() == 0)
end
local caller_state = a:state()
local original_key, original_pos = caller_state.key, caller_state.position
drbg.from_state(caller_state):bytes(1)
assert(caller_state.key == original_key and caller_state.position == original_pos)
for _, field in ipairs({"bytes", "u32", "u64", "range", "uniform", "uniform_number", "normal_int", "normal", "exponential", "poisson", "log_normal", "beta"}) do
	assert(type(a[field]) == "function", field)
end
print("LuaJIT library unit contracts passed")
