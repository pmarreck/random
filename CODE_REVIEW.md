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
