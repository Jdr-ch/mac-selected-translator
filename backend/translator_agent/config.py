"""Runtime configuration for the local translator service.

The desktop app intentionally talks to a local HTTP service instead of loading
LangChain inside Swift. That keeps macOS UI permissions in the native layer and
keeps service runtime settings separate from the CLI-owned model configuration.
"""

from __future__ import annotations

from dataclasses import dataclass
import math
import os


class ConfigError(RuntimeError):
    """Raised when required runtime configuration is missing."""


@dataclass(frozen=True)
class Settings:
    """Environment-backed settings for the local HTTP service only.

    Attributes:
        host: Local bind address for the HTTP service.
        port: Local port consumed by the macOS app.
        request_timeout_seconds: Per-request model timeout.
        max_input_chars: Guardrail that prevents accidental huge selections
            from creating slow or expensive model calls.
    """

    host: str
    port: int
    request_timeout_seconds: float
    max_input_chars: int

    @classmethod
    def from_env(cls) -> "Settings":
        """Start even with a broken model configuration so its panel can show the error."""

        port_raw = os.getenv("TRANSLATOR_BACKEND_PORT", "8765")
        timeout_raw = os.getenv("TRANSLATOR_REQUEST_TIMEOUT_SECONDS", "120")
        max_input_raw = os.getenv("TRANSLATOR_MAX_INPUT_CHARS", "8000")

        try:
            port = int(port_raw)
            request_timeout_seconds = float(timeout_raw)
            if not math.isfinite(request_timeout_seconds) or request_timeout_seconds <= 0:
                raise ValueError("Invalid timeout")
            max_input_chars = int(max_input_raw)
        except ValueError as exc:
            raise ConfigError(
                "TRANSLATOR_BACKEND_PORT 和 TRANSLATOR_MAX_INPUT_CHARS 必须是数字，"
                "TRANSLATOR_REQUEST_TIMEOUT_SECONDS 必须是有限正数。"
            ) from exc

        return cls(
            host=os.getenv("TRANSLATOR_BACKEND_HOST", "127.0.0.1"),
            port=port,
            request_timeout_seconds=request_timeout_seconds,
            max_input_chars=max_input_chars,
        )
