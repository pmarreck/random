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

        # LuaJIT is the only runtime dependency (ffi + bit are built in).
        runtimeTools = [ pkgs.luajit ];
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
        packages.default = random;
        packages.random = random;

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
