local ffi = require('ffi')
ffi.cdef[[
typedef struct {uint8_t key[32];uint64_t position;} ffi_drbg;
int randomz_drbg_init(ffi_drbg*,const uint8_t*);
int randomroc_drbg_init(ffi_drbg*,const uint8_t*);
int randomz_drbg_set_state(ffi_drbg*,const uint8_t*,uint64_t);
int randomroc_drbg_set_state(ffi_drbg*,const uint8_t*,uint64_t);
int randomz_drbg_get_state(const ffi_drbg*,uint8_t*,uint64_t*);
int randomroc_drbg_get_state(const ffi_drbg*,uint8_t*,uint64_t*);
int randomz_drbg_seek(ffi_drbg*,uint64_t);
int randomroc_drbg_seek(ffi_drbg*,uint64_t);
int randomz_drbg_fill(ffi_drbg*,uint8_t*,size_t);
int randomroc_drbg_fill(ffi_drbg*,uint8_t*,size_t);
int randomz_drbg_u32(ffi_drbg*,uint32_t*);
int randomroc_drbg_u32(ffi_drbg*,uint32_t*);
int randomz_drbg_u64(ffi_drbg*,uint64_t*);
int randomroc_drbg_u64(ffi_drbg*,uint64_t*);
void randomz_drbg_zeroize(ffi_drbg*);
void randomroc_drbg_zeroize(ffi_drbg*);
size_t randomroc_debug_live(void);
]]
local z=ffi.load(assert(os.getenv('RANDOM_ROC_ORACLE_LIBRARY')))
local r=ffi.load(assert(os.getenv('RANDOM_ROC_SHARED_LIBRARY')))
local zs,rs=ffi.new('ffi_drbg[1]'),ffi.new('ffi_drbg[1]')
local zo,ro=ffi.new('uint8_t[1048611]'),ffi.new('uint8_t[1048611]')
local checks=0
local function same_state()
	assert(ffi.string(zs,40)==ffi.string(rs,40),'state mismatch')
	assert(r.randomroc_debug_live()==0)
end
local limit=9007199254740992ULL
for _,seed in ipairs({string.rep('\0',32),string.rep('\0',31)..string.char(42),string.rep('\255',32)}) do
	assert(z.randomz_drbg_init(zs,seed)==0 and r.randomroc_drbg_init(rs,seed)==0);same_state();checks=checks+1
	for _,position in ipairs({0ULL,1ULL,63ULL,64ULL,65ULL,274877906943ULL,274877906944ULL,limit-197,limit}) do
		assert(z.randomz_drbg_seek(zs,position)==r.randomroc_drbg_seek(rs,position));same_state()
		for _,count in ipairs({0,1,4,8,63,64,197}) do
			ffi.fill(zo,1048611,0xa5);ffi.fill(ro,1048611,0xa5)
			local a,b=z.randomz_drbg_fill(zs,zo+1,count),r.randomroc_drbg_fill(rs,ro+1,count)
			assert(a==b and ffi.string(zo,1048611)==ffi.string(ro,1048611),'fill count '..count)
			same_state();checks=checks+1
		end
		for _,bits in ipairs({32,64}) do
			local za,ra=ffi.new('uint'..bits..'_t[1]',123),ffi.new('uint'..bits..'_t[1]',123)
			assert(z['randomz_drbg_u'..bits](zs,za)==r['randomroc_drbg_u'..bits](rs,ra) and za[0]==ra[0]);same_state();checks=checks+1
		end
	end
	local key=ffi.new('uint8_t[32]');local pos=ffi.new('uint64_t[1]')
	assert(r.randomroc_drbg_get_state(rs,key,pos)==0)
	assert(ffi.string(key,32)==ffi.string(rs[0].key,32) and pos[0]==rs[0].position)
	assert(z.randomz_drbg_set_state(zs,key,pos[0])==0 and r.randomroc_drbg_set_state(rs,key,pos[0])==0);same_state()
	local before=ffi.string(rs,40)
	assert(r.randomroc_drbg_seek(rs,limit+1)==3 and ffi.string(rs,40)==before)
	assert(r.randomroc_drbg_set_state(rs,key,limit+1)==3 and ffi.string(rs,40)==before)
	assert(r.randomroc_drbg_fill(rs,nil,0)==0 and ffi.string(rs,40)==before)
	checks=checks+5
end
assert(z.randomz_drbg_seek(zs,0)==0 and r.randomroc_drbg_seek(rs,0)==0)
assert(z.randomz_drbg_fill(zs,zo+1,1048609)==0 and r.randomroc_drbg_fill(rs,ro+1,1048609)==0)
assert(ffi.string(zo+1,1048609)==ffi.string(ro+1,1048609));same_state();checks=checks+1
r.randomroc_drbg_zeroize(rs);assert(ffi.string(rs,40)==string.rep('\0',40));checks=checks+1
assert(checks==263)
print('Roc DRBG FFI: '..checks..' exact Zig key/state/byte/integer, O(1) seek, overflow, chunking and zeroization checks passed.')
