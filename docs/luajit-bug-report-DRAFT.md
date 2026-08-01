# DRAFT v2 — LuaJIT issue report (for Peter's review before filing)

Revised after an independent critique by Codex (GPT-5.1-codex), which verified
every empirical claim and found one real defect in v1: the benchmark's baseline
was mislabeled. Details in "Notes for Peter" at the bottom.

**Proposed title:** Incorrect result from JIT-compiled `uint64_t` cdata division loop; `-O-fwd` avoids it

---

<!-- PETER: the identity/thanks paragraph is the one open question. See notes. -->

## Summary

A Lua function performing restoring bit-serial division on 64-bit cdata returns
the expected value before its trace is compiled and a different, incorrect value
afterward, given identical arguments. The divergence requires a warmup that
mixes operand signs.

The reproduction fails with `fwd` enabled and passes with `-O-fwd`. That
identifies an interaction requiring `fwd`; it does not identify the defective
transformation.

```
luajit      -O2 -O+fwd   repro.lua   →  wrong result
luajit      -O3 -O-fwd   repro.lua   →  expected result
```

For this reproduction, `-joff`, `-O0`, `-O1` and `-O2` return the expected
value; default `-O3` does not. Disabling `dse`, `abc`, `sink` or `fuse`
individually does not change the outcome.

## Environment

Reproduced identically on two builds:

- **Upstream commit `4886b676a698acc4bbdf54adfabb3e33a8c020e8`**, built from
  source with plain `make`, no flags, reporting `LuaJIT 2.1.1785577137`. Tested
  2026-08-01.
- LuaJIT 2.1.1774638290 as packaged by Nixpkgs.

- x86_64, `jit.arch = "x64"`, 8-byte pointers (GC64)
- Linux 6.18.40

## Reproduction

```lua
local ffi = require("ffi")
local u64, i64 = ffi.typeof("uint64_t"), ffi.typeof("int64_t")
local TWO62 = 0x4000000000000000ULL

-- floor(|m1| * 2^62 / |m2|), sign applied at the end.
-- Operands are always in 2^62 <= |m| < 2^63, so no intermediate overflows
-- and INT64_MIN is never negated.
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

-- Warmup with mixed-sign operands. 500 is comfortably above the threshold;
-- it begins failing at a few hundred on this build.
local lcg = 0x9E3779B97F4A7C15ULL
for i = 1, 500 do
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
warm     = 7736760332538321936LL
expected = 3125074314110934032LL

$ luajit -joff repro.lua
cold     = 3125074314110934032LL
warm     = 3125074314110934032LL
expected = 3125074314110934032LL
```

The script exits non-zero when the result is wrong.

## Expected value

Computed independently with `bc`:

```
$ echo '(4735866454561506793 * 2^62) / 6988739120546013429' | bc
3125074314110934032
```

## Observations

Facts only; I have not determined the cause.

- Replacing the sign-flipping warmup with all-positive operands returns the
  expected value.
- Removing the final signed-result negation still fails — the incorrect value
  is already present in the unsigned magnitude.
- Both absolute-value forms tested fail: `ffi.cast(u64, 0) - a` and
  `m1 < 0 and -m1 or m1`.
- Moving the division loop into a separate helper function also fails.

## Offer

I can test a patch on this x86_64/GC64 configuration and provide clean `-jdump`
output if that would be useful.

---

## Notes for Peter — not part of the report

### What the Codex critique verified

It independently confirmed every empirical claim: 20/20 runs each way on the
`-O+fwd` / `-O-fwd` bisect, the `bc` value, all four narrowing results, and that
both workarounds pass. It also examined whether the Lua itself is at fault and
concluded it is not — the bounds prevent signed-min negation and intermediate
unsigned overflow, and the cdata semantics used are documented behavior. That is
the finding I most wanted an independent model to check, and it came back clean.

### What it caught that was genuinely wrong

**The benchmark.** v1 claimed `jit.off(div, true)` cost 1.096 s versus 641.8 ms
for the split, a 1.71× difference. Codex measured the `jit.off` baseline at
5.72–5.78 s and called the number unreproducible. It was right, and I found the
cause: my baseline script called `divmag` from a *separate module*, and
`jit.off(f, true)` descends only into lexically nested prototypes — so the hot
inner loop stayed JIT-compiled. I was benchmarking a partial disable and calling
it a full one. Corrected on this machine:

| variant | time |
|---|---|
| true full `jit.off` (both functions) | 6.219 s ± 0.565 s |
| what v1 called "the baseline" | 1.350 s ± 0.143 s |
| split, positives JIT-compiled | 786.3 ms ± 132.3 ms |

Both original numbers were real measurements; the label was wrong. The whole
benchmark and workaround section is cut from the filing regardless — a bug
report does not need our mitigation, and publishing a number I had mislabeled
once is exactly the reputational risk you asked me to avoid.

This is also the *second* time in this session that `jit.off`'s recursive flag
misled someone about its scope. Worth remembering.

**Unsupported causal claims.** v1 asserted the split "does not help because
LuaJIT inlines it into the same trace." Codex checked and found the loop records
as its own root trace, so that explanation is wrong. Cut. Same for "it is the
sign branch itself" and "takes a trace specialized for a different sign
pattern" — plausible, unverified, cut.

**The IR hypothesis.** Cut entirely. Codex called it "speculative compiler
fan-fiction," which is fair. Guessing at a mechanism in front of the person who
wrote the compiler is a bad trade even when hedged.

**The warmup count.** v1 used 3000 calls and called the repro minimal. Codex
found it fails from 144; my own bisection found 162. The threshold differs
between harnesses, so I set the repro to 500 and described it qualitatively
rather than quoting a precise minimum that will not reproduce for others.

**Artifacts.** The committed IR dumps contain raw ANSI escapes. Stripped.

### The one thing I did not change, because it is your call

Codex recommends cutting the AI-identity paragraph and the thanks entirely, on
the grounds that the preamble "invites a maintainer to read the report as an
uncurated agent dump" and that Mike Pall does not need our workflow narrated.

You explicitly asked for both. I have left them out of v2 only so you can see
the report as Codex would have it, not because I decided against you.

My own view, for what it is worth: Codex is right that v1's version was too
long and congratulated itself for "doing the legwork." It is wrong that
disclosure should be omitted — a report substantially produced by a model
should say so, and burying that would be worse if it ever came out. The fix is
brevity. Something like:

> Filed by Peter Marreck. The investigation and reduction were done by Claude
> Opus 5 (Anthropic) under my review; I have verified the reproduction myself.
> Thanks for LuaJIT.

Three lines, no apology, no self-congratulation, and the reproduction carries
the argument. Say the word and I will put that back in, keep it out, or use
wording of your own.

### Still outstanding before filing

- Replace the placeholder SHA with the real 40-character commit hash.
- You confirming you have actually run the repro yourself, since the report says
  you reviewed it.
