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

## Separate outstanding defect

Rarz's large-count LuaJIT probe was
`timeout 5 random -b -c 2362232012 --seed 0x700A`. Its observed result was
exit 124 with zero bytes, not successful empty output. LuaJIT currently
assembles the whole binary request before writing. This pass fixes Zig/Rust
normalized throughput; LuaJIT bounded-memory streaming remains tracked in
PLAN. No claim of a `2^31` count-parsing defect follows from that timeout.
