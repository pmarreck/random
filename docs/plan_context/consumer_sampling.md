# Consumer sampling requests

An October 4 consumer request needs deterministic shaped positions over ranges
as large as about 2^40, plus sparse distinct sampling and weighted choice.
These remain follow-up APIs. The Roc port and the coordinated Ziggurat migration
are now shipped in release 0.4.0. Existing replay contracts still need explicit
construction identifiers when a new API changes integer conversion or rejection.

The proposed surfaces need contracts before implementation:

- Parameterized bounded integers: normal mean/stddev, anchored exponential,
  range-mapped beta and log-normal. Define integer conversion, conditioning on
  the inclusive bounds, rejection/work limits, exact byte consumption and
  insufficient-support errors. The consumer's original million-step Box–Muller
  concern was superseded by the 0.4.0 Ziggurat construction's 55-bit coordinates.
  Existing normalized integers still fix the center and width/6 scale; they do
  not supply the requested independently parameterized bounded sampler.
- Uniform k-distinct values in [0,n): O(k) storage via sparse Fisher-Yates or
  Floyd, with explicit k>n refusal. Shaped distinct sampling additionally needs
  duplicate handling and narrow-support/work-limit policy.
- A u64 geometric convenience conversion must fail on overflow, never clamp or
  wrap. Canonical Fixed uses a separate binary exponent, so probabilities near
  1e-12 are representable; it is not limited to a fixed absolute quantum.
- Weighted index and direct Zig Source/Drbg entrypoints should share the same
  pure selection logic as any C ABI. Roc now supplies a weighted-index API;
  that alone does not establish the requested Zig-native consumer surface.
- Each new construction needs an identifier and independent frozen vectors
  covering seed, parameters, output and next byte cursor. Record the existing
  implementation revision separately from the construction identifier.

Keep LuaJIT-first contracts and all-language comparisons. Do not claim full
u64 endpoints when the specified API admits only the exact-position domain.

## Reconciliation, 2026-10-14

The October 4 request is preserved here and in PLAN. The first contract milestone
should specify the existing exact-position domain (including about 2^40-sized
ranges), integer rounding, bounded work, failure effects and construction IDs.
Full u64 shaped endpoints and shaped distinct sampling remain separate extensions;
neither may be inferred from a checked u64 geometric conversion. The consumer
must retain its implementation revision alongside each construction identifier.
