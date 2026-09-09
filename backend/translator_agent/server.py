"""Minimal local HTTP server used by the macOS translator app."""

from __future__ import annotations

from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import sys
from typing import Any

from openai import APITimeoutError

from .agent import TranslationError, TranslatorAgent
from .config import ConfigError, Settings
from .model_config import ModelConfigurationReader
from .flowchart import FlowchartAgent, FlowchartError


class TranslatorRequestHandler(BaseHTTPRequestHandler):
    """HTTP endpoints consumed by the Swift floating translator.

    Each request resolves one fresh configuration snapshot; switching the app's
    default never changes an in-flight request or the CLI's configuration files.
    """

    settings: Settings
    models: ModelConfigurationReader

    def do_GET(self) -> None:
        """Expose service capabilities and allowlisted model metadata, never credentials."""

        if self.path == "/health":
            self._send_json({"ok": True, "capabilities": ["model-switching"],
                             "request_timeout_seconds": self.settings.request_timeout_seconds})
            return
        if self.path in ("/models/codex", "/models/qwen"):
            try:
                configuration = self.models.read(self.path.rsplit("/", 1)[-1])
                self._send_json(configuration.metadata())
            except ValueError as exc:
                self._send_json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)
            return
        self._send_json({"error": "Not found"}, HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        """Route flowcharts, translation, and polishing through separate model policies."""

        if self.path == "/flowchart":
            self._generate_flowchart()
            return

        if self.path not in ("/translate", "/polish"):
            self._send_json({"error": "Not found"}, HTTPStatus.NOT_FOUND)
            return

        try:
            payload = self._read_json_body()
            text = self._read_text(payload)
            # Older HTTP clients omit provider; their historical Qwen choice remains explicit here.
            agent = self._agent_for_provider(payload.get("provider", "qwen"))
            if self.path == "/polish":
                result = {
                    "polished_text": agent.polish(
                        text, payload.get("role"), payload.get("scenario"), payload.get("tone")
                    )
                }
            else:
                target_language = payload.get("target_language")
                result = {"translation": agent.translate(text, target_language)}
        except APITimeoutError:
            self._send_json({"error": "模型响应超时，请稍后重试。"}, HTTPStatus.GATEWAY_TIMEOUT)
            return
        except (ValueError, TranslationError) as exc:
            self._send_json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)
            return
        except Exception:  # Provider exceptions can contain endpoint credentials or request data.
            operation = "润色" if self.path == "/polish" else "翻译"
            self._send_json({"error": f"{operation}请求失败，请检查所选模型的连接和认证配置。"},
                            HTTPStatus.BAD_GATEWAY)
            return

        self._send_json(result)

    def _agent_for_provider(self, provider: object) -> TranslatorAgent:
        """Bind all calls, including IPA correction, to the same freshly loaded model."""
        return TranslatorAgent(self.models.client(provider, self.settings.request_timeout_seconds))

    def _generate_flowchart(self) -> None:
        """Keep one-shot diagram generation independent of translation's response policy."""
        try:
            payload = self._read_json_body()
            client = self.models.client(payload.get("provider", "qwen"), self.settings.request_timeout_seconds)
            result = FlowchartAgent(client, self.settings.max_input_chars).generate(payload.get("text"))
        except APITimeoutError:
            self._send_json({"error": "模型响应超时，请稍后重试。"}, HTTPStatus.GATEWAY_TIMEOUT)
            return
        except (ValueError, FlowchartError) as exc:
            self._send_json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)
            return
        except Exception:  # Provider errors may include request details; do not expose credentials.
            self._send_json({"error": "流程解析请求失败，请检查所选模型的连接和认证配置。"},
                            HTTPStatus.BAD_GATEWAY)
            return
        self._send_json(result)

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
                f"选中文字超过 {self.settings.max_input_chars} 字符，请缩短后重试。"
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
    """Keep service startup independent of either provider's current credentials."""

    TranslatorRequestHandler.settings = settings
    TranslatorRequestHandler.models = ModelConfigurationReader()
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
        f"http://{settings.host}:{settings.port}",
        file=sys.stderr,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[translator-backend] stopping", file=sys.stderr)
    finally:
        server.server_close()
    return 0
