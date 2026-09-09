"""Read the CLI-owned model settings without copying or updating their credentials."""

from __future__ import annotations

from dataclasses import dataclass, field
from copy import deepcopy
import json
import os
from pathlib import Path
from typing import Any, Mapping

try:
    import tomllib
except ModuleNotFoundError:  # Python 3.10 uses the same TOML parser through its backport.
    import tomli as tomllib

from langchain_openai import ChatOpenAI


class ModelConfigurationError(ValueError):
    """A safe configuration diagnostic that never includes file contents or secrets."""


@dataclass(frozen=True)
class ModelConfiguration:
    """One request's snapshot; only metadata may cross the local HTTP boundary."""

    provider: str
    model: str
    source: str
    options: dict[str, Any] = field(repr=False)

    def metadata(self) -> dict[str, str]:
        """Expose an explicit allowlist, even when this snapshot includes a credential."""
        return {"provider": self.provider, "model": self.model, "source": self.source}


class ModelConfigurationReader:
    """Reread the selected CLI's files for every panel refresh and model request."""

    def __init__(self, home: Path | None = None, environment: Mapping[str, str] | None = None) -> None:
        self.home = Path.home() if home is None else home
        self.environment = os.environ if environment is None else environment

    def read(self, provider: object, *, include_credentials: bool = False) -> ModelConfiguration:
        """Resolve only the two approved providers and redact parser/authentication failures."""
        if provider not in ("codex", "qwen"):
            raise ModelConfigurationError("模型来源必须是 codex 或 qwen。")
        source = "~/.codex/config.toml" if provider == "codex" else "~/.qwen/settings.json"
        try:
            if provider == "codex":
                model, options = self._codex(include_credentials)
            else:
                model, options = self._qwen(include_credentials)
            return ModelConfiguration(provider, model, source, options)
        except ModelConfigurationError:
            raise
        except (OSError, ValueError, TypeError, KeyError, AttributeError):
            # JSON/TOML exceptions can contain source lines, including an embedded API key.
            raise ModelConfigurationError(f"配置读取失败，请检查 {source}。") from None

    def client(self, provider: object, timeout: float, reasoning: object = "fastest") -> ChatOpenAI:
        """Overlay App reasoning on a copy; source settings and other generation options stay intact."""
        configuration = self.read(provider, include_credentials=True)
        options = deepcopy(configuration.options)
        allowed = ("fastest", "medium", "high", "xhigh") if provider == "codex" else ("fastest", "thinking")
        if reasoning not in allowed:
            raise ModelConfigurationError("推理强度不适用于所选模型，请在模型切换面板重新选择。")
        if provider == "codex":
            # The current Codex provider supports low as its fastest effort, not none/minimal.
            options["reasoning_effort"] = "low" if reasoning == "fastest" else reasoning
        else:
            options["extra_body"]["enable_thinking"] = reasoning == "thinking"
        try:
            return ChatOpenAI(model=configuration.model, timeout=timeout, max_retries=0,
                              **options)
        except Exception:
            # SDK validation errors can print the rejected configuration, including credentials.
            raise ModelConfigurationError(f"模型配置不可用，请检查 {configuration.source}。") from None

    def _codex(self, include_credentials: bool) -> tuple[str, dict[str, Any]]:
        """Respect the selected TOML provider and its Responses/reasoning settings."""
        with (self.home / ".codex/config.toml").open("rb") as file:
            settings = tomllib.load(file)
        if "profile" in settings:
            settings = {**settings, **settings["profiles"][settings["profile"]]}
        model = self._required_string(settings["model"])
        provider_id = settings.get("model_provider", "openai")
        if provider_id == "openai":
            provider = settings.get("model_providers", {}).get("openai", {})
            base_url = provider.get("base_url", "https://api.openai.com/v1")
        else:
            provider = settings["model_providers"][provider_id]
            base_url = provider["base_url"]
        wire_api = provider.get("wire_api", "responses")
        if wire_api not in ("responses", "chat"):
            raise ValueError("Unsupported wire API")
        options: dict[str, Any] = {
            "base_url": self._required_string(base_url),
            "use_responses_api": wire_api == "responses",
            "temperature": None,
        }
        if "model_reasoning_effort" in settings:
            options["reasoning_effort"] = self._required_string(settings["model_reasoning_effort"])
        if wire_api == "responses":
            options["store"] = False
        if include_credentials:
            if "env_key" in provider:
                key = self.environment.get(provider["env_key"])
            else:
                auth = json.loads((self.home / ".codex/auth.json").read_text(encoding="utf-8"))
                key = auth.get("OPENAI_API_KEY")
            if not isinstance(key, str) or not key.strip():
                raise ModelConfigurationError("Codex API Key 不可用，请检查 .codex 的认证配置。")
            options["api_key"] = key.strip()
        return model, options

    def _qwen(self, include_credentials: bool) -> tuple[str, dict[str, Any]]:
        """Match name plus endpoint so Standard and Coding Plan entries cannot be mixed."""
        settings = json.loads((self.home / ".qwen/settings.json").read_text(encoding="utf-8"))
        if settings["security"]["auth"]["selectedType"] != "openai":
            raise ModelConfigurationError("Qwen 当前不是 OpenAI 兼容接入，请检查 .qwen/settings.json。")
        model = self._required_string(settings["model"]["name"])
        base_url = self._required_string(settings["model"]["baseUrl"])
        candidates = [entry for entry in settings["modelProviders"]["openai"]
                      if entry["id"] == model and entry.get("baseUrl") == base_url]
        if len(candidates) != 1:
            raise ModelConfigurationError("Qwen 当前模型与服务地址未唯一匹配，请检查 .qwen/settings.json。")
        provider = candidates[0]
        generation = provider.get("generationConfig", {})
        options: dict[str, Any] = {
            "base_url": base_url,
            "temperature": generation.get("temperature"),
            "extra_body": generation.get("extra_body", {}),
            # Qwen thinking may require streaming; invoke still returns one complete answer.
            "streaming": True,
            "use_responses_api": False,
        }
        if include_credentials:
            env_key = self._required_string(provider["envKey"])
            # CLI-owned settings take precedence over the translator's legacy .env/Keychain exports.
            key = settings.get("env", {}).get(env_key)
            if key is None:
                key = self.environment.get(env_key)
            if not isinstance(key, str) or not key.strip():
                raise ModelConfigurationError("Qwen API Key 不可用，请检查 .qwen 中引用的环境变量。")
            options["api_key"] = key.strip()
        return model, options

    @staticmethod
    def _required_string(value: Any) -> str:
        """Reject missing config values instead of sending a different implicit SDK default."""
        if not isinstance(value, str) or not value.strip():
            raise ValueError("Expected a non-empty string")
        return value.strip()
