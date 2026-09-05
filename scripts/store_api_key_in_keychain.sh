#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/load_env.sh"

if [[ "$(uname -s)" != "Darwin" ]] || ! command -v security >/dev/null 2>&1; then
  echo "当前系统不支持 macOS 钥匙串。" >&2
  exit 1
fi

api_key="${DASHSCOPE_API_KEY:-${QWEN_API_KEY:-}}"
if [[ -z "${api_key}" ]]; then
  if [[ ! -t 0 ]]; then
    echo "缺少可保存的 API Key，请先设置 DASHSCOPE_API_KEY。" >&2
    exit 1
  fi

  read -r -s -p "请输入 DashScope API Key：" api_key
  echo
fi

normalized_api_key="$(printf '%s' "${api_key}" | tr '[:upper:]' '[:lower:]')"
case "${normalized_api_key}" in
  sk-xxxx|your-api-key|replace-me)
    echo "拒绝保存占位 API Key。" >&2
    exit 1
    ;;
esac

security add-generic-password \
  -U \
  -a "${TRANSLATOR_KEYCHAIN_ACCOUNT}" \
  -s "${TRANSLATOR_KEYCHAIN_SERVICE}" \
  -w "${api_key}" \
  >/dev/null

echo "DashScope API Key 已安全保存到 macOS 钥匙串。"
