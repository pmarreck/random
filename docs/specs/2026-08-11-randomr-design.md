# `randomr` Rust port design

Status: implemented and gated on 2026-08-11. Development began with persisted
failing controls; the completed library, CLI, three-way differential,
cross-target builds, native ARM64 workflows, and statistical/package gates are
green.

## Objective

Add a third, independent implementation named `randomr`. Given the same seed
and arguments, it must emit exactly the same bytes as both the LuaJIT `random`
oracle and the Zig-core/C-CLI `randomz` implementation for every deterministic
operation: raw BLAKE3 output, integer ranges, normal, exponential, Poisson,
log-normal, beta, choose, shuffle, weighted choice, decimal formatting, binary
encodings, and distribution curves.

True-random output is intentionally not reproducible. Its contract is source
selection, exact filling, and fail-closed error behavior.

## Workspace and dependency direction

The repository root is a Cargo workspace containing two packages:

```text
rust/randomr/       package randomr; reusable library crate
rust/randomr-cli/   package randomr-cli; binary target randomr
```

`randomr-cli` depends on `randomr` by a normal path dependency. `randomr`
cannot depend on `randomr-cli`, execute another frontend, use the C ABI, or
load Lua/Zig output. This makes the Rust implementation a third producer, not
a wrapper around either oracle.

The library is the natural import surface for Rust users:

```toml
[dependencies]
randomr = { path = "../random/rust/randomr" }
```

The root lockfile pins the official `blake3` crate and the low-level
`getrandom` crate. No general-purpose random/distribution crate is used: its
sampling and float behavior would be a second, incompatible wire contract.

## Purity boundary

The library is divided into deterministic modules and one isolated entropy
module.

Deterministic modules contain no filesystem, terminal, environment, clock,
network, process, locale, or platform-I/O access and no mutable global state:

- `fixed`: the exact integer-only `(m, e)` arithmetic kernel;
- `drbg`: BLAKE3 KDF plus keyed empty-message XOF and explicit byte position;
- `distribution`: range rejection and every sampler;
- `curve`: protocol-neutral distribution-curve samples.

All operations are functions of explicit arguments and caller-owned state.
`Drbg` mutation is only an ergonomic state transition over `(key, position)`;
copying the value copies the future stream, and there is no ambient state.

`entropy` is the sole library exception. The CLI hands it an explicit request:

- the system-preferred CSPRNG;
- the system source with nonblocking semantics where supported; or
- an explicit device/path supplied by the caller.

The module fills a caller buffer exactly or returns an error. It never falls
back to a deterministic generator, accepts a partial read as success, or hides
a policy denial. Distribution functions do not select or open entropy sources;
they consume a `ByteSource` supplied by the caller. Keeping the adapter in the
library lets another Rust program request the same vetted entropy behavior
without importing CLI concerns.

The CLI owns everything else impure or representational: argv and invocation
aliases, environment lookup, stdin operations, stdout/stderr, terminal
capability detection, chart framing, decimal parsing/formatting, seed spelling,
range grammar, hex/base64, and user-facing errors.

## Public library contract

The stable initial API exposes:

- `Fixed { m: i64, e: i32 }` plus checked integer arithmetic constructors and
  operations needed to supply distribution parameters;
- `Drbg::new(&[u8; 32])`, state import/export, position, fill, `u32`, `u64`,
  and zeroization;
- `ByteSource::fill_exact(&mut self, &mut [u8])`;
- one-shot range, uniform, normal, exponential, Poisson, log-normal, and beta
  functions generic over `ByteSource`;
- protocol-neutral curve sampling with normalized integer heights and fixed
  x-bounds;
- typed errors with no panics for caller-reachable invalid input.

Seed material is exactly 32 bytes. CLI decimal/hex seed parsing remains a
frontend convenience. Byte position is capped at 2^53, matching the two
existing state representations. Draw assembly is big-endian and every
sampler's byte-consumption order is part of the compatibility contract.

## CLI contract

The binary is `randomr`; installed aliases are `nrandomr` and `drandomr`.
Their behavior matches `randomz`, except that the deterministic environment
variable is independently namespaced as `DRANDOMR_SEED`. `DRANDOM_SEED` and
`DRANDOMZ_SEED` must be inert for the Rust frontend. Chart renderer selection
continues to use the deliberately shared `RANDOMZ_CHART_TYPE` variable because
that variable describes a protocol choice, not generator state.

The complete existing command surface is required. There is no reduced
"initial Rust CLI" accepted as complete.

## Red-first controls and oracle independence

The following controls are added before production Rust code and are observed
failing because the workspace/artifact does not yet exist:

1. `randomr_architecture_test` requires the two-package dependency direction,
   rejects forbidden I/O symbols outside `entropy`, builds library docs/tests,
   and verifies a downstream fixture can import `randomr` without the CLI.
2. `randomr_test` requires a freshly built release binary, runs the shared CLI
   suite with the Rust seed namespace, and runs exact deterministic matrices
   against both existing executables.

The final control stack deliberately uses different truth sources:

- upstream BLAKE3 vectors judge the cryptographic primitive;
- LuaJIT and Zig/C independently judge Rust deterministic behavior;
- pairwise comparison first verifies the two oracles still agree, then
  requires Rust to agree with both, so a stale/broken oracle is named rather
  than silently outvoted;
- metamorphic DRBG chunk/seek/replay and range-equivalence controls do not
  depend on hand-authored expected values;
- Rust unit tests exercise library errors and boundaries directly;
- the shared Bash suite exercises the public CLI rather than a Rust test-only
  driver;
- `./stats` remains a gross-bias/shape sanity check and never claims to certify
  cryptographic security;
- mutation probes must demonstrate that the candidate selector, second-oracle
  comparison, deterministic-core purity boundary, nonlinear kernels, and
  entropy failures can each make the gate red.

No test is allowed to regenerate its expected values from `randomr` itself.

## Build and packaging

Cargo builds use the checked-in lockfile. Nix vendors the locked dependencies,
builds the library and release CLI hermetically, installs `randomr` plus its two
aliases, and exposes the library source/API for ordinary Rust path or registry
consumption. The root `./build` copies all four frontend families to the stable
build output.

The flake publishes the Rust library independently as `random-rust-lib`. It is
a CLI-free source overlay, not a precompiled `.rlib`: downstream Nix builds use
the package's `cargoPath` passthru as a Cargo path dependency and compile it
inside their own vendored dependency graph. Library manifests therefore use
compatible semver ranges while this repository's lockfile pins the exact
release resolution. The package gate compiles a standalone consumer against
the same `libc` and `zeroize` versions used by `validate_gui`; neither the CLI
package nor a Rust toolchain enters the library output's runtime closure.

Required compile evidence covers native Linux, Linux aarch64, Windows
x86_64/aarch64, FreeBSD x86_64, and NetBSD x86_64. Rust 1.97.1 does not publish
standard-library artifacts for OpenBSD or BSD ARM64, so those combinations are
named toolchain gaps rather than passing skips. At least one non-x86_64 runtime
must join the existing cross-architecture payload before the portability claim
is extended to Rust.

Both Zig and Rust can produce WebAssembly. Rust's deterministic library must
remain compatible with `wasm32-wasip1`, but the initial port does not replace
or duplicate the shipped Zig reactor by assumption. After native parity, build
equivalent Zig and Rust WASI artifacts and measure at least raw size, compressed
size, instantiation cost, raw DRBG throughput, and representative nonlinear
distribution throughput under the same runtime. That evidence decides whether
the project ships Zig WASM, Rust WASM, or both; language preference does not.
The initial port enforces the library-compatibility half with a no-default-
features `wasm32-wasip1` compile gate; it deliberately does not count that as a
shippable equivalent CLI/reactor artifact.

## Completion gate

The completed port passed the canonical suite, Rust unit/doc/downstream tests,
pairwise three-frontend differential, statistical suite, package smoke,
cross-target builds, and cross-architecture runtime payload from a clean
checkout. README/help/about may therefore claim all three implementations.
