# random

A unified command-line random number generator, written in [LuaJIT](https://luajit.org/).
One small program that covers the cases you usually reach for several tools to do:
multiple statistical distributions, both **true** randomness (`/dev/urandom`) and
**reproducible** randomness (seeded PCG32), stdin operations (choose/shuffle/weighted),
and several output encodings.

It ships as three commands — `random`, `nrandom`, `drandom` — that are the same binary;
the invocation name selects the mode (`nrandom` ⇒ normalized, `drandom` ⇒ deterministic).

## Features

- **Distributions:** uniform (default), normal (Box-Muller), exponential, Poisson, log-normal, beta
- **Two sources:** true random from `/dev/urandom`, or deterministic PCG32 (`-d`/`--seed`)
- **Stdin ops:** `--choose` one item, `--shuffle` all items, `--weighted` (`value:weight`)
- **Output formats:** decimal, `--hex`, `--base64`, raw `--binaryoutput`
- **Reproducible sessions:** deterministic state persists per session so sequences continue across calls
- **Reproducible across platforms:** seeded streams are bit-identical across machines, operating systems and CPU architectures, because all math runs on an integer-only kernel instead of the platform's libm — see [Determinism](#determinism) below
- **Zero heavy deps:** just LuaJIT (FFI + bit are built in)

### Determinism

Seeded streams are **bit-identical across runs, machines, operating systems and
CPU architectures**. All math runs on an integer-only software float
(`lib/fixed.lua`) rather than the platform's libm, because libm transcendentals
are not portable: IEEE-754 pins down `+ - * / sqrt` and says nothing about
`log`, `cos` or `exp`. Measured glibc vs musl over this program's actual input
domain, `log` differs on 0.006% of inputs, `cos` on 3.06%, and `exp` on 8.85% —
which meant roughly 3% of seeded "normal" values differed between two builds of
the same source at the same seed.

The algorithm is PCG32 (XSH-RR 64/32), multiplier `6364136223846793005`,
increment `1442695040888963407`, seeded by `state = 0; advance; state += seed;
advance`. A stream is reproducible from that description alone.

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

Converting to the integer kernel deliberately changed seeded output **once**:
values from `--normalized`, `--exponential`, `--poisson`, `--log-normal` and
`--beta` at a given seed differ from pre-conversion runs of this program (the
old float path was never cross-platform-reproducible to begin with, so there
was no compatibility guarantee to preserve). Also, fractional range bounds are
no longer accepted — `random 1.5 6.5` is now an error, not a silently-truncated
range.

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
random --hex -c 5                   # 5 hex values
printf 'a\nb\nc\n' | random --choose
printf 'rare:1,common:10' | random --weighted --delimiter ','
```

Run `random -h` for the full option list.

### State persistence note

In deterministic mode, state is saved per session (keyed by `DRANDOM_CONTEXT`, defaulting
to the parent PID) so successive calls continue the sequence. Because pipes and `$(...)`
subshells change the parent PID, set a stable context in scripts:

```sh
export DRANDOM_CONTEXT=$$
```

State lives under `DRANDOM_STATE_HOME` (default `/tmp`).

## Install

### Nix (flake)

```sh
nix run github:pmarreck/random            # run without installing
nix profile install github:pmarreck/random
```

### Manual

Put `bin/` on your `PATH` (it contains `random` plus the `nrandom`/`drandom` symlinks).
Requires `luajit` on your `PATH`.

## Development

A dev shell with LuaJIT and the test tooling is provided:

```sh
direnv allow      # or: nix develop
./test            # FAST mode (quick, quiet on success)
FAST= ./test      # full statistical run
nix flake check   # hermetic CI check (runs all 6 suites, but FORCES FAST=1 --
                   # kernel_jit_diff's 60000-iteration deep JIT differential
                   # is deep-mode-only by design and is SKIPPED here, not run;
                   # run `FAST= ./test` locally for the full non-FAST suite)
```

`./test` runs every suite under `tests/` (CLI behavior, kernel unit tests, golden
vectors, the `bc` sweep, and the deep-mode-only JIT differential). Each suite is
hermetic and concurrency-safe — every run isolates its own state directory.

## Layout

```
bin/random          the program (LuaJIT)
bin/nrandom         -> random   (normalized mode)
bin/drandom         -> random   (deterministic mode)
lib/fixed.lua       integer-only soft-float kernel (see Determinism above)
tests/random_test   CLI behavior + statistical distribution suite (bash)
tests/fixed_test    unit tests for lib/fixed.lua (bash)
tests/golden_test   verifies committed golden vectors still reproduce
tests/kernel_bc_sweep sweeps the kernel against `bc -l` as an independent oracle
tests/kernel_jit_diff JIT-vs-interpreter differential control (deep mode only)
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
