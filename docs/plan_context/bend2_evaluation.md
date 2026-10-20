# Experimental Bend 2 implementation and evaluation

## Status and ownership

Owner: the random project agent. The request was accepted for staged work on
October 20, 2026. The independent pure core implements seed expansion, keyed
empty-message XOF reads, checked state and signed bounded integers. A pinned-source
JavaScript run passes 2,798 independent vector/cursor/range/domain checks; the
packaged compiler and native byte probe pass 36 additional adapter checks. Four
implementation-linked laws pass ordinary and explicit kernel checking, with
implementation/specification mutation controls. All 45 repository suites passed
before checkpoint commit `bc736a2`. The extended evaluation now records 78 core,
startup and CLI cases: 66 valid unbaselined observations and 12 inconclusive
outcomes. No baseline was approved and no consumer was migrated. See the
[scoped report](../reports/2026-10-20-bend2-evaluation.md) and its numeric data.
The new bounded benchmark controls are also required by `./test`.
All 46 default suites passed; the three affected Bend suites also passed after
final upstream-notice packaging and digest verification.
The first CI pass found host-hidden script/ELF interpreter dependencies; an
additional early `bend2-sandbox` gate checks the fixes without replacing any
existing suite or CI target.
There is no owner-decision blocker. Remaining work is cache/arithmetic
optimization, stronger refinement laws, nonlinear distributions and full
frontend/library coverage; none is silently claimed complete.

The experiment must preserve production behavior and all required suites. No
consumer migration or production-ready support claim is authorized. A host
adapter may handle I/O and OS entropy; calling an existing generator through
FFI does not count as a Bend implementation.

## Toolchain selection

Use a recent stable Bend **2.x**, as explicitly requested. On October 20 the
project's locked nixpkgs reports Bend **0.2.37**. Upstream's latest stable
release is **2.0.37**, published October 13, at commit
`4ff8545f19b09b7d2b8ca2303668100eac8efd66`. These are different versions.
Use the [official upstream package](https://github.com/bendlang/bend/blob/4ff8545f19b09b7d2b8ca2303668100eac8efd66/flake.nix)
at that immutable revision, following the existing nixpkgs input. Its generated
flake unexpectedly selects the **2.0.36** archive. An executable-version test
failed on that mismatch. A narrow override now selects the published 2.0.37
archive with its platform-specific SHA-256 digest; remove the override when a
selected upstream tag and its archive agree. Do not update production language
toolchains to obtain Bend.

The core uses explicit U32 limbs because the native runtime caps Nat at
`2^48-1` and has no U64 primitive. Limb arithmetic and cursor tests include the
portable `2^53` boundary. The BLAKE3 API is deliberately the <=64-byte hash
subset needed for the fixed context, 32-byte seed and empty keyed XOF, like the
Lean implementation; it does not claim general multi-block/tree hashing.

The initial laws cover four-byte word encoding, 64-byte block encoding,
zero-length XOF output and the singleton sampler branch. They do not establish
BLAKE3 correctness, general chunk/refinement laws, probability laws or security.
An initial explicit verdict attempt correctly failed while its separate Lean
4.34.0 toolchain/kernel was unavailable. The isolated kernel was then built and
the stronger checks passed. Its headline consistency and termination theorems
use `propext`, `Classical.choice` and `Quot.sound`. Kernel elaboration/C generation
took 30.17 seconds and 935,744 KiB peak RSS; C compilation took 11.49 seconds
and 247,856 KiB peak RSS in the observed build. These are build observations,
not application runtime measurements. The existing production Lean version is
unchanged.

The previous coordinator trial used ordinary checking and generated JavaScript
only. It did not run native code, Nix packaging, GPU execution or the stronger
Lean-backed verdict. Verify the installed compiler identity and pin the verdict
kernel separately before making a stronger proof claim. Native Windows and a
stable C-library export were absent in that reviewed snapshot; revalidate
before reporting support. Do not run a network installer script.

## Staged acceptance

1. Implement the actual pure Bend deterministic core: canonical seed expansion,
   keyed BLAKE3 XOF, exact byte order/cursor behavior and bounded integers.
   Reuse official BLAKE3 vectors and frozen cross-language expectations without
   regenerating expected outputs. Cover zero length, block boundaries,
   chunk/resume equivalence, range endpoints, rejection byte-consumption order
   and degenerate equal-bound ranges. Exhaust affordable finite domains.
2. Add meaningful laws about executed definitions. Use explicit
   `bend PROOF.bend --verdict` with a pinned kernel. Protect the complete
   specification dependency surface, including imported predicates and the
   acceptance command. Deliberate implementation mutations must be rejected;
   timeouts are inconclusive. State assumptions and trusted primitives.
3. Extend compatible frontend and integer/nonlinear distribution coverage as
   practical. Reuse the shared Bash expectations and cross-implementation
   continuation tests. Report every incomplete surface and genuine language or
   toolchain blocker. A proof or statistical test does not establish
   cryptographic unpredictability or source entropy quality.
4. Put all required acceptance checks in `./test`, with flake-controlled
   dependencies and bounded execution. Preserve existing required matrices.
   Send an initial milestone receipt and a final reproducible evaluation.

## Measurement contract

Use the shared performance-profiling workflow and existing `./bm` machinery.
Compare identical verified work on the same hardware, using optimized builds
and pinned versions. Include Zig, Rust and LuaJIT; add Lean/Roc where existing
runners make that straightforward. Record scalar/SIMD, backend and affinity.

Measure startup to first result, warmed in-process bytes, bounded integers and
supported nonlinear distributions, matching end-to-end output handling, memory
and input-doubling scaling. Measure compilation and proof checking separately.
Keep absolute observations, sample spread, ratios, commands, sizes and output
verification. Distinguish live allocation coverage, retained RSS and leaks.
Measure single-core and multicore cases separately without changing contiguous
stream semantics. GPU work is optional and must include actual setup/transfer
costs; it is not a separate toolchain project.

Check unexpectedly fast results for unequal work. Unavailable or noisy results
are inconclusive. Do not invent acceptance thresholds, approve historical
baseline changes or infer performance from emitted C alone. The final report
must distinguish supported features, measured costs, proof coverage,
development friction, unresolved gaps and recommendations.
