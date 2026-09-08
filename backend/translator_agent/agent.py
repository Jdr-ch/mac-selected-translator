"""LangChain translation agent.

The desktop client sends selected text and receives a compact translation card.
Keeping prompt policy and model calls in one class gives the macOS layer a
stable local API while still allowing future agent features such as glossary
lookup, rewrite modes, and history tools.
"""

from __future__ import annotations

import re

import jieba
from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, SystemMessage
from langchain_openai import ChatOpenAI

from .config import Settings
from .polishing import polish_messages



MAX_PHONETIC_WORDS = 5
LATIN_LETTERS = "A-Za-zÀ-ÖØ-öø-ÿĀ-ſ\u1e00-\u1eff"
ENGLISH_WORD_PATTERN = re.compile(
    rf"[{LATIN_LETTERS}]+(?:['’-][{LATIN_LETTERS}]+)*"
)
CHINESE_TOKEN_PATTERN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]")
IPA_TRANSCRIPTION_PATTERN = re.compile(r"/[^/\n]+/")
PHONETIC_ENTRY_PATTERN = re.compile(
    rf"([{LATIN_LETTERS}]+(?:['’-][{LATIN_LETTERS}]+)*)\s+/[^/\n]+/"
)
URL_PATTERN = re.compile(
    r"(?:https?://|www\.)\S+|\b[A-Za-z0-9.-]+\.[A-Za-z]{2,}(?:/\S*)?",
    re.IGNORECASE,
)
INLINE_CODE_PATTERN = re.compile(r"`[^`\n]+`")
IPA_SIGNAL_CHARACTERS = "ˈˌɑɐɒæɓʙβɔɕçɗɖðʤəɚɛɜɝɞɟʄɡɢʛɦɧħɥʜɨɪʝɭɬʟɮɱɯɰŋɳɲɴøɵɸœɶɹɺɻɾʀʁɽʂʃʈθʊʋⱱʌɣɤχʎʐʑʒʔʕ"
STANDALONE_TRANSCRIPTION_PATTERN = re.compile(
    rf"(?<!\S)/(?=[^/\n]*[{IPA_SIGNAL_CHARACTERS}])[^/\n]+/(?!\S)"
)


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

        requires_phonetics = self._requires_phonetics(clean_text)

        # `target_language` stays in the public API for older desktop builds,
        # but the product now chooses direction from the selected text itself.
        messages = [
            SystemMessage(content=self._system_prompt(requires_phonetics)),
            HumanMessage(content=f"原文：\n{clean_text}"),
        ]

        content = self._invoke(messages)
        if requires_phonetics and not self._has_valid_phonetics(content, clean_text):
            content = self._retry_with_phonetics(messages, content)
            if not self._has_valid_phonetics(content, clean_text):
                # Phonetics enrich the result but must not make a valid
                # translation fail when the model cannot supply reliable IPA.
                content = self._removing_phonetics_line(content)
        elif not requires_phonetics:
            content = self._removing_phonetics_line(content)

        return content

    def polish(self, text: str, role: object, scenario: object, tone: object) -> str:
        """Rewrite original text using the existing configured model and a separate prompt policy."""

        messages = polish_messages(text, role, scenario, tone)
        response = self._llm.invoke(messages)
        content = self._coerce_content(response.content).strip()
        if not content:
            raise TranslationError("模型返回了空润色结果，请重试。")
        return content

    @classmethod
    def _requires_phonetics(cls, text: str) -> bool:
        """Return whether a bilingual selection falls within the 1-5 word rule."""

        word_count = cls._selected_word_count(text)
        return 1 <= word_count <= MAX_PHONETIC_WORDS

    @staticmethod
    def _selected_word_count(text: str) -> int:
        """Count English and Chinese words without counting punctuation as words.

        English contractions and hyphenated expressions count as one word. The
        remaining Chinese text is segmented with jieba so an unspaced sentence
        does not collapse into a single word.
        """

        natural_text = URL_PATTERN.sub(" ", INLINE_CODE_PATTERN.sub(" ", text))
        english_words = ENGLISH_WORD_PATTERN.findall(natural_text)
        chinese_text = ENGLISH_WORD_PATTERN.sub(" ", natural_text)
        chinese_words = [
            token
            for token in jieba.lcut(chinese_text, cut_all=False)
            if CHINESE_TOKEN_PATTERN.search(token)
        ]
        return len(english_words) + len(chinese_words)

    @staticmethod
    def _system_prompt(requires_phonetics: bool) -> str:
        """Build the response contract for the request's deterministic word count."""

        if requires_phonetics:
            phonetics_instruction = (
                "本次原文已由程序判定为 1-5 个词。"
                "必须在主译下一行输出且只输出一行“音标：...”。"
                "音标行必须覆盖英文原文和英文主译中出现的每个英文词。"
                "格式为“音标：word /IPA/；word /IPA/”，单词之间用中文分号分隔。"
                "音标行必须位于“候选：”之前，且不能使用短横线或项目符号开头。"
            )
        else:
            phonetics_instruction = (
                "本次原文不在 1-5 个词范围内，不得输出“音标：”行或任何 IPA。"
            )

        return (
            "你是一个桌面划词翻译和双语词典助手。"
            "先判断原文主要语言：主要是英文就翻译成简体中文，"
            "主要是中文就翻译成自然英文。"
            "候选译法必须使用目标语言。"
            "如果原文是单词、固定搭配或短语，必须给 3-6 个常用候选译法；"
            "如果候选依赖语境，要在括号里用很短的说明标明语境。"
            "例如中文“标准化的”可给 standardized、normalized、"
            "canonical、orthonormal（数学/线性代数语境）等候选。"
            "输出格式：第一行“主译：...”。"
            f"{phonetics_instruction}"
            "短词短语最后输出“候选：”并用短横线列出候选；"
            "每个候选必须独占一行，格式为“- 候选词（可选语境）”，"
            "候选词放在短横线后的第一段，语境说明只能放在括号里。"
            "不得把音标追加到候选行。"
            "句子或段落不要为了凑候选添加同义改写。"
            "不要输出 Markdown 标题、引号或寒暄。"
            "保留原文中的代码标识符、URL、数字和必要换行。"
        )

    def _invoke(self, messages: list[BaseMessage]) -> str:
        """Invoke Qwen and normalize the response into a non-empty string."""

        response = self._llm.invoke(messages)
        content = self._coerce_content(response.content).strip()
        if not content:
            raise TranslationError("模型返回了空译文。")
        return content

    def _retry_with_phonetics(self, messages: list[BaseMessage], content: str) -> str:
        """Retry once when a short selection omits or misplaces the IPA line."""

        correction = HumanMessage(
            content=(
                "上一版缺少合规音标行或顺序错误。请完整重写结果并保持原译义："
                "第一行是“主译：...”，第二行是“音标：word /IPA/”，"
                "音标行必须逐一覆盖每个英文词，"
                "候选区必须位于音标行之后。只输出修正后的完整结果。"
            )
        )
        return self._invoke([*messages, AIMessage(content=content), correction])

    @classmethod
    def _has_valid_phonetics(cls, content: str, source_text: str) -> bool:
        """Validate IPA placement and one transcription for every expected English word."""

        lines = [line.strip() for line in content.splitlines() if line.strip()]
        main_index = next(
            (index for index, line in enumerate(lines) if line.startswith(("主译：", "主译:"))),
            None,
        )
        phonetics_indices = [
            index
            for index, line in enumerate(lines)
            if line.startswith(("音标：", "音标:"))
        ]
        candidate_index = next(
            (index for index, line in enumerate(lines) if line in ("候选：", "候选:")),
            None,
        )

        if main_index is None or len(phonetics_indices) != 1:
            return False
        phonetics_index = phonetics_indices[0]
        phonetics_line = lines[phonetics_index]
        if phonetics_index <= main_index or not IPA_TRANSCRIPTION_PATTERN.search(phonetics_line):
            return False
        if candidate_index is not None and phonetics_index >= candidate_index:
            return False

        expected_words = cls._expected_phonetic_words(source_text, lines[main_index])
        phonetic_words = {
            cls._normalized_english_word(match.group(1))
            for match in PHONETIC_ENTRY_PATTERN.finditer(phonetics_line)
        }
        return bool(expected_words) and expected_words.issubset(phonetic_words)

    @classmethod
    def _expected_phonetic_words(cls, source_text: str, main_line: str) -> set[str]:
        """Collect every English word present in either the source or main result."""

        source_words = ENGLISH_WORD_PATTERN.findall(
            URL_PATTERN.sub(" ", INLINE_CODE_PATTERN.sub(" ", source_text))
        )
        _, separator, main_translation = main_line.partition("：")
        if not separator:
            _, _, main_translation = main_line.partition(":")
        words = [*source_words, *ENGLISH_WORD_PATTERN.findall(main_translation)]
        return {cls._normalized_english_word(word) for word in words}

    @staticmethod
    def _normalized_english_word(word: str) -> str:
        """Normalize case and apostrophe variants before comparing IPA coverage."""

        return word.casefold().replace("’", "'")

    @staticmethod
    def _removing_phonetics_line(content: str) -> str:
        """Hide IPA when phonetics are not required or cannot be validated."""

        lines: list[str] = []
        for line in content.splitlines():
            if line.strip().startswith(("音标：", "音标:")):
                continue
            cleaned_line = STANDALONE_TRANSCRIPTION_PATTERN.sub("", line).rstrip()
            if cleaned_line.strip():
                lines.append(cleaned_line)
        return "\n".join(lines).strip()

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
