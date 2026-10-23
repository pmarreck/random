{ pkgs, source, cargoDeps }:
let
	version = "1.97.1";
	target = "aarch64-pc-windows-gnullvm";
	# This is the same published target and Zig linker as the standalone
	# Windows ARM64 gate, without a rustup download during a sandboxed build.
	components = {
		"rust-std-${target}" = "1079377ea603055be2430d342f5ac4cc7b4eb60f9144c41c7e414ec465d7d61e";
		rust-std-x86_64-unknown-linux-gnu = "1c1e704ae80126b7de34f72ea2825f7fd01736dec20732faed47374b95282fba";
	};
	archives = pkgs.lib.mapAttrs (component: sha256: pkgs.fetchurl {
		url = "https://static.rust-lang.org/dist/${builtins.replaceStrings [ "rust-std-" ] [ "rust-std-${version}-" ] component}.tar.xz";
		inherit sha256;
	}) components;
	toolchain = pkgs.stdenvNoCC.mkDerivation {
		pname = "random-rust-windows-arm64-toolchain";
		inherit version;
		src = pkgs.fetchurl {
			url = "https://static.rust-lang.org/dist/rustc-${version}-x86_64-unknown-linux-gnu.tar.xz";
			sha256 = "9819d0a32d56bd339585319c80260e332779f5541fd66838ab7e016d6c814819";
		};
		nativeBuildInputs = [ pkgs.autoPatchelfHook ];
		buildInputs = [ pkgs.stdenv.cc.cc.lib pkgs.zlib pkgs.libxml2 ];
		dontBuild = true;
		dontStrip = true;
		installPhase = ''
			runHook preInstall
			bash install.sh --prefix="$out" --disable-ldconfig
			${pkgs.lib.concatStringsSep "\n" (pkgs.lib.mapAttrsToList (component: archive: ''
				tar -xf ${archive} -C "$TMPDIR"
				bash "$TMPDIR/${builtins.replaceStrings [ "rust-std-" ] [ "rust-std-${version}-" ] component}/install.sh" \
				  --prefix="$out" --disable-ldconfig
			'') archives)}
			runHook postInstall
		'';
	};
in assert pkgs.rustc.version == version;
pkgs.stdenv.mkDerivation {
	pname = "random-rust-mswin-arm64";
	version = "0.4.0";
	src = source;
	inherit cargoDeps;
	strictDeps = true;
	nativeBuildInputs = [ pkgs.cargo pkgs.rustPlatform.cargoSetupHook pkgs.zig_0_16 ];
	dontStrip = true;
	dontPatchELF = true;
	buildPhase = ''
		runHook preBuild
		export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
		export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
		mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
		for linker in tools/zig-rust-linker tools/zig-aarch64-windows-linker; do
		  substituteInPlace "$linker" --replace-fail '#!/usr/bin/env bash' '#!${pkgs.bash}/bin/bash'
		done
		export CARGO_TARGET_AARCH64_PC_WINDOWS_GNULLVM_LINKER="$PWD/tools/zig-aarch64-windows-linker"
		# Rust rlib metadata also distinguishes an official compiler from a
		# source-tarball build of the same commit. Keep compiler and both standard
		# libraries from the same published release, including host build scripts.
		export RUSTC=${toolchain}/bin/rustc
		export RUSTDOC=${toolchain}/bin/rustdoc
		cargo build --frozen --release -p randomr-cli --target ${target}
		runHook postBuild
	'';
	installPhase = ''
		runHook preInstall
		mkdir -p "$out/bin" "$out/share/licenses/random-rust"
		for command in randomr nrandomr drandomr; do
		  install -m755 target/${target}/release/randomr.exe "$out/bin/$command.exe"
		done
		install -m644 LICENSE "$out/share/licenses/random-rust/LICENSE"
		cp -R ${toolchain}/share/doc/rust "$out/share/licenses/random-rust/rust-toolchain"
		runHook postInstall
	'';
	doInstallCheck = true;
	installCheckPhase = ''
		runHook preInstallCheck
		source build-support/core.sh
		source build-support/fs.sh
		rb_verify_product "$out" rust mswin-arm64 gnu ${target}
		runHook postInstallCheck
	'';
	meta = {
		description = "Standalone Rust Random CLI for Windows ARM64";
		license = pkgs.lib.licenses.mit;
		mainProgram = "randomr.exe";
		platforms = [ "x86_64-linux" ];
	};
}
