# Bend 2 deterministic-core experiment

## What works

This is an independent Bend implementation, not an FFI wrapper around another
generator. It implements the canonical seed KDF, keyed empty-message BLAKE3 XOF,
checked caller-owned byte state, chunk/resume behavior, and inclusive signed
bounded integers. Both generated JavaScript and optimized native execution
match the existing implementations in their tested domains.

The BLAKE3 implementation is deliberately the single-block subset needed by this
DRBG: the 25-byte context, 32-byte seed material, and empty keyed XOF. It is not a
general-purpose tree-hashing API. Public reads check the portable byte cursor
through 2^53; signed range bounds are within ±2^53 with inclusive span at most
2^53. Four-byte versus eight-byte rejection draws preserve the existing stream.

Acceptance includes 2,798 official-vector and independent cursor/range/domain
checks, 36 native byte-adapter cases, 135 continuous-stream benchmark-model
checks, and five-backend benchmark work/cursor and negative controls. Payloads
remain in RAM; timing probes consume a rolling checksum, and the CLI comparison
checks a frozen SHA-256 digest of the complete output.

The experimental outputs are `random-bend2-lib` (Bend source and pure generated
JavaScript) and `random-bend2-probe` (a narrow native byte-output adapter).
They are not added to the default aggregate. There is no production-compatible
Bend CLI, stable exported C ABI, OS-entropy adapter, nonlinear sampler, or
secure-erasure guarantee yet. Full frontend/distribution work remains in PLAN.
Generated/runtime artifacts carry the pinned upstream Bend Apache-2.0 notice;
the verdict kernel also carries the Lean license and third-party notices.
The project's own implementation source remains MIT.

Verification: all 46 default repository suites passed. After the notice-only
packaging change, all three affected Bend suites passed again, including exact
upstream notice digests. Deep-mode-only legacy checks are not claimed run.

The first hermetic CI run exposed two packaging gaps hidden by the host:
an unpatched `/usr/bin/env` test launcher and a proof-kernel ELF loader under
`/lib64`. The package now patches both interpreter paths, checks the kernel's
loader at installation, and runs an additional early real-sandbox gate before
the unchanged full regression matrix. Its fixture Trash is explicitly writable
inside that sandbox; no host home-directory fallback is needed.

## Compiler and proof boundary

The compiler is pinned to upstream Bend 2.0.37, revision
`4ff8545f19b09b7d2b8ca2303668100eac8efd66`. Its tag's generated flake packaged
2.0.36; an installed-version test exposed that discrepancy. A narrow override
selects the official 2.0.37 release archives with pinned platform digests.
The upstream guide and effects guidance were used for the actual syntax and
foreign-effect boundary, rather than relying on Bend 1 conventions.

Native Nat is limited to 48 bits and there is no U64 primitive. The core therefore
uses explicit U32 limbs for cursors, wide range arithmetic and values. Wide
remainder currently takes 64 bit steps. Small reads have no read-ahead cache.
These are implementation costs, not runtime execution of theorem proofs.

Four laws are tied to executed definitions: word encoding has four bytes, block
encoding has 64 bytes, a zero-length XOF request emits nothing, and the singleton
sampler branch preserves state. All pass ordinary checking and an explicit
`--verdict` using the pinned Lean-backed BendTT kernel. Deliberate implementation
mutations fail; altered law text, imported Base predicates and specified data
layouts trip the specification guard.

These laws do **not** prove BLAKE3 correctness, general chunk equivalence,
unbiased rejection sampling, distribution fidelity, cryptographic security or
native/JS compiler correctness. Frozen external vectors and differentials provide
independent evidence for those tested behaviors, not universal proofs.

The isolated verdict toolchain is Lean 4.34.0; production Lean remains 4.30.0.
The audited kernel consistency/termination theorems depend on `propext`,
`Classical.choice` and `Quot.sound`. The release archive is about 580 MB compressed.
Observed kernel elaboration/C generation took 30.17 s and 935,744 KiB peak RSS;
C compilation took 11.49 s and 247,856 KiB. These are build costs.

## Measurement method

The pinned performance-profile engine owns history, affinity, noise assessment
and its single allowed timing retry. New cohorts are not automatically approved.
Each core case uses sizes 1024, 2048, 4096 and 8192, seven CPU/wall samples after
a first verified unit and three warmup units, and one 20 ms wall-target calibration.
A sample advances one continuous stream; it does not replay a cached prefix.
Large-prefix checksums/cursors must agree between the existing Zig and Rust
cores; small prefixes additionally agree with LuaJIT.

The experiment runs on an AMD Ryzen Threadripper 3990X, Linux x86_64, with taskset
affinity of one and twelve CPUs. Twelve CPUs are availability, not twelve
independent streams or a promise of parallel speedup. Native Bend uses Clang -O3;
JavaScript uses pinned Node 24.19.0; LuaJIT is enabled; Zig uses its public buffered
C ABI; Rust uses the optimized public Drbg with its existing 1024-byte cache and
the repository's actual BLAKE3 `pure` feature configuration. No Bend SIMD path was
added. The probes include checksum work and adapter checks in their kernel timing.

Startup is measured independently from spawn to the first verified 1 KiB result,
including the same thin Bash launcher. End-to-end CLI measurements capture a
4096-byte stream as 8193 bytes of hex plus newline and verify its frozen digest.
The Bend adapter is narrower than the production CLIs, which emit different
stderr metadata; Rust uses its unwrapped libexec binary. These are not equal CLI
feature surfaces.

Memory is supplemental approximate Linux `/proc/self/status` VmHWM, not a live
allocator or leak measurement. `getrusage().ru_maxrss` was rejected because it
retained a large pre-exec high-water mark. No allocation-count, retained-heap,
leak-freedom, GPU, or native ARM/macOS/Windows performance conclusion is claimed.

The first recorded sweep was invalid because per-backend build labels did not
match the engine's configured build identity. Its records remain preserved and
are excluded from conclusions. The corrected protocol keeps the common
optimized identity and retains specific backend build metadata.

## Results

The corrected core sweep recorded **59 valid unbaselined cases and 11
inconclusive cases**. The CLI sweep recorded seven valid unbaselined cases and
one inconclusive case. No baseline was approved. All source-before/source-after
digests match. Full samples, calibration observations, retries, cursors and
verdicts are retained in [the numeric observations](2026-10-20-bend2-observations.json).
The core source fingerprint is
`4131287e7488e5abf9443e83b17119e8839bf860e6a6df35c8f0b29102f54aa9`;
the source tree was unchanged throughout that sweep.

Mean process CPU per 1024 items, one CPU available:

| Backend | 1024 raw bytes (µs) | 1024 d6 draws (ms) | 1024 wide draws (ms) |
|---|---:|---:|---:|
| Bend native | 37.88 | 2.026 | 2.438 |
| Zig buffered C ABI | 3.38 | 0.0260 | 0.0416 |
| Rust public Drbg | 1.82 | 0.0121 | 0.0182 |
| LuaJIT | 181.86 | 1.316 | 2.906 |
| Bend JavaScript | inconclusive | inconclusive | inconclusive |

The wide case is inclusive 1..2^52. Bend native raw bytes were about 11.2×
Zig's CPU cost and 20.8× Rust's, but about 4.8× faster than LuaJIT in this probe.
Its d6 cost was about 78× Zig's and 167× Rust's. These are measured implementation
ratios, not intrinsic language multipliers or proof overhead.

For Bend native, doubling ratios across 1024–8192 were 2.01/2.07/2.05 for bytes,
2.01/2.00/2.04 for d6 and 1.98/2.00/2.00 for wide ranges. Twelve-CPU availability
did not meaningfully accelerate this sequential implementation: its corresponding
1024-item CPU means were 38.61 µs, 2.075 ms and 2.405 ms. Its one-CPU wall means
were 38.24 µs, 2.079 ms and 2.443 ms. All remain observations without an approved
historical baseline.

All six JavaScript CPU cases were inconclusive after the permitted retry.
Four JavaScript wall cases and the twelve-CPU Zig raw-byte CPU case were also
inconclusive. Their numbers remain in the diagnostic data; they are not reliable
rankings. This run does not establish steady-state V8 throughput.

Mean one-CPU startup-to-ready, including the common launcher, was 16.70 ms
Bend native, 20.76 ms Zig, 21.86 ms Rust, 27.62 ms LuaJIT and 74.51 ms Bend
JavaScript. Separately, 4 KiB hex CLI spawn-to-exit means from an already running
Node parent were 3.25 ms Bend, 3.36 ms Zig, 2.98 ms Rust and 11.92 ms LuaJIT.
These intervals have different boundaries: do not subtract them or call the
launcher-inclusive figure native-binary startup alone. The twelve-CPU Zig CLI
case remained inconclusive.

Bend native's measured supplemental RSS was approximately 1.63–1.79 MiB across
the one-CPU core sweeps. That is not its address-space reservation: the emitted
CPU runtime initially maps an 8 GiB corpus. It does not mean 8 GiB resident use.
Live allocation, peak reachable data and cleanup residuals were not instrumented.

The stripped byte adapter is 80,120 bytes; the benchmark is 141,664 bytes.
Both are dynamically linked host/Nix artifacts, not promised standalone static
releases. Observed benchmark native compilation took 2.42 s / 162,912 KiB peak
RSS; model-to-JavaScript compilation took 0.26 s / 94,932 KiB; byte-adapter native
compilation took 1.47 s / 119,476 KiB. An already-built explicit four-law verdict
check took 0.56 s / 135,120 KiB in one observation. Dependency downloads and
kernel compilation are separate costs, not hidden inside those times.

## Recommendation and remaining work

Keep this as an explicitly experimental independent oracle and proof-tooling
example. It demonstrates a real native Bend core with exact existing streams,
a small binary and executable-linked kernel-checked laws. The recommendation is
based on the measured workload and missing interfaces—not on an assumption that
formal languages cannot replace production implementations.

Before evaluating a production promotion, add a caller-owned read-ahead cache,
prepare range parameters once for batches, and replace or specialize the wide
remainder path without weakening exactness. Re-measure with these changes
individually controlled. The present d6 probe recomputes a whole XOF block for
each small read, unlike the buffered native references. Cached bytes must never
alter cursor, rejection or failure-prefix semantics.

Then extend the nonlinear distributions and frontend through the existing shared
Bash oracle, add cross-implementation state continuation, design a supported C
library boundary, and strengthen laws toward arithmetic/stream/sampler refinement.
Neither four small laws nor statistically good samples justify calling the
complete CSPRNG proven. No consumer has been migrated.

Reproduce the extended observations with an existing writable external history
directory; the first unapproved run normally exits 3:

```bash
build-budget --project random -- ./bm --bend2 --history-url file:///absolute/history
build-budget --project random -- ./bm --bend2 --cli --history-url file:///absolute/history
```

Bounded work/proof/clock/metadata checks are required by `./test`; the extended
performance sweep is opt-in. The 78-case raw observations preserve inconclusive
results instead of rerunning until favorable. No claim is made for nonlinear
performance, GPU execution, live-allocator growth, general compiler soundness,
or native platforms not executed here.

References: [pinned Bend guide](https://github.com/bendlang/bend/blob/4ff8545f19b09b7d2b8ca2303668100eac8efd66/guide/GUIDE.md),
[pinned effects guide](https://github.com/bendlang/bend/blob/4ff8545f19b09b7d2b8ca2303668100eac8efd66/guide/EFFECTS.md),
[official 2.0.37 release](https://github.com/bendlang/bend/releases/tag/v2.0.37).
The memory-method distinction follows the documented preservation of usage
across exec in [getrusage(2)](https://man7.org/linux/man-pages/man2/getrusage.2.html)
and the approximate high-water metric in
[proc_pid_status(5)](https://man7.org/linux/man-pages/man5/proc_pid_status.5.html).
