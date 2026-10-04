-- LuaJIT exercises the public geometric C ABI without a compiled C harness.
local ffi = require("ffi")
local fx = require("fixed")
local oracle = require("drbg")
local counts = require("unsigned_count")
ffi.cdef[[
typedef struct { int64_t m; int32_t e; } geometric_fixed;
typedef int (*geometric_fill_fn)(void *, uint8_t *, size_t);
int randomz_geometric(geometric_fill_fn, void *, geometric_fixed,
 uint8_t *, size_t, size_t *);
int randomz_geometric_probability_parse(const char *, size_t, geometric_fixed *);
int randomz_count_format(const uint8_t *, size_t, uint8_t, uint32_t *, size_t,
 char *, size_t, size_t *);
int randomz_distribution_curve(int, geometric_fixed, geometric_fixed,
 uint16_t *, size_t, size_t *, geometric_fixed *, geometric_fixed *);
]]
local library = ffi.load(assert(arg[1]))
for _, exponent in ipairs({-30,-62,-63,-100,-1000}) do
	local heights, size = ffi.new("uint16_t[9]"), ffi.new("size_t[1]")
	local minimum, maximum = ffi.new("geometric_fixed[1]"), ffi.new("geometric_fixed[1]")
	assert(library.randomz_distribution_curve(6,
		ffi.new("geometric_fixed", {4611686018427387904LL, exponent}),
		ffi.new("geometric_fixed", {0,0}), heights, 9, size, minimum, maximum) == 0)
	assert(size[0] == 9)
	for index = 0, 8 do
		-- At these probabilities the exponential limit differs by <0.001
		-- height units. This test uses an independent hardware-math oracle.
		local expected = math.floor(65535 * math.exp(-0.75 * index))
		assert(math.abs(tonumber(heights[index]) - expected) <= 1,
			"geometric C ABI chart cancellation: exponent " .. exponent .. " column " .. index)
	end
end
local seed = string.rep("\0", 31) .. string.char(42)
for _, probability in ipairs({"0.5", "0.25", "1", "1e-20", "2^-100", "2^-1000"}) do
	local m, e = require("geometric").parse_probability(probability)
	local parsed = ffi.new("geometric_fixed[1]")
	assert(library.randomz_geometric_probability_parse(probability, #probability, parsed) == 0)
	assert(parsed[0].m == m and parsed[0].e == e, probability .. ": parsed probability")
	local left, right = oracle.new(seed), oracle.new(seed)
	local callback = ffi.cast("geometric_fill_fn", function(_, out, size)
		local ok, bytes = pcall(right.bytes, right, tonumber(size))
		if not ok then return 3 end
		ffi.copy(out, bytes, #bytes)
		return 0
	end)
	local output, written = ffi.new("uint8_t[4098]"), ffi.new("size_t[1]", 999)
	for _ = 1, 12 do
		ffi.fill(output, 4098, 0xA5)
		local status = library.randomz_geometric(callback, nil,
			ffi.new("geometric_fixed", {m, e}), output + 1, 4096, written)
		assert(status == 0, probability .. ": status " .. status)
		local value = left:geometric(m, e)
		local expected = counts.to_blip(value)
		assert(ffi.string(output + 1, written[0]) == expected, probability)
		local scratch, text, text_length = ffi.new("uint32_t[4096]"), ffi.new("char[12288]"), ffi.new("size_t[1]")
		for _, radix in ipairs({10,16}) do
			assert(library.randomz_count_format(output + 1, written[0], radix, scratch, 4096, text, 12288, text_length) == 0)
			assert(ffi.string(text, text_length[0]) == (radix == 10 and counts.to_decimal(value) or counts.to_hex(value)), probability .. ": formatted count")
		end
		assert(left:position() == right:position(), probability .. ": cursor")
		assert(output[0] == 0xA5 and output[4097] == 0xA5, "canary")
	end
	callback:free()
end
local requests = 0
local callback = ffi.cast("geometric_fill_fn", function() requests = requests + 1; return 2 end)
local output, written = ffi.new("uint8_t[16]"), ffi.new("size_t[1]", 999)
ffi.fill(output, 16, 0xA5)
assert(library.randomz_geometric(callback, nil, ffi.new("geometric_fixed", {0,0}), output, 16, written) == 1)
assert(requests == 0 and output[0] == 0xA5 and written[0] == 999)
local m, e = fx.parse("0.5")
assert(library.randomz_geometric(callback, nil, ffi.new("geometric_fixed", {m,e}), output, 16, written) == 2)
assert(requests == 1)
assert(written[0] == 0 and output[0] == 0xA5)
callback:free()
-- Raw magnitude can fit while its BLIP header does not. This is a late,
-- consumed-source error, not permission to retry or overwrite neighboring bytes.
requests = 0
callback = ffi.cast("geometric_fill_fn", function(_, bytes, size)
	requests = requests + 1
	ffi.fill(bytes, size, requests <= 128 and 255 or 0)
	return 0
end)
local guarded = ffi.new("uint8_t[3]", {0xA5,0xA5,0xA5})
assert(library.randomz_geometric(callback, nil, ffi.new("geometric_fixed", {m,e}), guarded+1, 1, written) == 4)
assert(requests == 129 and written[0] == 0 and guarded[0] == 0xA5 and guarded[2] == 0xA5)
callback:free()
-- No mutation/read on a statically insufficient buffer or missing pointer.
requests = 0
callback = ffi.cast("geometric_fill_fn", function(_, bytes, size)
	requests = requests + 1
	ffi.fill(bytes, size, 0)
	return requests == 2 and 2 or 0
end)
written[0] = 999
assert(library.randomz_geometric(callback, nil,
	ffi.new("geometric_fixed", {4611686018427387904LL,-100}), output, 1, written) == 4)
assert(requests == 0 and written[0] == 0 and output[0] == 0xA5)
assert(library.randomz_geometric(callback, nil, ffi.new("geometric_fixed", {m,e}), nil, 16, written) == 1)
assert(library.randomz_geometric(callback, nil, ffi.new("geometric_fixed", {m,e}), output, 16, nil) == 1)
assert(requests == 0)
-- A late callback failure must retain the error, not drop the sample and retry.
local quarter_m, quarter_e = fx.parse("0.25")
assert(library.randomz_geometric(callback, nil, ffi.new("geometric_fixed", {quarter_m,quarter_e}), output, 16, written) == 2)
assert(requests == 2 and written[0] == 0)
callback:free()
for _, malformed in ipairs({"", "\128", "\128\0", "\129\1", "\129\0", "\161\0\128", "\192\128", "\0\1"}) do
	local scratch, text = ffi.new("uint32_t[128]"), ffi.new("char[128]")
	ffi.fill(text, 128, 0xA5); written[0] = 999
	assert(library.randomz_count_format(malformed, #malformed, 10, scratch, 128, text, 128, written) == 1)
	assert(written[0] == 999 and ffi.cast("uint8_t *", text)[0] == 0xA5, "invalid BLIP mutated output")
end
print("Geometric C ABI matches LuaJIT values and byte cursors")
