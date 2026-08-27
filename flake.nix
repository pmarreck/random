{
  description = "Cross-platform-identical deterministic CSPRNG and OS-entropy random CLI with alternate distributions";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
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
          ln -s ${pkgs.zig_0_16}/bin/zig $out/bin/zig
          ln -s ${randomr}/bin/randomr $out/bin/randomr-x86_64-glibc
          ln -s ${randomrCrossAarch64}/bin/randomr $out/bin/randomr-aarch64-glibc
        '';

        # LuaJIT is the only runtime dependency (ffi + bit are built in).
        runtimeTools = [ luajitFixed ];
        # External tools the executable shells out to / the test suite needs.
        testTools = with pkgs; [
          bashInteractive coreutils gnugrep ripgrep gawk bc xxd binutils gnutar
          stdenv.cc libsixel imagemagick nodejs wasm-tools
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

		mkRandomr = rustPkgs: runTests: rustPkgs.rustPlatform.buildRustPackage {
		  pname = "random-rust";
          version = "0.3.0";
          src = ./.;
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
		  version = "0.3.0";
		  src = ./.;
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
		  version = "0.3.0";
		  src = ./.;
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
		randoml = pkgs.stdenv.mkDerivation {
		  pname = "random-lean";
          version = "0.3.0";
          src = ./.;
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
		  version = "0.3.0";
		  src = ./.;
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
			description = "Importable LuaJIT numeric, BLAKE3, chart, and state modules";
			license = licenses.mit;
			platforms = platforms.unix;
		  };
		};
		randomLuaNativeBuildInputs = [ pkgs.makeWrapper pkgs.bash ];
		randomLua = pkgs.stdenvNoCC.mkDerivation {
		  pname = "random-luajit";
		  version = "0.3.0";
		  src = ./.;
		  strictDeps = true;
		  nativeBuildInputs = randomLuaNativeBuildInputs;
		  dontBuild = true;
		  installPhase = ''
			runHook preInstall
			mkdir -p $out/bin $out/tests $out/share/licenses/random-luajit
			install -Dm755 bin/random $out/bin/random
			ln -s ${randomLuaLib}/lib $out/lib
			install -Dm755 tests/random_test $out/tests/random_test
			install -Dm644 tests/cli_test_setup.sh $out/tests/cli_test_setup.sh
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
		  version = "0.3.0";
		  src = ./.;
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
			ln -s ${./.} $out/src
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
		  version = "0.3.0";
		  src = ./.;
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
		randomAll = pkgs.runCommand "random-all-0.3.0" {
		  meta = with pkgs.lib; {
			description = "Aggregate LuaJIT, Zig/C, Rust, and Lean random CSPRNG distribution";
			license = licenses.mit;
			platforms = platforms.unix;
			mainProgram = "random";
		  };
		} ''
		  mkdir -p $out/bin $out/lib $out/libexec $out/include \
			$out/share/licenses
		  ln -s ${randomLua}/bin/* ${randomZig}/bin/* ${randomr}/bin/* \
			${randoml}/bin/* $out/bin/
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
		'';

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
          "linux-aarch64"
          "windows-x86_64"
        ];
        rustCrossSets = if crossSupported then {
          linux-aarch64 = crossWithUnsupported pkgs.pkgsCross.aarch64-multiplatform;
          windows-x86_64 = crossWithUnsupported pkgs.pkgsCross.mingw-ucrt-x86_64;
        } else { };
        randomrCrossPackages = pkgs.lib.mapAttrs
          (_name: rustPkgs: mkRandomr rustPkgs false)
          rustCrossSets;
        randomrCrossAarch64 = if crossSupported then
          randomrCrossPackages.linux-aarch64
        else null;
        randomrCrossTargets = assert
          builtins.attrNames rustCrossSets == rustCrossTargetNames;
          pkgs.linkFarm "randomr-cross-targets"
            (pkgs.lib.mapAttrsToList (name: path: { inherit name path; })
              randomrCrossPackages);
		leanLibraryConsumer = pkgs.writeText "randoml-library-consumer.lean"
		  (builtins.concatStringsSep "\n" [
			"import Randoml"
			"#check Randoml.Drbg.init"
			"#check Randoml.normal"
			"example : Randoml.maxExactPosition = 9007199254740992 := rfl"
		  ] + "\n");
      in {
        # The conditional attribute is merged INSIDE `packages`, not by `//`-ing
        # a second `{ packages.crossToolchains = ...; }` onto the outputs set.
        # `//` is a SHALLOW merge, so that form silently replaced the whole
        # `packages` attribute -- default, random and luajitPinned all vanished
        # and only crossToolchains survived. `nix flake check` did not catch it
        # (it exercised `checks.*`, which was untouched); Mechatron Prime did,
        # with "target failed: packages.x86_64-linux.default".
        packages = {
		  # Preserve the historical default for compatibility, but expose its
		  # aggregate nature explicitly so consumers can select one implementation.
          default = randomAll;
          random-all = randomAll;
		  random-luajit = randomLua;
		  random-zig = randomZig;
		  random-rust = randomr;
		  random-lean = randoml;
		  random-luajit-lib = randomLuaLib;
		  random-zig-lib = randomZigLib;
		  random-rust-lib = randomRustLib;
		  random-lean-lib = randomLeanLib;

		  # Compatibility aliases. Language-named aliases now resolve to their
		  # minimal package; `random` remains the historical aggregate alias.
          random = randomAll;
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
        } // nixpkgs.lib.optionalAttrs crossSupported {
          # Only meaningful on x86_64-linux: pkgsCross/pkgsMusl and qemu-user are
          # what make the aarch64 and musl legs buildable from this host at all.
          crossToolchains = crossToolchains;
          randomrAarch64 = randomrCrossAarch64;
          randomrCrossTargets = randomrCrossTargets;
        };

        apps.randomz = {
          type = "app";
          program = "${randomZig}/bin/randomz";
          meta.description = "Run the C CLI over the Zig randomz library";
        };

        apps.randomr = {
          type = "app";
          program = "${randomr}/bin/randomr";
          meta.description = "Run the Rust randomr CLI";
        };

        apps.randoml = {
          type = "app";
          program = "${randoml}/bin/randoml";
          meta.description = "Run the independent Lean implementation";
        };

        # Hermetic CI check: runs the FULL suite runner (./test), not just
        # tests/random_test, so fixed_test/golden_test/kernel_bc_sweep are
        # actually exercised here too, not just the CLI-behavior suite.
        checks.random-test = pkgs.runCommand "random-test"
          {
            nativeBuildInputs = runtimeTools ++ testTools ++ zigTools ++ rustTools ++ leanTools;
            cargoDeps = rustCargoDeps;
          } ''
            cp -r ${./.} work
            chmod -R u+w work
            cd work
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
            patchShebangs bin tests lean/build-owned-cli
            export HOME="$TMPDIR"
            export PATH="$PWD/bin:$PATH"
            # ./test sets RANDOM_TEST_FILE itself; FAST=1 keeps this hermetic
            # check fast (kernel_jit_diff is deep-mode-only by design — see
            # its own header comment).
            FAST=1 bash ./test
            touch $out
          '';

        checks.stats-smoke = pkgs.runCommand "random-stats-smoke"
          {
            nativeBuildInputs = runtimeTools ++ testTools ++ zigTools ++ rustTools ++ leanTools;
            cargoDeps = rustCargoDeps;
          } ''
            cp -r ${./.} work
            chmod -R u+w work
            cd work
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
            patchShebangs bin tests stats lean/build-owned-cli
            export HOME="$TMPDIR"
            export PATH="$PWD/bin:$PATH"
            FAST=1 RANDOM_STATS_SKIP_TRUE=1 bash ./stats --all
            touch $out
          '';

		checks.package-split = assert pkgs.lib.assertMsg
		  luaDeclaredBuildInputsClean
		  "random-luajit has a Zig, Rust/Cargo, or Lean direct build input";
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

			# The backwards-compatible default is the documented aggregate and
			# therefore exposes every implementation.
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
			  pkgs.rustPlatform.cargoSetupHook
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
			(cd "$TMPDIR/rust-consumer" && cargo check --offline)

			# The compiled Lean library imports without the CLI derivation or sources.
			LEAN_PATH=${randomLeanLib}/lib/lean lean ${leanLibraryConsumer}
			touch $out
		  '';

        checks.package-smoke = pkgs.runCommand "random-package-smoke"
          { nativeBuildInputs = [ pkgs.stdenv.cc pkgs.wasm-tools ]; } ''
            export HOME="$TMPDIR/home"
            export XDG_CONFIG_HOME="$HOME/.config"
            export XDG_CACHE_HOME="$HOME/.cache"
            export XDG_DATA_HOME="$HOME/.local/share"
            export XDG_STATE_HOME="$HOME/.local/state"
            export XDG_RUNTIME_DIR="$TMPDIR/runtime"
            mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" \
              "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
            chmod 0700 "$XDG_RUNTIME_DIR"
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
              patchShebangs bin tests crossarch
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
                  windows-*) suffix=.exe ;;
                  *) suffix= ;;
                esac
                test -s ${randomrCrossTargets}/"$target"/bin/randomr"$suffix"
              done
              file ${randomrCrossTargets}/linux-aarch64/bin/randomr | grep -q 'ARM aarch64'
              file ${randomrCrossTargets}/windows-x86_64/bin/randomr.exe | grep -q 'x86-64'
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
              patchShebangs bin
              export HOME="$TMPDIR/home"
              export WINEPREFIX="$TMPDIR/wine"
              export WINEDEBUG=-all
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
              export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
              mkdir -p "$HOME" "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
              zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu \
                --prefix "$TMPDIR/windows"
              bin/random -d --seed 42 -b -c 131 > lua.raw
              wine "$TMPDIR/windows/bin/randomz.exe" -d --seed 42 -b -c 131 > windows.raw
              cmp lua.raw windows.raw
              RANDOMZ_CHART_TYPE=utf8 bin/random --beta=3 --alpha=1 --view > lua.view
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

        devShells.default = pkgs.mkShell {
          packages = runtimeTools ++ testTools ++ zigTools ++ leanTools ++
            [ pkgs.cargo pkgs.clippy pkgs.rustc pkgs.rustfmt pkgs.openssh pkgs.rsync ];
        };
      });
}
