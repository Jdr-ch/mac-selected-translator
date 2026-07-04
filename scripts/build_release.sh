#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift build --package-path "${ROOT_DIR}" -c release
echo "Swift 可执行文件：${ROOT_DIR}/.build/release/SelectedTextTranslatorApp"
echo "如果需要双击启动的 App，请运行：${ROOT_DIR}/scripts/build_app.sh"
