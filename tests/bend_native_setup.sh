# shellcheck shell=bash
# Resolve one current native Bend snapshot, never an unrelated PATH command.
bend_native_setup() {
	if [ -z "${RANDOM_BEND_ARTIFACT_DIR:-}" ]; then
		RANDOM_BEND_ARTIFACT_DIR="$(bash "$root/bend/build-native")" || return 1
		export RANDOM_BEND_ARTIFACT_DIR
	fi
	local extension=so native_hash cli_hash
	if [ "$(uname -s)" = Darwin ]; then extension=dylib; fi
	RANDOM_BEND_CLI="$RANDOM_BEND_ARTIFACT_DIR/bin/randomb"
	RANDOM_BEND_SHARED_LIBRARY="$RANDOM_BEND_ARTIFACT_DIR/lib/librandomb.$extension"
	if [ ! -x "$RANDOM_BEND_CLI" ] || [ ! -s "$RANDOM_BEND_SHARED_LIBRARY" ] ||
	   [ ! -s "$RANDOM_BEND_ARTIFACT_DIR/lib/librandomb.a" ]; then
		echo "Bend native test RED: incomplete artifact directory: $RANDOM_BEND_ARTIFACT_DIR" >&2
		return 1
	fi
	native_hash="$RANDOM_BEND_ARTIFACT_DIR/native-source.sha256"
	cli_hash="$RANDOM_BEND_ARTIFACT_DIR/cli-source.sha256"
	if [ ! -f "$native_hash" ]; then native_hash="$RANDOM_BEND_ARTIFACT_DIR/share/random-bend2-ffi/native-source.sha256"; fi
	if [ ! -f "$cli_hash" ]; then cli_hash="$RANDOM_BEND_ARTIFACT_DIR/share/random-bend2/cli-source.sha256"; fi
	if ! (cd "$root" && sha256sum --check --status "$native_hash" && sha256sum --check --status "$cli_hash"); then
		echo 'Bend native test RED: selected artifact snapshot is stale' >&2
		return 1
	fi
	if [ -z "${RANDOM_BEND_ORACLE_LIBRARY:-}" ]; then
		(cd "$root" && zig build -Doptimize=ReleaseFast) || return 1
		RANDOM_BEND_ORACLE_LIBRARY="$root/zig-out/lib/librandomz.$extension"
	fi
	if [ ! -s "$RANDOM_BEND_ORACLE_LIBRARY" ]; then echo 'Bend native test RED: Zig oracle library missing' >&2; return 1; fi
	export RANDOM_BEND_CLI RANDOM_BEND_SHARED_LIBRARY RANDOM_BEND_ORACLE_LIBRARY
}
