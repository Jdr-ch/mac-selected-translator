#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/load_env.sh"
load_env_if_unset "${ROOT_DIR}/.env"

export TRANSLATOR_PROJECT_ROOT="${TRANSLATOR_PROJECT_ROOT:-${ROOT_DIR}}"

exec swift run --package-path "${ROOT_DIR}" SelectedTextTranslatorApp
