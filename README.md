# random

[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Frandom.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)

A unified command-line random number generator with matching implementations:
the original [LuaJIT](https://luajit.org/) oracle and a Zig core exposed through
a public C ABI, driven by a C CLI that dogfoods that ABI.
One small program that covers the cases you usually reach for several tools to do:
multiple statistical distributions, both **true** randomness (the OS CSPRNG) and
**reproducible** randomness (a seeded BLAKE3 keyed XOF), stdin operations (choose/shuffle/weighted),
and several output encodings.

It ships two equivalent command families: `random`/`nrandom`/`drandom` use the
LuaJIT implementation, while `randomz`/`nrandomz`/`drandomz` use the C frontend
over the Zig library. The invocation name selects normalized or deterministic
mode in either family.

## Features

- **Distributions:** uniform (default), normal (Box-Muller), exponential, Poisson, log-normal, beta
- **Two sources:** the platform OS CSPRNG, or a deterministic BLAKE3 keyed XOF (`-d`/`--seed`)
- **Stdin ops:** `--choose` one item, `--shuffle` all items, `--weighted` (`value:weight`)
- **Output formats:** decimal, `--hex`, `--base64`, raw `--binaryoutput`
- **Visual distribution help:** append `--help` to an alternate-distribution
  flag for its shape; Kitty and Ghostty receive an embedded PNG via Kitty
  graphics, WezTerm receives Sixel, and other terminals receive Braille
- **Replayable invocations:** deterministic mode starts at stream position zero and never writes state to disk
- **Reproducible across platforms:** seeded streams are bit-identical across machines, operating systems and CPU architectures — verified on x86_64-glibc, x86_64-musl, aarch64-Linux and native aarch64-macOS — because all math runs on an integer-only kernel instead of the platform's libm — see [Determinism](#determinism) below
- **Embeddable core:** `librandomz.a` plus `randomz.h`; callers own DRBG state
  and provide entropy through a callback, so the Zig core performs no I/O
- **Small runtime surface:** LuaJIT for the oracle CLI; libc only for `randomz`

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
without a seed, the program obtains 32 bytes from the OS and prints a full
`0x`-prefixed seed to stderr so the invocation can be replayed. Compromise of
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
accepted — `random 1.5 6.5` is an error, not a silently-truncated range.

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
random 1 6                          # uniform in [1, 6]
random -n --mean 50 --stddev 10     # normal distribution
random -d --seed 42 -c 5            # 5 reproducible numbers
random --true-random -b -c 32       # force entropy even if DRANDOM_SEED is set
random --hex -c 5                   # 5 hex values
printf 'a\nb\nc\n' | random --choose
printf 'rare:1,common:10' | random --weighted --delimiter ','
```

Run `random -h` for the full option list.

Distribution-qualified help is order-independent: for example,
`random --normalized --help` and `random --help --normalized` show the normal
curve. The CLI sends its embedded PNG directly through the Kitty graphics
protocol without a temporary file in Kitty and Ghostty. WezTerm uses a
code-generated Sixel rendering of the same plot; tmux 3.4+ handles that DCS
protocol natively when built with Sixel support. Kitty graphics under tmux
requires `allow-passthrough` to be `on` or `all`; otherwise auto mode uses the
UTF-8 fallback. Set `RANDOMZ_CHART_TYPE=utf8|kitty|sixel` to override automatic
selection. `--utf8-graphics`, `--kitty`, and `--sixel` override the environment
for one distribution-help invocation; if repeated, the last renderer flag wins.

`--test` runs the shared Bash contract suite. Nix installations close over its
tool dependencies; manual Zig and Windows installations require Bash plus the
common Unix command-line tools used by the suite.

### Entropy and persistence

True-random mode uses `getrandom` on Linux, `getentropy` where available, and
`BCryptGenRandom` on Windows, with an exact-read `/dev/urandom` fallback on
Unix. Any short read or source error fails closed. `--random-source PATH`
selects an explicit byte source, chiefly for deterministic testing;
`--no-wait` requests Linux `GRND_NONBLOCK` behavior.

The CLIs never persist deterministic state. Reusing a seed restarts the same
stream; omitting it prints a replayable seed. The LuaJIT CLI uses
`DRANDOM_SEED`; the C/FFI CLI uses the separately namespaced `DRANDOMZ_SEED`.
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
nix run github:pmarreck/random            # run without installing
nix run github:pmarreck/random#randomz    # C CLI over the Zig FFI
nix profile install github:pmarreck/random
```

### Manual

For the LuaJIT oracle, put `bin/` on your `PATH`; it requires `luajit`. For the
C CLI and static library, run `zig build -Doptimize=ReleaseFast` and use
`zig-out/bin/randomz`, `zig-out/include/randomz.h`, and
`zig-out/lib/librandomz.a`. `nrandomz` and `drandomz` are installed aliases;
the Nix package installs them as symlinks.

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

## Development

A dev shell with LuaJIT and the test tooling is provided:

```sh
direnv allow      # or: nix develop
./test            # FAST mode (quick, quiet on success)
FAST= ./test      # full statistical run
./stats           # separate, deeper sanity analysis of both implementations
nix flake check   # hermetic CI check (runs all 13 suites, but FORCES FAST=1 --
                   # kernel_jit_diff's 60000-iteration deep JIT differential
                   # is deep-mode-only by design and is SKIPPED here, not run;
                   # run `FAST= ./test` locally for the full non-FAST suite)
```

`./test` runs every suite under `tests/` (official BLAKE3 vectors, an independent
Zig DRBG reference check, the same 75-check Bash CLI contract against both
executables, 108 exact LuaJIT-vs-C cases, a C-compiled public-ABI conformance
test, isolated Zig-package reconstruction, five-target cross-compilation
(including Windows ARM64), Wine-executed Windows x86_64 parity, kernel unit
tests, golden vectors, the `bc` sweep, and the deep-mode-only JIT differential).
Set `RANDOM_TEST_CLI` to
run `tests/random_test` or `tests/drbg_test` against another compatible binary.
The suites are hermetic and concurrency-safe.

`./stats` is intentionally separate from the correctness suite. It streams raw
bytes and distribution samples without writing them to disk, checks obvious
bias/shape failures, and first proves its thresholds reject deliberately bad
generators. Use `./stats --lua`, `./stats --c`, or `./stats --cli PATH`; `FAST=1`
reduces sample sizes. A pass is a statistical smoke test, not a cryptographic
security certification. The sensitivity set rejects seven deliberately bad
generators: an all-zero byte stream plus constant uniform, normal,
exponential, Poisson, log-normal, and beta samples.

## Layout

```
bin/random          the program (LuaJIT)
bin/nrandom         -> random   (normalized mode)
bin/drandom         -> random   (deterministic mode)
lib/fixed.lua       integer-only soft-float kernel (see Determinism above)
lib/distribution_charts.lua generated embedded PNG/Sixel/Braille help charts
src/fixed.zig       independent Zig port of the fixed-point kernel
src/randomz.zig     pure RNG/distribution core and exported C ABI
src/randomz_cli.c   C CLI; accesses the Zig core only through randomz.h
tools/generate_distribution_charts.lua deterministic shared chart generator
include/randomz.h   public caller-owned-state C API
tests/random_test   CLI behavior + statistical distribution suite (bash)
tests/randomz_test  shared C-CLI contract + exact LuaJIT differential matrix
tests/randomz_cross_compile_test  Linux/macOS/Windows x86_64/aarch64 build gate
stats               standalone raw/distribution statistical sanity analysis
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
