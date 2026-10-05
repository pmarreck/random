local ffi = require('ffi')
package.path = (assert(os.getenv('RANDOM_PROJECT_ROOT'))..'/lib/?.lua;')..package.path
local counts = require('unsigned_count')
ffi.cdef[[
int randomz_count_format(const uint8_t*,size_t,uint8_t,uint32_t*,size_t,char*,size_t,size_t*);
int randomroc_count_format(const uint8_t*,size_t,uint8_t,uint32_t*,size_t,char*,size_t,size_t*);
size_t randomroc_debug_live(void);
]]
local z = ffi.load(assert(os.getenv('RANDOM_ROC_ORACLE_LIBRARY')))
local r = ffi.load(assert(os.getenv('RANDOM_ROC_SHARED_LIBRARY')))
local workspace, output, written = ffi.new('uint32_t[260]'), ffi.new('char[1026]'), ffi.new('size_t[1]')
local cases = {'','\0','\1','\127','\129\128','\130\0\1','\128','\129\0','\129\127','\160\0','\255','\0\0'}
for _, length in ipairs({7,8,31,32,33,64,127,128,255}) do
	cases[#cases+1] = counts.to_blip(string.rep('\255',length))
end
local checks = 0
for _, encoded in ipairs(cases) do
	for _, radix in ipairs({0,10,16,17}) do
		for _, scratch_capacity in ipairs({0,1,8,260}) do
			for _, capacity in ipairs({0,1,2,16,1024}) do
				local function invoke(lib, symbol)
					ffi.fill(workspace,ffi.sizeof(workspace),0xa5)
					ffi.fill(output,ffi.sizeof(output),0x5a);written[0]=999
					local status = lib[symbol](encoded,#encoded,radix,workspace,scratch_capacity,output+1,capacity,written)
					assert(output[0] == 0x5a and output[capacity+1] == 0x5a)
					return status,tonumber(written[0]),status == 0 and ffi.string(output+1,written[0]) or ''
				end
				local zs,zw,zt = invoke(z,'randomz_count_format')
				local rs,rw,rt = invoke(r,'randomroc_count_format')
				assert(zs == rs and zw == rw and zt == rt,
					'case '..checks..' status '..rs..'/'..zs..' written '..rw..'/'..zw)
				assert(r.randomroc_debug_live() == 0)
				checks = checks + 1
			end
		end
	end
end
assert(checks == 1680)
print('Roc count-format FFI: '..checks..' exact Zig statuses, values, refusal-mutation, canaries and ownership checks passed.')
