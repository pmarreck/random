local ffi=require('ffi')
local ffi_callback = dofile(assert(os.getenv('RANDOM_PROJECT_ROOT'))..'/tests/ffi_callback.lua')
package.path=(assert(os.getenv('RANDOM_PROJECT_ROOT'))..'/lib/?.lua;')..package.path
local drbg,counts,g=require('drbg'),require('unsigned_count'),require('geometric')
ffi.cdef[[
typedef struct { int64_t m; int32_t e; } geometric_roc_fixed;
typedef int (*geometric_roc_fill)(void *,uint8_t *,size_t);
int randomroc_geometric(geometric_roc_fill,void*,geometric_roc_fixed,uint8_t*,size_t,size_t*);
size_t randomroc_debug_live(void);
]]
local lib=ffi.load(assert(arg[1]))
local seed=string.rep('\0',31)..string.char(42)
local output,written=ffi.new('uint8_t[4098]'),ffi.new('size_t[1]')
local checks=0
for _,probability in ipairs({'1','0.5','0.25','1e-20','2^-100','2^-1000'}) do
	local m,e=g.parse_probability(probability)
	local p=ffi.new('geometric_roc_fixed',{m,e})
	local left,right=drbg.new(seed),drbg.new(seed)
	local requests=0
	local fill=ffi.cast('geometric_roc_fill',function(_,out,count)
		requests=requests+1
		local bytes=right:bytes(tonumber(count));ffi.copy(out,bytes,#bytes);return 0
	end)
	for _=1,12 do
		ffi.fill(output,4098,0xa5);written[0]=999
		assert(ffi_callback(lib, 'randomroc_geometric', fill,nil,p,output+1,4096,written)==0)
		local expected=counts.to_blip(left:geometric(m,e))
		assert(ffi.string(output+1,written[0])==expected)
		assert(left:position()==right:position())
		assert(output[0]==0xa5 and output[4097]==0xa5 and lib.randomroc_debug_live()==0)
		checks=checks+1
	end
	if probability=='1' then assert(requests==0)end
	fill:free()
end
local requests=0
local fill=ffi.cast('geometric_roc_fill',function(_,out,count)
	requests=requests+1;ffi.fill(out,count,requests<=128 and 255 or 0);return 0
end)
local half=ffi.new('geometric_roc_fixed',{4611686018427387904LL,-1})
ffi.fill(output,4098,0xa5);written[0]=999
assert(ffi_callback(lib, 'randomroc_geometric', fill,nil,half,output+1,1,written)==4)
assert(requests==129 and written[0]==0 and output[0]==0xa5 and output[2]==0xa5)
fill:free()
requests=0
fill=ffi.cast('geometric_roc_fill',function() requests=requests+1;return 99 end)
written[0]=999
assert(ffi_callback(lib, 'randomroc_geometric', fill,nil,ffi.new('geometric_roc_fixed',{0,0}),output,16,written)==1)
assert(requests==0 and written[0]==999)
assert(ffi_callback(lib, 'randomroc_geometric', fill,nil,ffi.new('geometric_roc_fixed',{4611686018427387904LL,-100}),output,1,written)==4)
assert(requests==0 and written[0]==0)
assert(ffi_callback(lib, 'randomroc_geometric', fill,nil,half,output,16,written)==2)
assert(requests==1 and written[0]==0 and lib.randomroc_debug_live()==0)
fill:free()
print('Roc bounded geometric FFI: '..checks..' exact BLIP values/cursors; refusal, late capacity, callback and ownership controls passed.')
