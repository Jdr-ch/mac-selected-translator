#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Selected Text Translator"
APP_DIR="${ROOT_DIR}/dist/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
INFO_PLIST="${CONTENTS_DIR}/Info.plist"
APP_ICON="${RESOURCES_DIR}/AppIcon.icns"
EXECUTABLE_NAME="SelectedTextTranslatorApp"
BACKEND_URL="${TRANSLATOR_BACKEND_URL:-http://127.0.0.1:${TRANSLATOR_BACKEND_PORT:-8765}}"

swift build --package-path "${ROOT_DIR}" -c release

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${ROOT_DIR}/.build/release/${EXECUTABLE_NAME}" "${MACOS_DIR}/${EXECUTABLE_NAME}"
chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"
# Keep the local renderer available without depending on SwiftPM's development build directory.
ditto "${ROOT_DIR}/Sources/SelectedTextTranslatorApp/Resources/Flowchart" "${RESOURCES_DIR}/Flowchart"

ICON_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/selected-text-translator-icon.XXXXXX")"
trap 'rm -rf "${ICON_WORK_DIR}"' EXIT
ICONSET_DIR="${ICON_WORK_DIR}/AppIcon.iconset"
/usr/bin/xcrun swift "${ROOT_DIR}/scripts/generate_app_icon.swift" "${ICONSET_DIR}"
/usr/bin/iconutil -c icns "${ICONSET_DIR}" -o "${APP_ICON}"

cat > "${INFO_PLIST}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string zh_CN" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${APP_NAME}" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string ${EXECUTABLE_NAME}" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.local.selected-text-translator" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string ${APP_NAME}" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.1.0" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 13.0" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Add :NSHumanReadableCopyright string Local development build" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Add :TranslatorBackendURL string ${BACKEND_URL}" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Add :TranslatorProjectRoot string ${ROOT_DIR}" "${INFO_PLIST}"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "${APP_DIR}" >/dev/null
fi

echo "App 已生成：${APP_DIR}"
