-- Independent production-LuaJIT oracle; retain no generated payload on disk.
package.path = './lib/?.lua;' .. package.path
local bit, b, d = require('bit'), require('blake3'), require('drbg')
local kind, n, repeats, seed = tonumber(arg[1]), tonumber(arg[2]), tonumber(arg[3]), tonumber(arg[4])
assert(#arg == 4 and kind and kind >= 0 and kind <= 2 and kind == math.floor(kind))
assert(n and n >= 0 and n <= 8192 and n == math.floor(n))
assert(repeats and repeats >= 1 and repeats <= 1000000 and repeats == math.floor(repeats))
assert(seed and seed >= 0 and seed <= 4294967295 and seed == math.floor(seed))
local source, hash = d.new(b.hex_to_bin(string.format('%064x',seed))), 0
local function step(h, v) return bit.bxor(bit.rol(h,5),v) end
for _=1,repeats do
	if kind == 0 then
		local bytes = source:bytes(n)
		for i=1,#bytes do hash = step(hash,bytes:byte(i)) end
	else
		for _=1,n do
			local value = source:range(1,kind == 1 and 6 or 4503599627370496)
			hash = step(step(hash,value % 4294967296),math.floor(value / 4294967296))
		end
	end
end
io.write(string.format('{"hash":%.0f,"position":"%.0f"}\n',hash < 0 and hash + 4294967296 or hash,source:position()))
