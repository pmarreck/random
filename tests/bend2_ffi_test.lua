-- Directly exercise the owned native Bend C ABI; LuaJIT is the independent
-- numerical oracle, not a compiled C harness or another RNG behind the ABI.
package.path = './lib/?.lua;' .. package.path
local ffi = require('ffi')
local drbg = require('drbg')
local fx = require('fixed')
local count = require('unsigned_count')
local invoke = dofile('tests/ffi_callback.lua')
ffi.cdef[[
typedef struct { int64_t m; int32_t e; } randomb_fixed;
typedef struct { uint8_t key[32]; uint64_t position; } randomb_drbg;
typedef int (*randomb_fill_fn)(void *, uint8_t *, size_t);
int randomb_drbg_init(randomb_drbg *, const uint8_t *);
int randomb_drbg_set_state(randomb_drbg *, const uint8_t *, uint64_t);
int randomb_drbg_seek(randomb_drbg *, uint64_t);
int randomb_drbg_fill(randomb_drbg *, uint8_t *, size_t);
int randomb_normal(randomb_fill_fn, void *, randomb_fixed, randomb_fixed, randomb_fixed *);
int randomb_exponential(randomb_fill_fn, void *, randomb_fixed, randomb_fixed *);
int randomb_log_normal(randomb_fill_fn, void *, randomb_fixed, randomb_fixed, randomb_fixed *);
int randomb_beta(randomb_fill_fn, void *, randomb_fixed, randomb_fixed, randomb_fixed *);
int randomb_poisson(randomb_fill_fn, void *, randomb_fixed, int64_t *);
int randomb_range(randomb_fill_fn, void *, int64_t, int64_t, int64_t *);
int randomb_normal_int(randomb_fill_fn, void *, int64_t, int64_t, int64_t *);
int randomb_geometric(randomb_fill_fn, void *, randomb_fixed, uint8_t *, size_t, size_t *);
int randomb_count_format(const uint8_t *, size_t, uint8_t, uint32_t *, size_t, char *, size_t, size_t *);
int randomb_debug_heap_pages(uint64_t *);
]]
local lib = ffi.load(assert(arg[1], 'native Bend library path required'))
local seed = string.rep('\0', 31) .. '\42'
local seed_buffer = ffi.new('uint8_t[32]')
ffi.copy(seed_buffer, seed, 32)
local state = ffi.new('randomb_drbg[1]')
assert(lib.randomb_drbg_init(state, seed_buffer) == 0)
local oracle = drbg.new(seed)
local buffer = ffi.new('uint8_t[1537]')
assert(lib.randomb_drbg_fill(state, buffer, 1537) == 0)
assert(ffi.string(buffer, 1537) == oracle:bytes(1537))
assert(state[0].position == 1537)
for _, position in ipairs({0, 1, 63, 64, 65, 4294967295, 9007199254740927}) do
	assert(lib.randomb_drbg_seek(state, position) == 0)
	assert(lib.randomb_drbg_fill(state, buffer, 65) == 0)
	assert(ffi.string(buffer, 65) == drbg.new(seed, position):bytes(65))
end
assert(lib.randomb_drbg_seek(state, 9007199254740992) == 0)
ffi.fill(buffer, 65, 165)
assert(lib.randomb_drbg_fill(state, buffer, 1) == 3)
assert(state[0].position == 9007199254740992 and buffer[0] == 165)
assert(lib.randomb_drbg_fill(state, nil, 0) == 0)
for _, position in ipairs({9007199254740993ULL, 18446744073709551615ULL}) do
	local before = ffi.string(state, ffi.sizeof(state))
	assert(lib.randomb_drbg_seek(state, position) == 3, 'seek must report position overflow')
	assert(ffi.string(state, ffi.sizeof(state)) == before, 'invalid seek changed state')
	assert(lib.randomb_drbg_set_state(state, seed_buffer, position) == 3, 'restore must report position overflow')
	assert(ffi.string(state, ffi.sizeof(state)) == before, 'invalid restore changed state')
end
-- The callback intentionally reenters the SAME Bend library. Holding an
-- evaluator lock while invoking user I/O would deadlock this test.
local fill = ffi.cast('randomb_fill_fn', function(context, output, length)
	return lib.randomb_drbg_fill(ffi.cast('randomb_drbg *', context), output, length)
end)
local zero = ffi.new('randomb_fixed', {0, 0})
local one = ffi.new('randomb_fixed', {fx.from_int(1)})
local out = ffi.new('randomb_fixed[1]')
local integer = ffi.new('int64_t[1]')
local checks = 0
for _, mode in ipairs({'normal', 'exponential', 'log_normal', 'beta', 'poisson', 'range', 'normal_int'}) do
	assert(lib.randomb_drbg_init(state, seed_buffer) == 0)
	oracle = drbg.new(seed)
	for i = 1, 128 do
		local status, m, e
		if mode == 'normal' or mode == 'log_normal' then
			status = invoke(lib, 'randomb_' .. mode, fill, state, zero, one, out)
			m, e = oracle[mode](oracle, 0LL, 0, one.m, one.e)
		elseif mode == 'beta' then
			status = invoke(lib, 'randomb_beta', fill, state, one, one, out)
			m, e = oracle:beta(one.m, one.e, one.m, one.e)
		elseif mode == 'exponential' then
			status = invoke(lib, 'randomb_exponential', fill, state, one, out)
			m, e = oracle:exponential(one.m, one.e)
		elseif mode == 'poisson' then
			status = invoke(lib, 'randomb_poisson', fill, state, one, integer)
			assert(integer[0] == oracle:poisson(one.m, one.e))
		else
			status = invoke(lib, 'randomb_' .. mode, fill, state, -20, 20, integer)
			assert(integer[0] == oracle[mode](oracle, -20, 20))
		end
		assert(status == 0, mode .. ' returned ' .. status)
		if m then assert(out[0].m == m and out[0].e == e, mode .. ' numeric mismatch') end
		assert(state[0].position == oracle:position(), mode .. ' cursor mismatch')
		checks = checks + 1
	end
end
local encoded = ffi.new('uint8_t[1024]')
local scratch = ffi.new('uint32_t[1024]')
local text = ffi.new('char[4096]')
local written, text_length = ffi.new('size_t[1]'), ffi.new('size_t[1]')
for _, exponent in ipairs({-1, -2, -20, -63, -100, -1000}) do
	local p = ffi.new('randomb_fixed', {4611686018427387904LL, exponent})
	assert(lib.randomb_drbg_init(state, seed_buffer) == 0)
	oracle = drbg.new(seed)
	for i = 1, 12 do
		assert(invoke(lib, 'randomb_geometric', fill, state, p, encoded, 1024, written) == 0)
		local expected = oracle:geometric(p.m, p.e)
		assert(ffi.string(encoded, written[0]) == count.to_blip(expected))
		assert(lib.randomb_count_format(encoded, written[0], 10, scratch, 1024, text, 4096, text_length) == 0)
		assert(ffi.string(text, text_length[0]) == count.to_decimal(expected))
		assert(state[0].position == oracle:position())
		checks = checks + 1
	end
end
-- Fixed-size repeated work must reuse the runtime heap after warmup. This
-- measures allocated pages, not a fictitious count of every live allocation.
assert(lib.randomb_drbg_init(state, seed_buffer) == 0)
for _ = 1, 256 do assert(lib.randomb_drbg_fill(state, buffer, 64) == 0) end
local pages = ffi.new('uint64_t[1]')
assert(lib.randomb_debug_heap_pages(pages) == 0)
local before = pages[0]
for _ = 1, 2048 do assert(lib.randomb_drbg_fill(state, buffer, 64) == 0) end
assert(lib.randomb_debug_heap_pages(pages) == 0)
assert(pages[0] == before, 'fixed-workload Bend heap keeps growing')
fill:free()
io.write('Bend native C ABI: ', checks, ' independent sampling/cursor checks, reentrancy and heap reuse passed\n')
