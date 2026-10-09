-- Exact CLI text checksum from experimental samples, outside timed processes.
-- It covers formatting/newlines as well as the intended sampler work.
package.path = "lib/?.lua;" .. package.path
local ffi, fx = require("ffi"), require("fixed")
ffi.cdef[[
typedef struct { int64_t m; int32_t e; } cli_expected_pair;
int experiment_samples(uint64_t,uint8_t,uint8_t,size_t,cli_expected_pair *);
int randomz_fixed_format(cli_expected_pair,size_t,char *,size_t,size_t *);
]]
local lib = ffi.load(assert(arg[1]))
local count, seed = assert(tonumber(arg[2])), assert(tonumber(arg[3]))
local half_m, half_e = fx.from_int(1); half_e = half_e-1
local samples = ffi.new("cli_expected_pair[?]",count)
local buffer, written = ffi.new("char[512]"), ffi.new("size_t[1]")
local function fold(sum,text)
	for i=1,#text do sum = sum*128ULL + sum/144115188075855872ULL + text:byte(i) end
	return sum
end
io.write('{')
for a, algorithm in ipairs({"before","after"}) do
	if a>1 then io.write(',') end
	io.write('"',algorithm,'":{')
	for op, name in ipairs({"normal","integer","lognormal","beta"}) do
		assert(lib.experiment_samples(seed, a==1 and 0 or 2, op-1, count, samples)==0)
		local sum = 0ULL
		for i=0,count-1 do
			local x = samples[i]
			local text
			if op==1 or op==2 then
				local m,e = x.m,tonumber(x.e)
				if op==1 then
					if m<0 then m,e=fx.sub(m,e,half_m,half_e) else m,e=fx.add(m,e,half_m,half_e) end
				end
				text = string.format("%.0f",fx.to_int_trunc(m,e))
			else
				assert(lib.randomz_fixed_format(x,18,buffer,512,written)==0)
				text = ffi.string(buffer,written[0])
			end
			sum = fold(sum,text.."\n")
		end
		if op>1 then io.write(',') end
		io.write('"',name,'":"',tostring(sum):gsub("ULL$",""),'"')
	end
	io.write('}')
end
io.write('}\n')
