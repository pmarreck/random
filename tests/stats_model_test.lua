-- The CLI's custom normal is integer-rounded, not a continuous Gaussian.
local model = dofile('tests/rounded_normal_model.lua')
local count = 0
local function check(ok, message) count=count+1; assert(ok,message) end
local observed = {
	{2971,40076,226039,598123,894539,987768,999433},
	{2867,39711,226022,598464,894247,987924,999471},
	{3027,40051,226401,598767,894401,987661,999406},
}
for _, counts in ipairs(observed) do
	local r=model.from_counts(counts,1000000,.01/3)
	check(r.ok,'preserved million-value rounded-normal specificity fixture rejected')
	check(r.max_error<.00061,'unexpected rounded-normal CDF discrepancy')
end
local bad = {
	-- The previous continuous-null interpretation must not pass the rounded law.
	{1350,22750,158655,500000,841345,977250,998650},
	{0,0,0,1000000,1000000,1000000,1000000},
	{0,1000000,1000000,1000000,1000000,1000000,1000000},
}
for _, counts in ipairs(bad) do check(not model.from_counts(counts,1000000,.01/3).ok,'wrong law accepted') end
for _, counts in ipairs({{1,2,3}, {-1,0,0,0,0,0,0}, {3,2,4,5,6,7,8}, {0,0,0,0,0,0,1000001},
	{0,0,0,0.5,1,2,3}}) do
	check(not model.from_counts(counts,1000000,.01).ok,'invalid cumulative counts accepted')
end
for _, n in ipairs({0,-1,1.5,math.huge}) do check(not model.from_counts(observed[1],n,.01).ok,'invalid N accepted') end
for _, alpha in ipairs({0,-.1,1,math.huge}) do check(not model.from_counts(observed[1],1000000,alpha).ok,'invalid alpha accepted') end
check(not model.from_values({5.1,5.9},.01).ok,'noninteger support accepted')
check(not model.from_values({0/0,5},.01).ok,'nonfinite support accepted')
local values={}
for _, item in ipairs({{-1,3},{1,37},{3,187},{5,372},{7,295},{9,94},{11,11},{12,1}}) do
	for _=1,item[2] do values[#values+1]=item[1] end
end
check(model.from_values(values,.01).ok,'rounded fixture value adapter rejected')
local function copy(items)
	local result={};for k,v in pairs(items) do result[k]=v end;return result
end
-- Lua's length and ipairs do not establish a dense array: holes can hide data.
for _, hole in ipairs({2,4,7}) do
	local counts=copy(observed[1]);counts[hole]=nil
	check(not model.from_counts(counts,1000000,.01/3).ok,'holey cumulative counts accepted')
end
for _, key in ipairs({0,8,1.5,'extra'}) do
	local counts=copy(observed[1]);counts[key]=0
	check(not model.from_counts(counts,1000000,.01/3).ok,'extra CDF key accepted')
end
check(not model.from_values({5,nil,5},.01).ok,'holey values accepted')
for _, key in ipairs({0,1002,1.5,'extra'}) do
	local malformed=copy(values);malformed[key]=5
	check(not model.from_values(malformed,.01).ok,'extra values key accepted')
end
-- Independent high-precision target: Phi((k+1/2-5)/2), not Phi((k-5)/2).
package.path='experiments/?.lua;'..package.path
local m=require('mpfr');m.precision=512
local zero,two=m.new(0),m.new(2)
local function phi(z) return m.div(m.erfc(m.div(m.sub(zero,z),m.sqrt(two))),two) end
for i,k in ipairs(model.thresholds) do
	local p=phi(m.div(m.sub(m.add(m.new(k),m.new('.5')),m.new(5)),two))
	check(math.abs(m.number(p)-model.cdf[i])<1e-15,'MPFR rounded-normal reference differs')
end
local variance=m.new(0)
for j=-64,64 do
	local lo=phi(m.div(m.sub(m.new(j),m.new('.5')),two))
	local hi=phi(m.div(m.add(m.new(j),m.new('.5')),two))
	variance=m.add(variance,m.mul(m.new(j*j),m.sub(hi,lo)))
end
check(math.abs(m.number(variance)-model.variance)<1e-14,'MPFR rounded variance reference differs')
print(('Statistical model: %d rounded-normal specificity/refusal/MPFR controls passed'):format(count))
