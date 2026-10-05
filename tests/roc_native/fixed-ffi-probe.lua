local ffi = require('ffi')
ffi.cdef[[
typedef struct {int64_t m;int32_t e;} codec_fixed;
codec_fixed randomz_fixed_from_int(int64_t);
codec_fixed randomroc_fixed_from_int(int64_t);
int randomz_fixed_to_int_trunc(codec_fixed,int64_t*);
int randomroc_fixed_to_int_trunc(codec_fixed,int64_t*);
int randomz_fixed_to_int_round(codec_fixed,int64_t*);
int randomroc_fixed_to_int_round(codec_fixed,int64_t*);
int randomz_fixed_parse(const char*,size_t,codec_fixed*);
int randomroc_fixed_parse(const char*,size_t,codec_fixed*);
int randomz_geometric_probability_parse(const char*,size_t,codec_fixed*);
int randomroc_geometric_probability_parse(const char*,size_t,codec_fixed*);
int randomz_fixed_parse_int_safe(const char*,size_t,int64_t*);
int randomroc_fixed_parse_int_safe(const char*,size_t,int64_t*);
int randomz_fixed_format(codec_fixed,size_t,char*,size_t,size_t*);
int randomroc_fixed_format(codec_fixed,size_t,char*,size_t,size_t*);
size_t randomroc_debug_live(void);
]]
local z=ffi.load(assert(os.getenv('RANDOM_ROC_ORACLE_LIBRARY')))
local r=ffi.load(assert(os.getenv('RANDOM_ROC_SHARED_LIBRARY')))
local output,integer,written,buffer=ffi.new('codec_fixed[1]'),ffi.new('int64_t[1]'),ffi.new('size_t[1]'),ffi.new('char[4098]')
local checks=0
for _,n in ipairs({0LL,1LL,-1LL,9007199254740992LL,-9007199254740992LL,9223372036854775807LL,-9223372036854775807LL-1}) do
	local a,b=z.randomz_fixed_from_int(n),r.randomroc_fixed_from_int(n)
	assert(a.m==b.m and a.e==b.e);checks=checks+1
end
local raw={'','0','-0','1','-1','0.1','+0.25','  42\r\n','1.99999999999999999999','.5','1.','.',
	'9007199254740992','9007199254740993','-9007199254740992','-9007199254740993',
	'1e-20','2^-100','0.0000000000000000001','1\0','\255','1 2',string.rep('9',2000),string.rep('9',2001)}
for _,op in ipairs({'fixed_parse','geometric_probability_parse','fixed_parse_int_safe'}) do
	for _,text in ipairs(raw) do
		local function invoke(lib,prefix)
			output[0].m=123;output[0].e=456;integer[0]=789
			local status=lib[prefix..op](text,#text,op=='fixed_parse_int_safe' and integer or output)
			return status,tostring(output[0].m)..','..output[0].e..';'..tostring(integer[0])
		end
		local zs,zo=invoke(z,'randomz_');local rs,ro=invoke(r,'randomroc_')
		assert(zs==rs and zo==ro,op..' input len '..#text..' status '..rs..'/'..zs..' output '..ro..'/'..zo)
		assert(r.randomroc_debug_live()==0);checks=checks+1
	end
end
local fixed_values={{0LL,0},{1LL,0},{0LL,1},{4611686018427387904LL,-1000000},
	{4611686018427387904LL,-1},{-4611686018427387904LL,-1},
	{9223372036854775807LL,0},{-9223372036854775807LL,0},
	{4611686018427387904LL,53},{4611686018427387904LL,62},{4611686018427387904LL,2043}}
for _,parts in ipairs(fixed_values) do
	local value=ffi.new('codec_fixed',parts)
	for _,op in ipairs({'fixed_to_int_trunc','fixed_to_int_round'}) do
		local function invoke(lib,prefix)
			integer[0]=789;local status=lib[prefix..op](value,integer)
			return status,tostring(integer[0])
		end
		local zs,zo=invoke(z,'randomz_');local rs,ro=invoke(r,'randomroc_')
		assert(zs==rs and zo==ro,op);checks=checks+1
	end
	for _,places in ipairs({0,1,6,18}) do
		for _,capacity in ipairs({0,1,2,6,19,4096}) do
			local function invoke(lib,prefix)
				ffi.fill(buffer,4098,0x5a);written[0]=999
				local status=lib[prefix..'fixed_format'](value,places,buffer+1,capacity,written)
				assert(buffer[0]==0x5a and buffer[capacity+1]==0x5a)
				return status,tonumber(written[0]),status==0 and ffi.string(buffer+1,written[0]) or ''
			end
			local zs,zw,zo=invoke(z,'randomz_');local rs,rw,ro=invoke(r,'randomroc_')
			assert(zs==rs and zw==rw and zo==ro,'format m='..tostring(value.m)..' e='..value.e..' places='..places..' cap='..capacity..' status='..rs..'/'..zs)
			assert(r.randomroc_debug_live()==0);checks=checks+1
		end
	end
end
assert(checks==365)
print('Roc numeric FFI: '..checks..' exact Zig conversions, parsing, rendering, refusals and ownership controls passed.')
