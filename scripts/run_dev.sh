#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/load_env.sh"
load_env_if_unset "${ROOT_DIR}/.env"

BACKEND_URL="${TRANSLATOR_BACKEND_URL:-http://127.0.0.1:8765}"

if ! curl -fsS "${BACKEND_URL}/health" >/dev/null 2>&1; then
  "${ROOT_DIR}/scripts/run_backend.sh" &
  BACKEND_PID=$!
  trap 'kill "${BACKEND_PID}" >/dev/null 2>&1 || true' EXIT

  BACKEND_READY=0
  for _ in {1..30}; do
    if curl -fsS "${BACKEND_URL}/health" >/dev/null 2>&1; then
      BACKEND_READY=1
      break
    fi

    if ! kill -0 "${BACKEND_PID}" >/dev/null 2>&1; then
      wait "${BACKEND_PID}" || true
      echo "本地翻译服务启动失败，请检查 .env 中的 DASHSCOPE_API_KEY 和端口配置。" >&2
      exit 1
    fi

    sleep 0.5
  done

  if [[ "${BACKEND_READY}" != "1" ]]; then
    echo "本地翻译服务未在 15 秒内就绪：${BACKEND_URL}/health" >&2
    exit 1
  fi
else
  BACKEND_PID=""
fi

exec "${ROOT_DIR}/scripts/run_app.sh"
