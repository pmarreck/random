{
  description = "Cross-platform-identical deterministic CSPRNG and OS-entropy random CLI with alternate distributions";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    bend-upstream = {
      url = "github:bendlang/bend/4ff8545f19b09b7d2b8ca2303668100eac8efd66";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    roc-upstream.url = "github:roc-lang/roc/1a4df199210309bbb6befb1322f7435361bd01e1?dir=src";
    performance-profiling.url = "github:pmarreck/performance_profiling/a04d62a441a5b9315e81f6277f57f7eddb9a57af";
  };

  outputs = { self, nixpkgs, flake-utils, bend-upstream, roc-upstream, performance-profiling }:
    # Enumerate the supported native systems explicitly. flake-utils' default
    # still includes x86_64-darwin, which nixpkgs 26.11 has dropped and this
    # project no longer promises; Windows remains a Zig/Rust cross target.
    flake-utils.lib.eachSystem [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        # Canonization changes a selector, not every implementation's source.
        # Explicit language consumers never depend on that selection file.
        implementationSource = pkgs.lib.fileset.toSource {
          root = ./.;
          fileset = pkgs.lib.fileset.difference ./. (pkgs.lib.fileset.unions [
            ./CANONICAL_IMPL ./PLAN.md ./.dirtree-state ./.mechatron-prime
          ]);
        };
        # The pinned shared engine has a hard-coded 30s child deadline. Expose
        # its existing process.run timeout argument, without forking its policy.
        # Remove this override when the pinned upstream admits, forwards and
        # records timeout_ms; keep the real-child behavioral regression control.
        performanceProfile = performance-profiling.packages.${system}.default.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [ ./nix/performance-profile-timeout.patch ];
        });
        # The v2.0.37 source tag's generated flake still packages v2.0.36.
        # Override only that stale archive selection, using the published
        # v2.0.37 asset digests. Remove when a selected upstream tag agrees
        # with its archive; tests/bend2_test checks the executable identity.
        bendArchive = {
          x86_64-linux = { target = "linux-x64"; sha256 = "84c32465a39bc9ac315eade23f470cb8db03153dc860f89564fcfec153c3e445"; };
          aarch64-linux = { target = "linux-arm64"; sha256 = "b65d452e5c68a4c486e353220d4298ba5d76f535db47109a7d76ffdf72efafb1"; };
          aarch64-darwin = { target = "darwin-arm64"; sha256 = "846d25ccf0c12d5d1e5e648c0b3ba4c8397fdb852812ac00ef8135998f8e194b"; };
        }.${system};
        bendToolchain = bend-upstream.packages.${system}.default.overrideAttrs (_: {
          version = "2.0.37";
          src = pkgs.fetchurl {
            url = "https://github.com/bendlang/bend/releases/download/v2.0.37/bend-2.0.37-${bendArchive.target}.tar.gz";
            inherit (bendArchive) sha256;
          };
        });
        bendProofKernel = pkgs.callPackage ./nix/bend2-proof-kernel.nix {
          upstream = bend-upstream.outPath;
        };
        bendBench = pkgs.callPackage ./nix/bend2-benchmarks.nix {
          inherit bendToolchain randomZigLib randomBendNative randomRocNative;
          upstream = bend-upstream.outPath;
        };
        bendSource = pkgs.lib.fileset.toSource {
          root = ./.;
          fileset = pkgs.lib.fileset.unions [ ./bend ./include/randomb.h ./LICENSE ];
        };
        bendCliSource = pkgs.lib.fileset.toSource {
          root = ./.;
          fileset = pkgs.lib.fileset.unions [ ./src ./include ./bend/build-native
            ./bend/cli-compat.h ./tests/random_test ./tests/cli_test_setup.sh
            ./tests/fixture-cleanup.sh ./LICENSE ];
        };
        randomBendLib = pkgs.stdenvNoCC.mkDerivation {
          pname = "random-bend2-lib-experimental";
          version = "0.4.0";
          src = bendSource;
          strictDeps = true;
          nativeBuildInputs = [ bendToolchain pkgs.time ];
          allowedReferences = [ ];
          BEND_NO_TELEMETRY = "1";
          buildPhase = ''
            runHook preBuild
            ${pkgs.time}/bin/time -o compiler-cost.json \
              -f '{"wall_seconds":%e,"peak_rss_kib":%M}' \
              bend bend/Core.bend -o core.mjs
            bend bend/Fixed.bend -o fixed.mjs
            bend bend/Draw.bend -o draw.mjs
            bend bend/ZigguratTables.bend -o tables.mjs
            bend bend/Sampler.bend -o sampler.mjs
            bend bend/Count.bend -o count.mjs
            bend bend/Decimal.bend -o decimal.mjs
            bend bend/Chart.bend -o chart.mjs
            bend bend/Library.bend -o index.mjs
            sha256sum bend/Core.bend bend/Fixed.bend bend/Draw.bend \
              bend/ZigguratTables.bend bend/Ziggurat.bend bend/Sampler.bend bend/Library.bend \
              bend/Count.bend bend/Geometric.bend bend/Decimal.bend bend/Chart.bend \
              bend/Batch.bend bend/Selection.bend > core-source.sha256
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out/lib/bend/random $out/lib/javascript/random \
              $out/share/licenses/random-bend2-lib $out/share/random-bend2-lib
            install -m644 bend/Core.bend bend/Fixed.bend bend/Draw.bend bend/ZigguratTables.bend \
              bend/Ziggurat.bend bend/Sampler.bend bend/Library.bend bend/LAWS.bend bend/PROOF.bend $out/lib/bend/random/
            install -m644 bend/Count.bend bend/Geometric.bend bend/Decimal.bend bend/Chart.bend \
              bend/Batch.bend bend/Selection.bend $out/lib/bend/random/
            install -m644 core.mjs fixed.mjs draw.mjs tables.mjs sampler.mjs count.mjs \
              decimal.mjs chart.mjs index.mjs $out/lib/javascript/random/
            install -m644 compiler-cost.json $out/share/random-bend2-lib/
            install -m644 core-source.sha256 $out/share/random-bend2-lib/
            install -m644 LICENSE $out/share/licenses/random-bend2-lib/LICENSE
            install -Dm644 ${bend-upstream.outPath}/LICENSE $out/share/licenses/random-bend2-lib/Bend-LICENSE
            runHook postInstall
          '';
          meta = {
            description = "Experimental independent Bend source and generated JavaScript facade; deterministic bytes and integer/nonlinear samplers";
            license = with pkgs.lib.licenses; [ mit asl20 ];
            platforms = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
          };
        };
        randomBendProbe = pkgs.stdenv.mkDerivation {
          pname = "random-bend2-probe-experimental";
          version = "0.4.0";
          src = implementationSource;
          strictDeps = true;
          nativeBuildInputs = [ bendToolchain pkgs.clang pkgs.time ];
          disallowedReferences = [ bendToolchain ];
          stripDebugList = [ ];
          stripAllList = [ "bin" ];
          BEND_NO_TELEMETRY = "1";
          buildPhase = ''
            runHook preBuild
            ${pkgs.time}/bin/time -o compiler-cost.json \
              -f '{"wall_seconds":%e,"peak_rss_kib":%M}' \
              bend bend/Probe.bend -o bend2-probe
            bend tests/fixtures/bend2-fixed-probe.bend -o bend2-fixed-probe
            bend tests/fixtures/bend2-sampler-probe.bend -o bend2-sampler-probe
            sha256sum bend/Core.bend bend/Fixed.bend bend/ProbeModel.bend bend/Probe.bend \
              bend/Draw.bend bend/ZigguratTables.bend bend/Ziggurat.bend bend/Sampler.bend \
              tests/fixtures/bend2-fixed-probe.bend tests/fixtures/bend2-sampler-probe.bend > probe-source.sha256
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin $out/share/random-bend2-probe
            install -m755 bend2-probe bend2-fixed-probe bend2-sampler-probe $out/bin/
            install -m644 compiler-cost.json $out/share/random-bend2-probe/
            install -m644 probe-source.sha256 $out/share/random-bend2-probe/
            install -Dm644 LICENSE $out/share/licenses/random-bend2-probe/LICENSE
            install -Dm644 ${bend-upstream.outPath}/LICENSE $out/share/licenses/random-bend2-probe/Bend-LICENSE
            runHook postInstall
          '';
          meta = {
            description = "Experimental optimized native Bend byte probe, not the production random CLI contract";
            license = with pkgs.lib.licenses; [ mit asl20 ];
            platforms = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
          };
        };
        randomBendNative = pkgs.clangStdenv.mkDerivation {
          pname = "random-bend2-ffi-experimental";
          version = "0.4.0";
          src = bendSource;
          strictDeps = true;
          nativeBuildInputs = [ bendToolchain ];
          disallowedReferences = [ bendToolchain randomBendLib ];
          RANDOM_BEND_COMPILER = "${bendToolchain}/bin/bend";
          BEND_NO_TELEMETRY = "1";
          buildPhase = ''
            runHook preBuild
            bash bend/build-native "$PWD/bend-lib-out" --library-only
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out/lib $out/include $out/share/licenses/random-bend2-ffi \
              $out/share/random-bend2-ffi
            install -m644 bend-lib-out/lib/librandomb.a $out/lib/
            install -m755 bend-lib-out/lib/librandomb${pkgs.stdenv.hostPlatform.extensions.sharedLibrary} $out/lib/
            install -m644 include/randomb.h $out/include/
            install -m644 bend-lib-out/share/random-bend2-ffi/native-source.sha256 $out/share/random-bend2-ffi/
            install -m644 LICENSE $out/share/licenses/random-bend2-ffi/LICENSE
            install -m644 ${bend-upstream.outPath}/LICENSE $out/share/licenses/random-bend2-ffi/Bend-LICENSE
            runHook postInstall
          '';
          meta = {
            description = "Experimental independent native Bend static/shared C ABI, without CLI or compiler runtime dependencies";
            license = with pkgs.lib.licenses; [ mit asl20 ];
            platforms = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
          };
        };
        randomBend = pkgs.clangStdenv.mkDerivation {
          pname = "random-bend2-experimental";
          version = "0.4.0";
          src = bendCliSource;
          strictDeps = true;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          buildInputs = [ pkgs.bash ];
          disallowedReferences = [ bendToolchain randomBendLib randomBendNative ];
          RANDOM_BEND_NATIVE_LIBRARY = "${randomBendNative}/lib/librandomb.a";
          stripDebugList = [ ];
          stripAllList = [ "bin" ];
          buildPhase = ''
            runHook preBuild
            bash bend/build-native "$PWD/bend-cli-out" --cli-only
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin $out/tests $out/share/random-bend2 $out/share/licenses/random-bend2
            install -m755 bend-cli-out/bin/randomb $out/bin/
            ln -s randomb $out/bin/nrandomb
            ln -s randomb $out/bin/drandomb
            install -m644 bend-cli-out/share/random-bend2/cli-source.sha256 $out/share/random-bend2/
            install -m755 tests/random_test $out/tests/
            install -m644 tests/cli_test_setup.sh tests/fixture-cleanup.sh $out/tests/
            patchShebangs --host $out/tests/random_test
            wrapProgram $out/tests/random_test --prefix PATH : ${pkgs.lib.makeBinPath installedTestTools}
            install -m644 LICENSE $out/share/licenses/random-bend2/LICENSE
            install -m644 ${bend-upstream.outPath}/LICENSE $out/share/licenses/random-bend2/Bend-LICENSE
            runHook postInstall
          '';
          meta = {
            description = "Experimental independent Bend core with the common C I/O CLI; not part of the default aggregate";
            license = with pkgs.lib.licenses; [ mit asl20 ];
            platforms = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
            mainProgram = "randomb";
          };
        };
        bendTestArtifacts = pkgs.linkFarm "random-bend2-test-artifacts" [
          { name = "bin"; path = "${randomBend}/bin"; }
          { name = "lib"; path = "${randomBendNative}/lib"; }
          { name = "include"; path = "${randomBendNative}/include"; }
          { name = "native-source.sha256"; path = "${randomBendNative}/share/random-bend2-ffi/native-source.sha256"; }
          { name = "cli-source.sha256"; path = "${randomBend}/share/random-bend2/cli-source.sha256"; }
        ];
        kaniVerifier = pkgs.callPackage ./nix/kani.nix { };
        rocToolchain = import ./nix/roc-toolchain.nix {
          inherit pkgs;
          upstream = roc-upstream.packages.${system}.roc;
        };
        rocSupported = nixpkgs.lib.hasSuffix "-linux" system;
        rocTools = pkgs.lib.optionals rocSupported [ rocToolchain ];
        randomRocLib = pkgs.stdenvNoCC.mkDerivation {
          pname = "random-roc-lib";
          version = "0.4.0";
          src = implementationSource;
          strictDeps = true;
          dontBuild = true;
          allowedReferences = [ ];
          installPhase = ''
            runHook preInstall
            mkdir -p $out/lib/roc/random $out/share/licenses/random-roc-lib
            for module in main Fixed Codec Blake3 Drbg Draw Sampler Ziggurat ZigguratTables Count Geometric Decimal Chart Batch Selection; do
              install -m644 roc/"$module".roc $out/lib/roc/random/
            done
            install -m644 LICENSE $out/share/licenses/random-roc-lib/LICENSE
            runHook postInstall
          '';
          meta = {
            description = "Independent pure Roc source library without a compiler or CLI dependency";
            license = pkgs.lib.licenses.mit;
            platforms = pkgs.lib.platforms.linux;
          };
        };

        randomRocNative = pkgs.stdenvNoCC.mkDerivation {
          pname = "random-roc-ffi";
          version = "0.4.0";
          src = implementationSource;
          strictDeps = true;
          nativeBuildInputs = [ rocToolchain pkgs.zig_0_16 pkgs.binutils ];
          allowedReferences = [ ];
          RANDOM_ROC_COMPILER = "${rocToolchain}/bin/roc";
          RANDOM_ROC_SOURCE_DIR = "${rocToolchain.src}";
          RANDOM_ROC_LIBRARY_DIR = "${randomRocLib}/lib/roc/random";
          buildPhase = ''
            runHook preBuild
            # Even --no-cache materializes the compiler-owned glue platform.
            # Give that source cache a writable, build-local root, not HOME.
            export ROC_CACHE_DIR="$TMPDIR/roc-cache"
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
            export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
            bash roc/build-native "$PWD/roc-lib-out" --library-only
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out/lib $out/include $out/share/licenses/random-roc-ffi
            install -m644 roc-lib-out/lib/librandomroc.a $out/lib/
            install -m755 roc-lib-out/lib/librandomroc.so $out/lib/
            install -m644 include/randomroc.h $out/include/
            install -m644 LICENSE $out/share/licenses/random-roc-ffi/LICENSE
            install -m644 roc-lib-out/share/licenses/random-roc-ffi/Roc-UPL \
              $out/share/licenses/random-roc-ffi/
            runHook postInstall
          '';
          meta = {
            description = "Standalone static/shared Roc C ABI libraries; no CLI or compiler runtime dependency";
            license = [ pkgs.lib.licenses.mit pkgs.lib.licenses.upl ];
            platforms = pkgs.lib.platforms.linux;
          };
        };

        randomRoc = pkgs.stdenvNoCC.mkDerivation {
          pname = "random-roc";
          version = "0.4.0";
          src = implementationSource;
          strictDeps = true;
          nativeBuildInputs = [ pkgs.zig_0_16 pkgs.makeWrapper ];
          buildInputs = [ pkgs.bash ];
          RANDOM_ROC_NATIVE_LIBRARY = "${randomRocNative}/lib/librandomroc.a";
          RANDOM_ROC_MUSL_LICENSE = "${pkgs.zig_0_16}/lib/zig/libc/musl/COPYRIGHT";
          buildPhase = ''
            runHook preBuild
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
            export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
            bash roc/build-native "$PWD/roc-cli-out" --cli-only
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin $out/tests $out/share/licenses/random-roc
            install -m755 roc-cli-out/bin/randomroc $out/bin/
            ln -s randomroc $out/bin/nrandomroc
            ln -s randomroc $out/bin/drandomroc
            install -m755 tests/random_test $out/tests/
            install -m644 tests/cli_test_setup.sh tests/fixture-cleanup.sh $out/tests/
            patchShebangs --host $out/tests/random_test
            wrapProgram $out/tests/random_test \
              --prefix PATH : ${pkgs.lib.makeBinPath installedTestTools}
            install -m644 LICENSE $out/share/licenses/random-roc/LICENSE
            install -m644 roc-cli-out/share/licenses/random-roc/Roc-UPL \
              roc-cli-out/share/licenses/random-roc/musl-COPYRIGHT \
              $out/share/licenses/random-roc/
            runHook postInstall
          '';
          meta = {
            description = "Independent Roc core with a stripped static C I/O CLI";
            license = [ pkgs.lib.licenses.mit pkgs.lib.licenses.upl ];
            platforms = pkgs.lib.platforms.linux;
            mainProgram = "randomroc";
          };
        };
        rocTestArtifacts = pkgs.linkFarm "random-roc-test-artifacts" [
          { name = "bin"; path = "${randomRoc}/bin"; }
          { name = "lib"; path = "${randomRocNative}/lib"; }
          { name = "include"; path = "${randomRocNative}/include"; }
        ];

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
        # SEPARATE LuaJIT bugs this pin exposed in the former deterministic code
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
          ln -s ${pkgs.qemu-user}/bin/qemu-x86_64 $out/bin/qemu-x86_64
          ln -s ${pkgs.zig_0_16}/bin/zig $out/bin/zig
          ln -s ${randomr}/bin/randomr $out/bin/randomr-x86_64-glibc
          ln -s ${randomr}/libexec/randomr $out/bin/randomr-unwrapped-x86_64
          ln -s ${randomrCrossAarch64}/bin/randomr $out/bin/randomr-aarch64-glibc
        '';

        # LuaJIT is the only runtime dependency (ffi + bit are built in).
        runtimeTools = [ luajitFixed ];
        # External tools the executable shells out to / the test suite needs.
        testTools = with pkgs; [
          bashInteractive coreutils gnugrep ripgrep gawk bc xxd binutils gnutar git file
          stdenv.cc libsixel imagemagick nodejs wasm-tools jq time
        ];
        # The installed 80-case CLI self-test needs ordinary shell utilities,
        # not the compilers, cross toolchains, image decoders, Node, or WASM
        # tooling used by the repository-wide CI gates. Keeping this list
        # separate prevents `random --test` from inflating the runtime closure
        # by gigabytes merely to make those unrelated tools visible on PATH.
        installedTestTools = with pkgs; [
          bashInteractive coreutils gnugrep gnused gawk bc xxd binutils
        ] ++ lib.optionals stdenv.isLinux [ glibc.bin ]
          ++ lib.optionals stdenv.isDarwin [ darwin.cctools ];

        # Zig 0.16 for the port (docs/plans/2026-08-02-zig-port.md). Pinned to
        # the explicit `zig_0_16` attribute rather than the rolling `zig`, so a
        # nixpkgs bump to 0.17 cannot silently change the compiler underneath a
        # port whose entire point is bit-reproducible output.
        zigTools = [ pkgs.zig_0_16 ];
		randomZigSharedName =
		  "librandomz${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";

        rustCargoDeps = pkgs.rustPlatform.importCargoLock {
          lockFile = ./Cargo.lock;
        };
        rustTools = [
          pkgs.cargo
          pkgs.clippy
          pkgs.rustc
          pkgs.rustfmt
          pkgs.rustPlatform.cargoSetupHook
        ];
        leanTools = [ pkgs.lean4 ];
		distributionMathlib = pkgs.callPackage ./nix/distribution-mathlib.nix { };

		mkRandomr = rustPkgs: runTests: rustPkgs.rustPlatform.buildRustPackage {
		  pname = "random-rust";
          version = "0.4.0";
          src = implementationSource;
          cargoLock.lockFile = ./Cargo.lock;
          cargoBuildFlags = [ "-p" "randomr-cli" ];
          cargoTestFlags = [ "--workspace" ];
          doCheck = runTests;
          nativeBuildInputs = pkgs.lib.optionals runTests [ pkgs.makeWrapper ];
          installPhase = ''
            runHook preInstall
            randomr_suffix="${rustPkgs.stdenv.hostPlatform.extensions.executable}"
            randomr_binary="target/${rustPkgs.stdenv.hostPlatform.rust.rustcTarget}/release/randomr$randomr_suffix"
            install -Dm755 "$randomr_binary" "$out/libexec/randomr$randomr_suffix"
            install -Dm755 "$randomr_binary" "$out/bin/randomr$randomr_suffix"
            ln -s "randomr$randomr_suffix" "$out/bin/nrandomr$randomr_suffix"
            ln -s "randomr$randomr_suffix" "$out/bin/drandomr$randomr_suffix"
			${pkgs.lib.optionalString runTests ''
			  install -Dm755 tests/random_test "$out/share/randomr/tests/random_test"
			  install -Dm644 tests/cli_test_setup.sh "$out/share/randomr/tests/cli_test_setup.sh"
			  install -Dm644 tests/fixture-cleanup.sh "$out/share/randomr/tests/fixture-cleanup.sh"
			  patchShebangs "$out/share/randomr/tests/random_test"
			  wrapProgram "$out/bin/randomr" \
			    --set-default RANDOM_TEST_FILE "$out/share/randomr/tests/random_test" \
			    --prefix PATH : ${pkgs.lib.makeBinPath installedTestTools}
			''}
			install -Dm644 LICENSE "$out/share/licenses/random-rust/LICENSE"
            runHook postInstall
          '';
          meta = with pkgs.lib; {
            description = "Rust library and CLI for the cross-platform-identical random CSPRNG";
            license = licenses.mit;
            mainProgram = "randomr";
          };
        };
        randomr = mkRandomr pkgs true;
		randomRustLib = pkgs.stdenvNoCC.mkDerivation {
		  pname = "random-rust-lib";
		  version = "0.4.0";
		  src = implementationSource;
		  strictDeps = true;
		  dontBuild = true;
		  installPhase = ''
			runHook preInstall
			mkdir -p $out/src/rust $out/share/licenses/random-rust-lib
			install -Dm644 Cargo.toml Cargo.lock README.md $out/src/
			cp -R rust/randomr $out/src/rust/randomr
			chmod -R u+w $out/src
			substituteInPlace $out/src/Cargo.toml \
			  --replace-fail \
			  'members = ["rust/randomr", "rust/randomr-cli"]' \
			  'members = ["rust/randomr"]'
			install -Dm644 LICENSE $out/share/licenses/random-rust-lib/LICENSE
			runHook postInstall
		  '';
		  passthru = {
			cargoPath = "src/rust/randomr";
			crateName = "randomr";
		  };
		  meta = with pkgs.lib; {
			description = "Cargo-consumable randomr library source without the CLI or Rust toolchain";
			license = licenses.mit;
			platforms = platforms.all;
		  };
		};
		randomLeanLib = pkgs.stdenvNoCC.mkDerivation {
		  pname = "random-lean-lib";
		  version = "0.4.0";
		  src = implementationSource;
		  strictDeps = true;
		  nativeBuildInputs = [ pkgs.lean4 ];
		  buildPhase = ''
			runHook preBuild
			export HOME="$TMPDIR/home"
			export XDG_CACHE_HOME="$HOME/.cache"
			mkdir -p "$XDG_CACHE_HOME"
			(cd lean && lake build Randoml)
			runHook postBuild
		  '';
		  installPhase = ''
			runHook preInstall
			mkdir -p $out/lib/lean $out/src $out/share/licenses/random-lean-lib
			cp -R lean/.lake/build/lib/lean/. $out/lib/lean/
			cp -R lean/Randoml $out/src/Randoml
			install -Dm644 lean/Randoml.lean lean/lakefile.toml \
			  lean/lean-toolchain $out/src/
			install -Dm644 LICENSE $out/share/licenses/random-lean-lib/LICENSE
			runHook postInstall
		  '';
		  meta = with pkgs.lib; {
			description = "Importable Randoml Lean 4 library, proofs, and compiled modules";
			license = licenses.mit;
			platforms = platforms.unix;
		  };
		};
		randomLeanProofs = pkgs.stdenvNoCC.mkDerivation {
		  pname = "random-lean-proofs";
		  version = "0.4.0";
		  src = implementationSource;
		  strictDeps = true;
		  nativeBuildInputs = [ pkgs.lean4 pkgs.bash pkgs.gnugrep pkgs.gnused ];
		  propagatedBuildInputs = [ randomLeanLib distributionMathlib ];
		  RANDOM_DISTRIBUTION_PROOF_DEPS = "${distributionMathlib}/lib/lean";
		  buildPhase = ''
			runHook preBuild
			export XDG_CACHE_HOME="$TMPDIR/random-proof-cache"
			export RANDOM_TEST_TRASH_DIR="$TMPDIR/random-proof-trash"
			bash proofs/check
			runHook postBuild
		  '';
		  installPhase = ''
			runHook preInstall
			mkdir -p "$out/lib/lean" "$out/src" "$out/share/licenses/random-lean-proofs"
			cp -R proofs/.lake/build/lib/lean/. "$out/lib/lean/"
			cp -R proofs/DistributionProofs "$out/src/DistributionProofs"
			install -Dm644 proofs/Contract.lean "$out/src/Contract.lean"
			install -Dm644 LICENSE "$out/share/licenses/random-lean-proofs/LICENSE"
			runHook postInstall
		  '';
		  passthru = {
			leanPath = "lib/lean";
			coreLibrary = randomLeanLib;
			mathLibrary = distributionMathlib;
		  };
		  meta = with pkgs.lib; {
			description = "Production-linked Randoml distribution proofs, separate from CLI/core consumers";
			license = licenses.mit;
			platforms = platforms.unix;
		  };
		};
		randoml = pkgs.stdenv.mkDerivation {
		  pname = "random-lean";
          version = "0.4.0";
          src = implementationSource;
          strictDeps = true;
          nativeBuildInputs = [ pkgs.lean4 pkgs.makeWrapper pkgs.bash ];
          buildInputs = [ pkgs.gmp pkgs.libuv ];
          buildPhase = ''
            runHook preBuild
            bash lean/build-owned-cli randoml
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            install -Dm755 randoml $out/bin/randoml
            install -Dm755 tests/random_test $out/share/randoml/tests/random_test
            install -Dm644 tests/cli_test_setup.sh $out/share/randoml/tests/cli_test_setup.sh
            install -Dm644 tests/fixture-cleanup.sh $out/share/randoml/tests/fixture-cleanup.sh
			install -Dm644 LICENSE $out/share/licenses/random-lean/LICENSE
			substituteInPlace $out/share/randoml/tests/random_test \
			  --replace-fail '#!/usr/bin/env bash' '#!${pkgs.bash}/bin/bash'
            makeWrapper $out/bin/randoml $out/bin/nrandoml \
              --set RANDOML_INVOKED_AS nrandoml
            makeWrapper $out/bin/randoml $out/bin/drandoml \
              --set RANDOML_INVOKED_AS drandoml
            wrapProgram $out/bin/randoml \
              --set-default RANDOM_TEST_FILE $out/share/randoml/tests/random_test \
              --prefix PATH : ${pkgs.lib.makeBinPath installedTestTools}
            runHook postInstall
          '';
          meta = with pkgs.lib; {
            description = "Independent Lean 4 implementation of the cross-platform-identical random CSPRNG";
            license = licenses.mit;
            platforms = platforms.unix;
            mainProgram = "randoml";
          };
        };

		randomLuaLib = pkgs.stdenvNoCC.mkDerivation {
		  pname = "random-luajit-lib";
		  version = "0.4.0";
		  src = implementationSource;
		  strictDeps = true;
		  dontBuild = true;
		  installPhase = ''
			runHook preInstall
			mkdir -p $out/share/lua/5.1 $out/share/licenses/random-luajit-lib
			cp lib/*.lua $out/share/lua/5.1/
			ln -s share/lua/5.1 $out/lib
			install -Dm644 LICENSE $out/share/licenses/random-luajit-lib/LICENSE
			runHook postInstall
		  '';
		  meta = with pkgs.lib; {
			description = "Caller-owned LuaJIT DRBG, distributions, numeric, chart and state modules";
			license = licenses.mit;
			platforms = platforms.unix;
		  };
		};
		randomLuaNativeBuildInputs = [ pkgs.makeWrapper pkgs.bash ];
		randomLua = pkgs.stdenvNoCC.mkDerivation {
		  pname = "random-luajit";
		  version = "0.4.0";
		  src = implementationSource;
		  strictDeps = true;
		  nativeBuildInputs = randomLuaNativeBuildInputs;
		  dontBuild = true;
		  installPhase = ''
			runHook preInstall
			mkdir -p $out/bin $out/tests $out/share/licenses/random-luajit
			install -Dm755 luajit/random $out/bin/random
			ln -s ${randomLuaLib}/lib $out/lib
			install -Dm755 tests/random_test $out/tests/random_test
			install -Dm644 tests/cli_test_setup.sh $out/tests/cli_test_setup.sh
			install -Dm644 tests/fixture-cleanup.sh $out/tests/fixture-cleanup.sh
			install -Dm644 LICENSE $out/share/licenses/random-luajit/LICENSE
			ln -s random $out/bin/nrandom
			ln -s random $out/bin/drandom
			substituteInPlace $out/bin/random \
			  --replace-fail '#!/usr/bin/env luajit' '#!${luajitFixed}/bin/luajit'
			substituteInPlace $out/tests/random_test \
			  --replace-fail '#!/usr/bin/env bash' '#!${pkgs.bash}/bin/bash'
			wrapProgram $out/tests/random_test \
			  --prefix PATH : ${pkgs.lib.makeBinPath installedTestTools}
			runHook postInstall
		  '';
		  meta = with pkgs.lib; {
			description = "LuaJIT oracle CLI for the cross-platform-identical random CSPRNG";
			license = licenses.mit;
			platforms = platforms.unix;
			mainProgram = "random";
		  };
		};

		randomZigLib = pkgs.stdenvNoCC.mkDerivation {
		  pname = "random-zig-lib";
		  version = "0.4.0";
		  src = implementationSource;
		  strictDeps = true;
		  nativeBuildInputs = [ pkgs.zig_0_16 ];
		  buildPhase = ''
			runHook preBuild
			export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
			export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
			mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
			zig build library -Doptimize=ReleaseFast --prefix zig-lib-out
			runHook postBuild
		  '';
		  installPhase = ''
			runHook preInstall
			mkdir -p $out/lib $out/include $out/share/licenses/random-zig-lib
			install -Dm644 zig-lib-out/lib/librandomz.a $out/lib/librandomz.a
			install -Dm755 zig-lib-out/lib/${randomZigSharedName} \
			  $out/lib/${randomZigSharedName}
			install -Dm644 zig-lib-out/include/randomz.h $out/include/randomz.h
			ln -s ${implementationSource} $out/src
			install -Dm644 LICENSE $out/share/licenses/random-zig-lib/LICENSE
			runHook postInstall
		  '';
		  meta = with pkgs.lib; {
			description = "Zig module source plus static/shared randomz C ABI libraries";
			license = licenses.mit;
			platforms = platforms.unix;
		  };
		};
		randomZig = pkgs.stdenv.mkDerivation {
		  pname = "random-zig";
		  version = "0.4.0";
		  src = implementationSource;
		  strictDeps = true;
		  nativeBuildInputs = [
			pkgs.makeWrapper pkgs.removeReferencesTo pkgs.zig_0_16
		  ];
		  buildPhase = ''
			runHook preBuild
			export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
			export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
			mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
			zig build -Doptimize=ReleaseFast
			runHook postBuild
		  '';
		  installPhase = ''
			runHook preInstall
			mkdir -p $out/bin $out/lib $out/include $out/tests \
			  $out/share/licenses/random-zig
			install -Dm755 zig-out/bin/randomz $out/bin/randomz
			ln -s randomz $out/bin/nrandomz
			ln -s randomz $out/bin/drandomz
			install -Dm644 zig-out/lib/librandomz.a $out/lib/librandomz.a
			install -Dm755 zig-out/lib/${randomZigSharedName} \
			  $out/lib/${randomZigSharedName}
			install -Dm644 zig-out/bin/randomz-wasi.wasm $out/lib/randomz-wasi.wasm
			remove-references-to -t ${pkgs.zig_0_16} $out/lib/randomz-wasi.wasm
			install -Dm644 zig-out/include/randomz.h $out/include/randomz.h
			install -Dm755 tests/random_test $out/tests/random_test
			install -Dm644 tests/cli_test_setup.sh $out/tests/cli_test_setup.sh
			install -Dm644 tests/fixture-cleanup.sh $out/tests/fixture-cleanup.sh
			install -Dm644 LICENSE $out/share/licenses/random-zig/LICENSE
			patchShebangs $out/tests/random_test
			wrapProgram $out/tests/random_test \
			  --prefix PATH : ${pkgs.lib.makeBinPath installedTestTools}
			runHook postInstall
		  '';
		  meta = with pkgs.lib; {
			description = "Zig CSPRNG library, C ABI/CLI, and WASI reactor";
			license = licenses.mit;
			platforms = platforms.unix;
			mainProgram = "randomz";
		  };
		};

		# Compose the compatibility aggregate deliberately. Both the LuaJIT and
		# Zig packages carry the same shared Bash oracle at /tests; selecting the
		# LuaJIT copy here avoids buildEnv's collision suppression while retaining
		# one canonical aggregate self-test surface.
		randomAll = pkgs.runCommand "random-all-0.4.0" {
		  meta = with pkgs.lib; {
			description = "Aggregate matching random CSPRNG implementations (including Roc on Linux)";
			license = [ licenses.mit ] ++ optional rocSupported licenses.upl;
			platforms = platforms.unix;
			mainProgram = "random";
		  };
		} (''
		  mkdir -p $out/bin $out/lib $out/libexec $out/include \
			$out/share/licenses
		  ln -s ${randomZig}/bin/* ${randomr}/bin/* \
			${randoml}/bin/* $out/bin/
		  ln -s ${randomLua}/bin/random $out/bin/random-luajit
		  for command in random nrandom drandom; do
		    ln -s ${randomCanonical}/bin/$command $out/bin/$command
		  done
		  ln -s ${randomLua}/lib/* ${randomZig}/lib/* $out/lib/
		  ln -s ${randomr}/libexec/* $out/libexec/
		  ln -s ${randomZig}/include/* $out/include/
		  ln -s ${randomLua}/tests $out/tests
		  ln -s ${randomr}/share/randomr $out/share/randomr
		  ln -s ${randoml}/share/randoml $out/share/randoml
		  ln -s ${randomLua}/share/licenses/random-luajit \
			${randomZig}/share/licenses/random-zig \
			${randomr}/share/licenses/random-rust \
			${randoml}/share/licenses/random-lean \
			$out/share/licenses/
		'' + pkgs.lib.optionalString rocSupported ''
		  ln -s ${randomRoc}/bin/* $out/bin/
		  ln -s ${randomRocNative}/lib/* $out/lib/
		  ln -s ${randomRocNative}/include/* $out/include/
		  ln -s ${randomRoc}/share/licenses/random-roc \
		    ${randomRocNative}/share/licenses/random-roc-ffi $out/share/licenses/
		'');

		luaConsumerClosure = pkgs.closureInfo {
		  rootPaths = [ randomLua ];
		};
		# Keep this list mechanically tied to every external derivation named by
		# randomLua: its stdenv, native tools, interpreter, and self-test PATH.
		# This avoids a recursive .drv closure check, which would fetch Nixpkgs'
		# entire compiler-bootstrap universe rather than model what selecting this
		# binary-cache output asks a consumer to build.
		luaDeclaredBuildInputNames = map pkgs.lib.getName
		  ([ pkgs.stdenvNoCC luajitFixed randomLuaLib ] ++ randomLuaNativeBuildInputs
		    ++ installedTestTools);
		luaForbiddenBuildMarkers = [
		  "random-zig" "random-rust" "random-lean"
		  "zig" "rustc" "cargo" "lean4"
		];
		luaDeclaredBuildInputsClean = builtins.all (name:
		  builtins.all (marker: !(pkgs.lib.hasInfix marker name))
		    luaForbiddenBuildMarkers
		) luaDeclaredBuildInputNames;
        crossWithUnsupported = crossPkgs: import nixpkgs {
          localSystem = system;
          crossSystem = crossPkgs.stdenv.hostPlatform;
          # Several Rust targets are compile-capable even though Nixpkgs does
          # not advertise the target as a package execution platform.
          config.allowUnsupportedSystem = true;
        };
        rustCrossTargetNames = [
          "linux-arm64"
          "mswin-amd64"
          "mswin-arm64"
        ];
        rustCrossSets = if crossSupported then {
          linux-arm64 = crossWithUnsupported pkgs.pkgsCross.aarch64-multiplatform;
          mswin-amd64 = crossWithUnsupported pkgs.pkgsCross.mingw-ucrt-x86_64;
          mswin-arm64 = crossWithUnsupported pkgs.pkgsCross.mingw-ucrt-aarch64;
        } else { };
        randomrCrossPackages = pkgs.lib.mapAttrs
          (_name: rustPkgs: mkRandomr rustPkgs false)
          rustCrossSets // pkgs.lib.optionalAttrs crossSupported {
            # Nixpkgs' ARM64 MinGW bootstrap currently requests unavailable
            # pthread headers. Retain the target using its pinned official
            # Rust std and the existing standalone gate's Zig linker.
            mswin-arm64 = pkgs.callPackage ./nix/rust-windows-arm64.nix {
              source = implementationSource;
              cargoDeps = rustCargoDeps;
            };
          };
        randomrCrossAarch64 = if crossSupported then
          randomrCrossPackages.linux-arm64
        else null;
        randomrCrossTargets = assert
          builtins.attrNames rustCrossSets == rustCrossTargetNames;
          pkgs.linkFarm "randomr-cross-targets"
            (pkgs.lib.mapAttrsToList (name: path: { inherit name path; })
              randomrCrossPackages);
        hostPf = {
          x86_64-linux = "linux-amd64";
          aarch64-linux = "linux-arm64";
          aarch64-darwin = "macos-arm64";
        }.${system};
        platformSystem = {
          linux-amd64 = "x86_64-linux";
          linux-arm64 = "aarch64-linux";
          macos-arm64 = "aarch64-darwin";
        };
        languageAttribute = {
          zig = "random-zig"; rust = "random-rust"; luajit = "random-luajit";
          lean = "random-lean"; roc = "random-roc"; bend = "random-bend2";
        };
        nativeLanguagePackages = {
          zig = randomZig; rust = randomr; luajit = randomLua;
          lean = randoml; bend = randomBend;
        } // pkgs.lib.optionalAttrs rocSupported { roc = randomRoc; };
        buildProducts = import ./nix/build-products.nix {
          inherit pkgs system installedTestTools;
          source = implementationSource;
          rustCrossPackages = randomrCrossPackages;
          getNativePackage = impl: pf:
            if pf == hostPf then nativeLanguagePackages.${impl}
            else if pkgs.lib.hasPrefix "mswin-" pf && impl == "rust" then
              # This existing cross builder requires its declared Linux host.
              self.packages.x86_64-linux."random-build-rust-${pf}-gnu-ReleaseFast"
            else self.packages.${platformSystem.${pf}}.${languageAttribute.${impl}};
        };
        selectionBytes = builtins.readFile ./CANONICAL_IMPL;
        canonicalId = pkgs.lib.removeSuffix "\n" selectionBytes;
        canonicalValid = builtins.elem canonicalId [ "zig" "rust" "luajit" "lean" "roc" "bend" ];
        canonicalVariant = if hostPf == "macos-arm64" then ""
          else if builtins.elem canonicalId [ "zig" "roc" ] then "musl" else "gnu";
        canonicalProductName = "random-build-${canonicalId}-${hostPf}"
          + pkgs.lib.optionalString (canonicalVariant != "") "-${canonicalVariant}"
          + "-ReleaseFast";
        canonicalProduct = if canonicalValid && builtins.hasAttr canonicalProductName buildProducts then
          buildProducts.${canonicalProductName}
          else throw "Invalid or unavailable CANONICAL_IMPL; run ./build canonize zig (one identifier, optional single LF).";
        canonicalMain = {
          zig = "randomz"; rust = "randomr"; luajit = "random";
          lean = "randoml"; roc = "randomroc"; bend = "randomb";
        }.${canonicalId};
        randomCanonical = pkgs.runCommand "random-${canonicalId}-canonical-0.4.0" {
          meta = {
            description = "Canonical ${canonicalId} implementation of cross-platform-identical Random";
            mainProgram = "random";
            license = canonicalProduct.meta.license or pkgs.lib.licenses.mit;
          };
          passthru = { implementation = canonicalId; product = canonicalProduct; };
        } ''
          mkdir -p "$out/bin"
          for entry in ${canonicalProduct}/*; do
            [ "$(basename "$entry")" = bin ] || ln -s "$entry" "$out/"
          done
          ln -s ${canonicalProduct}/bin/* "$out/bin/"
          for prefix in "" n d; do
            [ -e "$out/bin/''${prefix}random" ] ||
              ln -s ${canonicalProduct}/bin/''${prefix}${canonicalMain} "$out/bin/''${prefix}random"
          done
        '';
      in {
        # The conditional attribute is merged INSIDE `packages`, not by `//`-ing
        # a second `{ packages.crossToolchains = ...; }` onto the outputs set.
        # `//` is a SHALLOW merge, so that form silently replaced the whole
        # `packages` attribute -- default, random and luajitPinned all vanished
        # and only crossToolchains survived. `nix flake check` did not catch it
        # (it exercised `checks.*`, which was untouched); Mechatron Prime did,
        # with "target failed: packages.x86_64-linux.default".
        packages = {
          # The default follows only the canonical implementation; the
          # intentionally expensive multi-language aggregate stays explicit.
          default = randomCanonical;
          random-all = randomAll;
		  random-luajit = randomLua;
		  random-zig = randomZig;
		  random-rust = randomr;
		  random-lean = randoml;
		  random-luajit-lib = randomLuaLib;
		  random-zig-lib = randomZigLib;
		  random-rust-lib = randomRustLib;
		  random-lean-lib = randomLeanLib;
		  random-lean-proofs = randomLeanProofs;
          random-bend2-lib = randomBendLib;
          random-bend2-probe = randomBendProbe;
          random-bend2-ffi = randomBendNative;
          random-bend2 = randomBend;
          randomb = randomBend;
          bend2-toolchain = bendToolchain;

		  # Compatibility aliases. Language-named aliases now resolve to their
		  # minimal package; `random` follows the tracked canonical selection.
          random = randomCanonical;
          randomz = randomZig;
          randomr = randomr;
          randoml = randoml;

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
        } // buildProducts // nixpkgs.lib.optionalAttrs (nixpkgs.lib.hasSuffix "-linux" system) {
          roc-toolchain = rocToolchain;
          random-roc-lib = randomRocLib;
          random-roc-ffi = randomRocNative;
          random-roc = randomRoc;
          randomroc = randomRoc;
        } // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          bend2-proof-kernel = bendProofKernel;
          random-bend2-bench = bendBench.bendNative;
          random-zig-bend2-bench = bendBench.zigNative;
          random-rust-bend2-bench = bendBench.rustNative;
          random-bend2-sampler-bench = bendBench.bendSamplers;
          random-roc-bend2-bench = bendBench.rocSamplers;
          random-bend2-full-cli-driver = bendBench.cliDriver;
        } // nixpkgs.lib.optionalAttrs crossSupported {
          # Only meaningful on x86_64-linux: pkgsCross/pkgsMusl and qemu-user are
          # what make the aarch64 and musl legs buildable from this host at all.
          crossToolchains = crossToolchains;
          randomrAarch64 = randomrCrossAarch64;
          randomrCrossTargets = randomrCrossTargets;
          kani = kaniVerifier;
        };

        apps = {
        default = {
          type = "app";
          program = "${randomCanonical}/bin/random";
          meta.description = "Run the canonical Random implementation";
        };
        randomz = {
          type = "app";
          program = "${randomZig}/bin/randomz";
          meta.description = "Run the C CLI over the Zig randomz library";
        };

        randomr = {
          type = "app";
          program = "${randomr}/bin/randomr";
          meta.description = "Run the Rust randomr CLI";
        };

        randoml = {
          type = "app";
          program = "${randoml}/bin/randoml";
          meta.description = "Run the independent Lean implementation";
        };
        randomb = {
          type = "app";
          program = "${randomBend}/bin/randomb";
          meta.description = "Run the experimental Bend core through the shared C I/O frontend";
        };
        } // nixpkgs.lib.optionalAttrs rocSupported {
          randomroc = {
            type = "app";
            program = "${randomRoc}/bin/randomroc";
            meta.description = "Run the C I/O frontend over the independent Roc core";
          };
        };

        # Hermetic CI check: runs the FULL suite runner (./test), not just
        # tests/random_test, so fixed_test/golden_test/kernel_bc_sweep are
        # actually exercised here too, not just the CLI-behavior suite.
        checks.distribution-proofs = randomLeanProofs;
        checks.build-architecture = pkgs.runCommand "random-build-architecture" {
          nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.binutils pkgs.file pkgs.stdenv.cc ];
        } ''
          cp -r ${./.} work
          chmod -R u+w work
          cd work
          export RANDOM_TEST_TRASH_DIR="$TMPDIR/fixture-trash"
          patchShebangs tests/build_arch_test
          bash tests/build_arch_test
          touch "$out"
        '';
        # Fast real-sandbox gate before the full matrix; never replaces it.
        checks.bend2-sandbox = if system == "x86_64-linux" then pkgs.runCommand "random-bend2-sandbox" {
          nativeBuildInputs = runtimeTools ++ testTools ++ zigTools ++ [ bendToolchain ];
          BEND_NO_TELEMETRY = "1";
          RANDOM_BEND_LIBDIR = "${randomBendLib}";
          RANDOM_BEND_PROBEDIR = "${randomBendProbe}";
          RANDOM_BEND_ARTIFACT_DIR = "${bendTestArtifacts}";
          RANDOM_BEND_ORACLE_LIBRARY = "${randomZigLib}/lib/${randomZigSharedName}";
          RANDOM_BEND_NATIVE_BENCH = "${bendBench.bendNative}/bin/bend2-bench";
          RANDOM_BEND_MODEL_MODULE = "${bendBench.bendNative}/lib/javascript/model.mjs";
          RANDOM_BEND_ZIG_BENCH = "${bendBench.zigNative}/bin/zig-bend2-bench";
          RANDOM_BEND_RUST_BENCH = "${bendBench.rustNative}/bin/rust-bend2-bench";
          RANDOM_BEND_PROBE = "${randomBendProbe}/bin/bend2-probe";
          RANDOM_BEND_LUA_CLI = "${randomLua}/bin/random";
          RANDOM_BEND_ZIG_CLI = "${randomZig}/bin/randomz";
          RANDOM_BEND_RUST_CLI = "${randomr}/libexec/randomr";
          RANDOM_BENDTT_REQUIRED = "${bendProofKernel}/bin/bendtt";
        } ''
          cp -r ${./.} work
          chmod -R u+w work
          cd work
          export RANDOM_TEST_TRASH_DIR="$TMPDIR/fixture-trash"
          export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
          export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
          mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
          patchShebangs bin luajit tests experiments
          FAST=1 bash ./test bend2
          touch $out
        '' else pkgs.runCommand "random-bend2-sandbox-not-applicable" { } "touch $out";
        checks.random-test = pkgs.runCommand "random-test"
          ({
            nativeBuildInputs = runtimeTools ++ testTools ++ zigTools ++ rustTools ++ leanTools ++ rocTools ++ [ bendToolchain performanceProfile ];
            BEND_NO_TELEMETRY = "1";
            RANDOM_BEND_LIBDIR = "${randomBendLib}";
            RANDOM_BEND_PROBEDIR = "${randomBendProbe}";
            RANDOM_BEND_ARTIFACT_DIR = "${bendTestArtifacts}";
            RANDOM_BEND_ORACLE_LIBRARY = "${randomZigLib}/lib/${randomZigSharedName}";
            RANDOM_BEND_NATIVE_BENCH = pkgs.lib.optionalString (system == "x86_64-linux") "${bendBench.bendNative}/bin/bend2-bench";
            RANDOM_BEND_MODEL_MODULE = pkgs.lib.optionalString (system == "x86_64-linux") "${bendBench.bendNative}/lib/javascript/model.mjs";
            RANDOM_BEND_ZIG_BENCH = pkgs.lib.optionalString (system == "x86_64-linux") "${bendBench.zigNative}/bin/zig-bend2-bench";
            RANDOM_BEND_RUST_BENCH = pkgs.lib.optionalString (system == "x86_64-linux") "${bendBench.rustNative}/bin/rust-bend2-bench";
            RANDOM_BEND_PROBE = "${randomBendProbe}/bin/bend2-probe";
            RANDOM_BEND_LUA_CLI = "${randomLua}/bin/random";
            RANDOM_BEND_ZIG_CLI = "${randomZig}/bin/randomz";
            RANDOM_BEND_RUST_CLI = "${randomr}/libexec/randomr";
            RANDOM_BENDTT_REQUIRED = pkgs.lib.optionalString (system == "x86_64-linux") "${bendProofKernel}/bin/bendtt";
            RANDOM_BEND_SAMPLER_BENCH = pkgs.lib.optionalString (system == "x86_64-linux") "${bendBench.bendSamplers}/bin/bend2-sampler-bench";
            RANDOM_BEND_ROC_SAMPLER_BENCH = pkgs.lib.optionalString (system == "x86_64-linux") "${bendBench.rocSamplers}/bin/roc-bend2-sampler-bench";
            RANDOM_BEND_FULL_CLI_DRIVER = pkgs.lib.optionalString (system == "x86_64-linux") "${bendBench.cliDriver}/bin/bend2-full-cli-driver";
            RANDOM_BEND_FULL_BEND_CLI = "${randomBend}/bin/randomb";
            RANDOM_BEND_FULL_LUA_CLI = "${randomLua}/bin/random";
            RANDOM_BEND_FULL_ZIG_CLI = "${randomZig}/bin/randomz";
            RANDOM_BEND_FULL_RUST_CLI = "${randomr}/libexec/randomr";
            RANDOM_BEND_FULL_LEAN_CLI = "${randoml}/bin/randoml";
            RANDOM_BEND_FULL_ROC_CLI = pkgs.lib.optionalString rocSupported "${randomRoc}/bin/randomroc";
            cargoDeps = rustCargoDeps;
            RANDOM_GMP_LIBRARY = "${pkgs.gmp}/lib/libgmp${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
			RANDOM_DISTRIBUTION_PROOF_DEPS = "${distributionMathlib}/lib/lean";
            RANDOM_MPFR_LIBRARY = "${pkgs.mpfr}/lib/libmpfr${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
          } // pkgs.lib.optionalAttrs rocSupported {
            RANDOM_ROC_COMPILER = "${rocToolchain}/bin/roc";
            RANDOM_ROC_SOURCE_DIR = "${rocToolchain.src}";
            RANDOM_ROC_NATIVE_DIR = "${rocTestArtifacts}";
          }) ''
            cp -r ${./.} work
            chmod -R u+w work
            cd work
            source tests/product_paths.sh
			# runCommand has no unpack/patch phases, so cargoSetupHook's normal
			# phase hooks do not fire automatically. Apply them explicitly to
			# point Cargo at importCargoLock's vendored source tree.
			cargoSetupPostUnpackHook
			cargoSetupPostPatchHook
			export CARGO_HOME="$TMPDIR/cargo-home"
			mkdir -p "$CARGO_HOME"
			cp .cargo/config.toml "$CARGO_HOME/config.toml"
			substituteInPlace "$CARGO_HOME/config.toml" \
			  --replace-fail 'directory = "cargo-vendor-dir"' \
			  "directory = \"$PWD/cargo-vendor-dir\""
			export CARGO_NET_OFFLINE=true
            # Zig writes to a global cache; the sandbox has no writable HOME by
            # default, and without this `zig build` fails before compiling
            # anything. No network is needed -- build.zig.zon declares no
            # dependencies, deliberately.
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
            export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
            # The Nix sandbox has no /usr/bin/env, so resolve shebangs in both the
            # program (bin/) and the test scripts (tests/) — `random --test` execs the
            # latter via its #!/usr/bin/env bash shebang.
            patchShebangs bin luajit tests experiments lean/build-owned-cli
            export HOME="$TMPDIR"
            export PATH="$PWD/bin:$PATH"
            # ./test sets RANDOM_TEST_FILE itself; FAST=1 keeps this hermetic
            # check fast (kernel_jit_diff is deep-mode-only by design — see
            # its own header comment).
            FAST=1 bash ./test
            touch $out
          '';

        checks.roc-core = if rocSupported then pkgs.runCommand "random-roc-core"
          {
            nativeBuildInputs = runtimeTools ++ testTools ++ zigTools ++ rocTools;
            RANDOM_ROC_COMPILER = "${rocToolchain}/bin/roc";
            RANDOM_ROC_SOURCE_DIR = "${rocToolchain.src}";
            RANDOM_ROC_LIBRARY_DIR = "${randomRocLib}/lib/roc/random";
          } ''
            cp -r ${./.} work
            chmod -R u+w work
            cd work
            source tests/product_paths.sh
            export ROC_CACHE_DIR="$TMPDIR/roc-cache"
            export XDG_CACHE_HOME="$TMPDIR/roc-xdg-cache"
            mkdir -p "$ROC_CACHE_DIR" "$XDG_CACHE_HOME"
            patchShebangs bin luajit tests
            bash tests/roc_core_test
            bash tests/roc_platform_test
            mkdir consumer
            cp tests/roc_library_consumer.roc consumer/main.roc
            ln -s ${randomRocLib}/lib/roc/random consumer/library
            ln -s ${rocToolchain.src}/src/echo_platform/platform consumer/platform
            substituteInPlace consumer/main.roc \
              --replace-fail '__RANDOM_ROC_LIBRARY__' './library/main.roc' \
              --replace-fail '__RANDOM_ROC_ECHO_PLATFORM__' './platform/main.roc'
            "$RANDOM_ROC_COMPILER" check consumer/main.roc
            # The upstream Echo declaration has no external native target
            # manifest: only headerless apps get its bundled host. Check the
            # actual package imports above; execute the installed source
            # overlay in an isolated headerless consumer below. Do not claim
            # this is execution of a custom platform or of our future C ABI.
            mkdir native-consumer
            cp ${randomRocLib}/lib/roc/random/*.roc native-consumer/
            cp tests/roc_library_native.roc native-consumer/consumer.roc
            "$RANDOM_ROC_COMPILER" check native-consumer/consumer.roc
            "$RANDOM_ROC_COMPILER" build native-consumer/consumer.roc --opt=speed --output="$PWD/native-consumer/run"
            actual="$(native-consumer/run 42)"
            expected="$("$RANDOM_TEST_ZIG_OUT/bin/roc-core-test" geometric 42 4611686018427387904 -100 1)"
            expected="''${expected//$'\n'pos=/:}"
            test "$actual" = "$expected"
            test ! -e ${randomRocLib}/bin
            test ! -e ${randomRocLib}/lib/roc/random/test.roc
            touch $out
          '' else pkgs.runCommand "random-roc-core-not-applicable" { } "touch $out";

        checks.roc-native = if rocSupported then pkgs.runCommand "random-roc-native"
          {
            nativeBuildInputs = runtimeTools ++ testTools ++ zigTools;
            RANDOM_ROC_NATIVE_DIR = "${rocTestArtifacts}";
          } ''
            cp -r ${./.} work
            chmod -R u+w work
            cd work
            source tests/product_paths.sh
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
            export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
            export RANDOM_TEST_TRASH_DIR="$TMPDIR/test-Trash"
            patchShebangs bin luajit tests
            bash tests/roc_native_test
            bash tests/roc_cli_test
            test ! -e ${randomRocNative}/bin
            test ! -e ${randomRocLib}/bin
            test ! -e ${randomRoc}/lib
            for notice in ${randomRocNative}/share/licenses/random-roc-ffi/Roc-UPL \
                ${randomRoc}/share/licenses/random-roc/Roc-UPL; do
              test -s "$notice"
              test "$(sha256sum "$notice" | cut -d' ' -f1)" = \
                "$(sha256sum ${rocToolchain.src}/LICENSE | cut -d' ' -f1)"
            done
            test -s ${randomRoc}/share/licenses/random-roc/musl-COPYRIGHT
            test "$(sha256sum ${randomRoc}/share/licenses/random-roc/musl-COPYRIGHT | cut -d' ' -f1)" = \
              "$(sha256sum ${pkgs.zig_0_16}/lib/zig/libc/musl/COPYRIGHT | cut -d' ' -f1)"
            ${randomRoc}/bin/randomroc --test
            touch $out
          '' else pkgs.runCommand "random-roc-native-not-applicable" { } "touch $out";

        checks.stats-smoke = pkgs.runCommand "random-stats-smoke"
          ({
            RANDOM_STATS_SKIP_BUILD = "1";
            RANDOM_STATS_LUA_CLI = "${randomLua}/bin/random";
            RANDOM_STATS_ZIG_CLI = "${randomZig}/bin/randomz";
            RANDOM_STATS_RUST_CLI = "${randomr}/bin/randomr";
            RANDOM_STATS_LEAN_CLI = "${randoml}/bin/randoml";
            nativeBuildInputs = runtimeTools ++ testTools ++ zigTools ++ rustTools ++ leanTools;
            cargoDeps = rustCargoDeps;
          } // pkgs.lib.optionalAttrs rocSupported {
            RANDOM_ROC_NATIVE_DIR = "${rocTestArtifacts}";
            RANDOM_STATS_ROC_CLI = "${randomRoc}/bin/randomroc";
          }) ''
            cp -r ${./.} work
            chmod -R u+w work
            cd work
            source tests/product_paths.sh
			cargoSetupPostUnpackHook
			cargoSetupPostPatchHook
			export CARGO_HOME="$TMPDIR/cargo-home"
			mkdir -p "$CARGO_HOME"
			cp .cargo/config.toml "$CARGO_HOME/config.toml"
			substituteInPlace "$CARGO_HOME/config.toml" \
			  --replace-fail 'directory = "cargo-vendor-dir"' \
			  "directory = \"$PWD/cargo-vendor-dir\""
			export CARGO_NET_OFFLINE=true
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
            export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
            patchShebangs bin luajit tests stats lean/build-owned-cli
            export HOME="$TMPDIR"
            export PATH="$PWD/bin:$PATH"
            FAST=1 RANDOM_STATS_SKIP_TRUE=1 bash ./stats --all
            touch $out
          '';

		checks.package-split = assert pkgs.lib.assertMsg
		  luaDeclaredBuildInputsClean
		  "random-luajit has a Zig, Rust/Cargo, or Lean direct build input";
		  assert pkgs.lib.assertMsg
		    (builtins.all (shells: shells ? proofs) (builtins.attrValues self.devShells))
		    "the isolated proof shell is missing on a supported native system";
		  pkgs.runCommand "random-package-split"
		  { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
			# Each named output exposes only its implementation's command family.
			test -x ${randomLua}/bin/random
			test -x ${randomLua}/bin/nrandom
			test -x ${randomLua}/bin/drandom
			test ! -e ${randomLua}/bin/randomz
			test ! -e ${randomLua}/bin/randomr
			test ! -e ${randomLua}/bin/randoml

			test -x ${randomZig}/bin/randomz
			test -s ${randomZig}/lib/librandomz.a
			test -s ${randomZig}/lib/${randomZigSharedName}
			test -s ${randomZig}/lib/randomz-wasi.wasm
			test -s ${randomZig}/include/randomz.h
			test ! -e ${randomZig}/bin/random
			test ! -e ${randomZig}/bin/randomr
			test ! -e ${randomZig}/bin/randoml

			test -x ${randomr}/bin/randomr
			test ! -e ${randomr}/bin/random
			test ! -e ${randomr}/bin/randomz
			test ! -e ${randomr}/bin/randoml

			test -x ${randoml}/bin/randoml
			test ! -e ${randoml}/bin/random
			test ! -e ${randoml}/bin/randomz
			test ! -e ${randoml}/bin/randomr

			# Library selectors contain native import/link surfaces and no CLI.
			test -s ${randomLuaLib}/lib/blake3.lua
			test ! -e ${randomLuaLib}/bin
			test -s ${randomZigLib}/lib/librandomz.a
			test -s ${randomZigLib}/lib/${randomZigSharedName}
			test -s ${randomZigLib}/include/randomz.h
			test -s ${randomZigLib}/src/build.zig
			test ! -e ${randomZigLib}/bin
			test -s ${randomRustLib}/src/rust/randomr/src/lib.rs
			test ! -e ${randomRustLib}/bin
			test -s ${randomLeanLib}/lib/lean/Randoml.olean
			test -s ${randomLeanLib}/src/Randoml.lean
			test ! -e ${randomLeanLib}/bin
			test -s ${randomLeanProofs}/lib/lean/DistributionProofs/Uniform.olean
			test -s ${randomLeanProofs}/lib/lean/DistributionProofs/Geometric.olean
			test -s ${randomLeanProofs}/src/Contract.lean
			test ! -e ${randomLeanProofs}/bin

            # The explicit aggregate exposes every production implementation;
            # the default selects the canonical implementation separately.
			for executable in random randomz randomr randoml; do
			  test -x ${randomAll}/bin/"$executable"
			done

			${randomLua}/bin/random --seed 42 --count 1 >/dev/null
			${randomZig}/bin/randomz --seed 42 --count 1 >/dev/null
			${randomr}/bin/randomr --seed 42 --count 1 >/dev/null
			${randoml}/bin/randoml --seed 42 --count 1 >/dev/null

			# The eval-time assertion above checks the package's direct .drv inputs;
			# this checks the exact transitive runtime closure inherited by a
			# consumer of the installed output.
			if grep -E -- '-(zig|rustc|cargo|lean4)(-|$)' \
			    ${luaConsumerClosure}/store-paths; then
			  echo "random-luajit closure unexpectedly contains a compiler toolchain" >&2
			  exit 1
			fi
			for forbidden in ${randomZig} ${randomr} ${randoml}; do
			  if grep -Fx -- "$forbidden" ${luaConsumerClosure}/store-paths; then
				echo "random-luajit closure unexpectedly contains $forbidden" >&2
				exit 1
			  fi
			done
			touch $out
		  '';

		checks.library-packages = pkgs.runCommand "random-library-packages"
		  {
			nativeBuildInputs = [
			  luajitFixed pkgs.lean4 pkgs.zig_0_16 pkgs.cargo pkgs.rustc
			  pkgs.rustPlatform.cargoSetupHook bendToolchain pkgs.nodejs
			];
			cargoDeps = rustCargoDeps;
		  } ''
			cp ${./Cargo.lock} Cargo.lock
			cargoSetupPostUnpackHook
			cargoSetupPostPatchHook
			export CARGO_HOME="$TMPDIR/cargo-home"
			mkdir -p "$CARGO_HOME"
			cp .cargo/config.toml "$CARGO_HOME/config.toml"
			substituteInPlace "$CARGO_HOME/config.toml" \
			  --replace-fail 'directory = "cargo-vendor-dir"' \
			  "directory = \"$PWD/cargo-vendor-dir\""
			export CARGO_NET_OFFLINE=true

			# Lua modules are directly importable without the CLI package.
			LUA_PATH='${randomLuaLib}/lib/?.lua;;' luajit -e '
			  local b3 = require("blake3")
			  assert(b3.blake3("", nil, 32) ==
			    "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262")
			'
			LUA_PATH='${randomLuaLib}/lib/?.lua;;' luajit ${./tests/luajit_library.lua}
			LUA_PATH='${randomLuaLib}/lib/?.lua;;' luajit ${./tests/geometric.lua}
			LUA_PATH='${randomLuaLib}/lib/?.lua;;' luajit ${./tests/geometric_ffi.lua} \
			  ${randomZigLib}/lib/${randomZigSharedName}

			# Load and execute the installed C ABI directly through LuaJIT FFI;
			# no separately compiled test harness is needed for behavior coverage.
			luajit -e '
			  local ffi = require("ffi")
			  ffi.cdef[[
			    typedef struct { uint8_t key[32]; uint64_t position; } randomz_drbg;
			    int randomz_drbg_init(randomz_drbg *, const uint8_t *);
			    int randomz_drbg_fill(randomz_drbg *, uint8_t *, size_t);
			  ]]
			  local rz = ffi.load("${randomZigLib}/lib/${randomZigSharedName}")
			  local seed = ffi.new("uint8_t[32]")
			  seed[31] = 42
			  local state = ffi.new("randomz_drbg[1]")
			  local output = ffi.new("uint8_t[64]")
			  assert(rz.randomz_drbg_init(state, seed) == 0)
			  assert(rz.randomz_drbg_fill(state, output, 64) == 0)
			  local hex = ffi.string(output, 64):gsub(".", function(byte)
			    return string.format("%02x", string.byte(byte))
			  end)
			  assert(hex == "69dfe2e9b579cf6dfe3d71b11024db6eb49d5b9861505b3ecfc3d379a6dc8f04" ..
			    "b6900db333d20760661226da010db589c5080aaf5f6068fc0874ce62aca36f60")
			'

			# A separate Zig package imports the installed package's public module.
			cp -R ${./tests/fixtures/randomz-consumer} "$TMPDIR/zig-consumer"
			chmod -R u+w "$TMPDIR/zig-consumer"
			ln -s ${randomZigLib}/src "$TMPDIR/zig-consumer/random"
			export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
			export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
			mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
			(cd "$TMPDIR/zig-consumer" && zig build test -Doptimize=ReleaseSafe)

			# The source-only Rust output must resolve beside validate_gui's exact
			# libc/zeroize versions, while the project's Cargo.lock stays reproducible.
			cp -R ${./tests/fixtures/randomr-consumer} "$TMPDIR/rust-consumer"
			chmod -R u+w "$TMPDIR/rust-consumer"
			substituteInPlace "$TMPDIR/rust-consumer/Cargo.toml" \
			  --replace-fail '../../../rust/randomr' \
			  '${randomRustLib}/src/rust/randomr'
			(cd "$TMPDIR/rust-consumer" && cargo run --offline)

			# The compiled Lean library imports without the CLI derivation or sources.
			LEAN_PATH=${randomLeanLib}/lib/lean lean ${./tests/fixtures/randoml-consumer.lean}
			# Check the installed proof artifacts, not just repository elaboration.
			LEAN_PATH=${randomLeanProofs}/lib/lean:${randomLeanLib}/lib/lean:${distributionMathlib}/lib/lean \
			  lean -DwarningAsError=true --trust=0 ${randomLeanProofs}/src/Contract.lean

			# Compile an independent consumer with only the installed Bend source
			# SDK. Also import the coherent JS facade and load the solo C ABI.
			export BEND_NO_TELEMETRY=1
			mkdir -p "$TMPDIR/bend-consumer"
			cp ${./tests/fixtures/randomb-consumer.bend} "$TMPDIR/bend-consumer/main.bend"
			# Bend validates canonical path components; Nix store hashes are not
			# module identifiers. Copy the SDK into the consumer's source graph.
			cp -R ${randomBendLib}/lib/bend/random "$TMPDIR/bend-consumer/random"
			bend "$TMPDIR/bend-consumer/main.bend" -o "$TMPDIR/bend-consumer/main.js"
			test "$(node "$TMPDIR/bend-consumer/main.js")" = '0:18:0:4'
			node ${./tests/fixtures/randomb-consumer.mjs} ${randomBendLib}/lib/javascript/random/index.mjs
			LUA_PATH='${randomLuaLib}/lib/?.lua;;' luajit ${./tests/geometric_ffi.lua} \
			  ${randomBendNative}/lib/librandomb${pkgs.stdenv.hostPlatform.extensions.sharedLibrary} randomb
			test ! -e ${randomBendLib}/bin
			test ! -e ${randomBendNative}/bin
			test -s ${randomBendNative}/lib/librandomb.a
			test -s ${randomBendNative}/include/randomb.h
			test ! -e ${randomBend}/lib
			test ! -e ${randomBend}/include
			touch $out
		  '';

        checks.package-smoke = pkgs.runCommand "random-package-smoke"
          { nativeBuildInputs = [ pkgs.stdenv.cc pkgs.wasm-tools pkgs.file ]; } ''
            export HOME="$TMPDIR/home"
            export XDG_CONFIG_HOME="$HOME/.config"
            export XDG_CACHE_HOME="$HOME/.cache"
            export XDG_DATA_HOME="$HOME/.local/share"
            export XDG_STATE_HOME="$HOME/.local/state"
            export XDG_RUNTIME_DIR="$TMPDIR/runtime"
            mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" \
              "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
            chmod 0700 "$XDG_RUNTIME_DIR"
            # The public default must execute precisely its selected product,
            # not a same-output program accidentally found elsewhere on PATH.
            test "$(readlink -f ${randomCanonical}/bin/random)" = \
              "$(readlink -f ${canonicalProduct}/bin/${canonicalMain})"
            ${randomCanonical}/bin/random --about
            test "$(${randomCanonical}/bin/random --seed 42 d20 -c 10 2>/dev/null)" = \
              "$(${randomLua}/bin/random --seed 42 d20 -c 10 2>/dev/null)"
            ${randomCanonical}/bin/random --test
            test -s ${randomAll}/share/licenses/random-luajit/LICENSE
            test -s ${randomAll}/share/licenses/random-zig/LICENSE
            test -s ${randomAll}/share/licenses/random-rust/LICENSE
			test -s ${randomAll}/share/licenses/random-lean/LICENSE
            test -s ${randomAll}/lib/randomz-wasi.wasm
            wasm-tools validate ${randomAll}/lib/randomz-wasi.wasm
            cc -std=c11 -Wall -Wextra -Werror -I${randomAll}/include \
              ${./tests/randomz_abi_test.c} ${randomAll}/lib/librandomz.a \
              -o randomz-abi-test
            ./randomz-abi-test
			${randomAll}/bin/randomz --about >/dev/null
			${randomAll}/bin/drandomz --seed 42 -c 1 >/dev/null
			${randomAll}/bin/nrandomz --seed 42 -c 1 >/dev/null
			${randomAll}/bin/randomr --about >/dev/null
			${randomAll}/bin/randoml --about >/dev/null
			${randomAll}/libexec/randomr --about >/dev/null
			${randomAll}/bin/drandomr --seed 42 -c 1 >/dev/null
			${randomAll}/bin/nrandomr --seed 42 -c 1 >/dev/null
			${randomAll}/bin/drandoml --seed 42 -c 1 >/dev/null
			${randomAll}/bin/nrandoml --seed 42 -c 1 >/dev/null
			${randomAll}/bin/drandom --seed 42 -c 1 >/dev/null
			${randomAll}/bin/nrandom --seed 42 -c 1 >/dev/null
			test "$(${randomAll}/bin/random --seed 42 -c 8)" = \
			  "$(${randomAll}/bin/randomz --seed 42 -c 8)"
			test "$(${randomAll}/bin/random --seed 42 -c 8)" = \
			  "$(${randomAll}/bin/randomr --seed 42 -c 8)"
			test "$(${randomAll}/bin/random --seed 42 -c 8)" = \
			  "$(${randomAll}/bin/randoml --seed 42 -c 8)"
			test "$(${randomAll}/bin/randomr --seed 42 -c 8)" = \
			  "$(${randomAll}/libexec/randomr --seed 42 -c 8)"
			${randomAll}/bin/random --test
			${randomAll}/bin/randomz --test
			RANDOM_TEST_FILE=${randomAll}/tests/random_test ${randomAll}/bin/randomr --test
			${randomAll}/bin/randoml --test
			${randomr}/bin/randomr --test
			test -s ${randomBend}/share/licenses/random-bend2/LICENSE
			test -s ${randomBend}/share/licenses/random-bend2/Bend-LICENSE
			${randomBend}/bin/randomb --test
			test "$(${randomAll}/bin/random --seed 42 d20 -c 8)" = \
			  "$(${randomBend}/bin/drandomb --seed 42 d20 -c 8)"
            ${pkgs.lib.optionalString rocSupported ''
              test -s ${randomAll}/include/randomroc.h
              test -s ${randomAll}/lib/librandomroc.a
              test -s ${randomAll}/lib/librandomroc.so
              test -s ${randomAll}/share/licenses/random-roc/LICENSE
              ${randomAll}/bin/randomroc --test
              test "$(${randomAll}/bin/random --seed 42 -c 8)" = \
                "$(${randomAll}/bin/randomroc --seed 42 -c 8)"
            ''}
            touch $out
          '';

        # On aarch64-darwin this is the macOS target gate; cross-linking it
        # from Linux currently fails inside Nixpkgs' xcbuild before Rust runs.
        checks.randomr-native = randomr;

		checks.randoml-native = pkgs.runCommand "randoml-native" { } ''
		  export HOME="$TMPDIR/home"
		  export XDG_CONFIG_HOME="$HOME/.config"
		  export XDG_CACHE_HOME="$HOME/.cache"
		  export XDG_DATA_HOME="$HOME/.local/share"
		  export XDG_STATE_HOME="$HOME/.local/state"
		  export XDG_RUNTIME_DIR="$TMPDIR/runtime"
		  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" \
		    "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
		  chmod 0700 "$XDG_RUNTIME_DIR"
		  ${randoml}/bin/randoml --test
		  ${randoml}/bin/drandoml --seed 42 --count 8 >/dev/null
		  ${randoml}/bin/nrandoml --seed 42 --count 8 >/dev/null
		  touch $out
		'';

        checks.random-crossarch = if crossSupported then
          pkgs.runCommand "random-crossarch"
            { nativeBuildInputs = testTools; } ''
              cp -r ${./.} work
              chmod -R u+w work
              cd work
            source tests/product_paths.sh
              patchShebangs bin luajit tests crossarch
              export HOME="$TMPDIR"
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
              export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
              mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
              CROSS_TOOLCHAINS=${crossToolchains} FAST=1 bash ./crossarch
              touch $out
            ''
          else pkgs.runCommand "random-crossarch-not-applicable" { } "touch $out";

        checks.randomr-cross-compile = if crossSupported then
          pkgs.runCommand "randomr-cross-compile"
            { nativeBuildInputs = [ pkgs.file ]; } ''
              test -s ${randomr}/bin/randomr
              for target in ${pkgs.lib.escapeShellArgs rustCrossTargetNames}; do
                case "$target" in
                  mswin-*) suffix=.exe ;;
                  *) suffix= ;;
                esac
                test -s ${randomrCrossTargets}/"$target"/bin/randomr"$suffix"
              done
              file ${randomrCrossTargets}/linux-arm64/bin/randomr | grep -q 'ARM aarch64'
              file ${randomrCrossTargets}/mswin-amd64/bin/randomr.exe | grep -q 'x86-64'
              file ${randomrCrossTargets}/mswin-arm64/bin/randomr.exe | grep -q 'Aarch64\|ARM64'
              touch $out
            ''
          else pkgs.runCommand "randomr-cross-compile-not-applicable" { } "touch $out";

        checks.windows-x64-smoke = if crossSupported then
          pkgs.runCommand "random-windows-x64-smoke"
            { nativeBuildInputs = runtimeTools ++ zigTools ++
                [ pkgs.wineWow64Packages.stable pkgs.coreutils ]; } ''
              cp -r ${./.} work
              chmod -R u+w work
              cd work
            source tests/product_paths.sh
              patchShebangs bin luajit
              export HOME="$TMPDIR/home"
              export WINEPREFIX="$TMPDIR/wine"
              export WINEDEBUG=-all
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
              export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
              mkdir -p "$HOME" "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
              zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu \
                --prefix "$TMPDIR/windows"
              luajit/random -d --seed 42 -b -c 131 > lua.raw
              wine "$TMPDIR/windows/bin/randomz.exe" -d --seed 42 -b -c 131 > windows.raw
              cmp lua.raw windows.raw
              RANDOMZ_CHART_TYPE=utf8 luajit/random --beta=3 --alpha=1 --view > lua.view
              RANDOMZ_CHART_TYPE=utf8 wine "$TMPDIR/windows/bin/randomz.exe" --beta=3 --alpha=1 --view > windows.view
              cmp lua.view windows.view
              wine "$TMPDIR/windows/bin/nrandomz.exe" -d --seed 42 -c 8 > alias.out
              wine "$TMPDIR/windows/bin/randomz.exe" -n -d --seed 42 -c 8 > flag.out
              cmp alias.out flag.out
              wine "$TMPDIR/windows/bin/randomz.exe" --true-random -b -c 32 > true.raw
              test "$(wc -c < true.raw)" -eq 32
              touch $out
            ''
          else pkgs.runCommand "random-windows-x64-smoke-not-applicable" { } "touch $out";

        devShells = {
          zig = pkgs.mkShell {
            packages = [ pkgs.zig_0_16 pkgs.bash pkgs.coreutils pkgs.binutils pkgs.file ];
          };
          bend2 = pkgs.mkShell {
            packages = [ bendToolchain pkgs.bun pkgs.clang ] ++
              runtimeTools ++ testTools ++ zigTools;
            BEND_NO_TELEMETRY = "1";
          };
          ziggurat = pkgs.mkShell {
            packages = [ pkgs.zig_0_16 luajitFixed pkgs.bash pkgs.jq pkgs.coreutils
              pkgs.cargo pkgs.rustc pkgs.rustfmt
              performanceProfile ];
            RANDOM_MPFR_LIBRARY = "${pkgs.mpfr}/lib/libmpfr${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
          };
          default = pkgs.mkShell ({
            packages = runtimeTools ++ testTools ++ zigTools ++ leanTools ++ rocTools ++ [ bendToolchain ] ++
              [ pkgs.cargo pkgs.clippy pkgs.rustc pkgs.rustfmt pkgs.openssh pkgs.rsync pkgs.hyperfine performanceProfile ];
            BEND_NO_TELEMETRY = "1";
            RANDOM_BEND_LIBDIR = "${randomBendLib}";
            RANDOM_BEND_PROBEDIR = "${randomBendProbe}";
            RANDOM_BEND_ARTIFACT_DIR = "${bendTestArtifacts}";
            RANDOM_BEND_ORACLE_LIBRARY = "${randomZigLib}/lib/${randomZigSharedName}";
            RANDOM_BEND_NATIVE_BENCH = pkgs.lib.optionalString (system == "x86_64-linux") "${bendBench.bendNative}/bin/bend2-bench";
            RANDOM_BEND_MODEL_MODULE = pkgs.lib.optionalString (system == "x86_64-linux") "${bendBench.bendNative}/lib/javascript/model.mjs";
            RANDOM_BEND_ZIG_BENCH = pkgs.lib.optionalString (system == "x86_64-linux") "${bendBench.zigNative}/bin/zig-bend2-bench";
            RANDOM_BEND_RUST_BENCH = pkgs.lib.optionalString (system == "x86_64-linux") "${bendBench.rustNative}/bin/rust-bend2-bench";
            RANDOM_BEND_PROBE = "${randomBendProbe}/bin/bend2-probe";
            RANDOM_BEND_LUA_CLI = "${randomLua}/bin/random";
            RANDOM_BEND_ZIG_CLI = "${randomZig}/bin/randomz";
            RANDOM_BEND_RUST_CLI = "${randomr}/libexec/randomr";
            RANDOM_BENDTT_REQUIRED = pkgs.lib.optionalString (system == "x86_64-linux") "${bendProofKernel}/bin/bendtt";
            # The geometric accuracy oracle uses exact rational arithmetic;
            RANDOM_BEND_FULL_CLI_DRIVER = pkgs.lib.optionalString (system == "x86_64-linux") "${bendBench.cliDriver}/bin/bend2-full-cli-driver";
            RANDOM_BEND_FULL_BEND_CLI = "${randomBend}/bin/randomb";
            RANDOM_BEND_FULL_LUA_CLI = "${randomLua}/bin/random";
            RANDOM_BEND_FULL_ZIG_CLI = "${randomZig}/bin/randomz";
            RANDOM_BEND_FULL_RUST_CLI = "${randomr}/libexec/randomr";
            RANDOM_BEND_FULL_LEAN_CLI = "${randoml}/bin/randoml";
            RANDOM_BEND_FULL_ROC_CLI = pkgs.lib.optionalString rocSupported "${randomRoc}/bin/randomroc";
            RANDOM_BEND_SAMPLER_BENCH = pkgs.lib.optionalString (system == "x86_64-linux") "${bendBench.bendSamplers}/bin/bend2-sampler-bench";
            RANDOM_BEND_ROC_SAMPLER_BENCH = pkgs.lib.optionalString (system == "x86_64-linux") "${bendBench.rocSamplers}/bin/roc-bend2-sampler-bench";
            # resolve its library from the derivation, never by store searches.
            RANDOM_GMP_LIBRARY = "${pkgs.gmp}/lib/libgmp${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
			RANDOM_DISTRIBUTION_PROOF_DEPS = "${distributionMathlib}/lib/lean";
            RANDOM_MPFR_LIBRARY = "${pkgs.mpfr}/lib/libmpfr${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
          } // pkgs.lib.optionalAttrs rocSupported {
            RANDOM_ROC_COMPILER = "${rocToolchain}/bin/roc";
            RANDOM_ROC_SOURCE_DIR = "${rocToolchain.src}";
            RANDOM_ROC_MUSL_LICENSE = "${pkgs.zig_0_16}/lib/zig/libc/musl/COPYRIGHT";
          });
		  proofs = pkgs.mkShell {
			packages = leanTools ++ [ pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
			RANDOM_DISTRIBUTION_PROOF_DEPS = "${distributionMathlib}/lib/lean";
		  };
        } // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          bend2-profile = pkgs.mkShell {
            packages = [ bendToolchain pkgs.nodejs luajitFixed pkgs.bash
              pkgs.coreutils pkgs.jq pkgs.time pkgs.rustfmt pkgs.git
              performanceProfile ];
            BEND_NO_TELEMETRY = "1";
            RANDOM_BEND_NATIVE_DIR = "${bendBench.bendNative}";
            RANDOM_BEND_NATIVE_BENCH = "${bendBench.bendNative}/bin/bend2-bench";
            RANDOM_BEND_MODEL_MODULE = "${bendBench.bendNative}/lib/javascript/model.mjs";
            RANDOM_BEND_ZIG_BENCH = "${bendBench.zigNative}/bin/zig-bend2-bench";
            RANDOM_BEND_RUST_BENCH = "${bendBench.rustNative}/bin/rust-bend2-bench";
            RANDOM_BEND_PROBE = "${randomBendProbe}/bin/bend2-probe";
            RANDOM_BEND_LUA_CLI = "${randomLua}/bin/random";
            RANDOM_BEND_ZIG_CLI = "${randomZig}/bin/randomz";
            RANDOM_BEND_RUST_CLI = "${randomr}/libexec/randomr";
            RANDOM_BEND_LIBDIR = "${randomBendLib}";
            RANDOM_BEND_SAMPLER_BENCH = "${bendBench.bendSamplers}/bin/bend2-sampler-bench";
            RANDOM_BEND_ROC_SAMPLER_BENCH = "${bendBench.rocSamplers}/bin/roc-bend2-sampler-bench";
            RANDOM_BEND_FULL_CLI_DRIVER = "${bendBench.cliDriver}/bin/bend2-full-cli-driver";
            RANDOM_BEND_FULL_BEND_CLI = "${randomBend}/bin/randomb";
            RANDOM_BEND_FULL_LUA_CLI = "${randomLua}/bin/random";
            RANDOM_BEND_FULL_ZIG_CLI = "${randomZig}/bin/randomz";
            RANDOM_BEND_FULL_RUST_CLI = "${randomr}/libexec/randomr";
            RANDOM_BEND_FULL_LEAN_CLI = "${randoml}/bin/randoml";
            RANDOM_BEND_FULL_ROC_CLI = "${randomRoc}/bin/randomroc";
          };
          bend2-proofs = pkgs.mkShell {
            packages = [ bendToolchain pkgs.bash pkgs.coreutils pkgs.nodejs ];
            BEND_NO_TELEMETRY = "1";
            BENDTT = "${bendProofKernel}/bin/bendtt";
            RANDOM_BENDTT_REQUIRED = "${bendProofKernel}/bin/bendtt";
          };
        } // nixpkgs.lib.optionalAttrs (nixpkgs.lib.hasSuffix "-linux" system) {
          roc = pkgs.mkShell {
            packages = runtimeTools ++ testTools ++ zigTools ++ rocTools;
            RANDOM_ROC_COMPILER = "${rocToolchain}/bin/roc";
            RANDOM_ROC_SOURCE_DIR = "${rocToolchain.src}";
            RANDOM_ROC_MUSL_LICENSE = "${pkgs.zig_0_16}/lib/zig/libc/musl/COPYRIGHT";
          };
        } // nixpkgs.lib.optionalAttrs crossSupported {
          kani = pkgs.mkShell {
            packages = [ kaniVerifier pkgs.time pkgs.jq pkgs.coreutils ];
            RANDOM_KANI_CARGO_CONFIG = pkgs.writeText "random-kani-cargo-config.toml" ''
              [source.crates-io]
              replace-with = "kani-vendor"
              [source.kani-vendor]
              directory = "${rustCargoDeps}"
            '';
          };
        };
      });
}
