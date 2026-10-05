local ffi=require('ffi')
local ffi_callback = dofile(assert(os.getenv('RANDOM_PROJECT_ROOT'))..'/tests/ffi_callback.lua')
package.path=(assert(os.getenv('RANDOM_PROJECT_ROOT'))..'/lib/?.lua;')..package.path
local drbg=require('drbg')
ffi.cdef[[
typedef int (*selection_fill)(void*,uint8_t*,size_t);
int randomroc_weighted_total(const int64_t*,size_t,int64_t*,uint8_t*);
int randomroc_weighted_index(selection_fill,void*,const int64_t*,size_t,int64_t*,uint8_t*);
int randomroc_shuffle_indices(selection_fill,void*,int64_t*,size_t,size_t*);
size_t randomroc_debug_live(void);
]]
local lib=ffi.load(assert(os.getenv('RANDOM_ROC_SHARED_LIBRARY')))
local checks=0
for _,weights in ipairs({{1},{0,1,0},{1,3,0},{100,1,7,0,2},{9007199254740992LL}}) do
	local input=ffi.new('int64_t[?]',#weights,weights)
	local total,index,reason=ffi.new('int64_t[1]'),ffi.new('int64_t[1]'),ffi.new('uint8_t[1]',99)
	assert(lib.randomroc_weighted_total(input,#weights,total,reason)==0 and reason[0]==0)
	local left,right=drbg.new(string.rep('\0',31)..string.char(42)),drbg.new(string.rep('\0',31)..string.char(42))
	local callback=ffi.cast('selection_fill',function(_,out,n)local s=right:bytes(tonumber(n));ffi.copy(out,s,#s);return 0 end)
	for _=1,32 do
		assert(ffi_callback(lib, 'randomroc_weighted_index', callback,nil,input,#weights,index,reason)==0 and reason[0]==0)
		local pick=left:range(1,tonumber(total[0]));local cumulative,expected=0LL,0
		for i,weight in ipairs(weights) do cumulative=cumulative+weight;if pick<=cumulative then expected=i-1;break end end
		assert(index[0]==expected and left:position()==right:position() and lib.randomroc_debug_live()==0)
		checks=checks+1
	end
	callback:free()
end
for _,count in ipairs({0,1,2,3,20,129,4096}) do
	local out,written=ffi.new('int64_t[?]',count+2),ffi.new('size_t[1]')
	local left,right=drbg.new(string.rep('\0',31)..string.char(42)),drbg.new(string.rep('\0',31)..string.char(42))
	local callback=ffi.cast('selection_fill',function(_,dst,n)local s=right:bytes(tonumber(n));ffi.copy(dst,s,#s);return 0 end)
	for _=1,4 do
		ffi.fill(out,ffi.sizeof(out),0xa5);written[0]=999
		assert(ffi_callback(lib, 'randomroc_shuffle_indices', callback,nil,out+1,count,written)==0 and written[0]==count)
		local expected={};for i=1,count do expected[i]=i-1 end
		for i=count,2,-1 do local j=left:range(1,i);expected[i],expected[j]=expected[j],expected[i] end
		for i=1,count do assert(out[i]==expected[i]) end
		assert(out[0]==-6510615555426900571LL and out[count+1]==-6510615555426900571LL)
		assert(left:position()==right:position() and lib.randomroc_debug_live()==0);checks=checks+1
	end
	callback:free()
end
local calls=0
local callback=ffi.cast('selection_fill',function()calls=calls+1;return 99 end)
local output,reason=ffi.new('int64_t[1]',789),ffi.new('uint8_t[1]',99)
for _,case in ipairs({{{},4},{{0,0},3},{{-1,2},1},{{9007199254740992LL,1},2}}) do
	local weights=ffi.new('int64_t[?]',math.max(1,#case[1]),case[1])
	assert(ffi_callback(lib, 'randomroc_weighted_index', callback,nil,weights,#case[1],output,reason)==1)
	assert(output[0]==789 and reason[0]==case[2] and calls==0 and lib.randomroc_debug_live()==0);checks=checks+1
end
assert(ffi_callback(lib, 'randomroc_weighted_index', callback,nil,ffi.new('int64_t[2]',{1,3}),2,output,reason)==2)
assert(output[0]==789 and calls==1 and lib.randomroc_debug_live()==0);checks=checks+1
callback:free()
assert(checks==193)
print('Roc selection FFI: '..checks..' exact weights/shuffles, source cursors, refusal reasons, canaries and ownership controls passed.')
