# PLAN

## Done
- [x] Fix `pcg32_range` infinite loop for ranges > 2^32 (2026-08-01 EST)
- [x] Golden vectors for the integer paths, blessed pre-conversion (2026-08-01 EST)
- [x] Integer-only soft-float kernel: mul/add/div/ln/exp/cos/sqrt/pow (2026-08-01 EST)
- [x] Integer-only decimal parse and format (2026-08-01 EST)
- [x] `bc` sweep control + JIT/interpreter differential (2026-08-01 EST)
- [x] Convert `bin/random`; Poisson to sum-of-exponentials (2026-08-01 EST)
- [x] Golden vectors for the distributions (2026-08-01 EST)
- [x] Package `lib/` in `flake.nix`; point `checks.random-test` at the full
      `./test` runner instead of just `tests/random_test` (2026-08-01 EST)
- [x] `kernel_bc_sweep`: missing `bc` now fails loudly instead of skipping
      silently, so the check can't lose coverage without anyone noticing
      (2026-08-01 EST)
- [x] README: determinism guarantee, exact PRNG spec (PCG32 XSH-RR 64/32,
      multiplier/increment/seeding), measured libm divergence, LuaJIT #1499
      note, compatibility note (2026-08-01 EST)
- [x] `cos_turns` negative-`u` branch: documented as intentional
      out-of-domain defense, not dead code (2026-08-01 EST)
- [x] `M.parse` dedicated unit pin: sign applies to the full integer+fraction
      magnitude, not just the integer part (2026-08-01 EST)
- [x] Spec status line: steps 1-4 implemented, step 5 (Zig port) pending
      (2026-08-01 EST)
- [x] Codex hostile-review fixes, all 8 findings: `pcg32_range` power-of-two
      hang, `$IFS`-independent default delimiter, `DRANDOM_SEED` implies
      `-d`, malformed-seed grammar (nil-check + u64 overflow guard), large
      integer bounds/weights past 2^53 (`M.parse_int_safe`), `M.norm`/
      `M.mul` integer-exponent asserts, `M.parse` bignum fallback past
      int64 + `M.tostring` shift guard (shared `MAX_INT_PART_DIGITS`). Full
      report with before/after evidence and mutation-test results:
      `docs/codex-fix-report.md`. Golden vectors unmoved throughout
      (2026-08-02 EST)
- [x] Hostile audit (round 2) fixes: 9 vacuous/weak test controls (Part A,
      mutation-verified 10/10 both directions each), the i32 exponent
      contract validated on inputs not just outputs + `to_int_trunc`'s
      silent-round-not-clamp defect (Part B), ~15 false/stale claims across
      PLAN.md/README/lib/fixed.lua/the design spec (Part C), and
      `flake.nix` now pins LuaJIT commit `28084004` (the `v2.1`-branch
      merge of the actual #1499 fix, `5ed524c` -- see
      `docs/luajit-1499-pin-investigation.md` for why the bare fix commit
      hash doesn't work: wrong branch, wrong version string). `bin/random`'s
      PCG32 code was also rewritten (`xor64`/`u32()`, portability-motivated:
      avoids an undocumented LuaJIT extension rather than a confirmed
      defect) -- an initial version of this work claimed two confirmed
      LuaJIT bugs motivated the rewrite; both were challenged by the
      coordinator, independently re-investigated, and RETRACTED (one was
      diagnosed against a since-superseded commit and never re-checked
      against the actual pin; the other's evidence was contaminated by a
      test-harness bug printing cdata pointer addresses instead of
      values). See `docs/luajit-1499-pin-investigation.md`'s "RETRACTED"
      sections for the full account. Measured recovered speed: 5.31x
      +/- 0.28x (hyperfine, `--log-normal -c 20000`). Golden vectors
      unmoved throughout, verified under both the pinned and system
      LuaJIT, re-verified again after the retraction. Full report:
      `docs/codex-audit-fix-report.md` (2026-08-02 EST)

## Next: Zig port (separate plan)
- [ ] `src/fixed.zig` mirroring `lib/fixed.lua`, verified against the same `bc` sweep
- [ ] Zig core (pure, no I/O) + `include/randomz.h` C FFI
- [ ] `randomz` C CLI + `drandomz`/`nrandomz` symlinks, argv[0] dispatch
- [ ] Differential harness: `randomz` vs `bin/random` over a seed x flag matrix
- [ ] Cross-target digest control: x86_64 / aarch64 / musl must agree
- [ ] `./bm` benchmark suite covering **both** implementations — LuaJIT and Zig —
      so the port's speedup is measured rather than assumed, and so a regression
      in either is visible. Per the fleet convention: ndjson log per machine-id,
      committed, two-sided tolerance (a surprise speedup may mean lost work),
      CPU time for single-threaded kernels, ReleaseFast only. Note the existing
      measured figure to beat: the `#1499` mitigation costs ~5.7x on the float
      distributions on pre-fix LuaJIT and nothing on fixed builds, so the
      benchmark must record which LuaJIT it ran under.
- [ ] Mechatron Prime CI via the `mechatron-ci` skill

## TODO
- [ ] Drop `flake.nix`'s `luajitFixed` override (and its `28084004` pin) once
      nixpkgs-unstable's own `pkgs.luajit` picks up a commit at or past the
      real #1499 fix (roll number >= 1785606157, branch `v2.1`) — check via
      `nix eval nixpkgs#luajit.version`. Once dropped, revert `runtimeTools`
      back to `[ pkgs.luajit ]` directly.

## Deferred (recorded, deliberately not fixed)
- `LUAJIT_1499_FIXED_IN` in `lib/fixed.lua` (currently `1785606157`) is a magic
  constant with no AUTOMATED link to `flake.nix`'s pinned LuaJIT toolchain --
  MANUALLY verified aligned as of 2026-08-02 (`flake.nix`'s `luajitFixed`
  override pins exactly the commit whose roll number is this constant; see
  `docs/luajit-1499-pin-investigation.md`), but nothing enforces that
  alignment going forward. A manual bump of either side (the constant, or
  the nixpkgs LuaJIT pin once the override above is dropped) could drift
  silently — e.g. pinning a LuaJIT built after the real #1499 fix but
  forgetting to lower the constant just wastes the ~5.7x mitigation cost
  forever; getting it backwards (raising the constant past a build that still
  has the bug) would silently reintroduce the miscompilation. No test
  currently cross-checks the constant against the toolchain's actual
  `jit.version`; would need something like a check step that builds against
  `pkgs.luajit` and asserts `jit.version`'s roll number against the constant
  in both directions.
- `./test`'s exit code is the raw suite-failure count, unclamped — wraps
  modulo 256 past 255 failing suites. With 6 suites total today (fixed_test,
  golden_test, random_test, random_jit_diff_test, kernel_bc_sweep,
  kernel_jit_diff — plus, as of this audit round, a required-suite manifest
  that fails loudly if any of the 6 goes missing or non-executable) this is
  unreachable in practice; not worth guarding until the suite count grows by
  two orders of magnitude.
- `./test`'s `for suite in ... ; do [ -x "$suite" ] || continue; ...` glob
  loop would treat an executable directory as a suite (and then fail
  confusingly when `timeout` execs it). No directory named `*_test` (or
  `kernel_bc_sweep`/`kernel_jit_diff`) exists under `tests/` today; low risk,
  not fixed.
- `tests/random_test`'s power-of-two range classifier (Test 20d) sweeps
  2^33..2^52, not the full 2^33..2^62 the original finding specified.
  `M.parse_int_safe`'s later 2^53 CLI ceiling (finding #3 in
  `docs/codex-fix-report.md`) makes spans above 2^53 unreachable through
  positional CLI arguments at all -- not a weakening of the `pcg32_range`
  fix itself, which is unconditional u64 arithmetic with no reference to
  that ceiling. Recovering full coverage to 2^62 would need a Lua-level
  test entry point into `pcg32_range` (currently a local, unexported
  function in `bin/random`); not worth the refactor for a range no CLI
  invocation can produce.
