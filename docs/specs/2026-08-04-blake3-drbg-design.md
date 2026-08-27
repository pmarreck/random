# BLAKE3 keyed-DRBG replacement for PCG32 — design

**Date:** 2026-08-04 · **Status:** implemented and gated independently in LuaJIT,
Zig/C, Rust, and Lean 4; selected production invariants formalized in Lean 4 · **Supersedes:** the PCG32
deterministic generator in `bin/random`

## Why

`random`'s deterministic path (`-d`/`--seed`/`drandom`) formerly used PCG32
(XSH-RR 64/32). PCG32 is fast and cross-platform-reproducible, but **trivially
predictable** — its full state is recoverable from a handful of outputs, so it
can never back a secure use. Peter's decision (2026-08-04): the deterministic
path becomes a **BLAKE3 keyed DRBG outright**, not a `--secure` opt-in. A
keyed PRF is deterministic per key, so reproducibility and secrecy can
coexist when the seed itself is secret and has enough entropy. A public or
guessable seed remains guessable after any KDF; the KDF supplies domain
separation and a uniform key representation, not additional entropy.

This was sequenced **before** the Zig FFI/CLI port (Tasks 8–10): porting the
former generator and deleting it the same day would have been waste. The Zig
core implements BLAKE3 directly (`std.crypto.hash.Blake3`); the legacy generator
was never ported. `bin/random` (LuaJIT) remains the original behavioral oracle.
The C and Rust CLIs now pass the same Bash contract plus exact
seed/flag/distribution/stdin matrices, all three implementations are compared
pairwise, and the construction remains directly gated against published
official outputs.

Terminology is important here: LuaJIT is the original implementation and the
behavioral oracle the later Zig port must match. The small Zig-stdlib program
used during this LuaJIT work is only an independent reference check on the
written KDF/XOF construction; it does not define or supersede the Lua contract.

BLAKE3 correctness and performance were established in
`docs/research/2026-08-04-pure-lua-blake3-evaluation.md` (246/246 vs the Zig
stdlib, seekable XOF verified). Licensing is handled as the documented
best-effort inference described under Vendoring & attribution below.

## Scope

**In:** replace `pcg32_*` with a BLAKE3 DRBG, preserve the useful public API,
re-bless deterministic golden vectors, and replace the coupled true-random and
auto-seed entropy paths with fail-closed OS APIs.

**Also implemented downstream:** the pure Zig core, caller-owned C ABI and C
CLI; and the importable pure-core `randomr` Rust library with its separate I/O
and formatting CLI. Alternate distributions, the three-frontend differential
gate, and comparative benchmarking are implemented.

## The generator: keyed XOF + seek

Construction chosen (over keyed-hash-of-counter) for its single-position
resumable state:

```
state = { key: [32]u8, pos: exact_integer } # pos is a BYTE offset into the keystream

keystream = BLAKE3_keyed(key).xof()        # extendable output, seekable
draw_bytes(n): b = keystream.seek(pos).read(n); pos += n; return b
seek_to_draw(n, width): pos = n * width    # O(1) only for fixed-width raw draws
```

- LuaJIT: the vendored LuaJIT-specific implementation's
  `blake3(message="", key, -1)` returns the seekable closure
  (`f("seek", pos)` / `f(nbytes)`), verified against official output and the
  Zig stdlib.
- Zig: `std.crypto.hash.Blake3` keyed, XOF via the public
  `finalizeSeek(seek, out)` API in Zig 0.16.
- Rust: the official `blake3` crate's pure-Rust backend, using derive-key mode
  and a keyed XOF reader with an explicit byte position. It shares neither
  implementation code nor FFI with the LuaJIT or Zig core.
- Lean: an independent single-chunk derive-key/keyed-empty-message XOF model
  in `lean/Randoml`, sufficient for this DRBG's fixed context and 32-byte seed.
  The same importable Lean library owns the integer-only numeric kernel, every
  distribution, state parser, CLI semantics, formatting, stdin operations, and
  canonical chart model. `randoml` is therefore a fourth independent oracle;
  it has no `randomz` process or library dependency.
- The keyed-hash *message* is empty; the key alone determines the stream. The
  KDF context string below domain-separates keys derived through this CLI.
- LuaJIT numbers represent integers exactly only through 2^53. The Lua oracle
  therefore rejects any seek or consumption that would make `pos > 2^53`.
  Zig or Rust may support a wider internal position later, but the shared
  public contract remains capped so all implementations represent it
  exactly.
- Seeking to a known byte position is O(1). Locating distribution item N from
  only a seed is generally O(N): rejection sampling and nonlinear samplers may
  consume a variable number of bytes. Emitted continuation state records the
  actual byte position, so resumption itself remains O(1).

### Endianness: BIG-ENDIAN, one rule everywhere

Every integer↔bytes conversion is **big-endian** — both byte→draw assembly and
integer-seed→bytes serialization. Rationale: a byte stream does not *imply* an
endianness (repacking a byte group into an integer is a choice), but the
universal convention for reading a byte string / hash output *as a number* is
big-endian (network byte order = how the hex reads left to right), and it is the
**verifiable** choice this project's ethos demands: the first u64 draw off
keystream hex `af1349b9f5f9a1a6…` is `0xaf1349b9f5f9a1a6`, read straight off,
no mental byte-flip, checkable by hand or by an independent oracle. (Little-
endian's only pull is that it is the x86 native freebie — void here, since we
pin and convert explicitly in all three implementations regardless. BLAKE3's
internals are LE, but that governs its own word serialization, not how we read
the output as draws.)

```
draw_u32(): be_u32(draw_bytes(4))          # b0*2^24 + b1*2^16 + b2*2^8 + b3
draw_u64(): be_u64(draw_bytes(8))
```

## Seed → key

The 256-bit key is derived via BLAKE3's **KDF (derive_key) mode** with a
versioned context string. This produces a domain-separated key without claiming
to strengthen the entropy of a guessable seed:

```
KDF_CONTEXT = "random drbg 2026-08-04 v1"           # bump on any wire change
key = BLAKE3_derive_key(seed_material, KDF_CONTEXT, 32)
```

`--seed` accepts one unsigned integer in either decimal or `0x`-prefixed
hexadecimal notation. Both forms are parsed as a mathematical integer no wider
than 256 bits and serialized canonically as exactly 32 big-endian bytes before
the KDF. Equivalent spellings such as `42`, `0x2a`, and `0x002A` deliberately
select the same stream.

| `--seed` form | rule | `seed_material` |
|---|---|---|
| decimal | one or more ASCII digits, value < 2^256 | 32-byte big-endian integer |
| hexadecimal | `0x` or `0X`, then 1–64 ASCII hex digits | the same 32-byte big-endian integer |

Signs, whitespace, separators, bare hex, passphrases, empty hex, and values at
or above 2^256 are rejected. A uniformly generated 256-bit value is suitable
for an unguessable reproducible stream; a small decimal seed is suitable only
for reproducibility.

**No-seed path:** draw 32 bytes from `getrandom`/`getentropy` (or the documented
OS fallback), emit them as a replayable `0x` seed in JSON state, and feed the same canonical
32 bytes through the KDF. This replaces `now_seed()` and fails closed if entropy
is unavailable. Re-running with the emitted seed must reproduce the stream.

`DRANDOM_SEED` (LuaJIT CLI), `DRANDOMZ_SEED` (C/FFI CLI), `DRANDOMR_SEED`
(Rust CLI), and `DRANDOML_SEED` (Lean frontend) follow the same rules as
`--seed`. Each frontend ignores the other frontends' variables.

## State and persistence

The CLI performs no persistent writes. PCG32 state files, legacy seed files,
`DRANDOM_CONTEXT`, and `DRANDOM_STATE_HOME` are removed without migration. A
seed starts at byte position zero. State schema 2 uses short `args.op` and
`args.delim` keys and rejects schema 1. Deterministic success emits one compact JSON
object on stderr containing compatibility version `sv`, producer application
version `rv`, the canonical root `seed`, the actual XOF byte cursor `next_pos`,
effective semantic `args`, and `notices`/`warnings`. Output values remain solely
on stdout and are never duplicated in metadata.

`--state-stdout` moves successful deterministic metadata from stderr to the
final stdout line without duplicating values. It implies deterministic mode,
conflicts with true-random mode, and requires a textual encoding for binary
output. Errors remain JSON on stderr.

`sv` is the enforced compatibility gate and must increment for any change to
state or stream interpretation. `rv` records the producer application's version
for diagnostics only; consumers deliberately accept other string values so an
application-only version bump does not invalidate an otherwise compatible
stream.

`--state` and `--resume` are aliases. They accept inline JSON; `-` or an omitted
value reads at most 1 MiB from stdin. Explicit CLI arguments override inherited
`args`; state and `--seed` are mutually exclusive. Stdin population operations
require inline state. The root seed—not the derived key—is serialized, and all
three implementations reconstruct the DRBG then seek to `next_pos`. Thus state
is implementation-neutral: every LuaJIT, Zig/C, Rust, and Lean-frontend producer→consumer
direction is tested across every distribution and direct binary output.
State JSON must be valid UTF-8 and is structurally bounded to 64 nested levels,
32 members per object, and 1024 items per array so hostile input cannot overflow
a recursive parser stack or trigger effectively unbounded schema-irrelevant work.

All CLI-controlled diagnostics and notices are also JSON on stderr. When no
state, notice, warning, or error exists, stderr is empty.

## Draw operations (API-preserving)

The three consumption shapes keep their exact external behaviour; only the bit
source changes from PCG32 to the BLAKE3 keystream:

- **`range(a, b)`** — deterministic sampling retains the rejection logic
  (including the ≥2^33 power-of-two short-circuit fixed earlier), calling
  `draw_u32`/`draw_u64` instead of `pcg32_random`. The true-random wide path
  now uses the same exact u64 arithmetic rather than assembling 7–8 bytes in
  an inexact Lua number.
- **`uniform [0,1)`** — keeps the `from_int(u32) / 2^32` soft-float shape
  (`pcg32_uniform`'s structure), so every distribution built on it (normal,
  exponential, …) keeps its arithmetic structure; only the uniform bits differ.
- **default `--binaryoutput`** over the full byte range `[0,255]` emits
  `draw_bytes(count)` directly. A custom byte range or a non-uniform
  distribution retains the ordinary sampling path and its corresponding draw
  consumption. These two cases are separate frozen contracts.

## Public API preserved

`-d`/`--deterministic`, `--seed`, the frontend-specific seed environment
variable, and the `drandom`/`drandomz`/`drandomr`/`drandoml` aliases remain. Seed
grammar and deterministic streams deliberately change.
Implicit cross-call state continuity and its two state environment variables
are removed.

## Vendoring & attribution

Vendor the author's faster LuaJIT-specific `blake3_for_luajit.lua` at its
verified commit. Preserve Egor Skriptunoff's authorship, the complete MIT notice
from the earlier `pure_lua_SHA` work, both upstream URLs, both commit IDs, and
this provenance statement: source history and direct comparison show that the
gist derives from the same author's MIT-licensed BLAKE3 implementation, but the
gist itself carries no visible license and clarification is presently
unavailable. This is a deliberate best-effort licensing inference, not a claim
that the gist contains an explicit MIT grant.

## Golden vectors

Every seeded stream changes, so **all deterministic golden vectors are
re-blessed in the same commit** as the generator swap (`tests/golden/`, via
`tests/bless-goldens`). The re-blessing is a deliberate, reviewed act; the new
vectors become the frozen definition of the BLAKE3-DRBG streams. Integer/kernel
goldens for `lib/fixed.lua` are unaffected (the kernel is unchanged).

## MFIC controls

- **Official external oracle:** vendor the upstream BLAKE3
  `test_vectors.json` unchanged and check all 35 published cases in hash,
  keyed, and derive-key modes at both 32-byte and 131-byte output lengths.
- **Additional independent reference:** compare 4 seed classes at output
  lengths 1, 31, 32, 63, 64, 65, and 131 against Zig 0.16's stdlib. This can
  catch a self-consistent Lua construction mistake, but LuaJIT remains the
  behavioral oracle for the port. Keep seek/chunk probes against published
  official expected bytes.
- **Three-way differential:** require complete seeded CLI matrices for
  LuaJIT↔Zig/C, Rust↔LuaJIT, and Rust↔Zig/C. Rust's official pure BLAKE3
  backend and independent integer kernel make the two later implementations
  separate judges rather than one copied oracle.
- **Cross-architecture:** `./crossarch` compares 512 contiguous seeded BLAKE3
  bytes plus ranged and alternate-distribution CLI outputs on its platform
  matrix, so the DRBG's cross-platform identity is measured, not assumed.
- **Seed replay:** an auto-generated seed emitted in JSON continuation state,
  or supplied explicitly on the next invocation, must reproduce the exact
  stream.
- **Consumption:** chunked XOF reads must concatenate to the same bytes as one
  uninterrupted read, including block-boundary crossings.
- **Mutation:** each new control is mutation-verified (break it, watch it fire,
  restore) per project discipline.

## Implemented Zig/C boundary

`src/randomz.zig` uses `std.crypto.hash.Blake3` keyed-XOF and exports the API in
`include/randomz.h`. The caller owns `(key[32], byte_position)` state; the core
does no I/O and distribution samplers obtain bytes only through a caller-supplied
callback. `src/randomz_cli.c` is compiled as C and links the static library, so
bypassing the public ABI is inexpressible. The LuaJIT↔Zig/C differential
compares those two BLAKE3 implementations bit-for-bit, with official vectors
and the independent Zig reference retaining control over a self-consistent
mistake.

## Implemented Rust boundary

`rust/randomr` is an importable deterministic library with caller-owned `Drbg`
state and byte-source-driven samplers. Its default entropy feature is isolated
in `entropy.rs`; the deterministic core builds without that feature and without
`std`. `rust/randomr-cli` exclusively owns argv, environment variables, OS
paths, stdin/stdout, formatting, and terminal chart protocols. Rust is judged
independently by both the LuaJIT and Zig/C implementations across the complete
seeded CLI matrix, while direct library vectors pin state, consumption, and
every sampler without going through CLI formatting.

## Implemented Lean boundary

`lean/Randoml` is an importable, pure Lean 4.30 library. It independently
implements the exact BLAKE3 compression/KDF/keyed-XOF construction needed by
this DRBG, seekable byte generation, big-endian 32/64-bit assembly, and narrow
and wide rejection sampling. It also owns fixed arithmetic, all six
distributions, JSON state, CLI validation, formatting, stdin operations, and
the semantic/chart-raster pipeline. Lean's kernel checks production-linked
proofs for cursor advancement, key preservation, position/range bounds,
canonical parameter boundaries, curve endpoints, and population preservation
under the production shuffle operations. A separate abstract stream theorem
establishes slice composition; byte equality for two actual `xofAt`/`fill`
chunks remains differentially tested rather than formally connected to it.

The executable uses a thin C adapter only where operating-system bytes require
it: byte-preserving `argv`, OS entropy handles, platform/architecture labels,
and the Base64 transport codec used for terminal output. The canonical chart
shape/raster remains Lean-owned. The exact proved/tested/assumed boundary is
recorded in
`docs/reports/2026-08-26-lean4-evaluation.md`.

## Finalized boundary decisions

- The public C ABI uses caller-owned `{ key[32], position }` state, explicit
  get/set/fill/u32/u64 calls, checked fixed-format conversions, and
  callback-fed one-shot samplers. Its entropy-free distribution-curve API
  returns normalized heights and x-bounds to caller-owned storage; terminal
  protocols and rasterization remain in the CLIs. Panic-capable low-level
  arithmetic remains internal.
- C, Zig, Rust, and Lean share the Lua oracle's exact-integer position ceiling of
  2^53 so one serialized state has one meaning on every supported
  implementation.
