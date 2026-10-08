-- Independent fresh-reviewer oracle; cases within explicit arithmetic margins
-- are counted as ambiguous, not silently judged correct or proven.
package.path = "experiments/?.lua;" .. package.path
local ffi = require("ffi")
local m = require("mpfr")
m.precision = 512
ffi.cdef[[
typedef struct { int64_t m; int32_t e; } reviewer_pair;
void experiment_strip(uint8_t, reviewer_pair *, reviewer_pair *, uint64_t *);
int experiment_words(const uint64_t *, size_t, size_t *, reviewer_pair *);
]]
local lib = ffi.load(assert(arg[1]))
local zero, one, two = m.new(0), m.new(1), m.new(2)
local x, y, k = {}, {}, {}
for i = 0,255 do
	local a,b,c = ffi.new("reviewer_pair[1]"),ffi.new("reviewer_pair[1]"),ffi.new("uint64_t[1]")
	lib.experiment_strip(i,a,b,c)
	x[i],y[i],k[i] = m.fixed(a[0].m,a[0].e),m.fixed(b[0].m,b[0].e),c[0]
end
y[256] = one
local S = 36028797018963968ULL
local vcoords = {0ULL,S/4ULL,S/2ULL,3ULL*(S/4ULL),S-1ULL}
local function header(i,negative,j) return j*512ULL+i+(negative and 256ULL or 0ULL) end
local words,out,used = ffi.new("uint64_t[5]"),ffi.new("reviewer_pair[1]"),ffi.new("size_t[1]")
local passed, ambiguous = 0,0
for i = 1,255 do
	for _,j in ipairs({k[i],(k[i]+S-1ULL)/2ULL,S-1ULL}) do
		for _,v in ipairs(vcoords) do
			local xx = m.mul(m.shift(m.new(j),-55),x[i])
			local yy = m.add(y[i],m.mul(m.shift(m.new(v),-55),m.sub(y[i+1],y[i])))
			local f = m.exp(m.div(m.sub(zero,m.mul(xx,xx)),two))
			local gap = m.sub(f,yy)
			if m.cmp(m.abs(gap),m.new("1e-15")) < 0 then ambiguous = ambiguous+2
			else
				local accept = m.cmp(gap,zero) > 0
				for _,negative in ipairs({false,true}) do
					words[0],words[1],words[2] = header(i,negative,j),header(0,false,v),header(42,false,123ULL)
					assert(lib.experiment_words(words,3,used,out) == 0,"wedge stream failure")
					assert(tonumber(used[0]) == (accept and 2 or 3),"MPFR wedge decision strip="..i)
					if accept then
						local expected = negative and m.sub(zero,xx) or xx
						assert(m.cmp(m.abs(m.sub(m.fixed(out[0].m,out[0].e),expected)),m.new("4e-18")) < 0,"wedge output magnitude")
					end
					passed = passed+1
				end
			end
		end
	end
end
local tcoords = {0ULL,1ULL,S/3ULL,S/2ULL,3ULL*(S/4ULL),S-1ULL}
for _,a in ipairs(tcoords) do for _,b in ipairs(tcoords) do
	local t = m.div(m.sub(zero,m.log(m.shift(m.new(a+1ULL),-55))),x[1])
	local yy = m.sub(zero,m.log(m.shift(m.new(b+1ULL),-55)))
	local gap = m.sub(m.mul(two,yy),m.mul(t,t))
	if m.cmp(m.abs(gap),m.new("1e-14")) < 0 then ambiguous = ambiguous+2
	else
		local accept = m.cmp(gap,zero) >= 0
		for _,negative in ipairs({false,true}) do
			words[0],words[1],words[2],words[3],words[4] = header(0,negative,S-1ULL),header(0,false,a),header(0,false,b),18446744073709551615ULL,18446744073709551615ULL
			assert(lib.experiment_words(words,5,used,out) == 0,"tail stream failure")
			assert(tonumber(used[0]) == (accept and 3 or 5),"MPFR tail decision")
			passed = passed+1
		end
	end
end end
print("Independent MPFR scripted decision checks passed="..passed.." ambiguous-boundary cases excluded="..ambiguous)
