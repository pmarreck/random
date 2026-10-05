local ffi=require('ffi')
local ffi_callback = dofile(assert(os.getenv('RANDOM_PROJECT_ROOT'))..'/tests/ffi_callback.lua')
package.path=(assert(os.getenv('RANDOM_PROJECT_ROOT'))..'/lib/?.lua;')..package.path
local drbg=require('drbg')
ffi.cdef[[
typedef int (*batch_fill)(void*,uint8_t*,size_t);
int randomz_normal_int_batch(batch_fill,void*,int64_t,int64_t,int64_t*,size_t,size_t*,int);
int randomroc_normal_int_batch(batch_fill,void*,int64_t,int64_t,int64_t*,size_t,size_t*,int);
size_t randomroc_debug_live(void);
]]
local z=ffi.load(assert(os.getenv('RANDOM_ROC_ORACLE_LIBRARY')))
local r=ffi.load(assert(os.getenv('RANDOM_ROC_SHARED_LIBRARY')))
local values,written=ffi.new('int64_t[131]'),ffi.new('size_t[1]')
local checks=0
local bounds={{0LL,99LL},{1LL,20LL},{7LL,7LL},{-9007199254740992LL,9007199254740992LL},
	{0LL,9007199254740992LL},{9007199254740992LL,9007199254740992LL},
	{2LL,1LL},{-9007199254740993LL,0LL},{0LL,9007199254740993LL}}
for _,range in ipairs(bounds) do
	for _,count in ipairs({0,1,3,4,5,7,8,9,96,129}) do
		for _,mode in ipairs({-1,0,1,2}) do
			for _,failure in ipairs({0,1,3,9}) do
				local function invoke(lib,prefix,backend)
					local rng=drbg.new(string.rep('\0',31)..string.char(42))
					local calls,sizes=0,{}
					local callback=ffi.cast('batch_fill',function(_,out,n)
						calls=calls+1;sizes[#sizes+1]=tonumber(n)
						if calls==failure then ffi.fill(out,n,0x11);return 3 end
						local bytes=rng:bytes(tonumber(n));ffi.copy(out,bytes,#bytes);return 0
					end)
					ffi.fill(values,ffi.sizeof(values),0xa5);written[0]=999
					local status=ffi_callback(lib, prefix..'normal_int_batch', callback,nil,range[1],range[2],values+1,count,written,backend)
					callback:free()
					assert(values[0]==-6510615555426900571LL and values[count+1]==-6510615555426900571LL)
					return status,tonumber(written[0]),ffi.string(values,ffi.sizeof(values)),table.concat(sizes,','),rng:position()
				end
				local zs,zw,zv,zr,zp=invoke(z,'randomz_',mode)
				local rs,rw,rv,rr,rp=invoke(r,'randomroc_',mode)
				assert(zs==rs and zw==rw and zv==rv and zr==rr and zp==rp,
					'case '..checks..' status='..rs..'/'..zs..' written='..rw..'/'..zw..' mode='..mode)
				assert(r.randomroc_debug_live()==0);checks=checks+1
			end
		end
	end
end
assert(checks==1440)
print('Roc normalized-batch FFI: '..checks..' exact Zig AUTO/SCALAR values, cursors, read sequence, prefixes, domains and ownership checks passed.')
