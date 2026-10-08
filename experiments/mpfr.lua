-- High-precision external oracle, deliberately independent of lib/fixed.lua.
local ffi = require("ffi")
ffi.cdef[[
typedef struct { long precision; int sign; long exponent; unsigned long *limbs; } random_mpfr;
void mpfr_init2(random_mpfr *, long);
void mpfr_clear(random_mpfr *);
int mpfr_set_str(random_mpfr *, const char *, int, int);
int mpfr_set(random_mpfr *, const random_mpfr *, int);
int mpfr_add(random_mpfr *, const random_mpfr *, const random_mpfr *, int);
int mpfr_sub(random_mpfr *, const random_mpfr *, const random_mpfr *, int);
int mpfr_mul(random_mpfr *, const random_mpfr *, const random_mpfr *, int);
int mpfr_div(random_mpfr *, const random_mpfr *, const random_mpfr *, int);
int mpfr_mul_2si(random_mpfr *, const random_mpfr *, long, int);
int mpfr_sqrt(random_mpfr *, const random_mpfr *, int);
int mpfr_log(random_mpfr *, const random_mpfr *, int);
int mpfr_exp(random_mpfr *, const random_mpfr *, int);
int mpfr_erfc(random_mpfr *, const random_mpfr *, int);
int mpfr_abs(random_mpfr *, const random_mpfr *, int);
int mpfr_floor(random_mpfr *, const random_mpfr *);
long mpfr_get_exp(const random_mpfr *);
int mpfr_cmp(const random_mpfr *, const random_mpfr *);
int mpfr_const_pi(random_mpfr *, int);
int mpfr_snprintf(char *, size_t, const char *, ...);
double mpfr_get_d(const random_mpfr *, int);
]]
local c = ffi.load(assert(os.getenv("RANDOM_MPFR_LIBRARY"), "Nix must resolve RANDOM_MPFR_LIBRARY"))
local M = { c = c }
M.precision = 256
function M.i64(text)
	local n = 0LL
	for digit in text:gmatch("%d") do n = n * 10LL + tonumber(digit) end
	return text:sub(1, 1) == "-" and -n or n
end
function M.new(text)
	local x = ffi.new("random_mpfr[1]")
	c.mpfr_init2(x, M.precision)
	ffi.gc(x, c.mpfr_clear)
	assert(c.mpfr_set_str(x, tostring(text or 0):gsub("[UuLl]+$", ""), 10, 0) == 0)
	return x
end
for _, op in ipairs({"add", "sub", "mul", "div"}) do
	M[op] = function(a, b) local x = M.new(); c["mpfr_" .. op](x, a, b, 0); return x end
end
for _, op in ipairs({"sqrt", "log", "exp", "erfc", "abs"}) do
	M[op] = function(a) local x = M.new(); c["mpfr_" .. op](x, a, 0); return x end
end
function M.shift(a, e) local x = M.new(); c.mpfr_mul_2si(x, a, e, 0); return x end
function M.floor(a) local x = M.new(); c.mpfr_floor(x, a); return x end
function M.cmp(a, b) return c.mpfr_cmp(a, b) end
function M.number(a) return c.mpfr_get_d(a, 0) end
function M.text(a, digits)
	local buffer = ffi.new("char[512]")
	assert(c.mpfr_snprintf(buffer, 512, digits and ("%." .. digits .. "Rg") or "%.0Rf", a) < 512)
	return ffi.string(buffer)
end
function M.fixed(m, e) return M.shift(M.new(m), e - 62) end
function M.pair(x)
	if M.cmp(x, M.new(0)) == 0 then return "0", 0 end
	local e = c.mpfr_get_exp(x) - 1
	return M.text(M.floor(M.shift(x, 62 - e))), e
end
return M
