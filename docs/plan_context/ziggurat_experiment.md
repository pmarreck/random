# Fixed-point Ziggurat experiment

Measured results: [96M-output analysis and timing](../reports/2026-10-08-fixed-point-ziggurat.md).
The isolated experiment is complete; coordinated production promotion remains open.

The current standard-normal sampler computes one Box–Muller output from two
32-bit uniforms and does not cache its paired sine output. Normalized integers
use a separate Box–Muller path with million-point uniforms. Normal sampling also
feeds log-normal and the gamma samplers used by beta.

Switching algorithms is authorized if the replacement is superior. This is an
experiment first: production streams remain unchanged until the evidence and
five-language implementation are ready. Stream compatibility is not a veto;
promotion must version the construction and reject incompatible continuations
explicitly rather than silently reinterpret their byte cursor.

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
