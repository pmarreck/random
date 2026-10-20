{ pkgs, bendToolchain, randomZigLib, upstream }:
{
  bendNative = pkgs.stdenv.mkDerivation {
    pname = "random-bend2-bench-experimental";
    version = "0.4.0";
    src = ../.;
    strictDeps = true;
    nativeBuildInputs = [ bendToolchain pkgs.clang pkgs.time ];
    BEND_NO_TELEMETRY = "1";
    stripDebugList = [ ];
    stripAllList = [ "bin" ];
    buildPhase = ''
      runHook preBuild
      ${pkgs.time}/bin/time -o native-compiler-cost.json \
        -f '{"wall_seconds":%e,"peak_rss_kib":%M}' \
        bend bend/Benchmark.bend -o bend2-bench
      ${pkgs.time}/bin/time -o model-compiler-cost.json \
        -f '{"wall_seconds":%e,"peak_rss_kib":%M}' \
        bend bend/BenchmarkModel.bend -o model.mjs
      bend tests/fixtures/bend2-clock.bend -o bend2-clock-test
      sha256sum bend/Core.bend bend/ProbeModel.bend bend/BenchmarkModel.bend \
        bend/Benchmark.bend bend/Clock.bend bend/clock.c bend/clock.js \
        bend/rss.c bend/rss.js bend/optimized.c bend/optimized.js \
        tests/fixtures/bend2-clock.bend > source.sha256
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin $out/lib/javascript $out/share/random-bend2-bench
      install -m755 bend2-bench bend2-clock-test $out/bin/
      install -m644 model.mjs $out/lib/javascript/
      install -m644 source.sha256 native-compiler-cost.json model-compiler-cost.json \
        $out/share/random-bend2-bench/
      install -Dm644 LICENSE $out/share/licenses/random-bend2-bench/LICENSE
      install -Dm644 ${upstream}/LICENSE $out/share/licenses/random-bend2-bench/Bend-LICENSE
      runHook postInstall
    '';
    meta = {
      platforms = [ "x86_64-linux" ];
      license = with pkgs.lib.licenses; [ mit asl20 ];
    };
  };
  zigNative = pkgs.stdenv.mkDerivation {
    pname = "random-zig-bend2-comparison-probe";
    version = "0.4.0";
    src = ../.;
    strictDeps = true;
    buildInputs = [ randomZigLib ];
    stripDebugList = [ ];
    stripAllList = [ "bin" ];
    buildPhase = ''
      runHook preBuild
      $CC -std=c11 -D_POSIX_C_SOURCE=200809L -O3 -Wall -Wextra -Werror \
        -I${randomZigLib}/include experiments/bend2_zig_bench.c \
        -L${randomZigLib}/lib -Wl,-rpath,${randomZigLib}/lib -lrandomz -o zig-bend2-bench
      find src -type f -print0 | sort -z | xargs -0 sha256sum > source.sha256
      find include -type f -print0 | sort -z | xargs -0 sha256sum >> source.sha256
      sha256sum experiments/bend2_zig_bench.c build.zig build.zig.zon >> source.sha256
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 zig-bend2-bench $out/bin/zig-bend2-bench
      install -Dm644 source.sha256 $out/share/random-zig-bend2-bench/source.sha256
      runHook postInstall
    '';
    meta.platforms = [ "x86_64-linux" ];
  };
  rustNative = pkgs.rustPlatform.buildRustPackage {
    pname = "random-rust-bend2-comparison-probe";
    version = "0.4.0";
    src = ../.;
    cargoLock.lockFile = ../Cargo.lock;
    cargoBuildFlags = [ "-p" "randomr" "--example" "bend2_bench" ];
    doCheck = false;
    postBuild = ''
      find rust/randomr/src -type f -print0 | sort -z | xargs -0 sha256sum > source.sha256
      sha256sum rust/randomr/examples/bend2_bench.rs rust/randomr/Cargo.toml Cargo.toml Cargo.lock >> source.sha256
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 target/${pkgs.stdenv.hostPlatform.rust.rustcTarget}/release/examples/bend2_bench \
        $out/bin/rust-bend2-bench
      install -Dm644 source.sha256 $out/share/random-rust-bend2-bench/source.sha256
      runHook postInstall
    '';
    meta.platforms = [ "x86_64-linux" ];
  };
}
