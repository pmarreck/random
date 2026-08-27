# Lean 4 evaluation for `random`

**Date:** 2026-08-26 EDT
**Toolchain:** Lean 4.30.0 / Lake 5.0.0
**Scope:** complete independent `randoml` library and CLI, selected machine-checked
production invariants, shared differential/statistical tests, packaging, and
performance evaluation

## Outcome

`randoml` is a fourth independent implementation, not a compatibility wrapper.
Its importable Lean library owns the BLAKE3 derive-key/keyed-XOF DRBG, exact
fixed-point arithmetic, all distributions, state parsing and serialization, CLI
semantics, formatting, byte-oriented stdin operations, and the canonical chart
model and encoders. It neither launches nor links LuaJIT, Zig, or Rust for normal
operation.

The native C boundary is intentionally small and contains only I/O-facing work:
raw byte-preserving argv capture, OS entropy, platform identification, Lean
runtime startup, and Base64 transport acceleration. Lean-generated C and these
small native objects are linked into one `randoml` executable. The C code does
not select distributions, advance deterministic state, parse state JSON, format
numbers, shuffle items, or construct chart geometry.

This changes the conclusion of the earlier delegated experiment. There was no
defensible metric behind the statement that Lean was “not yet justified as a
wholesale replacement”: that statement measured a subprocess wrapper, not a
Lean implementation. It is retracted. The completed experiment shows that Lean
is a strong fit for this library's integer-heavy core and materially increases
assurance, although the present proofs cover selected invariants rather than
the entire numerical or cryptographic specification.

## Architecture and trust boundary

The production path is:

```text
raw OS argv / entropy
        │
        ▼
thin native C boundary
        │
        ▼
Lean CLI ──► pure Lean DRBG / fixed arithmetic / distributions / state / charts
        │
        ▼
stdout and structured stderr
```

The `Drbg` constructor is private. Public construction and restoration validate
the 32-byte key and the 2^53 cursor ceiling. Public BLAKE3 helpers return
`Option`, reject unsupported key/message shapes, and cap a single `fill` at 1
MiB; larger CLI streams are produced in bounded chunks. These boundaries prevent
callers from manufacturing the invalid states on which earlier proof statements
quietly depended.

One architectural imperfection remains explicit in `PLAN.md`: deterministic
sampling uses the pure `Distribution` definitions, while the true-random
interpreter repeats sampler control flow in the effectful Lean `CliSource`
module so it can request OS bytes. The business logic is still Lean-owned and
matches the oracle, but a future pure byte-source effect should make the two
interpreters share one sampler program.

## Proof and evidence matrix

“Proved” below means Lean 4.30 elaborated the production-linked theorem under
`--trust=0`; the source contains no `sorry`, `admit`, project `axiom`, `unsafe`,
or nonterminating `partial` definitions. The gate checks the exact theorem types
through `ProofContract.lean`, audits each theorem's dependencies with
`#print axioms`, and permits only the expected kernel-level `propext` and
`Quot.sound` dependencies where needed.

| Claim | Status | Evidence or boundary |
|---|---|---|
| Successful `Drbg.fill` advances by exactly the requested bytes | Proved on the production definition | `fill_advances_position` |
| Successful fill preserves the derived key and respects the 2^53 ceiling | Proved on the production definition | `fill_preserves_key`, `fill_respects_position_limit` |
| Successful seek sets the requested cursor | Proved on the production definition | `seek_sets_position` |
| `nextU32`, `nextU64`, and uniform draws advance by 4/8/4 bytes and preserve the key | Proved on production definitions | six cursor/key theorems |
| Every successful rejection-sampled range result is inside its requested inclusive bounds | Proved, including the bounded rejection loop | `rangeWithFuel_result_bounds`, `range_result_bounds` |
| Canonical and positive parameter wrappers preserve their represented value/invariants | Proved | canonical/positive/normal/beta parameter theorems |
| Production shuffle steps and schedules neither add nor drop items | Proved for every supplied swap schedule | production shuffle permutation theorems |
| Curve height is zero for nonpositive inputs and saturated at/above one | Proved on the production function | two curve-height theorems |
| Splitting an arbitrary logical stream slice preserves order/content | Proved for the abstract stream model | `stream_slice_chunking` |
| Actual BLAKE3 XOF/fill bytes compose identically across resumed chunks | Executably tested, not yet formally connected to the abstract theorem | direct production `fill(a+b)` versus `fill(a); fill(b)` controls across 63/64-byte boundaries, plus external 65,535–65,538-byte CLI differentials |
| Lean BLAKE3 matches the standard and the other implementations | Tested, not formally refined to a separate standard model | official empty and `abc` BLAKE3 vectors; frozen seed-42 stream; offset/block-boundary differentials |
| Fixed-point operations and all nonlinear distributions match the contract | Differentially and statistically tested, not proved end-to-end | 141 exact CLI cases, continuation matrix, benchmark digests, and statistical shape/sensitivity suite |
| State parser/serializer, CLI parser, codecs, stdin operations, and chart transports match | Exactly tested, not proved | shared 80-case Bash contract, parser limit fixtures, 736 continuation checks, frozen chart layers, exact frontend differential |
| Rejection sampling is statistically uniform | Not formally proved | result bounds are proved; uniformity relies on the standard argument plus statistical controls |
| BLAKE3 is a secure PRF/XOF and this construction is a CSPRNG | External cryptographic assumption | proofs establish implementation invariants, not cryptographic security |
| Lean compiler/runtime, C compiler, OS, and hardware are correct | Trusted base | conventional systems boundary; native runtime parity beyond x86_64 Linux remains planned |

The abstract stream theorem is deliberately described as abstract. It does not
silently stand in for a refinement proof about `Blake3.xofAt`; connecting those
definitions is the most important remaining formal task.

## What the independent port found

- The singleton inclusive range path originally consumed four bytes in Lean even
  though LuaJIT, Zig, and Rust consume zero. The independent implementation made
  the cursor discrepancy visible; the Lean path was corrected and the behavior
  is now in the shared state test.
- The first state parser was recursively partial and had looser resource limits.
  It is now structurally total, capped at 1 MiB, 64 levels, 32 object members,
  and 1,024 array items, with exact accepted/rejected boundary fixtures.
- A pre-parse scan for `--help`, `--about`, and `--test` confused option values
  with actions—for example, a delimiter literally named `--help`. Actions now
  come only from the value-aware parser.
- Standard Lean `main (List String)` cannot preserve invalid UTF-8 argv. The thin
  native launcher fixed this instead of accepting a missing feature or false
  rejection. Raw input bytes now reach Lean unchanged.
- Public `ByteArray`/`Array` constructors initially exposed invalid BLAKE3/DRBG
  states and made some theorem preconditions social rather than typed. Private
  constructors and checked factories now enforce them.
- Pure Lean Base64 was correct but took roughly 22 seconds for 1 MiB. Moving only
  that transport primitive to the native edge reduced the same exact output to
  about 104 ms end-to-end while leaving DRBG bytes and chart construction in
  Lean. Frozen byte digests and terminal framing guard the boundary.
- The code review caught a Windows entropy hazard before runtime testing:
  `BCryptGenRandom` accepts a 32-bit length. The C edge now chunks larger `size_t`
  requests rather than narrowing them and risking an uninitialized tail.
- The review also forced the project to distinguish theorem-shaped reassurance
  from production-linked evidence. Exact theorem-type witnesses, a strict axiom
  whitelist, private state constructors, official vectors, and an independence
  gate now make weakening substantially louder.

Lean did not expose a divergence in the established BLAKE3 deterministic stream.
The new implementation did initially contain an ordinary porting error—message
words were indexed from the working state—which the official/frozen vector gate
caught before any output was accepted.

## Runtime `libm` linkage

The source and generated deterministic logic use no floating-point type or
operation. The final ELF nevertheless has a `libm` dependency because Lean's
general native runtime/link configuration brings that system library into the
executable. A dynamic-library name is therefore not evidence that this program's
numeric core uses floating point. The appropriate controls are structural source
checks, integer-only definitions, exact cross-implementation bytes, and the
absence of float/libm calls in the implementation code—not pretending the Lean
runtime has a narrower dependency set than it does.

## Performance and size

The three-run `./bm --quick` measurement below used direct argv, one warmup, and
a null sink for timed payloads. It first compared digests for every workload; all
ten payloads were byte-identical across LuaJIT, Zig/C, Rust, and Lean. Times are
end-to-end means on the current x86_64-Linux host:

| Workload | LuaJIT | Zig/C | Rust | Lean |
|---|---:|---:|---:|---:|
| 1 MiB raw | 197.0 ms | 3.1 ms | 2.6 ms | 103.4 ms |
| 1 MiB hex | 238.8 ms | 8.2 ms | 5.5 ms | 120.4 ms |
| 1 MiB Base64 | 241.0 ms | 7.3 ms | 4.3 ms | 104.3 ms |
| 5,000 uniform small | 22.5 ms | 4.6 ms | 3.8 ms | 48.8 ms |
| 5,000 uniform wide | 26.7 ms | 5.8 ms | 4.9 ms | 56.6 ms |
| 5,000 normal | 298.1 ms | 13.1 ms | 15.3 ms | 564.4 ms |
| 5,000 exponential | 306.2 ms | 9.4 ms | 13.2 ms | 467.2 ms |
| 5,000 Poisson | 618.2 ms | 30.8 ms | 33.3 ms | 1.462 s |
| 5,000 log-normal | 465.0 ms | 17.1 ms | 21.9 ms | 912.9 ms |
| 5,000 beta | 862.7 ms | 38.2 ms | 43.0 ms | 1.705 s |

Lean is about 24–40× slower than the fastest implementation for the 1 MiB byte
workloads and 12–53× slower for these value/distribution batches. The nonlinear
gap comes from the clear reference-style arbitrary-precision/fixed-point code,
not from proof checking—the proofs are erased from runtime. This is acceptable
for an oracle and many ordinary CLI uses, but not yet competitive for a hot
generation path. The measured results also identify concrete optimization work
rather than guessing that extraction will be fast.

The dedicated stripped `randoml` executable is 2,781,384 bytes and its Nix
runtime closure is 120.7 MiB on x86_64 Linux. That is larger than the 653,088-byte
Zig/C and 1,007,424-byte Rust binaries measured during this work, but it is not a
precomputed-random table cost. It is principally Lean runtime and generated-code
machinery. Removing unused interpreter support had already eliminated the first
10.3 MiB binary and a packaging review reduced an accidental 2.4 GiB closure.

## Platform evidence

Deterministic CLI equality for `randoml` is measured on x86_64 Linux. The flake
defines native Lean package outputs for x86_64 Linux, aarch64 Linux, and aarch64
macOS, but this session did not download and execute the multi-gigabyte aarch64
closure merely to convert a source claim into a weak emulated one. The native C
entropy edge is compile/provenance-gated for Linux, macOS, OpenBSD, FreeBSD,
NetBSD, illumos/Solaris, and Windows, and Linux entropy failure is injected and
verified to fail closed. Native Lean runtime/digest legs for aarch64 Linux/macOS
and a supported Windows Lean toolchain remain explicit plan items.

Accordingly, the repository-wide cross-platform-identical contract remains
strongly evidenced by the established LuaJIT/Zig/Rust architecture matrix; the
Lean implementation is a fourth exact oracle on the measured host, not yet an
independent multi-architecture confirmation.

## Other hard decisions

- State schema version 2 uses the short `args.op` and `args.delim` keys and does
  not preserve schema-1 compatibility, as the project explicitly permits
  breaking legacy state.
- `--state-stdout` moves canonical continuation state to the final stdout line;
  it does not duplicate potentially large value streams in JSON.
- Empty delimiter mode treats choose/shuffle input as raw bytes, including NUL
  and invalid UTF-8. Weighted records reject that mode because byte items cannot
  represent `value:weight` records.
- Lean source uses spaces because Lean 4.30 rejects tab indentation. Shell, C,
  Nix, and other repository files retain the project's tab preference where
  their formatters/parsers allow it.

## Recommendation

For this library, keep and deepen the complete Lean implementation. It already
provides three kinds of value that a model beside a delegated wrapper could not:

1. a genuinely independent typed implementation that catches differing state
   and parser assumptions;
2. kernel-checked properties of the actual production definitions; and
3. an executable oracle whose exact outputs can challenge all three mature
   implementations.

Lean is especially well matched to deterministic integer libraries with explicit
state, bounded arithmetic, parsers, serialization, and conservation properties.
The tradeoff is real: implementation/proof effort is higher, runtime is currently
much slower, and “written in Lean” does not imply end-to-end correctness.

For libraries seeking similar assurance:

1. make the proved definition the production definition, or publish a refinement
   theorem that connects them;
2. pair proofs with independent official vectors, differential/property tests,
   and mutation-sensitive controls;
3. publish a claim matrix separating proved, tested, externally assumed, and
   out-of-scope properties;
4. close constructors around invariants instead of documenting them as caller
   obligations;
5. gate `--trust=0`, forbidden proof escapes, exact theorem signatures, and
   explicit axiom dependencies in CI; and
6. measure the extracted executable before deciding whether it is a production
   hot path, an authoritative oracle, or both.

The next formal priorities are to connect actual `Blake3.xofAt`/`Drbg.fill` bytes
to the abstract stream theorem, add a separate BLAKE3 specification/refinement
layer, and prove more of the fixed-point and distribution error bounds. The next
architectural priority is the shared pure byte-source sampler program described
above. These are reasons to continue the Lean investment, not grounds for
discounting the complete implementation already delivered.

## Verification summary

The final pre-shipment gate covers 22 required suites, the shared 80-case CLI
contract against all four command families, 141 exact LuaJIT-versus-Lean cases,
736 all-direction continuation checks, official/frozen vectors, production
chunking boundaries, parser resource boundaries, chart layer and framing
fixtures, trust-zero proof elaboration and exact axiom auditing, independence
controls, statistical shape/sensitivity checks, entropy fault injection and
cross-compilation, package self-tests, ten benchmark digest comparisons, and the
existing Zig/Rust/WASI/cross-architecture gates. Exact CI status belongs to the
shipping handoff rather than being predicted here.
