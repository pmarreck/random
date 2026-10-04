# Geometric counts: portable sampling and arbitrary-width output

Status: implemented in LuaJIT, Zig/C, Rust, and independent Lean 4. The shared Bash CLI suite runs the same assertions against each executable; language-specific library tests cover internal and FFI boundaries separately.

## User contract

`--geometric --probability P` returns the number of **failures before success**. Its ideal probability mass is `P(G=k)=p(1-p)^k` for `k=0,1,...`. The default probability is `0.5`; `p=1` returns zero without requesting source bytes. Zero, negative, noncanonical, and greater-than-one probabilities are errors. No range argument is accepted.

```sh
drandomz --seed 42 --geometric --probability 0.5 --count 8
# 0, 4, 1, 4, 0, 0, 3, 1 (one per line)
drandomr --seed 42 --geometric --probability 1e-20 --count 2
# 2914182621352146285, 80629014300636972342
randoml --geometric --probability '2^-100' --view --utf8
```

Finite counts, continuous `--stream`, OS-random sources, deterministic seeds, and cross-language continuation use the existing common policies. State stores `args.distribution="geometric"` and the original probability text in `args.p`; an explicitly supplied probability overrides inherited state. `next_pos` remains the **DRBG byte cursor**, not the sampled gap or the number of output items. A gap can exceed u64 or 2^53 without violating the byte cursor's existing 2^53 limit.

An event skipper normally advances its own cursor by `G+1`, accounting for the success. That cursor is the consumer's responsibility: perform checked addition or use an arbitrary-width representation. Sampling a large gap does not make it fit a finite address or event index.

## Probability representation and text syntax

The target is the canonical Fixed value `m * 2^(e-62)`, with `2^62 <= m < 2^63`, `-1000000 <= e <= 0`, and represented value at most one. Existing Fixed arithmetic is reused; BLIP extends the **count**, not the probability format.

Accepted probability text:

- Ordinary decimal numbers, with the existing Fixed parser's first eighteen fractional digits. Integer portions have at most 2,000 digits, including leading zeroes. Ordinary decimal parsing retains the existing ASCII whitespace/sign policy.
- Scientific syntax such as `5e-1` or `1e-20`: unsigned decimal mantissa, `e` or `E`, and an ASCII integer exponent of magnitude at most 1,000,000. No whitespace inside the scientific form. Scaling uses Fixed multiply/divide and square-and-multiply powers of ten, never hardware floating-point conversion.
- `2^N`, where N is an ASCII signed integer in `[-1000000,0]`, supplies an exact binary exponent. No whitespace inside this form.

Scientific scaling retains the portable Fixed rounding rules; it is not exact decimal rational arithmetic. A textual positive value that becomes zero or leaves the supported exponent domain is rejected. Tiny probabilities should use scientific or binary-power syntax rather than a decimal whose first eighteen fractional digits are all zero. These adapters do not alter parsers or seeded outputs for existing modes.

## Algorithm and frozen byte schedule

For `p<1/2`, independently sample `H ~ Geom(q)` and `B ~ Bernoulli(b)`, where `q=2p-p²` and `b=(1-p)/(2-p)`, then reconstruct `G=2H+B`. In exact arithmetic this is a bijection onto the ideal geometric law. Significant levels use the existing Fixed arithmetic in this exact evaluation order:

1. Compute the reconstruction-bit threshold from `Fixed.div(Fixed.sub(1,p), Fixed.sub(2,p))`.
2. Double by **incrementing the exponent**, preserving odd mantissas; do not substitute `Fixed.add(p,p)`.
3. Compute `Fixed.sub(doubled, Fixed.mul(p,p))`.
4. Stop once the stored probability is at least one half.

Prepared parameters cache significant thresholds. All actually sampled Bernoulli thresholds have exponent -2 or -1 and fit exactly in u64: respectively `m` or `2m`. Strict `draw < threshold` comparisons therefore introduce no additional probability grid. Existing u32 uniform variates are not used for these decisions.

For `e<-62`, the stored recurrence is exactly doubling and the stored bit probability is exactly one half. Jump to `e=-62` with unchanged mantissa and retain `tail_bits=-62-e`. This avoids a million per-bit Fixed operations for sparse probabilities.

One sample requests bytes in this order:

1. Repeated **eight-byte big-endian** u64 base trials until success. Every failure increments an arbitrary-width count; there is no native-width counter ceiling.
2. Significant reconstruction bits, in reverse preparation order, with one **eight-byte big-endian** u64 request per bit.
3. One contiguous request of `ceil(tail_bits/8)` bytes. Interpret it as a **little-endian low-bit integer**, mask padding above `tail_bits`, and append those low bits beneath the reconstructed count.

There is no hidden bit reservoir or cross-call tail cache. Discarded high padding is not reused by the next sample. Probability one is the only zero-request path.

## Count format and resource failures

Text output is exact integer decimal; `--hex` is exact unprefixed hexadecimal. Neither converts a sampled count through binary64. Binary output concatenates canonical **unsigned little-endian BLIP v1.2** integers. `--hex` and `--base64` then encode that byte stream using the existing transport rules. `--count` counts samples, not encoded bytes.

BLIP fixtures: zero=`00`, 127=`7f`, 128=`81 80`, 256=`82 00 01`, and 2^64=`89 00 00 00 00 00 00 00 00 01`. Values below 128 use immediate form; larger values use the shortest unsigned LE payload, plus the spec-defined length header and continuation bytes. Signed `blip_mp` positive sign-padding is deliberately not used. There is no external BLIP runtime dependency.

There is no u32/u64 output ceiling, but source and memory resources remain finite. The lowest supported exponent requires roughly 125 KiB of fair-bit/magnitude storage per sample. Decimal conversion costs grow with integer width. CLI streaming keeps only bounded per-sample/chunk storage, independent of total requested count; it does not promise constant memory independent of probability or output width.

Buffer, source, cursor, and allocation errors fail closed: never wrap, clamp, omit a sample, or resample until a value fits. A generic opaque source cannot be rolled back. Once sampling begins, a failure may consume bytes and modify scratch/output; do not blindly retry with an entropy source. A deterministic client can retain a state clone when it needs transactional retry. Pure Lean state transitions return no replacement state on failure.

## Library surfaces

- LuaJIT: `geometric.parse_probability`, `geometric.prepare`, and `geometric.sample(prepared, read_exact)`; `rng:geometric(m,e)` is a convenience method. Counts are canonical raw LE magnitudes, converted through `unsigned_count.to_decimal`, `.to_hex`, or `.to_blip`.
- Zig: `randomz.geometric.Prepared.init`, `.sample(prepared, source, caller_buffer)`, `.encodeInPlace`, and `.formatCount`. Sampling and formatting allocate no memory internally.
- C ABI: `randomz_geometric`, `randomz_geometric_probability_parse`, and `randomz_count_format`, documented in `include/randomz.h`. The C CLI uses these entry points instead of implementing distribution arithmetic. All pointer lifetimes and disjoint storage belong to the caller. Invalid static inputs precede source/output mutation; successful samplings publish the complete BLIP length. After valid-input failures, `written` is zero.
- Rust: `Geometric::parse_probability`, `Geometric::new`, and `.sample(&mut impl ByteSource) -> Result<UnsignedCount, Error>`. `UnsignedCount` supplies exact decimal/hex/BLIP representations. The core works with `alloc`, without CLI I/O.
- Lean: `Geometric.Probability`, `prepare`, pure generic `sampleWith`, pure `sample` over a caller-owned DRBG, and `unsignedBlip`. Only source interpreters perform I/O.

All four libraries have existing separate `random-{luajit,zig,rust,lean}-lib` Nix outputs. Their installed-library consumer gate exercises the new Lua modules and Zig C ABI directly through LuaJIT FFI, without compiling a separate C harness.

## Accuracy, proofs, and independent controls

Counts are exact integers, but the Fixed recurrence targets an **approximation** to the ideal geometric law. The independent analytical budget is total variation `<770 * 2^-62`, approximately `1.67e-16`, assuming independent uniform source bytes. This combines operation-specific significant-level bounds with a geometrically summed tiny-region bound; it does not grow with the number of skipped tiny exponents. It excludes source/resource failures. A seeded DRBG supplies cryptographic pseudorandomness assumptions, not mathematically independent bytes.

`tests/geometric_rational_test` uses independently supplied GMP exact rational arithmetic: 1,828 parameter cases, 57,420 operation comparisons, 16,064 exact block-PMF identities, reduced-width threshold exhaustion, tail/cursor controls, and deliberate corrupted producers. The significant corpus is not exhaustive over all 62-bit mantissas. The budget is an analytical derivation supported by these checks and code inspection, **not a universal Lean distribution theorem or security certification**.

Lean's kernel checks the invariants carried by validated probabilities, the actual reconstruction helper's quotient/remainder, and the actual probability-one sampler's zero-output/unchanged-state behavior. Executable boundary, BLIP, cursor, and cross-language tests cover additional cases; do not conflate them with universal theorems.

The **same Bash CLI tests** run under each executable selector. Shared suites also compare complete help output, stream prefixes, and continuation in every implementation-to-implementation direction. `./stats --all` tests moderate-p PMF bins, survival, memorylessness, moments, and sparse-p scaled shapes plus exact low-digit parity; deliberately invalid generators establish sensitivity. `./bm` hashes payloads before measuring default and sparse geometric workloads. Neither timing nor empirical statistics proves the tiny total-variation bound.

## Charts

Runtime views plot relative ideal PMF height `(1-p)^floor(x)` across `0..6/p`, using integer-only core math. Probability one is a delta at zero. For `p<1/16`, an eight-term log1p series avoids catastrophic cancellation in `ln(1-p)`. The omitted exponent over this plot interval is below `6*p^8/(9*(1-p)) <1.66e-10`, before ordinary Fixed rounding. For larger p, use the existing logarithm kernel. Raster heights normalize to `0..65535`; extremely wide x coordinates retain the Fixed representation rather than clamping to a machine integer.

Independent test-side mathematical oracles check heights at the branch and tiny-probability boundaries. Chart approximation/quantization never changes sampled values or source consumption. The frozen default `--help` chart remains separate from customized `--view` generation.

## Independent review findings

A separate reviewer began the exact-rational derivation before inspecting the producer, then performed a read-only implementation pass. The review found and resolved four additional regressions: materially wrong charts at `p=2^-62`; disagreement on overlong decimal mantissas; Lean rejecting inherited-mode probability overrides; and Rust type-checking an overridden old state probability. Independent rebuilt probes passed after each correction. The shared Bash suite retains the CLI regressions; independent height-oracle and FFI tests retain the numerical/source controls.

Earlier exact-rational review also exposed odd-mantissa loss in a proposed `add(p,p)` recurrence; exponent adjustment replaced it before acceptance. Review is scoped evidence, not blanket certification. Remaining limits include incomplete universal probability proofs, non-Linux runtime evidence for the new mode, and potentially quadratic extreme-width decimal/Nat conversion.

## Acceptance measurements

On 2026-10-04, the complete fast runner passed all 34 required suites. The unchanged shared Bash CLI contract passed 85 cases per implementation; complete help/chart comparisons passed 80 cases, continuation passed 1,276 checks across all sixteen language pairings, and streaming passed 184 checks. Installed-library and split-package Nix checks passed. The separate fast statistical analysis passed 73 sanity/sensitivity checks per implementation; the empirical gates are not distribution proofs.

`./bm --quick` passed SHA-256 equivalence for all thirteen workloads before each timing run. Release executables used seed 42, 5,000 text samples, three measured runs, and one warmup. Linux x86_64 CPU affinity was fixed separately to one core and twelve cores; these scalar CLI workloads do not become twelve-thread samplers. Timings include startup, sampling, formatting, and output to `/dev/null`. Rust timing bypassed its installed self-test wrapper, which remained in the equivalence preflight. No benchmark payloads or history were written to disk.

Mean wall time in milliseconds:

| Affinity | Probability | LuaJIT | Zig/C | Rust | Lean |
|---|---|---:|---:|---:|---:|
| One core | 0.25 | 55.0 | 3.9 | 3.2 | 128.9 |
| One core | 1e-20 | 917.9 | 29.6 | 11.7 | 2137 |
| Twelve cores | 0.25 | 58.3 | 4.7 | 3.8 | 112.7 |
| Twelve cores | 1e-20 | 925.6 | 30.7 | 11.8 | 2120 |

These short runs had observable variance and are initial feature measurements, not a pre/post speedup claim. The C CLI currently prepares geometric parameters through its public ABI per sample, whereas the Rust CLI caches its prepared sampler; Zig library consumers can also reuse `Prepared`. Extreme-width integer conversion remains a separate optimization opportunity.
