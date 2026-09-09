# Normalized-output throughput, 2026-09-06

Zig and Rust are approximately 3.3 times faster on the measured normalized-byte
workload, with identical output and continuation positions. Arithmetic remains
integer-only. No approximation, coefficient, distribution, seed derivation,
or byte-consumption rule changed.

## Before and after

Host: AMD Ryzen Threadripper 3990X, Linux x86_64. Zig 0.16.0 ReleaseFast;
Rust 1.97.1 release; stripped executables. Baseline source is commit
`7a3ee0fd511edd3819369a2691bc190541e20cbf`. Both original Rust and candidate
were built today, so these comparisons do not rely on Friday's measurements.

Hyperfine 1.20.0 executed the binaries directly with output discarded, one
warmup and five measurements. The machine was shared with other projects;
these are local measurements, not universal speed guarantees. Raw records
include CPU time, individual wall samples, toolchain versions, and binary
digests in [normalized-throughput-2026-09-06.ndjson](../benchmarks/normalized-throughput-2026-09-06.ndjson).

Command: `CLI -d -b -n --seed 0x700A -c COUNT`.

| Normalized bytes | Zig before → after | Rust before → after |
| --- | ---: | ---: |
| 64 KiB | 153.8 → 46.1 ms | 184.1 → 57.2 ms |
| 256 KiB | 617.3 → 188.4 ms | 723.8 → 221.2 ms |
| 1 MiB | 2,421.2 → 718.7 ms | 2,882.1 → 876.5 ms |

For 1 MiB, Zig's wall-time speedup is 3.37× and Rust's is 3.29×. CPU time
(user + system) falls from 2.407 to 0.714 seconds for Zig, and from 2.864 to
0.871 seconds for Rust. Wall standard deviations are 11.2 → 10.8 ms and
6.3 → 1.3 ms, respectively. Growth over these bounded sizes remains roughly
linear; this is not a proof of complexity for every possible input.

The original rarz workload, 100 MiB of normalized Zig output with seed
`0x700A`, completed in **70.684 seconds wall**, 70.287 seconds user and
0.001 seconds system. This was one timed run, without a warmup. A separate
count-only run emitted exactly 104,857,600 bytes. The historical report was
a timeout beyond roughly five minutes, not a completed baseline measurement.

Uniform 100-MiB bulk output stayed close to its previous speed: Zig
169.5 → 172.0 ms; Rust 96.4 → 96.6 ms. Normalized output still costs much
more than uniform output because each sample evaluates fixed-point
transcendentals. Multi-GiB normalized workloads remain substantial work.

The release binaries grew from 617,472 to 618,808 bytes for Zig and from
824,168 to 832,360 bytes for Rust. The byte cache is runtime storage, not
a compiled table of random values.

## Retained changes and SIMD decision

- Replace 62 rounds of restoring magnitude division with the exact unsigned
  quotient `(u128(a) << 62) / b` in both kernels. Normalized magnitudes are in
  `[2^62, 2^63)`, so the numerator fits in 125 bits and the quotient in 63.
  Restoring the sign afterward preserves truncation toward zero.
- Cache 1 KiB of deterministic BLAKE3 bytes for small draws. Prefetching does
  not advance the exported cursor. Large fills bypass the cache; successful
  seek/rekey operations invalidate it. Failure checks precede output writes.
  Keyed temporaries and cached state have explicit wiping paths. Rust wipes
  its context on drop; the C CLI registers process-exit cleanup.
- Preserve the original 40-byte Zig C state. Clients can opt into the additive
  1,080-byte buffered context. Rust uses a private cache automatically.
- Add ordinary Rust inline hints to arithmetic helpers. A separate five-run
  comparison after caching reduced 256-KiB wall time from 239.5 to 223.2 ms
  (about 7%). Error checks and numerical semantics remain intact.

Callgrind on optimized, symbol-retaining builds after division/caching and
before Rust inlining attributed 40.9% of Zig's instructions to `ln`, 27.6%
to the sine/cosine evaluators combined, and 2.2% to BLAKE3 compression.
Rust attributed 24.8% to `ln`, 23.2% to its addition helper, and 17.7% to
sine/cosine evaluators. These are **instruction shares, not CPU-time shares**.

No custom SIMD sampler was added. Faster BLAKE3 alone targets a small part
of this profile; the pinned Rust dependency already contains x86 SIMD
dispatch. The more promising vector experiment is batching fixed-point
logarithm/trig work across samples. That requires preserving each lane's
wide products, truncation, domain checks, rejection ordering, and consumed
byte position. It is deferred rather than claimed as an unmeasured win.
Portable builds do not acquire a host-only AVX requirement.

## Correctness and review

The expanded default 25-suite run passed, along with the strengthened timing
validation's targeted rerun. Validation
includes 264,327 raw Zig/LuaJIT kernel cases, Rust unit tests and doctest,
736 four-way continuation checks, 11-target Zig cross-compilation, direct
LuaJIT shared-library tests, and 32-bit WASM execution at cache boundaries,
above `2^32`, and at the `2^53` cap. `./crossarch` passed Lua, Zig, and Rust
execution comparisons; ARM64 was emulated under QEMU, not native hardware.
The deep LuaJIT-only JIT sweep is intentionally excluded by default FAST mode.

Original and optimized binaries emitted exactly 65,536 normalized bytes with
SHA-256 `7cf91062027515b697c9b3f158b03c6bc9de387e7846be7a3bb186733ed5a7f1`
for seed `0x700A`. Their uniform 100-MiB outputs also had identical digests
and separately verified byte counts. Benchmark payloads went to `/dev/null`,
streaming digests, or counters; diagnostic artifacts were kept in tmpfs.

A fresh-context review found no blocking defect. Its independent Lua-oracle
probe passed 105 boundary requests and three rekeys over populated caches.
The review suggested testing the new declarations through the actual C
header, in addition to LuaJIT's cdefs. The existing C consumer now checks the
buffered layout and all six entry points with frozen-vector replay.

`./bm --quick` proved all 11 workloads identical across all four languages
before timing them. Its [44 measured records](../benchmarks/four-way-throughput-2026-09-06.ndjson)
retain the original timing values, with exact duplicates removed: this run
exposed Hyperfine's cumulative exports to a pipe, which had caused 110
history rows for 44 measurements. The parser now validates and retains only
the final snapshot. A regression test was seen failing on the old flatten-all
behavior, then passing; a subsequent real-Hyperfine smoke run produced exactly
44 unique case/implementation records. Review also prompted rejecting missing,
negative, or nonnumeric timing fields; those corruption cases were seen red
before the added validation made them pass.

A clean dev-shell check subsequently exposed an undeclared `jq` dependency
that the ordinary development shell inherited from the host. The flake now
declares `jq` for repository tests and `hyperfine` for development benchmarks;
neither was added to the installed CLI runtime dependencies.

## LuaJIT streaming follow-up

Rarz's large-count LuaJIT probe was
`timeout 5 random -b -c 2362232012 --seed 0x700A`. Its observed result was
exit 124 with zero bytes, not successful empty output. LuaJIT assembled the
whole binary request before writing. No claim of a `2^31` count-parsing defect
follows from that timeout.

The follow-up fixes binary streaming with 49,152-byte direct chunks and
3,072-byte sampled chunks. Sampled output writes into reserved `string.buffer`
byte storage. Both sizes are multiples of three, preserving Base64 grouping;
only the final chunk can contain padding. Raw/hex/Base64 bytes and newlines,
the order of random draws, and exact continuation positions remain unchanged.
Known-overlong direct requests still fail before output at the 2^53 cap.
Writes are checked before drawing another chunk. A later entropy or output
failure can leave a prefix, but cannot publish successful continuation state.
This bound applies to binary generation, not buffered text or stdin populations.

`tests/luajit_stream_test` passes 53 controls, including 32 MiB of deterministic
output under a 16 MiB virtual-memory budget, 128 MiB of explicit entropy input
under 64 MiB, exact byte counts, chunk boundaries, output errors, and a verified
prefix of the original multi-GiB request. Payloads use pipes or `/dev/null`.
The original code failed the new huge-request controls with out-of-memory
errors before reaching the sink; no timeout was counted as success.

The tests exposed an older four-language defect: fractional binary state
contained text-only precision and was rejected on resume. All implementations
now omit that inapplicable field. The shared state suite passes 844 checks,
including every producer/consumer pairing for those binary distributions.
Lean also checks `binary_state_needs_no_precision`: the metadata predicate is
false for binary mode. That narrow theorem uses standard `propext`; it does
not prove the entire serializer or I/O behavior.

All 26 default suites passed. The fresh-context reviewer found no actionable
defect and independently passed 497 assertions with system encoding oracles,
four-language resumption, and cursor/sink boundaries. Further complete raw,
hex and Base64 entropy streams consumed 48 MiB each under a 24 MiB address-space
budget. Huge-count failing-sink probes also passed. Review artifacts are
`/tmp/dispatch-log/random-stream-review-final.md` and the RAM-only probe script;
the checked-in tests carry the ongoing gate.

On the same host, Hyperfine measured these LuaJIT changes (one warmup; three
before samples, five after; full-suite work ran concurrently during some
measurements):

| Workload | Wall time before → after | CPU time before → after |
| --- | ---: | ---: |
| 8 MiB raw | 1.795 → 1.446 s | 1.783 → 1.437 s |
| 1 MiB hex | 246.5 → 189.1 ms | 244.8 → 187.5 ms |
| 1 MiB Base64 | 245.9 → 230.1 ms | 244.1 → 228.3 ms |
| 49,153 normalized bytes | 2.030 → 2.167 s | 2.015 → 2.142 s |

The normalized case was about 7% slower in this run, with 122 ms wall-time
standard deviation after versus 38 ms before; no normalized speedup is claimed
for LuaJIT. The benefit there is bounded memory and incremental output.
An intermediate hex implementation regressed to 336 ms and was replaced with
direct byte-buffer encoding before retention. Raw measurement records are in
[luajit-streaming-2026-09-06.ndjson](../benchmarks/luajit-streaming-2026-09-06.ndjson).

## Fixed-point SIMD experiments

The subsequent opt-in experiment evaluates four independent fixed-point lanes
in Zig `@Vector` code and Rust AVX2 intrinsics. Neither prototype is imported
by a production library or CLI. Each uses four 32-bit partial products per
lane to recover the exact wide product; scalar 62/63-bit truncation and
coefficient order are preserved. Logarithm retains scalar initial divisions
and batches the twenty series steps. Cosine retains scalar quadrant reduction
and batches the fourteen sine/cosine steps with lane masks. No floating-point
source arithmetic, new approximation, or random prefetch is involved.

The final reviewed run on the same Threadripper used Zig 0.16.0 ReleaseFast
and Rust 1.97.1 opt-level 3, both compiled for the native CPU. The runner pins
the optimization/CPU flags separately for **every** Zig module and builds the
Rust dependency with matching native target flags. Hyperfine used three warmups
and five measurements; outputs went to `/dev/null`.

| Operation | Samples per invocation | Zig scalar → vector wall | Rust scalar → vector wall |
| --- | ---: | ---: | ---: |
| ln | 1,048,576 | 257.7 → 155.3 ms (1.66×) | 302.7 → 186.5 ms (1.62×) |
| cosine in turns | 1,048,576 | 196.4 → 112.2 ms (1.75×) | 221.0 → 119.4 ms (1.85×) |
| multiply | 33,554,432 | 339.1 → 166.1 ms (2.04×) | 345.1 → 244.9 ms (1.41×) |

CPU times track those wall-time gains: ln 255.8 → 153.9 ms (Zig) and
300.5 → 185.1 ms (Rust); cosine 194.8 → 111.1 and 219.3 → 118.4 ms.
Multiplication's final run was noisier, especially Zig scalar (35.9 ms wall
standard deviation); treat its ratio as approximate. The benchmark includes
input setup, operation dispatch and result accumulation, not only arithmetic.
The same 8,192 deterministic inputs are reused across iterations in all four
variants. These are cache-resident kernel workloads, **not measured CLI gains**.

Run `nix develop -c ./bm --simd`, or append `--check` to omit timing. Before
timing, each variant emits all 8,192 canonical mantissa/exponent results for
each operation through a validated line-count/format gate and SHA-256. All
four outputs must agree; empty or incomplete outputs cannot pass. The cheap
rolling checksum inside timed invocations only prevents dead-code elimination.
Measured records, including CPU time, samples, toolchains, source digests and
earlier exploratory runs, are in
[fixed-simd-2026-09-06.ndjson](../benchmarks/fixed-simd-2026-09-06.ndjson).
The final twelve records describe the reviewed run in the table.

Exact-pair tests cover mixed signs, zeros, cancellation, exponent gaps and
quadrants. Zig's initially stubbed operations failed these controls before
implementation. ReleaseSafe tests pass for native AVX2, baseline x86_64 and
ARM64 under QEMU; ARM emulation is a correctness check, not a performance
measurement. The Rust AVX2 tests check CPU support before entering unsafe
code; their target-feature module remains outside the safe production core.
The benchmark artifacts are host-specific and do not provide portable dispatch.

The independent reviewer passed 135,200 add/multiply pair comparisons per
language over full-limb boundary/carry inputs, plus arbitrary-mantissa logs
and quadrant cases. It found one shared prototype defect: a sufficiently tiny
negative turn can round to quadrant 4 during the scalar wrap. Both prototypes
had chosen cosine there, while the scalar default selects sine. New persistent
regressions failed in both languages; corrected masks now match the scalar
fallback, and the reviewer's original and expanded controls pass. The scalar
result itself is mathematically surprising, but lies outside the sampler's
nonnegative `[0,1)` domain. PLAN records that separate four-oracle question.
No unresolved actionable review finding remains.

At the experiment milestone, production promotion still required a bounded
batch API, supported-domain/error handling, tails, portable CPU dispatch,
sequential rejection/consumption controls, and end-to-end measurements.
The follow-up below addresses that work. Empirical controls do not constitute
a proof over every mantissa/exponent or of compiler correctness.

## Production promotion (2026-09-09)

Range-scaled normal integer batches now have public caller-buffer APIs in
Zig/C and Rust, dogfooded by their CLIs. Each computes at most four candidates
when at least four output slots remain, accepts them in stream order, and
handles the final short tail scalarly. Scratch space is independent of count.
The CLIs use 256-value staging buffers; output encodings and continuation JSON
are unchanged. Explicit mean/stddev normal and other distributions remain
scalar. No distribution coefficients, fixed-point rounding, seed derivation,
or scalar oracle algorithms changed.

Zig's generic callback batch completes any previously gathered candidates
before propagating a later read error. It never gathers more candidates than
remaining output slots. SIMD is restricted to bounds within ±2^53 and the
bounded positive uniform inputs used by this sampler, so no intervening math
error can be overtaken by a later read failure. `written` reports the completed
output prefix, leaving the suffix
untouched. An explicit scalar mode provides a caller-controlled reference path.

Rust accelerates only its seekable `Drbg`. On a read or numeric failure, it
rewinds the uncommitted four-candidate group and replays scalar calls to retain
the original failure, output prefix, and byte cursor. Its generic `ByteSource`
batch API remains scalar, including for partially consuming entropy failures.
Neither implementation retains candidate values between calls.

Zig builds the dispatcher/scalar core for a baseline CPU by default and isolates
AVX2 in non-inline functions in a separately targeted module. CPUID and XCR0
checks require CPU support and OS XMM/YMM state saving. Rust uses its standard
runtime feature check and a private target-feature module; the rest of the
core retains its unsafe-code prohibition. Existing I/O bans also apply inside
the SIMD module, with new mutation controls proving that this narrow exception
does not permit I/O there or unsafe code elsewhere. Non-x86 targets, no_std
Rust, and x86 CPUs without AVX2 use scalar fallback.

### End-to-end results

Paired release measurements on an AMD Ryzen Threadripper 3990X, Linux x86_64,
used the previous release commit `74d91d3` and the final production batch
implementation. Each command had three warmups and five measured runs.
All four before/after/language outputs matched by SHA256 before timing; output
went through digest pipes for comparison and to `/dev/null` during timing.
No random payload files were written.

| Workload | Zig before → after | Rust before → after |
| --- | ---: | ---: |
| Normal raw, 1,048,576 values | 696.7 → 514.1 ms (1.36×) | 882.5 → 509.6 ms (1.73×) |
| Normal hex, 1,048,576 values | 699.0 → 519.0 ms (1.35×) | 888.3 → 517.1 ms (1.72×) |
| Normal base64, 1,048,576 values | 701.3 → 518.4 ms (1.35×) | 897.4 → 513.8 ms (1.75×) |
| Normal text, 131,072 values | 98.6 → 73.3 ms (1.34×) | 154.3 → 103.3 ms (1.49×) |
| Uniform raw, 4,194,304 values | 8.75 → 9.21 ms | 5.17 → 5.21 ms |

These are mean wall times, including process startup, generation, rejection,
formatting and output. Normal-raw mean CPU time (user + system) fell from
691.8 to 510.4 ms for Zig and from 876.5 to 506.2 ms for Rust. The host was
shared with other builds/tests, not isolated benchmark hardware. The short
uniform measurements are startup/noise-sensitive; they do not establish a
uniform-path speedup. Measurements are AVX2-host results, not performance
claims for fallback CPUs or other distributions.

Doubling normal-raw counts from 65,536 through 524,288 gave median CPU-time
ratios of approximately 1.98 for Zig and 1.97 for Rust, consistent with linear
work. No measured doubling exceeded 2.8. This is a recorded experiment, not a
new timing-sensitive CI gate. The Zig executable grew from 618,816 to 638,304
bytes (+3.15%); Rust grew from 1,015,840 to 1,044,912 bytes (+2.86%).

The [machine-readable measurements](../benchmarks/normalized-batch-2026-09-09.ndjson)
record individual runs, CPU times, exact executable hashes, output digests,
toolchains and the implementation-source fingerprint. The source fingerprint
is SHA256 of the `sha256sum` listing, in this order: `build.zig`,
`src/randomz.zig`, `src/fixed.zig`, `src/fixed_simd.zig`,
`src/fixed_simd_dispatch.zig`, `src/randomz_cli.c`, `include/randomz.h`,
`rust/randomr/src/batch.rs`, `rust/randomr/src/batch_avx2.rs`,
`rust/randomr/src/distribution.rs`, `rust/randomr/src/fixed.rs`,
`rust/randomr/src/lib.rs`, `rust/randomr-cli/src/main.rs`, `Cargo.lock`.

### Correctness and review

The final release build, all 26 default `./test` suites, the complete
cross-architecture gate, and `./bm --check` passed. `./bm --quick` also measured
all eleven workloads across four implementations. The default test run uses
FAST mode; its deep-only LuaJIT kernel-JIT sweep is explicitly skipped. The
default Zig/LuaJIT arithmetic differential covered 264,327 bit-identical cases.
An earlier full run collided with a concurrent build replacing the Lean CLI
while its entropy test was stripping it. The entropy test and then the entire
suite passed when rerun without that competing artifact writer. No Lean or
entropy implementation change was needed.

Persistent direct LuaJIT-FFI controls pass 80,229 exact scalar/batch comparisons,
including tail lanes, both rejection stages, partial source failures, cursor
positions and untouched output suffixes. The shared continuation/encoding
suite has 1,060 checks, including resumption across all four implementations.
Rust's purity mutation controls reject both unsafe code outside the narrow
SIMD boundary and I/O inside it.

A [fresh-context reviewer](reports/2026-09-09-production-batch-review.md)
wrote independent controls against the unchanged
scalar APIs: 109,440 C ABI cases and 47,210 Rust cases passed after the domain
fix below. The reviewer found no remaining actionable defect. It also executed
the dispatcher under emulated no-AVX and XSAVE-disabled CPUs. The durable
cross-architecture gate now compares native and no-AVX execution of the same
Zig and Rust binaries across raw/hex/base64 tails and continuation metadata;
the complete gate passed, including ARM64 comparisons. Emulation checks
instruction selection and results, not native hardware speed. These finite
controls and source review are not a formal proof or a cryptographic audit.

The independent review identified an inherited domain hazard: very narrow
scalar ranges near i64 extrema can reject indefinitely after fixed rounding.
The new batch APIs therefore reject bounds outside ±2^53, before source or
output mutation even for empty buffers. The same rule applies to AUTO/scalar,
Rust's generic/DRBG entries, and all CPU targets. Endpoint and immediately
outside-domain tests failed against the initial wide-acceptance implementation
before the restriction was added. Existing scalar APIs are unchanged; their
domain inconsistency is tracked separately. Rejection sampling still cannot
promise termination for an adversarial source that keeps supplying rejected
draws, even within supported bounds.
