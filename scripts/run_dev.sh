#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/.env"
  set +a
fi

BACKEND_URL="${TRANSLATOR_BACKEND_URL:-http://127.0.0.1:8765}"

if ! curl -fsS "${BACKEND_URL}/health" >/dev/null 2>&1; then
  "${ROOT_DIR}/scripts/run_backend.sh" &
  BACKEND_PID=$!
  trap 'kill "${BACKEND_PID}" >/dev/null 2>&1 || true' EXIT

  for _ in {1..30}; do
    if curl -fsS "${BACKEND_URL}/health" >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done
else
  BACKEND_PID=""
fi

exec "${ROOT_DIR}/scripts/run_app.sh"
