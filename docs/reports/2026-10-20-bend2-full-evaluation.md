# Full Bend 2 implementation and evaluation

## Outcome

`randomb` now has an independent Bend numeric core and the existing C I/O
frontend, connected through its own static/shared C ABI. It covers the current
BLAKE3 DRBG, fixed-point nonlinear distributions, arbitrary-width geometric
counts, selection/shuffle plans, bounded batches and canonical chart models.
It does not call another implementation's generator or arithmetic. Source and
generated-JS consumers can also import the pure library without the CLI.

The implementation remains an optional experiment, outside the five-backend
default aggregate. Its measured APIs are substantially slower than Zig/Rust;
the new interfaces and tests do not make it production-approved or prove the
sampler distributions. The [earlier byte-only report](2026-10-20-bend2-evaluation.md)
remains a historical checkpoint, not the current feature limit.

## Correctness and integration

The same Bash expectations now select Bend. The expanded matrix executed
2,574 six-way continuation checks, 120 complete help-output comparisons,
330 streaming checks and 2,982 frozen Ziggurat checks. The Lean matrix was not
reduced. These counts overlap coverage; they are not independent random samples.

Additional exact controls include 2,554 BigInt/LuaJIT fixed cases and 1,626 native
fixed cases; 9,315 sampler and 832 integer-sampler results with exact cursors in
native and generated-JS execution; 823 count fixtures; 288 geometric JS
value/BLIP/cursor comparisons through 2^-1000; and 261 decimal/72 chart-model
comparisons. Direct native controls add 968 sample/cursor checks, 596 model/codec
checks and 1,993 batch/selection/failure-prefix checks. Installed source/JS
consumers and the solo C ABI were checked separately from the CLI.

The corrected full statistical sanity run passed 81 checks: 4 MiB each of seeded bytes
and OS randomness, 50,000 values per tested distribution, tiny-geometric parity
(25,004 odd counts of 50,000), and rejection of all-zero/seven-bad-shape controls.
This is evidence against gross shape/bias errors, not a security certification,
IID proof or global distribution-error theorem.

The normal follow-up found a test-model error, not a port difference. The custom
normal CLI intentionally rounds samples to integers; the old analysis used
continuous-normal moments. For `--mean 5 --stddev 2`, the rounded target has
SD about 2.020726 rather than 2. The original 50,000-value SD 2.02249 is consistent
with that distinction. Three million-value CLI streams matched Zig's complete
output SHA-256 and state. Their seven-point CDF errors against the corrected
`Phi((k+0.5-5)/2)` null are 0.0005884, 0.0006054 and 0.0002264, below the nominal
0.0017884 envelope. This same-sample reinterpretation is exploratory; the
envelope does not restore post-selection coverage. The failed continuous-null
analysis remains in the [statistical data](2026-10-20-bend2-normal-statistics.json).

An unrounded million-value core run at seed81002 also matched every exact
fixed mantissa/exponent and cursor with Zig; SD was 1.999969. It overlaps the
earlier stream and is not independent confirmation. A separate seed81032
holdout, with N, continuous null, seven thresholds and alpha=.01 fixed before
running, matched every exact value/cursor and had SD 1.998787. Its largest checked
CDF error, 0.0004913, is below its own nominal 0.0016276 envelope. It was not pooled
with the exploratory checks into a combined confidence claim. These envelopes
assume IID ideal target-law draws; fixed DRBG seeds do not prove that assumption,
and seven checked points are not a measured full-CDF supremum.

Forty-five deterministic model controls now include independent 512-bit MPFR
CDF/variance references, dense valid fixtures and wrong-law/nonfinite/sparse-array
refusals. The sparse-array regression failed before its fix. This makes the
required default manifest 50 suites; the additional suite does not rerun a
million-value statistical campaign on every edit.

The first expanded default-suite run passed 48 of 49 suites. Its one failure
was the new Bend table-regeneration emitter: signed cdata remainder produced
negative exponents instead of U32 encodings. After conversion before modulo,
512-bit MPFR regeneration is byte-identical to the frozen Bend table. The
current release gate includes all 50 suites plus installed-library/package
checks; shipping verification is recorded against the exact commit.

The fresh-context reviewer caught an SDK fixture expecting seed42/d20 to finish
at cursor8 rather than cursor4, and an unqualified generated-JS constructor tag.
Independent LuaJIT returned value18/cursor4; the fixture, not the generator,
was corrected. Other resolved port/integration defects included native function
flattening, premature output-length mutation on invalid geometric/count-format
input, invalid-seek status and Bend's p=1 chart shape. No new mathematical error
was demonstrated in the existing production samplers. See [CODE_REVIEW](../../CODE_REVIEW.md).

## Measurement method and preserved failures

The pinned `performance-profile` engine owns affinity, history comparisons,
noise classification and its single allowed timing retry. There are 372 logical
cases: 216 sampler cases and 156 whole-CLI cases, each with 1/12-CPU affinity.
The linked [403 retained observations](2026-10-20-bend2-full-observations.json)
include raw samples, calibration, diagnostics, cursors, policies, exact source
identities and executable/source manifests. No baseline was approved.

The original 216-case sampler campaign produced 171 UNBASELINED, 14 INCONCLUSIVE
and 31 INVALID records. Every invalid was the engine's hard-coded 30-second
outer deadline expiring, not an observed value mismatch or source drift. One
expired on the permitted second attempt. Those original records remain intact.

A repo-local Nix patch exposes the existing runner's per-case deadline,
validates integer milliseconds in 1..3,600,000 and persists it in each definition.
It changes no numerical code, workload, retry, noise or approval policy. The
real-child regression was RED against the original engine and GREEN against
the patch; the original package checks also passed. The upstream profiler
checkout was not edited. A fresh source review verified the patch's scope and
the exact repair selection.

A separately named/versioned campaign reran exactly those 31 timed-out identities
with 300,000 ms budgets: 30 UNBASELINED and one INCONCLUSIVE. None of the original
14 noisy-only identities was selected for an extra run. Resolving only the
original timeouts gives 201 UNBASELINED and 15 INCONCLUSIVE sampler cases.
The CLI campaign produced 91 UNBASELINED and 65 INCONCLUSIVE cases. All completed
work checks passed; every record has matching before/after source fingerprints.
The 403 records represent 372 workloads, not 403 independent experiments.

The v1/v2 source fingerprints differ after the deadline/configuration repair.
The downstream executable manifest was captured from the v2 repair/CLI
environment; it is not a reconstructed binary manifest for v1. Numeric/probe
work was unchanged. Post-measurement edits correct development dependencies,
test-shell failure propagation and documentation; they do not change samplers.

### Sampler boundary

Sizes are 256/512/1024/2048, with seven CPU and monotonic-wall samples after
verified warmup and one 20 ms calibration. Each sample resets once, then advances
one continuous seeded stream. Every timed value hash is checked; the reported
last-sample cursor is checked against Zig/Rust, with short prefixes also checked
against LuaJIT. Only the last sample's cursor is published.

Parameters: normal(0,1), normalized integer 0..255, exponential rate4, Poisson
lambda5, log-normal mean-.25/stddev1.75, beta(1,3), geometric p=.25 or 2^-100.
The batch workload consumes up to 96 normalized integers per call, including
tail batches. LuaJIT uses its existing scalar API loop for that row; generated
JS consumes the public pure batch plan item by item.

These are actual API comparisons: Bend/Roc plain C ABIs, Zig's buffered C ABI,
Rust's native public API, LuaJIT modules and Bend's generated-JS facade. Each
includes its own DRBG, sampler, result consumption and per-call geometric
preparation. Rust does not get a cached geometric-preparation advantage, but
its existing 1024-byte DRBG cache, Zig buffering, Bend's uncached source and
scalar/SIMD batch differences remain real implementation differences. This is
not an isolated language-codegen experiment. Lean core timing is not isolated
in this sweep; Lean is included in the full-CLI sweep.

Median process CPU microseconds per value at N=2048, one CPU available:

| Workload | Bend native | Bend JS | Zig | Rust | LuaJIT | Roc |
|---|---:|---:|---:|---:|---:|---:|
| Normal | 11.56 | 49.25† | 0.06454 | 0.05626 | 5.228 | 5.716 |
| Normalized integer | 23.31 | 95.94 | 0.09537 | 0.09822 | 11.55 | 5.798 |
| Exponential | 106.4 | 295.6 | 0.2947 | 0.3663 | 18.47† | 8.270 |
| Poisson | 626.7 | 1353 | 1.855 | 2.239 | 90.36 | 49.73 |
| Log-normal | 93.97 | 296.8 | 0.3069 | 0.3832 | 12.41 | 8.077 |
| Beta | 134.9 | 424.9 | 0.7296 | 0.8983 | 56.07 | 26.72 |
| Geometric .25 | 39.54 | 114.1 | 0.5301 | 0.2358 | 13.00 | 19.73 |
| Geometric 2^-100 | 883.2 | 1038 | 4.969 | 4.027 | 293.1 | 395.8 |
| Normalized batch | 23.47 | 92.89† | 0.09109 | 0.05616 | 11.70 | 5.792 |

† The case remained INCONCLUSIVE after the allowed retry. Its median is
diagnostic, not a reliable ranking. All four sizes, seven samples, ranges and
CPU/wall observations remain in the linked data, including noisy outcomes.

Native Bend normal costs about 179× Zig's API and 206× Rust's here; exponential
costs about 361× Zig's. These are current implementation costs, not proof
execution or a language's limit. Native Bend's 12/1-CPU median CPU ratios across
these nine largest-size cases are 0.967..1.005: no meaningful parallel speedup
was demonstrated for this sequential embedding.

### Whole-CLI boundary

All six CLIs are measured. Preflight compares complete payload SHA-256 and
continuation JSON with LuaJIT/Zig/Rust. The checked wait4/monotonic driver then
measures two warmups and seven fresh children, checking output fold and exit
status through a fixed 64 KiB RAM sink. Timed-child stderr is suppressed, so
state equality is a preflight check, not an independent check on every child.
No random payload files or startup subtraction are used.

Parsing, startup, sampling, formatting and I/O are included. Rust uses its native
libexec executable; Lean includes its Nix Bash environment wrapper. The CLI's
custom normal rounds to integers with mean-.25/stddev1.75; exponential uses rate1.75, unlike the
core sweep. Do not subtract the two to infer formatting overhead or infer
pure Lean-core throughput from wrapper-inclusive CLI results.

Median spawn-to-exit wall milliseconds at the largest size: 65,536 input bytes
for raw/hex/base64, 4,096 output bytes for normalized binary, and 4,096 values
for the remaining rows. These are warm-host measurements, not cold-cache tests.

| Workload | Bend | Zig | Rust | Lean | LuaJIT | Roc |
|---|---:|---:|---:|---:|---:|---:|
| Raw bytes | 5.61 | 0.87 | 1.02 | 26.05† | 20.19 | 5.80 |
| Normalized binary | 97.13 | 1.05 | 1.11 | 75.62† | 67.18 | 24.82 |
| Hex | 6.27 | 1.60 | 1.28 | 29.01† | 20.36 | 6.39 |
| Base64 | 6.19 | 1.18 | 1.22 | 30.13† | 22.71 | 6.04 |
| d20 | 34.92 | 1.03 | 10.84† | 45.31 | 18.79 | 23.16 |
| Wide range | 36.98 | 1.23 | 7.32† | 61.35† | 26.40 | 23.84 |
| Normal | 56.10 | 1.33 | 8.47† | 70.69† | 45.72 | 25.40 |
| Exponential | 806.07 | 4.22 | 17.19† | 395.95 | 269.15 | 49.94 |
| Poisson | 2557.23 | 8.65 | 27.74† | 1259.79 | 553.69 | 213.06 |
| Geometric .25 | 168.83 | 3.05 | 9.56† | 103.59† | 47.64 | 86.86 |
| Geometric 2^-100 | 3540.01 | 22.09 | 27.22† | 1756.53 | 773.45 | 1682.97 |
| Log-normal | 763.54 | 4.32 | 20.36† | 365.42 | 150.86† | 49.09 |
| Beta | 920.04 | 6.14 | 24.34 | 612.80 | 383.62 | 129.22 |

The same † qualification applies. There are 65 inconclusive CLI cases across
both affinity settings; do not turn the diagnostic entries into speed claims.
Hardware was a Linux x86_64 AMD Ryzen Threadripper 3990X, with taskset affinity
of one/twelve CPUs, pinned Bend2.0.37/Clang-O3/Node24.19.0 and existing optimized
backends. Some original sampler timings overlapped the earlier full test run.
No laboratory isolation, uniform host load, GPU result or universal multiplier
is claimed. Source identities remained frozen within each campaign.

## Packaging, runtime and proof boundary

Separate flake outputs are `random-bend2`/`randomb` (CLI and aliases),
`random-bend2-ffi` (header/static/shared C ABI) and `random-bend2-lib`
(pure sources/coherent JS). Source/FFI outputs contain no CLI. The CLI links
its own archive, not another RNG, and has no compiler/SDK runtime dependency.
Bend validates canonical module-path components; Nix store hashes are not valid
module names. Copy the source SDK beside a consumer before importing it.
Use one coherent JS `index.mjs` graph, not tagged values mixed between separately
emitted graphs.

Stripped ELF payloads: Bend 1,329,216 bytes, Zig 670,544, Rust 1,103,008,
Lean 3,309,768 and Roc 449,864. Lean additionally has a 2,449-byte environment
launcher. These are executable sizes, not runtime closure sizes. Native Bend
needs libc/pthreads, not libm. Actual native execution was verified on Linux
x86_64; aarch64 Linux/macOS definitions are not native execution evidence.
No native Bend Windows/WASM support is provided.

The private serialized runtime reserves an 8 GiB corpus and 2 GiB evaluator
stack. RSS is different from this address-space reservation; the streaming
check applies the same 128 MiB resident cap as Lean. Source callbacks run
outside the evaluator mutex and tested callbacks can reenter. Fixed-work
heap high-water reuse is not a live-allocation leak census. No sanitizer,
allocation-failure, multithread/fork/unload stress or universal erasure guarantee
is claimed. Runtime exhaustion is fail-stop. Caller state wiping does not erase
temporary runtime heap copies. AUTO/SIMD batch requests use a scalar Bend plan;
list-based shuffle currently has quadratic work.

The four executed laws remain word/block encoding size, zero output and the
singleton branch. Ordinary checking and the pinned Lean-backed verdict kernel
pass with specification/implementation mutation controls. They do not establish
BLAKE3 correctness, general stream refinement, fixed arithmetic error bounds,
sampler probability laws, cryptographic security or compiler correctness.
Proof checks do not execute during sampling. U32 limbs, graph allocation,
effect interpretation, missing read-ahead and arithmetic algorithms still cost
time even though the output is C.

Separate warm-toolchain observations, after the timing sweeps, excluding
downloads/Nix waiting and the earlier kernel build:

| Phase | Wall seconds | Peak RSS KiB |
|---|---:|---:|
| Complete NativeAPI C generation | 2.65 | 309,744 |
| Clang -O3 native object compilation | 13.64 | 344,408 |
| Shared-library link | 0.36 | 40,612 |
| Existing four laws, ordinary check | 0.16 | 70,752 |
| Existing four laws, explicit kernel verdict | 0.60 | 120,328 |

These are individual build/check observations, not approved historical timing
anchors or costs of proving the entire new implementation. The generated C
was 2,789,621 bytes; the old SDK's Core-only compiler timer is not a full-port
build measurement.

## Recommendation and reproduction

Keep Bend optional as an independent executable oracle and proof-tooling example.
The full experiment is useful precisely because it measures a real core and
real CLI rather than a delegated wrapper. Current speed, serialized embedding,
erasure/OOM limits and four-law proof coverage do not support replacing the
production kernels. That conclusion has measurable criteria, not a presumption
about formal languages.

Next candidates are caller-owned deterministic read-ahead, amortized prepared
ranges/batches, and exact wide-division/remainder specialization, measured one
at a time while preserving byte order and failures. Stronger executable-linked
stream/arithmetic/sampler refinements and native platform checks remain open.

Use an existing writable external history directory:

```bash
build-budget --project random -- ./bm --bend2 --full --history-url file:///absolute/history
build-budget --project random -- ./bm --bend2 --full-cli --history-url file:///absolute/history
build-budget --project random -- nix build --no-link .#checks.x86_64-linux.random-test .#checks.x86_64-linux.library-packages .#checks.x86_64-linux.package-smoke
```

The event-addressed RNG brief is read and tracked separately in the plan
context. Stable semantic event identity and the choice of cryptographic versus
noncryptographic mixer are independent design decisions. No extra generator or
changed stream construction was added as part of this Bend evaluation.
