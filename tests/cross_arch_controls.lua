-- SENSITIVITY CONTROLS for tests/cross_arch_diff.
--
-- The cross-architecture suite's real assertion is a negative one: "these
-- toolchains produce identical output." A negative assertion is worthless
-- without evidence that the comparison could have come out positive. Two
-- things make "identical" vacuous, and this project has already shipped one of
-- them: a differential where BOTH invocations failed and both digests were of
-- empty stdout (see the handoff's list of five guards that could not detect
-- being broken). The other is subtler -- comparing outputs that have been
-- quantized (bin/random's default 0..99 integer range rounds away exactly the
-- last-ulp divergence the project exists to eliminate).
--
-- So this file supplies deliberately FRAGILE payloads: constructs whose results
-- are KNOWN to differ across the axes under test. cross_arch_diff requires them
-- to differ. If they ever agree, the harness has lost its ability to observe
-- divergence and every "identical" verdict it reports is unfalsifiable, so the
-- suite fails loudly rather than reporting a green it did not earn.
--
-- Measured on 2026-08-02, LuaJIT pinned to 2.1.1785606157 for all three legs:
--
--   control     x86_64-glibc vs x86_64-musl   x86_64-glibc vs aarch64-glibc
--   libm        DIFFER                        same
--   float2int   same                          DIFFER
--
-- The two are complementary, not redundant: neither one alone covers both
-- axes, and using only `libm` would have left the architecture axis -- the
-- headline claim -- with no demonstrated sensitivity at all.
--
-- Usage: luajit cross_arch_controls.lua <libm|float2int>

local ffi = require("ffi")

-- Both extractors below reinterpret bits through a union, which is only
-- comparable between two little-endian targets. Fail loudly rather than let
-- byte order masquerade as a value difference.
local echk = ffi.new("union { uint32_t u; uint8_t b[4]; }")
echk.u = 0x01020304
assert(echk.b[0] == 0x04,
	"big-endian target: this probe's bit extraction is not comparable across it")

local dconv = ffi.new("union { double d; uint32_t u[2]; }")
-- Exact IEEE-754 bit pattern of a double, as hex. Deliberately NOT
-- string.format("%.17g") or tostring(): those route through the platform's
-- printf, which is itself one of the things under test -- the probe must not
-- introduce the difference it is trying to observe.
local function dbits(d)
	dconv.d = d
	return string.format("%08x%08x", dconv.u[1], dconv.u[0])
end

local ibox = ffi.new("union { int64_t i64; uint64_t u64; int32_t i32; uint32_t u32; uint32_t h[2]; }")
-- Exact bits of an integer conversion result.
--
-- NEVER `tostring(ffi.cast("int32_t", x))` here. On a 32-bit integer cdata
-- that prints a boxed ADDRESS ("cdata<int>: 0x7f70..."), not a value. An
-- earlier draft of this probe did exactly that; its digest varied run to run
-- on a single machine under ASLR, and it reported a confident DIFFER that was
-- pure address noise. This project has already retracted two upstream LuaJIT
-- bug claims to that same mistake -- see docs/luajit-1499-pin-investigation.md.
-- The reflexivity check in cross_arch_diff exists to catch a regression here.
local function ibits(setter)
	ibox.u64 = 0ULL          -- clear the high half so narrow writes are deterministic
	setter()
	return string.format("%08x%08x", ibox.h[1], ibox.h[0])
end

local mode = arg[1] or ""
local lines = {}

if mode == "libm" then
	-- LIBC AXIS. Platform libm over the (0,1) domain Box-Muller consumed before
	-- the kernel conversion. IEEE-754 pins + - * / sqrt and says essentially
	-- nothing about transcendentals, so every libc returns a different final
	-- ulp. This is the divergence the whole project was built to eliminate, so
	-- it is the honest positive control for "could we have seen it?".
	for k = 1, 20000 do
		local u = k / 4294967296.0
		lines[#lines + 1] = dbits(math.log(u))
		lines[#lines + 1] = dbits(math.cos(u * 6.283185307179586))
		lines[#lines + 1] = dbits(math.exp(u * 40.0 - 20.0))
		lines[#lines + 1] = dbits(u ^ 0.7)
	end

elseif mode == "float2int" then
	-- ARCHITECTURE AXIS. Out-of-range double->integer conversion is genuinely
	-- architecture-defined, not libc-defined: x86_64's cvttsd2si yields the
	-- "integer indefinite" value (INT64_MIN) for anything unrepresentable
	-- including NaN, while aarch64's fcvtzs saturates to INT64_MAX/INT64_MIN
	-- and maps NaN to 0. Measured through qemu-aarch64, confirming emulation
	-- reproduces the architecture-visible semantics rather than the host's.
	local vals = {
		2^31, 2^31 + 0.5, -2^31 - 1, 2^63, -2^63, 2^64,
		1e300, -1e300, 0/0, 1/0, -1/0, -0.0,
		2147483647.9, -2147483648.9, 1.5, -1.5,
	}
	for i = 1, #vals do
		local v = vals[i]
		lines[#lines + 1] = ibits(function() ibox.i32 = ffi.cast("int32_t",  v) end)
		lines[#lines + 1] = ibits(function() ibox.u32 = ffi.cast("uint32_t", v) end)
		lines[#lines + 1] = ibits(function() ibox.i64 = ffi.cast("int64_t",  v) end)
		lines[#lines + 1] = ibits(function() ibox.u64 = ffi.cast("uint64_t", v) end)
	end

else
	io.stderr:write("cross_arch_controls: expected mode 'libm' or 'float2int', got '"
		.. tostring(arg[1]) .. "'\n")
	os.exit(2)
end

io.write(table.concat(lines, "\n"), "\n")
