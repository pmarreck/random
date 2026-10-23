# shellcheck shell=bash
# Pure build request planning. Filesystem and compiler effects are separate ports.

RB_IMPLEMENTATIONS=(zig rust luajit lean roc bend)
RB_PLATFORMS=(linux-amd64 linux-arm64 macos-arm64 mswin-amd64 mswin-arm64)

rb_error() { printf 'random build: %s\n' "$*" >&2; return 1; }

rb_known_impl() {
	case "$1" in zig|rust|luajit|lean|roc|bend) return 0 ;; esac
	rb_error "unknown implementation '$1'; choose zig, rust, luajit, lean, roc or bend"
}

# Normalize the execution environment, never the physical host underneath WSL.
rb_platform() {
	local os arch
	case "$1" in
		Linux|linux) os=linux ;;
		Darwin|darwin|macos) os=macos ;;
		Windows_NT|Windows|mswin|MINGW*|MSYS*|CYGWIN*) os=mswin ;;
		*) rb_error "unsupported execution OS '$1'"; return 1 ;;
	esac
	case "$2" in
		x86_64|amd64|AMD64) arch=amd64 ;;
		aarch64|arm64|ARM64) arch=arm64 ;;
		*) rb_error "unsupported execution architecture '$2'"; return 1 ;;
	esac
	rb_known_platform "$os-$arch" || return 1
	printf '%s\n' "$os-$arch"
}

rb_known_platform() {
	case "$1" in linux-amd64|linux-arm64|macos-arm64|mswin-amd64|mswin-arm64) return 0 ;; esac
	rb_error "unsupported platform '$1'; use a declared Mecha OS-ARCH pair"
}

# These are build definitions, not claims of native execution on every target.
rb_supported() {
	case "$1:$2" in
		zig:*) rb_known_platform "$2" ;;
		rust:linux-*|rust:macos-arm64|rust:mswin-amd64|rust:mswin-arm64) return 0 ;;
		luajit:linux-*|luajit:macos-arm64|lean:linux-*|lean:macos-arm64|bend:linux-*|bend:macos-arm64) return 0 ;;
		roc:linux-*) return 0 ;;
		*) return 1 ;;
	esac
}

rb_default_variant() {
	case "$1:$2" in zig:linux-*|roc:linux-*) printf musl ;; *:linux-*|*:mswin-*) printf gnu ;; esac
}

rb_triple() {
	local impl="$1" pf="$2" variant="$3"
	case "$impl:$pf" in
		zig:linux-amd64|roc:linux-amd64) printf 'x86_64-linux-%s' "$variant" ;;
		zig:linux-arm64|roc:linux-arm64) printf 'aarch64-linux-%s' "$variant" ;;
		zig:macos-arm64) printf aarch64-macos.14.0 ;;
		zig:mswin-amd64) printf x86_64-windows-gnu ;;
		zig:mswin-arm64) printf aarch64-windows-gnu ;;
		*:linux-amd64) printf x86_64-unknown-linux-gnu ;;
		*:linux-arm64) printf aarch64-unknown-linux-gnu ;;
		*:macos-arm64) printf aarch64-apple-darwin ;;
		rust:mswin-amd64) printf x86_64-pc-windows-gnu ;;
		rust:mswin-arm64) printf aarch64-pc-windows-gnullvm ;;
		*) rb_error "no compiler mapping for $impl/$pf" ;;
	esac
}

rb_plan() {
	local canonical="$1" host="$2" impl pf variant triple
	shift 2
	rb_known_impl "$canonical" && rb_known_platform "$host" || return 1
	RB_BACKEND=nix RB_PROFILE=ReleaseFast RB_TEST=0 RB_PLAN=() RB_NIX_ARGS=()
	local all_impls=0 all_plats=0 selected="$canonical" platform="$host" selected_variant=auto
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--all-impls|--all-implementations) all_impls=1 ;;
			--all-plats|--all-platforms) all_plats=1 ;;
			--all) all_impls=1; all_plats=1 ;;
			--debug) RB_PROFILE=Debug ;;
			--test) RB_TEST=1; RB_PROFILE=ReleaseSafe ;;
			--impl|--platform|--variant|--backend|--profile)
				[ "$#" -ge 2 ] || { rb_error "$1 requires a value"; return 1; }
				case "$1" in
					--impl) selected="$2" ;; --platform) platform="$2" ;;
					--variant) selected_variant="$2" ;; --backend) RB_BACKEND="$2" ;;
					--profile) RB_PROFILE="$2" ;;
				esac
				shift ;;
			--impl=*) selected="${1#*=}" ;; --platform=*) platform="${1#*=}" ;;
			--variant=*) selected_variant="${1#*=}" ;; --backend=*) RB_BACKEND="${1#*=}" ;;
			--profile=*) RB_PROFILE="${1#*=}" ;;
			--print-build-logs|-L|--show-trace|--offline) RB_NIX_ARGS+=("$1") ;;
			--) shift; RB_NIX_ARGS+=("$@"); break ;;
			*) rb_error "unknown build argument '$1'; see ./build --help"; return 1 ;;
		esac
		shift
	done
	rb_known_impl "$selected" && rb_known_platform "$platform" || return 1
	case "$RB_BACKEND" in nix|direct) ;; *) rb_error "unknown backend '$RB_BACKEND'"; return 1 ;; esac
	case "$RB_PROFILE" in ReleaseFast|ReleaseSafe|Debug) ;; *) rb_error "unknown profile '$RB_PROFILE'"; return 1 ;; esac
	case "$selected_variant" in auto|gnu|musl) ;; *) rb_error "invalid ABI variant '$selected_variant'"; return 1 ;; esac
	local impls=("$selected") plats=("$platform")
	[ "$all_impls" -eq 0 ] || impls=("${RB_IMPLEMENTATIONS[@]}")
	[ "$all_plats" -eq 0 ] || plats=("${RB_PLATFORMS[@]}")
	for impl in "${impls[@]}"; do
		for pf in "${plats[@]}"; do
			if ! rb_supported "$impl" "$pf"; then
				if [ "$all_plats" -eq 1 ]; then continue; fi
				rb_error "no declared $impl builder for $pf"; return 1
			fi
			variant="$(rb_default_variant "$impl" "$pf")"
			if [ "$selected_variant" != auto ]; then variant="$selected_variant"; fi
			case "$impl:$pf:$variant" in
				zig:linux-*:gnu|zig:linux-*:musl|roc:linux-*:musl) ;;
				roc:*) rb_error "no declared $impl/$pf/$variant ABI builder"; return 1 ;;
				*:linux-*:gnu|*:mswin-*:gnu|*:macos-arm64:) ;;
				*) rb_error "no declared $impl/$pf/$variant ABI builder"; return 1 ;;
			esac
			if [ "$impl" != zig ] && { [ "$RB_BACKEND" = direct ] || [ "$RB_PROFILE" != ReleaseFast ] || [ "$RB_TEST" -eq 1 ]; }; then
				rb_error "$impl uses its declared Nix ReleaseFast package; this direct/profile/test builder is unavailable"; return 1
			fi
			if [ "$RB_TEST" -eq 1 ] && [ "$pf" != "$host" ]; then
				rb_error "cannot execute $pf unit tests on $host without a declared runtime adapter"; return 1
			fi
			triple="$(rb_triple "$impl" "$pf" "$variant")" || return 1
			RB_PLAN+=("$impl|$pf|$variant|$RB_PROFILE|$triple")
		done
	done
}

# Read exact bytes: command substitution alone would discard extra trailing LFs.
rb_read_selection() {
	local root="$1" selection="" status
	[ -f "$root/CANONICAL_IMPL" ] || { rb_error 'CANONICAL_IMPL is missing; run ./build canonize zig'; return 1; }
	IFS= read -r -d '' selection <"$root/CANONICAL_IMPL"
	status=$?
	[ "$status" -eq 1 ] || { rb_error 'CANONICAL_IMPL must contain one identifier, without NUL bytes'; return 1; }
	selection="${selection%$'\n'}"
	rb_known_impl "$selection" || return 1
	printf '%s\n' "$selection"
}

# Atomic mkdir is the lock primitive on both BSD and GNU build hosts. Released
# lock directories are moved to project-local Trash rather than destroyed.
rb_lock() {
	local root="$1" name="$2"
	mkdir -p "$root/.build-work/locks" || return 1
	if ! mkdir "$root/.build-work/locks/$name.lock" 2>/dev/null; then
		rb_error "$name is locked by another build; inspect .build-work/locks/$name.lock before recovering an interrupted operation"
		return 1
	fi
}

rb_unlock() {
	local root="$1" name="$2" trash
	mkdir -p "$root/.build-work/.Trash" || return 1
	trash="$(mktemp -d "$root/.build-work/.Trash/lock.XXXXXX")" || return 1
	mv -- "$root/.build-work/locks/$name.lock" "$trash/" || return 1
}

rb_canonize() {
	local root="$1" selected="$2" old temporary status=0
	rb_known_impl "$selected" || return 1
	old="$(rb_read_selection "$root" 2>/dev/null)"
	if [ "$old" != "$selected" ]; then
		rb_lock "$root" selection || return 1
		temporary="$(mktemp "$root/.build-work/selection.XXXXXX")" || { rb_unlock "$root" selection; return 1; }
		printf '%s\n' "$selected" >"$temporary" &&
			mv -- "$temporary" "$root/CANONICAL_IMPL" || status=1
		rb_unlock "$root" selection || status=1
		[ "$status" -eq 0 ] || return 1
	fi
	printf '%s implementation canonized. Rerun ./build to rebuild.\n' "$selected"
}
