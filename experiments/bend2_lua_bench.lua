-- Public LuaJIT DRBG API comparison, with checked Linux CPU/wall clocks.
package.path = "./lib/?.lua;" .. package.path
local ffi, bit = require("ffi"), require("bit")
local drbg, blake3 = require("drbg"), require("blake3")
assert(ffi.os == "Linux" and ffi.abi("64bit"), "probe currently requires 64-bit Linux")
assert(jit.status(), "benchmark requires enabled LuaJIT")
ffi.cdef[[struct random_bend_timespec { long tv_sec; long tv_nsec; };
int clock_gettime(int clock_id, struct random_bend_timespec *stamp);]]
local stamp = ffi.new("struct random_bend_timespec[1]")
local function clock(kind)
	assert(ffi.C.clock_gettime(kind, stamp) == 0, "clock failed")
	assert(stamp[0].tv_sec >= 0 and stamp[0].tv_sec < 18446744073LL and
		stamp[0].tv_nsec >= 0 and stamp[0].tv_nsec < 1000000000, "invalid clock")
	return ffi.new("uint64_t", stamp[0].tv_sec) * 1000000000ULL +
		ffi.cast("uint64_t", stamp[0].tv_nsec)
end
local kind, n, repeats, expected, first, warm, seed = tonumber(arg[1]), tonumber(arg[2]),
	tonumber(arg[3]), tonumber(arg[4]), tonumber(arg[5]), tonumber(arg[6]), tonumber(arg[7])
local function whole(value, lo, hi)
	return value and value == math.floor(value) and value >= lo and value <= hi
end
assert(#arg == 7 and whole(kind,0,2) and whole(n,1,8192) and
	whole(repeats,1,1000000) and whole(expected,0,4294967295) and
	whole(first,0,4294967295) and whole(warm,0,4294967295) and
	whole(seed,0,4294967295), "kind size repeats batch-checksum first-checksum warm-checksum seed required")
local template = drbg.new(blake3.hex_to_bin(string.format("%064x", seed)))
local function mix(h, value) return bit.bxor(bit.rol(h, 5), value) end
local function work(source, hash)
	if kind == 0 then
		local bytes = source:bytes(n)
		assert(#bytes == n, "incorrect byte count")
		for i=1,#bytes do hash = mix(hash, bytes:byte(i)) end
	else
		local last = kind == 1 and 6 or 4503599627370496
		for _=1,n do
			local value = source:range(1, last)
			hash = mix(mix(hash, value % 4294967296), math.floor(value / 4294967296))
		end
	end
	return hash < 0 and hash + 4294967296 or hash
end
local function batch(count)
	local source, hash = template:with_position(0), 0
	for _=1,count do hash = work(source, hash) end
	return hash
end
local function settle()
	local previous = math.huge
	for _=1,32 do
		collectgarbage("collect")
		local current = collectgarbage("count")
		if current >= previous then return end
		previous = current
	end
	error("heap did not settle outside timing")
end
assert(batch(1) == first, "incorrect first work")
io.write("READY\n"); io.flush()
assert(batch(3) == warm, "incorrect warmup")
local cpu, wall = {}, {}
for sample=1,7 do
	settle()
	local w0, c0 = clock(1), clock(2)
	local result = batch(repeats)
	local c1, w1 = clock(2), clock(1)
	assert(result == expected, "incorrect timed work")
	assert(c1 > c0 and w1 > w0, "nonpositive clock interval")
	cpu[sample] = math.floor(tonumber(c1-c0) / repeats)
	wall[sample] = math.floor(tonumber(w1-w0) / repeats)
	assert(cpu[sample] > 0 and wall[sample] > 0, "zero normalized sample")
end
local status = assert(io.open("/proc/self/status", "r"))
local rss
for line in status:lines() do rss = rss or tonumber(line:match("^VmHWM:%s+(%d+) kB")) end
assert(status:close() and rss, "RSS unavailable")
io.write(string.format('{"schema":"performance-measurement/v1","correct":true,' ..
	'"build_mode":"optimized","backend_build_mode":"LuaJIT-JIT","allocator_coverage":"Lua/native allocation counters unavailable; supplemental high-water RSS only",' ..
	'"source_backend":"LuaJIT production DRBG with fresh with_position state per sample",' ..
	'"rss_method":"Linux /proc/self/status VmHWM; supplemental approximate post-exec high water",' ..
	'"heap_settled":true,"iterations":%d,"peak_rss_bytes":%.0f,' ..
	'"rows":[{"size":%d,"samples":{"cpu_ns":[%s],"wall_ns":[%s]}}]}\n',
	repeats,rss*1024,n,table.concat(cpu,","),table.concat(wall,",")))
