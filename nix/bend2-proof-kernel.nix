# The experimental Bend verdict has its own Lean pin; never replace randoml's.
{ pkgs, upstream }:
let
  lean = pkgs.stdenv.mkDerivation {
    pname = "lean4-bend2-kernel-toolchain";
    version = "4.34.0";
    src = pkgs.fetchurl {
      url = "https://github.com/leanprover/lean4/releases/download/v4.34.0/lean-4.34.0-linux.tar.zst";
      sha256 = "caaa98356098c85dc0fcbbd28e1ec66f39eb6551829972b752ff20e1286b646b";
    };
    strictDeps = true;
    nativeBuildInputs = [ pkgs.autoPatchelfHook pkgs.zstd ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib pkgs.gmp pkgs.zlib ];
    dontBuild = true;
    dontStrip = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r . $out/
      patchShebangs $out/bin
      runHook postInstall
    '';
    meta = {
      description = "Isolated pinned Lean toolchain for the experimental Bend proof kernel";
      license = pkgs.lib.licenses.asl20;
      platforms = [ "x86_64-linux" ];
    };
  };
  audit = pkgs.writeText "bend2-kernel-audit.lean" ''
    import bendtt
    #print axioms consistent
    #print axioms halts
  '';
in pkgs.stdenv.mkDerivation {
  pname = "random-bend2-proof-kernel";
  version = "2.0.37";
  src = upstream + "/bend2/bendtt.lean";
  dontUnpack = true;
  strictDeps = true;
  nativeBuildInputs = [ lean pkgs.time ];
  buildPhase = ''
    runHook preBuild
    test "$(lean --version | cut -d, -f1)" = 'Lean (version 4.34.0'
    cp $src bendtt.lean
    ${pkgs.time}/bin/time -f 'kernel elaboration: %e s wall; %M KiB peak RSS' \
      lean -t0 -c bendtt.c -o bendtt.olean bendtt.lean
    LEAN_PATH=. lean -t0 ${audit} > axioms.log
    ${pkgs.time}/bin/time -f 'kernel C compilation: %e s wall; %M KiB peak RSS' \
      leanc -O3 -DNDEBUG bendtt.c -o bendtt
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/random-bend2-proof-kernel
    install -m755 bendtt $out/bin/bendtt
    install -m644 axioms.log $out/share/random-bend2-proof-kernel/
    install -Dm644 ${upstream}/LICENSE $out/share/licenses/random-bend2-proof-kernel/Bend-LICENSE
    install -Dm644 ${lean}/LICENSE $out/share/licenses/random-bend2-proof-kernel/Lean-LICENSE
    install -Dm644 ${lean}/LICENSES $out/share/licenses/random-bend2-proof-kernel/Lean-LICENSES
    lean --version > $out/share/random-bend2-proof-kernel/lean-version
    runHook postInstall
  '';
  meta = {
    description = "Lean-built BendTT verdict kernel with recorded headline axiom dependencies";
    license = pkgs.lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
  };
}
