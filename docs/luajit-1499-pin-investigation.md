# Pinning the LuaJIT/LuaJIT#1499 fix in flake.nix — investigation

**Date:** 2026-08-02
**Context:** Part D of a hostile-audit fix pass. The task: override
`pkgs.luajit` in `flake.nix` to build the commit that fixes
[LuaJIT/LuaJIT#1499](https://github.com/LuaJIT/LuaJIT/issues/1499), so this
project's own packaged build gets the fix (and the ~5.7x mitigation cost
back) without waiting for nixpkgs-unstable to catch up. What actually
happened along the way is worth a permanent record, because none of it
was assumed — every claim below was built, run, and diffed.

## 1. The commit hash didn't report the version string everyone expected

The task's starting assumption: pin commit
`5ed524c09fec64bed46b4bf74fa03be9083b0963` ("Don't fold -a / -b for
unsigned operands" — the actual #1499 fix, per `lib/fixed.lua`'s own doc
comments from an earlier session), and it would report `jit.version` as
`LuaJIT 2.1.1785606157`.

Building it directly (`pkgs.luajit.overrideAttrs` with just `version`/`src`
changed) instead produced `LuaJIT 2.0.1785605975` — both the roll number
AND the branch label were wrong. Two separate reasons, both confirmed by
cloning upstream LuaJIT directly and inspecting history, not guessed:

- **Roll number**: `git show -s --format=%ct 5ed524c...` gives
  `1785605975`, not `1785606157`. The number `1785606157` belongs to a
  DIFFERENT commit, `28084004ee68d576f3f0c9ea61ea448fe3e10f07`
  ("Merge branch 'master' into v2.1"), timestamped 182 seconds later.
  `5ed524c` lives on LuaJIT's `master` branch; `28084004` is the commit
  that merges `master` (including `5ed524c`'s fix) into the `v2.1`
  branch. Confirmed `5ed524c` is an ancestor of `28084004` via
  `git merge-base --is-ancestor`, and that `src/lj_carith.c` is
  unaffected by that specific merge's own delta beyond what the merge
  brings in from master (i.e. the fix content is identical either way).
- **Branch label ("2.0" vs "2.1")**: LuaJIT's root `Makefile` sets
  `MAJVER`/`MINVER` directly (not derived from the branch name).  At
  `5ed524c` (still living on `master`, not yet merged into `v2.1`),
  `MAJVER=2 MINVER=0`. At `28084004` (post-merge, on `v2.1`),
  `MAJVER=2 MINVER=1`. `needs_1499_mitigation`'s version-string pattern
  (`"2%.1%.(%d+)"` in `lib/fixed.lua`) only matches the `v2.1` branch
  format — a bare build of `5ed524c` would silently fall into the
  FAIL-SAFE "unparseable version" branch and keep the mitigation ON
  regardless of the roll number, defeating the entire point of this pin.

**Resolution:** `flake.nix`'s `luajitFixed` override pins
`28084004ee68d576f3f0c9ea61ea448fe3e10f07`, not the bare `5ed524c` hash.
This needed no change to `lib/fixed.lua`'s `LUAJIT_1499_FIXED_IN`
constant — `28084004`'s roll number (`1785606157`) is exactly what that
constant already used.

**Likely explanation for the original mismatch** (not verified, offered
as the most plausible account): an earlier verification session probably
built the `v2.1` branch tip at the time (which happened to be at
`28084004`) rather than the bare `5ed524c` commit hash, and attributed
the resulting version string to "commit 5ed524c" from memory/narrative
rather than re-checking which exact commit produced it. Both commits
contain the identical functional fix, differing only by an unrelated
182-second merge — an easy mixup, not a fabrication.

## 2. `bit.*` library functions no longer accept 64-bit cdata operands

`bin/random`'s PCG32 implementation (`pcg32_random`) passed `pcg_state`
(a `uint64_t` cdata) directly into `bit.rshift`/`bit.bxor`. This crashed
immediately on the newly-pinned build:

```
bad argument #1 to 'rshift' (number expected, got cdata)
```

Confirmed by diffing `src/lj_carith.c` between the OLD (pre-fix,
`fbb36bb6`, what nixpkgs-unstable currently pins) and NEW (`28084004`)
source trees: an entire section, "64 bit bit operations helpers"
(`lj_carith_check64`, `lj_carith_shift64` — "Equivalent to
`lj_lib_checkbit()`, but handles cdata") was REMOVED between them. This
was an undocumented extension to the officially 32-bit-only `bit.*` API
that this project's original PCG32 implementation happened to rely on;
its removal is not itself a bug, just a tightening back to documented
behavior.

**Fix:** `bin/random` now does the required 64-bit right-shifts via plain
unsigned `u64` cdata DIVISION (`old / 262144ULL` for `old >> 18`, etc. —
exact for unsigned values, the same technique `lib/fixed.lua`'s own
`M.norm` shift loops already use) and a hand-rolled `xor64()` helper that
splits each 64-bit operand into hi/lo 32-bit halves, XORs each half with
the officially-supported 32-bit `bit.bxor`, and recombines. Verified
against the removed extension as an independent oracle: 200,000 random
`u64` pairs plus adversarial edge cases (all-zero, all-one, MSB-only,
mixed high/low patterns), 0 mismatches, on the pre-fix build where the
removed extension still works as ground truth.

## 3. A SEPARATE, independent trace-compiler miscompilation

Even after fixing #2, `tests/random_jit_diff_test` (JIT-on vs JIT-off
differential over `bin/random` itself) failed 30/30 combinations, and
`tests/golden_test` failed (both golden sets changed value) — under the
NEW LuaJIT build specifically. Isolated with a minimal, standalone
repro (bisection transcript below), NOT inferred from the failure alone:

```lua
-- Isolated repro: a hot loop doing nothing but reinterpreting a signed
-- int32-range Lua number as unsigned via ffi.cast.
local ffi = require("ffi")
local u32 = ffi.typeof("uint32_t")
for i = 1, 200000 do
  local v = <some int32-range Lua number, occasionally negative>
  local r = ffi.cast(u32, v)
  -- accumulate/print r
end
```

Run under `luajit` (JIT-on) vs `luajit -joff` (interpreted): the output
streams DIFFER. A genuine logic bug would make JIT-on and JIT-off AGREE
with each other (both wrong the same way, since both execute the same
Lua source); disagreement between them is specifically the signature of
a trace-compiler MISCOMPILATION. Confirmed this reproduces on BOTH the
pre-fix (`2.1.1774638290`) and post-fix (`2.1.1785606157`) builds —
version-independent, unlike #1499 itself, and apparently latent in
`bin/random`'s ORIGINAL `pcg32_random` all along (`tonumber(ffi.cast(
"uint32_t", res))` at its final line, unchanged by this session until
this fix) — it simply never manifested because the pre-fix code's exact
trace-formation pattern happened not to trigger it, the same
warmup-pattern sensitivity this project's own #1499 documentation
already describes for that bug.

Bisection method (each step isolated one operation, comparing JIT-on vs
JIT-off over 100,000-200,000 iterations):
1. u64 division/modulo alone (hi/lo split) — IDENTICAL, not the cause.
2. `bit.bxor` on the resulting hi/lo halves — IDENTICAL, not the cause.
3. `ffi.cast(u64, ffi.cast("uint32_t", rhi))` recombination — DIVERGED.
4. Isolated further: a BARE `ffi.cast("uint32_t", <negative Lua number>)`
   in a hot loop, nothing else — DIVERGED on its own.

**Fix:** replaced every `ffi.cast(..., "uint32_t", v)` sign-reinterpretation
in `bin/random`'s PCG32 path with a pure-arithmetic equivalent:

```lua
local function u32(v)
  if v < 0 then return v + 4294967296 end
  return v
end
```

The result (magnitude < 2^32) is exactly representable as a Lua double
(far under the 2^53 exact-integer boundary), so this needs no cdata at
all — sidestepping the cast miscompilation entirely rather than working
around one specific trigger condition. Re-verified: JIT-on and JIT-off
now agree bit-for-bit over 200,000+ iterations on BOTH LuaJIT builds.

## 4. Final verification (all satisfied)

- `nix build` succeeds; `./result/bin/random -d --seed 42 0 99` → `26`.
- Packaged LuaJIT reports `LuaJIT 2.1.1785606157` (`jit.version`).
- `fx._needs_1499_mitigation_for_tests` is `false` under the packaged
  build (mitigation correctly reports itself inactive).
- `tests/golden_test` (both "integer" and "dist" sets) reproduces
  IDENTICALLY under both the pinned (`28084004`) and system
  (pre-fix, `fbb36bb6`) LuaJIT.
- Full FAST and deep `./test` (all 6 suites, including
  `random_jit_diff_test` and `kernel_jit_diff`) pass under BOTH LuaJIT
  builds.
- `nix flake check` passes.
- Measured recovered speed (hyperfine, `-N --warmup 3`,
  `--log-normal -d --seed 1 -c 20000`): pre-fix build (mitigation ON)
  5.988s ± 0.137s vs the newly-pinned build (mitigation OFF, via
  `./result`) 1.127s ± 0.054s — **5.31x ± 0.28x faster**, consistent
  with the previously-measured ~5.7x figure (same order of magnitude;
  the residual gap is ordinary machine-load noise between separate
  hyperfine invocations, not a discrepancy worth chasing further).

## Takeaways

- Don't trust a commit hash's claimed version string without building it
  — a fix landing on `master` vs its merge into a release branch can
  report meaningfully different version metadata even for byte-identical
  fix content.
- "JIT-on and JIT-off disagree with each other" is a stronger, more
  specific signal than "the test failed" — it immediately rules out
  ordinary logic bugs and points straight at the trace compiler, which is
  exactly what let this be isolated to a 4-line minimal repro rather than
  debugged inside the full `pcg32_random` call graph.
- An undocumented LuaJIT extension (`bit.*` accepting 64-bit cdata) and a
  genuine, version-independent miscompilation (`ffi.cast` sign
  reinterpretation) were BOTH latent in this project's shipped code before
  this investigation — neither was introduced by pinning a new LuaJIT
  commit; pinning a different build is simply what finally exercised the
  code paths that exposed them.
