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

- [x] **Cross-architecture determinism VERIFIED** — the README's headline claim
      was an argument (the kernel is integer-only) with zero non-x86_64
      measurements behind it. Now measured: `./crossarch`
      (`tests/cross_arch_diff`) compares the kernel sweep, the decimal I/O
      paths and `bin/random` itself across four platforms built from one
      pinned LuaJIT source — x86_64-glibc, x86_64-musl, aarch64-Linux (qemu),
      and **native aarch64-macOS on an M4 Max** — and all payloads are
      byte-identical. Two positive controls establish the comparison could
      have failed: libm splits three ways (libc axis), out-of-range
      double→int splits two ways along architecture (arch axis); neither
      alone covers both. qemu fidelity established rather than assumed (its
      float→int digest equals native Darwin's). All four controls
      mutation-verified. Full results, caveats and two corrected mistakes:
      `docs/cross-architecture-evidence.md` (2026-08-02 EDT)

## Next: Zig port (separate plan)
- [x] **Task 1: toolchain, scaffold, and the differential harness FIRST** — Zig
      0.16 in the flake (pinned to `zig_0_16`, LuaJIT pin untouched);
      `build.zig` with ReleaseFast artifacts / ReleaseSafe tests;
      `src/fixed.zig` with `norm` + `fromInt`; `tests/zig_differential`
      comparing it against `lib/fixed.lua` bit-exactly over 84,035 swept cases.
      Harness mutation-verified in both directions: a gross mutation (exponent
      compensation sign) and a narrow one (canonical zero keeping its incoming
      exponent, which differs in only a handful of cases) both fail it, and it
      passes on restore. Wired into `./test` (now 7 suites) and the hermetic
      Nix check. `ZIG_0.15_TO_0.16_MIGRATION.md` symlinked at the root — it is
      more current than `ZIG_RECENT_API_CHANGES.md`, which is stale on the
      0.16 I/O rework (2026-08-02 EDT)
- [ ] `src/fixed.zig` mirroring `lib/fixed.lua`, verified against the same `bc` sweep
- [ ] Zig core (pure, no I/O) + `include/randomz.h` C FFI
- [ ] `randomz` C CLI + `drandomz`/`nrandomz` symlinks, argv[0] dispatch
- [ ] Differential harness: `randomz` vs `bin/random` over a seed x flag matrix
- [ ] Cross-target digest control: x86_64 / aarch64 / musl must agree — EXTEND
      `tests/cross_arch_diff` rather than writing a second one; it already has
      the legs, the sensitivity controls and the native-hardware path. Add
      `randomz` as a payload alongside `bin/random`. Note the mutation finding:
      a CLI-level differential alone is too coarse to catch a 1-ulp kernel
      perturbation, so the Zig port needs a kernel-level digest payload too.
- [ ] `./bm` benchmark suite covering **both** implementations — LuaJIT and Zig —
      so the port's speedup is measured rather than assumed, and so a regression
      in either is visible. Per the fleet convention: ndjson log per machine-id,
      committed, two-sided tolerance (a surprise speedup may mean lost work),
      CPU time for single-threaded kernels, ReleaseFast only. Note the existing
      measured figure to beat: the `#1499` mitigation costs ~5.7x on the float
      distributions on pre-fix LuaJIT and nothing on fixed builds, so the
      benchmark must record which LuaJIT it ran under.
- [ ] Mechatron Prime CI via the `mechatron-ci` skill

## Approved directives (Peter, 2026-08-04)

**Standing permission:** `random`'s public behavior may be changed at will —
Peter is currently its only user. Preserve the existing API surface; replace
internals with superior ones. Behavior changes no longer need per-change
sign-off (this supersedes the "awaits Peter's approval" boundary Einstein
recorded on 2026-08-04).

- [ ] **Entropy: fail closed, via `getrandom(2)`/`getentropy()`.** Delete the
      time-derived stage-3 fallback in `get_random_bytes`
      (`bin/random:312-317`) entirely — it emits an arithmetic progression
      mod 256 (measured: constant step ≈58, two same-second draws differ by a
      constant), ~10-15 bits of real entropy. Reach the syscalls by FFI;
      devices become the fail-closed fallback with a read-retry loop (a
      partial read must re-read the same source, never demote to a weaker
      one). Blocking-until-seeded is the DEFAULT and is free — it is
      `getrandom`'s behavior absent `GRND_NONBLOCK`. Add a flag for callers
      who prefer a loud error to a wait (Peter's explicit request); a
      `--random-source=PATH` option à la `shuf` also makes the failure path
      naturally testable without the code knowing it is under test.
- [ ] **Make `drandom` itself a CSPRNG.** Not a `--secure` opt-in: the
      deterministic path becomes a BLAKE3 keyed DRBG outright. Seed 32 bytes
      from `getrandom` when none is given; a user `--seed` is expanded
      through BLAKE3's KDF rather than used raw. Counter mode or seekable XOF
      — both give O(1) random access to draw N, which is what makes replaying
      one fuzz-corpus entry cheap.
      CONSEQUENCE TO PLAN FOR: seeded streams change completely, so every
      deterministic golden vector must be re-blessed in the same commit. Do
      this AFTER the kernel port lands, so goldens move exactly once and both
      implementations change together.
      SPEED NOTE (measured, not assumed): BLAKE3 in LuaJIT yields ~1.8M u64
      draws/s vs PCG32's far higher rate — acceptable, because the LuaJIT
      side is the ORACLE; Zig's SIMD BLAKE3 is the production path. If a
      fast-but-predictable generator is ever wanted back, it returns as an
      explicit opt-in, never the default.
- [ ] **New functionality lands in LuaJIT first**, then ports to Zig using
      LuaJIT as the differential oracle — the established pattern. (The
      kernel-port tasks are the reverse direction: existing LuaJIT functions
      being ported to Zig.)

## Future goals (recorded 2026-08-03, Peter)
- [ ] **Cryptographically-secure mode** (deferred by Peter's call; priority for
      now is fast, identical cross-platform seeded output with optional
      nonlinear distributions). Design sketch when picked up: a seeded DRBG —
      keyed stream cipher (ChaCha20, as in libsodium's deterministic
      randombytes, or NIST CTR-DRBG) behind the same generator interface, so
      reproducibility is preserved (a keyed PRF is deterministic per key).
      PCG32 stays the fast default and must be documented as PREDICTABLE
      (state recoverable from a few outputs); a `--secure` flag swaps the
      generator. Distributions layer unchanged on top of either.
      PRIMITIVE SETTLED (2026-08-04): BLAKE3 from Egor Skriptunoff's
      MIT-licensed pure_lua_SHA on the LuaJIT side, std.crypto.hash.Blake3
      on the Zig side -- both verified bit-exact against the official
      test-vector methodology (246/246, all three modes, seekable XOF).
      See docs/research/2026-08-04-pure-lua-blake3-evaluation.md.

## Inbox-driven (additive, after current Zig-port task)
- [ ] **Einstein 2026-08-04: assess `random` as entropy source for
      `randompassdict`** (inbox/2026-08-04-from-einstein-randompassdict-csprng.md,
      stays in inbox/ until answered). Review-only, no dotfiles changes. Five
      questions: OS-CSPRNG API surface, rejection-vs-modulo bounded sampling
      (cite code+tests), smallest stable call for uniform [0, dict_size),
      security delta vs GNU `shuf --random-source=/dev/random`, and
      platform/fork/partial-read caveats for secret generation. Reply via
      LLMsend with evidence and known-green SHA. NOTE: current PCG32 seeded
      mode is NOT cryptographically secure (recorded under Future goals);
      only the true-random path is candidate material here.

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
