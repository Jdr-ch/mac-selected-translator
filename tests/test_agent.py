"""Focused tests for the translator's short-selection IPA contract."""

from __future__ import annotations

from types import SimpleNamespace
import unittest

from backend.translator_agent.agent import TranslationError, TranslatorAgent


class StubLLM:
    """Return predefined model responses while retaining request messages."""

    def __init__(self, responses: list[str]) -> None:
        self._responses = iter(responses)
        self.calls: list[list[object]] = []

    def invoke(self, messages: list[object]) -> SimpleNamespace:
        """Record one invocation and expose the next response as message content."""

        self.calls.append(messages)
        return SimpleNamespace(content=next(self._responses))


class TranslatorAgentPhoneticsTests(unittest.TestCase):
    """Protect the five-word boundary and the plain-text response layout."""

    def make_agent(self, responses: list[str]) -> tuple[TranslatorAgent, StubLLM]:
        """Construct an agent without creating the real network-backed ChatOpenAI client."""

        llm = StubLLM(responses)
        agent = TranslatorAgent.__new__(TranslatorAgent)
        agent._llm = llm
        return agent, llm

    def test_english_word_count_has_exact_five_word_boundary(self) -> None:
        self.assertTrue(TranslatorAgent._requires_phonetics("one two three four five"))
        self.assertFalse(
            TranslatorAgent._requires_phonetics("one two three four five six")
        )

    def test_contractions_and_hyphenated_terms_each_count_as_one_word(self) -> None:
        self.assertEqual(
            TranslatorAgent._selected_word_count("don't use state-of-the-art tools"),
            4,
        )

    def test_accented_latin_words_keep_the_five_word_boundary(self) -> None:
        self.assertTrue(
            TranslatorAgent._requires_phonetics("café naïve résumé déjà vu")
        )

    def test_url_and_inline_code_do_not_trigger_phonetics(self) -> None:
        self.assertFalse(
            TranslatorAgent._requires_phonetics("https://example.com/a/b")
        )
        self.assertFalse(TranslatorAgent._requires_phonetics("`someVariable`"))

    def test_chinese_and_mixed_text_use_the_same_boundary(self) -> None:
        self.assertTrue(TranslatorAgent._requires_phonetics("苹果 香蕉 西瓜 葡萄 桃子"))
        self.assertFalse(
            TranslatorAgent._requires_phonetics("苹果 香蕉 西瓜 葡萄 桃子 梨")
        )
        self.assertEqual(TranslatorAgent._selected_word_count("翻译 hello world"), 3)

    def test_mixed_selection_covers_source_and_main_translation_words(self) -> None:
        agent, llm = self.make_agent(
            [
                "主译：translate hello\n音标：hello /həˈloʊ/",
                "主译：translate hello\n"
                "音标：translate /trænzˈleɪt/；hello /həˈloʊ/",
            ]
        )

        result = agent.translate("翻译 hello")

        self.assertIn("translate /trænzˈleɪt/", result)
        self.assertEqual(len(llm.calls), 2)

    def test_short_selection_requires_phonetics_before_candidates(self) -> None:
        agent, llm = self.make_agent(
            [
                "主译：你好\n"
                "音标：hello /həˈloʊ/\n"
                "候选：\n"
                "- 你好（日常问候）"
            ]
        )

        result = agent.translate("hello")

        self.assertIn("音标：hello /həˈloʊ/", result)
        system_prompt = llm.calls[0][0].content
        self.assertIn("必须在主译下一行输出", system_prompt)
        self.assertEqual(len(llm.calls), 1)

    def test_chinese_selection_accepts_ascii_output_markers(self) -> None:
        agent, llm = self.make_agent(
            ["主译: hello\n音标: hello /həˈloʊ/\n候选:\n- hello（日常问候）"]
        )

        result = agent.translate("你好")

        self.assertIn("音标: hello /həˈloʊ/", result)
        self.assertEqual(len(llm.calls), 1)

    def test_short_selection_retries_once_when_phonetics_are_missing(self) -> None:
        agent, llm = self.make_agent(
            [
                "主译：你好\n候选：\n- 你好（日常问候）",
                "主译：你好\n音标：hello /həˈloʊ/\n候选：\n- 你好（日常问候）",
            ]
        )

        result = agent.translate("hello")

        self.assertIn("音标：hello /həˈloʊ/", result)
        self.assertEqual(len(llm.calls), 2)

    def test_five_word_selection_retries_when_any_word_lacks_phonetics(self) -> None:
        agent, llm = self.make_agent(
            [
                "主译：一二三四五\n音标：one /wʌn/",
                "主译：一二三四五\n"
                "音标：one /wʌn/；two /tuː/；three /θriː/；"
                "four /fɔːr/；five /faɪv/",
            ]
        )

        result = agent.translate("one two three four five")

        self.assertIn("five /faɪv/", result)
        self.assertEqual(len(llm.calls), 2)

    def test_short_selection_fails_after_two_invalid_responses(self) -> None:
        agent, _ = self.make_agent(["主译：你好", "主译：你好"])

        with self.assertRaisesRegex(TranslationError, "IPA 音标"):
            agent.translate("hello")

    def test_long_selection_removes_an_unexpected_phonetics_line(self) -> None:
        agent, llm = self.make_agent(
            [
                "主译：这是一个较长的句子\n"
                "音标：this /ðɪs/\n"
                "补充：this /ðɪs/\n"
                "正则：/foo/\n"
                "这是补充说明。"
            ]
        )

        result = agent.translate("one two three four five six")

        self.assertNotIn("音标：", result)
        self.assertNotIn("/ðɪs/", result)
        self.assertIn("/foo/", result)
        self.assertIn("不得输出", llm.calls[0][0].content)


if __name__ == "__main__":
    unittest.main()
