{ lib, stdenv, fetchurl, autoPatchelfHook, zlib, libxml2, openssl, curl }:

# Verification-only toolchain. Nothing here replaces the production Rust pin.
let
	version = "0.68.0";
	nightly = "2026-08-21";
	components = {
		cargo = "51306dcd70ad7ea807727fb313b6a0cbc6406934ad230b6c18db79a97c539c57";
		rust-std = "52cd12570c6f967c3d04173e061fdab1cd44ab9613f53df8e04f7ce3b52ea3a3";
		rustc = "e531815fa551362b5a485e0d286b6c96555312d49359c0b8fe9e8f34c45594b4";
		rustc-dev = "175a1fb7447dc3c4407d6ea568eeb5cbe15316c8e2e4ee06a93864a466f71bdb";
	};
	archives = lib.mapAttrs (name: sha256: fetchurl {
		url = "https://static.rust-lang.org/dist/${nightly}/${name}-nightly-x86_64-unknown-linux-gnu.tar.xz";
		inherit sha256;
	}) components;
in stdenv.mkDerivation {
	pname = "random-kani";
	inherit version;
	src = fetchurl {
		url = "https://github.com/model-checking/kani/releases/download/kani-${version}/kani-${version}-x86_64-unknown-linux-gnu.tar.gz";
		sha256 = "32e2b484d73ede0bbf64a2cf0879c4259422497d8aec4ee67d448de9ae7843d3";
	};
	nativeBuildInputs = [ autoPatchelfHook ];
	buildInputs = [ stdenv.cc.cc.lib zlib libxml2 openssl curl ];
	strictDeps = true;
	dontBuild = true;
	dontStrip = true;
	installPhase = ''
		runHook preInstall
		mkdir -p "$out"
		cp -r . "$out/"
		${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: archive: ''
			tar -xf ${archive}
			bash ${name}-nightly-x86_64-unknown-linux-gnu/install.sh \
				--prefix="$out/toolchain" --disable-ldconfig
		'') archives)}
		ln -s kani-driver "$out/bin/kani"
		ln -s kani-driver "$out/bin/cargo-kani"
		runHook postInstall
	'';
	meta = {
		description = "Pinned, isolated Kani verifier for random's Rust POC";
		platforms = [ "x86_64-linux" ];
		license = with lib.licenses; [ asl20 mit ];
	};
}
