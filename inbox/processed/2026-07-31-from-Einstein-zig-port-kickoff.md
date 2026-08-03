# Port `random` to Zig 0.16 — C FFI + `randomz` CLI, keeping the existing test suite

**From:** Einstein (orchestrator, ~/Code)
**Date:** 2026-07-31 14:10 EDT
**Requested by:** Peter, directly.

## Why now

`random` has become useful enough — **especially for deterministic fuzzing** —
to deserve a fast, embeddable implementation. The fleet is standardising fuzzing
(`./fuzz`), and a seeded, reproducible RNG callable at high speed from any Zig
project is the missing primitive. Today it is a 940-line LuaJIT script: fine as
a CLI, not something a fuzz harness can call in a hot loop.

## The mandate

Port to **Zig 0.16** *inside this existing project* (`~/Code/random`), following
the fleet's hexagonal pattern:

```
any consumer ──► C FFI (include/randomz.h) ──► Zig core (src/, pure, no I/O)
                                                     ▲
                              C CLI `randomz` ───────┘  (dogfoods the FFI)
```

- **Zig core is pure — no I/O.** A fuzz harness must be able to call it in-process.
- **CLI is named `randomz`**, written in **C**, calling through the header.
  C is deliberate: it *cannot* `@import` a Zig module, so bypassing the FFI is
  inexpressible rather than merely discouraged.
- **`drandomz` and `nrandomz` are symlinks to `randomz`** — same argv[0]-dispatch
  pattern `bin/drandom`/`bin/nrandom` already use today. Preserve that behaviour.

## Reuse the test suite — it is the whole point

`tests/random_test` is **983 lines** and already encodes the expected behaviour
of the LuaJIT implementation. **Do not rewrite it from scratch.** It becomes a
**differential oracle**:

- Keep the existing LuaJIT `bin/random` in place during the port.
- Run the same suite against both implementations and require **identical
  output** for identical `--seed` values.
- That is a genuine MFIC differential control: the oracle is code you did not
  write for this port, so it cannot rubber-stamp your work.

Where behaviour *must* differ, say so explicitly and get Peter's sign-off — do
not silently "improve" semantics mid-port.

## CLI surface to preserve

From `bin/random --help`, at minimum:

`--about --alpha --base --beta --beta-param --binaryoutput --choose --count
--delim --delimiter --deterministic --exponential --help --hex --log-normal
--mean --normalized --poisson --seed --shuffle`

Per the fleet CLI conventions: `-h/--help`, `--about` (one line: name, version,
platform, arch), `--json` output where structure is implied, `-`/`@stdin` and
`-`/`@stdout` for paths, metadata to stderr, `--no-color`/`--no-ansi`/`--simple`,
later args override earlier ones, and args parseable in any order.

## Determinism is the headline feature

Since the driving use case is reproducible fuzzing:

- `--seed` must give **bit-identical** streams across runs, machines, OSes, and
  architectures. Test that as an explicit invariant, not an assumption.
- Pick and **document the exact algorithm** (name + parameters) so a stream can
  be reproduced years later — a PRNG whose algorithm is undocumented is not
  reproducible, it is merely repeatable today.
- Beware endianness and any float path: **IEEE-754 is non-deterministic in ways
  that matter here** (non-associativity, platform-divergent float→int
  conversion). Where a distribution needs floats, pin the exact operation order
  and cover it with cross-platform tests. See the shared memory *"Prefer
  deterministic integer and rational arithmetic."*
- No time-based or entropy-based seeding on the deterministic path.

## Non-negotiables

- **TDD with a real red phase.** Failing test first, watch it fail, then minimal
  code. The differential suite above makes this unusually easy — run it against
  Zig before the feature exists and watch it fail honestly.
- **Tests build ReleaseSafe, shipped artifact ReleaseFast.** Fleet floor since
  2026-07-01, adopted fleet-wide 2026-07-29. A ReleaseFast suite compiles out the
  safety checks and cannot observe UB — it hid three real crashers in `rarz` and
  a `u32` underflow in `tiffz` that produced the right answer by accident.
- **Flakes only see git-tracked files.** `git add` new sources before wondering
  why `nix build` cannot find them. This has bitten the fleet repeatedly this
  week, including in `rawz` an hour ago.
- **Zig 0.16 API:** read `ZIG_RECENT_API_CHANGES.md` **before** writing build
  code — it is ahead of the scaffold templates. Notably `linkLibrary` lives on
  the **module**, not on `Build.Step.Compile`.
- **Never commit red.**

## CI

Wire **Mechatron Prime** via the `mechatron-ci` skill once the flake outputs are
real and locally verified — `.mechatron-prime/targets` listing the exact check
attributes, plus the canonical dynamic badge. Do not add Garnix; it is
permanently retired.

## Sequencing suggestion

1. Scaffold the Zig core + FFI + `randomz` C CLI alongside the existing LuaJIT
   script (do not delete it yet).
2. Port the core generator; get the existing suite passing **differentially**.
3. Port the distributions (normal, poisson, exponential, beta, log-normal) one
   at a time, each proven against the LuaJIT oracle.
4. `randomz` + symlinks; CLI tests in `tests/cli/`.
5. Only once everything is green and Peter agrees: decide whether the LuaJIT
   implementation is retired or kept as a permanent oracle. **Recommend keeping
   it** — a second independent implementation is a standing differential control.

Report to `~/Code/inbox/`. Keep `PLAN.md` current; `dirtree note` new files.

— Einstein
