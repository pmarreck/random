local ffi=require('ffi')
local ffi_callback = dofile(assert(os.getenv('RANDOM_PROJECT_ROOT'))..'/tests/ffi_callback.lua')
ffi.cdef[[
typedef struct { int64_t m; int32_t e; } domain_fixed;
typedef int (*domain_fill)(void *, uint8_t *, size_t);
int randomz_normal(domain_fill,void*,domain_fixed,domain_fixed,domain_fixed*);
int randomroc_normal(domain_fill,void*,domain_fixed,domain_fixed,domain_fixed*);
int randomz_exponential(domain_fill,void*,domain_fixed,domain_fixed*);
int randomroc_exponential(domain_fill,void*,domain_fixed,domain_fixed*);
int randomz_poisson(domain_fill,void*,domain_fixed,int64_t*);
int randomroc_poisson(domain_fill,void*,domain_fixed,int64_t*);
int randomz_log_normal(domain_fill,void*,domain_fixed,domain_fixed,domain_fixed*);
int randomroc_log_normal(domain_fill,void*,domain_fixed,domain_fixed,domain_fixed*);
int randomz_beta(domain_fill,void*,domain_fixed,domain_fixed,domain_fixed*);
int randomroc_beta(domain_fill,void*,domain_fixed,domain_fixed,domain_fixed*);
]]
local z=ffi.load(assert(os.getenv('RANDOM_ROC_ORACLE_LIBRARY')))
local r=ffi.load(assert(os.getenv('RANDOM_ROC_SHARED_LIBRARY')))
local function p(m,e)return ffi.new('domain_fixed',{m,e})end
local one,zero=p(4611686018427387904LL,0),p(0,0)
local cases={
	{'normal',zero,zero},{'normal',p(4611686018427387904LL,-1000001),one},
	{'normal',zero,p(4611686018427387904LL,1000001)},
	{'normal',p(4611686018427387904LL,-1000001),zero},
	{'normal',p(1,0),one},{'normal',p(0,1),one},
	{'exponential',zero},{'exponential',p(-4611686018427387904LL,0)},
	{'exponential',p(4611686018427387904LL,-1000001)},
	{'poisson',p(4611686018427387904LL,20)},{'poisson',zero},
	{'log_normal',p(4611686018427387904LL,28),one},
	{'log_normal',zero,p(4611686018427387904LL,24)},
	{'beta',p(4611686018427387904LL,21),one},
	{'beta',one,p(4611686018427387904LL,-21)},
	{'beta',zero,one},{'beta',one,p(-4611686018427387904LL,0)},
}
local calls=0
local source=ffi.cast('domain_fill',function()calls=calls+1;return 2 end)
local output,integer=ffi.new('domain_fixed[1]'),ffi.new('int64_t[1]')
local fails=0
for index,c in ipairs(cases) do
	local function invoke(lib,prefix)
		output[0].m=123;output[0].e=456;integer[0]=123
		local status
		if c[1]=='poisson' then status=ffi_callback(lib, prefix..c[1], source,nil,c[2],integer)
		elseif c[1]=='exponential' then status=ffi_callback(lib, prefix..c[1], source,nil,c[2],output)
		else status=ffi_callback(lib, prefix..c[1], source,nil,c[2],c[3],output) end
		assert(calls==0 and output[0].m==123 and output[0].e==456 and integer[0]==123)
		return status
	end
	local expected,actual=invoke(z,'randomz_'),invoke(r,'randomroc_')
	if expected~=actual then print('domain mismatch '..index..': '..c[1]..' status '..actual..' expected '..expected);fails=fails+1 end
end
source:free()
assert(fails==0,tostring(fails)..' admission classification mismatches')
print('Roc sampler domains: '..#cases..' exact Zig statuses, no reads or output mutation.')
