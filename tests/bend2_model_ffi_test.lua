-- The already-independent Zig implementation judges native Bend's public
-- numeric/model ABI, including refusal precedence and untouched output guards.
local ffi = require('ffi')
ffi.cdef[[typedef struct {int64_t m;int32_t e;} model_fixed;]]
for _, prefix in ipairs({'randomz_', 'randomb_'}) do
	local declarations = ([[
model_fixed @fixed_from_int(int64_t);
int @fixed_to_int_trunc(model_fixed,int64_t*);
int @fixed_to_int_round(model_fixed,int64_t*);
int @fixed_parse(const char*,size_t,model_fixed*);
int @geometric_probability_parse(const char*,size_t,model_fixed*);
int @fixed_parse_int_safe(const char*,size_t,int64_t*);
int @fixed_format(model_fixed,size_t,char*,size_t,size_t*);
int @distribution_curve(int,model_fixed,model_fixed,uint16_t*,size_t,size_t*,model_fixed*,model_fixed*);
]]):gsub('@', prefix)
	ffi.cdef(declarations)
end
local candidate = ffi.load(assert(arg[1], 'Bend shared library required'))
local oracle = ffi.load(assert(arg[2], 'Zig oracle shared library required'))
local output, integer = ffi.new('model_fixed[1]'), ffi.new('int64_t[1]')
local written, buffer = ffi.new('size_t[1]'), ffi.new('char[4098]')
local checks = 0
local function compare(call, label)
	local a, b = {call(oracle, 'randomz_')}, {call(candidate, 'randomb_')}
	assert(#a == #b)
	for i = 1, #a do assert(a[i] == b[i], label .. ' field ' .. i .. ': ' .. tostring(b[i]) .. '/' .. tostring(a[i])) end
	checks = checks + 1
end
for _, n in ipairs({0LL, 1LL, -1LL, 9007199254740992LL, -9007199254740992LL, 9223372036854775807LL, -9223372036854775807LL-1}) do
	compare(function(lib, prefix)
		local v = lib[prefix .. 'fixed_from_int'](n)
		return tostring(v.m), v.e
	end, 'from_int')
end
local raw = {'', '0', '-0', '1', '-1', '0.1', '+0.25', '  42\r\n', '1.99999999999999999999', '.5', '1.', '.',
	'9007199254740992', '9007199254740993', '-9007199254740992', '-9007199254740993',
	'1e-20', '2^-100', '0.0000000000000000001', '1\0', '\255', '1 2', string.rep('9', 2000), string.rep('9', 2001)}
for _, op in ipairs({'fixed_parse', 'geometric_probability_parse', 'fixed_parse_int_safe'}) do
	for _, text in ipairs(raw) do
		compare(function(lib, prefix)
			output[0].m = 123; output[0].e = 456; integer[0] = 789
			local status = lib[prefix .. op](text, #text, op == 'fixed_parse_int_safe' and integer or output)
			return status, tostring(output[0].m), output[0].e, tostring(integer[0])
		end, op .. ' len=' .. #text)
	end
end
for _, parts in ipairs({{0LL,0}, {1LL,0}, {0LL,1}, {4611686018427387904LL,-1000000},
	{4611686018427387904LL,-1}, {-4611686018427387904LL,-1}, {9223372036854775807LL,0},
	{-9223372036854775807LL,0}, {4611686018427387904LL,53}, {4611686018427387904LL,62}, {4611686018427387904LL,2043}}) do
	local value = ffi.new('model_fixed', parts)
	for _, op in ipairs({'fixed_to_int_trunc', 'fixed_to_int_round'}) do
		compare(function(lib, prefix)
			integer[0] = 789
			return lib[prefix .. op](value, integer), tostring(integer[0])
		end, op)
	end
	for _, places in ipairs({0, 1, 6, 18}) do
		for _, capacity in ipairs({0, 1, 2, 6, 19, 4096}) do
			compare(function(lib, prefix)
				ffi.fill(buffer, 4098, 0x5a); written[0] = 999
				local status = lib[prefix .. 'fixed_format'](value, places, buffer+1, capacity, written)
				return status, tonumber(written[0]), ffi.string(buffer, 4098)
			end, 'format m=' .. tostring(value.m) .. ' e=' .. value.e .. ' p=' .. places .. ' cap=' .. capacity)
		end
	end
end
package.path = './lib/?.lua;' .. package.path
local f, g = require('fixed'), require('geometric')
local heights, lo, hi = ffi.new('uint16_t[4099]'), ffi.new('model_fixed[1]'), ffi.new('model_fixed[1]')
local function curve(kind, a, b, capacity)
	compare(function(lib, prefix)
		ffi.fill(heights, ffi.sizeof(heights), 0xa5); written[0] = 999
		lo[0].m = 123; lo[0].e = 456; hi[0].m = 789; hi[0].e = 321
		local status = lib[prefix .. 'distribution_curve'](kind, a, b, heights+1, capacity, written, lo, hi)
		return status, tonumber(written[0]), ffi.string(heights, ffi.sizeof(heights)),
			tostring(lo[0].m), lo[0].e, tostring(hi[0].m), hi[0].e
	end, 'curve kind=' .. kind .. ' cap=' .. capacity)
end
local shapes = {{1,'-1','0.125'}, {1,'0','1'}, {1,'5','2.5'}, {2,'0.125','0'}, {2,'1','0'}, {2,'8','0'},
	{3,'0.000001','0'}, {3,'0.5','0'}, {3,'3','0'}, {3,'50','0'}, {3,'500000','0'},
	{4,'-2','0.5'}, {4,'0','1'}, {4,'5','3'}, {4,'0','10'},
	{5,'0.25','0.5'}, {5,'1','1'}, {5,'1','3'}, {5,'2','2'}, {5,'3','4'}, {5,'1048576','0.125'},
	{6,'1','0'}, {6,'0.99','0'}, {6,'0.5','0'}, {6,'0.0625','0'}, {6,'0.05','0'}, {6,'2^-64','0'}, {6,'2^-1000000','0'}}
for _, shape in ipairs(shapes) do
	local am, ae = (shape[1] == 6 and g.parse_probability or f.parse)(shape[2])
	local bm, be = f.parse(shape[3])
	for _, capacity in ipairs({2, 3, 5, 17, 96, 310, 4096}) do
		curve(shape[1], ffi.new('model_fixed', {am, ae}), ffi.new('model_fixed', {bm, be}), capacity)
	end
end
local one, zero = ffi.new('model_fixed', {4611686018427387904LL, 0}), ffi.new('model_fixed', {0, 0})
for _, kind in ipairs({0,1,2,3,4,5,6,7}) do
	for _, capacity in ipairs({0,1,2,4097}) do curve(kind, one, zero, capacity) end
end
for _, kind in ipairs({1,4,5}) do curve(kind, ffi.new('model_fixed', {4611686018427387904LL,1000001}), zero, 17) end
assert(checks == 596)
print('Bend model C ABI: ' .. checks .. ' exact Zig numeric/curve, refusal and output-mutation comparisons passed')
