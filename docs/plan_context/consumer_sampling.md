# Consumer sampling requests

An October 4 consumer request needs deterministic shaped positions over ranges
as large as about 2^40, plus sparse distinct sampling and weighted choice.
These are follow-up APIs, not a reason to change frozen sampler streams during
the Roc port.

The proposed surfaces need contracts before implementation:

- Parameterized bounded integers: normal mean/stddev, anchored exponential,
  range-mapped beta and log-normal. Define integer conversion, conditioning on
  the inclusive bounds, rejection/work limits, exact byte consumption and
  insufficient-support errors. Existing normal-integer sampling uses a frozen
  million-step uniform construction; a higher-resolution construction needs a
  distinct identifier/API rather than silently changing replay.
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
