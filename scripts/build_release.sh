#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift build --package-path "${ROOT_DIR}" -c release
echo "Swift 可执行文件：${ROOT_DIR}/.build/release/SelectedTextTranslatorApp"
