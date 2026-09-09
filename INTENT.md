# Intent

Provide fast, usable, embeddable cryptographically secure random generation
whose deterministic output is identical across supported languages, operating
systems, and CPU architectures, including nonlinear distributions.

Peter established this goal through the LuaJIT oracle, Zig/C, Rust, and Lean 4
implementations. Libraries serve downstream applications; the matching CLIs
also serve shell users and exercise the public library boundaries.

## Constraints and verification

- Preserve seeded bytes, distribution evaluation order, rejection order, and
  portable continuation cursors when optimizing. Fixed-point integer arithmetic
  avoids platform libm differences. Speed does not justify lowering quality.
- Keep computation in reusable cores, with I/O and terminal transport at the
  edges. Zig's C CLI exercises its public C ABI. Callers own generator state.
- Bound streaming memory independently of requested output size. Prefer RAM,
  pipes, and digest comparisons over temporary payload files.
- Use recommended OS entropy sources and fail closed on entropy failure.
  Seed expansion does not create entropy; replay state is sensitive, and the
  generator does not promise recovery after state compromise.
- Lead changes with failing tests, retain independent implementation oracles,
  compare exact intermediate values and final bytes, and test cross-language
  resumption. Lean proofs must distinguish proved invariants from tested or
  assumed behavior.
- Measure release performance before and after changes, including end-to-end
  workloads. Portable scalar fallbacks remain available for optimized paths.

The [README](README.md) describes supported surfaces and security limits;
[PLAN](PLAN.md) records implementation work and platform gaps. SIMD production
promotion was requested on 2026-09-09 with these constraints unchanged.
