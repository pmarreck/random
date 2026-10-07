# Distribution proof certificates: first production-linked results

These are analytic proofs, not claims inferred from a histogram, a large sample,
or cross-implementation agreement. They are a first milestone, **not completion
of the distribution-proof plan**. No production sampler or seeded stream was
changed to obtain them.

## Proven bounds

CDF error means the supremum of the absolute difference between the sampled
CDF and the specified ideal CDF. An error of epsilon bounds the difference in
probability for every lower-threshold event. It does not assert total variation
epsilon between an atomic output and a continuous distribution.

| Production core operation | Certified domain | CDF deviation | Failure accounting |
| --- | --- | --- | --- |
| Fractional uniform | Every available U32 input word | At most 2^-32 = 1/4294967296, approximately 2.3283064365e-10; tight at zero | Every successful `nextU32` yields an actual canonical sample at the source's returned state |
| Nonzero-uniform helper | Every available U32 input word | At most 2^-32 against continuous U[0,1] | Zero becomes 1/2^32; no redraw or hidden validation rejection |
| Geometric failures-before-success | Every canonical fixed-point probability p in [1/2,1), R independent available eight-byte trials | At most (1-p)^R, hence at most 2^-R | Exact exhaustion probability (1-p)^R; successful masses are p(1-p)^k for k<R, zero above the cap |

For the geometric domain, the production preparation path, strict UInt64
threshold and public `sampleWith` interpretation are included. The threshold
probability equals the requested **represented fixed-point probability**, not
an idealized unrounded decimal string. The theorem is universal over its full
63-bit canonical mantissa interval; it does not enumerate that interval.

`direct_sampler_64` demonstrates the numerical geometric bound for 64 trials:
CDF deviation and exhaustion probability are at most
1/18446744073709551616, approximately 5.4210108624e-20. This is a corollary of
the universal proof, not an observed maximum. It is not a change to the CLI's
actual available-cursor budget.

Failures remain a separate `none` outcome. The finite-cap CDF is a
sub-probability CDF of successful results, not a renormalized conditional law.
For discrete geometric outputs, the proved threshold events are `result < n`
for every natural n; these determine the entire discrete CDF. Its exact form
is 1-(1-p)^(min(n,R)). Arbitrary external I/O failures are not bounded without
a fault/availability model.

## Production linkage

- `Fixed.divMagnitude_exact` proves that the actual 62-step long-division
  implementation equals floor(a*2^62/b), for every numerator and every positive
  denominator.
- `Fixed.divMagnitude_rounding` derives its universal scaled-mantissa error:
  nonnegative and strictly below one, from the actual quotient and remainder.
  This is a common arithmetic building block, not a completed transcendental
  sampler error budget.
- `Fixed.uniform_word_real` connects the actual normalization/division
  expression to n/2^32 for all words, including zero.
- `Uniform.uniform_of_read` and `nonzero_of_read` prove existence and exact
  values of actual sampler outputs after an available input word. This avoids
  a vacuous theorem that describes only successes while permitting arbitrary
  validation failures.
- The production CDF definitions count preimages of those actual arithmetic
  expressions. They are connected to the exact finite-grid CDF proofs.
- `Geometric.uniform_word_threshold` counts the words below every UInt64
  threshold symbolically. `uniform_source_observer` connects that count to the
  actual byte-count check and decoded-word comparison.
- The actual monadic base loop is interpreted with probability mass functions.
  Its finite-fuel success/failure laws are then linked through the actual
  preparation and public sampler in `direct_sampler_bound`.

## Assumptions and remaining obligations

Probability is over independent uniform source words. A fixed deterministic
seed produces a fixed sequence, not independent mathematical random variables.
Substituting the BLAKE3 DRBG for the ideal source relies on its external
cryptographic security assumption. OS entropy quality, adversarial source
faults and DRBG cursor availability are not proved here.

The geometric theorem covers `sampleWith` with a source that can supply the
whole R-trial cap. It does not yet refine the stateful `sample` function's
cursor-derived fuel calculation or an early exhausted read. The 64-trial
example must not be advertised as an unconditional CLI or end-of-cursor bound.

The geometric source contract explicitly supplies well-sized eight-byte reads
whose decoded UInt64 words are uniform. It excludes malformed-read failures;
it does not assume the output distribution or a desired numerical error bound.
The probability-mass-function interpretation supplies fresh independent draws
at each bind. The runtime compiler and platform source remain trust boundaries.

Still open:

- Geometric p<1/2: production recurrence rounding, accumulated parity error,
  tiny-rate fair-tail approximation and resource accounting for reconstruction.
  Ideal even/odd factorization identities are proved, but are not a production
  certificate for this domain. The existing analytic 770*2^-62 budget has not
  become a universal Lean certificate.
- Certain geometric p=1 already has a structural no-draw `certain_zero`
  theorem; the new direct-domain certificate does not include a preparation
  proof for that separate branch.
- Normal, bounded normalized integers, exponential, Poisson, log-normal and
  beta: full production-linked numerical and rejection/error certificates.
- Bounded uniform integer rejection: its probability law is not covered by the
  fractional-uniform theorem.
- Decimal parameter parsing and displayed/truncated decimal output: any claim
  against the original decimal text or formatted result needs these additional
  projections.
- Universal cross-language refinement: Lean proofs do not themselves prove the
  Zig, Rust, LuaJIT or Roc programs. The same complete Bash oracle and exact
  differentials remain mandatory empirical controls for those implementations.

## Reproduction and trust controls

Run `nix develop .#proofs -c bash tests/distribution_proof_test`. The complete
`./test` entry point also requires this gate; it is not an opt-in reduced Lean
matrix. The existing full shared CLI oracle is unchanged.

The proof layer pins Lean 4.30.0 and mathlib revision
`c5ea00351c28e24afc9f0f84379aa41082b1188f`. Nix hash-pins the mathematical
import artifacts and their source dependencies. This is a separate closure;
CLI and ordinary core-library packages do not acquire mathlib. The optional
`random-lean-proofs` flake package exports proof sources and compiled modules.

Our proof modules and independently restated contract types elaborate with
trust level zero and warnings as errors. The gate rejects unchecked declaration
shortcuts and audits headline theorem dependencies. Current headline axioms are
exactly `propext`, `Classical.choice` and `Quot.sound`, Lean's standard axioms;
there are no project-specific probability/error axioms. Imported precompiled
mathlib artifacts, Lean's kernel and the runtime compiler remain distinct trust
boundaries.

The mandatory negative controls compile private mutated copies of production
code. They reject a division loop shortened to 61 bits, a constant-zero uniform
sampler, and a geometric success count changed from failures to trials. Small
exact witnesses accept the unmodified code first. Missing imports and other
infrastructure errors do not count as successful mutation detection. Generated
fixtures use the temporary directory and move to Trash.

Independent mathematical review has already corrected overstatement of the
ideal parity identities and required actual source/preparation linkage, exact
headline contracts, explicit exhaustion mass and mandatory mutation invocation.
Further domains must meet the same standard before this report gains new bounds.

## Verification of this milestone

The complete 41-suite FAST runner passed on Linux x86_64, including the same
full Bash CLI expectations for LuaJIT, Zig, Rust, Lean and Roc. The deep-only
kernel JIT/interpreter differential also matched over 60,000 iterations.
Standalone Nix proof-package, package-split and installed library-consumer
checks passed; the latter imports the shipped compiled proof artifacts.

A fresh-context reviewer independently ran the proof gate, all 21 axiom audits,
all three mutation controls and the installed proof consumer. No mathematical
correctness or vacuity defect was found in the stated domain. Two low workflow
findings were corrected: the isolated proof shell now exists on every declared
native system, and the intentionally unused mutant draw no longer emits an
expected warning. Other warnings remain errors. The package-split check also
requires the proof shell on every supported system.

Darwin and ARM64 shell attributes are evaluation-checked, not native proof runs
on those hosts. Exact pushed-commit CI remains a separate shipment control.
