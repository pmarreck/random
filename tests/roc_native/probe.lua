local ffi = require('ffi')
local ffi_callback = dofile(assert(os.getenv('RANDOM_PROJECT_ROOT'))..'/tests/ffi_callback.lua')
package.path=(assert(os.getenv('RANDOM_PROJECT_ROOT'))..'/lib/?.lua;')..package.path
local oracle = require('drbg')
local fixed = require('fixed')
ffi.cdef[[
typedef struct { int64_t m; int32_t e; } randomroc_fixed;
typedef int (*randomroc_fill_fn)(void *, uint8_t *, size_t);
int randomroc_uniform(randomroc_fill_fn, void *, randomroc_fixed *);
int randomroc_normal(randomroc_fill_fn, void *, randomroc_fixed, randomroc_fixed, randomroc_fixed *);
int randomroc_exponential(randomroc_fill_fn, void *, randomroc_fixed, randomroc_fixed *);
int randomroc_poisson(randomroc_fill_fn, void *, randomroc_fixed, int64_t *);
int randomroc_log_normal(randomroc_fill_fn, void *, randomroc_fixed, randomroc_fixed, randomroc_fixed *);
int randomroc_beta(randomroc_fill_fn, void *, randomroc_fixed, randomroc_fixed, randomroc_fixed *);
int randomroc_range(randomroc_fill_fn, void *, int64_t, int64_t, int64_t *);
int randomroc_normal_int(randomroc_fill_fn, void *, int64_t, int64_t, int64_t *);
size_t randomroc_debug_live(void);
]]
local lib = ffi.load(assert(arg[1]))
local function parse(s)
	local m,e=fixed.parse(s)
	return ffi.new('randomroc_fixed',{m,e})
end
local seed=string.rep('\0',31)..string.char(42)
local left,right=oracle.new(seed),oracle.new(seed)
local reads={}
local fill=ffi.cast('randomroc_fill_fn',function(_,out,count)
	reads[#reads+1]=tonumber(count)
	local bytes=right:bytes(tonumber(count))
	ffi.copy(out,bytes,#bytes)
	return 0
end)
local first,second=parse('1.5'),parse('0.75')
local alpha,beta=parse('0.25'),parse('4')
local out=ffi.new('randomroc_fixed[1]')
local integer=ffi.new('int64_t[1]')
local checks=0
for _=1,50 do
	for _,op in ipairs({'uniform','normal','exponential','poisson','log_normal','beta','range','normal_int'}) do
		local status,m,e
		if op=='uniform' then status=ffi_callback(lib, 'randomroc_uniform', fill,nil,out); m,e=left:uniform()
		elseif op=='normal' then status=ffi_callback(lib, 'randomroc_normal', fill,nil,first,second,out); m,e=left:normal(first.m,first.e,second.m,second.e)
		elseif op=='exponential' then status=ffi_callback(lib, 'randomroc_exponential', fill,nil,first,out); m,e=left:exponential(first.m,first.e)
		elseif op=='poisson' then status=ffi_callback(lib, 'randomroc_poisson', fill,nil,first,integer); m=left:poisson(first.m,first.e)
		elseif op=='log_normal' then status=ffi_callback(lib, 'randomroc_log_normal', fill,nil,first,second,out); m,e=left:log_normal(first.m,first.e,second.m,second.e)
		elseif op=='beta' then status=ffi_callback(lib, 'randomroc_beta', fill,nil,alpha,beta,out); m,e=left:beta(alpha.m,alpha.e,beta.m,beta.e)
		elseif op=='range' then status=ffi_callback(lib, 'randomroc_range', fill,nil,-100,100,integer); m=left:range(-100,100)
		else status=ffi_callback(lib, 'randomroc_normal_int', fill,nil,-100,100,integer); m=left:normal_int(-100,100) end
		assert(status==0,op..' status '..status)
		if e then assert(out[0].m==m and out[0].e==e,op..' value')
		else assert(integer[0]==m,op..' integer') end
		assert(left:position()==right:position(),op..' source cursor')
		assert(lib.randomroc_debug_live()==0,op..' retained allocations')
		checks=checks+1
	end
end
fill:free()
local requests=0
for _,error in ipairs({1,2,3,4,5,99}) do
	fill=ffi.cast('randomroc_fill_fn',function() requests=requests+1; return error end)
	out[0].m=123;out[0].e=456
	assert(ffi_callback(lib, 'randomroc_uniform', fill,nil,out)==(error<=5 and error or 2))
	assert(out[0].m==123 and out[0].e==456)
	assert(lib.randomroc_debug_live()==0)
	fill:free()
end
assert(requests==6)
fill=ffi.cast('randomroc_fill_fn',function() error('invalid argument read source') end)
assert(ffi_callback(lib, 'randomroc_uniform', nil,nil,out)==1)
assert(ffi_callback(lib, 'randomroc_uniform', fill,nil,nil)==1)
assert(ffi_callback(lib, 'randomroc_normal', fill,nil,ffi.new('randomroc_fixed',{1,0}),second,out)==1)
assert(ffi_callback(lib, 'randomroc_exponential', fill,nil,ffi.new('randomroc_fixed',{0,0}),out)==1)
assert(ffi_callback(lib, 'randomroc_range', fill,nil,100,0,integer)==1)
fill:free()
print('Roc native sampler API: '..checks..' exact values/cursors and callback/refusal/ownership controls passed.')
