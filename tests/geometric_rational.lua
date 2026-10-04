-- Independent acceptance gate: GMP judges exact rational inequalities, while
-- scripted bytes pin sampling order. Equality of ports alone cannot establish
-- the distribution law or its fixed-arithmetic error bound.
local ffi = require("ffi")
local fx = require("fixed")
local geometric = require("geometric")

ffi.cdef[[
typedef struct { int alloc; int size; void *limbs; } random_mpz;
typedef struct { random_mpz numerator; random_mpz denominator; } random_mpq;
void __gmpq_init(random_mpq *);
void __gmpq_clear(random_mpq *);
int __gmpq_set_str(random_mpq *, const char *, int);
void __gmpq_set_ui(random_mpq *, unsigned long, unsigned long);
void __gmpq_set_z(random_mpq *, const random_mpz *);
void __gmpq_get_num(random_mpz *, const random_mpq *);
void __gmpq_canonicalize(random_mpq *);
void __gmpq_add(random_mpq *, const random_mpq *, const random_mpq *);
void __gmpq_sub(random_mpq *, const random_mpq *, const random_mpq *);
void __gmpq_mul(random_mpq *, const random_mpq *, const random_mpq *);
void __gmpq_div(random_mpq *, const random_mpq *, const random_mpq *);
void __gmpq_abs(random_mpq *, const random_mpq *);
void __gmpq_mul_2exp(random_mpq *, const random_mpq *, unsigned long);
void __gmpq_div_2exp(random_mpq *, const random_mpq *, unsigned long);
int __gmpq_cmp(const random_mpq *, const random_mpq *);
void __gmpz_init(random_mpz *);
void __gmpz_clear(random_mpz *);
void __gmpz_fdiv_r_2exp(random_mpz *, const random_mpz *, unsigned long);
]]
local gmp = ffi.load(os.getenv("RANDOM_GMP_LIBRARY") or "gmp")
local function rational(text)
	local value = ffi.new("random_mpq[1]")
	gmp.__gmpq_init(value)
	ffi.gc(value, gmp.__gmpq_clear)
	assert(gmp.__gmpq_set_str(value, text or "0", 10) == 0)
	gmp.__gmpq_canonicalize(value)
	return value
end
local function integer_text(value) return tostring(value):gsub("[UuLl]+$", "") end
local function set_fixed(out, m, e)
	assert(gmp.__gmpq_set_str(out, integer_text(m), 10) == 0)
	gmp.__gmpq_div_2exp(out, out, 62 - e)
end
local function set_threshold(out, value)
	assert(ffi.istype("uint64_t", value), "threshold must retain all u64 bits")
	assert(gmp.__gmpq_set_str(out, integer_text(value), 10) == 0)
	gmp.__gmpq_div_2exp(out, out, 64)
end
local checks, steps, parameters, decompositions = 0, 0, 0, 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end
local one, two = rational("1"), rational("2")
local u = rational("1/4611686018427387904")
local three_u = rational("3/4611686018427387904")
local growth = rational("149/100")
local p, square, q_exact, b_exact = rational(), rational(), rational(), rational()
local numerator, denominator, q_stored, b_stored = rational(), rational(), rational(), rational()
local delta, bound, actual = rational(), rational(), rational()
local function within_q_bound(candidate, exact, label)
	gmp.__gmpq_sub(delta, candidate, exact)
	gmp.__gmpq_abs(delta, delta)
	gmp.__gmpq_mul(bound, exact, three_u)
	check(gmp.__gmpq_cmp(delta, bound) < 0, "q recurrence bound: " .. label)
end
local function within_b_bound(candidate, exact, label)
	gmp.__gmpq_sub(delta, candidate, exact)
	gmp.__gmpq_abs(delta, delta)
	check(gmp.__gmpq_cmp(delta, three_u) < 0, "b recurrence bound: " .. label)
end
local ONE_M, ONE_E = fx.from_int(1)
local TWO_M, TWO_E = fx.from_int(2)
local HALF_M, HALF_E = fx.parse("0.5")

-- Optional corruptions are test-side controls, never production debug hooks.
if arg[1] == "--mutate-threshold" then
	local original = geometric.prepare
	geometric.prepare = function(m, e)
		local result = original(m, e)
		if not result.certain then result.base = result.base + 1ULL end
		return result
	end
elseif arg[1] == "--mutate-tail" then
	local original = geometric.prepare
	geometric.prepare = function(m, e)
		local result = original(m, e)
		if result.tail_bits > 0 then result.tail_bits = result.tail_bits + 1 end
		return result
	end
else
	check(arg[1] == nil, "unknown acceptance-gate option")
end

local function verify_prepared(m, e)
	parameters = parameters + 1
	local label = integer_text(m) .. "," .. tostring(e)
	local prepared = geometric.prepare(m, e)
	local tail = math.max(0, -62 - e)
	check(prepared.tail_bits == tail, "tail bit count mismatch: " .. label)
	if fx.cmp(m, e, ONE_M, ONE_E) == 0 then
		check(prepared.certain and #prepared.levels == 0, "certain preparation mismatch")
		return prepared
	end
	check(not prepared.certain, "non-certain parameter became certain")
	e = math.max(e, -62)
	local index = 0
	while fx.cmp(m, e, HALF_M, HALF_E) < 0 do
		index = index + 1
		steps = steps + 1
		-- The expected q operation is exact exponent doubling, then the
		-- existing square/subtract; same-sign add is not exact for odd m.
		local nm, ne = fx.sub(ONE_M, ONE_E, m, e)
		local dm, de = fx.sub(TWO_M, TWO_E, m, e)
		local bm, be = fx.div(nm, ne, dm, de)
		local sm, se = fx.mul(m, e, m, e)
		local qm, qe = fx.sub(m, e + 1, sm, se)
		set_fixed(p, m, e)
		gmp.__gmpq_mul(square, p, p)
		gmp.__gmpq_mul(q_exact, p, two)
		gmp.__gmpq_sub(q_exact, q_exact, square)
		gmp.__gmpq_sub(numerator, one, p)
		gmp.__gmpq_sub(denominator, two, p)
		gmp.__gmpq_div(b_exact, numerator, denominator)
		set_fixed(q_stored, qm, qe)
		set_fixed(b_stored, bm, be)
		within_q_bound(q_stored, q_exact, label)
		within_b_bound(b_stored, b_exact, label)
		gmp.__gmpq_mul(bound, p, growth)
		check(gmp.__gmpq_cmp(q_stored, bound) > 0, "significant growth bound: " .. label)
		set_threshold(actual, prepared.levels[index])
		check(gmp.__gmpq_cmp(actual, b_stored) == 0, "bit threshold mismatch: " .. label)
		m, e = qm, qe
	end
	check(index == #prepared.levels and index <= 128, "level count mismatch: " .. label)
	set_fixed(p, m, e)
	set_threshold(actual, prepared.base)
	check(gmp.__gmpq_cmp(actual, p) == 0, "base threshold mismatch: " .. label)
	check(gmp.__gmpq_cmp(p, one) < 0, "base probability must be below one")
	return prepared
end

-- Every significant input exponent, normalized mantissa extrema, carries and
-- deterministic generated mantissas. GMP comparisons never use binary64.
local mantissas = {
	4611686018427387904LL, 4611686018427387905LL, 4611686018427387906LL,
	4611686018427387907LL, 4611686019501129727LL, 4611686020574871551LL,
	6917529027641081855LL, 6917529027641081856LL, 6917529027641081857LL,
	9223372036854775804LL, 9223372036854775805LL, 9223372036854775806LL,
	9223372036854775807LL,
}
local generated = 42ULL
for _ = 1, 16 do
	generated = generated * 6364136223846793005ULL + 1442695040888963407ULL
	mantissas[#mantissas + 1] = ffi.cast("int64_t", 4611686018427387904ULL +
		generated % 4611686018427387904ULL)
end
for e = -62, -2 do
	for _, m in ipairs(mantissas) do verify_prepared(m, e) end
end
for _, m in ipairs(mantissas) do verify_prepared(m, -1) end
verify_prepared(ONE_M, ONE_E)
for _, e in ipairs({-63, -64, -65, -1000, -1000000}) do
	for _, m in ipairs({mantissas[1], mantissas[2], mantissas[#mantissas]}) do
		verify_prepared(m, e)
	end
end

-- Tiny-region operation identities and the closed-form geometric-series
-- enclosure are distinct controls: skipping fixed steps must preserve the
-- stated dyadic doubling/fair-bit shortcut, even with odd mantissas.
local series, tiny_bound = rational(), rational("5/13835058055282163712")
local five_sixths = rational("5/6")
for _, e in ipairs({-63, -64, -1000, -1000000}) do
	for _, m in ipairs({mantissas[1], mantissas[2], mantissas[#mantissas]}) do
		local sm, se = fx.mul(m, e, m, e)
		local qm, qe = fx.sub(m, e + 1, sm, se)
		local nm, ne = fx.sub(ONE_M, ONE_E, m, e)
		local dm, de = fx.sub(TWO_M, TWO_E, m, e)
		local bm, be = fx.div(nm, ne, dm, de)
		check(qm == m and qe == e + 1, "tiny-region exact doubling identity")
		check(bm == HALF_M and be == HALF_E, "tiny-region exact fair-bit identity")
		set_fixed(p, m, e)
		set_fixed(q_stored, m, -62)
		gmp.__gmpq_sub(series, q_stored, p)
		gmp.__gmpq_mul(series, series, five_sixths)
		check(gmp.__gmpq_cmp(series, tiny_bound) < 0, "tiny-region series bound")
	end
end
gmp.__gmpq_mul(series, u, one)
for _ = 1, 128 do gmp.__gmpq_mul(series, series, growth) end
set_fixed(p, HALF_M, HALF_E)
check(gmp.__gmpq_cmp(series, p) > 0, "128-level exact rational growth enclosure")
local significant_bound = rational("768/4611686018427387904")
local global_bound = rational("770/4611686018427387904")
gmp.__gmpq_add(series, significant_bound, tiny_bound)
check(gmp.__gmpq_cmp(series, global_bound) < 0, "analytical global error enclosure")

-- A deliberate inexact result must exceed the independent rational budget.
set_fixed(p, 4611686018427387904LL, -2)
gmp.__gmpq_mul(q_exact, p, two)
gmp.__gmpq_mul(square, p, p)
gmp.__gmpq_sub(q_exact, q_exact, square)
gmp.__gmpq_add(q_stored, q_exact, three_u)
local accepted, reason = pcall(within_q_bound, q_stored, q_exact, "negative control")
check(not accepted and tostring(reason):find("q recurrence bound", 1, true),
	"q bound checker failed to reject corruption")
gmp.__gmpq_sub(numerator, one, p)
gmp.__gmpq_sub(denominator, two, p)
gmp.__gmpq_div(b_exact, numerator, denominator)
gmp.__gmpq_add(b_stored, b_exact, three_u)
accepted, reason = pcall(within_b_bound, b_stored, b_exact, "negative control")
check(not accepted and tostring(reason):find("b recurrence bound", 1, true),
	"b bound checker failed to reject corruption")

-- Finite-domain exact block decomposition: all dyadic p with denominators
-- 2..256, and 16 complete failure blocks. This verifies the mathematical
-- identity independently of Fixed and of the producer sampler.
local failure, bit_zero, block_failure = rational(), rational(), rational()
local block_mass, target_mass, reconstructed = rational(), rational(), rational()
for width = 1, 8 do
	local divisor = 2 ^ width
	for n = 1, divisor - 1 do
		gmp.__gmpq_set_ui(p, n, divisor)
		-- GMP assignment does not reduce common factors; arithmetic requires
		-- canonical operands (GNU MP manual, Initializing Rationals).
		gmp.__gmpq_canonicalize(p)
		gmp.__gmpq_sub(failure, one, p)
		gmp.__gmpq_mul(square, p, p)
		gmp.__gmpq_mul(q_exact, p, two)
		gmp.__gmpq_sub(q_exact, q_exact, square)
		gmp.__gmpq_sub(numerator, one, p)
		gmp.__gmpq_sub(denominator, two, p)
		gmp.__gmpq_div(b_exact, numerator, denominator)
		gmp.__gmpq_sub(bit_zero, one, b_exact)
		gmp.__gmpq_sub(block_failure, one, q_exact)
		gmp.__gmpq_mul(block_mass, q_exact, one)
		gmp.__gmpq_mul(target_mass, p, one)
		for _ = 0, 15 do
			gmp.__gmpq_mul(reconstructed, block_mass, bit_zero)
			check(gmp.__gmpq_cmp(reconstructed, target_mass) == 0, "even-block identity")
			gmp.__gmpq_mul(target_mass, target_mass, failure)
			gmp.__gmpq_mul(reconstructed, block_mass, b_exact)
			check(gmp.__gmpq_cmp(reconstructed, target_mass) == 0, "odd-block identity")
			gmp.__gmpq_mul(target_mass, target_mass, failure)
			gmp.__gmpq_mul(block_mass, block_mass, block_failure)
			decompositions = decompositions + 2
		end
	end
end
for threshold = 0, 256 do
	local successes = 0
	for draw = 0, 255 do if draw < threshold then successes = successes + 1 end end
	check(successes == threshold, "exhausted Bernoulli threshold cardinality")
end

local function big_endian(value)
	local bytes = {}
	for index = 8, 1, -1 do
		bytes[index] = string.char(tonumber(value % 256ULL))
		value = value / 256ULL
	end
	return table.concat(bytes)
end
local function scripted(spans)
	local calls, consumed = 0, 0
	return function(count)
		calls = calls + 1
		local span = spans[calls]
		assert(span and #span == count, "source request schedule mismatch")
		consumed = consumed + count
		return span
	end, function()
		check(calls == #spans, "source request count mismatch")
		return consumed
	end
end
local function check_sample(prepared, spans, expected)
	local read, finish = scripted(spans)
	check(geometric.sample(prepared, read) == expected, "scripted magnitude mismatch")
	return finish()
end
check_sample(geometric.prepare(ONE_M, ONE_E), {}, "")
local half = geometric.prepare(HALF_M, HALF_E)
check_sample(half, {big_endian(half.base - 1ULL)}, "")
check_sample(half, {big_endian(half.base), big_endian(0ULL)}, "\1")
check_sample(half, {big_endian(half.base + 1ULL), big_endian(0ULL)}, "\1")
local near_half = geometric.prepare(9223372036854775807LL, -2)
check(#near_half.levels == 1, "near-half must have one reconstruction bit")
check_sample(near_half, {big_endian(0ULL), big_endian(near_half.levels[1] - 1ULL)}, "\1")
check_sample(near_half, {big_endian(0ULL), big_endian(near_half.levels[1])}, "")
for _, invalid in ipairs({{0LL, 0}, {-4611686018427387904LL, -1},
	{4611686018427387904LL, 1}, {4611686018427387905LL, 0}, {1LL, 0},
	{4611686018427387904LL, -1000001}, {4611686018427387904LL, -0.5}}) do
	check(not pcall(geometric.prepare, unpack(invalid)), "invalid probability accepted")
end

-- Decode magnitude bytes through GMP, not through unsigned_count; derive the
-- expected shifted result independently, including discarded high padding.
local radix, byte, expected, observed, low = rational("256"), rational(), rational(), rational(), rational()
local residue = ffi.new("random_mpz[1]")
gmp.__gmpz_init(residue)
ffi.gc(residue, gmp.__gmpz_clear)
local function decode_unsigned(out, bytes)
	gmp.__gmpq_set_ui(out, 0, 1)
	for index = #bytes, 1, -1 do
		gmp.__gmpq_mul(out, out, radix)
		gmp.__gmpq_set_ui(byte, bytes:byte(index), 1)
		gmp.__gmpq_add(out, out, byte)
	end
end
for _, bits in ipairs({1, 7, 8, 9, 63, 64, 65, 247, 248, 249, 255, 256, 257, 1023}) do
	local prepared = verify_prepared(4611686018427387905LL, -62 - bits)
	local spans = {big_endian(prepared.base), big_endian(0ULL)}
	gmp.__gmpq_set_ui(expected, 1, 1)
	for index = #prepared.levels, 1, -1 do
		local bit = index % 2
		spans[#spans + 1] = big_endian(prepared.levels[index] - (bit == 1 and 1ULL or 0ULL))
		gmp.__gmpq_mul(expected, expected, two)
		gmp.__gmpq_set_ui(byte, bit, 1)
		gmp.__gmpq_add(expected, expected, byte)
	end
	local bytes = math.floor((bits + 7) / 8)
	local tail = {}
	for index = 1, bytes do tail[index] = string.char((index * 73 + 19) % 256) end
	tail[bytes] = "\255"
	tail = table.concat(tail)
	spans[#spans + 1] = tail
	decode_unsigned(low, tail)
	gmp.__gmpq_get_num(residue, low)
	gmp.__gmpz_fdiv_r_2exp(residue, residue, bits)
	gmp.__gmpq_set_z(low, residue)
	gmp.__gmpq_mul_2exp(expected, expected, bits)
	gmp.__gmpq_add(expected, expected, low)
	local read, finish = scripted(spans)
	local sampled = geometric.sample(prepared, read)
	check(#sampled == 0 or sampled:byte(#sampled) ~= 0, "noncanonical magnitude output")
	decode_unsigned(observed, sampled)
	check(gmp.__gmpq_cmp(observed, expected) == 0, "bulk magnitude mismatch at bits=" .. bits)
	check(finish() == 8 * (#prepared.levels + 2) + bytes, "bulk cursor consumption mismatch")
end

-- The numerical gate samples mantissas; the universal TV bound remains the
-- independent analytical enclosure, not a new Lean theorem or statistical
-- measurement. Exact finite identities and rejection controls are exhaustive.
print(string.format("Geometric GMP rational gate passed: %d parameters, %d fixed steps, %d exact block identities, %d checks",
	parameters, steps, decompositions, checks))
