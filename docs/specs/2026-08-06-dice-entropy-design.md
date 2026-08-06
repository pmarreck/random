# Physical dice entropy design

Status: proposed for post-shipment implementation; no CLI in this document is
implemented yet.

## Goal

Allow a person to supplement the platform CSPRNG with manually rolled fair
dice, or deliberately use dice alone, without introducing human ordering bias,
silent source downgrade, ambiguous serialization, or a false claim that
hashing creates entropy.

This is seed generation, not a new per-sample distribution. After collecting
the sources, the frontend derives one 32-byte seed, prints it in the existing
replayable `0x` form, and instantiates the existing BLAKE3 DRBG. Replaying that
printed seed requires neither the dice transcript nor another entropy draw.

## Proposed CLI

- `--dice MdN` requests exactly M rolls of an N-sided die and combines them
  with 32 fresh bytes from the normal OS backend.
- `--dice-only MdN` is the explicit, conspicuous no-OS-source mode. It is
  rejected unless the conservative nominal min-entropy reaches 256 bits.
- `--dice-unordered MdN` accepts a simultaneously rolled collection, sorts it
  before framing, and credits only the lower unordered min-entropy described
  below. It modifies either dice mode rather than being an implicit behavior.
- `--dice-source PATH` reads the transcript from an explicit file for tests or
  controlled automation. There is deliberately no `--dice-values` argument:
  roll secrets must not appear in shell history or process listings.

Interactive entry uses the controlling terminal rather than ordinary stdin,
which may already contain `--choose`, `--shuffle`, or `--weighted` data. Each
value must be in `1..N`; EOF, an extra value, a missing value, or invalid text
fails the invocation. The prompt tells the user before the first roll to choose
their rule for cocked or off-table dice and then apply it consistently—never
selectively reroll an aesthetically suspicious valid result.

## Ordering

Ordered rolls preserve the full outcome space only when the order is fixed
independently of the observed faces. Recommended choices are one die rolled M
times sequentially, or differently colored/positioned dice whose read order is
declared before rolling. The prompt states this explicitly.

Sorting is safe only as an explicit lower-information mode. It prevents a
person from choosing a favorable order after seeing the results, but it
collapses every permutation to the same transcript and those sorted
transcripts are not equiprobable.

For ideal independent fair dice, ordered nominal entropy is:

```text
H = M log2(N)
```

For sorted counts `c1..cN`, the most probable multiset has the largest
multinomial coefficient. The conservative min-entropy credited to the mode is:

```text
H_min = M log2(N) - log2(max(M! / (c1! c2! ... cN!)))
```

The maximum uses counts distributed as evenly as possible. When `M <= N`, this
simplifies to `M log2(N) - log2(M!)`. Thus 5d20 has about 21.61 ordered nominal
bits but only about 14.70 sorted min-entropy. For dice-only mode, 60d20 exceeds
256 ordered nominal bits; 5d20 is nowhere close. These figures assume fair,
independent physical dice and are upper bounds on real-world entropy quality,
not a warranty.

## Canonical combination

The LuaJIT oracle implements this first. Zig then matches frozen vectors.
Values are serialized independently of host endianness as:

```text
mode:       u8       (1 = OS plus ordered, 2 = OS plus sorted,
                      3 = dice-only ordered, 4 = dice-only sorted)
M:          u32be
N:          u32be
roll[0..M]: u32be each (sorted first only for a sorted mode)
OS bytes:   exactly 32 bytes, present only for modes 1 and 2
```

The implementation restricts M and N to what this framing can represent and N
to at least 2. It derives 32 bytes with BLAKE3 derive-key context
`random dice entropy 2026-08-06 v1` over that complete frame. The distinct mode
byte prevents dice-only and combined transcripts from sharing an input domain.
The resulting bytes then enter the existing DRBG seed KDF.

Default `--dice` must fail if OS entropy fails. Only an explicitly requested,
threshold-satisfying `--dice-only` invocation may proceed without it. The
sources are not XORed, truncated, or accepted after a partial read. BLAKE3
provides an unambiguous robust combiner and domain separation; it does not add
entropy to weak inputs.

## Controls required before implementation is complete

- Frozen external BLAKE3 combination vectors plus LuaJIT-versus-Zig exact
  differential vectors.
- Ordered permutations must differ; sorted permutations must match.
- Boundary tests for every M/N/value/count rule and trailing transcript data.
- A fault-injected OS source must abort combined mode while the same transcript
  succeeds only under explicit, threshold-satisfying dice-only mode.
- Mutation tests must show the mode byte, M, N, every roll, and all 32 OS bytes
  affect the derived seed.
- CLI tests must prove interactive transcripts do not appear in argv or normal
  output and that existing stdin-consuming operations remain unambiguous.
- Statistical tests remain a sampler sanity check, not evidence that the
  intended entropy source was selected.

## Motivation and cautionary example

Coldcard MK3 firmware demonstrated why fallback provenance and fail-closed
behavior matter: production defined `MICROPY_HW_ENABLE_RNG` as zero while a
dependency tested whether it was defined, selecting a deterministic PRNG; a
later reseed retained only 32 bits. Hashing the resulting material could not
restore the missing entropy. See the
[vendor advisory](https://blog.coinkite.com/coldcard-mk3-seed-generation-warning/)
and [independent technical analysis](https://engineering.block.xyz/blog/predictable-rng-fallback-and-32-bit-reseed-in-coldcard-firmware).

Coldcard's dice documentation gives the ideal-die entropy calculation, while
BitBox's guide independently recommends deciding how dice will be selected
before rolling: [Coldcard dice math](https://coldcard.com/docs/verifying-dice-roll-math/)
and [BitBox dice guide](https://bitbox.swiss/bitbox02/BitBox_Diceware_HowTo.pdf).
