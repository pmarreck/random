# BLAKE3 keyed-DRBG replacement for PCG32 — design

**Date:** 2026-08-04 · **Status:** approved design, pre-implementation ·
**Supersedes:** the PCG32 deterministic generator in `bin/random`

## Why

`random`'s deterministic path (`-d`/`--seed`/`drandom`) currently uses PCG32
(XSH-RR 64/32). PCG32 is fast and cross-platform-reproducible, but **trivially
predictable** — its full state is recoverable from a handful of outputs, so it
can never back a secure use. Peter's decision (2026-08-04): the deterministic
path becomes a **BLAKE3 keyed DRBG outright**, not a `--secure` opt-in. There is
nothing lost by making the reproducible generator also unpredictable — a keyed
PRF is deterministic per key, so reproducibility and secrecy coexist.

This is sequenced **before** the Zig FFI/CLI port (Tasks 8–10): porting PCG32 to
Zig and deleting it the same day is waste. The Zig core implements BLAKE3
directly (`std.crypto.hash.Blake3`, already verified 246/246 against the official
vectors); **PCG32 is never ported.** `bin/random` (LuaJIT) is the differential
oracle, so it changes first.

BLAKE3 correctness/perf/licensing were settled in
`docs/research/2026-08-04-pure-lua-blake3-evaluation.md` (246/246 vs the Zig
stdlib, seekable XOF verified, MIT via `pure_lua_SHA`).

## Scope

**In:** the deterministic generator only — replace `pcg32_*` with a BLAKE3 DRBG,
preserve the public API, re-bless deterministic golden vectors.

**Out (separate, coupled tasks):** the true-random path's entropy fix
(`getrandom`, fail-closed, delete the `now_seed()` time fallback) is its own
work item; this design only *depends* on it for the DRBG's auto-seed. The Zig
port is downstream.

## The generator: keyed XOF + seek

Construction chosen (over keyed-hash-of-counter) for its single-position
resumable state:

```
state = { key: [32]u8, pos: u64 }          # pos is a BYTE offset into the keystream

keystream = BLAKE3_keyed(key).xof()        # infinite output, seekable
draw_bytes(n): b = keystream.seek(pos).read(n); pos += n; return b
seek_to_draw(n, width): pos = n * width    # O(1) random access to draw N
```

- LuaJIT: `pure_lua_SHA`'s `blake3(message="", key, -1)` returns the seekable
  closure (`f("seek", pos)` / `f(nbytes)`), verified 6/6 out-of-order this
  session.
- Zig: `std.crypto.hash.Blake3` keyed, XOF via `rootBytes(seek, out)`.
- The keyed-hash *message* is empty; the key alone determines the stream. (A
  fixed domain-separation label in the message is possible but unnecessary —
  the KDF context string below already domain-separates at the key layer.)

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
versioned context string, so a low-entropy human seed still yields a
well-distributed key and the derivation is domain-separated:

```
KDF_CONTEXT = "random drbg 2026-08-04 v1"           # bump on any wire change
key = BLAKE3_derive_key(seed_material, KDF_CONTEXT, 32)
```

`seed_material` depends on how `--seed` was given. **`--seed` accepts full-width
seeds** (Peter's decision), disambiguated by an explicit rule so there is no
ambiguity:

| `--seed` form | rule | `seed_material` |
|---|---|---|
| all decimal digits, fits u64 | today's behaviour (compat) | the integer, big-endian 8 bytes |
| `0x`-prefixed hex | even length, ≤ 64 hex digits (≤ 32 bytes) | the decoded bytes |
| anything else | treated as a passphrase | the UTF-8 bytes verbatim |

So bare `deadbeef` is a **passphrase**, not hex — the `0x` prefix is required for
raw bytes. This keeps `--seed 42` identical to today while allowing
`--seed 0x<64 hex>` for a full-strength reproducible-and-unguessable stream, or
`--seed "any passphrase"`.

**No-seed path:** draw 32 bytes from `getrandom`/`getentropy` and use them
**directly** as the key (already uniform; no KDF needed). This replaces the
current `now_seed()` time-derived fallback and couples to the entropy fix — the
DRBG must fail closed if entropy is unavailable, never fall back to a clock.

`DRANDOM_SEED` (env) follows the same rules as `--seed`.

## State persistence

Continuity across calls is preserved (the "successive `drandom` calls continue
the sequence" behaviour). The persisted state changes from a single u64 to
`(key, pos)`:

- **Path unchanged:** `$DRANDOM_STATE_HOME/drandom/$USER/$context.seed`, keyed by
  `DRANDOM_CONTEXT` (or PPID) exactly as today.
- **Format:** version-tagged, e.g. a first line `random-drbg-v1`, then
  `hex(key)` and decimal `pos`. Exact layout finalized in implementation; it
  must be parse-unambiguous and self-identifying.
- **Old / unparseable files** (including every existing single-u64 PCG32 state
  file) are treated as **absent** → reseed fresh. Safe because the stream
  changes entirely regardless; there is no meaningful migration of a PCG32
  position into a BLAKE3 keystream.

## Draw operations (API-preserving)

The three consumption shapes keep their exact external behaviour; only the bit
source changes from PCG32 to the BLAKE3 keystream:

- **`range(a, b)`** — the existing rejection-sampling logic is generator-
  agnostic and stays byte-for-byte (including the ≥2^33 power-of-two short-
  circuit fixed earlier). It just calls `draw_u32`/`draw_u64` instead of
  `pcg32_random`.
- **`uniform [0,1)`** — keeps the `from_int(u32) / 2^32` soft-float shape
  (`pcg32_uniform`'s structure), so every distribution built on it (normal,
  exponential, …) keeps its arithmetic structure; only the uniform bits differ.
- **raw bytes / `--binaryoutput`** in deterministic mode emit `draw_bytes`
  directly.

## Public API preserved

`-d`/`--deterministic`, `--seed`, `DRANDOM_SEED`, `DRANDOM_CONTEXT`,
`DRANDOM_STATE_HOME`, the `drandom` argv[0] symlink, and cross-call state
continuity all behave as before. New surface is strictly additive: `--seed` now
*also* accepts hex/passphrase forms.

## Vendoring & attribution

Derive `lib/blake3.lua` **from `pure_lua_SHA`'s `sha2.lua`** (MIT, © 2018–2022
Egor Skriptunoff) by stripping its multi-engine (Lua 5.1–5.4 / Luau) dispatch
down to the LuaJIT BLAKE3 path — the author's own path, per the chronology
(BLAKE3 landed in the MIT repo 2022-01-09; the LuaJIT gist was published
2022-03-05, i.e. it is the *derivative*). Modifying MIT code is explicitly
permitted, so the derived file stays MIT with the header and copyright retained
and the upstream repo credited by name and URL — **real chain of title, not
inferred**. The derived file is re-verified against the same 246 official
test-vectors before use.

Rejected: copying the unlicensed gist's bytes and relabeling them MIT — the
gist carries no license, and an author is not bound by his own MIT grant on a
separately-published file, so that attribution would be inference, not a grant.

Honest caveat: stripping may not perfectly reproduce the gist's ~44% small-call
speed edge if the gist has hand-tuning beyond dispatch removal; it will be close,
and this is the oracle/CLI, where bulk throughput (a measured wash) is what
matters most.

## Golden vectors

Every seeded stream changes, so **all deterministic golden vectors are
re-blessed in the same commit** as the generator swap (`tests/golden/`, via
`tests/bless-goldens`). The re-blessing is a deliberate, reviewed act; the new
vectors become the frozen definition of the BLAKE3-DRBG streams. Integer/kernel
goldens for `lib/fixed.lua` are unaffected (the kernel is unchanged).

## MFIC controls

- **Differential oracle (external):** the 246 official BLAKE3 test-vectors gate
  the derived `lib/blake3.lua` — an oracle authored by the algorithm's
  designers, not by us. Re-run in `./test`.
- **Cross-architecture:** `./crossarch` already sweeps `bin/random`; a seeded
  BLAKE3 stream digest is added to its payload so the DRBG's cross-platform
  identity is proven on the four-platform matrix, not assumed.
- **Round-trip / resumption:** persisting state, reloading, and continuing must
  produce the same stream as an uninterrupted run — a metamorphic check.
- **Mutation:** each new control is mutation-verified (break it, watch it fire,
  restore) per project discipline.

## Zig port implication

When Task 8 (FFI) arrives, the Zig core's deterministic generator is
`std.crypto.hash.Blake3` keyed-XOF, occupying the exact slot PCG32 would have.
The FFI exposes DRBG state `(key, pos)`, not PCG32 state. The CLI-level
differential (Task 10) then compares two BLAKE3 implementations that must agree
bit-for-bit — with the official vectors as an additional independent check on
both.

## Open items (finalize in implementation, not blocking)

- Exact byte layout of the state file (self-identifying, version-tagged).
- Whether `--binaryoutput` deterministic mode draws from the same `pos` stream
  as numeric draws (default: yes, one stream per key).
- Draw width for `range` on wide spans (keep today's u32-narrow / u64-wide
  split; it is generator-agnostic).
