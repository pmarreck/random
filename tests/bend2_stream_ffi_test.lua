-- Independent controls for core-owned batch plans, weighted decisions and
-- shuffle indices. Callback request order is part of the portable contract.
local ffi = require('ffi')
package.path = './lib/?.lua;' .. package.path
local drbg = require('drbg')
local invoke = dofile('tests/ffi_callback.lua')
ffi.cdef[[
typedef int (*bend_fill)(void *,uint8_t *,size_t);
int randomb_weighted_total(const int64_t *,size_t,int64_t *,uint8_t *);
int randomb_weighted_index(bend_fill,void *,const int64_t *,size_t,int64_t *,uint8_t *);
int randomb_shuffle_indices(bend_fill,void *,int64_t *,size_t,size_t *);
int randomb_normal_int_batch(bend_fill,void *,int64_t,int64_t,int64_t *,size_t,size_t *,int);
int randomz_normal_int_batch(bend_fill,void *,int64_t,int64_t,int64_t *,size_t,size_t *,int);
]]
local lib = ffi.load(assert(arg[1], 'Bend library required'))
local z = ffi.load(assert(arg[2], 'Zig oracle library required'))
local seed = string.rep('\0', 31) .. string.char(42)
local checks = 0
local canary = -6510615555426900571LL
local function callback_for(rng)
	return ffi.cast('bend_fill', function(_, dst, n)
		local bytes = rng:bytes(tonumber(n)); ffi.copy(dst, bytes, #bytes); return 0
	end)
end
for _, weights in ipairs({{1}, {0,1,0}, {1,3,0}, {100,1,7,0,2}, {9007199254740992LL}}) do
	local input = ffi.new('int64_t[?]', #weights, weights)
	local total, index, reason = ffi.new('int64_t[1]'), ffi.new('int64_t[1]'), ffi.new('uint8_t[1]', 99)
	assert(lib.randomb_weighted_total(input, #weights, total, reason) == 0 and reason[0] == 0)
	local left, right = drbg.new(seed), drbg.new(seed)
	local callback = callback_for(right)
	for _ = 1, 32 do
		assert(invoke(lib, 'randomb_weighted_index', callback, nil, input, #weights, index, reason) == 0 and reason[0] == 0)
		local pick = left:range(1, tonumber(total[0]))
		local cumulative, expected = 0LL, 0
		for i, weight in ipairs(weights) do
			cumulative = cumulative + weight
			if pick <= cumulative then expected = i-1; break end
		end
		assert(index[0] == expected and left:position() == right:position())
		checks = checks + 1
	end
	callback:free()
end
for _, count in ipairs({0,1,2,3,20,129,4096}) do
	local out, written = ffi.new('int64_t[?]', count+2), ffi.new('size_t[1]')
	local left, right = drbg.new(seed), drbg.new(seed)
	local callback = callback_for(right)
	for _ = 1, 4 do
		ffi.fill(out, ffi.sizeof(out), 0xa5); written[0] = 999
		assert(invoke(lib, 'randomb_shuffle_indices', callback, nil, out+1, count, written) == 0 and written[0] == count)
		local expected = {}; for i = 1, count do expected[i] = i-1 end
		for i = count, 2, -1 do local j = left:range(1, i); expected[i], expected[j] = expected[j], expected[i] end
		for i = 1, count do assert(out[i] == expected[i]) end
		assert(out[0] == canary and out[count+1] == canary and left:position() == right:position())
		checks = checks + 1
	end
	callback:free()
end
local calls = 0
local callback = ffi.cast('bend_fill', function() calls = calls+1; return 99 end)
local output, reason = ffi.new('int64_t[1]', 789), ffi.new('uint8_t[1]', 99)
for _, case in ipairs({{{},4}, {{0,0},3}, {{-1,2},1}, {{9007199254740992LL,1},2}}) do
	local weights = ffi.new('int64_t[?]', math.max(1, #case[1]), case[1])
	assert(invoke(lib, 'randomb_weighted_index', callback, nil, weights, #case[1], output, reason) == 1)
	assert(output[0] == 789 and reason[0] == case[2] and calls == 0)
	checks = checks + 1
end
assert(invoke(lib, 'randomb_weighted_index', callback, nil, ffi.new('int64_t[2]', {1,3}), 2, output, reason) == 2)
assert(output[0] == 789 and calls == 1)
callback:free()
checks = checks + 1
assert(checks == 193)
local values, written = ffi.new('int64_t[131]'), ffi.new('size_t[1]')
local bounds = {{0LL,99LL}, {1LL,20LL}, {7LL,7LL}, {-9007199254740992LL,9007199254740992LL},
	{0LL,9007199254740992LL}, {9007199254740992LL,9007199254740992LL},
	{2LL,1LL}, {-9007199254740993LL,0LL}, {0LL,9007199254740993LL}}
for _, range in ipairs(bounds) do
	for _, count in ipairs({0,1,3,4,5,7,8,9,96,129}) do
		for _, mode in ipairs({-1,0,1,2,3}) do
			for _, failure in ipairs({0,1,3,9}) do
				local function measure(library, prefix)
					local rng, requests, call_count = drbg.new(seed), {}, 0
					local fill = ffi.cast('bend_fill', function(_, out, n)
						call_count = call_count+1; requests[#requests+1] = tonumber(n)
						if call_count == failure then ffi.fill(out, n, 0x11); return 3 end
						local bytes = rng:bytes(tonumber(n)); ffi.copy(out, bytes, #bytes); return 0
					end)
					ffi.fill(values, ffi.sizeof(values), 0xa5); written[0] = 999
					local status = invoke(library, prefix .. 'normal_int_batch', fill, nil, range[1], range[2], values+1, count, written, mode)
					fill:free()
					assert(values[0] == canary and values[count+1] == canary)
					return {status, tonumber(written[0]), ffi.string(values, ffi.sizeof(values)), table.concat(requests, ','), rng:position()}
				end
				local a, b = measure(z, 'randomz_'), measure(lib, 'randomb_')
				for i = 1, #a do assert(a[i] == b[i], 'batch case=' .. checks .. ' field=' .. i .. ' mode=' .. mode) end
				checks = checks + 1
			end
		end
	end
end
assert(checks == 1993)
print('Bend stream C ABI: ' .. checks .. ' exact selection/batch, callback order, cursor, refusal and prefix checks passed')
