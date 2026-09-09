# Independent production batching review

Status: done, including follow-up review of the explicit ±2^53 batch domain and durable non-AVX gate. No blocking regression found. This is an empirical and source-level review, not a formal proof or an audit of BLAKE3 security.

## Scope and independence

Reviewed `src/randomz.zig`, `src/fixed_simd.zig`, `src/fixed_simd_dispatch.zig`, `build.zig`, `include/randomz.h`, C CLI batching, Rust `batch.rs`/`batch_avx2.rs`/CLI changes, and associated purity/resumption controls. The control plan was recorded from the ABI contract and existing scalar behavior before reading the batch implementations. Existing unchanged scalar APIs were the causal oracle; the independent controls contain no copied nonlinear math.

## Independent executions

- Final C ABI differential control passed 109,440 cases. It swept all 289 ordered pairs from seventeen signed endpoints around i64 min/max, ±2^53 and immediately inside/outside, ±2^31, zero and singleton bounds; counts 0..17; partial-byte failure caps 0..130; callback return statuses 1..7; and pseudorandom, all-one rejection and forced tail-rejection prefixes. Within the supported domain, AUTO and SCALAR matched repeated scalar calls in returned values/status, completed count, untouched suffix, total consumed bytes, callback count and every requested read length. Outside the domain, both modes returned InvalidArgument with written=0, untouched samples and zero callback requests, including count=0.
- Final Rust library differential control passed 47,210 cases. It checked the same 289 endpoint pairs/counts against both generic and Drbg batch entries, every available-byte cap 0..130 over 32 seeds and ten counts through 31, and 1,025 outputs partitioned into eleven widths from 1 to 257. Within the supported domain, results, typed failure prefixes and continuation positions matched unchanged scalar sampling. Outside it, both entries returned zero-prefix InvalidArgument without changing samples or position.
- Independently reran the existing Zig ReleaseSafe dispatcher artifact under QEMU Nehalem (no AVX) and Haswell with XSAVE disabled. All three tests passed on each: valid endpoints/quadrants, malformed/out-of-domain lanes, and 10,000 mixed four-lane exact ln/cos batches. Haswell emulation emitted expected unsupported HLE/RTM feature warnings.
- Both production CLIs, native and QEMU Nehalem, produced identical normalized 1,025-byte output for seed 42, SHA256 `423dddc65929cb24983930c697c678e288066facbf19d1715a28def810e84975`.
- Ran the Rust purity check successfully. Read the new unsafe-core/SIMD-I/O mutation cases; their full mutation-suite execution belongs to the implementation agent/parent and was not repeated here.

## Source review conclusions

- Batches gather at most four candidates when at least four output slots remain. Accepted candidates commit in original order; rejected candidates cannot cause consumption beyond the scalar requested prefix. Scalar tails avoid hidden saved samples.
- Zig finishes complete candidate lanes before propagating a later callback failure. Every new batch entry in both languages now requires `-2^53 <= start <= end <= 2^53`, keeping downstream integer conversion away from i64 overflow. Domain validation occurs before sampling or sample writes, even for empty batches. The legacy scalar APIs were left unchanged.
- Rust speculates only with its own seekable Drbg. On a math/read error it restores the saved valid position and runs unchanged scalar sampling, including its exact error prefix/cursor. Generic user ByteSource callbacks stay scalar, so partially consuming external failures are never replayed.
- SIMD inputs are checked before unsafe arithmetic. Rust admits only canonical positive sampler uniforms in [2^-20,1]; Zig separately checks canonical ln `(0,1]` and cosine `[0,1]` lanes, with exponent at least -64. Fixed coefficient arrays and four-lane/256-value scratch arrays are constant sized. No production sample-count allocation or worker thread was found.
- Zig checks CPUID capabilities and OS XMM/YMM state before entering noinline AVX2 functions. Inspected existing LLVM attributes confirm dispatcher baseline `-avx,-avx2` and vector boundary `+avx,+avx2` plus SSE dependencies covered by the detector. Rust target-feature functions stay behind private safe runtime detection. The non-AVX and XSAVE-disabled executions support this boundary; emulation is not native hardware performance evidence.
- CLI batching uses bounded storage. Successful text prefixes survive a later sampling failure; binary chunk failure handling retains the previous chunk-level emission policy. No change to scalar distribution formulas was found in the reviewed diff.

## Findings and residuals

No actionable new correctness or memory-safety bug was reproduced.

The original draft inherited pathological narrow ranges close to i64 extrema from the scalar API. Review recommended narrowing only the new batch APIs, consistent with the existing public MAX_EXACT_INTEGER and CLI domain. That recommendation was accepted and implemented. The final independent controls confirm deterministic rejection outside ±2^53. The old scalar behavior remains a separate tracked issue; it is no longer accepted by the new batch APIs. Rejection sampling still cannot promise termination for an adversarial source, even within the supported domain.

The final header, Rust API docs and README state the domain restriction. A minor wording issue was sent to the parent: invalid inputs must not write samples, but the C API intentionally sets the separate `written` result to zero; its comment should distinguish those writes.

## Durable fallback gate follow-up

Reviewed the added `tests/cross_arch_diff` block and its two declared `flake.nix` toolchain symlinks. The gate compares the same native executable under Nehalem emulation for counts 1,4,5,257,1025 across raw/hex/base64 output, checks nonzero producer statuses through pipefail, rejects empty digests, and compares nonempty continuation metadata. Failures enter the existing accumulated failure count. Shell syntax passed. The emulator comes from declared `pkgs.qemu-user`; the Rust target comes from an existing installed `$out/libexec/randomr` ELF, avoiding the shell wrapper under QEMU. The writing-nix source preflight confirmed all five newly required source/test inputs are tracked. No defect found in this addition. Parent owns execution of the complete cross-architecture gate; this reviewer did not repeat its full build.

Cross-language LuaJIT/Lean continuation and the complete output-encoding matrix are parent-owned full-suite gates. Their newly added cases were inspected but not redundantly executed by this reviewer. Likewise, release speed claims belong to the parent's exact-output-gated measurements. Private SIMD tests sweep substantial finite corpora, not every possible canonical mantissa. No native Windows/macOS/ARM execution was performed here.

## Artifacts, changes, and retry instructions

No source edits, commits, deletions, Python, payload files, or Nix-store searches were performed. No codescan watcher was started or stopped.

Created RAM-resident review artifacts using apply_patch:

- `/tmp/dispatch-log/random-production-review-progress.md`
- `/tmp/dispatch-log/random-production-review-final.md`
- `/tmp/dispatch-log/random-production-review-control.c`
- `/tmp/dispatch-log/random-production-review-control.rs`

Compiled executables are `/tmp/dispatch-log/random-production-review-control` and `/tmp/dispatch-log/random-production-review-rust-control`. Build tools were invoked through `nix develop`. The C control links `zig-out/lib/librandomz.so`; Rust links the release rlib under the Cargo-metadata target directory `/mnt/devcache/projects/random-b4b940d363e1/cargo-target`.

One tooling pitfall: the top-level release rlib initially predated batching although the CLI had been rebuilt. Direct linking correctly failed for missing batch APIs. `nix develop -c cargo build --locked --release -p randomr --message-format=json` refreshed the top-level artifact, and the unchanged review control then compiled and passed. This was stale local build output, not an implementation failure.

The final rerun emitted an ignored concurrent Nix SQLite evaluation-cache busy warning, then completed successfully; both independent controls returned zero. No review retry is needed for the source examined. Parent should finish its full-suite and performance acceptance gates, and rerun these controls if production batching changes before commit.
