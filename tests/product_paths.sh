# shellcheck shell=bash
# Test products are private, target/profile-qualified native graph outputs.
# They never write through a user's published implementation or Nix link.
RANDOM_TEST_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$RANDOM_TEST_PROJECT_ROOT/build-support/core.sh"
RANDOM_TEST_PF="$(rb_platform "$(uname -s)" "$(uname -m)")" || return 1
RANDOM_TEST_PRODUCTS="${RANDOM_TEST_PRODUCTS:-$RANDOM_TEST_PROJECT_ROOT/.build-work/tests/$RANDOM_TEST_PF}"
export RANDOM_TEST_PRODUCTS RANDOM_TEST_PF
export RANDOM_TEST_ZIG_OUT="$RANDOM_TEST_PRODUCTS/ReleaseFast/zig"
export RANDOM_TEST_ZIG_SAFE_OUT="$RANDOM_TEST_PRODUCTS/ReleaseSafe/zig"
export RANDOM_TEST_LEAN_OUT="$RANDOM_TEST_PRODUCTS/ReleaseFast/lean"
export RANDOM_TEST_ROC_OUT="$RANDOM_TEST_PRODUCTS/ReleaseFast/roc"
