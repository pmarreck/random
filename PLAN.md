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
      measured figure to beat: the `#1499` mitigation costs ~5.5x on the float
      distributions on pre-fix LuaJIT and nothing on fixed builds, so the
      benchmark must record which LuaJIT it ran under.
- [ ] Mechatron Prime CI via the `mechatron-ci` skill

## Deferred (recorded, deliberately not fixed)
- `LUAJIT_1499_FIXED_IN` in `lib/fixed.lua` (currently `1785577137`) is a magic
  constant with no automated link to `flake.nix`'s pinned LuaJIT toolchain. A
  manual bump of either side (the constant, or the nixpkgs LuaJIT pin) could
  drift silently — e.g. pinning a LuaJIT built after the real #1499 fix but
  forgetting to lower the constant just wastes the ~5.7x mitigation cost
  forever; getting it backwards (raising the constant past a build that still
  has the bug) would silently reintroduce the miscompilation. No test
  currently cross-checks the constant against the toolchain's actual
  `jit.version`; would need something like a check step that builds against
  `pkgs.luajit` and asserts `jit.version`'s roll number against the constant
  in both directions.
- `./test`'s exit code is the raw suite-failure count, unclamped — wraps
  modulo 256 past 255 failing suites. With 5 suites total today this is
  unreachable in practice; not worth guarding until the suite count grows by
  two orders of magnitude.
- `./test`'s `for suite in ... ; do [ -x "$suite" ] || continue; ...` glob
  loop would treat an executable directory as a suite (and then fail
  confusingly when `timeout` execs it). No directory named `*_test` (or
  `kernel_bc_sweep`/`kernel_jit_diff`) exists under `tests/` today; low risk,
  not fixed.
