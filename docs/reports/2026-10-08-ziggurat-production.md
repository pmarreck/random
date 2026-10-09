# Production Ziggurat and exact SIMD

2026-10-08–09. Release 0.4.0 replaces Box–Muller in LuaJIT, Zig/C, Rust, Lean 4
and Roc. The [stream contract](../specs/2026-10-08-ziggurat-stream-v3.md)
specifies header bits, rejection, arithmetic order and continuation behavior.

Normal, normalized integers, log-normal and beta intentionally get new seeded
sequences. CLI continuation schema is now `sv:3`; old schemas are rejected
before output. BLAKE3 bytes, uniform, exponential, Poisson and geometric retain
their sequences. Production contains no legacy Box–Muller option or spare-normal
cache. Low-level key/cursor snapshots remain unversioned, so consumers persisting
them must pin their sampler construction separately.

## Portability and failure controls

An independent acceptance author froze the experiment-derived expectations
before inspecting production implementations. The Bash suite requires all five
implementations on Linux and four on Darwin, plus Roc when explicitly selected.
Its fixture SHA-256 is
`14b1296c6e1520debba234ff83eb93332a25c43027844d13b3a4738813bfc127`.

The 2,305-assertion Linux corpus covers nine parameterizations, eleven counts
from zero through 1,025, exact stdout digests and byte cursors, raw/hex/base64
output, and all 25 producer-to-consumer continuation directions at two splits.
Eight supplied entropy streams force wedge acceptance/rejection, both tail
signs, tail equality and local retry. Forty additional signed endpoint checks
exercise the independently derived correction described below.
Expectations are stored, never regenerated
from production outputs during acceptance.

Zig's LuaJIT-FFI batch suite passed 347,075 checks across AUTO, SCALAR and explicit
SIMD. It compares values, cursor, callback request order, status, completed
prefix, untouched suffix and canary storage against sequential scalar calls.
Directed tail/wedge streams fail at every byte cutoff from 0 through 104.
Rust tests cover scalar/automatic batch partitions, supported endpoint ranges,
invalid pre-read admission, cursor-cap failures and speculative-group replay.
Rust speculates only on its seekable caller-owned DRBG; arbitrary effectful
`ByteSource` implementations use the scalar entry.

All five generated tables regenerate with identical signed integer literals at
512-bit MPFR precision. The finite certificate checks every threshold floor,
stored-height direction, geometric bounds and selected near-boundary decisions.
It explicitly reports eight compiled-versus-ideal-real wedge differences;
these are not hidden or counted as exact real-arithmetic agreement. Mutation
controls reject wrong coordinate bits, reversed acceptance comparisons,
corrupted tables and skipped benchmark work.

Stale test assumptions surfaced during the migration: frozen Box–Muller
values and a Roc probe that assumed every normal draw consumed exactly eight
bytes. The latter now captures the cursor before sampling. These were test
assumptions, not newly discovered arithmetic defects. The installed Rust
consumer also retained a Box–Muller normal value; its expectation now uses the
independent experiment-derived Ziggurat vector already frozen in the Lua
library test. Only that fixture changed, and the rebuilt Rust executable's
SHA-256 was identical before and after the fixture correction.

The full native gate also caught a backend-mode mismatch: Zig accepted the new
explicit SIMD mode `2`, while Roc still treated it as invalid. Roc now accepts
it through its portable scalar fallback. Its 1,800-case FFI corpus compares all
three valid modes and retains negative controls for modes −1 and 3; the core
suite passed all 197 tests plus its runtime oracle cases.

Final review exposed an inherited arithmetic defect: normalized integers near
±2^53 could clamp a rejected tail into an endpoint. With U=V=1 the base tail
is greater than three standard deviations; on `[2^53−10,2^53]` the old result
was `2^53` instead of rejection. All 40 independently derived endpoint
assertions failed across the five CLIs before correction, while the original
2,265 assertions still passed. Scalar/batch agreement alone had missed it.

Every implementation now rejects before generic saturating conversion. For a
canonical `m·2^(e−62)`, the exact rejection threshold `|x|≥2^53+1/2` is
`e>53`, or `e=53` and `|m|≥2^62+256`. Exact half ties are included. Tests cover
both signs, adjacent mantissas, actual four-lane groups, byte cursors, source
failures and untouched suffixes. Legacy scalar entries also reject unsupported
endpoints before reading. Lua computes wide interval widths in fixed point,
preserving odd widths above 2^53; Lean no longer applies the uniform mapper's
cardinality restriction to the nonlinear library sampler. CLI range admission
remains unchanged.

## Production statistical repeat

The actual public Zig C ABI generated 32 million outputs: four seeds, four
shapes, two million outputs per cell. This repeats the candidate's seeds and
workloads from the [96-million-output experiment](2026-10-08-fixed-point-ziggurat.md).
It checks production wiring; it is overlapping evidence, not an independent
additional statistical campaign. The frozen thresholds were unchanged.
This campaign preceded the endpoint correction; its small-range workloads
and normal/log-normal/beta arithmetic are unchanged by that correction.
Corrected builds repeated the statistical smoke and finite/oracle controls,
not another full 32-million-output campaign.

| Shape | Maximum empirical CDF discrepancy | Frozen envelope |
|---|---:|---:|
| Normal, mean −0.25 / stddev 1.75 | 0.000733031 | 0.00214359 |
| Rounded, conditioned normal integers 0..255 | 0.000724869 | 0.00214359 |
| Corresponding log-normal | 0.000733031 | 0.00214359 |
| Beta(1,3) | 0.000849527 | 0.00214359 |

Normal seam, sign, moment, serial-covariance and occupancy diagnostics passed.
Across eight million standardized normal draws, 502 exceeded four standard
deviations and two exceeded five. The five-sigma count is too small to establish
extreme-tail accuracy. The experiment report states the ideal-source assumptions
and which diagnostics have calibrated probability budgets. Fixed seeds do not
provide a proof of IID randomness or cryptographic security.

## SIMD decision

Four-lane AVX2 performs exact fixed-point multiplication and two additions on
completed normal candidates. It uses integer limb products and preserves scalar
truncation and addition order. Sampling and rejection remain sequential; short
tails are scalar. The fused entry crosses the CPU-feature boundary once, keeping
all three affine stages in vector registers. The release Rust binary contains
AVX2 `vpmuludq`, variable shifts and blends. Feature detection requires supported
CPU/OS vector state; other machines retain portable scalar execution.

The first unfused/grouped measurements were unstable and sometimes slower than
scalar. They remain in the receipts as diagnostics. The fused protocol warms
both modes and measures 24 balanced scalar/SIMD pairs per process. Each side
times eight fresh-state 16,384-value workloads, checking every repetition against
an independently composed output checksum outside the clock. Even pairs run
scalar first; odd pairs run SIMD first.

Measured scalar/SIMD geometric-mean CPU ratios on an AMD Threadripper 3990X,
Linux x86_64, pinned Zig 0.16.0 and Rust 1.97.1:

| Implementation / allowed affinity | Paired ratio, two separate processes | Decision |
|---|---:|---|
| Rust / one CPU | 1.312, 1.309 | Enable runtime-guarded automatic AVX2 |
| Rust / twelve CPUs | 1.304, 1.304 | Enable runtime-guarded automatic AVX2 |
| Zig / one CPU, no decimal formatting | 1.027, 1.027 | Keep SIMD opt-in |
| Zig / twelve CPUs, no decimal formatting | 1.026, 1.027 | Keep SIMD opt-in |

Ratios above one favor SIMD. All final runs include the exact endpoint guard
and prepared-sampler proof boundary. All twelve paired cases met the unchanged
variation policy. Rust favored SIMD in 24/24 pairs in each process, corresponding
to 30–31% higher throughput on this workload. Zig's four final core processes
also favored SIMD in 24/24 pairs, but the gain was only 2.6–2.7%; formatted
ratios ranged from 1.008 to 1.016. Earlier Zig processes ranged from 0.984 to
1.013 without formatting. We retain the small final gain as evidence, but keep
Zig AUTO scalar pending broader measurements; explicit SIMD is available.
Earlier inconclusive measurements remain inconclusive in the receipts.
These are host/workload measurements, not universal speed guarantees or
independent statistical replicates. Twelve allowed CPUs
means a single-threaded process may run on those CPUs, not twelve-thread scaling.

Rust's `Drbg::normal_int_batch` automatically selects AVX2 on supported
std-enabled x86_64 builds. Zig's `RANDOMZ_BATCH_AUTO` currently uses scalar;
`RANDOMZ_BATCH_SIMD` explicitly requests guarded AVX2 with scalar fallback.
`RANDOMZ_BATCH_SCALAR` is always available. This policy follows the measurements
without changing values, source consumption or bounded-memory guarantees.

## Actual CLI before/after

The end-to-end probe executes immutable 0.3.0 and 0.4.0 CLI packages, including
startup, sampler, decimal formatting and pipe output. A bounded 64-KiB RAM sink
verifies every stdout byte using a frozen rolling checksum. Stderr and stdin go
to the null device. There are no payload files or startup-cost subtraction.
Each case uses seed 42, 32,768 values, two warmups and seven timed invocations;
the checked clocks record child CPU time and full monotonic wall time.
The Rust executable from the final isolated package build has the same SHA-256
as the immutable Rust executable measured in the final run.

Final one-CPU observations, mean child CPU milliseconds per invocation:

| CLI / shape | Box–Muller 0.3.0 | Ziggurat 0.4.0 | Observed ratio |
|---|---:|---:|---:|
| Zig normal | 26.809 | 5.966 | 4.49× |
| Zig normalized integers | 18.840 | 5.735 | 3.29× |
| Zig log-normal | 51.547 | 29.462 | 1.75× |
| Zig beta | 86.083 | 43.177 | 1.99× |
| Rust normal | 151.692 | 93.669 | 1.62× |
| Rust normalized integers | 121.413 | 89.358 | 1.36× |
| Rust log-normal | 194.545 | 157.718 | 1.23× |
| Rust beta | 244.706 | 183.072 | 1.34× |

All sixteen final one-CPU cases satisfied the fixed variation policy and output
checks. Across both affinity cohorts, all 32 final CLI cases were valid
UNBASELINED measurements; none needed a retry. Together with the twelve paired
core cases, all 44 final cases passed output and unchanged-fingerprint checks.
Previous CLI runs had inconclusive cases or a permitted retry; those results
and all retries are retained, not relabeled as accepted observations. No
performance baseline was approved.

The host was heavily loaded and swapping during parts of this work. Grouped
CLI measurements do not remove temporal drift; report these as observed
improvements on this host, not precise portable speedup promises. The paired
core experiment addresses a different question from the complete CLI timing.
The CLI child and RAM sink share the allowed affinity: one CPU forces them to
take turns, while twelve allow them to run concurrently. Cross-cohort changes
can therefore include pipe scheduling and host effects; they are not sampler
thread scaling. Compare before/after within the same cohort.

[Sanitized measurement receipts](2026-10-08-ziggurat-production-measurements.json)
include pre-fusion diagnostics, fused pairs, final Zig opt-in pairs, every final
CLI case, retries, CPU/wall samples, checksums, unchanged source fingerprints,
artifact hashes and runtime identities. The `corrected_v7` section contains the
44 final endpoint-guard measurements; earlier v3–v6 entries are historical
pre-correction observations. Earlier full runs remain in the external
performance history. An initial combined Zig/Rust build-mode metadata mismatch
was rejected as INVALID and is excluded from all conclusions. The dedicated
experiment shell now pins Cargo, rustc and rustfmt instead of inheriting ambient
tools. Cargo from the Rust 1.97.1 package reports its own version as 1.97.0.

## Kani boundary repair

Caching normalized-integer parameters changed the Rust wrapper's scalar call
boundary. Its existing Kani stub still targeted the old scalar entrypoint, so
it no longer modeled the function the wrapper actually called. A forbidden
nonlinear-call assertion reproduced the mismatch in 4.8 seconds. The prepared
sampler now has an explicit private inline boundary, and the proof models that
boundary. Runtime scalar/SIMD comparisons remain separate checks.

Both affected positive contracts passed, as did their deliberate failing
controls: each control failed only its designated destination assertion, with
all required reachability covers satisfied. Both complete 21-harness compiled
manifests were checked; the other 19 proofs were not re-solved in this rerun.
Kani 0.68.0 used its pinned nightly compiler, CBMC 6.11.0 and MiniSAT. The same
two positives and two controls passed again after the endpoint correction,
with both full manifests accepted and selected metadata matched against them.
The positive wrapper and actual-source-error proofs took 28.833 and 1.365
seconds respectively. A private targeted runner initially applied the full
21-entry requirement to selected two-entry metadata and correctly failed
classification after both negative controls passed. The full manifest check
was retained; selected metadata was checked separately. An initial private
positive-runner syntax error started no solver and is not proof evidence.

An initial manifest mistakenly required a disconnected forbidden-call check
to appear as unreachable. Kani elides the entire disconnected function instead.
The classifier rejected that run; its expectation was corrected without
removing the guard. Any emitted guard is now outside the allowed assertion
set and rejects the result, including forged Success or Unreachable statuses.
The default classifier tests cover those cases. A preceding long diagnostic
was interrupted and is not counted as a proof result.

These proofs establish bounded portable-wrapper composition under an explicit
sampler model and the actual immediate-source-error path. They do not prove
successful nonlinear arithmetic, distribution laws or AVX2 equivalence. The
receipts include both cycles' eight accepted proof/control summaries and authored checks.

## Build and proof limits

Lean's CLI builder now lets Lake cache optimized native module objects and
dependency/compiler traces, instead of compiling every generated C file on
every invocation. The complete five-language state suite passed all 1,870
checks within its unchanged 300-second budget, including a default-path rebuild.
No reduced Lean/Roc acceptance matrix or raised timeout was used.

Local release validation passed all 43 default root `./test` suites and all
11 Nix release targets: installed libraries/CLIs, statistical smoke, Roc core
and C ABI, cross-architecture, Rust cross-compilation, Windows x64 smoke and
aggregate/separate Zig packaging. The stale installed-consumer fixture was
corrected and the library, package-smoke and remaining Rust cross-compile
targets rerun; generator sources were unchanged. Exact pushed-commit CI is
checked separately after publication. Native
execution during this migration is Linux x86_64; cross-compilation is not native
Darwin, Windows or aarch64 runtime evidence. Windows smoke runs under Wine,
not native Windows. A final fresh-context review covers
the production change, especially Rust and the SIMD/error-prefix boundary.

The final cross-architecture gate passed 63 CLI invocations through each of
three LuaJIT legs, three Zig/C targets and two Rust targets. It also passed
kernel, decimal and DRBG differentials and normalized batches under pre-AVX
CPU emulation. The aarch64 runtime legs use QEMU, not native ARM hardware.

After the endpoint correction, the fresh-context reviewer independently passed all
36 Rust library tests, a no-default-features compile check, 347,075 Zig batch
FFI checks and the complete 2,305-check five-language production corpus. It did
not independently rerun the Kani solver or heavy statistical campaign. The
endpoint finding above reopened clearance until these corrected-source checks
passed. DCR-001 is resolved, with no remaining implementation finding in the
requested scope. The inherited scalar validation gap outside ±2^53 is also
corrected; revalidation covers pre-read refusal, half-tie adjacency and an
independently derived real-DRBG AVX2 rejection case. Reviewed source hashes
were unchanged throughout independent execution.
The [review record](../../CODE_REVIEW.md) preserves its scope and exclusions.

The proposed global Kolmogorov error bound below `1e-11` is still unproved.
Primitive rounding bounds, branch-disagreement mass, rejection coupling and
production-linked distribution-law refinement remain explicit PLAN obligations.
Lean executable agreement, finite MPFR certificates and statistical diagnostics
are distinct evidence; none substitutes for those missing theorems.
