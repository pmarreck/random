# Pinning the LuaJIT/LuaJIT#1499 fix in flake.nix — investigation

**Date:** 2026-08-02
**Context:** Part D of a hostile-audit fix pass. The task: override
`pkgs.luajit` in `flake.nix` to build the commit that fixes
[LuaJIT/LuaJIT#1499](https://github.com/LuaJIT/LuaJIT/issues/1499), so this
project's own packaged build gets the fix (and the ~5.7x mitigation cost
back) without waiting for nixpkgs-unstable to catch up. What actually
happened along the way is worth a permanent record, because none of it
was assumed — every claim below was built, run, and diffed.

**UPDATE (2026-08-02, same day):** §2 and §3 below originally reported
two LuaJIT defects as confirmed findings. Both were challenged, both
were re-investigated independently, and both are RETRACTED — see each
section's own "RETRACTED" heading and the "Retraction and root cause"
section after §3 for the full account. §1's finding (the version-string
mismatch) held up under the same scrutiny and is unchanged. The sections
are kept, not deleted, per this project's own discipline that a
documented non-finding is worth more than silence.

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

## 2. RETRACTED — "`bit.*` no longer accepts 64-bit cdata operands"

**This section originally claimed `bin/random`'s PCG32 code crashed on
the newly-pinned build. That claim is FALSE for the build actually
pinned in `flake.nix`. Retracted 2026-08-02, by the coordinator's direct
challenge and my own independent re-verification — see "Retraction and
root cause" below.**

Original claim (kept for the record, per the discipline that a
documented non-finding is worth more than silence): `bin/random`'s
`pcg32_random` passes `pcg_state` (a `uint64_t` cdata) directly into
`bit.rshift`/`bit.bxor`. A build was observed to crash on this with `bad
argument #1 to 'rshift' (number expected, got cdata)`, attributed to an
`lj_carith.c` diff between the pre-fix and newly-pinned source trees
showing a "64 bit bit operations helpers" section
(`lj_carith_check64`/`lj_carith_shift64`) present on one side and absent
on the other.

**What was actually true:** that crash was real, but on a DIFFERENT
LuaJIT build than the one this flake pins — commit `5ed524c` built
BARE (see §1: that commit lives on LuaJIT's `master` branch, not
`v2.1`), not commit `28084004` (the `v2.1`-branch merge actually pinned
in `flake.nix`). The two builds were investigated back to back, produced
different nix store paths, and the crash finding from the first was
never re-verified against the second before being written up. Directly
re-tested against the ACTUAL pinned build (`28084004`,
`jit.version = "LuaJIT 2.1.1785606157"`): `bit.rshift(u64_cdata, 18)`
and `bit.bxor(u64_cdata, u64_cdata)` both work correctly, both JIT-on
and JIT-off, matching the pre-fix build's own output exactly. The
`lj_carith_check64`/`lj_carith_shift64` functions ARE present in
`28084004`'s source tree (confirmed by grep — 2 matches) despite being
absent from bare `5ed524c`'s tree; whatever intervening history changed
this between the two commits was never chased down, because it stopped
mattering once the real pin was re-tested directly.

## 3. RETRACTED — "a separate, independent trace-compiler miscompilation"

**This section originally claimed a confirmed `ffi.cast("uint32_t", v)`
miscompilation, version-independent, latent in `bin/random`'s original
code. That claim is FALSE as stated. Retracted 2026-08-02 — see
"Retraction and root cause" below for the full account, including one
narrow, unresolved residual data point that re-verification also turned
up and that is recorded honestly rather than swept away.**

Original claim (kept for the record): after "fixing" §2, JIT-on/JIT-off
differential tests over the real `bin/random` still diverged (30/30
combinations), and golden vectors changed value. A minimal repro —
`ffi.cast(ffi.typeof("uint32_t"), <negative Lua number>)` in a hot loop
— was reported to produce different output streams under JIT-on vs
JIT-off, on both LuaJIT builds, and attributed to a trace-compiler
defect rather than a logic error (correctly reasoning that JIT-on/off
disagreement, not mere wrongness, is the signature of a compiler bug —
that PRINCIPLE was sound; the specific finding built on it was not).

**What was actually true, found by direct re-verification, not by
accepting either side's claim on authority:**

1. **The original `pcg32_random` (unmodified) does not crash or diverge
   on the actual pinned build.** Re-tested directly against `28084004`:
   `bin/random -d --seed 42 0 99` → `26` under both JIT-on and JIT-off;
   a 1,000,000-draw stream comparison (`-d --seed 1 -c 1000000 0
   4294967295`) is byte-for-byte IDENTICAL between JIT-on and JIT-off.
   `tests/random_jit_diff_test`, run against the ORIGINAL code under the
   real pinned LuaJIT, PASSES 30/30. The 30/30 divergence originally
   reported was measured against the WRONG store path — same root cause
   as §2's retraction, not a second independent error.

2. **The "minimal repro" that seemed to confirm a `ffi.cast` defect was
   itself broken.** `tostring()` on a `uint32_t` cdata does not print
   the numeric value — it prints a boxed-pointer representation:
   ```
   > tostring(ffi.cast(ffi.typeof("uint32_t"), 12345))
   cdata<unsigned int>: 0x71a17d1b7490      -- a HEAP ADDRESS
   > tostring(ffi.cast(ffi.typeof("uint64_t"), 12345))
   12345ULL                                  -- the actual value
   ```
   (`uint64_t`/`int64_t` get LuaJIT's special decimal+suffix formatting;
   plain `uint32_t` does not.) Every bisection script that printed a
   `uint32_t` result via a bare `tostring()` was therefore hashing
   RANDOM HEAP ADDRESSES across separate process invocations, not
   computed values — confirmed directly: re-running the identical script
   twice produced two different digests even in the SAME JIT mode,
   which is impossible for a deterministic, fixed-seed computation and
   should have been caught immediately as a test-harness bug rather
   than treated as signal. Re-run with the value correctly extracted via
   `tonumber()` first, the same repro (a bare `ffi.cast("uint32_t",
   <negative>)` hot loop, 300,000 iterations) shows NO divergence, on
   either LuaJIT build — matching the coordinator's own counter-test
   exactly.

3. **One narrow, unresolved residual finding**, surfaced by re-testing
   more carefully rather than swept under the rug: a SPECIFIC
   intermediate formulation this investigation tried and then
   discarded — `ffi.cast(u64, ffi.cast("uint32_t", rhi)) * 4294967296ULL
   + ffi.cast(u64, ffi.cast("uint32_t", rlo))`, recombining hi/lo halves
   inside a hot loop that also evolves real `u64` PCG state and calls
   `bit.bxor` each iteration — DOES show a real, reproducible (not an
   address-printing artifact: the printed values are genuine, differing
   `uint64_t` decimal outputs, e.g. `10572366454355499262ULL` vs
   `10572366458650466558ULL` at the same position) divergence between
   JIT-on and JIT-off, stable across repeated invocations (12485 of
   100,000 lines differ, identically, across 3 separate runs), on the
   ACTUAL pinned build (`28084004`) specifically — it does NOT reproduce
   on the pre-fix build. This conflicts with the coordinator's own
   report of testing "step-3 `ffi.cast(u64, ffi.cast(u32, rhi))`
   recombination" and finding no divergence; the discrepancy was not
   chased down further (different exact iteration count, different
   surrounding loop body, or a machine/environment difference are all
   plausible, unconfirmed candidates). **This does not affect anything
   shipped**: `bin/random` never used this exact recombination pattern
   in committed code (it was an intermediate debugging step, replaced by
   the pure-arithmetic `u32()` before ever being committed), and both
   the original `pcg32_random` and the current `xor64`/`u32()` rewrite
   are independently confirmed clean at 1,000,000-draw scale (point 1
   above, and the current-code verification in §4). Recorded here, not
   acted on, because a real reproducible anomaly that doesn't affect
   anything shipped is still worth a permanent note rather than silent
   disposal — exactly the same discipline this whole retraction is
   arguing for.

**Fix status: the `xor64`/`u32()` rewrite in `bin/random` is KEPT, but
its justification in the source comments has been rewritten** to the
portability argument that actually holds: passing 64-bit cdata to
`bit.*` relies on an UNDOCUMENTED extension (LuaJIT's manual describes
`bit.*` as a 32-bit-only API) that happens to work on every build tested
so far but carries no stated compatibility guarantee — not a claim that
it is broken, crashes, or miscompiles anywhere in the code that ships.
See `bin/random`'s own comments on `u32()`/`xor64()` for the corrected
text.

## Retraction and root cause

Both §2 and §3's original findings shared ONE underlying methodological
failure, not two independent ones: **a hypothesis that explained an
observed symptom was written up as a confirmed finding without an
independent check that it was the actual cause.**

- §2's crash was real — on a commit (`5ed524c` bare) that was
  superseded by a DIFFERENT commit (`28084004`) partway through this
  same investigation, once the version-string mismatch in §1 was found.
  The crash diagnosis was never re-run against the commit that actually
  shipped.
- §3's "confirmed miscompilation" rested on bisection scripts whose
  PRINTING mechanism was itself broken (`tostring()` on 32-bit cdata),
  producing digests that varied run-to-run even under a fixed seed and
  a single JIT mode — a fact that should have been the FIRST thing
  checked (reproducibility within a mode, before ever comparing across
  modes) and was not.

This is the same class of error this project has now made roughly six
times across its history, in both directions (shipping an unverified
"fixed" claim, and separately, twice, mishandling `FAST=` semantics) —
worth naming plainly rather than quietly editing away, per the
coordinator's explicit request. The fix going forward is procedural, not
just "be more careful": before writing up ANY differential result
(JIT-on vs JIT-off, old-build vs new-build, or any A-vs-B comparison)
as a finding, first confirm (a) the exact artifact under test is the one
that will actually ship, not a superseded intermediate build, and (b)
the observation is reproducible on its own terms — same input, same
mode, run twice — before treating cross-mode disagreement as signal.

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

**Re-verified after the §2/§3 retraction** (the `bin/random` comment
rewrite touches text directly adjacent to live code, so this was
re-checked rather than assumed safe): `bin/random -d --seed 42 0 99` →
`26`; `./tests/golden_test` (both sets) still reproduces; the
1,000,000-draw JIT-on/JIT-off stream comparison against the actual
pinned build is still byte-for-byte identical. No behavior changed —
only the comments justifying `xor64()`/`u32()` did.

## Takeaways

- Don't trust a commit hash's claimed version string without building it
  — a fix landing on `master` vs its merge into a release branch can
  report meaningfully different version metadata even for byte-identical
  fix content. (This one HELD UP under challenge — §1's finding, unlike
  §2/§3, was independently re-confirmed.)
- "JIT-on and JIT-off disagree with each other" is a stronger, more
  specific signal than "the test failed" as a PRINCIPLE — it rules out
  ordinary logic bugs and points at the trace compiler or the harness.
  But the principle only works if the disagreement is real: check
  reproducibility WITHIN a mode (same input, same mode, run twice)
  before ever comparing ACROSS modes. §3's original "finding" skipped
  that check and mistook non-deterministic address-printing noise for a
  compiler bug.
- When a build changes mid-investigation (as it did here, `5ed524c` →
  `28084004`, once §1's version-string problem was found), re-run EVERY
  prior finding against the NEW build before writing any of them up.
  Carrying a diagnosis forward across a substituted artifact is exactly
  how a real symptom (on the build actually tested) becomes a false
  claim (about the build that ships).
- A reproducible anomaly that doesn't reproduce for someone else's
  formulation of "the same" test, and that doesn't affect anything
  shipped, is still worth recording rather than either asserting as fact
  or discarding — see §3 point 3's residual finding.
