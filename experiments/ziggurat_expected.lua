-- Independently loop over the FFI sample array, outside every timed process.
-- This catches skipped/changed benchmark work; MPFR/stats judge the sampler.
local ffi = require("ffi")
ffi.cdef[[
typedef struct { int64_t m; int32_t e; } expected_pair;
int experiment_samples(uint64_t, uint8_t, uint8_t, size_t, expected_pair *);
int production_samples(uint64_t, uint8_t, size_t, expected_pair *);
uint64_t experiment_checksum(uint8_t, uint8_t, size_t, uint64_t, bool);
int randomz_fixed_format(expected_pair, size_t, char *, size_t, size_t *);
]]
local lib = ffi.load(assert(arg[1]))
local seed = tonumber(arg[2]) or 42
local count = tonumber(arg[3])
local sizes = count and {count} or {4096,8192,16384,32768}
local algorithms, operations = {"box","paired","ziggurat"}, {"normal","integer","lognormal","beta"}
local function rotate(x) return x*128ULL + x/144115188075855872ULL end
io.write('{')
local first = true
for a, algorithm in ipairs(algorithms) do
	for o, operation in ipairs(operations) do
		for _, formatted in ipairs({false,true}) do
			if not first then io.write(',') end
			first = false
			io.write('"',algorithm,'-',operation,formatted and '-format' or '-core','":{')
			for s,n in ipairs(sizes) do
				local values = ffi.new("expected_pair[?]",n)
				assert(lib.experiment_samples(seed,a-1,o-1,n,values) == 0)
				if algorithm == "ziggurat" then
					local actual = ffi.new("expected_pair[?]",n)
					assert(lib.production_samples(seed,o-1,n,actual)==0, "production sampler status")
					for i=0,n-1 do assert(actual[i].m==values[i].m and actual[i].e==values[i].e,
						"production sampler differs from independent experiment: "..operation.." index="..i) end
				end
				local sum, buffer, written = 0ULL, ffi.new("char[512]"), ffi.new("size_t[1]")
				for i = 0,n-1 do
					local x = values[i]
					if formatted then
						assert(lib.randomz_fixed_format(x,19,buffer,512,written) == 0)
						for j = 0,tonumber(written[0])-1 do sum = rotate(sum) + ffi.cast("uint8_t*",buffer)[j] end
					else
						sum = rotate(sum) + ffi.cast("uint64_t",x.m) + ffi.cast("uint64_t",ffi.new("int64_t",x.e))
					end
				end
				assert(lib.experiment_checksum(a-1,o-1,n,seed,formatted) == sum, "benchmark work checksum differs from FFI-array oracle")
				if algorithm == "ziggurat" and operation == "integer" then
					for b, batch in ipairs({"auto", "scalar", "simd"}) do
						assert(lib.experiment_checksum(b+2,o-1,n,seed,formatted) == sum,
							batch .. " batch checksum differs from independent scalar work oracle")
					end
				end
				if s > 1 then io.write(',') end
				io.write('"',n,'":"',tostring(sum):gsub("ULL$", ""),'"')
			end
			io.write('}')
		end
	end
end
io.write('}\n')
