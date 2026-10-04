# PLAN

Completed work: [log](docs/PLAN_LOG.md). Historical directives and deferred risks: [context](docs/plan_context/legacy_decisions.md).

## Now: upstream Roc and standalone packages

- [ ] Pin and verify the upstream Roc toolchain, then implement an independent pure core with an I/O-only CLI adapter (context: docs/plan_context/legacy_decisions.md).
- [ ] Extend the shared CLI/library oracles and cross-implementation continuation tests to Roc, including geometric.
- [ ] Export separate Roc CLI and importable library Nix packages; verify standalone consumers and CLI-free library closures for every language.

## Correctness and verification

- [ ] Fix tiny-negative scalar cosine wrapping to quadrant four with coordinated language tests; preserve existing sampler streams outside that bug (context: docs/plan_context/legacy_decisions.md).
- [ ] Enforce the ±2^53 contract in legacy scalar normalized-integer APIs before source mutation, preventing rejection loops near i64 extrema.
- [ ] Complete MAX-mantissa/general-multiplication Kani proofs and minimize non-reproducing SMT diagnostics (context: docs/reports/2026-09-30-kani-contracts.md).
- [ ] Connect actual Lean `Blake3.xofAt`/`Drbg.fill` byte content to the abstract chunking theorem, beyond existing boundary differentials.
- [ ] Unify remaining Lean deterministic/entropy samplers through a pure byte-source effect and separate interpreters; geometric already uses this boundary.

## Platform coverage

- [ ] Produce and execute Solaris/illumos and DragonFly artifacts before claiming runtime support; source selectors alone are not execution evidence.
- [ ] Add native Lean aarch64 Linux/macOS runtime/digest legs and determine a supported Windows Lean toolchain.
- [ ] Build comparable Zig/Rust WASI artifacts and measure size, startup, DRBG, and nonlinear throughput under one runtime before choosing shipped variants.

## Post-shipment distribution enhancements

- [ ] Expose `--gamma`, reusing the Marsaglia-Tsang sampler already required by beta.
- [ ] Add `--weibull` for lifetime and latency models.
- [ ] Add `--pareto` and discrete `--zipf` for heavy-tailed values/frequencies.
- [ ] Add discrete `--binomial` count distributions after geometric ships.
- [ ] Add outlier-heavy `--cauchy` and `--student-t` distributions.
- [ ] Add fuzzing-oriented `--edge-biased` integers concentrated on zero, ±1, both bounds, powers of two, and powers-of-two ±1.
- [ ] Add fuzzing-oriented `--log-uniform` sizes spanning orders of magnitude.
- [ ] Require LuaJIT-first contracts, frozen byte consumption, library/FFI and shared CLI differentials, `./stats`, and `./bm` coverage for each new distribution in every implementation.

## Post-shipment chart architecture

- [ ] Port Lean's canonical chart pipeline to other cores, keeping terminal detection/writes at the edge and codecs separately testable (context: docs/plan_context/legacy_decisions.md).
- [ ] Pin cross-language chart spec/model/surface/codec fixtures, including native Kitty/Sixel ESC framing controls.

## Post-shipment physical entropy

- [ ] Add interactive `--dice MdN` entropy supplementation using the contract in `docs/specs/2026-08-06-dice-entropy-design.md`. Default mode combines 32 OS-CSPRNG bytes and the canonically framed roll sequence through a domain-separated BLAKE3 derivation, prints the resulting replay seed, and fails if the OS source fails rather than silently downgrading.
- [ ] Support ordered sequential entry (or a color/position order chosen before rolling) as the recommended mode. Offer explicit unordered entry only by sorting and reporting its lower conservative min-entropy; never credit it with the ordered `M*log2(N)` estimate.
- [ ] Keep secret roll transcripts out of argv, shell history, and process listings: prompt through the controlling terminal, with an explicit file source for automation/tests. Require exact count/range validation, predeclared cocked/off-table reroll rules, and no selective rerolls.
- [ ] Make dice-only operation a conspicuous explicit mode, require at least 256 bits of conservative nominal min-entropy, and distinguish its framed input from OS-plus-dice mode. Hashing and the DRBG KDF must never be described as creating entropy.

## Integration and maintenance

- [ ] Locate or deliver the outstanding password-generator entropy assessment with source/range/security/fork/partial-read evidence and a known-green commit; no dotfiles changes.
- [ ] Remove `luajitFixed` only when locked nixpkgs LuaJIT includes the verified #1499 fix (roll ≥1785606157); enforce toolchain/mitigation threshold alignment.
- [ ] Consider optional I/O-edge output pacing without changing sampled values or claiming improved entropy/statistical quality.
