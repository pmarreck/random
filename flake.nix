{
  description = "random — a unified CLI random number generator in LuaJIT (uniform/normal/exponential/poisson/log-normal/beta; true + deterministic; stdin ops; multiple output formats)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # LuaJIT/LuaJIT#1499 (https://github.com/LuaJIT/LuaJIT/issues/1499):
        # nixpkgs-unstable's own pkgs.luajit still pins a pre-fix commit
        # (fbb36bb6, reporting "LuaJIT 2.1.1774638290"), which is why
        # lib/fixed.lua carries jit.off(div_signed)/jit.off(M.norm) --
        # ~5.7x slower on the soft-float distributions, measured via
        # hyperfine (see lib/fixed.lua's own doc comments). Override just
        # `version`/`src` on top of nixpkgs' existing luajit derivation (no
        # patches to carry forward -- confirmed via `nix eval
        # nixpkgs#luajit.patches`, empty list -- so every other build
        # attribute nixpkgs already tuned stays exactly as-is) so this
        # flake's own build gets the fix NOW, without waiting for nixpkgs
        # to catch up.
        #
        # This does NOT let the runtime version gate
        # (NEEDS_1499_MITIGATION, computed from `jit.version` at
        # lib/fixed.lua load time) go away: a user running bin/random
        # against their OWN system LuaJIT (outside this flake's package
        # output) may still be on a pre-fix build, so the mitigation stays
        # conditional on the ACTUAL running interpreter's version, not on
        # what this flake happens to pin.
        #
        # DROP THIS OVERRIDE once nixpkgs-unstable's own pkgs.luajit picks
        # up a post-#1499-fix commit -- see PLAN.md.
        #
        # NOTE on the exact commit pinned here, empirically determined,
        # NOT the bare fix commit's own hash -- see docs/luajit-1499-pin-
        # investigation.md for the full investigation, including two
        # SEPARATE LuaJIT bugs this pin exposed in bin/random's PCG32 code
        # and how they were isolated and fixed. Short version: Mike Pall's
        # actual #1499 fix is commit 5ed524c09fec64bed46b4bf74fa03be9083b0963
        # ("Don't fold -a / -b for unsigned operands"), but it lives on
        # LuaJIT's `master` branch, whose Makefile reports MAJVER=2
        # MINVER=0 -- a bare build of it reports itself as
        # "LuaJIT 2.0.1785605975", which `needs_1499_mitigation`'s
        # "2%.1%.(%d+)" pattern does not match at all, so the fail-safe
        # branch would keep the mitigation ON regardless of the roll
        # number. `28084004ee68d576f3f0c9ea61ea448fe3e10f07` ("Merge
        # branch 'master' into v2.1") is the commit that actually merges
        # 5ed524c's fix into the `v2.1` branch -- confirmed an ancestor-
        # inclusive merge via `git merge-base --is-ancestor`, and its
        # Makefile reports MAJVER=2 MINVER=1, matching the "2.1.x" format
        # every consumer of this project (and LUAJIT_1499_FIXED_IN)
        # expects. Its roll number, 1785606157, is exactly what
        # lib/fixed.lua's LUAJIT_1499_FIXED_IN already used -- no change
        # needed there.
        # Factored into a function (rather than a one-off overrideAttrs) purely
        # so the cross-architecture toolchains below can apply the IDENTICAL
        # pin. If the musl and aarch64 interpreters were built from a different
        # LuaJIT revision than the native one, a digest mismatch in
        # tests/cross_arch_diff could not distinguish "the arithmetic diverges
        # across architectures" (the thing under test) from "these are
        # different LuaJIT versions" (an uncontrolled variable).
        pinLuajit = lj: lj.overrideAttrs (old: {
          version = "2.1.1785606157";
          src = pkgs.fetchFromGitHub {
            owner = "LuaJIT";
            repo = "LuaJIT";
            rev = "28084004ee68d576f3f0c9ea61ea448fe3e10f07";
            hash = "sha256-S0D5YMHDFHUpct8H4U58zFHhAAsnPRR1jUR6JmAIfdg=";
          };
        });

        luajitFixed = pinLuajit pkgs.luajit;

        # --- Cross-architecture differential toolchains ---------------------
        # README's headline claim is that seeded streams are bit-identical
        # across architectures. Until tests/cross_arch_diff existed that was an
        # ARGUMENT (the kernel is integer-only, and integer arithmetic is fully
        # pinned by the language) rather than EVIDENCE -- no non-x86_64 run had
        # ever been compared. These are the exact interpreters that control
        # compares. Two variables move, one at a time:
        #   luajit-x86_64-glibc  baseline
        #   luajit-x86_64-musl   libc differs, architecture held fixed
        #   luajit-aarch64-glibc architecture differs, libc family held fixed
        # qemu-aarch64 runs the last one in user-mode emulation. Emulation is a
        # real caveat and is stated as one in the runner's output -- but it does
        # faithfully reproduce the architecture-visible semantics that matter
        # here: the float->int saturation control in cross_arch_controls.lua
        # detects the genuine x86_64/aarch64 difference through it.
        crossSupported = system == "x86_64-linux";
        crossToolchains = pkgs.runCommand "random-cross-toolchains" { } ''
          mkdir -p $out/bin
          ln -s ${luajitFixed}/bin/luajit $out/bin/luajit-x86_64-glibc
          ln -s ${pinLuajit pkgs.pkgsMusl.luajit}/bin/luajit $out/bin/luajit-x86_64-musl
          ln -s ${pinLuajit pkgs.pkgsCross.aarch64-multiplatform.luajit}/bin/luajit \
                $out/bin/luajit-aarch64-glibc
          ln -s ${pkgs.qemu-user}/bin/qemu-aarch64 $out/bin/qemu-aarch64
        '';

        # LuaJIT is the only runtime dependency (ffi + bit are built in).
        runtimeTools = [ luajitFixed ];
        # External tools the executable shells out to / the test suite needs.
        testTools = with pkgs; [ bashInteractive coreutils gnugrep gawk bc xxd ];

        random = pkgs.stdenv.mkDerivation {
          pname = "random";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          buildInputs = runtimeTools;
          dontBuild = true;
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin $out/lib $out/share/random/tests
            cp bin/random $out/bin/random
            # bin/random resolves '../lib/?.lua' relative to itself -- without
            # this, the packaged binary can find lib/fixed.lua only inside the
            # build sandbox, not from $out/bin.
            cp lib/*.lua $out/lib/
            cp tests/random_test $out/share/random/tests/random_test
            chmod +x $out/bin/random $out/share/random/tests/random_test
            # Mode-by-invocation-name: nrandom => normalized, drandom => deterministic
            ln -s random $out/bin/nrandom
            ln -s random $out/bin/drandom
            # Resolve '#!/usr/bin/env luajit' to the store luajit
            patchShebangs $out/bin/random
            runHook postInstall
          '';
          meta = with pkgs.lib; {
            description = "Unified CLI random number generator (LuaJIT)";
            license = licenses.mit;
            platforms = platforms.unix;
            mainProgram = "random";
          };
        };
      in {
        # The conditional attribute is merged INSIDE `packages`, not by `//`-ing
        # a second `{ packages.crossToolchains = ...; }` onto the outputs set.
        # `//` is a SHALLOW merge, so that form silently replaced the whole
        # `packages` attribute -- default, random and luajitPinned all vanished
        # and only crossToolchains survived. `nix flake check` did not catch it
        # (it exercised `checks.*`, which was untouched); Mechatron Prime did,
        # with "target failed: packages.x86_64-linux.default".
        packages = {
          default = random;
          random = random;

          # Exposed so a machine of ANY architecture can build the exact
          # interpreter tests/cross_arch_diff pins, without also needing the
          # cross-compilation machinery. That is what lets the native
          # aarch64-darwin leg of the cross-architecture evidence be gathered on
          # real hardware rather than under emulation -- with LuaJIT source held
          # constant, so architecture and libc remain the only variables.
          luajitPinned = luajitFixed;
        # `nixpkgs.lib`, NOT `pkgs.lib`: deciding this attrset's NAMES must not
        # force `pkgs`. eachDefaultSystem still enumerates x86_64-darwin, which
        # nixpkgs 26.11 has dropped -- forcing `pkgs` for that system throws at
        # evaluation time and takes the whole flake down, including on Linux.
        } // nixpkgs.lib.optionalAttrs crossSupported {
          # Only meaningful on x86_64-linux: pkgsCross/pkgsMusl and qemu-user are
          # what make the aarch64 and musl legs buildable from this host at all.
          crossToolchains = crossToolchains;
        };

        # Hermetic CI check: runs the FULL suite runner (./test), not just
        # tests/random_test, so fixed_test/golden_test/kernel_bc_sweep are
        # actually exercised here too, not just the CLI-behavior suite.
        checks.random-test = pkgs.runCommand "random-test"
          { nativeBuildInputs = runtimeTools ++ testTools; } ''
            cp -r ${./.} work
            chmod -R u+w work
            cd work
            # The Nix sandbox has no /usr/bin/env, so resolve shebangs in both the
            # program (bin/) and the test scripts (tests/) — `random --test` execs the
            # latter via its #!/usr/bin/env bash shebang.
            patchShebangs bin tests
            export HOME="$TMPDIR"
            export PATH="$PWD/bin:$PATH"
            # ./test sets RANDOM_TEST_FILE itself; FAST=1 keeps this hermetic
            # check fast (kernel_jit_diff is deep-mode-only by design — see
            # its own header comment).
            FAST=1 bash ./test
            touch $out
          '';

        devShells.default = pkgs.mkShell {
          packages = runtimeTools ++ testTools;
        };
      });
}
