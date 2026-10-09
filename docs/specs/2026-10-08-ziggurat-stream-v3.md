# Ziggurat stream contract, version 3

Release 0.4.0 replaces Box–Muller in LuaJIT, Zig, Rust, Lean 4 and Roc. This is
an intentional deterministic-stream break for normal, normalized integers,
log-normal and beta. BLAKE3's key derivation and byte stream are unchanged.
Uniform, exponential, Poisson and geometric keep their earlier sequences.
CLI state uses `sv:3`; older schemas fail before producing output. `rv` remains
informational, not a substitute for the stream/schema gate.
Low-level library key/cursor snapshots are deliberately unversioned; callers
persisting them must also pin the sampler construction/release in their own
format. The CLI's schema gate cannot validate a bare FFI snapshot.

## Standard normal

The runtime uses only normalized fixed-point integer arithmetic and 256 stored
strips. `experiments/ziggurat_generate.lua` solves the equal-area recurrence
with MPFR and emits all five tables without host floating-point conversion.
Stored widths/heights use the existing 63-bit mantissa representation.
Thresholds are `floor(2^55 * next_stored_width / stored_width)`.

Each header is one big-endian 64-bit word:

| Bits | Meaning |
|---|---|
| 0–7 | Strip index |
| 8 | Sign: zero positive, one negative |
| 9–63 | Unsigned 55-bit coordinate `j` |

The three fields are disjoint. Form `u = j / 2^55` exactly and multiply by the
strip width. Accept the rectangle only when `j < threshold`. A zero result is
canonical `(0,0)` regardless of the sign bit.

For a non-base slow path, read another whole word and use its high 55 bits for
`v / 2^55`. Interpolate the stored wedge heights in the specified fixed-point
operation order and accept strictly below `exp(-x*x/2)`. A failed wedge starts
again with a fresh header, including a new strip and sign.

For the base slow path, retain the header's sign. Read two whole words and use
open uniforms `(j+1)/2^55` in `[2^-55,1]`. Compute `t = -ln(u)/R` and
`y = -ln(v)`; accept when `2*y >= t*t`, returning signed `R+t`.
A failed tail pair draws another pair locally, without a fresh header.
There is no spare paired normal, global RNG, background thread or cached sample.
Lean's retry fuel is an explicit failure bound, not an altered acceptance rule.

## Downstream arithmetic and batching

Normal computes `mean + z*stddev`. Log-normal applies fixed-point `exp` to that
result. Beta retains its gamma construction, substituting these standard-normal
draws and preserving the gamma uniforms' existing byte requests.

Normalized integers compute `(z*((end-start)/6) + (end-start)/2) + start`, with
the division parameters prepared before drawing and multiplication/additions
performed in that order. Round to nearest integer, ties away from zero, and
reject values outside the inclusive range. This conditioning is part of the
distribution, not clamping. Scalar and batch endpoints must lie within ±2^53,
validated before reading. Reject a canonical candidate `m·2^(e−62)` before
generic saturating conversion when `e>53`, or `e=53` and `|m|≥2^62+256`.
This is exactly `|x|≥2^53+1/2`, including the rejected half-away ties.

Zig/Rust batches have constant scratch space and no stream of their own. SIMD
may perform exact affine arithmetic on four completed normal candidates;
it cannot reorder source requests, skip rejected draws or retain unused normals.
Groups are gathered only when at least four output slots remain. Accepted
lanes commit in order; the short remainder is scalar. A failing callback must
expose the same successful prefix, untouched suffix, error and byte cursor as
repeated scalar calls. Rust only speculates on its seekable DRBG and replays a
failed group scalarly; arbitrary effectful byte sources remain scalar.
Rust automatically selects supported AVX2. Zig AUTO currently keeps scalar
arithmetic because the final single-host gain was small and earlier timings
were inconsistent. Explicit `RANDOMZ_BATCH_SIMD` requests AVX2 with a portable
scalar fallback.

## Evidence and limits

The required Bash production suite freezes independent experiment-derived
digests and byte cursors, checks all five CLIs and every producer/consumer
resumption direction, and forces real wedge/tail paths. Required FFI tests also
compare sequential scalar, AUTO, SCALAR and explicit SIMD outputs and
partial-read effects at byte cutoffs.
All five tables must regenerate with identical signed integer literals at
512-bit MPFR precision.

The [experiment report](../reports/2026-10-08-fixed-point-ziggurat.md) records
the 96-million-output statistical campaign, MPFR point/certificate checks,
mutation controls and measured speedups. These do not prove cryptographic
security or a whole-domain distribution-error bound. In particular, the
proposed global Kolmogorov bound below `1e-11` remains unproved: primitive
rounding, branch disagreement mass and rejection coupling still need proofs.
The finite certificate reports eight compiled/ideal-real wedge differences;
they are not silently counted as exact real-arithmetic decisions.
