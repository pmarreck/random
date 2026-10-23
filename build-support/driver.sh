# shellcheck shell=bash
# Thin build adapters. Native graphs compile; this layer selects and publishes.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fs.sh"

rb_nix_system() {
	case "$1" in
		linux-amd64) printf x86_64-linux ;; linux-arm64) printf aarch64-linux ;;
		macos-arm64) printf aarch64-darwin ;;
		*) rb_error 'Nix does not run natively on this platform; use --backend=direct with Zig installed'; return 1 ;;
	esac
}

rb_build_one() {
	local root="$1" request="$2" impl pf variant profile triple parent attribute system
	IFS='|' read -r impl pf variant profile triple <<<"$request"
	if [ "$RB_BACKEND" = nix ]; then
		system="$(rb_nix_system "$RB_HOST")" || return 1
		attribute="random-build-$impl-$pf"
		[ -z "$variant" ] || attribute="$attribute-$variant"
		attribute="$attribute-$profile"
		parent="$root/.nix-out/$impl/$pf"
		[ -z "$variant" ] || parent="$parent/$variant"
		parent="$parent/$profile"
		mkdir -p "$parent" || return 1
		RB_PRODUCT="$parent/$RB_GENERATION"
		# A Git-backed flake excludes untracked/ignored build trees. Every new
		# source must be reviewed and staged before invoking this adapter.
		nix build "$root#packages.$system.$attribute" --out-link "$RB_PRODUCT" "${RB_NIX_ARGS[@]}" || return 1
	else
		parent="$root/.build-work/products/$impl/$pf"
		[ -z "$variant" ] || parent="$parent/$variant"
		RB_PRODUCT="$parent/$profile/$RB_GENERATION"
		[ ! -e "$RB_PRODUCT" ] && [ ! -L "$RB_PRODUCT" ] || { rb_error "direct build prefix already exists: $RB_PRODUCT"; return 1; }
		mkdir -p "$RB_PRODUCT" || return 1
		(
			cd "$root" || exit 1
			if [ "$RB_TEST" -eq 1 ]; then
				zig build test "-Dtarget=$triple" || exit 1
			fi
			zig build "-Doptimize=$profile" "-Dtarget=$triple" --prefix "$RB_PRODUCT"
		) || return 1
	fi
}

rb_help() {
	printf '%s\n' \
		'Usage: ./build [options]' \
		'       ./build canonize IMPL' \
		'' \
		'Default: build CANONICAL_IMPL for this execution platform using Nix.' \
		'Canonize records a selection without building or switching commands.' \
		'Implementations: zig, rust, luajit, lean, roc, bend (experimental).' \
		'Platforms: linux-amd64, linux-arm64, macos-arm64, mswin-amd64, mswin-arm64.' \
		'' \
		'  --all-impls, --all-implementations  All declared implementations on this host' \
		'  --all-plats, --all-platforms       Canonical implementation on its declared platforms' \
		'  --all                             Expand both independent scopes' \
		'  --impl IMPL                       Build one implementation without canonizing it' \
		'  --platform PF                     Build one declared target platform' \
		'  --variant gnu|musl                Select a declared ABI (omit on macOS)' \
		'  --profile ReleaseFast|ReleaseSafe|Debug  ReleaseFast by default' \
		'  --debug / --test                  Zig Debug / ReleaseSafe plus native unit tests' \
		'  --backend nix|direct              Direct Zig graph; Nix is the default' \
		'  -L, --print-build-logs             Forward Nix build logs' \
		'  -- NIX-ARGS                       Forward remaining Nix arguments verbatim' \
		'' \
		'Unsupported required builders fail; --all never silently shrinks its matrix.' \
		'Products: IMPL-out/PF/[VARIANT/]PROFILE; commands: bin/PF/.' \
		'Only a successful canonical build publishes random, nrandom and drandom.'
}

rb_main() {
	local root="$1" canonical transaction request impl pf variant profile triple product publication failed=0 index
	shift
	if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then rb_help; return 0; fi
	if [ "${1:-}" = canonize ]; then
		[ "$#" -eq 2 ] || { rb_error 'use ./build canonize IMPL without build flags'; return 1; }
		rb_canonize "$root" "$2"
		return $?
	fi
	canonical="$(rb_read_selection "$root")" || return 1
	RB_HOST="$(rb_platform "$(uname -s)" "$(uname -m)")" || return 1
	rb_plan "$canonical" "$RB_HOST" "$@" || return 1
	mkdir -p "$root/.build-work/transactions" || return 1
	transaction="$(mktemp -d "$root/.build-work/transactions/build.XXXXXX")" || return 1
	RB_GENERATION="${transaction##*/}"
	RB_PRODUCTS=() RB_HOST_ENTRY=
	for request in "${RB_PLAN[@]}"; do
		IFS='|' read -r impl pf variant profile triple <<<"$request"
		printf 'Building %s for %s%s (%s, %s)...\n' "$impl" "$pf" "${variant:+/$variant}" "$profile" "$RB_BACKEND" >&2
		if rb_build_one "$root" "$request"; then
			product="$RB_PRODUCT"
			if rb_verify_product "$product" "$impl" "$pf" "$variant" "$triple"; then
				local variant_json=null cpu=package-default
				[ -z "$variant" ] || variant_json="\"$variant\""
				[ "$impl" != zig ] || cpu=baseline
				# All string fields come from the admitted registry, never shell
				# expressions. Keep a target/profile receipt next to this generation.
				printf '{"implementation":"%s","pf":"%s","variant":%s,"profile":"%s","target":"%s","cpu":"%s","backend":"%s"}\n' \
					"$impl" "$pf" "$variant_json" "$profile" "$triple" "$cpu" "$RB_BACKEND" \
					>"$transaction/$impl-$pf${variant:+-$variant}-$profile.json" || return 1
				RB_PRODUCTS+=("$product")
				continue
			fi
		fi
		failed=$((failed + 1))
		RB_PRODUCTS+=("")
		printf 'Build/verification failed: %s/%s%s\n' "$impl" "$pf" "${variant:+/$variant}" >&2
	done
	[ "$failed" -eq 0 ] || { rb_error "$failed requested build(s) failed; previous public commands were preserved"; return 1; }
	# Keep the product selection separate from the compiler destination. Direct
	# builds always use fresh owned directories, even after a Nix publication.
	for ((index=0; index<${#RB_PLAN[@]}; index++)); do
		rb_select_product "$root" "${RB_PLAN[$index]}" "${RB_PRODUCTS[$index]}" || return 1
	done
	for ((index=0; index<${#RB_PLAN[@]}; index++)); do
		request="${RB_PLAN[$index]}" product="${RB_PRODUCTS[$index]}"
		IFS='|' read -r impl pf variant profile triple <<<"$request"
		[ "$impl" = "$canonical" ] || continue
		local mode=link
		[[ "$RB_HOST" != mswin-* ]] || mode=copy
		publication="$(rb_publish "$root" "$canonical" "$request" "$product" "$mode")" || return 1
		if [ "$pf" = "$RB_HOST" ]; then
			RB_HOST_ENTRY="$publication/random"
			[[ "$pf" != mswin-* ]] || RB_HOST_ENTRY="$RB_HOST_ENTRY.exe"
		fi
		printf 'Published %s commands in bin/%s/ (%s%s, %s).\n' "$impl" "$pf" "$pf" "${variant:+/$variant}" "$profile"
	done
}
