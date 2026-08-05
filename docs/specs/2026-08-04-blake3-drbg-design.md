# BLAKE3 keyed-DRBG replacement for PCG32 — design

**Date:** 2026-08-04 · **Status:** implemented and gated in LuaJIT and Zig/C ·
**Supersedes:** the PCG32 deterministic generator in `bin/random`

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
was never ported. `bin/random` (LuaJIT) remains the differential oracle. The C
CLI now passes the same Bash contract plus an exact seed/flag/stdin matrix, and
the construction remains directly gated against published official outputs.

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

**Also implemented downstream:** the pure Zig core, caller-owned C ABI, and C
CLI. Benchmarking and additional distributions remain separate work.

## The generator: keyed XOF + seek

Construction chosen (over keyed-hash-of-counter) for its single-position
resumable state:

```
state = { key: [32]u8, pos: exact_integer } # pos is a BYTE offset into the keystream

keystream = BLAKE3_keyed(key).xof()        # extendable output, seekable
draw_bytes(n): b = keystream.seek(pos).read(n); pos += n; return b
seek_to_draw(n, width): pos = n * width    # O(1) random access to draw N
```

- LuaJIT: the vendored LuaJIT-specific implementation's
  `blake3(message="", key, -1)` returns the seekable closure
  (`f("seek", pos)` / `f(nbytes)`), verified against official output and the
  Zig stdlib.
- Zig: `std.crypto.hash.Blake3` keyed, XOF via the public
  `finalizeSeek(seek, out)` API in Zig 0.16.
- The keyed-hash *message* is empty; the key alone determines the stream. The
  KDF context string below domain-separates keys derived through this CLI.
- LuaJIT numbers represent integers exactly only through 2^53. The Lua oracle
  therefore rejects any seek or consumption that would make `pos > 2^53`.
  Zig may support a wider internal position later, but the shared public
  contract remains capped until both implementations can represent it exactly.

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
pin and convert explicitly on both implementations regardless. BLAKE3's
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
OS fallback), print them as a replayable `0x` seed, and feed the same canonical
32 bytes through the KDF. This replaces `now_seed()` and fails closed if entropy
is unavailable. Re-running with the printed seed must reproduce the stream.

`DRANDOM_SEED` (LuaJIT CLI) and `DRANDOMZ_SEED` (C/FFI CLI) follow the same
rules as `--seed`. Each frontend ignores the other frontend's variable.

## State and persistence

The CLI performs no persistent writes. PCG32 state files, legacy seed files,
`DRANDOM_CONTEXT`, and `DRANDOM_STATE_HOME` are removed without migration.
Every invocation starts at byte position zero from an explicit seed or a newly
generated seed printed to stderr. Consumers that later need continuation may
store `(key, pos)` outside the core through an explicit API, but implicit disk
state is not part of this CLI contract.

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
variable, and the `drandom`/`drandomz` argv[0] aliases remain. Seed grammar and
deterministic streams deliberately change.
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
- **Cross-architecture:** `./crossarch` compares 512 contiguous seeded BLAKE3
  bytes plus ranged and alternate-distribution CLI outputs on its platform
  matrix, so the DRBG's cross-platform identity is measured, not assumed.
- **Seed replay:** an auto-generated printed seed, supplied explicitly on the
  next invocation, must reproduce the exact stream.
- **Consumption:** chunked XOF reads must concatenate to the same bytes as one
  uninterrupted read, including block-boundary crossings.
- **Mutation:** each new control is mutation-verified (break it, watch it fire,
  restore) per project discipline.

## Implemented Zig/C boundary

`src/randomz.zig` uses `std.crypto.hash.Blake3` keyed-XOF and exports the API in
`include/randomz.h`. The caller owns `(key[32], byte_position)` state; the core
does no I/O and distribution samplers obtain bytes only through a caller-supplied
callback. `src/randomz_cli.c` is compiled as C and links the static library, so
bypassing the public ABI is inexpressible. The CLI-level differential compares
the two BLAKE3 implementations bit-for-bit, with official vectors and the
independent Zig reference retaining control over a self-consistent mistake.

## Finalized boundary decisions

- The public C ABI uses caller-owned `{ key[32], position }` state, explicit
  get/set/fill/u32/u64 calls, checked fixed-format conversions, and
  callback-fed one-shot samplers. Panic-capable low-level arithmetic remains
  internal.
- C and Zig share the Lua oracle's exact-integer position ceiling of 2^53 so
  one serialized state has one meaning on every supported implementation.
