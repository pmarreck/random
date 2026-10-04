-- Scripted bytes independently control each Bernoulli decision and its cost.
local ffi = require("ffi")
local fx = require("fixed")
local counts = require("unsigned_count")
local geometric = require("geometric")
local function fixed(text) return fx.parse(text) end
local function source(bytes)
	local position, requests = 0, {}
	return function(count)
		requests[#requests + 1] = count
		assert(position + count <= #bytes, "scripted source exhausted")
		local result = bytes:sub(position + 1, position + count)
		position = position + count
		return result
	end, function() return position, requests end
end
local function sample(text, bytes)
	local read, position = source(bytes)
	local value = geometric.sample(geometric.prepare(fixed(text)), read)
	return counts.to_decimal(value), position()
end
assert(sample("1", "") == "0")
local value, position = sample("0.5", string.rep("\255", 16) .. string.rep("\0", 8))
assert(value == "2" and position == 24)
-- p=1/4 takes two block levels: 7/16, then 175/256. One base failure
-- and two set reconstruction bits produce 4*1+2+1, not 2*1+1.
value, position = sample("0.25", string.rep("\255", 8) .. string.rep("\0", 24))
assert(value == "7" and position == 32)
value, position = sample("0.25", string.rep("\0", 8) .. string.rep("\255", 16))
assert(value == "0" and position == 24)
-- Threshold comparison must preserve bits below binary64's mantissa.
local above_half = geometric.prepare(4611686018427387905LL, -1)
local read, cursor = source("\128\0\0\0\0\0\0\1")
assert(geometric.sample(above_half, read) == "" and cursor() == 8)
local below_half = geometric.prepare(4611686018427387903LL * 2LL, -2)
read, cursor = source("\128\0\0\0\0\0\0\0" .. string.rep("\0", 16))
assert(counts.to_decimal(geometric.sample(below_half, read)) == "1" and cursor() == 16)
for _, parameters in ipairs({{0LL, 0}, {-4611686018427387904LL, -1},
	{4611686018427387904LL, 1}, {1LL, 0}, {4611686018427387904LL, -1000001}}) do
	assert(not pcall(geometric.prepare, unpack(parameters)))
end
assert(not pcall(geometric.sample, geometric.prepare(fixed("0.5")), function() return "" end))
assert(not pcall(geometric.sample, geometric.prepare(fixed("0.5")), function() error("entropy failed") end))
for _, text in ipairs({"0.5", "5e-1", "1e-20", "2^-100", "2^0"}) do
	local m, e = geometric.parse_probability(text)
	assert(m and m > 0 and e <= 0, text)
end
local power_m, power_e = geometric.parse_probability("2^-100")
assert(power_m == 4611686018427387904LL and power_e == -100)
for _, text in ipairs({"0", "1e2", "2^1", "2^-1000001", "-0.1", "1e", "1e-0.5", "NaN"}) do
	assert(geometric.parse_probability(text) == nil, text)
end
-- Independent hardware-math oracle belongs only in tests. Avoid subtractive
-- cancellation in the oracle too, by summing the real log1p series for p<1/16.
local function chart_oracle(p, index, denominator)
	local logarithm
	if p < 1/16 then
		local power, sum = p, p
		for n = 2, 16 do power = power * p; sum = sum + power / n end
		logarithm = -sum
	else logarithm = math.log(1-p) end
	return math.floor(65535 * math.exp(logarithm * math.floor((6/p)*index/denominator)))
end
for _, text in ipairs({"0.25", "0.03125", "0.0625", "2^-30", "2^-62", "2^-63", "2^-100", "2^-1000"}) do
	local m, e = geometric.parse_probability(text)
	local p = tonumber(m) * 2^(e-62)
	local heights = require("distribution_view").curve("geometric", {m,e}, {0LL,0}, 9)
	for index = 0, 8 do
		local expected = chart_oracle(p, index, 8)
		assert(math.abs(heights[index+1]-expected) <= 1,
			text .. ": chart column " .. index .. " expected " .. expected .. " got " .. heights[index+1])
	end
end
assert(geometric.parse_probability(string.rep("0", 2001) .. ".5") == nil,
	"overlong decimal mantissa accepted")
print("Geometric scripted-source contracts passed")
