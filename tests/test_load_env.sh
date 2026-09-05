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
  > "${env_file}"

(
  export DASHSCOPE_API_KEY="process-key"
  security() { return 1; }

  load_translator_configuration "${env_file}"

  assert_equal "process-key" "${DASHSCOPE_API_KEY}" "process environment must win"
)

(
  unset DASHSCOPE_API_KEY QWEN_API_KEY DASHSCOPE_BASE_URL
  security() { printf '%s' "keychain-key"; }

  load_translator_configuration "${env_file}"

  assert_equal "keychain-key" "${DASHSCOPE_API_KEY}" "Keychain must win over .env"
  assert_equal "https://env.example/v1" "${DASHSCOPE_BASE_URL}" ".env must still supply non-secret defaults"
)

(
  unset DASHSCOPE_API_KEY QWEN_API_KEY DASHSCOPE_BASE_URL
  security() { return 1; }

  load_translator_configuration "${env_file}"

  assert_equal "env-file-key" "${DASHSCOPE_API_KEY}" ".env must remain the final fallback"
)

echo "load_env tests passed"
