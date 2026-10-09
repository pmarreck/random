-- Direct LuaJIT FFI consumer of the real custom-platform shared library.
-- No delegated sampler or payload files; exact values come from the Lua oracle.
package.path=assert(arg[2],'oracle library directory required')..'/?.lua;'..package.path
local ffi=require('ffi')
ffi.cdef[[
int roc_probe_fixed(int64_t m,int32_t e,int64_t *out_m,int32_t *out_e);
int roc_probe_init(const uint8_t seed[32],uint8_t key[32]);
int roc_probe_fill(const uint8_t key[32],uint64_t position,uint8_t *out,size_t count);
int roc_probe_normal(const uint8_t key[32],uint64_t position,int64_t *m,int32_t *e,uint64_t *next);
size_t roc_probe_live(void);
]]
local native=ffi.load(assert(arg[1],'shared library path required'))
local f,d=require('fixed'),require('drbg')
local m,e=ffi.new('int64_t[1]'),ffi.new('int32_t[1]')
local expected_m,expected_e=f.ln(0x6000000000000003LL,20)
assert(native.roc_probe_fixed(0x6000000000000003LL,20,m,e)==0)
assert(m[0]==expected_m and e[0]==expected_e)
assert(native.roc_probe_fixed(-0x4000000000000000LL,0,m,e)~=0)
assert(m[0]==expected_m and e[0]==expected_e,'invalid ln modified output')
assert(native.roc_probe_live()==0,'retained Roc allocations after numeric API')
local seed=string.rep('\0',31)..string.char(42)
local state=d.new(seed)
local key=ffi.new('uint8_t[32]')
assert(native.roc_probe_init(seed,key)==0)
local exported=state:state()
assert(ffi.string(key,32)==exported.key)
assert(native.roc_probe_live()==0,'retained Roc allocations after init')
local out=ffi.new('uint8_t[197]')
for _,position in ipairs({0,63,64,65,274877906879,274877906944,9007199254740795}) do
	state=d.from_state({key=exported.key,position=position})
	assert(native.roc_probe_fill(key,position,out,197)==0)
	assert(ffi.string(out,197)==state:bytes(197))
	assert(native.roc_probe_live()==0,'retained Roc allocations after fill')
end
ffi.fill(out,197,0xa5)
assert(native.roc_probe_fill(key,9007199254740992,out,1)~=0)
assert(ffi.string(out,197)==string.rep(string.char(0xa5),197),'overflow modified output')
assert(native.roc_probe_fill(key,9007199254740992,out,0)==0)
assert(native.roc_probe_live()==0,'retained Roc allocations after refusal/empty fill')
local next=ffi.new('uint64_t[1]')
state=d.from_state({key=exported.key,position=0})
for index=1,1000 do
	local start=state:position()
	local em,ee=state:normal(0LL,0,0x4000000000000000LL,0)
	assert(native.roc_probe_normal(key,start,m,e,next)==0)
	assert(m[0]==em and e[0]==ee and next[0]==state:position())
	assert(native.roc_probe_live()==0,'retained Roc allocations after sampler')
end
print('Native Roc platform: numeric, DRBG, 1000 sampler and ownership witnesses passed.')
