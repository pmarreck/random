# shellcheck shell=bash
# Shared executable selector for the LuaJIT, Zig/C, Rust, and Lean CLI contract suites.
#
# Set RANDOM_TEST_CLI to an executable path to run that implementation under
# the historical random/nrandom/drandom invocation names. Unset means the
# repository's LuaJIT scripts already present on PATH.

cli_test_setup() {
	CLI_TEST_SHIM_DIR=""
	CLI_TEST_TARGET=""
	CLI_TEST_LEAN=0
	RANDOM_TEST_SEED_ENV="DRANDOM_SEED"
	RANDOM_TEST_OTHER_SEED_ENV="DRANDOMZ_SEED"
	RANDOM_TEST_OTHER_SEED_ENVS="DRANDOMZ_SEED DRANDOMR_SEED DRANDOML_SEED"
	if [ -z "${RANDOM_TEST_CLI:-}" ]; then
		return 0
	fi
	case "${RANDOM_TEST_CLI_KIND:-zig}" in
		zig)
			RANDOM_TEST_SEED_ENV="DRANDOMZ_SEED"
			RANDOM_TEST_OTHER_SEED_ENV="DRANDOM_SEED"
			RANDOM_TEST_OTHER_SEED_ENVS="DRANDOM_SEED DRANDOMR_SEED DRANDOML_SEED"
			;;
		rust)
			RANDOM_TEST_SEED_ENV="DRANDOMR_SEED"
			RANDOM_TEST_OTHER_SEED_ENV="DRANDOM_SEED"
			RANDOM_TEST_OTHER_SEED_ENVS="DRANDOM_SEED DRANDOMZ_SEED DRANDOML_SEED"
			;;
		lean)
			CLI_TEST_LEAN=1
			RANDOM_TEST_SEED_ENV="DRANDOML_SEED"
			RANDOM_TEST_OTHER_SEED_ENV="DRANDOM_SEED"
			RANDOM_TEST_OTHER_SEED_ENVS="DRANDOM_SEED DRANDOMZ_SEED DRANDOMR_SEED"
			;;
		*)
			echo "unknown RANDOM_TEST_CLI_KIND: $RANDOM_TEST_CLI_KIND" >&2
			return 1
			;;
	esac

	case "$RANDOM_TEST_CLI" in
		*/*) cli_candidate="$RANDOM_TEST_CLI" ;;
		*) cli_candidate="$(command -v "$RANDOM_TEST_CLI" 2>/dev/null || true)" ;;
	esac
	if [ -z "$cli_candidate" ] || [ ! -x "$cli_candidate" ]; then
		echo "RANDOM_TEST_CLI is not executable: $RANDOM_TEST_CLI" >&2
		return 1
	fi
	cli_dir="$(cd -P -- "$(dirname -- "$cli_candidate")" && pwd)" || return 1
	CLI_TEST_TARGET="$cli_dir/$(basename -- "$cli_candidate")"
	CLI_TEST_SHIM_DIR="$(mktemp -d "${TMPDIR:-/tmp}/random-cli-test.XXXXXX")" || return 1
	if [ "$CLI_TEST_LEAN" -eq 1 ]; then
		printf '#!%s\nRANDOML_INVOKED_AS=randoml exec %q "$@"\n' \
			"$(command -v bash)" "$CLI_TEST_TARGET" >"$CLI_TEST_SHIM_DIR/random"
		printf '#!%s\nRANDOML_INVOKED_AS=nrandoml exec %q "$@"\n' \
			"$(command -v bash)" "$CLI_TEST_TARGET" >"$CLI_TEST_SHIM_DIR/nrandom"
		printf '#!%s\nRANDOML_INVOKED_AS=drandoml exec %q "$@"\n' \
			"$(command -v bash)" "$CLI_TEST_TARGET" >"$CLI_TEST_SHIM_DIR/drandom"
		chmod +x "$CLI_TEST_SHIM_DIR/random" "$CLI_TEST_SHIM_DIR/nrandom" \
			"$CLI_TEST_SHIM_DIR/drandom"
	else
		ln -s "$CLI_TEST_TARGET" "$CLI_TEST_SHIM_DIR/random" || return 1
		ln -s "$CLI_TEST_TARGET" "$CLI_TEST_SHIM_DIR/nrandom" || return 1
		ln -s "$CLI_TEST_TARGET" "$CLI_TEST_SHIM_DIR/drandom" || return 1
	fi
	ln -s "$CLI_TEST_TARGET" "$CLI_TEST_SHIM_DIR/randomr" || return 1
	ln -s "$CLI_TEST_TARGET" "$CLI_TEST_SHIM_DIR/nrandomr" || return 1
	ln -s "$CLI_TEST_TARGET" "$CLI_TEST_SHIM_DIR/drandomr" || return 1
	ln -s "$CLI_TEST_TARGET" "$CLI_TEST_SHIM_DIR/randoml" || return 1
	ln -s "$CLI_TEST_TARGET" "$CLI_TEST_SHIM_DIR/nrandoml" || return 1
	ln -s "$CLI_TEST_TARGET" "$CLI_TEST_SHIM_DIR/drandoml" || return 1
	export PATH="$CLI_TEST_SHIM_DIR:$PATH"

	# Make a broken selector loud: the suite must actually resolve the chosen
	# executable, otherwise a passing run would say nothing about that target.
	if [ "$CLI_TEST_LEAN" -eq 0 ] &&
	   [ "$(readlink "$(command -v random)")" != "$CLI_TEST_TARGET" ]; then
		echo "RANDOM_TEST_CLI selector did not take control of random" >&2
		return 1
	fi
}

cli_test_cleanup() {
	if [ -n "${CLI_TEST_SHIM_DIR:-}" ]; then
		unlink "$CLI_TEST_SHIM_DIR/random" 2>/dev/null || true
		unlink "$CLI_TEST_SHIM_DIR/nrandom" 2>/dev/null || true
		unlink "$CLI_TEST_SHIM_DIR/drandom" 2>/dev/null || true
		unlink "$CLI_TEST_SHIM_DIR/randomr" 2>/dev/null || true
		unlink "$CLI_TEST_SHIM_DIR/nrandomr" 2>/dev/null || true
		unlink "$CLI_TEST_SHIM_DIR/drandomr" 2>/dev/null || true
		unlink "$CLI_TEST_SHIM_DIR/randoml" 2>/dev/null || true
		unlink "$CLI_TEST_SHIM_DIR/nrandoml" 2>/dev/null || true
		unlink "$CLI_TEST_SHIM_DIR/drandoml" 2>/dev/null || true
		trash_root="${HOME:?HOME must be set}/.Trash"
		mkdir -p "$trash_root"
		mv "$CLI_TEST_SHIM_DIR" "$trash_root/$(basename "$CLI_TEST_SHIM_DIR").$$" 2>/dev/null || true
	fi
}
