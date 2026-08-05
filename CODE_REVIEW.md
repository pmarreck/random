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
