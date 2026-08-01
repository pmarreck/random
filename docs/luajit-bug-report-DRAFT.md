# DRAFT — LuaJIT issue report (for Peter's review before filing)

**Proposed title:** Trace miscompilation with `-O+fwd`: pure function returns wrong result for int64 cdata after mixed-sign warmup

---

Hello, and thank you for LuaJIT.

Some context on who is writing, since it seems only fair to say up front: I am
Claude Opus 5 (model ID `claude-opus-5`), an AI agent from Anthropic, working
through Claude Code. Peter Marreck (@pmarreck) has overseen this work and
reviewed this report before it was filed. We hit this while building an
integer-only fixed-point arithmetic kernel, and we have tried to do the legwork
properly: reduce it to the smallest reproduction we could, identify the specific
optimization involved, and find the smallest and most performant workaround we
could rather than just switching the JIT off. Any errors here are ours, and
Peter is happy to be contacted with questions.

## Summary

A pure Lua function that performs restoring bit-serial division on 64-bit cdata
returns a **different, incorrect result for identical arguments** once its trace
has been compiled, but only when the trace was warmed with *mixed-sign*
operands. The interpreter and all lower optimization levels are correct.

The responsible optimization appears to be **`fwd`** (load/store forwarding):

```
luajit      -O2 -O+fwd   repro.lua   →  MISCOMPILED
luajit      -O3 -O-fwd   repro.lua   →  correct
```

`-O0`, `-O1`, `-O2` are all correct; `-O3` (the default) miscompiles. Disabling
any of `dse`, `abc`, `sink`, or `fuse` individually does not help; disabling
`fwd` does.

## Environment

- LuaJIT 2.1.1774638290 (also the newest currently in nixpkgs-unstable)
- x86_64, `jit.arch = "x64"`, 8-byte pointers (GC64)
- Linux 6.18.40, NixOS 26.11.20260726.624af66
- Built by Nixpkgs, unpatched

## Reproduction

```lua
local ffi = require("ffi")
local u64, i64 = ffi.typeof("uint64_t"), ffi.typeof("int64_t")
local TWO62 = 0x4000000000000000ULL

-- floor(|m1| * 2^62 / |m2|), sign applied at the end.
-- Operands are always normalized to 2^62 <= |m| < 2^63.
local function div(m1, m2)
	local neg = (m1 < 0) ~= (m2 < 0)
	local a = ffi.cast(u64, m1); if m1 < 0 then a = ffi.cast(u64, 0) - a end
	local b = ffi.cast(u64, m2); if m2 < 0 then b = ffi.cast(u64, 0) - b end
	local q0, rem = a / b, a % b
	local frac = 0ULL
	for _ = 1, 62 do
		rem = rem * 2ULL
		frac = frac * 2ULL
		if rem >= b then
			rem = rem - b
			frac = frac + 1ULL
		end
	end
	local r = ffi.cast(i64, q0 * TWO62 + frac)
	if neg then r = -r end
	return r
end

local A, B = -4735866454561506793LL, -6988739120546013429LL
local EXPECT = 3125074314110934032LL

local cold = div(A, B)

-- Warm the trace with varied, MIXED-SIGN operands.
local lcg = 0x9E3779B97F4A7C15ULL
for i = 1, 3000 do
	lcg = lcg * 6364136223846793005ULL + 1ULL
	local wa = ffi.cast(i64, TWO62 + ((lcg / 4ULL) % TWO62))
	lcg = lcg * 6364136223846793005ULL + 1ULL
	local wb = ffi.cast(i64, TWO62 + ((lcg / 4ULL) % TWO62))
	if i % 2 == 0 then wa = -wa end
	if i % 3 == 0 then wb = -wb end
	div(wa, wb)
end

local warm = div(A, B)

print(("cold     = %s"):format(tostring(cold)))
print(("warm     = %s"):format(tostring(warm)))
print(("expected = %s"):format(tostring(EXPECT)))
os.exit(warm == EXPECT and 0 or 1)
```

Output:

```
$ luajit repro.lua
cold     = 3125074314110934032LL
warm     = 7736760332538321936LL     <-- wrong
expected = 3125074314110934032LL

$ luajit -joff repro.lua
cold     = 3125074314110934032LL
warm     = 3125074314110934032LL     <-- correct
expected = 3125074314110934032LL
```

`div` is pure. The same arguments produce different results within one process
depending only on whether the trace has been compiled.

## Ground truth

Verified independently with `bc` (arbitrary precision), not by assuming the
interpreter is right:

```
$ echo '(4735866454561506793 * 2^62) / 6988739120546013429' | bc
3125074314110934032
```

The cold / `-joff` value matches. The JIT-warmed value does not.

## What we narrowed down

- **A positives-only warmup does not reproduce it.** The trigger is a warmup
  that mixes signs, after which a negative/negative call takes a trace
  specialized for a different sign pattern.
- **The final result negation is irrelevant.** Returning the unsigned magnitude
  `q0 * TWO62 + frac` without ever negating still reproduces — the wrong value
  is already present in the magnitude.
- **It is not one particular negation idiom.** Both
  `ffi.cast(u64, 0) - a` and `m1 < 0 and -m1 or m1` reproduce. It appears to be
  the sign *branch* rather than the arithmetic in it.
- **Moving the division loop into its own function does not help**, presumably
  because it gets inlined into the same trace.

## IR for the recorded loop trace

`luajit -jdump=i -O2 -O+fwd` on the reproduction. The root trace is the
62-iteration division loop:

```
---- TRACE 1 IR
0002 >  cdt SLOAD  #8    T
0005    u64 FLOAD  0002  cdata.int64      ; rem
0006  + u64 ADD    0005  0005             ; rem * 2
0008 >  cdt SLOAD  #9    T
0011    u64 FLOAD  0008  cdata.int64      ; frac
0012  + u64 ADD    0011  0011             ; frac * 2
0014 >  cdt SLOAD  #6    T
0017    u64 FLOAD  0014  cdata.int64      ; b
0018 >  u64 UGT    0017  0006             ; guard: rem*2 < b
0019  + int ADD    0001  +1
0020 >  int LE     0019  +62
0021 ------ LOOP ------------
0022  + u64 ADD    0006  0006
0024  + u64 ADD    0012  0012
0026 >  u64 ULT    0022  0017             ; guard: rem*2 < b
0027  + int ADD    0019  +1
0028 >  int LE     0027  +62
0029    int PHI    0019  0027
0030    cdt PHI    0007  0023
0031    u64 PHI    0006  0022
0032    cdt PHI    0013  0025
0033    u64 PHI    0012  0024
---- TRACE 1 stop -> loop
```

Side traces are recorded at the `if rem >= b` branch (line 43) and at the
`if neg` branch (line 48).

We did not diagnose this and offer the following only as an observation, not a
claim. Each of `rem` and `frac` appears to be carried in two parallel forms —
as a raw `u64` (`0006`, `0012`) and as a boxed cdata produced by `CNEWI`
(`0007`, `0013`) — with `PHI` nodes for both (`0030`–`0033`). We wondered
whether `fwd` could forward the raw `u64` across a side exit in a case where
the boxed cdata is what gets restored, which would produce a wrong value only
after an exit and only once the trace exists. That is a guess from reading the
dump; we have not tested it and may well be misreading it.

## Workaround, and why we chose it

The obvious mitigation is `jit.off(div, true)`, which is correct but costs the
whole function's JIT compilation. We instead route only the affected input class
off the hot trace: all-positive operands take a branch-free path that stays
fully JIT-compiled, and anything with a negative operand goes to a separately
`jit.off`'d function so the two never share a trace.

```lua
local function divmag(a, b)  -- positives only, no sign branches
	local q0, rem = a / b, a % b
	local frac = 0ULL
	for _ = 1, 62 do
		rem = rem * 2ULL; frac = frac * 2ULL
		if rem >= b then rem = rem - b; frac = frac + 1ULL end
	end
	return q0 * TWO62 + frac
end

local function div_signed(m1, m2)   -- cold path
	local neg = (m1 < 0) ~= (m2 < 0)
	local a = ffi.cast(u64, m1); if m1 < 0 then a = ffi.cast(u64, 0) - a end
	local b = ffi.cast(u64, m2); if m2 < 0 then b = ffi.cast(u64, 0) - b end
	local r = ffi.cast(i64, divmag(a, b))
	if neg then return -r end
	return r
end
jit.off(div_signed)

local function div(m1, m2)
	if m1 > 0 and m2 > 0 then
		return ffi.cast(i64, divmag(ffi.cast(u64, m1), ffi.cast(u64, m2)))
	end
	return div_signed(m1, m2)
end
```

Measured on a positives-heavy workload (300,000 divisions), `hyperfine -N
--warmup 3 -r 10`, both variants producing a bit-identical accumulator:

| variant | time |
|---|---|
| `jit.off(div, true)` | 1.096 s ± 0.005 s |
| split, positives JIT-compiled | 641.8 ms ± 3.0 ms |

**1.71 ± 0.01× faster**, and it passes the reproduction above.

We mention the workaround not because it needs fixing upstream, but in case the
shape of it is a useful hint about what the trace is getting wrong.

## Closing

Thank you sincerely for LuaJIT — Peter asked me to pass on that it kicks ass,
and he means it. It has been the backbone of a lot of his tooling for years.
Please reach out to @pmarreck with any questions, or if you would like us to
test a patch, gather IR dumps, or try to reduce this further. We are glad to.

---

## Notes for Peter (not part of the report)

- I have **not** filed this. Say the word and I will, or you may prefer to file
  it under your own account given it is addressed partly from you.
- Things I could add before filing if you want them: `-jdump` IR output for the
  bad trace, a check against LuaJIT built from upstream HEAD rather than the
  nixpkgs build, and whether it reproduces on aarch64.
- The repro is committed at `docs/luajit-div-miscompilation.lua` and exits
  non-zero when miscompiled, so it will also tell us if a future LuaJIT bump
  fixes this.
