#!/usr/bin/env bash

TRANSLATOR_KEYCHAIN_SERVICE="com.local.selected-text-translator.dashscope-api-key"
TRANSLATOR_KEYCHAIN_ACCOUNT="selected-text-translator"

# Preserve explicit process configuration and use Keychain only when neither
# supported API key variable has a usable value.
load_keychain_api_key_if_unset() {
  if [[ -n "${DASHSCOPE_API_KEY:-}" || -n "${QWEN_API_KEY:-}" ]]; then
    return 0
  fi

  [[ "$(uname -s)" == "Darwin" ]] || return 0
  command -v security >/dev/null 2>&1 || return 0

  local api_key
  if ! api_key="$(security find-generic-password \
    -a "${TRANSLATOR_KEYCHAIN_ACCOUNT}" \
    -s "${TRANSLATOR_KEYCHAIN_SERVICE}" \
    -w 2>/dev/null)"; then
    return 0
  fi

  [[ -n "${api_key}" ]] && export DASHSCOPE_API_KEY="${api_key}"
}

# Fill only variables absent from the process so an explicit shell or
# Keychain value cannot be overwritten by local development defaults.
load_env_if_unset() {
  local env_file="${1:-.env}"
  local runtime_only="${2:-false}"

  [[ -f "${env_file}" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue

    if [[ "${line}" == export\ * ]]; then
      line="${line#export }"
    fi

    [[ "${line}" == *=* ]] || continue

    key="${line%%=*}"
    value="${line#*=}"

    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    if [[ "${runtime_only}" == "true" ]]; then
      case "${key}" in
        TRANSLATOR_BACKEND_HOST|TRANSLATOR_BACKEND_PORT|TRANSLATOR_BACKEND_URL|TRANSLATOR_PROJECT_ROOT|TRANSLATOR_MAX_INPUT_CHARS|TRANSLATOR_REQUEST_TIMEOUT_SECONDS) ;;
        *) continue ;;
      esac
    fi

    # The user's shell environment is the source of truth. `.env` only fills
    # missing local defaults so placeholder values cannot hide a real API key.
    if [[ -z "${!key+x}" ]]; then
      if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
        value="${value:1:${#value}-2}"
      elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
        value="${value:1:${#value}-2}"
      fi

      export "${key}=${value}"
    fi
  done < "${env_file}"
}

# Model settings now belong to the CLIs; legacy .env/Keychain values must not shadow them.
load_translator_configuration() {
  local env_file="${1:-.env}"
  load_env_if_unset "${env_file}" true
}
