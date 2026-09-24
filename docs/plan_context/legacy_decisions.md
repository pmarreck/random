# Preserved planning context

Moved from PLAN.md on 2026-09-24 without re-authorizing or resolving these historical items.

## Approved directives (Peter, 2026-08-04)

**Standing permission:** `random`'s public behavior may be changed at will —
Peter is currently its only user. Preserve the existing API surface; replace
internals with superior ones. Behavior changes no longer need per-change
sign-off (this supersedes the "awaits Peter's approval" boundary Einstein
recorded on 2026-08-04).

## Deferred (recorded, deliberately not fixed)
- `LUAJIT_1499_FIXED_IN` in `lib/fixed.lua` (currently `1785606157`) is a magic constant with no AUTOMATED link to `flake.nix`'s pinned LuaJIT toolchain -- MANUALLY verified aligned as of 2026-08-02 (`flake.nix`'s `luajitFixed` override pins exactly the commit whose roll number is this constant; see `docs/luajit-1499-pin-investigation.md`), but nothing enforces that alignment going forward. A manual bump of either side (the constant, or the nixpkgs LuaJIT pin once the override above is dropped) could drift silently — e.g. pinning a LuaJIT built after the real #1499 fix but forgetting to lower the constant just wastes the ~5.7x mitigation cost forever; getting it backwards (raising the constant past a build that still has the bug) would silently reintroduce the miscompilation. No test currently cross-checks the constant against the toolchain's actual `jit.version`; would need something like a check step that builds against `pkgs.luajit` and asserts `jit.version`'s roll number against the constant in both directions.
- `./test`'s exit code is the raw suite-failure count, unclamped — wraps modulo 256 past 255 failing suites. With 9 suites today and a required-suite manifest that fails loudly if any goes missing or non-executable, this is unreachable in practice; not worth guarding until the suite count grows by two orders of magnitude.
- `./test`'s `for suite in ... ; do [ -x "$suite" ] || continue; ...` glob loop would treat an executable directory as a suite (and then fail confusingly when `timeout` execs it). No directory named `*_test` (or `kernel_bc_sweep`/`kernel_jit_diff`) exists under `tests/` today; low risk, not fixed.
- `tests/random_test`'s power-of-two range classifier (Test 20d) sweeps 2^33..2^52, not the full 2^33..2^62 the original finding specified. `M.parse_int_safe`'s later 2^53 CLI ceiling (finding #3 in `docs/codex-fix-report.md`) makes spans above 2^53 unreachable through CLI range components at all -- not a weakening of the range-rejection fix now carried by `drbg_range`, which uses unconditional u64 arithmetic with no reference to that ceiling. Recovering full coverage to 2^62 would need a Lua-level test entry point into `drbg_range` (currently a local, unexported function in `bin/random`); not worth the refactor for a range no CLI invocation can produce.
