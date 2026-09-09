#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/load_env.sh"

# Stop the regression script at the first precedence mismatch.
assert_equal() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [[ "${actual}" != "${expected}" ]]; then
    printf 'FAIL: %s (expected=%s, actual=%s)\n' "${message}" "${expected}" "${actual}" >&2
    exit 1
  fi
}

env_file="$(mktemp)"
trap 'rm -f "${env_file}"' EXIT
printf '%s\n' \
  'DASHSCOPE_API_KEY=env-file-key' \
  'DASHSCOPE_BASE_URL=https://env.example/v1' \
  'TRANSLATOR_BACKEND_PORT=8766' \
  > "${env_file}"

(
  export DASHSCOPE_API_KEY="process-key"
  security() { return 1; }

  load_translator_configuration "${env_file}"

  assert_equal "process-key" "${DASHSCOPE_API_KEY}" "process environment must win"
)

(
  unset DASHSCOPE_API_KEY QWEN_API_KEY DASHSCOPE_BASE_URL TRANSLATOR_BACKEND_PORT
  security() { echo "legacy Keychain must not be accessed" >&2; exit 1; }

  load_translator_configuration "${env_file}"

  assert_equal "" "${DASHSCOPE_API_KEY:-}" "legacy keys must not enter model resolution"
  assert_equal "" "${DASHSCOPE_BASE_URL:-}" "legacy endpoints must not enter model resolution"
  assert_equal "8766" "${TRANSLATOR_BACKEND_PORT}" ".env must still supply runtime settings"
)

(
  export TRANSLATOR_BACKEND_PORT=8767
  security() { return 1; }

  load_translator_configuration "${env_file}"

  assert_equal "8767" "${TRANSLATOR_BACKEND_PORT}" "explicit runtime settings must win over .env"
)

echo "load_env tests passed"
