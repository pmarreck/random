# shellcheck shell=bash
# Keep generated test fixtures recoverable; never permanently delete them.
test_trash() {
	local target="${1:?test fixture path required}" destination
	case "$target" in
		/|"${HOME:?}"|"${HOME:?}/"|.|..) echo "refusing broad fixture target: $target" >&2; return 1 ;;
	esac
	[ -e "$target" ] || [ -L "$target" ] || return 0
	mkdir -p "${HOME:?}/.Trash" || return 1
	destination=$(mktemp -d "${HOME:?}/.Trash/random-fixture.XXXXXX") || return 1
	mv -- "$target" "$destination/" || return 1
}
