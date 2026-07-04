#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/.env"
  set +a
fi

if [[ ! -x "${ROOT_DIR}/.venv/bin/python" ]]; then
  echo "缺少虚拟环境，请先运行：${ROOT_DIR}/scripts/setup.sh" >&2
  exit 1
fi

cd "${ROOT_DIR}"
exec "${ROOT_DIR}/.venv/bin/python" -m backend.translator_agent
