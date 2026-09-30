# Kani contracts: 2026-09-30

Run status: all 21 red/green contracts passed and the independent reviewer
granted acceptance for their stated domains. The ordinary `./test` passed
all 28 suites.

## Scope

The optional Rust verification suite now specifies 21 contracts over the existing
production core. The algorithms and ordinary Rust toolchain are unchanged.
`TMPDIR=/dev/shm ./verify-kani` runs a deliberately false version of every
contract before its corrected version. Normal `./test` runs only the fast
evidence-classifier controls, not the solver.

| Area | Domain and property | Exclusions |
|---|---|---|
| Constructor | Every i64 mantissa/i32 exponent: exact canonical acceptance and preservation | Compiler and specification correctness |
| Negation | Every canonical value: exact sign reversal, exponent preservation and involution | Invalid internal representations |
| Add/subtract | Every canonical operand pair and i32 exponent: canonical successful output, typed overflow; guaranteed success for exponents -1000..1000 | Exact real-number addition; intentional truncation remains |
| Multiply | First magnitude 2^62 or 2^62+1, both signs; every canonical second operand and exponent: exact truncated mantissa, sign, exponent and typed overflow | Other first-operand magnitudes, including i64::MAX |
| Divide | Divisor magnitude 2^62 or 2^62+1, both signs; every nonzero canonical numerator and exponent: widened quotient certificate, sign, normalization and typed overflow; separate zero-operand contract | Other nonzero divisor magnitudes |
| Restore/seek | Every key/requested u64 position; arbitrary backing cache and valid initial cursor for seek: cap, preserved key, exact cursor, cleared cache and failure atomicity | Drop-time erasure and release-compiler retention of erasure writes |
| Read | Lengths 1..8 crossing the cap: unchanged state/destination; lengths 0..8 wholly inside coherent cache: exact bytes/cursor and untouched tail | XOF content, refills, bulk reads and larger read lengths |
| Range | Every primitive word and valid i64 start at seven named cardinalities: exact reduction, one/two-word consumption and equal-preimage inverse witness | Other cardinalities, source failures, byte decoding and arbitrary rejection histories |
| Portable batch | 0..4 lanes: wrapper prefix/result/consumption/tail under an explicit scalar model; actual immediate EndOfSource path at range 0..20 | Successful nonlinear scalar evaluation, other ranges and AVX2 |

The seven cardinalities are 3, 257, 2^32-1, 2^32, 2^32+1, 2^53-1 and 2^53.
For the range proofs, an accepted first word returns its exact residue; a
rejected first word is followed by an accepted zero word. Word methods are
modeled directly, so byte ordering and the cryptographic primitive are not
under verification here.

Multiplication constructs the second operand from an unsigned magnitude,
independent sign and exponent. This covers every canonical value, with exponent
zero required for zero. The oracle is algebraic: a first magnitude of 2^62
preserves the second magnitude. For a first magnitude of 2^62+1, zero remains
zero; second magnitudes below i64::MAX produce magnitude+1 without an exponent
increment, while i64::MAX produces 2^62 with one exponent increment. Both
normalization branches are reachable, though the high branch has one magnitude.
The independent reviewer derived this oracle; it does not repeat production
multiplication or normalization.

For each named cardinality s, U is the 32- or 64-bit word universe and
cutoff = U - U%s. The inverse witness j*s+r verifies distinct accepted preimages
for each residue r and rank j. Because cutoff is a multiple of s, each residue
has cutoff/s preimages. Uniformity therefore depends on a uniform primitive
word; this is not a BLAKE3-security proof or a proof over all range sizes.

## Models and controls

The manifest pins every proof ID, authored assertion and cover, function
provenance, loop bound, and explicit stub. The driver compares it with the actual
compiled Kani metadata, so silently running a selected subset cannot pass.
All core Rust sources, Cargo/Nix definitions, proof modules and acceptance
controls are fingerprinted before and after the run.

Seek's six coverage points witness its input domain before the long erasure
path, including a nonzero byte at an arbitrary cache index. Exact cap acceptance
and reachable post-operation assertions establish the resulting behavior.
Its false contract expects the wrong typed error on a rejected position, which
avoids collecting a full cache-wipe counterexample without removing the wipe
from the proof.

Positive evidence requires every contract assertion to succeed and every
declared reachable cover to be satisfied. A few syntactically emitted covers
are explicitly impossible within a named domain, such as rejection for an
exactly dividing range. Those are separately pinned and must be Unreachable.
Unknown statuses/categories, missing checks, unfinished results, solver errors,
timeouts, unrelated failures and wrong proof identities are rejected.
Negative evidence requires exactly its named false-contract failure.

The zeroize compiler barrier is modeled as having no program-memory effect;
actual volatile erasure writes remain in the seek/restore proofs. Read proofs
replace XOF and cache erasure with assert-false forbidden calls and require those
assertions to be unreachable. The batch wrapper model assumes one scalar result
or its original error per modeled word; it does not prove the nonlinear sampler.

This uses the pinned Kani 0.68.0/Rust nightly 2026-08-21 environment from the
[constructor POC](2026-09-24-kani-poc.md), with no default library features,
MiniSAT, checks enabled, sequential solvers, a 240-second per-invocation limit
(360 seconds for seek), five-second kill fallback and 4 GiB per-process
virtual-memory cap.
The ordinary production Rust 1.97.1 environment is separate.

## Findings and cost

No production defect was established by these verifier runs.
The independent reviewer caught a weak negation control: involution and
canonicality also permit a no-op negation. Exact widened sign reversal now
prevents that false acceptance. Arithmetic closure likewise uses an independent
mathematical canonical predicate rather than trusting only `is_valid()`.

Exploratory full two-variable multiplication exceeded 240 seconds. Expanded
unreachable cache-write paths exhausted the 4 GiB solver limit. Those attempts
are failures, not proofs. Named arithmetic domains and forbidden-call read
contracts make the retained claims explicit without changing production code.
An earlier seek control exceeded 240 seconds; another exited 134 while the
verifier collected evidence under the memory cap. Both are inconclusive. Moving
its input witnesses and choosing a cheaper error-path false contract preserves
the production wipe and input domain.
The initial named-MAX multiplication positive proof also exceeded 240 seconds
with both MiniSAT and Kissat. Alternative symbolic encodings were interrupted
for reformulation; they supplied no accepted evidence.
The closed-form MAX oracle also exceeded the limit with MiniSAT and CaDiCaL.
The MAX experiment remains in source without a proof attribute and is excluded
from the accepted manifest. Its complete second-operand domain is still
unproved; the retained second named case uses first magnitude 2^62+1 instead.
This is a stated proof limit, with a follow-up in PLAN, not a production change.

A Bitwuzla 0.9.1 diagnostic returned four failures, including i64 overflow
when adding two widened i32 exponents and a boolean. That expression's possible
range is only -2^32..2^32-1. All four generated input witnesses satisfied the
corresponding contract in native Rust 1.97.1 debug execution and in direct
execution compiled by Kani's exact Rust nightly 2026-08-21 toolchain. The
evidence gate rejected this run. The contradiction remains a tooling investigation, not an
established library defect or an accepted proof.

The accepted run on an AMD Ryzen Threadripper 3990X took 772.08 summed wall
seconds and 790.48 CPU seconds across 42 solver invocations, excluding the two
unfiltered discovery compilations and Nix startup. Peak per-invocation RSS was
1,895,920 KiB (1.81 GiB), below the separate 4 GiB virtual-memory cap. These
are verifier costs, not library throughput or aggregate machine memory.

| Contracts (red and green combined) | Wall seconds | CPU seconds | Peak RSS GiB |
|---|---:|---:|---:|
| Fixed arithmetic, including constructor | 74.07 | 75.61 | 0.28 |
| Restore/seek | 393.76 | 402.78 | 1.81 |
| Bounded read | 164.04 | 169.84 | 1.34 |
| Portable batch | 57.44 | 58.28 | 0.61 |
| Named ranges | 82.77 | 83.97 | 0.18 |

The seek positive invocation took 204.51 seconds and cached-read positive
86.19 seconds. All required positive assertions succeeded, all required covers
were satisfied, and each negative failed only its named false assertion.

The [versioned evidence](../../verification/kani/2026-09-30-evidence.json)
contains all 42 acceptance summaries, exact source fingerprints, compiled proof
metadata, original export hashes, resource measurements and rejected SMT
witnesses. Dictionary rows retain category/function/status/multiplicity plus
exact authored assertion, guard and cover descriptions. Compiler descriptions,
property IDs, locations and traces are omitted explicitly. Reconstructed
summaries pass the original acceptance gate for all 42 runs; the archive is
not a complete raw solver export. Raw exports and transient build artifacts
remained in RAM under `/dev/shm`.

The independent reviewer froze obligations before inspecting implementation,
then replayed all 42 raw acceptance checks, recomputed discovery from all four
compiled targets, and independently regenerated the complete 24-file source
fingerprint set. It also rejected six additional mutations of actual evidence.
All 89 mandatory positive assertions and 79 required covers passed. Four
constant-disabled covers and four forbidden-call guards were separately required
to remain unreachable. The review is recorded in [CODE_REVIEW](../../CODE_REVIEW.md).

Exact-commit shipment is the final gate. MAX/general multiplication, arbitrary
range cardinalities, larger/refilling reads, actual successful nonlinear batch
semantics and cryptographic security remain outside these accepted claims.
