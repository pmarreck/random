local ffi = require('ffi')
package.path = (assert(os.getenv('RANDOM_PROJECT_ROOT'))..'/lib/?.lua;')..package.path
local f, g = require('fixed'), require('geometric')
ffi.cdef[[
typedef struct {int64_t m;int32_t e;} chart_fixed;
int randomz_distribution_curve(int,chart_fixed,chart_fixed,uint16_t*,size_t,size_t*,chart_fixed*,chart_fixed*);
int randomroc_distribution_curve(int,chart_fixed,chart_fixed,uint16_t*,size_t,size_t*,chart_fixed*,chart_fixed*);
size_t randomroc_debug_live(void);
]]
local z=ffi.load(assert(os.getenv('RANDOM_ROC_ORACLE_LIBRARY')))
local r=ffi.load(assert(os.getenv('RANDOM_ROC_SHARED_LIBRARY')))
local heights,written,lo,hi=ffi.new('uint16_t[4099]'),ffi.new('size_t[1]'),ffi.new('chart_fixed[1]'),ffi.new('chart_fixed[1]')
local shapes={
	{1,'-1','0.125'},{1,'0','1'},{1,'5','2.5'},
	{2,'0.125','0'},{2,'1','0'},{2,'8','0'},
	{3,'0.000001','0'},{3,'0.5','0'},{3,'3','0'},{3,'50','0'},{3,'500000','0'},
	{4,'-2','0.5'},{4,'0','1'},{4,'5','3'},{4,'0','10'},
	{5,'0.25','0.5'},{5,'1','1'},{5,'1','3'},{5,'2','2'},{5,'3','4'},{5,'1048576','0.125'},
	{6,'1','0'},{6,'0.99','0'},{6,'0.5','0'},{6,'0.0625','0'},{6,'0.05','0'},
	{6,'2^-64','0'},{6,'2^-1000000','0'},
}
local function compare(kind,a,b,capacity)
	local function invoke(lib,prefix)
		ffi.fill(heights,ffi.sizeof(heights),0xa5);written[0]=999
		lo[0].m=123;lo[0].e=456;hi[0].m=789;hi[0].e=321
		local status=lib[prefix..'distribution_curve'](kind,a,b,heights+1,capacity,written,lo,hi)
		assert(heights[0]==0xa5a5 and heights[capacity+1]==0xa5a5)
		return status,tonumber(written[0]),ffi.string(heights,ffi.sizeof(heights)),
			tostring(lo[0].m)..','..lo[0].e..';'..tostring(hi[0].m)..','..hi[0].e
	end
	local zs,zw,zh,zb=invoke(z,'randomz_');local rs,rw,rh,rb=invoke(r,'randomroc_')
	assert(zs==rs and zw==rw and zh==rh and zb==rb,
		'kind='..kind..' cap='..capacity..' status='..rs..'/'..zs..' written='..rw..'/'..zw)
	assert(r.randomroc_debug_live()==0)
end
local checks=0
for _,shape in ipairs(shapes) do
	local am,ae
	if shape[1]==6 then am,ae=g.parse_probability(shape[2]) else am,ae=f.parse(shape[2]) end
	local bm,be=f.parse(shape[3])
	for _,capacity in ipairs({2,3,5,17,96,310,4096}) do
		compare(shape[1],ffi.new('chart_fixed',{am,ae}),ffi.new('chart_fixed',{bm,be}),capacity)
		checks=checks+1
	end
end
local one,zero=ffi.new('chart_fixed',{4611686018427387904LL,0}),ffi.new('chart_fixed',{0,0})
local extreme=ffi.new('chart_fixed',{4611686018427387904LL,1000001})
for _,kind in ipairs({0,1,2,3,4,5,6,7}) do
	for _,capacity in ipairs({0,1,2,4097}) do
		compare(kind,one,zero,capacity);checks=checks+1
	end
end
for _,kind in ipairs({1,4,5}) do
	compare(kind,extreme,zero,17);checks=checks+1
end
assert(checks==231)
print('Roc chart FFI: '..checks..' exact Zig heights/bounds, error precedence, capacity, mutation and ownership checks passed.')
