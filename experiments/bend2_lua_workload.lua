-- Public-API dispatch and result consumption only, shared by the independent
-- LuaJIT oracle and its timing adapter. No replacement arithmetic or sampler.
local ffi, bit = require('ffi'), require('bit')
local count = require('unsigned_count')
local function mix(h, value) return bit.bxor(bit.rol(h, 5), value) end
local function integer(h, value)
	local bits = ffi.cast('uint64_t', value)
	return mix(mix(h, tonumber(bits % 4294967296ULL)), tonumber(bits / 4294967296ULL))
end
local one, sigma = 4611686018427387904LL, 8070450532247928832LL
return function(source, kind, n, hash)
	if kind == 0 then
		local bytes = source:bytes(n)
		assert(#bytes == n, 'incorrect byte count')
		for i = 1, #bytes do hash = mix(hash, bytes:byte(i)) end
	else
		for _ = 1, n do
			if kind <= 2 then hash = integer(hash, source:range(1, kind == 1 and 6 or 4503599627370496))
			elseif kind == 4 or kind == 11 then hash = integer(hash, source:normal_int(0, 255))
			elseif kind == 6 then hash = integer(hash, source:poisson(5764607523034234880LL, 2))
			elseif kind == 9 or kind == 10 then
				local value = source:geometric(one, kind == 9 and -2 or -100)
				local encoded = count.to_blip(value)
				for i = 1, #encoded do hash = mix(hash, encoded:byte(i)) end
			else
				local m, e
				if kind == 3 then m, e = source:normal(0LL, 0, one, 0)
				elseif kind == 5 then m, e = source:exponential(one, 2)
				elseif kind == 7 then m, e = source:log_normal(-one, -2, sigma, 0)
				elseif kind == 8 then m, e = source:beta(one, 0, 6917529027641081856LL, 1)
				else error('unknown sampler') end
				hash = mix(integer(hash, m), e)
			end
		end
	end
	return hash < 0 and hash + 4294967296 or hash
end
