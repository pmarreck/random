# shellcheck shell=bash
# Shared artifact selector only; every CLI assertion lives in the Bash oracle.
roc_native_setup() {
	if [ -z "${RANDOM_ROC_NATIVE_DIR:-}" ]; then
		RANDOM_ROC_NATIVE_DIR="$root/roc-out"
		bash "$root/roc/build-native" "$RANDOM_ROC_NATIVE_DIR" || return 1
		export RANDOM_ROC_NATIVE_DIR
	fi
	if [ ! -s "$RANDOM_ROC_NATIVE_DIR/lib/librandomroc.a" ] ||
	   [ ! -s "$RANDOM_ROC_NATIVE_DIR/lib/librandomroc.so" ] ||
	   [ ! -x "$RANDOM_ROC_NATIVE_DIR/bin/randomroc" ]; then
		echo "Roc native test RED: selected artifact directory is incomplete: $RANDOM_ROC_NATIVE_DIR" >&2
		return 1
	fi
}
