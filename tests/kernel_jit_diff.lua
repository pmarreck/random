-- Differential control: does LuaJIT's trace compiler produce the SAME
-- integer results as its own interpreter over a long, mixed-sign run of the
-- whole kernel? This is the control that would have caught LuaJIT/LuaJIT#1499
-- (https://github.com/LuaJIT/LuaJIT/issues/1499) directly, mechanically, on
-- every run -- rather than by the manual instrumented-repro session that
-- originally found it (see task-6-report.md). That bug was a trace-compiler
-- miscompilation of a conditional unsigned-negation branch followed by a
-- loop, reproducing only after ~500+ prior warmed-up calls; a single-call
-- check at cold start structurally cannot see it. This file's whole design
-- -- one long hot loop, run twice, compared by exact digest -- exists to
-- give the JIT enough rope to hang itself if the mitigation (lib/fixed.lua's
-- jit.off(div_signed)) is ever removed or bypassed.
--
-- Companion driver: tests/kernel_jit_diff (bash) runs THIS script twice --
-- once as `luajit kernel_jit_diff.lua` (JIT on), once as
-- `luajit -joff kernel_jit_diff.lua` (JIT fully disabled) -- and fails if
-- the two stdout digests differ. Integer kernel code has exactly one
-- correct answer per input; the interpreter is definitionally correct
-- (it has no trace compiler to miscompile anything), so it is the oracle
-- here, not `bc` -- this control is orthogonal to kernel_bc_sweep.lua's
-- accuracy sweep, not a replacement for it.
--
-- No `math.*`, no float literals, never `^` -- this walks the same
-- integer-only kernel paths random's own callers do.
package.path = (arg[0] or ""):match("^(.*)/[^/]+$") .. "/../lib/?.lua;" .. package.path
local ffi = require("ffi")
local fx = require("fixed")

local i64 = ffi.typeof("int64_t")
local u64 = ffi.typeof("uint64_t")
local TWO62 = 0x4000000000000000ULL

-- `FAST=` (set but empty) must mean fast mode, same trap as
-- kernel_bc_sweep.lua's own top-of-file comment: os.getenv("FAST") returns
-- "" (not nil) for a set-but-empty var, and "" is TRUTHY in Lua -- normalize
-- it to nil before testing, exactly like that file does, rather than
-- re-deriving (and possibly re-breaking) the same fix independently here.
local fast = os.getenv("FAST")
if fast == "" then fast = nil end
-- 30000 is the iteration count independently verified (see task-11-report.md)
-- to reliably diverge between `luajit` and `luajit -joff` once
-- jit.off(div_signed) is removed -- big enough that the trace compiler
-- reliably warms up and compiles div_signed's call sites well before the
-- run ends. Deliberately NOT scaled down for FAST mode, unlike every other
-- FAST/deep split in kernel_bc_sweep.lua: measured directly (see
-- task-11-report.md) that smaller counts (6000, 15000, 20000) miss the known
-- regression anywhere from ~17% to ~80% of runs -- LuaJIT's trace formation
-- is not deterministic in call count, so a control that reads green most of
-- the time on a REMOVED mitigation is not a control at all (a bug this
-- project's own review process has already flagged once, for a differently-
-- shaped probabilistic check -- see fixed_test.lua's SECONDARY check
-- comment). Deep mode instead runs MORE iterations, for extra margin, not
-- fewer -- "cheap" here means comfortably inside SUITE_TIMEOUT (300s
-- default), not "smaller than the number known to work."
local COUNT = fast and 30000 or 60000

-- Independently-seeded LCG (Knuth/PCG multiplier, distinct seed from
-- kernel_bc_sweep.lua's own so the two files' streams never accidentally
-- coincide). High bits are used (shift right before masking) since
-- power-of-two-modulus LCGs have weak low bits.
local lcg_state = 0x1234567890ABCDEFULL
local function next_mantissa()
	lcg_state = lcg_state * 6364136223846793005ULL + 1ULL
	local high = lcg_state / 4ULL
	return TWO62 + (high % TWO62)
end

-- Sign quadrants cycle deterministically across the run -- same rationale
-- as kernel_bc_sweep.lua's own SIGN_QUADRANTS: index-based, not randomized,
-- so div's negative/inexact-truncation path (div_signed, the ONE function
-- LuaJIT/LuaJIT#1499 requires jit.off on) is hit exactly as often as the
-- positive fast path, every run, deterministically.
local SIGN_QUADRANTS = { { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }
local function signed_i64(v, sign)
	local r = ffi.cast(i64, v)
	if sign < 0 then r = -r end
	return r
end

-- Small, bounded exponent sets (not derived from the mantissa LCG, kept
-- separate so resizing COUNT never shifts which exponent a given iteration
-- sees) -- deliberately modest magnitudes so M.exp's range-reduction
-- correction loop (bounded by EXP_MAX_CORRECTIONS) never has to work hard;
-- this file exists to catch a JIT miscompilation, not to stress accuracy or
-- range -- kernel_bc_sweep.lua already covers that ground.
local EXP1_SET = { -20, -13, -7, -3, -1, 0, 1, 3, 7, 13, 20 }
local EXP2_SET = { 5, -11, 17, -2, 9, -19, 0, 4, -8, 15, -6 }
-- pow's y operand needs its OWN small exponent set, kept tiny (|e| <= 3) so
-- y*ln(x) stays small and M.exp's correction loop for the pow chain below
-- never has more than a term or two of work to do.
local POW_Y_EXP_SET = { -3, -2, -1, 0, 1, 2, 3 }

local digest = 0xCBF29CE484222325ULL   -- FNV-64 offset basis, reused only as
                                        -- an arbitrary fixed seed
local DIGEST_MULT = 0x100000001B3ULL   -- FNV-64 prime, reused only as an
                                        -- arbitrary odd mixing constant
-- LuaJIT's Lua-5.1-derived grammar has no bitwise operators for 64-bit
-- cdata (only the `bit` library, which is 32-bit-only) -- see lib/fixed.lua's
-- own comment on this same constraint. This mixer therefore uses only +
-- and *, exactly the same arithmetic idiom this file's own LCG above (and
-- kernel_bc_sweep.lua's) already relies on, including uint64_t's
-- well-defined mod-2^64 wraparound on overflow. It has no cryptographic
-- ambition -- it only needs to make an arbitrary single differing i64
-- bit-pattern, anywhere across the ~720000 (FAST) to ~1.44 million (deep)
-- mixed (m, e) values a run produces (24 mix() calls/iteration x COUNT),
-- propagate to a different final digest, which multiply-accumulate over
-- the full u64 range does easily.
local function mix(v)
	digest = (digest + ffi.cast(u64, v)) * DIGEST_MULT
end

for i = 1, COUNT do
	local q = SIGN_QUADRANTS[(i % 4) + 1]
	local m1 = signed_i64(next_mantissa(), q[1])
	local m2 = signed_i64(next_mantissa(), q[2])
	local e1 = EXP1_SET[(i % #EXP1_SET) + 1]
	local e2 = EXP2_SET[(i % #EXP2_SET) + 1]
	mix(m1); mix(e1); mix(m2); mix(e2)

	-- div: the function this whole file exists to keep honest. Mixed-sign
	-- operands route through div_signed on every iteration where q[1] ~= q[2]
	-- (half the time, by construction of SIGN_QUADRANTS).
	local dm, de = fx.div(m1, e1, m2, e2)
	mix(dm); mix(de)

	local mm, me = fx.mul(m1, e1, m2, e2)
	mix(mm); mix(me)

	local am, ae = fx.add(m1, e1, m2, e2)
	mix(am); mix(ae)

	local sm, se = fx.sub(m1, e1, m2, e2)
	mix(sm); mix(se)

	-- norm: feed it a deliberately DE-normalized magnitude (half of an
	-- already-normalized mantissa, so exactly one doubling is needed) --
	-- calling it on an already-normalized value would make the loop a
	-- no-op and never exercise the shift path at all.
	local nm, ne = fx.norm(dm / 2LL, de)
	mix(nm); mix(ne)

	-- ln/sqrt/pow's base all require a positive argument; fx.neg flips
	-- whichever intermediate landed negative rather than re-deriving one.
	local ln_arg_m, ln_arg_e = mm, me
	if ln_arg_m < 0 then ln_arg_m, ln_arg_e = fx.neg(ln_arg_m, ln_arg_e) end
	local lnm, lne = fx.ln(ln_arg_m, ln_arg_e)
	mix(lnm); mix(lne)

	-- exp: fed the (mixed-sign) sub result directly -- exp is total over
	-- any sign, no adjustment needed.
	local expm, expe = fx.exp(sm, se)
	mix(expm); mix(expe)

	-- cos_turns: fed the (mixed-sign) add result -- also total, frac()
	-- handles negative inputs internally.
	local cosm, cose = fx.cos_turns(am, ae)
	mix(cosm); mix(cose)

	local sqrt_arg_m, sqrt_arg_e = nm, ne
	if sqrt_arg_m < 0 then sqrt_arg_m, sqrt_arg_e = fx.neg(sqrt_arg_m, sqrt_arg_e) end
	local sqm, sqe = fx.sqrt(sqrt_arg_m, sqrt_arg_e)
	mix(sqm); mix(sqe)

	-- pow: base is the same positive ln_arg used above; exponent y is a
	-- fresh, deliberately small-magnitude soft-float built from this
	-- iteration's OTHER mantissa draw so y varies independently of x.
	local y_m = signed_i64(next_mantissa(), q[1] * q[2])
	local y_e = POW_Y_EXP_SET[(i % #POW_Y_EXP_SET) + 1]
	local powm, powe = fx.pow(ln_arg_m, ln_arg_e, y_m, y_e)
	mix(powm); mix(powe)
end

io.stderr:write(("kernel_jit_diff: %d iterations (FAST=%s)\n"):format(COUNT, tostring(fast ~= nil)))
print(tostring(digest))
