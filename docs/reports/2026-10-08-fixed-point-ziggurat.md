# Fixed-point Ziggurat: measured experiment

2026-10-08. Base revision `a758c902143f`. Production samplers, stream versions,
continuation states and public library APIs are unchanged.

This is the historical experiment report. The later
[production migration and SIMD report](2026-10-08-ziggurat-production.md)
records the coordinated 0.4.0/schema-3 replacement and actual CLI measurements.

## Decision

The isolated Zig candidate is substantially faster than scalar production
Box–Muller, the paired-output control and the production AUTO batch path on
the measured normalized-integer workload.
Its 96-million-output campaign passed the predeclared distribution diagnostics.
This supports pursuing a coordinated replacement;
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

The frozen DKW threshold was **0.00214359**, computed using a 48-case allocation
and a family budget of 1e−6. This is conservative for the 32 unpaired scalar
and candidate cells. Joint independence of finite-grid paired outputs has not
been established, especially across downstream rejection boundaries, so their
16 pooled cells retain the same threshold only as diagnostics. This corrects
the initial all-48-cells IID interpretation; no thresholds or data changed.
Maximum observed absolute CDF discrepancies over the four seeds were:

| Shape | Production Box–Muller | Paired control | Ziggurat |
|---|---:|---:|---:|
| Normal | 0.000770596 | 0.000794929 | 0.000733031 |
| Normalized integers | 0.000813331 | 0.000784709 | 0.000724869 |
| Log-normal | 0.000770596 | 0.000794929 | 0.000733031 |
| Beta(1,3) | 0.000700354 | 0.000646291 | 0.000849527 |

Normal checks also covered sign balance, both sides of all 255 strip seams,
two-sided tails at 1–5 standard deviations, mean, second/fourth moments,
lag-1/lag-2 covariance, and occupancy collisions in 32-bit CDF cells. All passed.
The unpaired seam/tail/count family has a separate Bernstein/binomial budget
of 1e−6 over at most 100,000 checks (8,208 actually used). Under the IID
target-law nulls, the combined calibrated-family false-alarm budget is at most
2e−6. IID source words alone do not establish correct target probabilities.
Paired, moment, serial and collision diagnostics share no claimed global
significance level. The occupancy check is not Doornik's
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
the directed-certificate follow-up below later resolved those point fixtures,
including eight deviations. Their exclusion was never counted as a pass.
The whole-domain disagreement-mass bound remains separate and unresolved.

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

These first-run formatting cases perform decimal conversion and checksum consumption, not CLI
startup, parsing or writes to a sink. The baseline is scalar, not the optimized
bounded-batch path; the second-run comparison below addresses that limitation.
The paired control changes stream/caching semantics and
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
disagreement mass; compare actual CLI sinks; port exact words,
rounding and rejection consumption to LuaJIT, Rust, Lean and Roc; retain the
unchanged common Bash oracle across all five; and version/reject incompatible
continuation states. Current state schema version is 2; informational `rv`
alone does not enforce stream compatibility. Native non-Linux execution also
remains to be demonstrated. Total variation against a continuous law would be
1 for any finite discrete sampler and is not the appropriate quality metric.

The profiling command returns exit 3 for a new, unbaselined cohort; that is not
a historical performance pass or a failed computation check.

## Follow-up: production bounded batches

A second source-frozen run measured all 54 original cases again and added
eight production bounded-batch cases. AUTO and forced SCALAR call the actual
`randomz_normal_int_batch` ABI with caller-owned storage capped at 1,024 values.
Their outputs must match independently consumed scalar FFI output arrays;
the benchmark cannot supply its own expected checksum. Counts 0, 1, 3, 4, 7,
1,023, 1,024, 1,025 and 2,051 exercise lane/chunk boundaries in required tests.
Wrong checksums fail for both modes. The recorded AUTO capability flag was
true in all four AUTO timing cases, using the production AVX2 dispatcher.

Median process CPU nanoseconds per normalized integer, seed 42, 16,384 outputs:

| Allowed CPUs | Work | Forced SCALAR batch | AUTO batch | Ziggurat | AUTO / Ziggurat |
|---|---|---:|---:|---:|---:|
| 1 | Sampler + checksum | 671.8 | 515.9 | 158.0 | 3.27× |
| 1 | + decimal formatting | 728.3 | 572.5 | 250.6 | 2.28× |
| 12 | Sampler + checksum | 670.9 | 518.2 | 157.5 | 3.29× |
| 12 | + decimal formatting | 728.6 | 580.7 | 218.6 | 2.66× |

Every candidate observation was faster than every matching AUTO observation.
No project builds ran concurrently with timing, but other machine workloads
were active. Grouped execution and frequency drift limit the precision of
these ratios. One scalar normal growth case exceeded the variability policy
on its first attempt; the shared engine's single permitted retry completed.
The [second-run receipts](2026-10-08-ziggurat-batch-measurements.json) retain that
noisy attempt as well as all 62 final observations and runtime capability flags.
All final verdicts are UNBASELINED, with no automatic baseline approval.

These are library calls plus digest consumption, optionally using the same
19-place fixed formatter for all algorithms. They still do not measure CLI
startup, argument parsing, the CLI's 18-place default, integer-specific output
formatting or sink writes. The batch follow-up resolves the scalar-only
baseline limitation for the 0..255 workload, not the remaining CLI or
cross-platform performance limits. It adds no independent statistical draws
to the original 96M-output campaign.

## Follow-up: finite directed certificates

The required test now runs an independent MPFR-512 directed-interval
[certificate checker](../../experiments/ziggurat_certificate.lua). Unlike the
sampled kernel-error sweep, it encloses each of the 256 stored thresholds and
finite geometric quantities. It checks positive decreasing widths, increasing
heights below the true PDF, strip-area weight discrepancy below 2^−53,
missing-cover mass below 2^−60, and the base rectangle/tail mixture discrepancy
below 2^−54. It also checks exact integer inequalities for the analytic
atanh/Taylor remainder terms. These last checks do not certify rounding
propagation through the compiled kernels. Deliberately corrupted threshold and
height checker inputs fail.

Directed intervals resolve all 1,022 previously excluded point fixtures.
Eight signed wedge cases differ from ideal-real decisions: strips 73, 206,
213 and 223, both signs, magnitude `j=k_i` and height coordinate `2^55−1`.
Their exact ideal gaps are positive, approximately 1.92e−19 through 1.09e−18;
the compiled sampler rejects and consumes the next header. The checker prints
exact word fixtures and hexadecimal interval endpoints. The two tail-equality
fixtures accept as specified. Resolving these points is not a bound on the
mass of every possible finite-precision disagreement, and these eight
deviations must not be described as exact real-arithmetic agreement.

The checker also verifies the production normal ABI returns canonical zero
for `U2=1/4` and `3/4`, with `U1=1/2`, mean zero, standard deviation one and
exact source requests of 4,4 bytes. The cosine reduction is exactly zero at
those two angles regardless of the radius. Under ideal IID U32 input, this
gives the baseline a zero atom of at least 2^−31 and therefore Kolmogorov
distance at least 2^−32 from a continuous normal law. This conclusion combines
the executed witnesses with the source formula; samples alone cannot establish
the atom's probability. It does not apply directly to the rounded integer law.

A proposed whole-domain CDF bound still depends on source-linked primitive
rounding, reachable-range and rejection-coupling lemmas. Review corrected one
strict endpoint premise: the logarithm's reduced denominator error can equal
2^−62, rather than always being strictly smaller. No universal candidate CDF
bound or accuracy-superiority certificate is claimed here. The finite checker
explicitly reports that distinction, and the promotion item stays open.

References: [Marsaglia–Tsang algorithm](https://www.jstatsoft.org/article/view/v005i08),
[Doornik's independence and collision analysis](https://www.doornik.com/research/ziggurat.pdf),
[paired Box–Muller comparison discussion](https://heliosphan.org/zigguratalgorithm/zigguratalgorithm.html),
and [MPFR precision and rounding API](https://www.mpfr.org/mpfr-current/mpfr.html).
