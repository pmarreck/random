# Fixed-point Ziggurat: measured experiment

2026-10-08. Base revision `a758c902143f`. Production samplers, stream versions,
continuation states and public library APIs are unchanged.

## Decision

The isolated Zig candidate is substantially faster than scalar production
Box–Muller and a paired-output Box–Muller control on the measured machine.
Its 96-million-output campaign detected no distribution regression at the
predeclared sensitivity. This supports pursuing a coordinated replacement;
it does not establish superior accuracy, full CLI throughput, or a completed
five-language migration. Do not promote this prototype by changing one
implementation's stream alone.

## Statistical evidence

Before measuring, the analysis fixed four seeds (42, 700, 123456789 and
3735928559), three algorithms, four shapes and 2,000,000 outputs per cell:
48 cells, **96,000,000 outputs**. Samples, sort tables and occupancy counts stayed
in RAM. An earlier overlapping normal-only run is not counted as independent
additional evidence.

Normal and log-normal intentionally reuse the same underlying seed streams;
their outputs are correlated, not independent extra draws. The simultaneous
union-bound calibration does not require independence between test cells.

Shapes: normal with mean −0.25 and standard deviation 1.75; normalized integers
0..255; the corresponding log-normal; and Beta(1,3). The production scalar
baseline calls the real Zig C ABI. Candidate normals feed the same fixed-point
downstream formulas. This is not a sweep of every supported parameter.

Full empirical CDF checks used independent formulas: normal `erfc`, its
log-normal transformation, the conditioned rounded-normal integer CDF, and
`1 − (1 − x)^3` for Beta(1,3). The diagnostic libm normal CDF was independently
checked against MPFR at 161 inputs, within 2e−15.

The predeclared simultaneous DKW envelope was **0.00214359** for 48 checks
with a family budget of 1e−6. Maximum observed absolute CDF discrepancies over
the four seeds were:

| Shape | Production Box–Muller | Paired control | Ziggurat |
|---|---:|---:|---:|
| Normal | 0.000770596 | 0.000794929 | 0.000733031 |
| Normalized integers | 0.000813331 | 0.000784709 | 0.000724869 |
| Log-normal | 0.000770596 | 0.000794929 | 0.000733031 |
| Beta(1,3) | 0.000700354 | 0.000646291 | 0.000849527 |

Normal checks also covered sign balance, both sides of all 255 strip seams,
two-sided tails at 1–5 standard deviations, mean, second/fourth moments,
lag-1/lag-2 covariance, and occupancy collisions in 32-bit CDF cells. All passed.
The seam/tail/count family has a separate Bernstein/binomial budget of 1e−6
over at most 100,000 checks. The combined calibrated-family budget is at most
2e−6; extra moment, serial and collision diagnostics do not share a claimed
global significance level. The occupancy check is not Doornik's
30-dimensional TestU01 collision test.

For standardized `z = (sample + 0.25) / 1.75`, the candidate's 8,000,000 normal
outputs included 502 with `|z| > 4` (ideal expectation approximately 506.74)
and 2 with `|z| > 5` (expectation approximately 4.59).
The latter has far too few events to establish
accurate extreme-tail probabilities. The four standardized candidate runs had mean
between −0.000880466 and 0.000573854, second moment between 0.998104 and 1.00032,
and lag covariances below 0.001 in magnitude.

An actual negative control adding 0.02 to standardized normal outputs failed
the full-CDF gate. The envelope was not adjusted after observing results.

These probability calibrations assume ideal independent draws. Fixed-seed
cryptographic pseudorandom sequences are deterministic; the tests do not prove
that assumption, cryptographic security, independence at every lag, or errors
below the sampling sensitivity. A passing hypothesis test does not prove the
null hypothesis. Smaller observed CDF discrepancy is not proof of better accuracy.

## Boundary and numerical evidence

The implementation uses 256 strips, a 55-bit coordinate grid and integer-only
runtime arithmetic. A supplied big-endian U64 allocates low 8 bits to the strip,
bit 8 to the sign, and high 55 bits to the coordinate. These fields do not
overlap. Ordinary uniforms are `j/2^55`; tail uniforms are `(j+1)/2^55`, avoiding
`ln(0)` without duplicating the lowest grid point. Fast acceptance is strict
`j < k`. Wedge rejection restarts with a fresh header; tail rejection retains
its sign and draws two new tail words. There is no cached paired output.

MPFR-generated stored constants regenerate identically at 256 and 512 bits.
Thresholds use stored quantized widths rather than unquantized ratios.
Against independent 512-bit calculations, measured maximum absolute errors were:

| Check | Maximum observed error | Diagnostic gate |
|---|---:|---:|
| Stored strip area | 9.46722704e−20 | 2^−57 |
| Stored PDF height | 2.21017804e−19 | 2^−58 |
| Compiled fixed `exp`, 4,335 inputs | 2.19272311e−18 | 2^−55 |
| Compiled fixed `ln`, 3,640 inputs | 1.02232707e−17 | 2^−55 |

The logarithm sweep includes 65 mantissas at each of 56 exponents, not just
powers of two. These are measured maxima, **not universal certified bounds**.

Five directed unit tests cover all strips/signs, disjoint coordinate bits,
threshold neighbors (including 2^53 neighbors), wedge restart, tail-local
retry, source errors and exact consumed-word counts. Independent MPFR scripted
acceptance decisions passed 6,700 cases. Another 1,022 near-boundary cases were
explicitly excluded at separation margins 1e−15 for wedges and 1e−14 for tails;
those exclusions remain an unresolved numerical-analysis limit, not passes.

Required mutation controls reject wrong coordinate bits, reversed fast/tail
comparisons, and corrupted threshold/geometry/PDF checker inputs. A wrong work
checksum also fails. The fresh-context reviewer reproduced a skipped-work
benchmark that originally passed; after the external checksum fix, the same
mutation failed. The controls remain reachable from the default `./test`.

## Performance evidence

Native x86_64 Linux, AMD Ryzen Threadripper 3990X, Zig 0.16.0, ReleaseFast.
Each fixed case generated 16,384 outputs with seed 42, two in-process warmups
and seven recorded CPU/wall observations. Fresh deterministic state was used
per batch. The shared performance engine ran 48 fixed cases and six growth
cases, without concurrent builds. Every case completed in one attempt, passed
its independently prepared work checksum, and retained identical before/after
source fingerprints.

Median process CPU nanoseconds per output, one-CPU affinity:

| Workload | Production | Paired control | Ziggurat | Production / Ziggurat |
|---|---:|---:|---:|---:|
| Normal, sampler | 618.4 | 447.9 | 70.4 | 8.78× |
| Normal, + decimal formatting | 1130.4 | 954.2 | 563.7 | 2.01× |
| Normalized integer, sampler | 662.8 | 537.8 | 159.3 | 4.16× |
| Normalized integer, + formatting | 737.4 | 614.4 | 226.0 | 3.26× |
| Log-normal, sampler | 857.9 | 683.8 | 276.4 | 3.10× |
| Log-normal, + formatting | 1362.1 | 1180.8 | 772.5 | 1.76× |
| Beta, sampler | 1828.9 | 1478.3 | 691.0 | 2.65× |
| Beta, + formatting | 2327.5 | 1955.1 | 1173.9 | 1.98× |

Every candidate observation was faster than every corresponding scalar
baseline observation in these one-CPU cases. The 12-CPU allowed-affinity cohort
gave comparable results; workloads remained single-threaded, so this is not
12-thread scaling. Normal growth from 4,096 through 32,768 outputs was
approximately linear for all three algorithms. Grouped execution does not
eliminate temporal drift; these large effects warrant follow-up rather than
a precise universal speedup claim.

All 54 engine verdicts are **UNBASELINED**, because no previously accepted
historical cohort baseline existed. No baseline was automatically approved.
The table is a within-run algorithm comparison, not a historical regression
gate pass. Sanitized raw CPU/wall samples, aggregate statistics and source
fingerprints are retained
in [measurement receipts](2026-10-08-ziggurat-measurements.json); private machine
and filesystem provenance remains only in external local history.

Formatting cases perform decimal conversion and checksum consumption, not CLI
startup, parsing or writes to a sink. The baseline is scalar, not the optimized
bounded-batch path. The paired control changes stream/caching semantics and
uses its finer normal grid for normalized integers. These limitations must be
addressed before claiming production end-to-end superiority. The candidate
adds approximately 10 KiB of constant strip data. Its fast path requests eight
DRBG bytes, as does the current normal sampler; slow paths request more. This
experiment establishes no general entropy-consumption improvement.

## Reproduction and remaining promotion work

Local verification passed all 42 default suites in the hermetic Nix
`random-test` check, including the full five-implementation Bash CLI oracle.
The separate deep JIT/interpreter comparison also passed 60,000 iterations.
Experiment shells evaluate for x86_64 Linux, aarch64 Linux and aarch64 Darwin;
that evaluation is not native execution evidence for the latter two.

```bash
nix develop .#ziggurat -c tests/ziggurat_test
./stats --ziggurat 2000000
# Use an existing external metadata-history directory, not the repository.
PERFORMANCE_HISTORY_URL="file://$HOME/.local/state/performance-history" ./bm --ziggurat
```

Bounded correctness controls belong to `./test`; the larger statistical and
timing campaigns are explicitly opt-in. They do not write sampled payloads
to disk. New MPFR/performance dependencies are experiment/test tools, not
production runtime dependencies.

Before promotion: establish an explicit finite-grid/transcendental-error
budget in a useful CDF or transport metric; resolve the excluded decision
boundaries; compare optimized batched and actual CLI sinks; port exact words,
rounding and rejection consumption to LuaJIT, Rust, Lean and Roc; retain the
unchanged common Bash oracle across all five; and version/reject incompatible
continuation states. Current state schema version is 2; informational `rv`
alone does not enforce stream compatibility. Native non-Linux execution also
remains to be demonstrated. Total variation against a continuous law would be
1 for any finite discrete sampler and is not the appropriate quality metric.

The profiling command returns exit 3 for a new, unbaselined cohort; that is not
a historical performance pass or a failed computation check.

References: [Marsaglia–Tsang algorithm](https://www.jstatsoft.org/article/view/v005i08),
[Doornik's independence and collision analysis](https://www.doornik.com/research/ziggurat.pdf),
[paired Box–Muller comparison discussion](https://heliosphan.org/zigguratalgorithm/zigguratalgorithm.html),
and [MPFR precision and rounding API](https://www.mpfr.org/mpfr-current/mpfr.html).
