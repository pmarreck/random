# Deep code review — BLAKE3 DRBG milestone

**Date:** 2026-08-04
**Scope:** the repository after the LuaJIT BLAKE3/OS-entropy migration, with
particular attention to `bin/random`, `lib/blake3.lua`, and their controls.
**Result:** no critical findings remain. Five warnings and two advisories were
fixed during the review; two warnings and two advisories remain below.

## 1. Inconsistent, incomplete, or undefined functionality

- **Fixed — WARNING:** true-random wide ranges assembled 7–8 source bytes in a
  Lua number and silently lost low bits beyond 2^53. `bin/random:354-383` now
  performs exact big-endian `uint64_t` assembly and the same unbiased rejection
  arithmetic as deterministic mode. `tests/drbg_test:173-185` independently
  pins the result from known source bytes.
- **Fixed — WARNING:** endpoints could each be exact while their inclusive span
  was not. The CLI now rejects spans above 2^53 rather than sampling a rounded
  range, with an exact-maximum specificity check.
- **Fixed — WARNING:** aggregate weighted totals could exceed the exact range
  even when each input weight passed validation, and an all-zero table exited
  successfully without selecting anything. Both cases now fail explicitly.
- **Fixed — WARNING:** logarithmic distributions mapped an exact zero u32 to
  `1e-6` instead of the discrete generator's smallest positive value, 2^-32.
  The endpoint and its independently injected `/dev/zero` control now agree.

## 2. Inadequate test coverage

- **Remaining — WARNING:** Linux `getrandom` success is exercised by ordinary
  CLI tests, and explicit-source EOF is covered, but EINTR, ENOSYS, EAGAIN,
  `getentropy` fallback, and `BCryptGenRandom` cannot currently be forced from
  the public interface. A future injectable syscall adapter would make these
  branches mechanically testable without weakening production behavior.
- **Remaining — WARNING:** the Windows entropy branch at `bin/random:304-315`
  has no Windows CI leg; the Nix package itself declares Unix platforms. Verify
  it on actual Windows LuaJIT before advertising that implementation as proven.

## 3. Futile test coverage

No remaining finding. Re-blessed snapshots are not the sole authority: all 35
official BLAKE3 cases, a four-seed Zig-stdlib reference at seven structural
lengths, replay, source exhaustion, byte consumption, and range arithmetic are
separate controls. Mutating a BLAKE3 IV word, KDF context, seed grammar, and
wide-draw endianness made the intended suites fail.

## 4. Fast test coverage

The DRBG reference invokes `zig run` four times, but Zig's cache keeps the full
suite near two seconds locally. No sleep or timing-based entropy assertion was
added. No finding.

## 5. Superfluous or duplicated functionality

- **Advisory:** deterministic and true-random u64 assembly/rejection have small
  parallel implementations (`bin/random:163-210`, `354-383`). Factoring them
  through callbacks would reduce duplication but add calls in a hot path; the
  explicit parallel code is acceptable while the tests pin both paths.

## 6. Suboptimal, inconcise, or disorganized code

`main` remains large, but its size predates this migration and its mode branches
are explicit. The new seed, DRBG, and entropy sections are cohesive. No new
finding.

## 7. Algorithmic complexity

Seed parsing is O(32n), bounded by command-line input size. BLAKE3 and output
generation are linear. Rejection sampling has the expected constant average
cost. No finding.

## 8. Files without clear purpose

The new files have distinct roles: vendored producer, immutable upstream
fixture, official-vector runner, CLI contract suite, and independent Zig
reference. No finding.

## 9. Not leveraging language features

- **Remaining — ADVISORY:** very large raw/hex output is materialized in full,
  and the vendored BLAKE3 API represents output as hex before conversion back
  to bytes. Chunked `string.buffer`/FFI output would lower peak memory, but is a
  performance improvement rather than a correctness requirement for ordinary
  CLI counts.

## 10. Memory safety and resource leaks

- **Fixed — ADVISORY:** the new test initially sourced a personal absolute-path
  helper. It now has a hermetic private capture directory with trap cleanup.
- **Remaining — ADVISORY:** an explicit entropy file remains open for the life
  of the process. The CLI performs one operation and exits, so the OS closes it;
  an embeddable/library API should add explicit reader cleanup ownership.

## 11. FFI boundary correctness

The OS FFI loops preserve partial reads, retry EINTR, enforce `getentropy`'s
256-byte limit, fail on zero/short reads, and check BCrypt status. The planned
project Zig/C FFI has not been implemented yet and was not reviewed here.

## 12. Error handling gaps

- **Fixed — WARNING:** negative `--count` previously succeeded as an empty loop;
  count now uses exact safe-integer parsing and rejects negative values.
- **Fixed — ADVISORY:** entropy-source open/EOF failures now carry an `Error:
  entropy ...` diagnostic and never fall back after an explicitly selected
  source fails.

## 13. Database access patterns

Not applicable; the project has no database.

---

# Zig/C milestone addendum

**Date:** 2026-08-04
**Scope:** the pure Zig DRBG/distribution core, public C ABI, C CLI, shared
LuaJIT oracle, package surfaces, statistics harness, and cross-target controls.
**Method:** thirteen independent review passes covering functionality, coverage,
test validity, security, performance, reliability, architecture,
maintainability, API design, developer operations, dependencies, test strategy,
and product completeness.
**Result:** all reproduced critical findings were fixed. The remaining findings
are explicit limitations or post-shipment engineering work, not silent
correctness blockers.

## 1. Functionality and cross-platform behavior

- **Fixed — CRITICAL:** both CLIs now switch Windows stdout to binary mode, so
  LF bytes in deterministic/raw output are not expanded by the Microsoft CRT.
  The C path also normalizes CRLF stdin items; the Lua oracle does the same.
- **Fixed — WARNING:** `.exe` suffixes participate in `nrandomz`/`drandomz`
  argv[0] dispatch, and repeated selection of the same distribution is
  idempotent.
- **Remaining — WARNING:** Windows ARM64 is compiled and its PE machine field
  is checked, but no Windows ARM64 runtime is available. Windows x86_64 is
  executed under Wine in CI and compared byte-for-byte with the Lua oracle.

## 2. Coverage adequacy

- **Fixed:** a real C11 consumer now checks struct layout, statuses, callbacks,
  state replay, every public symbol, malformed values, and numeric limits.
- **Fixed:** scripted byte sources force both u32 and u64 rejection retries,
  exact-divisor paths, and failure on a retry. Beta vectors and statistics
  cover the distinct `alpha < 1` gamma branch.
- **Remaining — WARNING:** syscall-level EINTR/ENOSYS/EAGAIN/getentropy and
  native BCrypt failure branches need an injectable platform adapter for
  deterministic branch coverage.

## 3. Test validity / non-vacuity

- **Fixed — WARNING:** Lua/C differentials now require both processes to exit
  zero and emit nonempty bytes before comparison. Cross payloads similarly
  validate every framed case's status and byte count.
- **Fixed — WARNING:** `--test` uses executable probes that prove invocation
  and success/failure propagation. LuaJIT 5.1's encoded POSIX wait status is
  decoded before `os.exit`; the installed C self-test runs the actual suite.
- **Fixed:** uniform and log-normal evaluators gained deliberately bad
  sensitivity fixtures. Seven bad generators must now be rejected.

## 4. Security

- **Fixed:** `--true-random` overrides the frontend-specific seed environment
  (`DRANDOM_SEED` for LuaJIT, `DRANDOMZ_SEED` for C) and rejects deterministic
  conflicts. Each frontend ignores the other's variable, giving
  security-sensitive callers an explicit fail-safe entropy mode without
  cross-frontend namespace coupling.
- **Fixed:** panic-capable fixed arithmetic was removed from the public ABI.
  Public conversions and samplers validate canonical values/domains and return
  statuses; extreme log-normal input now returns `RANDOMZ_NUMERIC_ERROR` rather
  than aborting the embedding process.
- **Fixed:** the header documents single-thread/fork clone semantics and state
  sensitivity; `randomz_drbg_zeroize` provides a non-optimizable wipe.
- **Remaining — ADVISORY:** the CLI does not attempt comprehensive secure
  erasure across every early-return path; applications still own seed/key
  lifetime and must use the zeroize API.

## 5. Performance and scalability

- **Remaining — WARNING:** small deterministic sampler draws reconstruct a
  keyed BLAKE3 XOF and cross C→Zig→C→Zig per 4/8-byte draw. A buffered source or
  prepared/batch sampler ABI is the principal optimization opportunity.
- **Mitigated — WARNING:** Poisson's exact sum-of-exponentials algorithm is
  linear in lambda. The public ABI now caps its exponent/resource domain;
  a transformed-rejection large-lambda implementation remains post-shipment.
- **Remaining — ADVISORY:** hex/base64 use per-character stdio and `./stats`
  retains distribution samples in Lua tables. Neither affects correctness at
  the documented default sizes.

## 6. Reliability and error handling

- **Fixed — WARNING:** raw, hex, base64, text, choose, shuffle, and weighted
  paths all flush/check stdout. Auto-seeded deterministic mode refuses to emit
  output when its replay seed cannot be written to stderr.
- **Fixed:** callback status identities are preserved for known
  `randomz_status` values; unknown nonzero failures map to entropy/source error.

## 7. Architecture

- **Fixed:** the ReleaseSafe randomz test graph imports a separately
  ReleaseSafe fixed module rather than a ReleaseFast dependency.
- **Fixed:** the public boundary now contains checked constructors,
  conversions, samplers, and state operations; the raw invariant-dependent
  arithmetic kernel remains internal.
- **Remaining — ADVISORY:** `differential-driver` is installed by ordinary
  `zig build` because cross/oracle scripts consume its stable installed path,
  though the Nix product package deliberately omits it.

## 8. Maintainability

- **Remaining — WARNING:** `src/randomz_cli.c` is a large multi-domain
  translation unit. Entropy, option parsing, encoding, and stdin operations
  should become private modules when the post-shipment distributions land.
- **Remaining — WARNING:** distribution metadata and the cross-CLI corpus have
  manually synchronized owners. A descriptor table/shared corpus should
  precede the planned expansion in modes.
- **Fixed:** stale references to the removed migration document and unavailable
  agent skills were removed from active plans.

## 9. Public API design

- **Fixed:** `randomz_fixed`'s representation and construction rule,
  callback-status behavior, formatting's unterminated-span contract, thread
  ownership, cloning, and zeroization are documented in the header.
- **Remaining — ADVISORY:** package, header, and Zig manifest versions still
  have separate literals; release automation should enforce one source.

## 10. Developer experience and operations

- **Fixed:** Zig and Nix installations include the shared self-test and license.
  Nix wraps the test with its tool closure; manual/Windows Bash requirements
  are documented. Package checks exercise all six invocation names and both
  installed `--test` paths.
- **Fixed:** README now distinguishes the three default cross legs from the
  optional native macOS leg and provides a C embedding quick start.
- **Remaining — ADVISORY:** two tracked developer-doc symlinks resolve into the
  maintainer's adjacent directories and dangle in a clean clone. The active
  plan is now substantially self-contained, but repository-local snapshots
  would improve outside onboarding.

## 11. Dependency management

- **Fixed:** the Zig package allowlist includes the header, license, README,
  self-test, and all build inputs. An isolated `zig fetch` reconstruction must
  build/test/install successfully.
- **Fixed:** both Zig and Nix product installs carry the MIT license; Nix's
  unused wrapper dependency was either removed or put to actual use for the
  installed test closure.
- **Remaining — ADVISORY:** LuaJIT's pinned revision and the runtime mitigation
  roll-number constant are manually coupled and should gain a mechanical
  release check when the pin next moves.

## 12. Testing strategy

- **Fixed:** CI now has separate correctness, deterministic stats-smoke,
  installed-package/ABI, ReleaseFast cross-architecture, and Windows x86_64
  runtime checks. Required platform manifests cannot silently shrink.
- **Fixed:** the full pre-push analysis separately samples true OS entropy at
  4 MiB and 50,000 values/distribution for each implementation.
- **Remaining — WARNING:** native macOS remains an SSH-controlled optional leg,
  and Windows ARM64 remains compile-only. CI must not describe those as native
  runtime evidence.

## 13. Product completeness

- **Fixed:** surplus positional arguments, conflicting stdin operations,
  incompatible encodings, and irrelevant distribution parameters are rejected
  consistently by both CLIs.
- **Remaining — planned:** the benchmark suite is intentionally still open;
  gamma, Weibull, Pareto/Zipf, geometric/binomial, Cauchy/Student-t,
  edge-biased, and log-uniform modes are recorded as post-shipment work.

---

# Rust `randomr` milestone addendum

**Date:** 2026-08-11
**Scope:** the importable Rust core, Rust CLI, shared three-frontend controls,
Cargo/Nix packaging, cross targets, and native-target workflow.
**Method:** independent passes over review dimensions 1–4, 5–8, and 9–12,
followed by reproduction and revalidation against the changing tree.
**Result:** no critical findings or release-blocking warnings remain. All
reproduced warnings were fixed; only explicitly deferred performance and
organization advisories remain.

## 1. Inconsistent, incomplete, or undefined functionality

- **Fixed — WARNING:** Rust binary output allocated the entire requested count
  (plus a second base64 buffer) and aborted on valid large requests. It now
  streams fixed 64 KiB chunks, carries 0–2 base64 bytes between chunks, and is
  proven byte-identical at counts 65,535–65,538 under all three encodings. A
  128 MiB request must complete beneath a 64 MiB virtual-memory limit.
- **Fixed — WARNING:** the first streaming edit duplicated the final raw chunk.
  Independent review caught it before acceptance; the all-encoding boundary
  matrix would also turn red for that implementation.
- **Fixed:** fractional distributions now default to the deterministic maximum
  of 18 decimal places. `--precision N` and `--truncate N` explicitly truncate
  to 0–18 places without rounding in all three frontends.
- **Fixed:** `randomr` stdin is byte-oriented, preserves non-UTF-8/NBSP bytes,
  and accepts non-UTF-8 `--random-source` paths through `OsString`/`PathBuf`.

## 2. Inadequate test coverage

- **Fixed — WARNING:** direct library tests now pin every sampler's exact API
  output and byte consumption, u32/u64 rejection, typed source failures,
  invalid domains, DRBG state/cap/endian/zeroization behavior, and exact/EOF
  path entropy. The public doctest and downstream no-default-features consumer
  both compile.
- **Fixed — WARNING:** the pinned `getrandom` Linux backend treats `EPERM` as
  unavailable and falls back to `/dev/urandom`, which could turn a sandbox
  policy denial into silent success. The Linux/Android adapter now owns the
  blocking syscall policy: it retries `EINTR`, continues exact partial reads,
  reports `EAGAIN` distinctly for nonblocking calls, falls back only on
  `ENOSYS`, and fails closed on `EPERM`, zero-byte returns, and hard errors.
  Injected syscall controls cover the policy-denial, missing-syscall,
  interruption, partial-read, and would-block paths without kernel faults.
- **Fixed:** Windows/macOS ARM64 workflow payloads cover raw DRBG, every
  nonlinear distribution, a wide range, stdin shuffle, and OS entropy. The
  Windows leg also probes the Bash `--test` launcher; these become runtime
  evidence only after the remote workflow is green.

## 3. Futile or falsely reassuring tests

- **Fixed — WARNING:** selector/oracle mutations used nonexistent `/bin/false`
  and went red at executable preflight. The candidate selector now resolves a
  real failing executable and requires a downstream diagnostic. The final
  Zig-vs-Rust oracle mutation uses an executable wrapper whose Zig producer
  succeeds but corrupts its output; the control requires the named final
  differential with both producer statuses equal to zero.
- **Fixed — ADVISORY:** the purity check only searched a short list of `std`
  I/O paths. A dedicated gate now also rejects `getrandom`, `libc`, unsafe/FFI,
  output macros, ambient state, and entropy feature escape hatches everywhere
  outside `entropy.rs`; it verifies both OS dependencies remain optional and
  feature-confined. A feature-gated `getrandom` mutation in `drbg.rs` proves
  this stronger boundary can turn red.
- **Fixed — WARNING:** the shared `--test` probe accepted the formerly vacuous
  Rust implementation. It now requires child depth zero, and installed-package
  testing caught/fixed a recursive Nix wrapper before release.
- **Fixed:** architecture controls pin BLAKE3's zeroize feature and every
  seed/key/Hasher/OutputReader zeroizing guard, so deleting a wipe guard makes
  a source-level control red even though residual memory is not behaviorally
  observable.

## 4. Fast-test issues

- **Fixed — WARNING:** all three pairwise comparisons reran the complete shared
  acceptance/chart stack. Each frontend now runs local acceptance once, while
  the third pair uses an explicit differential-only mode. All three 141-case
  exact matrices remain mandatory.
- **Fixed — ADVISORY:** the nonlinear mutation still compiles an isolated
  release workspace, but now judges one frozen log-normal vector instead of
  rerunning the full acceptance/chart/differential stack. Producer independence
  is retained while routine mutation latency is sharply bounded.

## 5. Superfluous or duplicated functionality

- **Fixed:** the dead public `Error::BufferTooSmall` variant was removed, and
  the duplicated fixed exponent-validity predicate plus raw 2^53 literals now
  have one core owner.
- **Remaining — ADVISORY:** five cross-target/stat scripts repeat the same
  minimal `cargo metadata` target-directory extraction. A sourced Rust test
  setup helper would reduce maintenance without affecting behavior.

## 6. Suboptimal, inconcise, or disorganized code

- **Fixed:** generalized differential diagnostics now identify the actual
  oracle/candidate pair rather than claiming every comparison is Lua-versus-C.
- **Remaining — ADVISORY:** Rust CLI token interpretation is split across early
  actions, generation parsing, distribution help, and renderer selection.
  `Options::parse` also mixes consumption and cross-option validation. A typed
  command/action classifier should precede post-push CLI expansion.
- **Remaining — ADVISORY:** numeric CLI parameters remain tuple-encoded as
  `Option<(Fixed, String)>`; a `ParsedFixed` type would make value/spelling
  ownership clearer before adding more distributions.

## 7. Algorithmic complexity and performance

- **Fixed — WARNING:** encoded binary output is O(1) memory rather than
  O(requested output), while retaining O(n) time and exact byte order.
- **Fixed — ADVISORY:** `./bm` formerly timed the Nix Bash wrapper for
  `randomr`, whose repeated `PATH` setup added about 13 ms per process on the
  measured Linux host. The build now preserves the identical unwrapped ELF for
  timing while retaining the packaged CLI in the parity preflight. History
  schema 2 names this timing surface, so wrapper-era results cannot become a
  false regression baseline.
- **Fixed — ADVISORY:** Rust formerly recomputed the log, exponential, sine,
  and cosine series reciprocal coefficients at runtime through the kernel's
  62-step bit-serial division. It now builds exact tables during const
  evaluation, matching Zig's comptime policy. A red-before/green-after call
  counter proves `ln`, `exp`, and cosine no longer divide for coefficients;
  another test regenerates every table through the runtime kernel. Quick A/B
  CPU time improved 32–49% across the five nonlinear distributions while raw
  and uniform controls remained materially flat, and all benchmark payloads
  remained byte-identical across both Rust surfaces and both external oracles.
- **Remaining — ADVISORY:** beta/log-normal curve rendering calculates every
  expensive score twice to find and then normalize the maximum. A bounded
  score vector can halve transcendental work.
- **Remaining — ADVISORY:** scalar 4/8-byte sampler draws reconstruct a keyed
  BLAKE3 XOF reader. Measure this in the planned benchmark suite before adding
  a zeroized cache that could complicate state/clone semantics.

## 8. Files without clear purpose

No orphaned Rust file was found. The generated chart module, entropy mutant,
downstream fixture, BSD/Windows link gates, and linker adapters each have a
named consumer. The Windows ARM64 cross-link gate is now executed in CI rather
than merely syntax-checked.

## 9. Rust language and public API design

- **Fixed:** path-bearing argv uses `OsString`/`PathBuf`; arbitrary stdin items
  remain bytes. Rustfmt is repository-configured with `hard_tabs = true`.
- **Fixed:** the crate has a compiling example and complete public rustdoc;
  documentation builds deny both warnings and missing docs. Seed secrecy,
  exported derived-key sensitivity, state restoration, and caller wipe
  ownership are visible at the API site. Planned-to-grow `Error` and
  `Distribution` enums are non-exhaustive.

## 10. Memory safety, resource ownership, and secrets

- **Fixed — WARNING:** BLAKE3's feature alone does not wipe on drop. Incremental
  KDF and keyed-XOF Hashers, Hash/OutputReader temporaries, derived-key locals,
  restored-state parameters, option seeds, parsed environment seeds, and
  auto-seed storage now use zeroizing guards or explicit wipes. `Drbg` remains
  `ZeroizeOnDrop`; caller-owned seed/state copies are documented as caller
  responsibility.
- **Fixed:** help/about/view/generation writes return ordinary I/O errors rather
  than panicking on `/dev/full`; the same audit also fixed buffered help/about
  write failures in the LuaJIT and C frontends.

## 11. FFI and cross-target boundaries

The Rust deterministic implementation uses no C ABI and shares no code with
either oracle. Its sole unsafe block is the scoped Linux/Android `getrandom`
call over a valid remaining slice; other entropy access uses safe Rust APIs.
FreeBSD/NetBSD manifest identity is exact, Windows ARM64 is both cross-linked
through Zig and proven by first-party native execution, and the pure core is
compile-gated for `wasm32-wasip1`. Equivalent shippable Zig/Rust WASI artifacts
remain a measured post-port decision.

## 12. Error handling and packaging

- **Fixed — WARNING:** `randomr --test` formerly launched the shared suite at
  recursion depth one, so it returned green without tests. It now selects the
  Rust frontend at depth zero, propagates status, invokes Bash directly, and
  works from the standalone Nix package.
- **Fixed — WARNING:** the first standalone wrapper forced its suite path and
  recursively defeated the suite's test probe. `--set-default` preserves
  explicit overrides, and package smoke invokes the standalone self-test.
- **Fixed:** `Unsupported`, `WouldBlock`, EOF, and generic entropy failures have
  distinct typed errors and CLI diagnostics; path open errors retain path and
  OS cause. Output errors fail cleanly without panic diagnostics.
- **Remaining — ADVISORY:** Nix Rust derivations still hash the full
  multi-language repository (`src = ./.`). A fileset limited to Cargo inputs
  would improve cache reuse, but changing source filtering immediately before
  shipment adds more packaging risk than value.

## 13. Database access patterns

Not applicable. The project and all three deterministic cores have no database
or persistent RNG state.

---

# Portable continuation-state milestone addendum

**Date:** 2026-08-13
**Scope:** uncommitted LuaJIT, Zig/C, and Rust continuation-state implementation,
with special attention to the new Rust CLI/core boundary, hostile JSON input,
and the shared Bash interoperability oracle.
**Method:** independent fresh-context read-only review after the implementation
and full green gate, followed by producer-side fixes and reviewer revalidation.
**Result:** no critical, warning, or advisory findings remain in the reviewed
feature. Every reproduced finding below was fixed before shipment.

## Fixed findings

- **Fixed — WARNING:** recursive C and Rust JSON parsers could overflow their
  stacks on deeply nested input within the 1 MiB stdin allowance. All three
  codecs now enforce 64 nesting levels, 32 object members, and 1024 array
  items; the C limits also prevent quadratic unknown-key parsing from becoming
  an input-amplification path.
- **Fixed — WARNING:** LuaJIT and C accepted raw invalid UTF-8 state strings
  that Rust rejected, and could produce invalid JSON from a non-UTF-8 delimiter.
  State input and state-bearing delimiter output now share strict UTF-8 policy;
  diagnostics remain valid JSON even when hostile argv bytes are escaped.
- **Fixed — WARNING:** Lua's JSON decoder accepted leading-zero numbers,
  non-JSON whitespace, and one missing-object-value shape. The shared negative
  matrix now pins the same strict grammar in every frontend.
- **Fixed — WARNING:** state ranges accepted CLI shorthand despite claiming a
  canonical wire form. Consumers now require signed-integer `M..N`; `dN`,
  hyphen, and exclusive spellings are rejected in serialized state.
- **Fixed — WARNING:** stdin-operation continuation originally covered only
  same-implementation `--choose`. It now covers all 3×3 producer/consumer
  directions for choose, shuffle, and weighted selection, requires successful
  nonempty output, validates the resumed state shape, and proves that its byte
  cursor advances rather than restarting from the seed.
- **Resolved contract ambiguity:** `rv` is the informational producer
  application version requested by the state design, while `sv` is the
  enforced state/stream compatibility version. The documentation and oracle
  now pin that distinction so compatible application releases do not
  gratuitously invalidate state, and semantic changes must increment `sv`.
- **Fixed — WARNING:** the Nix package installed the new Lua state module, but
  the top-level `./build` copier omitted it from the stable `zig-out` tree.
  The in-memory `./bm --check` package preflight exposed the missing module;
  the copier now installs it and all ten benchmark workloads again agree.

## Independent oracle assessment

The generation matrix genuinely executes every directed 3×3 pair and compares
each prefix-plus-resumed-suffix with its producer's uninterrupted baseline for
ten fixed- and variable-consumption output families. The stdin matrix proves
all directed pairs, successful cursor advancement, and three-consumer
agreement; its semantic authority is differential rather than a separate
external oracle. Together with the independent BLAKE3 implementations and
existing sampler vectors, this is an appropriate control for a state transport
feature rather than a new random algorithm.

---

# State-schema 2, byte-delimiter, and Lean 4 milestone addendum

**Date:** 2026-08-26
**Scope:** schema-2 continuation transport, empty-delimiter byte semantics,
the Lean deterministic model/proofs/frontend, Nix packaging, and the shared
four-command-family gates.
**Method:** one primary-agent review across all thirteen dimensions, aided by
the current codescan index, direct source inspection, hostile probes, a
controlled mutation, and the complete local test/statistical/benchmark gates.
No separate review agent was used for this addendum.
**Result:** no critical finding remains. Three substantive review findings were
fixed; the remaining limitations below are explicit proof/product boundaries.

## 1. Functionality

- **Fixed — WARNING:** a manually constructed Lean `Drbg` with a cursor already
  above 2^53 could accept a zero-byte fill because natural-number subtraction
  truncated the bound to zero. `Drbg.fill` now rejects an invalid incoming
  cursor, and `fill_respects_position_limit` proves the successful result
  cursor itself is at or below the ceiling.
- **Fixed — WARNING:** `Drbg.init` accepted arbitrary seed lengths even though
  the wire contract is exactly 32 bytes and the modeled BLAKE3 subset is
  single-block. Initialization now returns `none` unless the seed is exactly
  32 bytes.
- **Remaining — explicit boundary:** `randoml` delegates its complete CLI,
  entropy, fixed-point distribution, and formatting surface to `randomz`.
  It is compatible but not a fourth independent behavioral oracle.

## 2. Coverage adequacy

- **Fixed — WARNING:** one frozen seed/cursor vector did not adequately probe
  block boundaries or seeking in the independent Lean DRBG. The trust-zero
  gate now retains that frozen vector and adds five LuaJIT-oracle differentials
  across seeds, offsets 0/1/63/64/4097, and multi-block reads, plus seed and
  position boundary controls.
- The shared state gate covers every 4×4 producer/consumer direction for fixed
  and variable consumption and every byte-oriented stdin operation direction.

## 3. Test validity

- **Mutation-verified:** flipping one bit in the Lean BLAKE3 IV made the external
  vector gate fail; restoring the bit returned it to green. The proof-source
  scan, trust-zero elaboration, and `#print axioms` audit are separate controls.

## 4. Fast coverage

No sleeps or timing assertions were introduced. The five extra pure Lean
differentials add seconds, not minutes; the multi-minute full gate remains
dominated by release/cross builds and intentional mutation builds.

## 5. Duplication

Schema serialization remains deliberately independent in Lua, C, and Rust so
the differential can detect a single-implementation mistake. The shared Bash
contract is the single behavioral owner. No actionable duplication finding.

## 6. Organization

The Lean modules separate BLAKE3, DRBG/range execution, and proofs. `Main.lean`
states its subprocess trust boundary directly. The established large C CLI
translation-unit warning remains, but this feature did not materially worsen
it.

## 7. Complexity

State JSON is capped at 1 MiB and already enforces depth/member/item limits.
Empty-delimiter shuffle is O(n) storage plus O(n) Fisher–Yates work. The Lean
BLAKE3 reference allocates arrays and is not presented as a throughput engine.
Removing unnecessary Lean interpreter support reduced the stripped adapter
from 10,320,384 to 2,007,232 bytes without changing behavior or proofs.

## 8. File purpose

Every new Lean and test file has one named role. The evaluation report is the
claim matrix and judgment log requested for this experiment; it is not a
second specification.

## 9. Language features

Lean source uses spaces because Lean 4.30 rejects tab indentation. The formal
model uses machine words for executable BLAKE3 but does not yet prove a
refinement to a separate `BitVec`/`Nat` compression specification.

## 10. Memory and resources

The C byte-item spans retain ownership in one backing allocation and preserve
embedded NUL bytes without calling string routines on byte items. Rust owns
each byte item. The Lean frontend waits for its child and introduces no
persistent state or temporary payload files.

- **Fixed — WARNING:** the initial installed Nix closure was 2.4 GiB because
  the CLI self-test wrapper retained the full CI toolchain and embedded Zig
  source paths made the WASM retain Zig/LLVM. A minimal, package-smoke-verified
  self-test PATH plus installation-time reference neutralization reduced the
  closure to 127.8 MiB without removing the installed self-test or WASM.

## 11. FFI correctness

The schema/delimiter work does not change the public C ABI. The complete ABI
symbol/layout test and C CLI dogfooding remain green. `randoml` crosses a
process boundary, not the C ABI, and is documented accordingly.

## 12. Error handling and proof gaps

- **Remaining — WARNING:** `Drbg.range` is a `partial` executable rejection
  loop. Mapping bounds are proved, but termination and statistical uniformity
  of the complete loop are not; the report does not claim otherwise.
- **Remaining — ADVISORY:** Lean's standard `List String` argv boundary cannot
  distinguish invalid UTF-8 replacement from a literal U+FFFD. The frontend
  fails closed, creating one documented false rejection. Exact parity would
  require a native raw-argv launcher that adds no value to the currently
  delegated CLI.
- **Fixed — ADVISORY:** package smoke inherited `/homeless-shelter` as HOME,
  so recoverable test-shim cleanup printed a failed-directory diagnostic. It
  now uses private HOME/XDG directories and a mode-0700 runtime directory.

## 13. Database access

Not applicable. No command family persists RNG state or uses a database.
