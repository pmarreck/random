# random

[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Frandom.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)

`random` is a cryptographically secure command-line generator built around an
unusual guarantee: given the same seed and arguments, it emits bit-identical
output across supported operating systems and CPU architectures—including for
normal, exponential, Poisson, log-normal, and beta distributions. True-random
mode instead draws fresh entropy from the operating system CSPRNG and is
intentionally not reproducible.

The project ships four independent matching implementations: the original
[LuaJIT](https://luajit.org/) oracle, a Zig core exposed through a public C ABI
and dogfooded by a C CLI, a pure-core Rust library with a separate Rust CLI, and
a Lean 4 implementation with a byte-preserving native launcher. `randoml` owns
its BLAKE3 DRBG, integer-only numeric kernel, distributions, state parser,
formatting, stdin operations, and canonical chart model; it does not launch or
link another implementation. Lean's kernel additionally checks selected
production invariants.
A seeded BLAKE3 keyed XOF powers cross-platform-identical deterministic streams;
stdin operations and multiple output encodings make the same small tool useful
beyond number generation.

It ships four equivalent command families: `random`/`nrandom`/`drandom` use
LuaJIT, `randomz`/`nrandomz`/`drandomz` use the C frontend over Zig, and
`randomr`/`nrandomr`/`drandomr` use Rust. `randoml`/`nrandoml`/`drandoml` use
the independent Lean implementation described above. The invocation name selects normalized or
deterministic mode in every family.

## Features

- **Distributions:** uniform (default), normal (Box-Muller), exponential, Poisson, log-normal, beta
- **Cryptographically secure sources:** the platform OS CSPRNG, or a deterministic BLAKE3 keyed XOF (`-d`/`--seed`)
- **Stdin ops:** `--choose` one item, `--shuffle` all items, `--weighted` (`value:weight`)
- **Output formats:** decimal, `--hex`, `--base64`, raw `--binaryoutput`
- **Visual distribution help:** append `--help` to an alternate-distribution
  flag for its shape; Kitty and Ghostty receive an embedded PNG via Kitty
  graphics, WezTerm receives Sixel, and other terminals (including every
  automatic invocation inside tmux) receive Braille; use `--view` to render
  the shape from parameters supplied on that invocation
- **Portable continuation:** deterministic invocations emit resumable JSON
  state on stderr; any implementation can continue state from either of the
  others, without writing state to disk. `--state-stdout` instead appends the
  same state as the final stdout line for simple `tail -n1` shell pipelines
- **Reproducible across platforms:** seeded streams are bit-identical across machines, operating systems and CPU architectures — verified on x86_64-glibc, x86_64-musl, aarch64-Linux and native aarch64-macOS — because all math runs on an integer-only kernel instead of the platform's libm — see [Determinism](#determinism) below
- **Embeddable core:** `librandomz.a` plus `randomz.h`; callers own DRBG state
  and provide entropy through a callback, so the Zig core performs no I/O
- **Native Rust library:** the `randomr` crate exposes the caller-owned DRBG,
  integer-only fixed arithmetic, samplers, and curve generation; only its
  explicitly selected `entropy` module performs I/O
- **Lean 4 implementation and proofs:** `lean/Randoml` independently implements
  the complete CLI/core surface and proves cursor advancement, key preservation,
  seek/range bounds, canonical-value boundary properties, curve saturation, and
  production shuffle-population invariants under Lean's kernel; see the exact
  proved/tested/assumed boundary in the
  [Lean evaluation report](docs/reports/2026-08-26-lean4-evaluation.md)
- **WASM build:** `randomz-wasi.wasm` exports the same deterministic core plus
  a fail-closed adapter to the host's WASI `random_get`; the pure Rust core is
  compile-gated for `wasm32-wasip1`, while an equivalent Rust artifact is
  deferred until a measured size/performance comparison decides whether
  shipping one or both is useful
- **Small runtime surface:** LuaJIT for the oracle CLI; libc for `randomz`;
  `randomr` is a native Rust executable; `randoml` uses the Lean runtime plus a
  thin C boundary for raw argv, OS entropy, and terminal-transport Base64

### Determinism

Seeded streams are **bit-identical across runs, machines, operating systems and
CPU architectures**. All math runs on an integer-only software float
(`lib/fixed.lua`) rather than the platform's libm, because libm transcendentals
are not portable: IEEE-754 pins down `+ - * / sqrt` and says nothing about
`log`, `cos` or `exp`. Measured glibc vs musl over this program's actual input
domain, `log` differs on 0.006% of inputs, `cos` on 3.06%, and `exp` on 8.85% —
which meant roughly 3% of seeded "normal" values differed between two builds of
the same source at the same seed.

The deterministic generator accepts only an unsigned decimal integer or a
`0x`-prefixed hexadecimal integer smaller than 2^256. Both spellings are
serialized as the same 32-byte big-endian value, passed through BLAKE3's
derive-key mode with context `random drbg 2026-08-04 v1`, then used as the key
for a BLAKE3 XOF over the empty message. Multibyte draws are assembled
big-endian. Default binary output over `[0,255]` is the contiguous XOF byte
stream; other integer ranges use rejection sampling.

The KDF provides domain separation, not extra entropy. A small or public seed
is reproducible and therefore predictable. If deterministic mode is requested
without a seed, the program obtains 32 bytes from the OS and includes the full
`0x`-prefixed seed in its JSON stderr state. Compromise of
that seed/key reveals the stream; this interface does not claim backtracking
resistance or state-compromise recovery.

If unpredictability matters, treat the seed as sensitive: command-line
arguments, shell history, environment variables, and captured stderr may expose
it. The CLI's replay feature is not a secret-storage mechanism.

That portability claim is measured, not argued. On an x86_64-Linux Nix host,
`./crossarch` (`tests/cross_arch_diff`) runs three local/emulated legs built
from pinned sources — x86_64-glibc, x86_64-musl, and aarch64-Linux — and
requires byte-identical output from all of them. Set
`CROSS_ARCH_REMOTE=peters-macbook-pro-m4-max` to add the recorded native
aarch64-macOS Apple-silicon leg (requires `ssh` and `rsync`). It also runs two deliberately
fragile controls that *must* diverge (platform libm across libcs, out-of-range
`double`→int conversion across architectures), because an "identical" verdict
from a comparison that could not have detected a difference proves nothing.
Results and caveats: [`docs/cross-architecture-evidence.md`](docs/cross-architecture-evidence.md).
The same local run compares 54 end-to-end invocations from native x86_64 and
emulated aarch64 Rust executables to the LuaJIT oracle.

While building this kernel we found and filed
[LuaJIT/LuaJIT#1499](https://github.com/LuaJIT/LuaJIT/issues/1499), an
unsigned negate-then-branch trace-compiler miscompilation that silently
corrupted this exact kernel shape. It is fixed upstream, but `lib/fixed.lua`
still ships a `jit.off` mitigation, gated at load time on the running
`jit.version` against the commit that carries the fix — most systems will be
on a pre-fix LuaJIT build for a long time yet. That mitigation is not free:
measured ~5.7x slower on the soft-float distributions (`--normalized`,
`--exponential`, `--poisson`, `--log-normal`, `--beta`) while it's active, and
nothing on the integer-only paths. Once your LuaJIT is built from the fix
commit or later, the mitigation switches itself off automatically.

#### Compatibility note

The BLAKE3 migration deliberately breaks all legacy seeded streams and
removes legacy state-file compatibility. Earlier integer-kernel conversion also
changed seeded alternate-distribution output. Fractional range bounds are not
accepted — `random 1.5..6.5` is an error, not a silently-truncated range.

#### `$IFS` is not part of the reproducibility contract

The default output delimiter (and default stdin item delimiter for
`--choose`/`--shuffle`/`--weighted`) is always a newline, regardless of
the shell's `$IFS`. Earlier versions derived the default from `$IFS`,
which meant a seeded stream's exact bytes — and even which stdin item a
`--choose`/`--shuffle`/`--weighted` call selected — silently depended on
an ambient shell variable neither the seed nor the command line
mentioned. Same seed, same arguments, different `$IFS`, different
output. `--delimiter` remains the explicit, documented control for
anyone who wants something other than newline.

## Usage

```sh
random                              # uniform 0-99
random 1..6                         # inclusive uniform range
random 1...7                        # same values; three dots exclude 7
random -n --mean 50 --stddev 10     # normal distribution
random --exponential --rate 4       # exponential with rate 4
random --poisson --lambda 5         # --mean 5 remains an exact alias
random --beta=3 --alpha=1 --view    # chart Beta(alpha=1, beta=3)
random --exponential --precision 6  # truncate fractional output to 6 places
random -d --seed 42 -c 5            # 5 reproducible numbers
state=$(random -d --seed 42 d20 2>&1 >/dev/null)
random --resume "$state"             # continue at the next die roll
printf '%s\n' "$state" | random --state - --count 10
random --true-random -b -c 32       # force entropy even if DRANDOM_SEED is set
random --hex -c 5                   # 5 hex values
printf 'a\nb\nc\n' | random --choose
printf %s Peter | random --shuffle --delimiter '' # byte-wise: e.g. ePert
printf 'rare:1,common:10' | random --weighted --delimiter ','
packet=$(random --seed 42 --count 3 d20 --state-stdout)
state=$(printf '%s\n' "$packet" | tail -n1)
```

Run `random -h` for the full option list.

### Continuation state

Generated values stay on stdout. A deterministic invocation writes one JSON
state object to stderr after stdout has been flushed:

```json
{"sv":2,"rv":"0.3.0","seed":"0x000000000000000000000000000000000000000000000000000000000000002a","next_pos":"12","args":{"distribution":"uniform","range":"1..20","count":"3","encoding":"text","delim":"\n"},"notices":[],"warnings":[]}
```

`next_pos` is a decimal string containing the next BLAKE3 XOF byte position,
not an output-item counter. That distinction preserves exact continuation when
rejection sampling or a nonlinear distribution consumes a variable number of
bytes. Seeking to the known position is O(1); deriving the Nth distributed
value from only a seed generally requires replaying the preceding values.

The state deliberately contains no copy of stdout's `value` or `values`.
Numbers in `args` are strings so a JSON parser cannot mutate exact decimals
through IEEE-754 conversion. `sv` is the enforced state/stream compatibility
version and must change when serialized semantics change; `rv` is the
informational producer application version and is not a compatibility gate.
Notices and warnings are arrays, and errors use an
`error` object in the same stderr JSON envelope. Successful true-random calls
with no notice or warning leave stderr empty. Input state must be valid UTF-8;
stdin state is capped at 1 MiB, and structural depth/member limits reject
pathological JSON before it can exhaust a parser stack or monopolize the CLI.
Schema 2 uses the short semantic keys `op` and `delim`; schema 1 is rejected
rather than silently translated.

For shell loops that only need to advance state, the redirection order below
captures stderr while discarding stdout:

```sh
state=$(random -d --seed 42 d20 2>&1 >/dev/null)
state=$(random --resume "$state" 2>&1 >/dev/null)
```

When redirecting file descriptors is awkward, `--state-stdout` keeps the
ordinary payload first and writes the same compact state as the final stdout
line. It implies deterministic mode, obtains and reports an OS seed if none is
supplied, conflicts with `--true-random`, and requires `--hex` or `--base64`
with binary output because raw bytes cannot safely share a line protocol.

To resume a stdin population operation, pass the state inline so stdin remains
available for the population:

```sh
printf 'red\ngreen\nblue\n' | random --choose --state "$state"
```

Fractional distributions print 18 deterministic decimal places by default.
Use `--precision N` or its `--truncate N` alias to truncate (never round) to
0–18 places; integer and binary stream semantics are unchanged.

Binary output streams in bounded chunks, including `--hex`, `--base64`,
and distribution-based bytes. LuaJIT uses at most 48 KiB of raw payload per
bulk chunk and 3 KiB per sampled chunk; memory does not grow with `--count`.
Base64 padding and the encoded-output newline appear only at the end.
A failed stream can leave an already-written prefix, but does not emit
successful continuation metadata. Text-number batches and stdin population
operations are separate paths and do not inherit this binary-memory bound.

Distribution-qualified help is order-independent: for example,
`random --normalized --help` and `random --help --normalized` show the normal
curve. The CLI sends its embedded PNG directly through the Kitty graphics
protocol without a temporary file in Kitty and Ghostty. WezTerm uses a
code-generated Sixel rendering of the same plot. Automatic mode always uses
the scrollback-stable UTF-8 Braille fallback inside tmux: terminal image
placements can disappear when scrolling even when tmux and the outer terminal
both advertise a supported protocol. Set
`RANDOMZ_CHART_TYPE=utf8|kitty|sixel` to override automatic selection.
`--utf8` (also `--utf8-graphics`), `--kitty`, and `--sixel` override the environment for one
distribution-help or `--view` invocation; if repeated, the last renderer flag
wins.

`--view` requires exactly one alternate distribution, generates no random
bytes, and prints only that distribution's parameter summary and chart. Normal
and log-normal accept `--mean` and `--stddev`; either normal parameter can be
supplied independently and the omitted one defaults to mean 0 or standard
deviation 1. Exponential accepts `--rate`, Poisson accepts `--lambda` (with
`--mean` retained as an exact alias), and bare `--beta` uses beta parameter 2
while `--beta B` or `--beta=B` replaces it; `--alpha` controls alpha. Parameter
options accept both `--name value` and `--name=value`. Distribution-qualified
`--help` deliberately keeps showing the frozen default chart even when
parameter tokens are also present.

Uniform and range-scaled normal modes accept at most one atomic integer range:
`M-N` and `M..N` include both endpoints, while Ruby-style `M...N` excludes N.
For die rolling, `dN` is an exact alias for `1..N`, so `random d6`,
`randomz d20`, and `randomr d100` select uniformly from the corresponding die
faces. `N` must be a positive whole number no larger than 2^53. The default
remains `0..99`. The former one/two bare endpoint grammar is not accepted.
Ranges are rejected where a distribution's own parameters determine its
output, including custom-parameter normal mode.

For stdin operations, an empty `--delimiter ''` means individual input bytes,
not Unicode code points: choose returns one byte and shuffle permutes all bytes
before writing one final newline. It deliberately preserves whitespace, NUL,
and invalid UTF-8. Weighted input rejects an empty delimiter because its
`value:weight` records cannot be represented byte-by-byte.

`--test` runs the shared Bash contract suite. Nix installations close over its
tool dependencies; manual Zig and Windows installations require Bash plus the
common Unix command-line tools used by the suite.

### Entropy and persistence

True-random mode uses `getrandom` on Linux, Solaris, and illumos;
`arc4random_buf` on Apple and the BSDs; `BCryptGenRandom` on Windows; and
`getentropy` on other Unix platforms that provide it. An exact-read
`/dev/urandom` fallback is used only when the selected Unix kernel API reports
that it is unavailable. Any other source error, policy denial, or short read
fails closed. `--random-source PATH` selects an explicit byte source, chiefly
for deterministic testing; `--no-wait` requests `GRND_NONBLOCK` on a
`getrandom` backend.

The Apple, FreeBSD, OpenBSD, and NetBSD C frontends are cross-compile gated on
x86_64 and aarch64. Solaris/illumos and DragonFly have pinned source selectors,
but Zig 0.16 currently lacks usable cross-libc support for their full artifacts;
native runtime validation remains pending and support is not yet claimed.

For Rust, the cross-build gate covers Linux aarch64, Windows x86_64/ARM64,
FreeBSD x86_64, and NetBSD x86_64 in addition to native Linux. Rust 1.97.1 does
not distribute standard libraries for OpenBSD or BSD ARM64, so those are
explicit target-library gaps rather than silent skips. Native ARM64 macOS and
Windows workflow legs have passed with architecture-sensitive controls, a
frozen raw stream plus all nonlinear distributions and stdin shuffling, OS
entropy, and the installed CLI self-test.

Backend flags are normalized to numeric `0`/`1` values and tested by value,
never by macro presence. The build rejects zero or multiple selected backends;
the test suite additionally defines disabled backends as `0` and proves they
remain false. Object-symbol checks pin each target to its intended OS API, and
a fault-injection test proves an OS policy denial cannot become a weak or
deterministic fallback.

The CLIs never persist deterministic state. Reusing a seed restarts the same
stream; omitting it emits a replayable JSON state. `--state` and its `--resume`
alias accept that object inline, from `-`, or from stdin when their value is
omitted. Explicit CLI arguments override inherited `args`; `--state` and
`--seed` are mutually exclusive. Because `--choose`, `--shuffle`, and
`--weighted` use stdin for their populations, those operations require state
inline. The LuaJIT CLI uses
`DRANDOM_SEED`; the C/FFI CLI uses `DRANDOMZ_SEED`; the Rust CLI uses
`DRANDOMR_SEED`; and the Lean frontend uses `DRANDOML_SEED`. Each frontend
ignores the other three namespaces.
An inherited frontend-specific seed variable makes a plain invocation
deterministic, so security-sensitive callers should use `--true-random`, which
overrides that frontend's environment variable and rejects deterministic flags.

The vendored LuaJIT BLAKE3 implementation is by Egor Skriptunoff. Its header
preserves the author's MIT notice from the verified earlier `pure_lua_SHA`
ancestor and records the chronology, source commits, and the fact that the
LuaJIT-only gist has no separately visible license.

## Install

### Nix (flake)

```sh
nix run github:pmarreck/random#random-luajit  # LuaJIT oracle only
nix run github:pmarreck/random#random-zig     # C CLI over the Zig core
nix run github:pmarreck/random#random-rust    # Rust CLI
nix run github:pmarreck/random#random-lean    # Lean CLI
nix build github:pmarreck/random#random-luajit-lib
nix build github:pmarreck/random#random-zig-lib
nix build github:pmarreck/random#random-rust-lib
nix build github:pmarreck/random#random-lean-lib
nix profile install github:pmarreck/random#random-all
```

Each language-specific package closes over only the runtime and build tools
needed by that implementation. Blocking checks prove that `random-luajit`
has no Zig, Rust/Cargo, Lean, or other implementation package among its direct
derivation inputs or transitive installed closure. `random-all` is the explicit
aggregate; the unqualified flake default remains an alias for it for backwards
compatibility. The older
`random`, `randomz`, `randomr`, and `randoml` output names remain compatibility
aliases for the aggregate, Zig, Rust, and Lean packages respectively.

The four `*-lib` outputs are independently consumable and contain no CLI:
`random-luajit-lib/lib` holds the Lua modules; `random-zig-lib` exposes the Zig
package source at `src`, the C header at `include/randomz.h`, and static/shared
libraries under `lib`; `random-rust-lib/src/rust/randomr` is a standalone Cargo
path dependency; and `random-lean-lib` supplies source under `src` plus compiled
modules under `lib/lean`. The package gate imports each native-language surface,
and loads the installed shared `librandomz` directly through LuaJIT FFI.

### Manual

For the LuaJIT oracle, put `bin/` on your `PATH`; it requires `luajit`. For the
C CLI and static/shared libraries, run `zig build -Doptimize=ReleaseFast` and use
`zig-out/bin/randomz`, `zig-out/include/randomz.h`, and
`zig-out/lib/librandomz.a` or the platform shared library. Zig programs consume
the exported `randomz` module from this repository's `build.zig`. `nrandomz` and
`drandomz` are installed aliases;
the Nix package installs them as symlinks. Zig release artifacts are stripped
by default; pass `-Dstrip=false` when a diagnostic release build needs symbols.

For Rust, run `cargo build --locked --release -p randomr-cli`; Cargo emits
`randomr`, and the Nix package supplies `nrandomr` and `drandomr` aliases. Rust
programs can depend on the workspace crate at `rust/randomr` and use `Drbg` as a
`ByteSource` for any exported sampler without involving CLI I/O or formatting.
Nix consumers should pin this flake and use its source-overlay package rather
than add a separate Cargo Git dependency:

```nix
let
  randomrLib = random.packages.${system}.random-rust-lib;
  randomrCargoPath = "${randomrLib}/${randomrLib.cargoPath}";
in # substitute randomrCargoPath into the consumer's vendored path dependency
```

`random-rust-lib` is deliberately source rather than a precompiled `.rlib`:
Rust library artifacts are compiler- and dependency-graph-specific, while the
source overlay compiles within the consumer's Nix-vendored Cargo graph. Its
manifest uses compatible semver ranges so it can share that graph's `libc`,
`zeroize`, `blake3`, and `getrandom` versions; this repository's `Cargo.lock`
retains exact release-build resolution. The MSRV and pinned build toolchain are
Rust 1.97.1. The workspace's release profile uses Cargo's `strip = "symbols"`
policy.

For Lean, `(cd lean && lake build)` with Lean 4.30.0 builds and checks the
importable `Randoml` library. Build the byte-preserving production executable
with `lean/build-owned-cli zig-out/bin/randoml`; no Zig binary or library is
used by that command. The dedicated `.#randoml` Nix package installs only the
Lean executable, `nrandoml`/`drandoml` aliases, and its self-test surface.
`build-owned-cli` strips the linked production executable; ordinary Lake
library/development builds retain their diagnostic information.

The same build emits `zig-out/bin/randomz-wasi.wasm`, a WASI Preview 1 reactor
module. It exports memory, the public deterministic `randomz_*` ABI, and
`randomz_wasi_fill(ptr, len)`, which returns `RANDOMZ_OK` on success and
`RANDOMZ_ENTROPY_ERROR` if the host's `random_get` fails. A browser can host
the module through a WASI shim whose randomness implementation calls Web
Crypto `crypto.getRandomValues`; the module never substitutes `Math.random`
or an internal deterministic fallback. The Nix package installs the module as
`lib/randomz-wasi.wasm`.

### C API quick start

The seed material is exactly 32 bytes; CLI decimal/hex parsing is a frontend
convenience. State is caller-owned, must be externally synchronized, and a
copy or process fork clones the future stream.

```c
#include <randomz.h>

uint8_t seed[32] = {0};
uint8_t bytes[32];
randomz_drbg rng;
seed[31] = 42;
if (randomz_drbg_init(&rng, seed) != RANDOMZ_OK ||
    randomz_drbg_fill(&rng, bytes, sizeof bytes) != RANDOMZ_OK)
    return 1;
randomz_drbg_zeroize(&rng);
```

Compile an installed static library with
`cc app.c -I$prefix/include $prefix/lib/librandomz.a -o app`. Samplers accept a
`randomz_fill_fn`; returning a known `randomz_status` preserves that error.
[tests/randomz_abi_test.c](tests/randomz_abi_test.c) is the exhaustive consumer
example, including state replay, fixed-format parameters, every sampler, and
error handling. Windows builds produce `randomz.lib`.

For frequent small draws, opt into `randomz_buffered_drbg` and the matching
`randomz_buffered_drbg_*` functions. Its 1-KiB byte cache amortizes BLAKE3 setup;
requests of 1 KiB or more still use direct bulk generation. The context is
1,080 bytes on the supported ABIs, versus 40 bytes for the unchanged
`randomz_drbg`. To use it with a sampler, provide a `randomz_fill_fn` adapter
that calls `randomz_buffered_drbg_fill(context, out, count)`. The Zig/C CLI
uses this buffered API; Rust's `Drbg` uses the same private cache automatically.

Prefetching never advances the logical byte position. Both APIs export only
the key and the consumed-byte cursor, so existing continuation states and
cross-language replay remain identical. Use the buffered setters for seeking
or rekeying; do not modify the nested unbuffered state directly. Treat the
cache as sensitive, do not serialize it, and call
`randomz_buffered_drbg_zeroize` before releasing its storage. Rust wipes its
key and cached bytes on drop. Neither implementation starts a worker thread.

## Development

A dev shell with LuaJIT and the test tooling is provided:

```sh
direnv allow      # or: nix develop
./test            # FAST mode (quick, quiet on success)
FAST= ./test      # full statistical run
./stats           # separate, deeper sanity analysis of all four command families
nix flake check   # hermetic CI check (runs all 26 suites, but FORCES FAST=1 --
                   # kernel_jit_diff's 60000-iteration deep JIT differential
                   # is deep-mode-only by design and is SKIPPED here, not run;
                   # run `FAST= ./test` locally for the full non-FAST suite)
```

`./test` runs every suite under `tests/` (official BLAKE3 vectors, an independent
Zig DRBG reference check, the same 80-check Bash CLI contract against all four
command families, a 68-output byte-exact four-way help/chart contract, the
independent LuaJIT-vs-Zig/Rust/Lean exact frontend matrices, Rust
mutation/downstream-library controls, a C-compiled public-ABI conformance
test, Lean trust-zero elaboration/frozen vectors/proof axiom audits, isolated
Zig-package reconstruction, 11-target Zig cross-compilation
(including Windows ARM64), Wine-executed Windows x86_64 parity, kernel unit
tests, golden vectors, the `bc` sweep, the all-directions continuation
matrix, and the deep-mode-only JIT differential).
Set `RANDOM_TEST_CLI` to
run `tests/random_test` or `tests/drbg_test` against another compatible binary.
The suites are hermetic and concurrency-safe.
Cold `./test` and Nix runs are dominated by ReleaseFast compilation and the
multi-target artifact gates, not by the pure arithmetic checks themselves.

`./stats` is intentionally separate from the correctness suite. It streams raw
bytes and distribution samples without writing them to disk, checks obvious
bias/shape failures, and first proves its thresholds reject deliberately bad
generators. Use `./stats --lua`, `./stats --c`, `./stats --rust`, `./stats --lean`, or
`./stats --cli PATH`; `FAST=1`
reduces sample sizes. A pass is a statistical smoke test, not a cryptographic
security certification. The sensitivity set rejects seven deliberately bad
generators: an all-zero byte stream plus constant uniform, normal,
exponential, Poisson, log-normal, and beta samples.

`./bm` compares release-built LuaJIT, Zig/C, Rust, and Lean command payloads
over raw, encoded, uniform, and every nonlinear distribution. Before timing,
it streams every seeded workload through SHA-256 and requires matching digests
across all four packaged CLIs and the unwrapped Rust payload; generated bytes
are never written to disk. Rust timing bypasses only the Nix
Bash wrapper that makes installed `--test` self-contained, so wrapper startup
is not misreported as core computation. Hyperfine runs with `--shell=none`, so
no shell participates in a measured invocation. The full suite emits 8 MiB or
20,000 samples per process, amortizing the remaining loader and CLI startup;
this is deliberately a direct-process throughput benchmark rather than a
single-draw latency benchmark. Measurements, timing-surface identity, exact
executable hashes, and the tool versions visible to the harness append to
`benchmarks/<machine-id>.ndjson`. Prior results on the same machine, argument
set, and timing surface provide a two-sided ±15% review threshold: regressions
are loud, and surprising speedups are flagged in case work disappeared. Use
`--quick` for a short run or `--check` for only the cross-implementation proof.
The Lean row measures the independent compiled Lean implementation. Its native
code handles only the approved byte/I/O boundary; timed DRBG, arithmetic, and
distribution work is Lean-owned.

`nix develop -c ./bm --simd` runs the separate x86_64 Zig/Rust fixed-point AVX2
experiments. Add `--check` to run their exact-pair controls and cross-language
SHA-256 comparison without timings. The runner builds every module in release
mode, records wall/CPU samples in `benchmarks/fixed-simd.ndjson` (override with
`BM_SIMD_RESULTS_FILE`), and retains compiler artifacts under `$TMPDIR` for
inspection. These host-native prototypes are not linked into the shipped
libraries or CLIs. Results and integration limits are recorded in the
[throughput report](docs/normalized-throughput-2026-09-06.md#fixed-point-simd-experiments).

Lean CLI parity is currently executed on x86_64 Linux. The repository's
multi-architecture contract is independently measured by the established
LuaJIT/Zig/Rust matrix; native Lean digest legs for aarch64 Linux/macOS and a
supported Windows Lean toolchain remain tracked in `PLAN.md` rather than being
claimed from source inspection alone.

The Rust compile-time coefficient change was measured before and after on an
AMD Ryzen Threadripper 3990X, using the quick suite's 5,000-sample batches and
CPU time (three measured runs after one warmup):

| Distribution | Rust before | Rust after | Improvement | Rust after vs. Zig |
|---|---:|---:|---:|---:|
| Normal | 30.92 ms | 19.00 ms | 38.6% | 1.14x |
| Exponential | 21.76 ms | 14.72 ms | 32.3% | 1.30x |
| Poisson | 77.51 ms | 39.16 ms | 49.5% | 0.96x |
| Log-normal | 43.67 ms | 26.09 ms | 40.3% | 1.27x |
| Beta | 77.70 ms | 52.05 ms | 33.0% | 1.04x |

Raw, encoded, and uniform control workloads changed by -2.7% to +4.4%, which
supports attributing the nonlinear gains to removal of runtime coefficient
division rather than unrelated machine noise or missing work. Every measured
payload remained byte-identical across LuaJIT, Zig/C, the packaged Rust CLI,
and the unwrapped Rust executable.

## Layout

```
bin/random          the program (LuaJIT)
bin/nrandom         -> random   (normalized mode)
bin/drandom         -> random   (deterministic mode)
lib/fixed.lua       integer-only soft-float kernel (see Determinism above)
lib/distribution_charts.lua generated embedded PNG/Sixel/Braille help charts
lib/distribution_view.lua runtime parameter-aware curve/raster oracle
src/fixed.zig       independent Zig port of the fixed-point kernel
src/randomz.zig     pure RNG/distribution core and exported C ABI
src/randomz_cli.c   C CLI; accesses the Zig core only through randomz.h
src/distribution_view.c C-side UTF-8/Kitty/Sixel runtime rasterizer
tools/generate_distribution_charts.lua deterministic shared chart generator
include/randomz.h   public caller-owned-state C API
rust/randomr/       importable pure-core Rust library plus isolated entropy module
rust/randomr-cli/   Rust I/O, argument parsing, formatting, and chart frontend
tests/random_test   CLI behavior + statistical distribution suite (bash)
tests/randomz_test  shared later-frontend contract + exact LuaJIT differential matrix
tests/randomr_test  Rust architecture, shared-contract, and two-oracle gate
tests/randomr_mutation_test  proves five Rust acceptance controls can turn red
tests/randomr_bsd_targets  Rust 1.97.1 distributed BSD-target cross-link gate
tests/randomz_cross_compile_test  Linux/macOS/Windows x86_64/aarch64 build gate
stats               standalone raw/distribution statistical sanity analysis
bm                  three-implementation release benchmark and parity preflight
benchmarks/         per-machine append-only NDJSON benchmark history
tests/fixed_test    unit tests for lib/fixed.lua (bash)
tests/golden_test   verifies committed golden vectors still reproduce
tests/kernel_bc_sweep sweeps the kernel against `bc -l` as an independent oracle
tests/kernel_jit_diff JIT-vs-interpreter differential control (deep mode only)
crossarch           runs the cross-architecture differential (not part of ./test)
tests/cross_arch_diff  cross-arch/libc differential + its sensitivity controls
tests/cross_arch_decimal.lua  payload: parse/tostring/int paths across platforms
tests/cross_arch_controls.lua positive controls that MUST diverge
tests/bless-goldens run deliberately to regenerate golden vectors; never from ./test
tests/golden/       committed golden vectors (integer.txt, dist.txt)
alternates/         earlier reference implementations (nrandombash, nrandomlua)
flake.nix           dev shell, package, and CI check
test                test runner
```

The `alternates/` directory keeps earlier single-distribution implementations
(`nrandombash`, an awk/bash normal generator; `nrandomlua`, a plain-Lua one) for
lineage and benchmarking. They are not installed.

## License

MIT © Peter Marreck
