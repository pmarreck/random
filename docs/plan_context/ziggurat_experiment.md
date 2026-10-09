# Fixed-point Ziggurat experiment

Measured results: [96M-output analysis and timing](../reports/2026-10-08-fixed-point-ziggurat.md).
The isolated experiment is complete; coordinated production replacement is underway.
The production AUTO/SCALAR bounded-batch follow-up retained 62 timing cases;
Ziggurat remained faster on the measured normalized-integer workload. Actual
CLI throughput and native non-Linux timing remain separate requirements.
Directed finite certificates now resolve all 1,022 previously excluded
fixtures, including eight real/fixed decision deviations. They certify table
geometry and analytic series remainders, not global compiled-kernel rounding
or rejection normalization. The baseline standard-normal zero atom gives a
useful comparison target: CDF error is at least 2^−32 under ideal IID inputs.

The provisional analytical route uses elementary fixed-operation error bounds
on `exp` inputs [−8,0] and `ln` inputs [2^−55,1], then a whole-domain wedge band
bound weighted by the certified sensitivity sum below 3. Tail retries have
an exact quarter-grid acceptance lower bound; the outer fast-acceptance
probability is certified above 0.985. A deliberately loose 1e−12 error bound
for each kernel would leave room for a standard-normal CDF bound below 1e−11.
That implication still requires independently justified rounding/range,
transport and repeated-rejection lemmas; neither sampled maxima nor the
finite certificate checker proves it. Keep it provisional until those
obligations are recorded and checked durably.

The pre-0.4 standard-normal sampler computed one Box–Muller output from two
32-bit uniforms and does not cache its paired sine output. Normalized integers
used a separate Box–Muller path with million-point uniforms. Normal sampling also
feeds log-normal and the gamma samplers used by beta.

The measured evidence favors replacement, including against production AUTO
batching. The owner approved a breaking replacement on 2026-10-08: implement
Ziggurat in all five languages without a production legacy sampler or seed
compatibility layer. Version the construction and reject old continuations
explicitly rather than silently reinterpret their byte cursor. Keep Box–Muller
only as a historical experimental control so earlier measurements remain
reproducible. Whole-domain rounding and distribution proofs remain separate
open obligations; the earlier Box–Muller sampler did not meet that bar either.

## Candidate and controls

Use 256 equal-area strips, independently generated high-precision constants,
integer thresholds, and the existing portable fixed-point kernels for rare
PDF and tail work. Allocate disjoint source bits to strip, sign and coordinate.
Restart strip selection after wedge rejection. Keep tail rejection local to
the selected tail. Do not substitute a trapezoid approximation.

Check every strip's geometry against MPFR, directed fast/wedge/tail cases,
random-source errors and byte consumption, and deterministic statistical checks
against an external normal CDF. Include controls that fail on wrong geometry,
shared-bit allocation and incorrect rejection restart. Statistical acceptance
is evidence, not a distribution-law proof. Quantization and transcendental
error still need explicit analysis; higher coordinate precision alone does not
establish a stronger distribution bound.

## Measurements and decision

Compare scalar Box–Muller and Ziggurat for normal, normalized integers,
log-normal and beta, separately measuring computation and computation plus
decimal formatting. Use optimized builds, equal output counts and seeds,
in-process warmup, checked CPU/monotonic clocks, raw repeated samples, and
single-core/12-core affinity cohorts. Use the shared performance-profile engine
and external history; a new cohort is unbaselined, never self-approved.

Promotion requires a repeatable practical workload speedup, no demonstrated
quality regression, satisfactory boundary/error checks, and exact deterministic
cross-language reproduction. If any part remains inconclusive, retain the
prototype and document the blocker instead of calling it production-ready.

References: [Marsaglia and Tsang (2000)](https://www.jstatsoft.org/article/view/v005i08),
[Doornik (2005)](https://www.doornik.com/research/ziggurat.pdf), and
[Colin Green's implementation discussion](https://heliosphan.org/zigguratalgorithm/zigguratalgorithm.html).
