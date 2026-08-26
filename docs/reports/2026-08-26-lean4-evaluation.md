# Lean 4 evaluation for `random`

**Date:** 2026-08-26 EDT
**Toolchain:** Lean 4.30.0 / Lake 5.0.0
**Scope:** independent deterministic DRBG model and proofs; compatible
`randoml` command family; state-schema and byte-delimiter enhancements across
all frontends

## Outcome

Lean was useful here, but not in the simplistic sense that “the program is now
proved correct.” The project now has an independent pure Lean implementation
of the exact BLAKE3 derive-key plus keyed-empty-message XOF construction used by
the DRBG, including seekable reads, big-endian draws, and narrow/wide rejection
sampling. Its seed-42 64-byte stream matches the frozen external oracle.

Lean's kernel checks useful state and sampling invariants: successful fills
advance by exactly the requested byte count, preserve the key, and leave the
result cursor at or below the 2^53 position ceiling; successful seeks set the requested cursor; stream slices
compose across resumptions; modulo mapping stays within its requested span; and
any schedule of adjacent swaps preserves the input population.

The complete `randoml` CLI is deliberately narrower as a correctness claim. It
delegates parsing, system entropy, formatting, charts, stdin operation details,
and nonlinear fixed-point distributions to the sibling `randomz` executable.
It therefore provides the complete user surface and participates in the shared
state/statistical/benchmark gates, but it is not a fourth independent oracle
and the delegated behavior is not proved by Lean.

That distinction is the most important result of the exercise: a theorem about
a clean model is valuable, but it becomes a theorem about the shipped program
only when the executable is the proved definition or a refinement theorem
connects the implementation to it.

## Proof and evidence matrix

| Claim | Status | Evidence or boundary |
|---|---|---|
| Lean BLAKE3 DRBG produces the frozen seed-42 stream | Tested independently | Trust-zero Lean evaluation against the existing 64-byte frozen vector |
| Lean seek/read agrees across seeds and BLAKE3 block boundaries | Differentially tested | Five LuaJIT-oracle cases at offsets 0, 1, 63, 64, and 4097, with reads up to 130 bytes |
| A successful fill advances the cursor exactly | Proved | `fill_advances_position` |
| A successful fill preserves the derived key | Proved | `fill_preserves_key` |
| Fill and seek respect/set the supported position | Proved | `fill_respects_position_limit`, `seek_sets_position` |
| Splitting a logical stream read preserves order/content | Proved for the stream model | `stream_slice_chunking` |
| Accepted modulo mapping is inside `[start,start+span)` | Proved | `mapped_draw_is_in_range` |
| Shuffle steps cannot add/drop bytes | Proved for arbitrary adjacent-swap schedules | `swap_schedule_preserves_population` |
| Lean BLAKE3 definition matches the complete BLAKE3 standard | Not formally proved | Frozen vector plus the existing three independent implementations; no formal standard model |
| Rejection sampling is statistically uniform | Not formally proved | Arithmetic mapping bound is proved; acceptance/uniformity remains a mathematical argument plus differential/statistical tests |
| Nonlinear fixed-point distributions are correct | Not proved by Lean | Delegated to `randomz`; already covered by independent LuaJIT/Zig/Rust differential and statistical controls |
| CLI parsing, JSON, entropy, formatting, and terminal protocols are correct | Not proved by Lean | Delegated and tested through the shared Bash contract |
| BLAKE3 is cryptographically secure | Outside proof scope | Relies on BLAKE3's external cryptographic analysis; these proofs establish program invariants, not PRF security |
| Compiler, runtime, kernel, and hardware are correct | Assumed trusted base | Standard systems boundary |

The trusted Lean source contains no `sorry`, `admit`, project `axiom`, or
`unsafe` declaration. `lean --trust=0` elaborates it. `#print axioms` reports
only Lean's standard `propext` and `Quot.sound` dependencies where simplification
and `ByteArray` equality require them; `sorryAx` and `Classical.choice` are
rejected by the gate.

The external control is mutation-sensitive: changing one bit in the Lean
BLAKE3 IV made the vector/differential gate fail, and restoring it returned the
gate to green.

## Hard decisions made overnight

### State schema and application version

Renaming `args.operation` to `args.op` and `args.delimiter` to `args.delim`
changes the serialized contract, so I bumped `sv` from 1 to 2 and rejected v1
instead of maintaining compatibility aliases. The project explicitly does not
need legacy-state compatibility. I bumped the application/package version from
0.2.0 to 0.3.0 because this is a deliberate public CLI/state change, not a
patch-level correction.

### State on stdout

The flag is `--state-stdout`, not bare `--stdout`, because ordinary values
already use stdout. Payload remains first and the canonical compact state is
the final line. Successful state is moved, not duplicated, so stderr is empty;
errors remain structured JSON on stderr. The flag implies deterministic mode,
auto-seeds when necessary, conflicts with `--true-random`, and rejects raw
binary unless it is encoded with `--hex` or `--base64`. These choices make
`tail -n1` sufficient without inventing a second envelope or repeating large
value arrays.

### Empty delimiters mean bytes

For `--choose` and `--shuffle`, `--delimiter ''` treats every input byte as an
item. It does not trim a trailing newline and does not decode UTF-8, so NUL and
invalid UTF-8 survive. Shuffle concatenates the permuted bytes and writes the
ordinary final newline; choose writes one selected byte and a newline.
`--weighted` rejects this mode because `value:weight` records cannot be
represented when every byte is independently tokenized. Byte semantics were
chosen over Unicode code points or grapheme clusters because they are exact,
cross-platform, binary-safe, and match the requested `Peter` example.

### Lean implementation boundary

I rejected pretending that a subprocess wrapper was an independent fourth
implementation. A complete independent Lean port of the 684-line fixed-point
kernel, every nonlinear sampler, JSON parser, terminal renderers, and OS
backends would have produced a large volume of new code faster than meaningful
refinement proofs could be written. That would optimize for the label “Lean
port,” not for justified confidence.

Instead, the independent Lean portion stops at a coherent, security-relevant
boundary: BLAKE3 DRBG, seek/state semantics, endian draws, and unbiased integer
range mechanics. The compatibility executable delegates the rest and says so
in source, docs, and this report. A future phase can move fixed-point functions
into Lean one operation at a time, with a specification and refinement theorem
before switching the production path.

### Lean formatting and argv limitations

Lean 4.30 rejects tab indentation in source files, so `.lean` files use spaces
despite the repository's tab preference. This is enforced by the parser.

Lean's ordinary `main (arguments : List String)` boundary also decodes OS argv
as Unicode strings. Invalid UTF-8 is replaced before Lean code can distinguish
it from a literal U+FFFD argument. `randoml` rejects arguments containing that
replacement character so the shared invalid-UTF-8 safety checks fail closed,
but this also rejects a genuinely encoded U+FFFD delimiter. Achieving exact
raw-argv parity would require a native launcher/FFI boundary. Since `randoml`
already delegates its CLI surface, adding that complexity now would not improve
the proved core and was deferred explicitly.

### Runtime `libm` linkage

The Lean runtime links symbols from `libm` even though `lean/Randoml` contains
no floating-point type or operation and the deterministic model is integer
only. The old binary-level “no libm dependency” test therefore cannot classify
a managed runtime correctly. For Lean, the gate structurally scans the trusted
model; it does not misrepresent unrelated runtime linkage as deterministic
floating-point arithmetic. The production nonlinear output remains the
integer-only `randomz` backend.

### Native systems and Nix closure

The flake no longer uses flake-utils' generic default-system list: current
nixpkgs has dropped x86_64-darwin and this project already dropped that target.
Native flake outputs are now exactly x86_64-Linux, aarch64-Linux, and
aarch64-macOS; Windows remains an intentional cross-build target.

The first installed package also retained a 2.4 GiB closure. Two unrelated
causes were fixed rather than accepted as “the cost of Lean”: the installed
80-case CLI self-test had inherited the full CI toolchain (Zig/LLVM, Node,
ImageMagick, WASM, and Sixel tools), and Zig source paths embedded in the WASM
made Nix retain the entire compiler closure. The self-test now closes over only
the utilities it actually executes, and the inert WASM store reference is
neutralized during installation. Installed-package smoke still runs all
frontends' shared self-tests and validates the WASM. The measured closure is
127.8 MiB, down from 2.4 GiB.

## Correctness versus performance

Proofs add compile-time cost and source complexity, but zero runtime cost when
they describe definitions erased from execution. The pure Lean BLAKE3 model is
clear enough for frozen-vector evaluation and theorem work, but it has not been
micro-optimized and is not yet the CLI's payload engine. The current `randoml`
benchmark row measures Lean process startup plus a `randomz` child process; it
is useful as an end-user latency measurement, not as Lean-versus-Zig algorithm
throughput.

This split is preferable to publishing a misleading fast number from delegated
code or a misleading correctness claim about code the theorem does not reach.
If Lean becomes the execution engine later, benchmark pure DRBG throughput,
allocation, executable size, and nonlinear samplers separately; proof erasure
does not guarantee an efficient extracted program.

The first release build unnecessarily enabled Lean interpreter support and was
10,320,384 bytes after stripping. The release review removed that setting; the
same stripped executable is 2,007,232 bytes, versus 653,088 bytes for `randomz`
and 1,007,424 bytes for the unwrapped Rust CLI on this x86_64-Linux build. The
remaining size is principally Lean runtime/startup machinery, not precomputed
random tables.

The three-run `./bm --quick` measurement below sent timed payloads to
Hyperfine's null sink and sent its history to `/dev/null`; no generated payload
or benchmark history was written to disk. Times are end-to-end mean wall time:

| Workload | LuaJIT | Zig/C | Rust | `randoml` adapter |
|---|---:|---:|---:|---:|
| 1 MiB raw | 197.1 ms | 3.7 ms | 2.6 ms | 8.9 ms |
| 1 MiB hex | 239.6 ms | 8.3 ms | 5.1 ms | 20.0 ms |
| 1 MiB base64 | 247.1 ms | 9.0 ms | 4.4 ms | 18.2 ms |
| 5,000 uniform small | 18.7 ms | 4.8 ms | 3.9 ms | 12.7 ms |
| 5,000 uniform wide | 28.2 ms | 4.6 ms | 4.8 ms | 11.6 ms |
| 5,000 normal | 324.3 ms | 12.8 ms | 14.9 ms | 20.9 ms |
| 5,000 exponential | 300.5 ms | 8.7 ms | 13.0 ms | 14.4 ms |
| 5,000 Poisson | 617.0 ms | 30.0 ms | 32.4 ms | 34.8 ms |
| 5,000 log-normal | 465.0 ms | 16.5 ms | 20.7 ms | 24.0 ms |
| 5,000 beta | 908.5 ms | 38.5 ms | 43.3 ms | 47.7 ms |

All ten benchmark payload digests were identical across the four packaged
frontends and the unwrapped Rust timing binary before timing began. The Lean
adapter is 1.16–4.15× the fastest implementation in these amortized batches;
the gap shrinks on compute-heavy distributions because its extra process
startup is fixed while `randomz` performs the same payload work underneath.

The separate fast statistical suite also passed 46 sanity/sensitivity checks
for each of four command families (184 target checks total). It used 262,144
raw bytes and 10,000 values per distribution and rejected its deliberately bad
all-zero/constant controls. These numbers establish gross-shape sanity, not
cryptographic security, and `randoml`'s statistical row measures delegated
`randomz` output rather than the independent Lean model.

## What Lean caught or clarified

- It forced the cursor/seek contract into explicit preconditions and made the
  successful-state postconditions mechanically checkable.
- The release review found that the first `fill` definition only bounded the
  requested count against natural-number subtraction. A manually constructed
  state already beyond the ceiling could therefore accept a zero-byte fill.
  Tightening the definition and theorem made the result cursor itself the
  proved postcondition; no production stream or frozen vector changed.
- Proving stream-slice composition clarified the exact property continuation
  needs: the stored cursor is a byte offset, not an output-item index.
- Proving swap-schedule preservation separated the deterministic choice of
  indices from the invariant users actually need—no input byte is created or
  lost.
- It exposed two boundary facts that ordinary porting language can hide:
  standard Lean argv is not byte-preserving, and linking `libm` says nothing by
  itself about whether a managed-language deterministic core uses floats.
- It did not uncover a divergence in the existing DRBG. The independent Lean
  compression/KDF/XOF implementation matched the frozen stream immediately
  after one local implementation mistake in the new code (message words were
  initially indexed from the working state) was caught during its own first
  build/review and corrected before any vector was accepted.

## Recommendation

Use Lean selectively for libraries where a small pure kernel carries a large
share of the risk: parsers with crisp grammars, serialization/state machines,
bounded arithmetic, cryptographic framing, allocation/accounting invariants,
and transformations such as shuffles that have strong conservation laws.

Do not begin by proving a whole CLI or by rewriting every mature numerical
routine. First identify a narrow executable kernel and an independently useful
specification. Require:

1. the production definition itself to be proved, or an explicit refinement
   theorem connecting production code to the model;
2. external vectors/differential tests for underspecified algorithms and for
   mistakes shared by a model and its proofs;
3. mutation controls showing the gates can reject plausible defects;
4. a published claim matrix separating proved, tested, externally assumed,
   and out-of-scope properties;
5. `--trust=0`, forbidden proof escapes, and `#print axioms` in CI.

For `random`, the best next Lean investment is to formalize the complete
rejection loop and connect `Blake3.xofAt` to `streamSlice`, then port and refine
one fixed-point primitive with the highest historical defect rate. Only after
those links are proved should `randoml` replace delegation for that path. Lean
is worth using here as a precision tool and executable specification; it is not
yet justified as a wholesale replacement for the three mature independent
implementations.

## Verification summary

The pre-shipment local gate passed all 21 suites, 700 shared state/continuation
checks, 184 statistical sanity/sensitivity checks, ten benchmark parity
digests, 11 Zig/C cross-compilation targets, WASI validation, installed-package
self-tests, trust-zero Lean elaboration/axiom audit, and the controlled Lean
mutation. Exact CI status is reported with the shipping handoff.
