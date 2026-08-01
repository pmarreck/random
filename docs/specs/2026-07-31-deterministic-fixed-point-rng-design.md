# Deterministic fixed-point RNG — design

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

Measured on this machine — glibc vs musl, identical inputs, sweeping
`u = k / 2^32` (the exact domain `pcg32_uniform()` produces):

| function | agrees? | divergence rate |
|---|---|---|
| `sqrt` | yes | 0% — IEEE-754 mandates correct rounding |
| `log`  | **no** | 0.006% |
| `cos`  | **no** | 3.06% |
| `exp`  | **no** | 8.85% |

Method: 20.4M strided samples digested per function (FNV-1a over raw bit
patterns), then 429,197 samples dumped and compared elementwise.

Box-Muller uses `log` **and** `cos` per variate, so roughly **3% of seeded
normal values differ between a glibc build and a musl build of the same source
at the same seed**. That is fatal to reproducible fuzzing: a corpus that
reproduces a crash on one machine will not reproduce it on another, and nothing
in the output indicates why.

A methodological note worth preserving: an initial 8-input hand-picked
comparison reported "identical" for all three functions. Only the swept,
set-based comparison over the real input domain revealed the divergence. Filters
and oracles must be evaluated as classifiers over sets, never as predicates over
examples.

### 2.1 Required commentary in the source

The implementation files **must** carry a header comment explaining why these
functions were reimplemented — the portability defect above, with the measured
numbers — so that a future reader (human or LLM) does not "helpfully" replace
the integer kernel with a call to `math.log` and silently destroy the guarantee.

That comment must also record the project's stated position, in Peter's words
and paraphrased faithfully rather than sanitised: that the industry's casual
tolerance of platform-divergent floating-point math — treating "it's only the
last ulp" as acceptable in code whose entire purpose is reproducibility — is
indefensible, and that the standard practice of shrugging at it is precisely why
this reimplementation was necessary in the first place.

## 3. Architecture

```
                       ┌─────────────────────────────────┐
   deterministic       │  fixed-point kernel (spec §4)   │
   numeric substrate   │  Q32.32 + soft-float, integers  │
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

## 4. The fixed-point kernel

### 4.1 Q32.32 — the working format

Signed `i64`, 32 integer bits, 32 fractional bits. Range ±2.1×10⁹, resolution
2.3×10⁻¹⁰. Chosen because it needs no 128-bit type, which LuaJIT lacks.

- **`mul(a,b)`** — 32×32→64 schoolbook partial products, sign handled
  separately on magnitudes. Zig may use `i128` directly; both must produce
  identical results, which they do because both truncate toward zero.
- **`div(a,b)`** — integer quotient, then the fraction refined in **two 16-bit
  steps**. The naive `(a % b) << 32` overflows `u64` whenever the remainder
  exceeds 2³²; this bug was found by the §7 `bc` control during design, and the
  two-step form avoids it. Precondition `|b| < 2^48`, asserted.
- Rounding is **truncation toward zero, everywhere, unconditionally.** Not
  round-to-nearest. Truncation is trivially reproducible and has no tie-breaking
  rule to get subtly wrong in one of the two implementations.

### 4.2 Soft-float — the range extension

Representation: `{ m : i64 (Q32.32, normalised to [1,2)), e : i32 }`, value
`m · 2^e`. Zero is `m = 0`, `e = 0`.

This is **not a bolted-on second numeric system**. It is the structure the
algorithms already produce and currently discard:

- `exp(x)` range-reduces to `2^k · exp(r)` with `exp(r) ∈ [0.7, 1.4]`. Returning
  the pair `(exp(r), k)` is *less* work than shifting by `k`, and the shift is
  exactly what overflows today.
- `ln(x)` already decomposes its argument as `m · 2^e` and computes
  `ln(m) + e·ln2`. It consumes the soft-float form natively.

Soft-float is therefore used only at the boundaries where range demands it
(notably log-normal). The series themselves operate on range-reduced arguments
where Q32.32 has ample headroom. Normalisation is: shift the mantissa so it lies
in `[1,2)` in Q32.32, truncating toward zero.

### 4.3 Transcendental algorithms

All integer-only. No libm, no hardware float, no IEEE-754 semantics anywhere.

**`ln(x)`, `x > 0`** — decompose `x = m·2^e`, `m ∈ [1,2)`. Then
`ln x = e·ln2 + 2·atanh(t)` where `t = (m−1)/(m+1) ∈ [0, 1/3)`. Sum
`2·(t + t³/3 + t⁵/5 + …)`, 12 terms. Converges quickly because `t < 1/3`.

**`exp(x)`** — reduce `x = k·ln2 + r` with `|r| ≤ ln2/2 ≈ 0.3466`, evaluate
`exp(r)` by Taylor to 16 terms, return soft-float `(exp(r), k)`.

**`cos(2πu)` — evaluated in *turns*, not radians.** The argument is always
literally `2π·u` for `u ∈ [0,1)`, so quadrant reduction is performed on `u`
directly and is therefore **exact**: quadrant `= floor(4u)`, position within
quadrant `= (u mod ¼)·4`. Only then is the result multiplied by `π/2` to get an
angle in `[0, π/2)` for the Taylor evaluation. This removes the `2π` multiply
from the reduction entirely, which was the single largest rounding source.
Quadrant mapping: `0 → cos(a)`, `1 → −sin(a)`, `2 → −cos(a)`, `3 → sin(a)`.

**`sqrt(x)`** — integer Newton iteration.

**`pow(x,y)`** — `exp(y·ln x)`, composed from the above.

**Series denominators are precomputed reciprocal constants multiplied in**, not
divided by. This removes division from every hot loop and, with it, the entire
`div` overflow hazard class from the series.

### 4.4 Constants

`LN2 = 2977044472` (`ln2 · 2^32`), `PI_2 = 6746518852` (`π/2 · 2^32`), plus the
reciprocal tables. All constants are **generated by `bc` at scale=40 and rounded
to nearest**, and the generating `bc` expression is committed alongside them so
they are auditable and regenerable rather than magic numbers.

### 4.5 Measured accuracy

Against `bc -l` at scale=40, 400 vectors over the real `k/2^32` domain:

| function | max abs error |
|---|---|
| `ln`  | 3.3×10⁻⁹ |
| `exp` | 2.5×10⁻⁹ |
| `cos` | 6.1×10⁻¹⁰ |

The statistical assertions in `tests/random_test` have tolerances around ±0.5,
so this carries roughly eight orders of magnitude of margin.

## 5. Float-free end to end

A deterministic core fed by `strtod` is not deterministic. Both float boundaries
are therefore closed as part of this work:

- **Input** — `--mean`, `--stddev`, `--alpha` and `--beta-param` parse from
  decimal strings **directly to Q32.32** by integer accumulation. Positional
  range bounds parse to plain **`i64` integers**; a fractional positional bound
  is rejected with an error rather than silently floored. No `tonumber`, no
  `strtod`.
- **Output** — values format to decimal by integer division. No `%f`, no
  `%.6f`. Soft-float values whose magnitude exceeds Q32.32 format in scientific
  notation via an integer decimal-exponent computation.

## 6. Distribution algorithms

| distribution | algorithm | change from today |
|---|---|---|
| uniform | PCG32 XSH-RR, rejection-sampled range | **none** (already integer) |
| normal | Box-Muller over the fixed-point kernel, both sub-paths: the ranged integer form (`normal_random_int`, uniforms drawn as `rand(1,10⁶)/10⁶` and resampled until in range) and the `--mean`/`--stddev` float form (`normal_random_float`) | values change; method identical |
| exponential | `−ln(u)/rate` | values change; method identical |
| **poisson** | **sum-of-exponentials: count `k` where `Σ −ln(uᵢ) > λ`** | **algorithm change, see below** |
| log-normal | `exp(normal(μ,σ))`, soft-float result | values change; method identical |
| beta | Marsaglia-Tsang gamma variates, `x/(x+y)` | values change; method identical |

**Poisson changes form.** The current product form (multiply uniforms until
`p ≤ e^{−λ}`) underflows Q32.32: at λ=20 the threshold is 2×10⁻⁹, only about
nine representable steps above zero, and quality degrades well before that. The
sum-of-exponentials form is the same distribution and consumes the same number
of uniforms per variate, but is numerically well-conditioned, raising usable λ
from roughly 20 to roughly 10⁵. Approved 2026-07-31.

### 6.1 Rejection-boundary note

Marsaglia-Tsang makes accept/reject decisions by comparing computed quantities.
Because `ln`/`exp`/`cos` are irrational for essentially every rational input, no
finite precision can guarantee the same side of a boundary as infinite-precision
truth — this is the table-maker's dilemma, and it is **not** a defect that more
bits would fix.

It is also **not a threat to determinism.** Our arithmetic is exact and
reproducible, so the decision is identical on every machine forever. The only
consequence is that beta cannot be validated against an external
double-precision reference; it is validated by its own golden vectors plus the
statistical bounds.

## 7. Controls (MFIC)

| control | type | what it catches |
|---|---|---|
| **`bc -l` sweep** of the kernel | differential, independent third-party oracle | wrong transcendental math. Already earned its keep: it caught a real `u64` overflow in `div` during design, at 0.46 absolute error. |
| **Cross-target stream digest** | metamorphic | any residual platform dependence; x86_64 / aarch64 / musl must digest identically |
| **Golden vectors, integer paths** | regression | fixed-point work disturbing paths it must not touch |
| **Golden vectors, distributions** | regression | unintended stream changes after blessing |
| **Statistical bounds** (existing suite) | property | a kernel that is deterministic *and wrong* — which goldens alone cannot detect |
| **`randomz` vs `bin/random` differential** | differential | Zig/LuaJIT divergence across a seed × flag matrix |

The two implementations must share **no code**, or the differential control
collapses into a single actor checking itself. This is why the LuaJIT oracle
does not FFI into the Zig kernel, and why arbitrary-precision arithmetic via
`blip_mp` was rejected as the substrate.

## 8. Sequencing

1. **Fix `pcg32_range`.** `bound = 2^32 − (2^32 mod range)` evaluates to `0` for
   any range > 2³², so `r < bound` is never true and the loop spins forever
   (`bin/random:175`). Failing test first.
2. **Bless golden vectors for integer paths only** — uniform, choose, shuffle,
   weighted, binary, hex, base64, delimiters, counts.
3. **Convert LuaJIT to the fixed-point kernel.**
4. **Bless golden vectors for the distributions.**
5. **Zig core + C FFI + `randomz` + symlinks + differential harness.**

**Steps 1–4 and step 5 are separate implementation plans.** This spec covers the
whole arc so the destination is fixed up front, but steps 1–4 (making the LuaJIT
implementation deterministic) is a self-contained, shippable project and gets
its own plan first. Step 5 (the Zig port) gets a second plan written once 1–4
have landed and the oracle is trustworthy — porting against a reference that is
still moving would be the worst possible sequencing.

**Step 2 deliberately excludes the distributions.** Their present values are
platform-dependent — that is the defect being fixed — so blessing them now would
laminate the bug into the test suite. Integer goldens can be blessed
immediately, and they are what proves step 3 left the integer paths untouched,
including the existing human-verified vector `seed 42, range 0..99 → 26`.

## 9. Compatibility

**Unchanged, bit-for-bit:** uniform, `--choose`, `--shuffle`, `--weighted`,
`--binaryoutput`, `--hex`, `--base64`, delimiters, counts, and the PCG32 stream
itself — with one exception that cannot break any working caller: ranges wider
than 2³² currently hang forever (§8 step 1), so the fix turns a non-terminating
program into a correct one. No previously-produced output changes.

**Tightened:** a fractional positional bound (`random 1.5 6.5`) is now an error.
It previously "worked" by accident through double arithmetic, was never
documented, and has no sensible meaning for an integer range.

**Changed once, deliberately and permanently:** seeded values from
`--normalized`, `--exponential`, `--poisson`, `--log-normal`, `--beta`. Anyone
depending on a specific seeded float stream from a prior version must re-bless.
Documented in README and CHANGELOG.

**`--about`** adopts the fleet one-line format (name, version, platform, arch),
replacing the current prose sentence. Approved 2026-07-31.

## 10. Non-goals

- Matching the *old* float output. It was never portable; reproducing it would
  reproduce the defect.
- Matching any particular libm. We are not glibc-compatible or musl-compatible;
  we are **self-compatible**, which is the property that was actually wanted.
- Correctly-rounded transcendentals. Accuracy need only be sufficient for valid
  distributions; §4.5 shows eight orders of margin.
- Arbitrary-precision arithmetic. Rejected: 168-digit denominators per `exp`
  call, still requires a truncation policy, orders of magnitude slower than the
  hot-loop target, and it would couple the oracle to the code under test.
