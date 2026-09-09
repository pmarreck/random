-- Compare production batches to the unchanged scalar ABI, including every
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
for _, mode in ipairs({0, 1}) do
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
-- Force inner range rejection, outer normal-tail rejection, and then accepted
-- candidates. Stop at every read, preserving failed requests as well as values.
local draws = {4294967295, 0, 0, 999999, 0, 999999, 249999,
	0, 0, 999999, 749999, 999999, 999999, 500000, 500000}
for _, mode in ipairs({0,1}) do
	for stop = 0, #draws do
		local cursor, requests = 0, 0
		local scripted = ffi.cast("randomz_fill_fn", function(_, out, n)
			requests = requests + 1
			assert(n == 4, "draw size/order changed")
			if cursor >= stop then return 2 end
			cursor = cursor + 1
			local x = draws[cursor]
			for j = 3, 0, -1 do out[j] = x % 256; x = math.floor(x / 256) end
			return 0
		end)
		local expected, status = {}, 0
		for j = 1, 7 do
			status = lib.randomz_normal_int(scripted, nil, 0, 255, one)
			if status ~= 0 then break end
			expected[#expected+1] = tostring(one[0])
		end
		local expected_cursor, expected_requests = cursor, requests
		cursor, requests = 0, 0
		for j = 0, 6 do output[j] = -123456 end
		check(batch(scripted, nil, 0, 255, output, 7, written, mode) == status, "failure status")
		check(written[0] == #expected, "failure prefix count")
		check(cursor == expected_cursor and requests == expected_requests, "failure consumption")
		for j = 1, #expected do check(tostring(output[j-1]) == expected[j], "failure prefix") end
		for j = #expected, 6 do check(output[j] == -123456, "failure suffix changed") end
		scripted:free()
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
for _, mode in ipairs({0,1}) do
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
check(batch(fill, nil, 0, 255, output, 1, written, 2) == 1, "invalid backend")
check(state[0].state.position == pos, "invalid request consumed bytes")
fill:free()
print("Batch LuaJIT FFI passed: " .. checks .. " exact scalar, cursor, rejection, tail and error checks")
