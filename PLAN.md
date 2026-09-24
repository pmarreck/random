# PLAN

Completed work: [log](docs/PLAN_LOG.md). Historical directives and deferred risks: [context](docs/plan_context/legacy_decisions.md).

## Current: bounded Rust verification experiment

- [x] Implement reviewed Nix-isolated Kani constructor POC; red/green proofs, five covers and all 27 FAST suites pass (done 2026-09-24 13:53 EDT; commit: containing commit; context: docs/reports/2026-09-24-kani-poc.md).

## Next

- [ ] Review the shared scalar cosine's negative-turn defense: sufficiently tiny negative inputs round their wrap to exactly one turn (quadrant 4), selecting sine and returning zero. This lies outside the sampler's nonnegative input domain. SIMD experiments preserve the oracle's current behavior; changing that behavior needs coordinated four-language tests.
- [ ] Align legacy scalar normalized-integer library domains with the ±2^53 exact-integer contract. Independent production-batch review found that some narrow ranges near i64 extrema can reject indefinitely. New batch APIs reject out-of-domain bounds before any source/output mutation; existing scalar APIs remain unchanged pending coordinated tests.

## Next: Zig port (separate plan)
- [ ] Produce and execute native Solaris/illumos and DragonFly artifacts. Their source selectors are implemented (`getrandom` for Solaris/illumos, `arc4random_buf` for DragonFly) and preprocessing controls pin them, but Zig 0.16 currently provides neither a usable illumos/DragonFly libc cross-sysroot nor a successful full illumos build. Do not claim runtime support until native or cross execution proves it.

## Completed: Rust library and CLI

- [ ] After native Rust parity, produce equivalent Zig and Rust WASI artifacts and benchmark raw/compressed size, instantiation, DRBG throughput, and nonlinear-distribution throughput under one runtime. Use the measurements to decide whether one or both WASM implementations ship.

## Completed: independent Lean 4 implementation and formalization

- [ ] Formally connect actual `Blake3.xofAt`/`Drbg.fill` byte content to the abstract stream-chunking theorem; current 63/64-byte and 65,535–65,538-byte chunk boundaries are controlled by exact external differentials.
- [ ] Remove the remaining deterministic/entropy sampler duplication by expressing the distribution program over a pure byte-source effect and interpreting it with either DRBG state or the native entropy reader.
- [ ] Add native Lean runtime/digest legs for aarch64 Linux/macOS and decide the supported Windows Lean toolchain; the C entropy edge is already cross-compiled/provenance-gated for Linux, macOS, BSD, and Windows.

## Post-shipment distribution enhancements

- [ ] Expose `--gamma`, reusing the Marsaglia-Tsang sampler already required by beta.
- [ ] Add `--weibull` for lifetime and latency models.
- [ ] Add `--pareto` and discrete `--zipf` for heavy-tailed values/frequencies.
- [ ] Add discrete `--geometric` and `--binomial` count distributions.
- [ ] Add outlier-heavy `--cauchy` and `--student-t` distributions.
- [ ] Add fuzzing-oriented `--edge-biased` integers concentrated on zero, ±1, both bounds, powers of two, and powers-of-two ±1.
- [ ] Add fuzzing-oriented `--log-uniform` sizes spanning orders of magnitude.
- [ ] Implement each mode LuaJIT-first, freeze its byte-consumption contract, port it through the Zig/C ABI and Rust core, run the shared CLI suite, `./stats`, and `./bm` against all three implementations, and add CLI-level differential vectors.

## Post-shipment chart architecture

- [ ] Permute the Lean experiment's explicit chart pipeline into LuaJIT, Zig, and Rust: semantic `Chart.Spec` -> normalized canonical `Chart.Model` -> indexed raster/dot-grid surfaces -> independent Kitty/Sixel/Braille codecs. Keep terminal detection and byte writes at the I/O edge.
- [ ] Add cross-implementation fixtures at each boundary so a discrepancy is localized to spec-to-model, model-to-surface, or surface-to-encoding, including compiled-native ESC framing controls for Kitty and Sixel.

## Post-shipment physical entropy

- [ ] Add interactive `--dice MdN` entropy supplementation using the contract in `docs/specs/2026-08-06-dice-entropy-design.md`. Default mode combines 32 OS-CSPRNG bytes and the canonically framed roll sequence through a domain-separated BLAKE3 derivation, prints the resulting replay seed, and fails if the OS source fails rather than silently downgrading.
- [ ] Support ordered sequential entry (or a color/position order chosen before rolling) as the recommended mode. Offer explicit unordered entry only by sorting and reporting its lower conservative min-entropy; never credit it with the ordered `M*log2(N)` estimate.
- [ ] Keep secret roll transcripts out of argv, shell history, and process listings: prompt through the controlling terminal, with an explicit file source for automation/tests. Require exact count/range validation, predeclared cocked/off-table reroll rules, and no selective rerolls.
- [ ] Make dice-only operation a conspicuous explicit mode, require at least 256 bits of conservative nominal min-entropy, and distinguish its framed input from OS-plus-dice mode. Hashing and the DRBG KDF must never be described as creating entropy.

## Inbox-driven (additive, after current Zig-port task)

- [ ] **Einstein 2026-08-04: assess `random` as entropy source for `randompassdict`** (inbox/2026-08-04-from-einstein-randompassdict-csprng.md, stays in inbox/ until answered). Review-only, no dotfiles changes. Five questions: OS-CSPRNG API surface, rejection-vs-modulo bounded sampling (cite code+tests), smallest stable call for uniform [0, dict_size), security delta vs GNU `shuf --random-source=/dev/random`, and platform/fork/partial-read caveats for secret generation. Reply via LLMsend with evidence and known-green SHA. The true-random path is the natural password-generation source; seeded mode is unpredictable only when its seed is both high-entropy and secret.

## TODO
- [ ] Drop `flake.nix`'s `luajitFixed` override (and its `28084004` pin) once nixpkgs-unstable's own `pkgs.luajit` picks up a commit at or past the real #1499 fix (roll number >= 1785606157, branch `v2.1`) — check via `nix eval nixpkgs#luajit.version`. Once dropped, revert `runtimeTools` back to `[ pkgs.luajit ]` directly.
