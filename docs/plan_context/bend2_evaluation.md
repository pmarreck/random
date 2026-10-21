# Experimental Bend 2 implementation and evaluation

## Current expanded status

October 20, 2026: the independent full Bend numeric core, native
C-FFI CLI, pure-source/coherent-JS SDK and isolated static/shared library outputs
are implemented. Shared help/stream/six-way continuation and distribution checks,
installed consumers and the corrected full 81-check statistical sanity run passed during
the port. See the [full evaluation](../reports/2026-10-20-bend2-full-evaluation.md)
and its 403 retained observations for the exact evidence boundaries.

The 216 logical sampler cases resolve to 201 UNBASELINED and 15 INCONCLUSIVE;
the 156 whole-CLI cases produced 91 UNBASELINED and 65 INCONCLUSIVE. All completed
work checks and before/after source identities match. The 31 original deadline
expirations remain preserved alongside the separate 31-case budget repair.
No noisy-only cases were selected for extra runs and no baseline was approved.
Native Bend's normal API is about 179× Zig's and 206× Rust's here, with real
buffering/representation differences; no language ceiling is inferred.

The four initial laws remain the only Bend proof claims. Stronger refinements,
read-ahead/prepared-range/exact-arithmetic optimizations, embedding/erasure/stress
work and native aarch64 execution remain open. Release verification requires
the complete current 50-suite gate, stats smoke, installed libraries/packages,
normal-shell runtime check and all 12 exact-commit CI targets; shipment receipts
identify the completed source snapshot, rather than inferring it from older gates.

The normal follow-up corrected a test-model assumption: the custom CLI rounds
to integers, while the old statistical null was continuous. No generator changed.
The failed null analysis and corrected same-sample exploratory results are both
retained; a separate predeclared million-value continuous-core holdout matches
every exact Zig value/cursor and passes its own seven-point conditional check.
The new required model suite has 45 MPFR/specificity/refusal controls, including
a RED→GREEN sparse-array domain fix found during fresh review. Full-CDF, IID,
algorithmic-error and security proofs are not claimed from these samples.
The dated checkpoints below preserve what was known earlier, not current limits.

## Checkpoint history and ownership

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
Checkpoint `e3ffa95653d0913af81029a95bbdcfb2072fda7d` passed all 12 exact-commit
CI targets on October 20, 2026 at 15:09 EDT, including the full 46-suite default
matrix, package/library checks, cross-architecture checks and Windows smoke.
There is no owner-decision blocker. Remaining work is cache/arithmetic
optimization, stronger refinement laws, nonlinear distributions and full
frontend/library coverage; none is silently claimed complete.

On October 20, the owner clarified that a full Bend evaluation requires both
native shared-CLI and nonlinear-distribution parity plus the matching performance
sweep. The initial scoped report is a checkpoint, not the final language verdict.
Complete that surface using the existing shared Bash expectations without
reducing the matrix or moving arithmetic/sampling into another language. Keep
parsing, OS entropy and byte-preserving I/O at the edge; reusable deterministic
arithmetic, distributions, state and chart models belong to the Bend core.
Freeze fixed-point intermediate results and rejection/cursor behavior against
the independent existing implementations before measuring optimized code.

Expanded-port checkpoint, October 20 at 16:05 EDT (unshipped working tree):
the checked limb/fixed-point kernel, pure byte-request composition, normal
Ziggurat and uniform/exponential/Poisson/log-normal/beta programs pass 9,315
exact production value/cursor comparisons in both native and generated JS
execution. Another 832 native/JS comparisons cover bounded and normalized
integers; the numeric kernel has 2,554 exact BigInt/LuaJIT checks and 1,626
native cases. Geometric/count code currently passes 288 JS value/BLIP/cursor
comparisons down to `2^-1000` and 823 BigInt/frozen-BLIP count fixtures; native
wide-count checks remain required. These are differential checks, not new
distribution/security theorems. Full CLI/native FFI, matching performance
measurements and the final expanded default/CI matrix remain open.

Expanded-port checkpoint, October 20 at 17:00 EDT (still unshipped): the
native library now passes 968 sampling/cursor/reentrancy/heap-reuse checks,
596 exact numeric/chart ABI comparisons against Zig (including refusal
precedence and output mutation), and 1,993 weighted-choice/shuffle/batch
comparisons against LuaJIT/Zig. Wide geometric values are native-tested through
`2^-1000`. Pure decimal codecs pass 261 LuaJIT comparisons and chart models
pass 72 exact model comparisons. The chart controls caught and fixed a Bend
`p=1` plotting mistake: every plotted x whose floor is zero has peak height,
not only the first sample.

The actual native `randomb` C-I/O frontend passes all 85 shared CLI behavior
tests, 12 DRBG controls and 186 output differential cases. The complete five
Bend suites passed the real Nix sandbox gate
`checks.x86_64-linux.bend2-sandbox`. Its initial independent Zig-reference
failure was fixed by declaring the toolchain and writable Zig caches, without
changing its expectations. Native FFI and CLI packaging are now separate
experimental outputs (`random-bend2-ffi` and `random-bend2`); the existing
source/JS output remains `random-bend2-lib`. No default aggregate was changed.
The source packages expose one coherent `Library.bend`/`index.mjs` graph.

Native ABI finding: direct generated function segments flatten sum arguments
and results, and even a function-valued factory can be eta-expanded. The owned
adapter instead obtains a fresh boxed pure entry closure from the generated
main's single effect payload and uses the runtime's ordinary boxed closure
application boundary. It never runs the Bend process I/O loop, installs its
signal handlers or starts worker threads. An evaluator mutex is released
around user source callbacks; the direct FFI test reenters the same library.
All arithmetic, formatting, chart geometry, weighted decisions, shuffle index
plans and batch advancement remain Bend-owned. The shared C edge marshals
values, services byte requests, and writes completed output prefixes.

Bend has been added to the unchanged shared help, continuation, streaming,
release-strip and frozen Ziggurat matrices. The expanded full repository check
is currently running; full six-way/cross-pair success, expanded performance,
final review and exact-commit CI are NOT yet claimed. The pinned runtime
reserves 8 GiB of corpus address space and 2 GiB of evaluator stack: streaming
therefore uses the same 128 MiB **resident** cap as Lean, not a misleading
128 MiB virtual-address cap. Heap high-water diagnostics are not live-allocation
counts. Scalar fallback is explicit; no Bend SIMD or multicore speedup is claimed.

A concrete integration finding: separately emitted JS module graphs qualify
imported tagged constructors differently (`Rejected` versus `Draw.Rejected`).
Mixing their sampler/interpreter objects can misread rejection as a byte
request and exhaust the JS stack. `bend/Library.bend` is the coherent public
facade; consumers must use a single compiled graph. Invalid-input controls
cover the failing case. The native single-graph path did not have this issue.
No upstream checker or compiler code was patched, and no unsafe termination
escape was introduced. Byte-request composition uses continuation encoding;
its seeded interpreter and rejection programs retain explicit structural fuel.

The experiment must preserve production behavior and all required suites. No
consumer migration or production-ready support claim is authorized. A host
adapter may handle I/O and OS entropy; calling an existing generator through
FFI does not count as a Bend implementation.

Expanded verification/measurement checkpoint, October 20 at 18:34 EDT (unshipped):
the expanded 49-suite run completed with only the new Bend MPFR-table formatting
check failing in its older source snapshot. All other 48 suites passed, including
120 help outputs, 2,574 continuation checks, 330 streaming checks and 2,982 frozen
Ziggurat checks across all six implementations. The generator's signed-cdata
modulo formatting is corrected and now regenerates the Bend file byte-for-byte
at 512-bit MPFR precision. Installed Bend source/JS and solo C-FFI consumers and
CLI package smoke checks pass. A complete current 49-suite rerun remains required.
The full statistical run passes 79 sanity/sensitivity checks with 4 MiB per raw
stream and 50,000 values per tested distribution; no security theorem is implied.

The 216-case sampler campaign retained 171 valid unbaselined observations,
14 inconclusive observations and 31 INVALID outer-deadline expirations. Every
source-before/after identity matched. The pinned shared engine imposed 30 seconds
on an entire four-size adapter command; this is not a diagnosed generator error.
A small repo-owned Nix patch exposes, validates and durably records per-case
budgets while preserving its 30-second default and all measurement/retry/baseline
policy. Real-child controls failed against the original engine and pass the
patched package, including explicit timeouts and invalid-budget refusals.
New full profiles declare 300 seconds. A separately identified 31-case campaign
repairs only those time-budget admissions, preserving the original INVALID
records and all noisy cases; the 156-case full CLI campaign remains required.
No baseline was approved. These additional experiments must finish with frozen
sources, and final verification/push/exact-commit CI are still pending.

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

## Event-addressed RNG investigation

The owner also requested review of `random-event-addressed-rng-brief.md`, a
203-line engineering brief dated October 20, 2026. This is a
discussion/investigation request, not approval
to change the generator or add a public noncryptographic backend. Keep it
separate from completing the Bend port.

The useful abstraction is stable semantic addressing of independent decisions:
one event-local substream per canonical, versioned event identity prevents an
extra draw in one event from shifting unrelated events. It can use keyed BLAKE3;
event addressing and noncryptographic speed are separate design axes. Existing
O(1) raw-byte seeking is not O(1) access to an arbitrary rejection-sampled value.
Event identity supplies no entropy and does not repair genuine simulation-state
divergence. A public/guessable seed still makes results predictable.

Before implementation, inventory existing seed/seek/buffer/state interfaces and
propose the smallest API, canonical encoding, domain separation and failure
semantics. Specify reorder/skip/replay/extra-draw tests and collision/ambiguous
encoding negative controls. Benchmark the buffered sequential baseline, existing
seek, per-value keyed hashing, per-event keyed XOF, the proposed four-round
64-bit permutation and an established noncryptographic comparator. Include
identity serialization/setup, variable-consumption nonlinear sampling and
end-to-end desynchronization/rollback costs rather than promising per-draw speed.

The proposed permutation's fixed-seed bijection is not evidence of local
statistical quality, independence, full feedback period or cryptographic
security. Informal numbers in the earlier conversation are not accepted
measurements. Any optional noncryptographic source needs reproducible whole-word
and low-bit quality tests, structured/related-input cases, known-bad controls,
multiple-testing discipline and explicit security labeling before a separate
production decision. Existing seeded bytes and schema-3 continuation remain
unchanged throughout the investigation.
