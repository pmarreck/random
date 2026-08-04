-- Cross-architecture payload for the original LuaJIT DRBG. Official vectors
-- establish BLAKE3 correctness; this establishes that the same LuaJIT oracle
-- emits identical KDF/keyed-XOF bytes on every architecture/libc leg.
local here = (arg[0]:match("^(.*)/") or ".")
package.path = here .. "/../lib/?.lua;" .. package.path

local b3 = require("blake3")
local context = "random drbg 2026-08-04 v1"
local seed = string.rep("\0", 31) .. "\42"
local key = b3.hex_to_bin(b3.blake3_derive_key(seed, context, 32))

local whole = b3.blake3("", key, 4096)
local stream = b3.blake3("", key, -1)
local chunks = stream(17) .. stream(47) .. stream(1) .. stream(1983) .. stream(2048)
assert(chunks == whole, "chunked BLAKE3 XOF consumption differs from one-shot output")

stream("seek", 1023)
assert(stream(131) == whole:sub(1023 * 2 + 1, (1023 + 131) * 2),
	"BLAKE3 XOF seek differs from one-shot output")

io.stdout:write(whole)
