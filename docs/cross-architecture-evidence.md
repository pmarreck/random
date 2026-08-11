# Cross-architecture determinism: evidence

**Date:** 2026-08-02; BLAKE3 DRBG extension re-verified 2026-08-04;
Rust extension verified 2026-08-11 ·
**Suite:** `tests/cross_arch_diff` (`./crossarch`)

## What was actually at stake

The README's headline claim is that a seeded stream is bit-identical across
machines, operating systems and CPU architectures. Until this suite existed
that claim rested on an *argument* — the kernel is integer-only, and integer
arithmetic is fully pinned by the language where transcendental float math is
not — and on **zero** non-x86_64 measurements. The whole project exists to
make that claim true, so leaving it unmeasured was the largest outstanding
gap in it.

An argument is not evidence. This file is the evidence.

## Design

Four interpreters, **all built from the identical pinned LuaJIT source**
(`flake.nix`'s `pinLuajit`, rev `28084004`, reporting `LuaJIT 2.1.1785606157`
on every leg) so that LuaJIT version is held fixed and only the platform
varies:

| leg | architecture | libc | OS | how |
|---|---|---|---|---|
| `x86_64-glibc` | x86_64 | glibc | Linux | native (baseline) |
| `x86_64-musl` | x86_64 | musl | Linux | native, `pkgsMusl` |
| `aarch64-qemu` | aarch64 | glibc | Linux | `pkgsCross` + qemu user-mode |
| `aarch64-darwin` | aarch64 | Apple libSystem | macOS 26.5 | **native M4 Max hardware** |

Four payloads:

- **kernel** — `tests/kernel_jit_diff.lua`, reused verbatim. Sweeps `div`,
  `mul`, `add`, `sub`, `norm`, `ln`, `exp`, `cos_turns`, `sqrt`, `pow` over
  ~720 000 mixed-sign values. Reused rather than written fresh **on purpose**:
  it is code that was not authored to make this test pass, so it cannot have
  been tuned to.
- **decimal** — `tests/cross_arch_decimal.lua`, covering the public surface the
  above does not touch: `parse`, `tostring`, `parse_int`, `parse_int_safe`,
  `from_int`, `to_int_trunc`, `frac`, `cmp`, `mul128`. Decimal I/O is exactly
  where a platform `strtod`/`printf` would re-enter an otherwise integer-only
  program.
- **drbg** — `tests/cross_arch_drbg.lua`, 4096 bytes from the versioned KDF and
  keyed BLAKE3 XOF, with chunked-consumption and seek assertions against the
  one-shot stream. This payload was added with the 2026-08-04 PCG32→BLAKE3
  migration and rerun on all four legs, including native M4 Max hardware.
- **cli** — `bin/random` end to end, byte-exact stdout, 54 invocations spanning
  four seeds and the full integer/nonlinear/binary surface.

## Results

sha256 of stdout, first 16 hex digits, `FAST=1`:

| payload | x86_64-glibc | x86_64-musl | aarch64-qemu | aarch64-darwin |
|---|---|---|---|---|
| kernel | `cbafb0f3177483e1` | `cbafb0f3177483e1` | `cbafb0f3177483e1` | `cbafb0f3177483e1` |
| decimal | `943f23170e87eb3d` | `943f23170e87eb3d` | `943f23170e87eb3d` | `943f23170e87eb3d` |
| BLAKE3 DRBG | `5c2ce6fe2d53725c` | `5c2ce6fe2d53725c` | `5c2ce6fe2d53725c` | `5c2ce6fe2d53725c` |
| *control:* libm | `d74d06aa0e68f67d` | `622518d5ffc3a60f` | `d74d06aa0e68f67d` | `763ae34a97400ca9` |
| *control:* float2int | `ddcc9fd67f79fb99` | `ddcc9fd67f79fb99` | `1ae5e1a5aa89121b` | `1ae5e1a5aa89121b` |

Plus 54 CLI invocations byte-identical across the three local legs.
The native remote section directly rechecked kernel, decimal, and the new DRBG
payload; it does not currently rerun the full CLI matrix remotely.

**The claim holds.** Every payload row is constant across all four platforms.

## Zig/C extension (2026-08-04)

The same suite now builds and executes the independent Zig/C implementation in
ReleaseFast mode. Its local matrix is:

| leg | architecture | libc | execution |
|---|---|---|---|
| `x86_64-glibc` | x86_64 | glibc | native |
| `x86_64-musl` | x86_64 | musl, static | native |
| `aarch64-musl` | aarch64 | musl, static | qemu user-mode |

Two new payloads passed:

- The raw `differential-driver` fixed-point output is byte-identical on all
  three targets. This is load-bearing because a CLI-only comparison can hide a
  one-ULP kernel defect through decimal formatting or integer quantization.
- `randomz`, the C CLI linked only through `include/randomz.h`, runs the same 54
  seed/flag/stdin cases on all three targets. Every framed payload is
  byte-identical both across the targets and against the native LuaJIT oracle.

The required suite also cross-compiles the frontend for aarch64-macOS,
x86_64-Windows-GNU, and aarch64-Windows-GNU. Compilation is not counted as
execution evidence; the optional native-remote leg builds and executes the
Zig/C payloads when supplied.

## Rust extension (2026-08-11)

`randomr` adds a third implementation rather than a wrapper around either
oracle. The deterministic library is integer-only Rust, uses the official
pure-Rust BLAKE3 crate backend, and shares no implementation code or FFI with
LuaJIT or Zig. The CLI is a separate crate.

The default suite first requires the complete 141-case LuaJIT↔Zig matrix to
agree, then independently requires the same matrix for Rust↔LuaJIT and
Rust↔Zig. The cross-architecture suite additionally runs the 54-invocation
end-to-end payload against the LuaJIT oracle on:

| leg | architecture | libc | execution |
|---|---|---|---|
| `randomr-x86_64-glibc` | x86_64 | glibc | native |
| `randomr-aarch64-glibc` | aarch64 | glibc | qemu user-mode |

Both Rust legs were byte-identical to LuaJIT on all 54 invocations. The same
positive sensitivity controls described above prove that the run can observe
both its libc and architecture axes before this verdict is accepted.

Cross-build evidence currently covers native Linux x86_64, Linux aarch64,
Windows x86_64, a license-free Windows ARM64 PE (`aarch64-pc-windows-gnullvm`
linked with Zig), FreeBSD x86_64, and NetBSD x86_64. The latter two use the
standard libraries Rust 1.97 actually distributes plus Zig's BSD sysroots.
Rust 1.97 distributes no standard-library artifact for OpenBSD or for any of
these BSD ARM64 targets; those four combinations are named target-library gaps,
not passing skips. Native macOS ARM64 and Windows ARM64 workflow legs completed
successfully for commit `5ae3524` in [GitHub Actions run
31524554055](https://github.com/pmarreck/random/actions/runs/31524554055). Both
validated their architecture, a 131-byte stream, the complete nonlinear and
wide-range/stdin payload against frozen oracle digests, OS entropy, and the
installed CLI self-test on first-party hosted ARM64 runners.

Five test-only mutations prove the Rust controls are live: a broken candidate
selector, a successfully executing Zig producer that corrupts the final
Rust-versus-Zig comparison, feature-gated entropy injected across the pure-core
boundary, a perturbed nonlinear fixed-point constant, and an entropy source
that incorrectly reports EOF as success each make the expected gate red.

## Why the control rows are the important part

A negative assertion — "these outputs are identical" — is unfalsifiable
without evidence that the comparison could have come out the other way. This
project has already shipped that exact failure: a differential that passed
because *both* invocations failed and both digests were of empty stdout.

So the control rows are deliberately fragile payloads, and their **split
pattern is the proof**:

- **libm** splits three ways. glibc and musl differ (measured over this
  program's own input domain: `log` on 0.006% of inputs, `cos` on 3.06%, `exp`
  on 8.85%); Apple's libSystem differs from both. glibc-x86_64 and
  glibc-aarch64 agree, so this control is **blind to the architecture axis**.
- **float2int** splits exactly two ways, along architecture. Out-of-range
  `double`→integer conversion is architecture-defined: x86_64's `cvttsd2si`
  yields the "integer indefinite" value (`INT64_MIN`) for anything
  unrepresentable including NaN, while aarch64's `fcvtzs` saturates to
  `INT64_MAX`/`INT64_MIN` and maps NaN to `0`. Both x86_64 legs agree and both
  aarch64 legs agree, so this control is **blind to the libc axis**.

Neither control alone covers both axes. Using only the libm one — the obvious
choice, since libm divergence is the defect this project was built to
eliminate — would have left the *architecture* axis, the headline claim, with
no demonstrated sensitivity whatsoever.

**Emulation fidelity, established rather than assumed:** `aarch64-qemu` and
`aarch64-darwin` produce byte-identical `float2int` digests. qemu is therefore
reproducing genuine aarch64 conversion semantics rather than leaking the
host's, which is what makes the emulated leg worth running at all.

## Mutation testing

A guard never observed failing is not yet a guard; this project shipped five
that could not detect being broken. Each control was broken deliberately and
confirmed to fire, then restored and confirmed to pass:

| control | mutation | result |
|---|---|---|
| divergence detection | libm-derived 1-ulp contaminant in `M.ln` | `DETERMINISM CLAIM VIOLATED` (glibc vs musl), 2/2 runs |
| liveness | payload crashed (ctype table overflow) | `exit 1 running kernel_jit_diff.lua` |
| sensitivity | libm control emits a constant | `SENSITIVITY LOST (libc axis)` |
| reflexivity | ASLR pointer mixed into the digest | `NOT self-reproducible` on all 3 legs |

**A finding from that exercise, worth keeping:** under the `M.ln` contaminant
the **CLI payload still reported identical**. At the then-current six-place
output precision, a 1-ulp perturbation of a 63-bit mantissa was invisible, and
the integer-range modes quantized it away entirely. The kernel payload is what
actually carries the weight here — a CLI-level differential alone, which is
what the original port kickoff proposed, would have passed this mutation.

## Three mistakes made and corrected while building this

Recorded because the corrections are the useful part.

1. **Hashed pointers instead of values.** The first `float2int` probe used
   `tostring(ffi.cast("int32_t", x))`, which prints a boxed *address*. Its
   digest varied run to run on a single machine under ASLR and it reported a
   confident `DIFFER` that was pure noise. This is the same mistake that cost
   this project two retracted upstream LuaJIT bug reports
   (`docs/luajit-1499-pin-investigation.md`). Caught by re-running the claim on
   one machine instead of re-reading it. The reflexivity control now exists
   specifically to catch a regression here.
2. **A mutation too weak to prove anything.** The first `M.ln` contaminant was
   derived from the exponent, which takes only ~11 distinct values in the
   sweep — against an 8.85% per-input divergence rate, it perturbed nothing and
   the harness correctly stayed green. Deriving it from the mantissa instead
   swept thousands of distinct libm inputs and the harness fired immediately.
   The mutation was defective, not the harness; "test filters as classifiers
   over sets, not predicates over single examples" applies to mutations too.
3. **Compared byte seeks to character offsets.** The first DRBG payload sought
   to byte 1023 but sliced the one-shot hexadecimal result at character 1024.
   A direct smoke run failed before the matrix was accepted. The expected slice
   now converts the byte interval to `2*offset+1 .. 2*(offset+length)`, and the
   corrected payload agrees on all four platforms.

The remote leg also initially returned empty output and, because its stderr was
being discarded, was undiagnosable. Capturing it revealed the real cause in one
run (`nix build --print-out-paths` yields the store *directory*, not the
binary). The liveness control caught the emptiness; two checks written that
same hour did **not** — `cmp -s` reports two empty files as equal, so
reflexivity cheerfully passed on a leg that had produced nothing. Both are now
`-s`-guarded.

## Caveats — what this does NOT establish

- **Only two executed architectures.** x86_64 and aarch64. No 32-bit, no big-endian,
  no RISC-V. The big-endian case is not merely untested: the controls'
  bit-extraction unions assert little-endianness and refuse to run.
- **Only three Unix libcs** (glibc, musl, Apple libSystem). The Zig/C frontend
  compiles for both x86_64 and ARM64 Windows. Windows x86_64 additionally runs
  under Wine in CI: its 131 raw deterministic bytes match the Lua oracle,
  `.exe` alias dispatch matches the explicit flag, true-random output has the
  requested byte count, and binary stdout is not CRLF-expanded. Zig/C Windows
  ARM64 runtime remains untested; its gate is compile plus PE-machine
  validation. The separate Rust CLI has passed natively on Windows ARM64.
- **One LuaJIT revision.** Held fixed on purpose, so this says nothing about
  behaviour across LuaJIT versions.
- The `aarch64-darwin` leg is opt-in (`CROSS_ARCH_REMOTE=<host>`) and needs
  ssh plus nix on the remote, so a default `./crossarch` run covers three legs,
  one of them emulated.

## Re-running

```sh
./crossarch                                            # 3 local legs
CROSS_ARCH_REMOTE=peters-macbook-pro-m4-max ./crossarch # + native aarch64
FAST= ./crossarch                                      # deep mode
```

First run compiles LuaJIT three ways (once); afterwards `CROSS_TOOLCHAINS=`
can point at the built farm to skip nix evaluation.
