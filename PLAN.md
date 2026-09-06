# PLAN

## Completed: BLAKE3 DRBG before the Zig FFI

- [x] Replace the legacy deterministic generator in `bin/random` with the
      LuaJIT-specific BLAKE3 keyed XOF;
      retain Egor Skriptunoff's MIT notice and document the verified
      `pure_lua_SHA` ancestry plus the pending-license-clarification caveat.
- [x] Accept only unsigned decimal and `0x`-prefixed hexadecimal seeds, each
      no wider than 256 bits; canonicalize both forms to the same 32-byte
      big-endian seed material and reject every other spelling.
- [x] Derive every deterministic key through the versioned BLAKE3 KDF. For an
      omitted seed, obtain 32 bytes from the OS, emit the corresponding
      replayable `0x` seed in JSON continuation metadata, and fail closed if
      entropy is unavailable.
- [x] Remove the legacy generator, `now_seed`, legacy state parsing, implicit state files,
      `DRANDOM_CONTEXT`, and `DRANDOM_STATE_HOME`. A CLI invocation performs no
      persistent writes; reproducibility comes from an explicit seed or
      explicit portable continuation state.
- [x] Replace the true-random entropy path with OS CSPRNG APIs plus an exact-read
      `/dev/urandom` fallback; add `--random-source=PATH` for explicit/testable
      input and a no-wait option where the OS API supports it.
- [x] Gate the Lua implementation directly against the upstream BLAKE3
      `test_vectors.json`; retain extra boundary and seek checks as separate
      Lua-vs-Zig independent reference controls, while retaining LuaJIT as the
      behavioral oracle for the later Zig port.
- [x] Pin big-endian draw assembly, exact byte-consumption rules, seek limits,
      range rejection, and raw/default versus ranged `--binaryoutput`
      semantics before re-blessing deterministic golden vectors.
- [x] Extend `./crossarch`, update CLI/README/spec documentation, mutation-test
      every new control, run the complete suite, and commit only green units.

## Next

- [ ] Fix and independently gate LuaJIT binary streaming for large requests.
      Rarz's exact probe was `timeout 5 random -b -c 2362232012 --seed 0x700A`.
      The original transcript reports exit 124 with zero bytes, correcting
      the earlier unsupported claim of a successful empty result. LuaJIT
      assembles the whole binary request before writing; the observation
      alone does not establish a `2^31` parsing bug. Gate bounded-memory
      streaming and count/encoding/continuation parity without multi-GiB
      fixtures or timing thresholds in correctness tests.
- [ ] If pursuing further SIMD work, prototype lane-parallel fixed-point
      logarithm/trig evaluation with exact rounding and byte-consumption
      controls. The current profile makes this a more relevant experiment
      than vectorizing BLAKE3 alone. No custom SIMD speedup is claimed.

## Done
- [x] Optimize Zig/Rust normalized output without changing output quality:
      exact u128 division, bounded 1-KiB deterministic draw caches, an additive
      Zig C ABI, and measured Rust inlining. Fresh 1-MiB pre/post benchmarks
      improved Zig 2.421 → 0.719 s (3.37×), Rust 2.882 → 0.877 s (3.29×).
      Zig's original 100-MiB workload completed in 70.684 s with an independent
      exact byte-count check. Uniform bulk performance stayed close to its
      baseline. Four-way ./bm covered all 11 workloads; a fresh-context review
      found no blocking defect and its header-coverage recommendation was
      incorporated. Fix cumulative Hyperfine pipe-export history duplication
      and reject malformed measurement sets. Evidence and residual limitations:
      `docs/normalized-throughput-2026-09-06.md`, with versioned benchmark logs.
      Release build, all 25 default suites, cross-architecture comparisons,
      and expanded C-header/export controls pass locally. (2026-09-06 EDT)
- [x] Publish and gate CLI-free `random-luajit-lib`, `random-zig-lib`,
      `random-rust-lib`, and `random-lean-lib` flake packages; prove native
      downstream imports, direct LuaJIT loading of the shared C ABI without a
      separately compiled test harness, Cargo graph compatibility with
      validate_gui's libc/zeroize pins, and Rust 1.97.1. (2026-08-27 EDT)
- [x] Split Nix distribution outputs by implementation: publish
      `random-luajit`, `random-zig`, `random-rust`, and `random-lean`, retain
      `random-all` as the explicit aggregate and the backwards-compatible
      default, smoke-test each package independently, and prove the LuaJIT-only
      direct build inputs and runtime closure contain no Zig, Rust/Cargo, or
      Lean toolchain.
- [x] Reduce the installed Nix closure from 2.4 GiB to 127.8 MiB without
      weakening `--test`: separate the small runtime self-test PATH from the
      full CI toolchain, neutralize inert Zig store references embedded in the
      shipped WASM, use private package-smoke HOME/XDG directories, and expose
      only the supported x86_64-Linux, aarch64-Linux, and aarch64-macOS native
      flake systems. (2026-08-26 EDT)
- [x] Ship state schema 2 across LuaJIT, Zig/C, Rust, and the Lean frontend:
      shorten semantic state keys to `op`/`delim`, add `--state-stdout` as a
      final-line transport without duplicating values, and reject schema 1.
      The shared four-way continuation matrix covers every producer/consumer
      direction. (2026-08-26 EDT)
- [x] Permit `--delimiter ''` for byte-wise `--choose` and `--shuffle`,
      preserving whitespace, NUL, and invalid UTF-8 while rejecting the
      unrepresentable weighted form. (2026-08-26 EDT)
- [x] Ship portable JSON continuation state across LuaJIT, Zig/C, and Rust:
      payload remains on stdout, structured state/notices/warnings/errors use
      stderr, `--state`/`--resume` accept inline JSON or stdin, explicit CLI
      arguments override inherited semantic arguments, and every directed
      producer/consumer pair resumes at the exact BLAKE3 byte cursor. The
      shared in-memory Bash gate covers fixed- and variable-consumption modes,
      state validation, override precedence, and post-resume state equality.
      (2026-08-13 EDT)
- [x] Accept `dN` as an exact `1..N` range alias across the LuaJIT, Zig/C,
      and Rust CLIs for convenient N-sided die rolls. (2026-08-12 EDT)
- [x] Replace ambiguous one/two bare range endpoints with one atomic range:
      `M-N`/`M..N` are inclusive and Ruby-style `M...N` excludes N. Reject
      ranges on distribution paths that do not consume them. (2026-08-05 EDT)
- [x] Fold Beta's second shape parameter into `--beta[=B]`: bare `--beta`
      keeps beta=2, while `--beta B`/`--beta=B` overrides it; remove the
      redundant `--beta-param` surface. (2026-08-05 EDT)
- [x] Distribution-qualified help (`--normalized --help`, etc.) renders
      deterministic embedded plots through Kitty graphics in Kitty/Ghostty and
      Sixel in WezTerm; tmux auto mode uses scrollback-stable UTF-8, with
      `RANDOMZ_CHART_TYPE`/CLI overrides, byte-identical Braille fallback, and
      matching Lua/C output (2026-08-05 EDT)
- [x] Fix the legacy range sampler's infinite loop for ranges > 2^32 (2026-08-01 EST)
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
- [x] README: determinism guarantee, exact then-current generator spec,
      measured libm divergence, LuaJIT #1499
      note, compatibility note (2026-08-01 EST)
- [x] `cos_turns` negative-`u` branch: documented as intentional
      out-of-domain defense, not dead code (2026-08-01 EST)
- [x] `M.parse` dedicated unit pin: sign applies to the full integer+fraction
      magnitude, not just the integer part (2026-08-01 EST)
- [x] Spec status line: steps 1-5 implemented, including the Zig/C port
      (2026-08-01 EST)
- [x] Codex hostile-review fixes, all 8 findings: legacy range-sampler power-of-two
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
      legacy generator code was also rewritten (`xor64`/`u32()`, portability-motivated:
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
      Nix check. The former migration note has been consolidated into the
      root `ZIG_RECENT_API_CHANGES.md` guide (2026-08-04 EDT).
- [x] `src/fixed.zig` mirroring `lib/fixed.lua`, verified against the Lua oracle and same `bc` sweep
- [x] Zig core (pure, no I/O) + `include/randomz.h` C FFI
- [x] `randomz` C CLI + `drandomz`/`nrandomz` symlinks, argv[0] dispatch
- [x] Differential harness: `randomz` vs `bin/random` over a seed x flag x stdin matrix
- [x] Cross-target digest control: x86_64 / aarch64 / musl agree — EXTEND
      `tests/cross_arch_diff` rather than writing a second one; it already has
      the legs, the sensitivity controls and the native-hardware path.
      `randomz` is now a payload alongside `bin/random`, including a raw Zig
      kernel payload before CLI quantization. Note the mutation finding:
      a CLI-level differential alone is too coarse to catch a 1-ulp kernel
      perturbation, so the Zig port needs a kernel-level digest payload too.
- [x] `./bm` benchmark suite covering all four command families — LuaJIT,
      Zig/C, Rust, and Lean — over raw/encoded output, narrow/wide uniform ranges,
      and every current nonlinear distribution. It proves seeded output parity
      before timing release builds, appends CPU/wall results to a
      per-machine NDJSON history, records toolchain and exact-binary identities,
      and flags two-sided ±15% changes (a surprise speedup may mean lost work).
      `--quick` shortens measurement; `--check` runs parity only. The recorded
      LuaJIT version keeps the `#1499` mitigation cost attributable.
- [x] Mechatron Prime CI targets for the correctness, statistical,
      installed-package, ReleaseFast cross-architecture, and Windows x86_64
      runtime gates
- [x] Select explicit OS entropy backends by numeric truth value: Linux uses
      `getrandom`, Apple/FreeBSD/OpenBSD/NetBSD use `arc4random_buf`, and
      Windows uses `BCryptGenRandom`. Cross-compile the C/FFI CLI for both
      x86_64 and aarch64 on the three BSD targets and Windows, with pre-link
      symbol-provenance controls and a defined-as-zero regression for the
      presence-vs-truth bug class. (2026-08-06 EDT)
- [x] Ship `randomz-wasi.wasm` as a WASI Preview 1 reactor. Its deterministic
      ABI is checked byte-for-byte against LuaJIT and its true-random adapter
      uses host `random_get`; an injected host failure must return an entropy
      error. (2026-08-06 EDT)
- [ ] Produce and execute native Solaris/illumos and DragonFly artifacts. Their
      source selectors are implemented (`getrandom` for Solaris/illumos,
      `arc4random_buf` for DragonFly) and preprocessing controls pin them, but
      Zig 0.16 currently provides neither a usable illumos/DragonFly libc
      cross-sysroot nor a successful full illumos build. Do not claim runtime
      support until native or cross execution proves it.

## Completed: Rust library and CLI

- [x] Implement the accepted `randomr` design in
      `docs/specs/2026-08-11-randomr-design.md`, beginning with persisted red
      architecture and behavioral controls. (2026-08-11 EDT)
- [x] Ship an importable `randomr` library with deterministic fixed arithmetic,
      BLAKE3 DRBG, distributions, and curve generation isolated from all I/O;
      keep the explicitly injected OS/path entropy adapter as the only impure
      library module. (2026-08-11 EDT)
- [x] Ship the separate `randomr` CLI crate with `nrandomr`/`drandomr` aliases,
      `DRANDOMR_SEED`, the complete existing CLI/chart surface, and no direct
      access to oracle implementations or the C ABI. (2026-08-11 EDT)
- [x] Parameterize one shared CLI and exact-differential harness across LuaJIT,
      Zig/C, and Rust. Require pairwise oracle agreement before accepting Rust,
      then run the statistical, package, cross-target, and non-x86_64 runtime
      gates. Rust 1.97.1 publishes BSD target libraries only for FreeBSD x86_64
      and NetBSD x86_64; OpenBSD and BSD ARM64 remain named library gaps.
      (2026-08-11 EDT)
- [x] Compile-gate the pure `randomr` core without default features for
      `wasm32-wasip1`, without pretending that a library-only check is an
      equivalent shippable WASI reactor. (2026-08-11 EDT)
- [ ] After native Rust parity, produce equivalent Zig and Rust WASI artifacts
      and benchmark raw/compressed size, instantiation, DRBG throughput, and
      nonlinear-distribution throughput under one runtime. Use the measurements
      to decide whether one or both WASM implementations ship.

## Completed: independent Lean 4 implementation and formalization

- [x] Create the reusable `lean4-development` skill, pin the project to Lean
      4.30.0, and require trust-zero elaboration, explicit axiom audits, frozen
      external vectors, and an honest proved/tested/assumed claim matrix.
- [x] Implement an independent pure Lean BLAKE3 derive-key/keyed-XOF DRBG and
      uniform range model. Match the frozen seed-42 64-byte stream exactly.
- [x] Prove cursor advancement, key preservation, bounded seek/fill, an abstract
      compositional stream-slicing model, range result bounds, and population
      preservation for arbitrary swap schedules without `sorry`, `admit`,
      project axioms, or `unsafe` declarations in the trusted source.
- [x] Ship `randoml`/`nrandoml`/`drandoml`, `DRANDOML_SEED`, a dedicated Lean-only
      Nix package, shared CLI/statistics/benchmark integration, and a 736-check
      all-directions continuation matrix. The executable owns its parser,
      integer-only arithmetic, distributions, formatting, stdin operations,
      and canonical charts and does not delegate to another implementation.
      The final conclusions, measurements, and hard decisions are in
      `docs/reports/2026-08-26-lean4-evaluation.md`.
- [x] Replace the compatibility delegation with the complete independent Lean
      implementation and a thin native C adapter limited to raw argv, OS entropy,
      platform labels, and terminal-transport Base64. Re-run the shared CLI,
      141-case exact differential, state, statistics, proof, package, and
      benchmark-parity gates.
- [ ] Formally connect actual `Blake3.xofAt`/`Drbg.fill` byte content to the
      abstract stream-chunking theorem; current 63/64-byte and 65,535–65,538-byte
      chunk boundaries are controlled by exact external differentials.
- [ ] Remove the remaining deterministic/entropy sampler duplication by
      expressing the distribution program over a pure byte-source effect and
      interpreting it with either DRBG state or the native entropy reader.
- [ ] Add native Lean runtime/digest legs for aarch64 Linux/macOS and decide the
      supported Windows Lean toolchain; the C entropy edge is already
      cross-compiled/provenance-gated for Linux, macOS, BSD, and Windows.

## Approved directives (Peter, 2026-08-04)

**Standing permission:** `random`'s public behavior may be changed at will —
Peter is currently its only user. Preserve the existing API surface; replace
internals with superior ones. Behavior changes no longer need per-change
sign-off (this supersedes the "awaits Peter's approval" boundary Einstein
recorded on 2026-08-04).

- [x] **Entropy: fail closed, via `getrandom(2)`/`getentropy()`.** Implemented
      with partial/EINTR retry, `BCryptGenRandom` on Windows, exact-read
      `/dev/urandom` fallback, `--no-wait`, and `--random-source=PATH`.
- [x] **Make `drandom` itself a CSPRNG — NOW, BEFORE the FFI/CLI port
      (resequenced 2026-08-04 by Peter).** Replace the legacy generator first,
      then port the final result: the Zig core implements BLAKE3 directly.
      Not a `--secure` opt-in: the
      deterministic path becomes a BLAKE3 keyed DRBG outright. Seed 32 bytes
      from `getrandom` when none is given (couples to the entropy fix below); a
      user `--seed` is expanded through BLAKE3's KDF rather than used raw.
      Counter mode or seekable XOF — both give O(1) random access to a known
      byte position. Finding distribution item N from the root seed remains
      O(N) when rejection or another variable-consumption sampler is involved;
      serialized continuation state makes resumption at its recorded cursor
      O(1).
      CONSEQUENCE: seeded streams change completely, so every deterministic
      golden vector must be re-blessed in the SAME commit. (This is why it was
      originally scheduled last; moving it first means the FFI/CLI port and the
      CLI-level differential are built against the FINAL generator, not a
      throwaway one — the goldens still move exactly once.)
      Implemented contract: versioned KDF, keyed empty-message XOF, big-endian
      32/64-bit draws, strict 256-bit integer seeds, no implicit state files,
      explicit portable continuation state, and direct full-range binary
      bytes. See the implemented design spec.
- [x] **New functionality lands in LuaJIT first**, then ports independently to
      Zig/C and Rust using LuaJIT as the original behavioral oracle and both
      later implementations as mutual differential controls — the established
      three-frontend pattern.

## Superseded future goal (recorded 2026-08-03, completed 2026-08-04)
- [x] **Cryptographically secure deterministic generator.** Peter superseded
      the deferred `--secure` opt-in: BLAKE3 is now the only deterministic
      generator, the legacy implementation is removed, and distributions layer
      over BLAKE3 unchanged.
      The faster LuaJIT-specific Egor Skriptunoff implementation is vendored
      with the documented provenance/licensing caveat; Zig will use
      `std.crypto.hash.Blake3`.

## Post-shipment distribution enhancements

- [x] Add `--view` as a chart-only action for exactly one selected
      distribution. Distribution-qualified `--help` keeps showing the frozen
      default shape; `--view` renders the parameters actually supplied (for
      example `--beta 3 --alpha 1 --view`) through the same
      UTF-8/Kitty/Sixel selector.
- [x] Complete the customization vocabulary before `--view`: add `--rate` for
      exponential and `--lambda` as a clearer Poisson alias while retaining
      `--mean`; normal/log-normal continue to use `--mean` + `--stddev`, and
      beta uses `--alpha` plus bare/default or parameterized `--beta[=B]`.
- [x] Implement parameter-aware curve generation LuaJIT-first using the fixed
      numeric kernel, then expose a protocol-neutral curve-sampling API from
      the Zig core through the C ABI. Keep PNG/Sixel/Braille rasterization in
      the CLIs so distribution math enters the reusable core without terminal
      protocols or a Lua/ImageMagick runtime dependency entering `randomz`.
      Runtime Kitty uses in-memory raw RGB, Sixel is encoded directly, and
      Braille is rasterized directly; no temporary file or external image
      runtime is needed. Lone normal `--mean`/`--stddev` now uses the missing
      parameter's 0/1 default instead of silently ignoring the supplied one.
- [ ] Expose `--gamma`, reusing the Marsaglia-Tsang sampler already required by beta.
- [ ] Add `--weibull` for lifetime and latency models.
- [ ] Add `--pareto` and discrete `--zipf` for heavy-tailed values/frequencies.
- [ ] Add discrete `--geometric` and `--binomial` count distributions.
- [ ] Add outlier-heavy `--cauchy` and `--student-t` distributions.
- [ ] Add fuzzing-oriented `--edge-biased` integers concentrated on zero, ±1,
      both bounds, powers of two, and powers-of-two ±1.
- [ ] Add fuzzing-oriented `--log-uniform` sizes spanning orders of magnitude.
- [ ] Implement each mode LuaJIT-first, freeze its byte-consumption contract,
      port it through the Zig/C ABI and Rust core, run the shared CLI suite,
      `./stats`, and `./bm` against all three implementations, and add
      CLI-level differential vectors.

## Post-shipment chart architecture

- [ ] Permute the Lean experiment's explicit chart pipeline into LuaJIT, Zig,
      and Rust: semantic `Chart.Spec` -> normalized canonical `Chart.Model` ->
      indexed raster/dot-grid surfaces -> independent Kitty/Sixel/Braille
      codecs. Keep terminal detection and byte writes at the I/O edge.
- [ ] Add cross-implementation fixtures at each boundary so a discrepancy is
      localized to spec-to-model, model-to-surface, or surface-to-encoding,
      including compiled-native ESC framing controls for Kitty and Sixel.

## Post-shipment physical entropy

- [ ] Add interactive `--dice MdN` entropy supplementation using the contract
      in `docs/specs/2026-08-06-dice-entropy-design.md`. Default mode combines
      32 OS-CSPRNG bytes and the canonically framed roll sequence through a
      domain-separated BLAKE3 derivation, prints the resulting replay seed,
      and fails if the OS source fails rather than silently downgrading.
- [ ] Support ordered sequential entry (or a color/position order chosen
      before rolling) as the recommended mode. Offer explicit unordered entry
      only by sorting and reporting its lower conservative min-entropy; never
      credit it with the ordered `M*log2(N)` estimate.
- [ ] Keep secret roll transcripts out of argv, shell history, and process
      listings: prompt through the controlling terminal, with an explicit
      file source for automation/tests. Require exact count/range validation,
      predeclared cocked/off-table reroll rules, and no selective rerolls.
- [ ] Make dice-only operation a conspicuous explicit mode, require at least
      256 bits of conservative nominal min-entropy, and distinguish its framed
      input from OS-plus-dice mode. Hashing and the DRBG KDF must never be
      described as creating entropy.

## Inbox-driven (additive, after current Zig-port task)

- [ ] **Einstein 2026-08-04: assess `random` as entropy source for
      `randompassdict`** (inbox/2026-08-04-from-einstein-randompassdict-csprng.md,
      stays in inbox/ until answered). Review-only, no dotfiles changes. Five
      questions: OS-CSPRNG API surface, rejection-vs-modulo bounded sampling
      (cite code+tests), smallest stable call for uniform [0, dict_size),
      security delta vs GNU `shuf --random-source=/dev/random`, and
      platform/fork/partial-read caveats for secret generation. Reply via
      LLMsend with evidence and known-green SHA. The true-random path is the
      natural password-generation source; seeded mode is unpredictable only
      when its seed is both high-entropy and secret.

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
  modulo 256 past 255 failing suites. With 9 suites today and a required-suite
  manifest that fails loudly if any goes missing or non-executable, this is
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
  CLI range components at all -- not a weakening of the range-rejection
  fix now carried by `drbg_range`, which uses unconditional u64 arithmetic with no reference to
  that ceiling. Recovering full coverage to 2^62 would need a Lua-level
  test entry point into `drbg_range` (currently a local, unexported
  function in `bin/random`); not worth the refactor for a range no CLI
  invocation can produce.
