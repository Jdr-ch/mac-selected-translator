"""Minimal local HTTP server used by the macOS translator app."""

from __future__ import annotations

from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import sys
from typing import Any

from .agent import TranslationError, TranslatorAgent
from .config import ConfigError, Settings


class TranslatorRequestHandler(BaseHTTPRequestHandler):
    """HTTP endpoints consumed by the Swift floating translator.

    The handler stores `agent` and `settings` as class attributes so the
    ThreadingHTTPServer can create lightweight request instances without
    rebuilding the LangChain client for every selected-text translation.
    """

    agent: TranslatorAgent
    settings: Settings

    def do_GET(self) -> None:
        """Expose a health endpoint for shell scripts and the macOS app."""

        if self.path == "/health":
            self._send_json({"ok": True, "model": self.settings.model})
            return
        self._send_json({"error": "Not found"}, HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        """Translate text submitted by the local desktop client."""

        if self.path != "/translate":
            self._send_json({"error": "Not found"}, HTTPStatus.NOT_FOUND)
            return

        try:
            payload = self._read_json_body()
            text = self._read_text(payload)
            target_language = payload.get("target_language")
            translation = self.agent.translate(text, target_language)
        except (ValueError, TranslationError) as exc:
            self._send_json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)
            return
        except Exception as exc:  # noqa: BLE001 - the UI needs a readable error payload.
            self._send_json({"error": f"翻译请求失败：{exc}"}, HTTPStatus.BAD_GATEWAY)
            return

        self._send_json({"translation": translation})

    def log_message(self, format: str, *args: Any) -> None:
        """Keep the backend log concise while preserving useful request lines."""

        sys.stderr.write("[translator-backend] " + format % args + "\n")

    def _read_json_body(self) -> dict[str, Any]:
        """Decode and validate the JSON body sent by the Swift app."""

        content_length = int(self.headers.get("Content-Length", "0"))
        if content_length <= 0:
            raise ValueError("请求体为空。")

        raw_body = self.rfile.read(content_length)
        try:
            payload = json.loads(raw_body.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise ValueError("请求体不是合法 JSON。") from exc

        if not isinstance(payload, dict):
            raise ValueError("请求体必须是 JSON object。")
        return payload

    def _read_text(self, payload: dict[str, Any]) -> str:
        """Extract selected text and apply the backend-side length guardrail."""

        text = payload.get("text")
        if not isinstance(text, str):
            raise ValueError("字段 text 必须是字符串。")
        if len(text) > self.settings.max_input_chars:
            raise ValueError(
                f"选中文字超过 {self.settings.max_input_chars} 字符，请缩短后再翻译。"
            )
        return text

    def _send_json(
        self,
        payload: dict[str, Any],
        status: HTTPStatus = HTTPStatus.OK,
    ) -> None:
        """Serialize a JSON response with UTF-8 so Chinese errors render cleanly."""

        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def build_server(settings: Settings) -> ThreadingHTTPServer:
    """Create a local HTTP server with one shared LangChain agent instance."""

    TranslatorRequestHandler.settings = settings
    TranslatorRequestHandler.agent = TranslatorAgent(settings)
    return ThreadingHTTPServer((settings.host, settings.port), TranslatorRequestHandler)


def main() -> int:
    """Start the local translator backend from `python -m backend.translator_agent`."""

    try:
        settings = Settings.from_env()
        server = build_server(settings)
    except ConfigError as exc:
        print(f"[translator-backend] 配置错误：{exc}", file=sys.stderr)
        return 2

    print(
        "[translator-backend] listening on "
        f"http://{settings.host}:{settings.port} with model={settings.model}",
        file=sys.stderr,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[translator-backend] stopping", file=sys.stderr)
    finally:
        server.server_close()
    return 0
