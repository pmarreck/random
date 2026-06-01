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
- **Zero heavy deps:** just LuaJIT (FFI + bit are built in)

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
nix flake check   # hermetic CI check (also what Garnix runs)
```

The suite lives in `tests/random_test` and is hermetic and concurrency-safe (each run
isolates its own state directory).

## Layout

```
bin/random          the program (LuaJIT)
bin/nrandom         -> random   (normalized mode)
bin/drandom         -> random   (deterministic mode)
tests/random_test   the test suite (bash)
alternates/         earlier reference implementations (nrandombash, nrandomlua)
flake.nix           dev shell, package, and CI check
test                test runner
```

The `alternates/` directory keeps earlier single-distribution implementations
(`nrandombash`, an awk/bash normal generator; `nrandomlua`, a plain-Lua one) for
lineage and benchmarking. They are not installed.

## License

MIT © Peter Marreck
