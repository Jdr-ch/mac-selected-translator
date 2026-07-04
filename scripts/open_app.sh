#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${ROOT_DIR}/dist/Selected Text Translator.app"

if [[ ! -d "${APP_PATH}" ]]; then
  "${ROOT_DIR}/scripts/build_app.sh"
fi

open "${APP_PATH}"
