-- Gate the vendored LuaJIT BLAKE3 directly against the upstream BLAKE3
-- project's published expected outputs. The fixture is an unchanged copy of
-- test_vectors/test_vectors.json at commit
-- 9eac279fd71b79ad9e897a4cffb23ee64acfb6df.
local here = (arg[0]:match("^(.*)/") or ".")
package.path = here .. "/../lib/?.lua;" .. package.path

local b3 = require("blake3")

local fixture_path = here .. "/fixtures/blake3-test-vectors.json"
local fixture = assert(io.open(fixture_path, "rb"))
local json = assert(fixture:read("*a"))
fixture:close()

local key = assert(json:match('"key"%s*:%s*"([^"]+)"'))
local context = assert(json:match('"context_string"%s*:%s*"([^"]+)"'))

local max_input_len = 102400
local input_bytes = {}
for i = 0, max_input_len - 1 do
	input_bytes[i + 1] = string.char(i % 251)
end
local all_input = table.concat(input_bytes)

local count = 0
local first_keyed
for input_len, hash, keyed_hash, derive_key in json:gmatch(
	'"input_len"%s*:%s*(%d+),%s*"hash"%s*:%s*"(%x+)",%s*' ..
	'"keyed_hash"%s*:%s*"(%x+)",%s*"derive_key"%s*:%s*"(%x+)"'
) do
	input_len = tonumber(input_len)
	local input = all_input:sub(1, input_len)
	assert(#hash == 262 and #keyed_hash == 262 and #derive_key == 262,
		"official vector output width changed")

	assert(b3.blake3(input, nil, 131) == hash,
		("plain BLAKE3 mismatch at input_len=%d"):format(input_len))
	assert(b3.blake3(input, key, 131) == keyed_hash,
		("keyed BLAKE3 mismatch at input_len=%d"):format(input_len))
	assert(b3.blake3_derive_key(input, context, 131) == derive_key,
		("derive-key mismatch at input_len=%d"):format(input_len))

	assert(b3.blake3(input, nil, 32) == hash:sub(1, 64),
		("plain 32-byte prefix mismatch at input_len=%d"):format(input_len))
	assert(b3.blake3(input, key, 32) == keyed_hash:sub(1, 64),
		("keyed 32-byte prefix mismatch at input_len=%d"):format(input_len))
	assert(b3.blake3_derive_key(input, context, 32) == derive_key:sub(1, 64),
		("derive-key 32-byte prefix mismatch at input_len=%d"):format(input_len))

	if input_len == 0 then first_keyed = keyed_hash end
	count = count + 1
end

assert(count == 35, ("expected 35 official cases, parsed %d"):format(count))
assert(first_keyed, "missing official empty-input keyed vector")

-- Seek/chunk metamorphic check whose expected bytes still come directly from
-- the official empty-input keyed vector.
local stream = b3.blake3("", key, -1)
assert(stream(17) == first_keyed:sub(1, 34))
assert(stream(47) == first_keyed:sub(35, 128))
stream("seek", 63)
assert(stream(2) == first_keyed:sub(127, 130))
stream("seek", 7)
assert(stream(64) == first_keyed:sub(15, 142))

print("blake3 vectors PASSED: 35 official cases x 3 modes x 2 widths; seek control passed")
