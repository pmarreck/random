local ffi = require('ffi')
local ffi_callback = dofile(assert(os.getenv('RANDOM_PROJECT_ROOT'))..'/tests/ffi_callback.lua')
package.path = (assert(os.getenv('RANDOM_PROJECT_ROOT'))..'/lib/?.lua;')..package.path
local drbg, geometric = require('drbg'), require('geometric')
ffi.cdef[[
typedef struct { int64_t m; int32_t e; } capacity_fixed;
typedef int (*capacity_fill)(void *,uint8_t *,size_t);
int randomz_geometric(capacity_fill,void*,capacity_fixed,uint8_t*,size_t,size_t*);
int randomroc_geometric(capacity_fill,void*,capacity_fixed,uint8_t*,size_t,size_t*);
size_t randomroc_debug_live(void);
]]
local roc = ffi.load(assert(os.getenv('RANDOM_ROC_SHARED_LIBRARY')))
local zig = ffi.load(assert(os.getenv('RANDOM_ROC_ORACLE_LIBRARY')))
local output, written = ffi.new('uint8_t[125010]'), ffi.new('size_t[1]')
local checks = 0
local probabilities = {'1','0.5','0.25','0.1','1e-20','2^-100','2^-1000','2^-1000000'}
local capacities = {0,1,2,7,8,9,16,31,32,33,64,65,125,126,127,128,129,130,125000,125008}
for _, text in ipairs(probabilities) do
	local m, e = geometric.parse_probability(text)
	local p = ffi.new('capacity_fixed',{m,e})
	for _, capacity in ipairs(capacities) do
		for _, mode in ipairs({'drbg','zero','ones','reject256','partial-error'}) do
			local function invoke(lib, symbol)
				local rng = drbg.new(string.rep('\0',31)..string.char(42))
				local requests, consumed, sizes = 0, 0, {}
				local callback = ffi.cast('capacity_fill',function(_, out, count)
					count = tonumber(count)
					requests = requests + 1; consumed = consumed + count
					assert(requests <= 512, 'unbounded forced rejection')
					sizes[#sizes+1] = tostring(count)
					if mode == 'drbg' then ffi.copy(out,rng:bytes(count),count)
					elseif mode == 'zero' then ffi.fill(out,count,0)
					elseif mode == 'ones' then ffi.fill(out,count,requests <= 1 and 255 or 0)
					elseif mode == 'reject256' then ffi.fill(out,count,requests <= 256 and 255 or 0)
					else ffi.fill(out,count,0x11);return 99 end
					return 0
				end)
				ffi.fill(output,125010,0xa5); written[0] = 999
				local status = ffi_callback(lib, symbol, callback,nil,p,output+1,capacity,written)
				callback:free()
				assert(output[0] == 0xa5 and output[capacity+1] == 0xa5)
				local encoding = status == 0 and ffi.string(output+1,written[0]) or ''
				return status,tonumber(written[0]),consumed,table.concat(sizes,','),encoding
			end
			local zs, zw, zc, zr, ze = invoke(zig,'randomz_geometric')
			local rs, rw, rc, rr, re = invoke(roc,'randomroc_geometric')
			assert(rs == zs and rw == zw and rc == zc and rr == zr and re == ze,
				text..' cap='..capacity..' mode='..mode..' status='..rs..'/'..zs..' reads='..rr..'/'..zr)
			assert(roc.randomroc_debug_live() == 0)
			checks = checks + 1
		end
	end
end
assert(checks == 800)
print('Roc geometric capacity FFI: '..checks..' exact Zig statuses, encodings, read sequences, canaries and ownership checks passed.')
