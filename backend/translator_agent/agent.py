"""LangChain translation agent.

The current product need is deliberately narrow: translate the selected text
and return only the translated content. Keeping the prompt and model call in one
class gives the macOS layer a stable local API while still allowing future
agent features such as glossary lookup, rewrite modes, and history tools.
"""

from __future__ import annotations

from langchain_core.messages import HumanMessage, SystemMessage
from langchain_openai import ChatOpenAI

from .config import Settings


class TranslationError(RuntimeError):
    """Raised when the model returns an empty or malformed translation."""


class TranslatorAgent:
    """Small LangChain-backed agent that translates text with Qwen.

    The Qwen thinking switch is passed through `extra_body` because DashScope's
    OpenAI-compatible endpoint accepts provider-specific request fields there.
    Translation is latency-sensitive, so thinking mode is disabled by default.
    """

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._llm = ChatOpenAI(
            api_key=settings.api_key,
            base_url=settings.base_url,
            model=settings.model,
            temperature=0,
            timeout=settings.request_timeout_seconds,
            max_retries=1,
            extra_body={"enable_thinking": False},
        )

    def translate(self, text: str, target_language: str | None = None) -> str:
        """Translate selected text and return the model's final content.

        Args:
            text: Raw text captured from the foreground macOS application.
            target_language: Optional target language from the desktop client.

        Raises:
            TranslationError: When the selected text is empty or the model does
                not provide a usable response.
        """

        clean_text = text.strip()
        if not clean_text:
            raise TranslationError("未读取到可翻译的选中文字。")

        target = (target_language or self._settings.default_target_language).strip()
        messages = [
            SystemMessage(
                content=(
                    "你是一个桌面划词翻译助手。"
                    "请只输出译文，不输出解释、引号、Markdown 标题或额外寒暄。"
                    "保留原文中的换行、列表层次、代码标识符、URL 和数字。"
                )
            ),
            HumanMessage(content=f"目标语言：{target}\n\n原文：\n{clean_text}"),
        ]

        response = self._llm.invoke(messages)
        content = self._coerce_content(response.content).strip()
        if not content:
            raise TranslationError("模型返回了空译文。")
        return content

    @staticmethod
    def _coerce_content(content: object) -> str:
        """Normalize LangChain message content into plain text.

        Most chat models return a string, but OpenAI-compatible providers may
        surface a list of text blocks. Normalizing here keeps the HTTP contract
        simple for the Swift app.
        """

        if isinstance(content, str):
            return content

        if isinstance(content, list):
            parts: list[str] = []
            for item in content:
                if isinstance(item, str):
                    parts.append(item)
                elif isinstance(item, dict) and isinstance(item.get("text"), str):
                    parts.append(item["text"])
            return "\n".join(parts)

        return str(content)
