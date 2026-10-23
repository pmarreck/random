# PLAN

Completed work: [log](docs/PLAN_LOG.md). Historical directives and deferred risks: [context](docs/plan_context/legacy_decisions.md).

## Canonical cross-platform build architecture

- [x] Adopt the cross-platform-project-build-arch contract with a tracked CANONICAL_IMPL selecting zig, validated canonization and independent implementation/platform build scopes (commit db8bdac; done 2026-10-23 17:07 EDT).
- [x] Namespace complete products by implementation/PF/VARIANT/profile and atomically publish only the canonical command set in bin/PF, preserving working selections on failure and foreign builds (commit db8bdac; done 2026-10-23 17:07 EDT).
- [x] Make the default Nix output select the canonical Zig/C CLI while retaining separately consumable language-specific CLIs, libraries and an explicitly named aggregate (commit db8bdac; done 2026-10-23 17:07 EDT).
- [x] Add failing Bash conformance tests for selection, scopes, hostile inputs, ABI/profile isolation, publication rollback and concurrency; include them in ./test and verify a real canonical host build (commit db8bdac; done 2026-10-23 17:07 EDT).
- [x] Migrate build/run/test helpers, packaging and documentation together, retain recoverable legacy products and report unexecuted foreign-platform checks without changing global shell configuration (commit db8bdac; done 2026-10-23 17:07 EDT).
- [x] Make every CLI's one-line --about identify its actual PF and applicable ABI variant, ignoring conflicting runtime target variables for compiled outputs (commit db8bdac; done 2026-10-23 17:07 EDT).

## Correctness and verification

- [ ] Prove production-linked distribution laws and explicit parameter-dependent deviation/failure bounds for uniform, normal, normalized integers, exponential, Poisson, log-normal, beta and geometric; preserve shared CLI acceptance and distinguish ideal-source assumptions from cross-language refinement (context: docs/plan_context/distribution_proofs.md).
- [ ] Complete MAX-mantissa/general-multiplication Kani proofs and minimize non-reproducing SMT diagnostics (context: docs/reports/2026-09-30-kani-contracts.md).
- [ ] Connect actual Lean `Blake3.xofAt`/`Drbg.fill` byte content to the abstract chunking theorem, beyond existing boundary differentials.
- [ ] Unify remaining Lean deterministic/entropy samplers through a pure byte-source effect and separate interpreters; geometric already uses this boundary.

## Experimental Bend 2 backend

- [x] Pin Bend 2.0.37 and implement independent seeded BLAKE3 bytes, checked chunk/resume behavior and signed bounded integers against frozen oracles; 45 suites passed (commit bc736a2; done 2026-10-20 13:10 EDT; context: docs/plan_context/bend2_evaluation.md).
- [x] Check four executed Bend invariants with pinned-kernel verdicts and specification/implementation mutation controls (commit bc736a2 plus strengthened guards in this change; done 2026-10-20 14:00 EDT; context: docs/plan_context/bend2_evaluation.md).
- [x] Implement independent Bend fixed arithmetic and all current nonlinear samplers with exact intermediate/value/cursor controls (this change; done 2026-10-20 19:35 EDT; context: docs/plan_context/bend2_evaluation.md).
- [x] Export independent Bend source/coherent-JS SDK, static/shared C ABI and CLI as isolated Nix outputs with installed-consumer checks (this change; done 2026-10-20 19:35 EDT; context: docs/plan_context/bend2_evaluation.md).
- [ ] Measure caller-owned Bend deterministic read-ahead, prepared ranges/batches and exact wide-division/remainder improvements individually before considering promotion (context: docs/plan_context/bend2_evaluation.md).
- [ ] Strengthen executable-linked Bend stream/arithmetic/sampler refinement beyond the four initial invariants and address documented runtime/erasure/stress gaps (context: docs/reports/2026-10-20-bend2-full-evaluation.md).

## Event-addressed RNG investigation

- [ ] Propose canonical event-local substream semantics and fair quality/performance experiments from the reviewed event-addressing brief, and obtain an architecture decision before adding a backend (context: docs/plan_context/bend2_evaluation.md#event-addressed-rng-investigation).

## Platform coverage

- [ ] Execute native macOS/Windows publication and resource lookup, including Windows copy/DLL handling, and validate the layout on a case-insensitive filesystem before claiming those runtime gates.
- [ ] Execute native Bend C-ABI/CLI checks on aarch64 Linux/macOS before widening the Linux-x86_64-only runtime evidence.
- [ ] Execute the Roc CLI/C ABI on native aarch64 Linux and extend official-platform packaging beyond Linux before widening runtime support claims.
- [ ] Produce and execute Solaris/illumos and DragonFly artifacts before claiming runtime support; source selectors alone are not execution evidence.
- [ ] Add native Lean aarch64 Linux/macOS runtime/digest legs and determine a supported Windows Lean toolchain.
- [ ] Build comparable Zig/Rust WASI artifacts and measure size, startup, DRBG, and nonlinear throughput under one runtime before choosing shipped variants.

## Post-shipment distribution enhancements

- [ ] Expose `--gamma`, reusing the Marsaglia-Tsang sampler already required by beta.
- [ ] Add `--weibull` for lifetime and latency models.
- [ ] Add `--pareto` and discrete `--zipf` for heavy-tailed values/frequencies.
- [ ] Add discrete `--binomial` count distributions.
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

- [ ] Investigate the intermittent nonpositive-clock rejection in the short-run benchmark smoke probe, retaining invalid-clock refusals and frozen profiling baselines.
- [ ] Specify and add parameterized bounded-integer, sparse distinct, checked u64 geometric and weighted-index consumer APIs with Zig-native entrypoints and construction IDs (context: docs/plan_context/consumer_sampling.md).
- [ ] Locate or deliver the outstanding password-generator entropy assessment with source/range/security/fork/partial-read evidence and a known-green commit; no dotfiles changes.
- [ ] Remove `luajitFixed` only when locked nixpkgs LuaJIT includes the verified #1499 fix (roll ≥1785606157); enforce toolchain/mitigation threshold alignment.
- [ ] Consider optional I/O-edge output pacing without changing sampled values or claiming improved entropy/statistical quality.
