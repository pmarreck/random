# Deterministic integer-only RNG numerics — design

**Date:** 2026-07-31
**Status:** approved (design); implementation not started
**Author:** Claude + Peter Marreck
**Supersedes:** the float-based numerics in `bin/random`

---

## 1. Purpose

Make `random` produce **bit-identical seeded streams across runs, machines,
operating systems, and CPU architectures**, so it can serve as the RNG primitive
for deterministic fuzzing across the fleet.

Then port it to a Zig 0.16 core + C FFI + `randomz` C CLI, keeping the LuaJIT
implementation permanently as an independent differential oracle.

## 2. Why the current implementation cannot deliver that

`bin/random` computes its distributions with `math.log`, `math.cos`, `math.exp`
and `math.pow`. LuaJIT forwards these to the platform libm. **libm results are
not portable**, because IEEE-754 specifies exact results for `+ - * / sqrt` and
says essentially nothing about transcendental functions. Every libc is free to
return a different final ulp, and they do.

Measured on this machine, glibc vs musl, identical inputs, sweeping
`u = k / 2^32` (the exact domain `pcg32_uniform()` produces):

| function | agrees? | divergence rate |
|---|---|---|
| `sqrt` | yes | 0%, IEEE-754 mandates correct rounding |
| `log`  | **no** | 0.006% |
| `cos`  | **no** | 3.06% |
| `exp`  | **no** | 8.85% |

Method: 20.4M strided samples digested per function (FNV-1a over raw bit
patterns), then 429,197 samples dumped and compared elementwise.

Box-Muller uses `log` **and** `cos` per variate, so roughly **3% of seeded
normal values differ between a glibc build and a musl build of the same source
at the same seed**. That is fatal to reproducible fuzzing. A corpus that
reproduces a crash on one machine will not reproduce it on another, and nothing
in the output indicates why.

A methodological note worth preserving: an initial 8-input hand-picked
comparison reported "identical" for all three functions. Only the swept,
set-based comparison over the real input domain revealed the divergence. Filters
and oracles must be evaluated as classifiers over sets, never as predicates over
examples.

### 2.1 Required commentary in the source

The implementation files **must** carry a header comment explaining why these
functions were reimplemented, with the measured numbers above, so that a future
reader (human or LLM) does not "helpfully" replace the integer kernel with a
call to `math.log` and silently destroy the guarantee.

That comment must also record the project's position, in Peter's words and
paraphrased faithfully rather than sanitised: that the industry's casual
tolerance of platform-divergent floating-point math, treating "it's only the
last ulp" as acceptable in code whose entire purpose is reproducibility, is
indefensible, and that the standard practice of shrugging at it is exactly why
this reimplementation was necessary.

## 3. Architecture

```
                       ┌─────────────────────────────────┐
   deterministic       │  numeric kernel (spec §4)       │
   numeric substrate   │  normalized soft-float, integer │
                       └───────────────┬─────────────────┘
                                       │ two independent implementations
                    ┌──────────────────┴───────────────────┐
                    ▼                                      ▼
        lib/fixed.lua  (LuaJIT)                   src/fixed.zig  (Zig 0.16)
                    │                                      │
        bin/random  (LuaJIT CLI)                  Zig core — pure, no I/O
          = permanent oracle                               │
                                                    C FFI (include/randomz.h)
                                                           │
                                              randomz (C CLI, dogfoods FFI)
                                              + drandomz/nrandomz symlinks
```

The Zig core performs **no I/O**. State persistence, stdin/stdout, environment
variables and the state file all live in the C CLI. The core exposes explicit
get/set of raw PRNG state so the CLI can round-trip it.

`randomz` is written in C deliberately: C cannot `@import` a Zig module, so
bypassing the FFI is inexpressible rather than merely discouraged.

The two implementations share **no code**. See §7.

## 4. The numeric kernel

### 4.1 Why not fixed point

An earlier draft of this spec used Q32.32. It works, and it wastes half the
register. Pi in Q32.32 spends 30 of 64 bits on leading zeros and retains about
33 bits of relative precision, against a double's 53.

Widening the fraction does not rescue it, because **no single fixed-point format
covers the required range**:

| quantity | range needed |
|---|---|
| `exp(r)` after range reduction | [0.707, 1.414] |
| `cos` output | [−1, 1] |
| `ln(u)` over `u = k/2^32` | down to −22.2 |
| normal variate `z0` | ±6.6 |
| user `--mean` / `--stddev` | ±1000 and beyond |
| `exp(μ+σz)` for log-normal | unbounded in practice |

Covering ±1000 costs 11 integer bits, leaving 53 fractional, which lands back at
double precision having gained nothing. Normalization removes the range/precision
tradeoff rather than relocating it.

### 4.2 The value type: normalized binary soft-float

`{ m : u64, e : i32, sign }`, value `= sign · (m / 2^63) · 2^e`, with
`m ∈ [2^63, 2^64)` for every nonzero value. Zero is `m = 0, e = 0`.

Normalized mantissa means **62-63 bits of relative precision at every
magnitude**, better than a double, with no wasted bits at any scale.

Base 2 rather than base 10, decided 2026-07-31. Decimal renormalization requires
dividing out a power of ten after each multiply, which is a 128÷64 division;
LuaJIT has no 128-bit division and it would have to be synthesized and proven
bit-identical against Zig's native `u128`. Binary renormalization is a shift and
a leading-zero count. Exact decimal I/O, which base 10 would give, is a tidiness
property and buys no determinism: reproducibility requires every platform to
produce the *same* value, not the decimal-exact one.

**This is a software float with semantics we define, not a hardware float.** No
IEEE-754, no rounding modes, no libm, no FPU. Rounding is **truncation toward
zero, everywhere, unconditionally**. Truncation is trivially reproducible and
has no tie-breaking rule to get subtly wrong in one implementation.

### 4.3 Primitive operations

- **`mul128(a,b)`** — full 64×64→128 product from four 32-bit partials.
  Required because **LuaJIT cannot do `__int128` arithmetic**: `ffi.cdef` accepts
  the typedef, but construction fails with `cannot convert 'number' to
  'int128_t'`. Mike Pall's "box it in the FFI" guidance covers storage; LuaJIT
  implements arithmetic only to 64 bits. Zig uses native `u128` and must produce
  identical results.
- **`sfmul`** — mantissa product lands in `[2^126, 2^128)`. If the high word has
  its top bit set the product is `≥ 2^127`, so take `hi` and `e₁+e₂+1`;
  otherwise take `(hi<<1)|(lo>>63)` and `e₁+e₂`. **Verified against `bc` at
  scale=40 over 64 mantissa pairs spanning both branches: worst relative error
  6.2×10⁻²⁰, below the 2⁻⁶³ = 1.08×10⁻¹⁹ representation floor.**
- **`sfadd`** — align the smaller exponent by right-shifting its mantissa, add
  or subtract by sign, renormalize.
- **`normalize`** — leading-zero count and shift. LuaJIT lacks a CLZ primitive,
  so a de Bruijn table or a 6-step binary search is used; Zig uses `@clz`. Both
  must agree, which they do since the result is exact.

### 4.4 Transcendental algorithms

All integer-only. No libm, no hardware float, no IEEE-754 anywhere.

Series are evaluated on **range-reduced arguments in a narrow, provably bounded
interval**, so their accumulators may use a local fixed-point format as an
optimization. Soft-float is the interface type at every function boundary.

**`ln(x)`, `x > 0`** — the soft-float form already *is* the decomposition:
`x = m·2^e` gives `ln x = e·ln2 + ln(m)` directly, with no work. Then
`ln(m) = 2·atanh(t)`, `t = (m−1)/(m+1) ∈ [0, 1/3)`, summed as
`2·(t + t³/3 + t⁵/5 + …)` to 12 terms. Converges quickly because `t < 1/3`.

**`exp(x)`** — reduce `x = k·ln2 + r`, `|r| ≤ ln2/2 ≈ 0.3466`, evaluate `exp(r)`
by Taylor to 16 terms. The result `(exp(r), k)` **is already a soft-float**;
returning the pair is strictly less work than shifting by `k`, and that shift is
precisely what overflowed the old fixed-point design. The range extension falls
out of the algorithm rather than being bolted onto it.

**`cos(2πu)`, evaluated in *turns* rather than radians.** The argument is always
literally `2π·u` for `u ∈ [0,1)`, so quadrant reduction is done on `u` directly
and is therefore **exact**: quadrant `= floor(4u)`, position within quadrant
`= (u mod ¼)·4`. Only then multiply by `π/2` to get an angle in `[0, π/2)` for
Taylor evaluation. This removes the `2π` multiply from reduction entirely, which
was the single largest rounding source. Quadrant mapping: `0 → cos(a)`,
`1 → −sin(a)`, `2 → −cos(a)`, `3 → sin(a)`.

**`sqrt(x)`** — halve the exponent, adjusting the mantissa by one shift when the
exponent is odd; integer Newton iteration on the mantissa.

**`pow(x,y)`** — `exp(y·ln x)`, composed from the above.

**Series denominators are precomputed reciprocal constants multiplied in**, never
divided by. This removes division from every hot loop, and with it an entire
class of overflow hazard (see §7 for the one that was actually caught).

### 4.5 Constants

`ln2`, `π/2`, and the reciprocal tables are stored as normalized
mantissa/exponent pairs, **generated by `bc` at scale=40 and rounded to
nearest**. The generating `bc` expression is committed alongside each constant so
they are auditable and regenerable rather than magic numbers.

### 4.6 Measured accuracy

Against `bc -l` at scale=40, 400 vectors over the real `k/2^32` domain:

| function | max abs error |
|---|---|
| `ln`  | 3.3×10⁻⁹ |
| `exp` | 2.5×10⁻⁹ |
| `cos` | 6.1×10⁻¹⁰ |

**These were measured on the Q32.32 prototype and are a lower bound on the
final design**, since the normalized mantissa carries roughly 30 more bits.
Re-measurement against the soft-float kernel is the first task of the
implementation plan, not an assumption of this spec.

The statistical assertions in `tests/random_test` have tolerances around ±0.5,
so even the lower bound carries about eight orders of magnitude of margin.

## 5. Float-free end to end

A deterministic core fed by `strtod` is not deterministic. Both boundaries are
closed as part of this work:

- **Input** — `--mean`, `--stddev`, `--alpha` and `--beta-param` parse from
  decimal strings directly to soft-float by integer accumulation. Positional
  range bounds parse to plain `i64`; a fractional positional bound is rejected
  with an error rather than silently floored. No `tonumber`, no `strtod`.
- **Output** — values format to decimal by integer division. No `%f`. Values
  whose magnitude exceeds the plain-decimal window format in scientific notation
  via an integer decimal-exponent computation.

## 6. Distribution algorithms

| distribution | algorithm | change from today |
|---|---|---|
| uniform | PCG32 XSH-RR, rejection-sampled range | **none**, already integer |
| normal | Box-Muller over the kernel, both sub-paths: the ranged integer form (`normal_random_int`, uniforms drawn as `rand(1,10⁶)/10⁶` and resampled until in range) and the `--mean`/`--stddev` form (`normal_random_float`) | values change; method identical |
| exponential | `−ln(u)/rate` | values change; method identical |
| **poisson** | **sum-of-exponentials: count `k` where `Σ −ln(uᵢ) > λ`** | **algorithm change, below** |
| log-normal | `exp(normal(μ,σ))` | values change; method identical |
| beta | Marsaglia-Tsang gamma variates, `x/(x+y)` | values change; method identical |

**Poisson changes form.** The current product form (multiply uniforms until
`p ≤ e^{−λ}`) underflows any fixed-width fraction. The sum-of-exponentials form
is the same distribution and consumes the same number of uniforms per variate,
but is numerically well-conditioned across the whole useful λ range. Approved
2026-07-31.

### 6.1 Rejection-boundary note

Marsaglia-Tsang makes accept/reject decisions by comparing computed quantities.
Because `ln`/`exp`/`cos` are irrational for essentially every rational input, no
finite precision can guarantee landing on the same side of a boundary as
infinite-precision truth. This is the table-maker's dilemma, and it is **not** a
defect that more bits would fix.

It is also **not a threat to determinism**. Our arithmetic is exact and
reproducible, so the decision is identical on every machine forever. The only
consequence is that beta cannot be validated against an external
double-precision reference; it is validated by its own golden vectors plus the
statistical bounds.

## 7. Controls (MFIC)

| control | type | what it catches |
|---|---|---|
| **`bc -l` sweep** of the kernel | differential, independent third-party oracle | wrong transcendental math |
| **Cross-target stream digest** | metamorphic | residual platform dependence; x86_64 / aarch64 / musl must digest identically |
| **Golden vectors, integer paths** | regression | kernel work disturbing paths it must not touch |
| **Golden vectors, distributions** | regression | unintended stream changes after blessing |
| **Statistical bounds** (existing suite) | property | a kernel that is deterministic *and wrong*, which goldens alone cannot detect |
| **`randomz` vs `bin/random` differential** | differential | Zig/LuaJIT divergence across a seed × flag matrix |

`bc` is a stronger oracle than assumed at the outset. **GNU bc 1.08.2 does not
use GMP**; it links only libc and carries its own arbitrary-precision decimal
arithmetic in `number.c`. It therefore shares no lineage with GMP, with
`blip_mp`, or with anything written here.

The `bc` control has already earned its place twice during design: it caught a
`u64` overflow in a fixed-point `div` helper that produced 0.46 absolute error in
`cos`, and it confirmed `sfmul` correct to below the representation floor. Both
findings came from swept comparison, not from inspection.

The two implementations must share no code, or the differential control
collapses into a single actor checking itself. This is why the LuaJIT oracle
does not FFI into the Zig kernel, why a single shared C kernel was rejected
(2026-07-31), and why arbitrary-precision arithmetic via `blip_mp` was rejected
as the substrate.

## 8. Sequencing

**Steps 1-4 and step 5 are separate implementation plans.** This spec fixes the
destination up front, but steps 1-4 (making the LuaJIT implementation
deterministic) is self-contained and shippable on its own. Step 5 gets a second
plan once 1-4 have landed and the oracle is trustworthy. Porting against a
reference that is still moving would be the worst possible sequencing.

1. **Fix `pcg32_range`.** `bound = 2^32 − (2^32 mod range)` evaluates to `0` for
   any range > 2³², so `r < bound` is never true and the loop spins forever
   (`bin/random:175`). Failing test first.
2. **Bless golden vectors for integer paths only**: uniform, choose, shuffle,
   weighted, binary, hex, base64, delimiters, counts.
3. **Build the kernel, re-measure against `bc`, convert LuaJIT to use it.**
4. **Bless golden vectors for the distributions.**
5. **Zig core + C FFI + `randomz` + symlinks + differential harness.**

**Step 2 deliberately excludes the distributions.** Their present values are
platform-dependent, which is the defect being fixed, so blessing them now would
laminate the bug into the test suite. Integer goldens can be blessed
immediately, and they are what proves step 3 left the integer paths untouched,
including the existing human-verified vector `seed 42, range 0..99 → 26`.

## 9. Compatibility

**Unchanged, bit-for-bit:** uniform, `--choose`, `--shuffle`, `--weighted`,
`--binaryoutput`, `--hex`, `--base64`, delimiters, counts, and the PCG32 stream
itself. One exception cannot break any working caller: ranges wider than 2³²
currently hang forever (§8 step 1), so the fix turns a non-terminating program
into a correct one, and no previously-produced output changes.

**Changed once, deliberately and permanently:** seeded values from
`--normalized`, `--exponential`, `--poisson`, `--log-normal`, `--beta`. Anyone
depending on a specific seeded float stream from a prior version must re-bless.
Documented in README and CHANGELOG.

**Tightened:** a fractional positional bound (`random 1.5 6.5`) is now an error.
It previously "worked" by accident through double arithmetic, was never
documented, and has no sensible meaning for an integer range.

**`--about`** adopts the fleet one-line format (name, version, platform, arch),
replacing the current prose sentence. Approved 2026-07-31.

## 10. Non-goals

- Matching the *old* float output. It was never portable; reproducing it would
  reproduce the defect.
- Matching any particular libm. We are not glibc-compatible or musl-compatible.
  We are **self-compatible**, which is the property actually wanted.
- Correctly-rounded transcendentals. Accuracy need only suffice for valid
  distributions, and §4.6 shows roughly eight orders of margin.
- Arbitrary precision (`lua-bint`, `blip_mp`, GMP). We need bounded reproducible
  precision, not unbounded accuracy. A 64-bit normalized mantissa already
  delivers ~1e-9 against tolerances of 0.5. Exact rationals were measured at
  168-digit denominators per `exp` call and 503 digits for a beta variate, still
  require a truncation policy for irrational results, and would couple the
  oracle to the code under test.
