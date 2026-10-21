-- Statistical null for round(N(5,2)), matching custom-normal CLI output.
-- Phi((k+1/2-5)/2) and variance references are independently checked with MPFR.
local M = {
	thresholds={-1,1,3,5,7,9,11},
	cdf={.002979763235054555,.040059156863817086,.2266273523768682,
		.5987063256829237,.8943502263331446,.9877755273449553,.9994229749576092},
	variance=4.083333333333333,
}
local function finite(x) return type(x)=='number' and x==x and math.abs(x)<math.huge end
local function invalid(reason) return {ok=false,reason=reason,max_error=math.huge,epsilon=0} end
local function dense_length(items)
	if type(items)~='table' then return nil end
	local count,maximum=0,0
	for k in next,items do
		if not finite(k) or k<1 or k~=math.floor(k) then return nil end
		count=count+1;maximum=math.max(maximum,k)
	end
	if count~=maximum then return nil end
	return count
end

-- Evaluate cumulative integer counts against a simultaneous DKW envelope.
-- The statistical interpretation assumes IID target-law draws, not proved DRBG IID.
function M.from_counts(counts,n,alpha)
	if not finite(n) or n<1 or n>9007199254740992 or n~=math.floor(n) then return invalid('sample count') end
	if not finite(alpha) or alpha<=0 or alpha>=1 then return invalid('alpha') end
	if dense_length(counts)~=#M.cdf then return invalid('CDF count shape') end
	local previous,max_error=0,0
	for i=1,#M.cdf do
		local c=rawget(counts,i)
		if not finite(c) or c<previous or c>n or c~=math.floor(c) then return invalid('cumulative counts') end
		max_error=math.max(max_error,math.abs(c/n-M.cdf[i]));previous=c
	end
	local epsilon=math.sqrt(math.log(2/alpha)/(2*n))
	return {ok=max_error<=epsilon,max_error=max_error,epsilon=epsilon,n=n}
end

-- Derive support and counts from actual values instead of trusting producer labels.
function M.from_values(values,alpha)
	local n=dense_length(values)
	if not n then return invalid('values') end
	local counts={0,0,0,0,0,0,0}
	for j=1,n do
		local v=rawget(values,j)
		if not finite(v) or v~=math.floor(v) then return invalid('integer support') end
		for i,k in ipairs(M.thresholds) do if v<=k then counts[i]=counts[i]+1 end end
	end
	local result=M.from_counts(counts,n,alpha)
	result.integer_support=true
	return result
end
return M
