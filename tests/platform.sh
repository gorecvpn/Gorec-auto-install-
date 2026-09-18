#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export GOREC_INSTALL_ROOT="$TEST_ROOT/opt/gorec"
export GOREC_CONFIG_ROOT="$TEST_ROOT/opt/gorec"
export GOREC_DATA_ROOT="$TEST_ROOT/opt/gorec"
export GOREC_BOT_SOURCE_DIR="$TEST_ROOT/opt/bot"
export GOREC_CABINET_SOURCE_DIR="$TEST_ROOT/opt/cabinet"
export GOREC_LIB_ROOT="$PROJECT_ROOT"

# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/system.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

detect_os
case "$OS_ID:$OS_VERSION" in
  ubuntu:22.04 | ubuntu:24.04 | debian:12*)
    check_supported_os
    ;;
  *)
    # Local/dev hosts outside the CI matrix: still verify architecture and paths.
    printf 'Platform OS check skipped on unsupported host for unit run: %s\n' "$OS_PRETTY"
    ;;
esac
check_architecture
ensure_runtime_dirs
[[ -d "$CONFIG_ROOT" && -d "$STATE_ROOT" ]] || fail "runtime dirs missing"
[[ "$(stat -c '%a' "$STATE_ROOT")" == 700 ]] || fail "STATE_ROOT must be 700"
# opt-max: INSTALL_ROOT/CONFIG_ROOT are the same tree and stay traversable (755);
# secrets are individual *.env files mode 600.
if [[ "$(readlink -m "$CONFIG_ROOT")" == "$(readlink -m "$INSTALL_ROOT")" ]]; then
  [[ "$(stat -c '%a' "$INSTALL_ROOT")" == 755 ]] || fail "opt-max INSTALL_ROOT must be 755"
else
  [[ "$(stat -c '%a' "$CONFIG_ROOT")" == 700 ]] || fail "split CONFIG_ROOT must be 700"
fi
printf 'Platform test passed: %s (%s)\n' "$OS_PRETTY" "$(uname -m)"
