# shellcheck shell=bash
# Keep generated test fixtures recoverable; never permanently delete them.
test_trash() {
	local target="${1:?test fixture path required}" destination
	local trash="${2:-${RANDOM_TEST_TRASH_DIR:-${HOME:?}/.Trash}}"
	case "$target" in
		/|"${HOME:?}"|"${HOME:?}/"|.|..) echo "refusing broad fixture target: $target" >&2; return 1 ;;
	esac
	case "$trash" in
		/*) ;;
		*) echo "fixture Trash must be an absolute path: $trash" >&2; return 1 ;;
	esac
	[ -e "$target" ] || [ -L "$target" ] || return 0
	mkdir -p "$trash" || return 1
	destination=$(mktemp -d "$trash/random-fixture.XXXXXX") || return 1
	mv -- "$target" "$destination/" || return 1
}

# Use from an EXIT trap: neither conceal failed cleanup nor erase suite failure.
test_trash_on_exit() {
	local status=$?
	if ! test_trash "$@"; then
		echo "test fixture could not be moved to Trash" >&2
		exit 1
	fi
	exit "$status"
}
