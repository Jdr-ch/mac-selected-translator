"""Focused request-policy and local HTTP coverage without remote model calls."""

from __future__ import annotations

from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
import json
from threading import Thread
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

import httpx
from openai import APITimeoutError

from backend.translator_agent.agent import TranslationError, TranslatorAgent
from backend.translator_agent.polishing import TONE_INSTRUCTIONS
from backend.translator_agent.server import TranslatorRequestHandler


class PolishingTests(unittest.TestCase):
    """Exercise the six approved tones and preserve the structured source/context boundary."""

    def setUp(self) -> None:
        self.agent = TranslatorAgent.__new__(TranslatorAgent)
        self.agent._llm = Mock()
        self.agent._llm.invoke.return_value = SimpleNamespace(content="接口开发已完成。\n请协助联调。")

    def test_every_tone_uses_original_text_and_same_language_policy(self) -> None:
        source = "库存接口还没好，弄好后叫我一下。保留 skuId 和 https://example.com/123。"
        self.assertEqual(len(TONE_INSTRUCTIONS), 6)
        for tone in TONE_INSTRUCTIONS:
            with self.subTest(tone=tone):
                self.assertEqual(
                    self.agent.polish(source, "前端开发工程师", "办公", tone),
                    "接口开发已完成。\n请协助联调。",
                )
                system, user = self.agent._llm.invoke.call_args.args[0]
                self.assertIn(TONE_INSTRUCTIONS[tone], system.content)
                self.assertIn("不进行翻译", system.content)
                self.assertIn("不增加原文没有的事实", system.content)
                self.assertIn("代码标识符", system.content)
                self.assertEqual(json.loads(user.content), {
                    "role": "前端开发工程师", "scenario": "办公", "text": source,
                })

    def test_invalid_context_or_tone_is_rejected_before_model_call(self) -> None:
        for role, scenario, tone in [
            ("", "办公", "professional"), ("开发", " ", "professional"),
            (["开发"], "办公", "professional"), ("开发", "办公", "unknown"),
            ("开发", "办公", []), ("开" * 101, "办公", "professional"),
        ]:
            with self.subTest(role=role, scenario=scenario, tone=tone):
                with self.assertRaises(ValueError):
                    self.agent.polish("原文", role, scenario, tone)
        self.agent._llm.invoke.assert_not_called()

    def test_empty_result_is_a_polishing_error(self) -> None:
        self.agent._llm.invoke.return_value = SimpleNamespace(content=" ")
        with self.assertRaisesRegex(TranslationError, "空润色结果"):
            self.agent.polish("原文", "开发", "办公", "professional")


class PolishingHTTPTests(unittest.TestCase):
    """Verify real JSON routing on an isolated ephemeral port with a stub model."""

    def setUp(self) -> None:
        agent = TranslatorAgent.__new__(TranslatorAgent)
        agent._llm = Mock()
        agent._llm.invoke.return_value = SimpleNamespace(content="商品列表页开发已完成。\n接口就绪后联调。")
        self.agent = agent

        class Handler(TranslatorRequestHandler):
            """Keep handler dependencies isolated from the application's running backend."""

            def _agent_for_provider(self, provider: object) -> TranslatorAgent:
                return agent

            def log_message(self, format: str, *args: object) -> None:
                pass

        Handler.settings = SimpleNamespace(max_input_chars=8000, request_timeout_seconds=120)
        Handler.models = SimpleNamespace(client=lambda provider, timeout: agent._llm)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def post(self, path: str, payload: dict) -> tuple[int, dict]:
        """Send UTF-8 through the actual request handler, retaining response status and JSON."""
        connection = HTTPConnection(*self.server.server_address, timeout=3)
        try:
            connection.request("POST", path, json.dumps(payload, ensure_ascii=False).encode(), {
                "Content-Type": "application/json",
            })
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def test_polish_returns_plain_output_and_translation_contract_stays_available(self) -> None:
        status, payload = self.post("/polish", {
            "text": "商品列表页写完了", "role": "前端开发工程师", "scenario": "办公", "tone": "polite",
        })
        self.assertEqual(status, 200)
        self.assertEqual(payload, {"polished_text": "商品列表页开发已完成。\n接口就绪后联调。"})
        status, payload = self.post("/translate", {"text": "one two three four five six"})
        self.assertEqual(status, 200)
        self.assertIn("translation", payload)

    def test_request_validation_preserves_actionable_error(self) -> None:
        base = {"text": "原文", "role": "开发", "scenario": "办公", "tone": "professional"}
        for field, value, expected in [
            ("text", "", "原文"), ("text", "文" * 8001, "8000"),
            ("role", "", "角色"), ("scenario", None, "场景"), ("tone", "unknown", "语气"),
        ]:
            with self.subTest(field=field):
                status, payload = self.post("/polish", {**base, field: value})
                self.assertEqual(status, 400)
                self.assertIn(expected, payload["error"])

    def test_model_timeout_is_not_reported_as_an_authentication_failure(self) -> None:
        self.agent._llm.invoke.side_effect = APITimeoutError(
            request=httpx.Request("POST", "https://example.invalid/private-endpoint"))
        for path in ("/translate", "/polish", "/flowchart"):
            status, payload = self.post(path, {"text": "one two three four five six", "provider": "codex",
                                              "role": "开发", "scenario": "办公", "tone": "polite"})
            self.assertEqual(status, 504)
            self.assertEqual(payload, {"error": "模型响应超时，请稍后重试。"})


if __name__ == "__main__":
    unittest.main()
