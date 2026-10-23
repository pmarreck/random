# The selection layer reuses native build graphs; compiler triples stay at
# their tool boundary while package/output namespaces use Mecha PF names.
{ pkgs, system, source, getNativePackage, rustCrossPackages, installedTestTools }:
let
	lib = pkgs.lib;
	hostPf = {
		x86_64-linux = "linux-amd64";
		aarch64-linux = "linux-arm64";
		aarch64-darwin = "macos-arm64";
	}.${system};
	platforms = [ "linux-amd64" "linux-arm64" "macos-arm64" "mswin-amd64" "mswin-arm64" ];
	profiles = [ "ReleaseFast" "ReleaseSafe" "Debug" ];
	zigTargets = {
		linux-amd64 = { gnu = "x86_64-linux-gnu"; musl = "x86_64-linux-musl"; };
		linux-arm64 = { gnu = "aarch64-linux-gnu"; musl = "aarch64-linux-musl"; };
		macos-arm64 = { "" = "aarch64-macos.14.0"; };
		mswin-amd64 = { gnu = "x86_64-windows-gnu"; };
		mswin-arm64 = { gnu = "aarch64-windows-gnu"; };
	};
	name = impl: pf: variant: profile:
		"random-build-${impl}-${pf}${lib.optionalString (variant != "") "-${variant}"}-${profile}";
	metadata = pf: variant: profile: pkgs.writeText "random-product.json" (builtins.toJSON {
		implementation = "zig";
		inherit pf profile;
		variant = if variant == "" then null else variant;
		target = zigTargets.${pf}.${variant};
		cpu = "baseline";
		minimum_os = if pf == "macos-arm64" then "14.0" else null;
	});
	zigProduct = pf: variant: profile: pkgs.stdenvNoCC.mkDerivation {
		pname = name "zig" pf variant profile;
		version = "0.4.0";
		src = source;
		strictDeps = true;
		nativeBuildInputs = [ pkgs.zig_0_16 pkgs.makeWrapper pkgs.removeReferencesTo ];
		nativeInstallCheckInputs = [ pkgs.file pkgs.binutils ];
		# Zig already implements the release strip policy, including cross outputs.
		# A native strip/fixup tool must not rewrite foreign PE or Mach-O files.
		dontStrip = true;
		dontPatchELF = true;
		buildPhase = ''
			runHook preBuild
			export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
			export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
			zig build -Doptimize=${profile} -Dtarget=${zigTargets.${pf}.${variant}} --prefix product
			runHook postBuild
		'';
		doCheck = pf == hostPf && profile == "ReleaseSafe";
		checkPhase = ''
			runHook preCheck
			zig build test -Dtarget=${zigTargets.${pf}.${variant}}
			runHook postCheck
		'';
		installPhase = ''
			runHook preInstall
			mkdir -p "$out/bin" "$out/lib" "$out/include" "$out/share" "$out/tests"
			cp -R product/lib/. "$out/lib/"
			cp -R product/include/. "$out/include/"
			cp -R product/share/. "$out/share/"
			cp -R product/tests/. "$out/tests/"
			for command in randomz nrandomz drandomz; do
			  install -m755 "product/bin/$command${lib.optionalString (lib.hasPrefix "mswin-" pf) ".exe"}" "$out/bin/"
			done
			${lib.optionalString (lib.hasPrefix "mswin-" pf) ''
			  for dll in product/bin/*.dll; do
			    [ ! -f "$dll" ] || install -m755 "$dll" "$out/bin/"
			  done
			''}
			install -m644 product/bin/randomz-wasi.wasm "$out/lib/randomz-wasi.wasm"
			remove-references-to -t ${pkgs.zig_0_16} "$out/lib/randomz-wasi.wasm"
			install -Dm644 tests/fixture-cleanup.sh "$out/tests/fixture-cleanup.sh"
			install -Dm644 ${metadata pf variant profile} "$out/share/random-build/product.json"
			chmod +x "$out/tests/random_test"
			# In strictDeps cross packages, implicit shebang discovery uses the
			# target PATH. The self-test is a build-host Bash script, not machine
			# code for that target; pin its interpreter explicitly before wrapping.
			substituteInPlace "$out/tests/random_test" \
			  --replace-fail '#!/usr/bin/env bash' '#!${pkgs.bash}/bin/bash'
			wrapProgram "$out/tests/random_test" \
			  --prefix PATH : ${lib.makeBinPath installedTestTools}
			runHook postInstall
		'';
		doInstallCheck = true;
		installCheckPhase = ''
			runHook preInstallCheck
			source build-support/core.sh
			source build-support/fs.sh
			rb_verify_product "$out" zig ${lib.escapeShellArg pf} ${lib.escapeShellArg variant} ${lib.escapeShellArg zigTargets.${pf}.${variant}}
			runHook postInstallCheck
		'';
		meta = {
			description = "Complete Zig/C Random product for ${pf}${lib.optionalString (variant != "") "/${variant}"}, ${profile}";
			license = lib.licenses.mit;
			mainProgram = "randomz";
			platforms = [ system ];
		};
		passthru = { inherit pf variant profile; compilerTarget = zigTargets.${pf}.${variant}; };
	};
	zigProducts = lib.listToAttrs (lib.concatMap (pf:
		lib.concatMap (variant: map (profile: {
			name = name "zig" pf variant profile;
			value = zigProduct pf variant profile;
		}) profiles) (builtins.attrNames zigTargets.${pf})
	) platforms);
	support = {
		rust = [ "linux-amd64" "linux-arm64" "macos-arm64" "mswin-amd64" "mswin-arm64" ];
		luajit = [ "linux-amd64" "linux-arm64" "macos-arm64" ];
		lean = [ "linux-amd64" "linux-arm64" "macos-arm64" ];
		roc = [ "linux-amd64" "linux-arm64" ];
		bend = [ "linux-amd64" "linux-arm64" "macos-arm64" ];
	};
	languageProducts = lib.listToAttrs (lib.concatMap (impl: map (pf: {
		name = name impl pf (if pf == "macos-arm64" then "" else if impl == "roc" then "musl" else "gnu") "ReleaseFast";
		value = if impl == "rust" && system == "x86_64-linux" && pf == "mswin-amd64" then
			rustCrossPackages.mswin-amd64
		else if impl == "rust" && system == "x86_64-linux" && pf == "mswin-arm64" then
			rustCrossPackages.mswin-arm64
		else if impl == "rust" && system == "x86_64-linux" && pf == "linux-arm64" then
			rustCrossPackages.linux-arm64
		else getNativePackage impl pf;
	}) support.${impl}) (builtins.attrNames support));
in zigProducts // languageProducts
