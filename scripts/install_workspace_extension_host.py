#!/usr/bin/env python3
"""注册当前用户的 Chrome 原生消息宿主，仅允许独立扩展目录声明的固定扩展 ID。"""
import argparse
import json
import os
from pathlib import Path
import re


def main():
    """在安装包存在时生成宿主清单；不改写 Chrome 用户资料或其他扩展设置。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("/Applications/Selected Text Translator.app"))
    parser.add_argument("--extension-dir", type=Path, required=True)
    args = parser.parse_args()
    contract = json.loads((args.extension_dir / "bridge-contract.json").read_text())
    extension_id = contract["extensionId"]
    if not re.fullmatch(r"[a-p]{32}", extension_id) or contract["protocolVersion"] != 1:
        raise SystemExit("扩展协议或标识无效。")
    host = args.app.resolve() / "Contents/MacOS/WorkspaceChromeHost"
    if not host.is_file() or not os.access(host, os.X_OK):
        raise SystemExit("安装包缺少可执行的 WorkspaceChromeHost，请先构建并安装 App。")
    directory = Path.home() / "Library/Application Support/Google/Chrome/NativeMessagingHosts"
    directory.mkdir(parents=True, exist_ok=True)
    manifest = {
        "name": contract["nativeHost"],
        "description": "本机工作场景助手",
        "path": str(host),
        "type": "stdio",
        "allowed_origins": [f"chrome-extension://{extension_id}/"],
    }
    target = directory / f"{contract['nativeHost']}.json"
    temporary = target.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    temporary.chmod(0o600)
    temporary.replace(target)
    print(f"Chrome 本机桥已注册：{target}")


if __name__ == "__main__":
    main()
