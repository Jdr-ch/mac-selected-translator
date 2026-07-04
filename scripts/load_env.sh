#!/usr/bin/env bash

load_env_if_unset() {
  local env_file="${1:-.env}"

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
