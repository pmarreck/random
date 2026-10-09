-- Compare production batches to the sequential scalar ABI, including every
-- read-failure boundary. Payloads and scripted entropy stay in memory.
local ffi = require("ffi")
ffi.cdef[[
typedef struct { uint8_t key[32]; uint64_t position; } randomz_drbg;
typedef struct {
	randomz_drbg state; uint8_t cache[1024]; uint64_t cache_start; uint64_t cache_len;
} randomz_buffered_drbg;
typedef int (*randomz_fill_fn)(void *, uint8_t *, size_t);
int randomz_buffered_drbg_init(randomz_buffered_drbg *, const uint8_t *);
int randomz_buffered_drbg_seek(randomz_buffered_drbg *, uint64_t);
int randomz_buffered_drbg_fill(randomz_buffered_drbg *, uint8_t *, size_t);
int randomz_normal_int(randomz_fill_fn, void *, int64_t, int64_t, int64_t *);
int randomz_normal_int_batch(randomz_fill_fn, void *, int64_t, int64_t,
	int64_t *, size_t, size_t *, int);
]]
local lib = ffi.load(assert(arg[1], "shared library path required"))
local seed = ffi.new("uint8_t[32]")
local state = ffi.new("randomz_buffered_drbg[1]")
local output = ffi.new("int64_t[257]")
local one = ffi.new("int64_t[1]")
local written = ffi.new("size_t[1]")
local checks = 0
local function check(ok, what)
	checks = checks + 1
	assert(ok, what)
end
local fill = ffi.cast("randomz_fill_fn", function(_, out, n)
	return lib.randomz_buffered_drbg_fill(state, out, n)
end)
-- Resolve the new symbol first: old libraries must fail this control.
local batch = lib.randomz_normal_int_batch
-- Expectations derived independently of the scalar implementation: neither
-- scalar nor SIMD may turn an out-of-domain candidate into a clipped endpoint.
for _, negative in ipairs({false, true}) do
	local tail = negative and 18446744073709551360ULL or 18446744073709551104ULL
	for _, bounds in ipairs({{-9007199254740992,9007199254740992},
		negative and {-9007199254740992,-9007199254740982} or {9007199254740982,9007199254740992}}) do
		local midpoint = bounds[1] / 2 + bounds[2] / 2
		for _, mode in ipairs({-1,0,1,2}) do
			for _, scenario in ipairs({{0,1,false}, {0,4,false}, {0,1,true}, {0,4,true}, {2,7,true}}) do
				local prefix, count, fail_source = unpack(scenario)
				if mode ~= -1 or count == 1 then
					local words = {}
					for _ = 1, prefix do words[#words+1] = 0ULL end
					words[#words+1] = tail
					words[#words+1] = 18446744073709551104ULL
					words[#words+1] = 18446744073709551104ULL
					if not fail_source then
						for _ = 1, count do words[#words+1] = 0ULL end
					end
					local cursor, calls = 0, 0
					local scripted = ffi.cast("randomz_fill_fn", function(_, bytes, size)
						calls = calls+1
						assert(size == 8)
						local word = words[cursor/8+1]
						if not word then return 3 end
						for j = 7, 0, -1 do bytes[j] = tonumber(word % 256ULL); word = word / 256ULL end
						cursor = cursor+8
						return 0
					end)
					for j = 0, count do output[j] = -123456 end
					local status, completed
					if mode == -1 then
						status = lib.randomz_normal_int(scripted, nil, bounds[1], bounds[2], output)
						completed = status == 0 and 1 or 0
					else
						status = batch(scripted, nil, bounds[1], bounds[2], output, count, written, mode)
						completed = tonumber(written[0])
					end
					check(status == (fail_source and 3 or 0), "independent endpoint status")
					check(completed == (fail_source and prefix or count), "independent endpoint prefix")
					local expected_bytes = (prefix+3+(fail_source and 0 or count))*8
					check(cursor == expected_bytes and calls == expected_bytes/8+(fail_source and 1 or 0),
						"independent endpoint source effects")
					for j = 0, completed-1 do check(output[j] == midpoint, "endpoint was clamped") end
					for j = completed, count do check(output[j] == -123456, "endpoint suffix changed") end
					scripted:free()
				end
			end
		end
	end
end
for _, bounds in ipairs({{-9007199254740993LL,0}, {0,9007199254740993LL},
	{9007199254740993LL,9007199254740993LL}, {-9007199254740993LL,-9007199254740993LL}}) do
	local calls = 0
	local forbidden = ffi.cast("randomz_fill_fn", function() calls = calls+1; return 3 end)
	one[0] = -123456
	check(lib.randomz_normal_int(forbidden, nil, bounds[1], bounds[2], one) == 1,
		"invalid scalar endpoint must fail before sampling")
	check(calls == 0 and one[0] == -123456, "invalid scalar endpoint changed source/output")
	forbidden:free()
end
for _, mode in ipairs({0, 1, 2}) do
	for s = 0, 15 do
		seed[31] = s
		for _, bounds in ipairs({{0,255}, {-17,981}, {7,7}, {-9007199254740992,0},
			{0,9007199254740992}, {-9007199254740992,9007199254740992}}) do
			for _, n in ipairs({0,1,2,3,4,5,7,8,9,31,64,257}) do
				assert(lib.randomz_buffered_drbg_init(state, seed) == 0)
				local expected = {}
				for j = 1, n do
					assert(lib.randomz_normal_int(fill, nil, bounds[1], bounds[2], one) == 0)
					expected[j] = tostring(one[0])
				end
				local position = state[0].state.position
				assert(lib.randomz_buffered_drbg_init(state, seed) == 0)
				ffi.fill(output, ffi.sizeof(output), 0x5a)
				check(batch(fill, nil, bounds[1], bounds[2], output, n, written, mode) == 0, "batch status")
				check(written[0] == n and state[0].state.position == position, "batch cursor/count")
				for j = 1, n do check(tostring(output[j-1]) == expected[j], "batch scalar value") end
			end
		end
	end
end
-- Explicit Ziggurat witnesses: both tail signs with local retry, and a wedge
-- rejection requiring a fresh strip. Fail at every byte, including partial
-- callbacks, and compare complete source effects and untouched output suffixes.
local streams = {
	{18446744073709551104ULL, 0ULL, 18446744073709551104ULL,
		18446744073709551104ULL, 18446744073709551104ULL},
	{18446744073709551360ULL, 0ULL, 18446744073709551104ULL,
		18446744073709551104ULL, 18446744073709551104ULL},
	{18446744073709551105ULL, 18446744073709551104ULL, 0ULL},
}
for _, words in ipairs(streams) do
	local bytes = ffi.new("uint8_t[104]")
	for i, word in ipairs(words) do
		for j = 7, 0, -1 do
			bytes[(i-1)*8+j] = tonumber(word % 256ULL); word = word / 256ULL
		end
	end
	for _, bounds in ipairs({{0,255}, {-17,981}, {5,5},
		{-9007199254740992,-9007199254740992}, {-9007199254740992,9007199254740992}}) do
		for _, n in ipairs({0,1,3,4,7,9}) do
			for stop = 0, 104 do
				local cursor, requests = 0, {}
				local scripted = ffi.cast("randomz_fill_fn", function(_, out, size)
					size = tonumber(size)
					requests[#requests+1] = size
					assert(size == 8, "Ziggurat word boundary changed")
					for j = 0, size-1 do
						if cursor == stop then return 2 end
						out[j] = bytes[cursor]; cursor = cursor+1
					end
					return 0
				end)
				local expected, status = {}, 0
				for j = 1, n do
					status = lib.randomz_normal_int(scripted, nil, bounds[1], bounds[2], one)
					if status ~= 0 then break end
					expected[#expected+1] = tostring(one[0])
				end
				local expected_cursor, expected_requests = cursor, table.concat(requests, ",")
				for _, mode in ipairs({0,1,2}) do
					cursor, requests = 0, {}
					for j = 0, n do output[j] = -123456 end
					check(batch(scripted, nil, bounds[1], bounds[2], output, n, written, mode) == status, "failure status")
					check(written[0] == #expected, "failure prefix count")
					check(cursor == expected_cursor and table.concat(requests, ",") == expected_requests, "failure read effects")
					for j = 1, #expected do check(tostring(output[j-1]) == expected[j], "failure prefix") end
					for j = #expected, n do check(output[j] == -123456, "failure suffix changed") end
				end
				scripted:free()
			end
		end
	end
end
for offset = 0, 39 do
	local cap = 9007199254740992ULL
	assert(lib.randomz_buffered_drbg_seek(state, cap-offset) == 0)
	local expected, status = {}, 0
	for j = 1, 7 do
		status = lib.randomz_normal_int(fill, nil, 0, 255, one)
		if status ~= 0 then break end
		expected[#expected+1] = tostring(one[0])
	end
	local pos = state[0].state.position
	assert(lib.randomz_buffered_drbg_seek(state, cap-offset) == 0)
	check(batch(fill, nil, 0, 255, output, 7, written, 0) == status, "cap status")
	check(written[0] == #expected and state[0].state.position == pos, "cap cursor/prefix")
	for j = 1, #expected do check(tostring(output[j-1]) == expected[j], "cap value") end
end
local pos = state[0].state.position
for _, mode in ipairs({0,1,2}) do
	for _, n in ipairs({0,1,4,5}) do
		for _, bounds in ipairs({{-9007199254740993LL,0}, {0,9007199254740993LL},
			{9007199254740993LL,9007199254740993LL},
			{-9007199254740993LL,-9007199254740993LL}}) do
			output[0] = -123456
			check(batch(fill, nil, bounds[1], bounds[2], output, n, written, mode) == 1,
				"outside exact-integer batch domain must fail")
			check(written[0] == 0 and output[0] == -123456 and state[0].state.position == pos,
				"invalid domain changed output/source")
		end
	end
end
check(batch(fill, nil, 1, 0, output, 0, written, 0) == 1 and written[0] == 0, "invalid empty range")
check(batch(fill, nil, 0, 255, nil, 0, written, 0) == 0, "empty null output")
check(batch(fill, nil, 0, 255, nil, 1, written, 0) == 1, "null output")
check(batch(nil, nil, 0, 255, output, 1, written, 0) == 1, "null callback")
check(batch(fill, nil, 0, 255, output, 1, nil, 0) == 1, "null count")
check(batch(fill, nil, 0, 255, output, 1, written, 3) == 1, "invalid backend")
check(state[0].state.position == pos, "invalid request consumed bytes")
fill:free()
print("Batch LuaJIT FFI passed: " .. checks .. " exact scalar, cursor, rejection, tail and error checks")
