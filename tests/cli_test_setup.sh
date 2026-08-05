# shellcheck shell=bash
# Shared executable selector for the LuaJIT and C CLI contract suites.
#
# Set RANDOM_TEST_CLI to an executable path to run that implementation under
# the historical random/nrandom/drandom invocation names. Unset means the
# repository's LuaJIT scripts already present on PATH.

cli_test_setup() {
	CLI_TEST_SHIM_DIR=""
	CLI_TEST_TARGET=""
	if [ -z "${RANDOM_TEST_CLI:-}" ]; then
		return 0
	fi

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
	ln -s "$CLI_TEST_TARGET" "$CLI_TEST_SHIM_DIR/random" || return 1
	ln -s "$CLI_TEST_TARGET" "$CLI_TEST_SHIM_DIR/nrandom" || return 1
	ln -s "$CLI_TEST_TARGET" "$CLI_TEST_SHIM_DIR/drandom" || return 1
	export PATH="$CLI_TEST_SHIM_DIR:$PATH"

	# Make a broken selector loud: the suite must actually resolve the chosen
	# executable, otherwise a passing run would say nothing about that target.
	if [ "$(readlink "$(command -v random)")" != "$CLI_TEST_TARGET" ]; then
		echo "RANDOM_TEST_CLI selector did not take control of random" >&2
		return 1
	fi
}

cli_test_cleanup() {
	if [ -n "${CLI_TEST_SHIM_DIR:-}" ]; then
		unlink "$CLI_TEST_SHIM_DIR/random" 2>/dev/null || true
		unlink "$CLI_TEST_SHIM_DIR/nrandom" 2>/dev/null || true
		unlink "$CLI_TEST_SHIM_DIR/drandom" 2>/dev/null || true
		rmdir "$CLI_TEST_SHIM_DIR" 2>/dev/null || true
	fi
}
