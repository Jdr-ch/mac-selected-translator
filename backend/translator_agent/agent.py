"""LangChain translation agent.

The desktop client sends selected text and receives a compact translation card.
Keeping prompt policy and model calls in one class gives the macOS layer a
stable local API while still allowing future agent features such as glossary
lookup, rewrite modes, and history tools.
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
            target_language: Kept for API compatibility; the current prompt
                auto-detects Chinese vs English instead of trusting the client.

        Raises:
            TranslationError: When the selected text is empty or the model does
                not provide a usable response.
        """

        clean_text = text.strip()
        if not clean_text:
            raise TranslationError("未读取到可翻译的选中文字。")

        # `target_language` stays in the public API for older desktop builds,
        # but the product now chooses direction from the selected text itself.
        messages = [
            SystemMessage(
                content=(
                    "你是一个桌面划词翻译和双语词典助手。"
                    "先判断原文主要语言：主要是英文就翻译成简体中文，"
                    "主要是中文就翻译成自然英文。"
                    "候选译法必须使用目标语言。"
                    "如果原文是单词、固定搭配或短语，必须给 3-6 个常用候选译法；"
                    "如果候选依赖语境，要在括号里用很短的说明标明语境。"
                    "例如中文“标准化的”可给 standardized、normalized、"
                    "canonical、orthonormal（数学/线性代数语境）等候选。"
                    "输出格式：第一行“主译：...”。"
                    "短词短语随后输出“候选：”并用短横线列出候选；"
                    "每个候选必须独占一行，格式为“- 候选词（可选语境）”，"
                    "候选词放在短横线后的第一段，语境说明只能放在括号里。"
                    "句子或段落不要为了凑候选添加同义改写。"
                    "不要输出 Markdown 标题、引号或寒暄。"
                    "保留原文中的代码标识符、URL、数字和必要换行。"
                )
            ),
            HumanMessage(content=f"原文：\n{clean_text}"),
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
