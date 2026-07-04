"""Runtime configuration for the local translator service.

The desktop app intentionally talks to a local HTTP service instead of loading
LangChain inside Swift. That keeps macOS UI permissions in the native layer and
lets the model provider be swapped through environment variables.
"""

from __future__ import annotations

from dataclasses import dataclass
import os


DEFAULT_BASE_URL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
PLACEHOLDER_API_KEYS = {"sk-xxxx", "your-api-key", "replace-me"}


class ConfigError(RuntimeError):
    """Raised when required runtime configuration is missing."""


@dataclass(frozen=True)
class Settings:
    """Environment-backed settings used by the LangChain translator agent.

    Attributes:
        api_key: DashScope or Model Studio API key used by the OpenAI-compatible
            endpoint. It is never logged by the server.
        base_url: Full OpenAI-compatible endpoint, including `/v1`.
        model: Qwen model name sent to LangChain. Defaults to `qwen3.7-max`.
        host: Local bind address for the HTTP service.
        port: Local port consumed by the macOS app.
        default_target_language: Language used when the app does not provide
            an explicit target language.
        request_timeout_seconds: Per-request model timeout.
        max_input_chars: Guardrail that prevents accidental huge selections
            from creating slow or expensive model calls.
    """

    api_key: str
    base_url: str
    model: str
    host: str
    port: int
    default_target_language: str
    request_timeout_seconds: float
    max_input_chars: int

    @classmethod
    def from_env(cls) -> "Settings":
        """Create validated settings from environment variables.

        `DASHSCOPE_BASE_URL` is optional because many DashScope-compatible
        accounts still use the public compatible-mode endpoint. If your account
        is bound to a Model Studio workspace endpoint, set the full endpoint in
        `.env` so the backend does not guess provider-specific routing.
        """

        api_key = os.getenv("DASHSCOPE_API_KEY") or os.getenv("QWEN_API_KEY")
        if not api_key or api_key.strip().lower() in PLACEHOLDER_API_KEYS:
            raise ConfigError(
                "缺少 DASHSCOPE_API_KEY。请先复制 .env.example 为 .env 并填入你的 API Key。"
            )

        port_raw = os.getenv("TRANSLATOR_BACKEND_PORT", "8765")
        timeout_raw = os.getenv("QWEN_REQUEST_TIMEOUT_SECONDS", "30")
        max_input_raw = os.getenv("TRANSLATOR_MAX_INPUT_CHARS", "8000")

        try:
            port = int(port_raw)
            request_timeout_seconds = float(timeout_raw)
            max_input_chars = int(max_input_raw)
        except ValueError as exc:
            raise ConfigError(
                "TRANSLATOR_BACKEND_PORT、QWEN_REQUEST_TIMEOUT_SECONDS 和 "
                "TRANSLATOR_MAX_INPUT_CHARS 必须是数字。"
            ) from exc

        return cls(
            api_key=api_key,
            base_url=os.getenv("DASHSCOPE_BASE_URL", DEFAULT_BASE_URL),
            model=os.getenv("QWEN_MODEL", "qwen3.7-max"),
            host=os.getenv("TRANSLATOR_BACKEND_HOST", "127.0.0.1"),
            port=port,
            default_target_language=os.getenv("DEFAULT_TARGET_LANGUAGE", "中文"),
            request_timeout_seconds=request_timeout_seconds,
            max_input_chars=max_input_chars,
        )
