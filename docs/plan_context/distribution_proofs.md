# Distribution proof obligations

The requested result is an analytic, kernel-checked account of sampler quality,
not a larger statistical campaign. Existing structural proofs and exact
cross-language output tests do not establish a probability law.

## Acceptance contract

- Cover uniform, normal, normalized bounded integers, exponential, Poisson,
  log-normal, beta and geometric failures-before-success.
- State the ideal law and admissible parameter domain for each operation.
  Normalized integers target rounded, range-conditioned normal samples rather
  than an unrestricted continuous normal distribution.
- Define probability over independent uniform input words. A fixed seed produces
  a fixed sequence; replacing the ideal source by the BLAKE3 DRBG retains an
  external cryptographic assumption, not a theorem of statistical independence.
- Connect ideal algorithms to actual production definitions. A theorem about a
  disconnected model, or a theorem assuming the desired conclusion, does not
  discharge the implementation obligation.
- For continuous targets, use uniform CDF deviation with explicit parameter
  dependence. Do not use small total-variation claims between atomic output and
  a continuous law. Discrete targets can additionally use total variation.
- Account for input-grid resolution, zero replacement, fixed-point arithmetic,
  rounding, range conditioning, rejection limits, source failures and cursor
  exhaustion. Report failure probability separately instead of silently
  conditioning it away.
- Publish actual numerical bounds only when all supporting inequalities have
  been proved. Do not report empirical maxima, a vacuous bound of one, or
  user-supplied unproved error budgets as production certificates.
- A proof of Lean behavior does not automatically prove Zig, Rust, LuaJIT or
  Roc. Retain exact differentials and identify any missing universal refinement
  or equivalence obligation explicitly.
- Keep proofs in a CLI-free proof layer. Do not add a large mathematical runtime
  dependency to consumers of the executable core merely to elaborate proofs.
- Gate theorem statements, trust-zero elaboration, dependency/axiom audits and
  negative mutation controls through the complete Bash test entry point and Nix.

## Ordered work

1. Audit production algorithms and existing theorem scope; identify endpoint,
   finite-precision and parameter-domain obstacles before claiming bounds.
2. Pin compatible mathematical tooling through Nix/Lake and establish a failing
   probability-law contract and an independently falsifiable proof gate.
3. Prove common finite-source and error-composition lemmas, then geometric and
   exponential production-linked results.
4. Extend the results to normal and bounded normalized output, log-normal,
   Poisson and beta, with actual arithmetic and rejection error budgets.
5. Independently review the mathematical claims and control strength, rerun the
   same CLI oracle, and publish a proved/tested/assumed/open claim matrix.

## Preserved behavior and open decisions

The initial proof work does not change seeded streams or weaken acceptance
expectations. If a proof reveals an unacceptable bias or unsupported advertised
domain, report the counterexample before deciding on a versioned sampler change.
Formatting and terminal charts are separate from the sampled-value law; any
claim about displayed decimals must add the formatting projection explicitly.

## First production-linked milestone

The [certificate report](../reports/2026-10-07-distribution-proof-certificates.md)
records universal fractional/nonzero-uniform CDF bounds, exact production
division/rounding and direct geometric preparation/source/sampler bounds for
p in [1/2,1). The entire plan remains open: smaller geometric probabilities,
the other nonlinear samplers, bounded integer rejection, formatting and
universal cross-language refinement are not discharged by that milestone.
