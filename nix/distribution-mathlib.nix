{ pkgs }:
let
	# Match lean/lean-toolchain exactly. Dependencies are the upstream manifest
	# at this revision, not the floating branches mentioned by its Lake file.
	source = repository: rev: hash: pkgs.fetchFromGitHub {
		owner = builtins.head (pkgs.lib.splitString "/" repository);
		repo = builtins.elemAt (pkgs.lib.splitString "/" repository) 1;
		inherit rev hash;
	};
	mathlib = source "leanprover-community/mathlib4"
		"c5ea00351c28e24afc9f0f84379aa41082b1188f"
		"sha256-RxOxdUiVUAxUbfVhxlkjmPX1V64EtmIIn1eW75TiJWA=";
	dependencies = {
		plausible = source "leanprover-community/plausible"
			"a456461b368b71d2accd95234832cd9c174b5437"
			"sha256-DSaS0W2cfCUh2N+7WyiM7aUv3trtRNON0PzCgCW2SKY=";
		LeanSearchClient = source "leanprover-community/LeanSearchClient"
			"c5d5b8fe6e5158def25cd28eb94e4141ad97c843"
			"sha256-L2aAwn3OeRLVt/VccLdBS0ogqmIIKAwnz94PpAOhaRc=";
		importGraph = source "leanprover-community/import-graph"
			"515cf9d0c00ece5e661f6de4326a53dedc1e8ea1"
			"sha256-V3bGQxTNs2G4MqaVxRb6WED1a7VaHfEo1HgBNqPipz8=";
		proofwidgets = source "leanprover-community/ProofWidgets4"
			"a84b3e2475d5c5ab979567b1ad8aea21b764bcf8"
			"sha256-kGoEkKGrucNUWFYkHW2LsS1gI4C0J8bAHQL2MiE4Pzc=";
		aesop = source "leanprover-community/aesop"
			"558915ae105bfd8074e22d597613d1961822adc2"
			"sha256-7PhQVMdiYImuzRYdf0Kgw3JYS4nBLfILXxyhFH8Zag0=";
		Qq = source "leanprover-community/quote4"
			"a6e6c34c4ef182f83b219a3a5a385f51f44bdc4c"
			"sha256-jVsRw/R7D7HmsE7vQvVeDXcnVerlcDBOrhf9FJJiXkY=";
		batteries = source "leanprover-community/batteries"
			"32dc18cde3684679f3c003de608743b57498c56f"
			"sha256-OOcKCQEgnn9zkkwjHOovMb/IprNomTDufLOfEXs7hFU=";
		Cli = source "leanprover/lean4-cli"
			"6b907cf12b2e445ccb7c24bc208ef04a1f39e84c"
			"sha256-oMaqHvWlEfk1601JfNKPvkGIWgMW6tiF7Mej7g63vh0=";
	};
	overrides = pkgs.writeText "mathlib-package-overrides.json" (builtins.toJSON {
		version = "1.2.0";
		packages = pkgs.lib.mapAttrsToList (name: _: {
			inherit name;
			inherited = false;
			type = "path";
			dir = ".lake/packages/${name}";
			configFile = if name == "proofwidgets" then "lakefile.lean" else "lakefile.toml";
		}) dependencies;
	});
in pkgs.stdenv.mkDerivation {
	pname = "random-distribution-mathlib";
	version = "4.30.0";
	src = mathlib;
	strictDeps = true;
	nativeBuildInputs = [ pkgs.lean4 pkgs.git pkgs.curl pkgs.cacert ];
	# The precompiled upstream dependencies are fetched only in this hash-pinned
	# network boundary. Production packages do not refer to this proof closure.
	outputHashMode = "recursive";
	outputHashAlgo = "sha256";
	outputHash = "sha256-AQEZj5qwpdWlQwNAigCHXK6176Nhf5G4B8UN8OA+RLk=";
	buildPhase = ''
		runHook preBuild
		export MATHLIB_CACHE_DIR="$TMPDIR/mathlib-cache"
		export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
		mkdir -p .lake/packages
		${pkgs.lib.concatStringsSep "\n" (pkgs.lib.mapAttrsToList (name: path: ''
			cp -R ${path} .lake/packages/${name}
			chmod -R u+w .lake/packages/${name}
		'') dependencies)}
		lake --packages=${overrides} build cache
		lake --packages=${overrides} exe cache get --repo=leanprover-community/mathlib4 \
			Mathlib.Probability.Distributions.Geometric \
			Mathlib.Probability.Distributions.Exponential \
			Mathlib.Probability.Distributions.Uniform \
			Mathlib.Analysis.SpecialFunctions.Log.Basic \
			Mathlib.Tactic
		runHook postBuild
	'';
	installPhase = ''
		runHook preInstall
		mkdir -p "$out/lib/lean" "$out/share/licenses"
		copyImports() {
			(cd "$1" && find . -type f \
				\( -name '*.olean' -o -name '*.olean.private' -o -name '*.olean.server' \
				-o -name '*.ir' \) -exec cp --parents -t "$out/lib/lean" '{}' +)
		}
		copyImports .lake/build/lib/lean
		${pkgs.lib.concatStringsSep "\n" (pkgs.lib.mapAttrsToList (name: _: ''
			if test -d .lake/packages/${name}/.lake/build/lib/lean; then
				copyImports .lake/packages/${name}/.lake/build/lib/lean
			fi
			cp .lake/packages/${name}/LICENSE "$out/share/licenses/${name}-LICENSE"
		'') dependencies)}
		cp LICENSE "$out/share/licenses/mathlib-LICENSE"
		# Lake traces and generated native object code are irrelevant to import
		# elaboration. Retain the split olean/IR files Lean 4.30 actually loads.
		runHook postInstall
	'';
	dontFixup = true;
	meta = {
		description = "Pinned mathematical dependencies for Randoml distribution proofs only";
		license = [ pkgs.lib.licenses.asl20 pkgs.lib.licenses.mit ];
		platforms = pkgs.lib.platforms.unix;
	};
}
