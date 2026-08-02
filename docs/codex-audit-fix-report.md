# Hostile audit (round 2) fix report

Date: 2026-08-02
Scope: Part A (vacuous test controls), Part B (implementation defects),
Part C (false/stale claims), Part D (LuaJIT pin) from a hostile audit of
this project's tests and documentation. Commits: `6ca808d..2fbae65` (12
commits, one per item or logical group, in the order below).

Discipline followed throughout: every Part A/B item was reproduced
against the pre-fix code (confirming the audit's exact claim) before
being fixed, then mutation-verified 10/10 consecutive failing runs with
the mutation applied, 10/10 passing runs restored. `./tests/golden_test`
(2 sets: `integer`, `dist`) and the full `./test` suite (all 6 suites,
FAST and non-FAST) were run after every change and never moved/failed
except where a fix was in progress. Golden vectors are unmoved at the
end of this session, verified under both the project's system LuaJIT
and the newly-pinned LuaJIT (Part D).

---

## Part A — surviving mutants

### A1. `kernel_bc_sweep` could silently skip an entire function

**Finding:** deleting `bc_lines[#bc_lines+1] = expr` from `add_sqrt_case`
(the label still landed in the shared `labels` table, but the
corresponding `bc` line never got emitted) reduced the sweep to
5384/7413 measurements, `worst sqrt 0 (nil)`, and the suite still
reported PASSED.

**Reproduced:** confirmed exactly — `worst sqrt relative error:
0.000000e+00 (nil)`, exit 0.

**Fix:** track every label `bc` actually reported an outcome for
(measured, SKIPped, or tostring-compared) in a new `observed` set built
during the parse loop; fail loudly listing the missing labels if any
generated label (from the `labels` table, populated unconditionally by
every `add_*_case`) is absent from `observed`. Added a belt-and-suspenders
per-function check that a non-nil worst-error label exists for every
category that generated at least one case.

**Mutation:** 10/10 fail (reverted push), 10/10 pass (restored).

Commit: `6ca808d`

### A2. `golden_test` passed with a golden file deleted

**Finding:** the only zero-files guard was `checked -eq 0`, which only
fires if EVERY golden set vanishes. Deleting `tests/golden/dist.txt`
alone left `checked=1`, reporting "All 1 set(s) reproduce", exit 0.

**Reproduced:** confirmed exactly.

**Fix:** `REQUIRED_SETS="integer dist"`, checked by name; missing file
is a named failure. Also flags any `golden/*.txt` file NOT in the
manifest, so an unlisted set can't sit unchecked either.

**Mutation:** 10/10 fail, 10/10 pass.

Commit: `80cf828`

### A3. `random_jit_diff_test` passed when both LuaJIT invocations failed

**Finding:** `luajit ... | md5sum | awk ...` only ever exposed
`md5sum`'s exit status, never `luajit`'s; `[ -z "$on_md5" ]` cannot catch
a silently-failed producer either, since `md5sum` of empty input is
itself a real, non-empty, deterministic digest
(`d41d8cd98f00b204e9800998ecf8427e`). With `luajit() { return 70; }`
exported, both JIT-on/JIT-off pipelines hashed the same empty stdout and
the control reported "30 combinations agree", exit 0.

**Reproduced:** confirmed exactly.

**Fix:** capture each producer's raw stdout into a variable first (so
`$?` immediately after is the producer's own exit code, not a
pipeline's), check it explicitly. Also check output plausibility
directly: each combo must produce exactly `COUNT` (300) lines.

**Mutation:** 10/10 fail, 10/10 pass.

Commit: `129e042`

### A4. `./test` silently omitted non-executable suites

**Finding:** `chmod -x tests/fixed_test tests/kernel_bc_sweep` left the
glob-based loop silently running the remaining 4, reporting "All 4
suite(s) passed", exit 0.

**Reproduced:** confirmed exactly.

**Fix:** `REQUIRED_SUITES` array naming all 6 shipped suites
(`fixed_test`, `golden_test`, `random_test`, `random_jit_diff_test`,
`kernel_bc_sweep`, `kernel_jit_diff`), checked by name before the
existing glob-driven loop. An unfiltered `./test` hard-fails, by name, if
any is missing or non-executable. Gated on `-z "$filter"` so `./test
<substring>` (an intentional partial run) isn't blocked by suites outside
the requested filter.

**Mutation:** 10/10 fail, 10/10 pass.

Commit: `a74acb9`

### A5–A9. `random_test` vacuous/weak checks (5 items) + 5 lower-priority gaps

All fixed and mutation-verified in one commit (`60255ab`) since they
share one file.

**A5 — `--exponential` computed `EXP_VAR` but never asserted it.**
Reproduced: mutating `exponential_random` to `return fx.from_int(1)`
(a constant) gave `mean=1.000, var=0.000, min=1.000`, PASSED. Fix:
assert variance in `(0.3, 3.0)`. Mutation: 10/10 fail, 10/10 pass.

**A6 — `--binaryoutput --normalized` had only a `>=35%` lower bound on
"center-heavy".** Reproduced: forcing every byte to a constant 128 gave
100% "in center", PASSED. Fix: added an 85% upper bound plus a direct
`stddev > 15` spread requirement (measured real normal ~42.5, constant
= 0). Mutation: 10/10 fail, 10/10 pass.

**A7 — `--shuffle` computed `shuffle_order`/`input_order` and never
compared them.** Reproduced: a no-op `shuffle_array` (`return arr`)
passed outright — only the multiset (sorted) comparison was asserted.
Fix: assert order differs from input for at least one of two seeds
(77777, 77778), still requiring the same multiset for both. Mutation:
10/10 fail, 10/10 pass.

**A8 — the 68/95/99.7 rule's bucket bounds also accept a symmetric
triangular distribution.** Reproduced: mutating `normal_random_int` to
Irwin-Hall-2 (`math.floor((n1+n2)/2)`, a triangular deviate) measured
65.0/96.6/100% across all 5 `NORMAL_TEST_SEEDS`, comfortably inside
55-80/85-99/>=98 — PASSED under the pre-fix bounds. Fix: added an
excess-kurtosis shape discriminator (normal=0, triangular=-3/5, a fixed
distribution-level difference, not a tuned bucket edge) at a dedicated
`SHAPE_SAMPLE_SIZE=4000` (independent of `FAST` — kurtosis is a
4th-moment statistic too noisy to resolve at `FAST`'s n=100). Measured
real-generator excess kurtosis in [-0.25, -0.07] across the 5 seeds
(truncation-shifted below the untruncated-normal 0), triangular measured
[-0.66, -0.58]; cutoff -0.4 sits with ~0.15-0.18 margin on both sides.
Mutation: 10/10 fail, 10/10 pass; also directly reproduced the OLD test
still passing the triangular mutant (audit's claim) before fixing.

**A9 (5 lower-priority items):**
- Test 1/2 claimed to test `--about/-a` and `--help/-h` but only
  invoked `--about` and `-h`. Now both alias forms are exercised and
  required to match. Mutation (removed the `-a`/`--help` alias branches
  in `bin/random`): 10/10 fail, 10/10 pass.
- Test 6 (custom range) drew one unseeded value, bounds-only. Mutation
  (`urandom_range` forced to `return start_val`) showed the old test
  still passing; now also draws a 50-value batch and requires >1
  distinct value. Verified via output-message assertion (the same
  mutation also hangs an unrelated pre-existing unseeded test, Test 21,
  confounding whole-suite exit-code-based mutation testing — see note
  below): 10/10 caught, 10/10 clean pass restored.
- Test 12 (`--binaryoutput` custom range) validated only the first 50 of
  200 generated bytes via `head -50`. Mutation (forced the last
  generated byte out of range): old test passed, new test fails 10/10,
  restored passes 10/10.
- Deleted `BINARY_SAMPLE_SIZE`, assigned twice, read nowhere.

**Note on A9's range-distinctness mutation:** the `urandom_range`
mutation is a broad, shared-function change that also happens to hang
an UNRELATED pre-existing test (Test 21, unseeded `--normalized`, not in
audit scope) via an infinite `until` retry loop once the underlying
"randomness" becomes a constant. This makes whole-suite exit-code-based
mutation testing non-discriminating for this specific item (both old and
new test scripts eventually time out for the SAME unrelated reason).
Verified instead via the specific assertion message in the (bounded,
`timeout`-wrapped) output, which is unaffected by the later hang. Not a
gap in the fix itself — Test 21's own hang-under-constant-randomness is
a separate, pre-existing latent issue, out of this audit's scope,
recorded here rather than silently worked around.

Commit: `60255ab`

---

## Part B — implementation defects

### B1. i32 exponent contract validated only results, not inputs

**Finding:** `M.norm`, `M.mul`, `M.div` each asserted the i32 contract
only on the computed RESULT. An out-of-contract INPUT could slip
through whenever the arithmetic happened to land back in range before
the output check ever saw it.

**Reproduced exactly:**
```
fx.norm(1LL, 2147483648)                              -- e one past I32_MAX
  -> (4611686018427387904LL, 2147483586), no error
fx.mul(m, 3000000000, m, -3000000000)                 -- e1 alone past I32_MAX
  -> succeeds (sum cancels to 0)
fx.div(m, 3000000000, m, 2999999900)                  -- e1 alone past I32_MAX
  -> succeeds (difference cancels to 100)
```

**Fix:** shared `assert_i32(e, label)` helper (`I32_MIN`/`I32_MAX` named
once); added an input-side call at the top of each of the three
functions, using the SAME message text as each function's pre-existing
output check (not a distinct "input exponent N" variant) so
previously-pinned tests asserting on that exact message keep passing
regardless of which check fires first. `M.div`'s dispatch structure and
both `jit.off` calls unchanged.

**Tests added:** 4 new regression tests in `fixed_test.lua` (tagged
`[B1]`), covering the input-side gap specifically (existing tests only
ever exercised an already-normalized mantissa, where input and output
checks are indistinguishable).

**Mutation:** reverting the three input checks fails 3 of 4 new tests
10/10 (the 4th, norm's negative-exponent case, is a legitimate case
where the output check alone already catches it — shifting AWAY from
range never walks back in — included anyway as a documented regression
pin); restoring passes 10/10.

Commit: `e008bd4`

### B2. `to_int_trunc` silently rounds past 2^53, doesn't clamp

**Finding:** the doc comment claims "values whose magnitude exceeds 2^53
are clamped" — true for the `sh>=0` branch only. The `sh<0` branch
computed an EXACT int64 quotient (no precision loss there) but handed it
to a bare `tonumber()`, which silently ROUNDS once the quotient's
magnitude passes 2^53.

**Reproduced exactly:** true integer `2^54+3` (18014398509481987)
returned `18014398509481988` (rounded UP by 1, not the documented
9007199254740992 clamp). Reachable from the CLI via a large `--mean`
(`fx.parse` has no 2^53 cap the way `parse_int_safe`'s positional-bound
path does): `bin/random -n --mean 18014398509481987 --stddev 1 -d
--seed 1 -c 1` printed the same silently-wrong value.

**Fix:** compare the quotient (still an exact int64) against the clamp
threshold BEFORE `tonumber()` runs, returning the same clamp constant
the `sh>=0` branch already uses.

**Tests added:** 4 regression tests (tagged `[B2]`): the 2^54+3 clamp on
both signs, and boundary correctness (2^53 exactly NOT clamped, 2^53-1
exact).

**Mutation:** reverting to the bare `tonumber()` fails 2 of 4 new tests
10/10 (the boundary tests correctly still pass either way, since both
are under/at the threshold where rounding and clamping agree);
restoring passes 10/10. CLI repro re-verified fixed (now prints the
clamp value, not the silently-wrong one).

Commit: `87559b2`

---

## Part C — false and stale claims

All comment/doc-only changes; no behavior changes except where noted
(the `--about` fix, which is Part C's one "implement, don't just
document" item).

- **PLAN.md JIT threshold**: said `1785577137` (the confirmed-still-broken
  build from `docs/luajit-bug-report.md`); the actual constant
  (`LUAJIT_1499_FIXED_IN`) is `1785606157`. Fixed.
- **~5.5x vs ~5.7x**: every measurement-sourced mention (README,
  `lib/fixed.lua` x2, all from the same hyperfine run) says ~5.7x; only
  PLAN.md said ~5.5x. Picked the measured number.
- **"5 suites" vs 6**: `./test` selects 6 (and now enforces that count
  via A4's manifest). Fixed.
- **`nix flake check` "runs the full suite"**: it forces `FAST=1`,
  skipping `kernel_jit_diff`'s deep JIT differential by that suite's own
  design. Restated to say what actually runs.
- **`M.exp` "has NO live callers"**: false since Task 12 —
  `bin/random`'s `exponential_random`/`poisson_random`/`lognormal_random`
  all call `fx.exp`; no `math.exp` call site remains. Fixed in both
  locations that made the claim.
- **`round_to_int`'s `math.floor(v+.5)` rationale**: claimed "correct in
  both directions"; `math.floor(-2.5+0.5) == -2`, not the correct
  ties-away-from-zero `-3` — floor rounds ties toward +infinity
  unconditionally, the identical asymmetry (reached differently) the
  surrounding comment already diagnoses in the truncate-based formula.
  Corrected the rationale; `round_to_int`'s own (correct) behavior
  unchanged — verified `round_to_int(-2.5) == -3` still holds.
- **"twenty-four orders of magnitude"** (`M.pow`'s doc comment): the gap
  is `2^24`, i.e. ~7.2 DECIMAL orders, not 24. Fixed.
- **Design spec** (`docs/specs/2026-07-31-...md`), stale in the audit's
  cited 9+ places: representation (`{m:i64, magnitude [2^62,2^63)}`, not
  `{m:u64 [2^63,2^64), sign}`), function names (`M.mul`/`M.add`/`M.sub`/
  `M.norm`, not `sfmul`/`sfadd`/`normalize`), ln term count (20, not
  12), constant generation (scale=60, FLOORED, not scale=40 rounded),
  tostring sample count (800, not 650), `bc`'s independence argument
  (self-contained arithmetic, not "links only libc" — it also links
  readline/ncurses for its REPL), historical vs current framing for the
  pre-kernel `math.log`/`cos`/`exp`/`pow` claim, positional-bound parsing
  (`parse_int_safe`, capped at 2^53, not "plain i64"), and 3
  promised-but-unshipped features each recorded explicitly:
  - Scientific notation output: **DROPPED** (fixed-decimal + a hard
    `MAX_INT_PART_DIGITS` ceiling already serves every real input).
  - `CHANGELOG.md`: **DROPPED** (not part of this project's mandatory
    conventions; PLAN.md + git history already serve as the record).
  - `--about` version/platform/arch: **IMPLEMENTED** (see below), since
    it closes a gap against this fleet's own MANDATORY CLI convention,
    not just an optional spec promise.
  Also fixed an internal inconsistency (§10's stale "eight orders of
  margin" vs §4.6/§2's more precise, already-measured "fourteen
  orders"). Added a top-of-file AS-BUILT NOTE.
- **`--about`**: was bare prose (no version/platform/arch), violating
  the fleet's mandatory CLI convention. Implemented: `VERSION` constant
  (manually synced with `flake.nix`'s package version) plus
  `jit.os`/`jit.arch`. New format: `random v0.1.0 (Linux/x64): Unified
  random number generator: ...`. Test 1 now checks dynamically against
  the running interpreter's own `jit.os`/`jit.arch` (portable across
  platforms) plus a `vN.N` pattern. **Mutation:** reverting to
  prose-only fails 10/10, restoring passes 10/10.
- **Orphaned evidence citations**: ~30 comments across `lib/fixed.lua`,
  `tests/fixed_test.lua`, `tests/kernel_bc_sweep.lua`,
  `tests/kernel_jit_diff.lua` cited deleted `task-N-report.md`/
  `final-fix-report.md` files. Each either dropped (essential number
  already inline) or, where the citation carried unrepeatable specifics
  with no values given, dropped the unverifiable claim along with it.
  Left non-file "task-N"/"task-N's mutation pass" references alone
  (name a project phase, not a dangling file pointer).

Commits: `665dede`, `fc4d83b`, `0bfb713`, `09f5852`

---

## Part D — pin the fixed LuaJIT

**Full investigation, with transcripts:**
`docs/luajit-1499-pin-investigation.md`.

**What was asked:** override `pkgs.luajit` in `flake.nix` to build
commit `5ed524c09fec64bed46b4bf74fa03be9083b0963` (the actual #1499
fix), expecting it to report `LuaJIT 2.1.1785606157`.

**What was found, empirically, not assumed:**

1. Building bare `5ed524c` reports `LuaJIT 2.0.1785605975` — WRONG on
   both the roll number and the branch label. `5ed524c` lives on
   LuaJIT's `master` branch (`MAJVER=2 MINVER=0` in its own Makefile);
   the commit that actually merges it into the `v2.1` branch (`MAJVER=2
   MINVER=1`) is `28084004ee68d576f3f0c9ea61ea448fe3e10f07`
   ("Merge branch 'master' into v2.1"), timestamped 182 seconds later,
   confirmed an ancestor-inclusive merge of `5ed524c`. Pinned
   `28084004` instead — reports `LuaJIT 2.1.1785606157` exactly, needing
   zero changes to `lib/fixed.lua`'s already-reviewed
   `LUAJIT_1499_FIXED_IN` constant.

2. Building against this pin crashed `bin/random` immediately:
   `bin/random`'s `pcg32_random` passed `pcg_state` (a `uint64_t` cdata)
   directly into `bit.rshift`/`bit.bxor`, relying on an undocumented
   LuaJIT extension (`lj_carith_check64`/`shift64` in `lj_carith.c`)
   that was removed between the pre-fix commit nixpkgs pins and this
   one — confirmed by diffing the upstream source trees directly. Fixed
   with a portable `xor64()` helper (hi/lo 32-bit split, `bit.bxor` each
   half, recombine) plus u64 division for the 64-bit right-shifts;
   verified against the removed extension as an independent oracle
   (200,000 cases, 0 mismatches).

3. After fixing #2, `random_jit_diff_test` failed 30/30 and
   `golden_test` failed (both sets changed) — under the new LuaJIT
   specifically. Isolated to a minimal, 4-line repro: a hot loop doing
   nothing but `ffi.cast("uint32_t", <negative Lua number>)` produces
   DIFFERENT output under JIT-on vs JIT-off — a genuine trace-compiler
   miscompilation (JIT-on/off disagreeing with each other, not merely
   both being wrong, is specifically that signature), reproducible on
   BOTH the pre-fix AND post-fix LuaJIT builds, and apparently latent in
   `bin/random`'s ORIGINAL `pcg32_random` all along (its final
   `tonumber(ffi.cast("uint32_t", res))`, unchanged until this fix) —
   it simply never manifested because the pre-fix code's exact
   trace-formation pattern never triggered it. Fixed by replacing every
   such cast with pure arithmetic (`v < 0 and v + 4294967296 or v`),
   which needs no cdata at all.

**Verification (all satisfied):**
- `nix build` succeeds; `./result/bin/random -d --seed 42 0 99` → `26`.
- Packaged LuaJIT reports `LuaJIT 2.1.1785606157`.
- `fx._needs_1499_mitigation_for_tests` is `false` under the packaged
  build.
- `tests/golden_test` (both sets) reproduces IDENTICALLY under both the
  pinned and system LuaJIT.
- Full FAST and deep `./test` (all 6 suites) pass under BOTH LuaJIT
  builds.
- `nix flake check` passes.
- Measured recovered speed (hyperfine, `-N --warmup 3`, `--log-normal -d
  --seed 1 -c 20000`): pre-fix build (mitigation ON) 5.988s ± 0.137s vs
  the newly-pinned build (mitigation OFF) 1.127s ± 0.054s — **5.31x ±
  0.28x faster**, consistent with the previously-measured ~5.7x figure.

PLAN.md: added a TODO to drop the override once nixpkgs-unstable's own
`pkgs.luajit` catches up, and updated the `LUAJIT_1499_FIXED_IN`
deferred note to record the manual (not automated) verification.

Commit: `2fbae65`

---

## What was not fixed, and why

- **`docs/plans/2026-08-01-deterministic-numeric-kernel.md`**'s own
  "links only libc" claim (inside a shown, already-executed git-commit-
  message code block) was left as-is. It is a historical planning
  artifact recording what WAS run, not living documentation; the same
  factual correction was made everywhere it appears in the actual
  design spec and in code comments, which are the documents readers
  actually consult.
- **A9's range-distinctness mutation's confound** with Test 21 (see Part
  A9 note above): Test 21 itself (a pre-existing, unseeded
  `--normalized` range check, not in this audit's scope) hangs under an
  extreme mutation to `urandom_range` — a separate, latent issue, not
  fixed here since it is out of scope and not one of the audit's named
  findings.
- **`fixed_test.lua`'s "task-N's mutation pass" phase references** (non-
  file, e.g. "task-9's mutation pass targets") were deliberately left
  alone — they name a project phase, not a dangling file pointer, and
  remain meaningful without the deleted report files.

No golden vector moved at any point in this session. Every fix that
touched behavior (B1, B2, A5-A9, the `--about` implementation, and Part
D's two LuaJIT-bug fixes) was verified via a failing-before/passing-after
test, mutation-tested 10/10 in both directions where a code-level
mutation was applicable, or (Part D) verified via an independent
differential (JIT-on vs JIT-off, old LuaJIT vs new LuaJIT) plus golden
vector reproduction under both toolchains.
