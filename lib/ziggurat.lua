-- Pure integer-only 256-strip normal sampler. The caller supplies BE U64 words.
local ffi = require("ffi")
local fx = require("fixed")
local strips = require("ziggurat_tables")
local function unit(n)
	if n == 0 then return 0LL, 0 end
	return fx.norm(ffi.cast("int64_t", n), 7)
end
local function signed(m, e, negative)
	return negative and -m or m, e
end

-- Strip/sign/coordinate occupy disjoint bits. Wedge rejection reselects the
-- strip; tail retries keep its sign. No spare normal or ambient RNG is retained.
local function normal(next_word)
	while true do
		local word = next_word()
		local index = tonumber(word % 256ULL)
		local negative = (word / 256ULL) % 2ULL ~= 0
		local j = word / 512ULL
		local strip = strips[index + 1]
		local um, ue = unit(j)
		local xm, xe = fx.mul(um, ue, strip[1], strip[2])
		if j < strip[5] then return signed(xm, xe, negative) end
		if index == 0 then
			local r = strips[2]
			while true do
				local tm, te = unit(next_word() / 512ULL + 1ULL)
				tm, te = fx.ln(tm, te)
				tm, te = fx.div(-tm, te, r[1], r[2])
				local ym, ye = unit(next_word() / 512ULL + 1ULL)
				ym, ye = fx.ln(ym, ye)
				ym, ye = fx.add(-ym, ye, -ym, ye)
				local sm, se = fx.mul(tm, te, tm, te)
				if fx.cmp(ym, ye, sm, se) >= 0 then
					local m, e = fx.add(r[1], r[2], tm, te)
					return signed(m, e, negative)
				end
			end
		end
		local hm, he
		if index == 255 then hm, he = fx.from_int(1)
		else hm, he = strips[index + 2][3], strips[index + 2][4] end
		local dm, de = fx.sub(hm, he, strip[3], strip[4])
		um, ue = unit(next_word() / 512ULL)
		local ym, ye = fx.mul(um, ue, dm, de)
		ym, ye = fx.add(strip[3], strip[4], ym, ye)
		local pm, pe = fx.mul(xm, xe, xm, xe)
		if pm ~= 0 then pe = pe - 1 end
		pm, pe = fx.exp(-pm, pe)
		if fx.cmp(ym, ye, pm, pe) < 0 then return signed(xm, xe, negative) end
	end
end
return {normal = normal}
