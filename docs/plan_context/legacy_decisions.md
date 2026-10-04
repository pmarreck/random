# Preserved planning context

Moved from PLAN.md on 2026-09-24 without re-authorizing or resolving these historical items.

## Upstream Roc toolchain, 2026-10-04

The `writing-roc` skill and both syntax/module references have been read. The candidate is official `roc-lang/roc` revision `1a4df199210309bbb6befb1322f7435361bd01e1`, using its `src/flake.nix`. This is not the project's LuaJIT-backend fork. The skill's executable checks used a locally available older compiler, not a built/tested artifact of this exact revision.

The candidate's locked Nix package uses Zig 0.16.0 and nixpkgs `64c08a7ca051951c8eae34e3e3cb1e202fe36786`. Four isolated builds failed when Zig compiled the final `roc` executable with SIGSEGV: ordinary Debug, increased process stack, ReleaseFast with increased stack, and an explicit Linux LLVM-backend packaging patch. Dependencies fetched successfully. These are compiler-build failures, not failures of a randomization port. The LLVM probe disproved the initial guess that switching off the self-hosted x86 backend would suffice.

A fifth isolated probe keeps the same official Roc revision and Zig version, but overrides nixpkgs with this project's already-pinned `9fbb54b33e91ee4ca368e35a78e0613c720600b3`; its result is still pending at this checkpoint. A durable coordination note requests a reproducibly working upstream revision or build workaround. Do not promote a fork executable or an unverified compiler package into the production dependency to conceal this failure. Upstream marks Darwin packaging broken; native build evidence is required before claiming Mac support.

The intended implementation remains independent: portable integer Fixed math, BLAKE3/DRBG, all distribution algorithms including arbitrary-width geometric counts, with platform-owned I/O only. Acceptance must reuse the existing Bash CLI bodies and expected results, then include all-direction continuation, library consumers, statistical checks, and benchmark digests. CLI and library outputs must remain separate, with no compiler or CLI runtime in the importable library closure. No Roc implementation or package has been accepted yet.

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

## Open-item audit, 2026-10-04

Five completed items were retired verbatim to `docs/PLAN_LOG.md`. The remaining
items are still open: existing source selectors, abstract proofs, and shared
oracles do not establish the deferred native execution or stronger proofs.
Geometric is now a current requirement; binomial remains a later enhancement.
The approved geometric convention counts failures before success, starting at
zero. The new language implementation targets upstream Roc, not a LuaJIT-codegen
fork, and must expose an independently consumable library as well as its CLI.

### Numeric risks

The scalar cosine's negative-turn defense can round a sufficiently tiny negative
input's wrap to exactly one turn. That selects quadrant four and returns zero.
This is outside the existing samplers' nonnegative input domain; SIMD experiments
deliberately preserve the current oracle behavior. Fixing the public numeric
function requires coordinated tests without silently changing sampler streams.

Legacy normalized-integer scalar APIs accept some narrow ranges near i64 extrema
that can reject indefinitely. Production batch APIs already reject bounds outside
the ±2^53 contract before source/output mutation. The scalar surface still needs
the same validation.

### Platform and proof limits

Solaris/illumos selects `getrandom`; DragonFly selects `arc4random_buf`.
Preprocessing controls pin these source choices, but Zig 0.16 lacks a usable
cross-sysroot for the existing full builds. Native or cross runtime evidence is
still required. Lean's C entropy edge is cross-compiled/provenance-gated for
Linux, macOS, BSD, and Windows; this does not establish native Lean runtime support
on those systems.

Lean chunking tests compare actual bytes around 63/64-byte and
65,535–65,538-byte boundaries. Its abstract chunking theorem has not yet been
connected formally to the byte content of `Blake3.xofAt` and `Drbg.fill`.

### Chart boundary contract

The intended shared pipeline is semantic `Chart.Spec` → normalized canonical
`Chart.Model` → indexed raster/dot-grid surfaces → independent Kitty/Sixel/Braille
codecs. Terminal detection and writes remain at the I/O edge. Fixtures should
identify which boundary disagrees, including compiled-native ESC framing tests.

### Outstanding entropy assessment

The old password-generator assessment has no matching note in the current inbox
and no located completion evidence, so it remains open rather than being marked
done. Its questions concern the OS-CSPRNG API, unbiased bounded rejection versus
modulo sampling, the smallest stable uniform `[0, dictionary_size)` call, security
differences from GNU `shuf --random-source=/dev/random`, and platform/fork/partial-
read caveats. Answer with code/test evidence and a known-green commit, without
changing dotfiles. True-random mode is the natural password-generation source;
seeded output is unpredictable only with a high-entropy secret seed.
