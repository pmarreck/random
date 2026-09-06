-- Exercise the installed buffered C ABI through LuaJIT, including byte cursors.
local ffi = require("ffi")
ffi.cdef[[
typedef struct { uint8_t key[32]; uint64_t position; } randomz_drbg;
typedef struct {
	randomz_drbg state; uint8_t cache[1024]; uint64_t cache_start; uint64_t cache_len;
} randomz_buffered_drbg;
int randomz_drbg_init(randomz_drbg *, const uint8_t *);
int randomz_drbg_seek(randomz_drbg *, uint64_t);
int randomz_drbg_fill(randomz_drbg *, uint8_t *, size_t);
int randomz_buffered_drbg_init(randomz_buffered_drbg *, const uint8_t *);
int randomz_buffered_drbg_seek(randomz_buffered_drbg *, uint64_t);
int randomz_buffered_drbg_fill(randomz_buffered_drbg *, uint8_t *, size_t);
int randomz_buffered_drbg_set_state(randomz_buffered_drbg *, const uint8_t *, uint64_t);
int randomz_buffered_drbg_get_state(const randomz_buffered_drbg *, uint8_t *, uint64_t *);
void randomz_buffered_drbg_zeroize(randomz_buffered_drbg *);
]]
local lib = ffi.load(assert(arg[1], "shared library path required"))
local plain = ffi.new("randomz_drbg[1]")
local cached = ffi.new("randomz_buffered_drbg[1]")
local seed = ffi.new("uint8_t[32]")
seed[31] = 42
assert(ffi.sizeof("randomz_drbg") == 40, "legacy ABI changed")
assert(ffi.sizeof("randomz_buffered_drbg") == 1080, "buffered ABI mismatch")
assert(lib.randomz_drbg_init(plain, seed) == 0)
assert(lib.randomz_buffered_drbg_init(cached, seed) == 0)
local expected, actual = ffi.new("uint8_t[4097]"), ffi.new("uint8_t[4097]")
for _, start in ipairs({0, 1, 63, 64, 1023, 1024, 1025, 8191}) do
	assert(lib.randomz_drbg_seek(plain, start) == 0)
	assert(lib.randomz_buffered_drbg_seek(cached, start) == 0)
	for _, size in ipairs({0, 1, 4, 8, 63, 64, 1023, 1024, 4097}) do
		assert(lib.randomz_drbg_fill(plain, expected, size) == 0)
		assert(lib.randomz_buffered_drbg_fill(cached, actual, size) == 0)
		assert(ffi.string(actual, size) == ffi.string(expected, size), "XOF mismatch")
		assert(plain[0].position == cached[0].state.position, "prefetch advanced cursor")
	end
end
local key, position = ffi.new("uint8_t[32]"), ffi.new("uint64_t[1]")
assert(lib.randomz_buffered_drbg_get_state(cached, key, position) == 0)
assert(position[0] == cached[0].state.position)
assert(lib.randomz_buffered_drbg_set_state(cached, key, 0) == 0)
assert(cached[0].cache_len == 0)
assert(lib.randomz_buffered_drbg_fill(cached, actual, 1) == 0)
seed[31] = 17 -- Rekey after filling the cache: no bytes from seed 42 may survive.
assert(lib.randomz_buffered_drbg_init(cached, seed) == 0)
assert(lib.randomz_drbg_init(plain, seed) == 0)
assert(lib.randomz_buffered_drbg_fill(cached, actual, 64) == 0)
assert(lib.randomz_drbg_fill(plain, expected, 64) == 0)
assert(ffi.string(actual, 64) == ffi.string(expected, 64))
local cap = 9007199254740992ULL
local saved = ffi.string(cached, ffi.sizeof(cached))
assert(lib.randomz_buffered_drbg_seek(cached, cap + 1) == 3)
assert(lib.randomz_buffered_drbg_set_state(cached, key, cap + 1) == 3)
assert(lib.randomz_buffered_drbg_set_state(cached, nil, 0) == 1)
assert(lib.randomz_buffered_drbg_init(cached, nil) == 1)
assert(lib.randomz_buffered_drbg_fill(cached, nil, 1) == 1)
assert(ffi.string(cached, ffi.sizeof(cached)) == saved, "failed request mutated cached state")
assert(lib.randomz_buffered_drbg_seek(cached, cap - 1) == 0)
ffi.fill(actual, 2, 165)
assert(lib.randomz_buffered_drbg_fill(cached, actual, 2) == 3)
assert(actual[0] == 165 and actual[1] == 165 and cached[0].state.position == cap - 1)
assert(lib.randomz_buffered_drbg_fill(cached, actual, 1) == 0)
assert(lib.randomz_buffered_drbg_fill(cached, nil, 0) == 0)
assert(lib.randomz_buffered_drbg_seek(cached, cap + 1) == 3)
assert(cached[0].state.position == cap)
assert(lib.randomz_buffered_drbg_init(nil, seed) == 1)
assert(lib.randomz_buffered_drbg_init(cached, nil) == 1)
assert(lib.randomz_buffered_drbg_seek(nil, 0) == 1)
assert(lib.randomz_buffered_drbg_fill(nil, actual, 1) == 1)
assert(lib.randomz_buffered_drbg_fill(cached, nil, 1) == 1)
assert(lib.randomz_buffered_drbg_set_state(cached, key, cap + 1) == 3)
assert(lib.randomz_buffered_drbg_set_state(cached, nil, 0) == 1)
assert(lib.randomz_buffered_drbg_get_state(cached, nil, position) == 1)
assert(lib.randomz_buffered_drbg_get_state(cached, key, nil) == 1)
lib.randomz_buffered_drbg_zeroize(nil)
lib.randomz_buffered_drbg_zeroize(cached)
assert(ffi.string(cached, ffi.sizeof(cached)) == string.rep("\0", ffi.sizeof(cached)))
print("Buffered DRBG LuaJIT FFI passed: legacy ABI, bytes, cursors, rekey, cap, errors, wiping")
