"""Focused diagram contract tests with isolated model clients and an ephemeral HTTP port."""

import json
from threading import Thread
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, call
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from http.server import ThreadingHTTPServer

from backend.translator_agent.config import Settings
from backend.translator_agent.flowchart import FlowchartAgent, FlowchartError, explicit_steps, validate_diagram
from backend.translator_agent.server import TranslatorRequestHandler


NAMES = ["语言文件", "编译器", "汇编代码", "汇编器", "二进制机器码", "链接器", "可执行exe文件"]


def document(names=NAMES):
    """Representative model output used only by tests; production always calls the configured service."""
    return {"title": "编译流程", "subtitle": "源代码到程序", "steps": [
        {"title": name, "description": "步骤说明", "kind": "process", "icon_id": "settings", "next_label": ""}
        for name in names
    ]}


class FlowchartTests(unittest.TestCase):
    def setUp(self):
        self.settings = Settings(host="127.0.0.1", port=0, request_timeout_seconds=2,
                                 max_input_chars=8000)
        self.llm = Mock(model_name="configured-model")
        self.llm.invoke.return_value = SimpleNamespace(content=json.dumps(document()))

    def test_explicit_chains_keep_all_nodes_without_splitting_english_hyphens(self):
        self.assertEqual(explicit_steps("描述编译型语言的执行过程：" + "-".join(NAMES)), NAMES)
        self.assertEqual(explicit_steps("A -> B -> C"), ["A", "B", "C"])
        self.assertEqual(explicit_steps("1. 语言文件\n2. 编译器"), NAMES[:2])
        self.assertIsNone(explicit_steps("Describe state-of-the-art compilation"))

    def test_one_call_uses_the_injected_configuration_snapshot(self):
        agent = FlowchartAgent(self.llm, self.settings.max_input_chars)
        result = agent.generate("-".join(NAMES))
        self.llm.invoke.assert_called_once()
        self.assertEqual(result["model"], "configured-model")
        self.assertEqual(result["diagram"]["steps"][0]["title"], NAMES[0])
        self.assertGreaterEqual(result["ai_ms"], 0)

    def test_invalid_or_reordered_output_is_rejected_without_another_ai_call(self):
        with self.assertRaises(FlowchartError):
            validate_diagram(document(list(reversed(NAMES))), NAMES)
        for invalid in [{}, {"title": "x", "steps": []}, document()]:
            if invalid.get("steps"):
                invalid["steps"][0]["icon_id"] = "https://example.invalid/icon.svg"
            with self.assertRaises(FlowchartError):
                validate_diagram(invalid)
        agent = FlowchartAgent(self.llm, self.settings.max_input_chars)
        self.llm.invoke.return_value = SimpleNamespace(content="broken JSON")
        with self.assertRaises(FlowchartError):
            agent.generate("请介绍编译流程")
        self.llm.invoke.assert_called_once()

    def test_empty_and_oversized_input_never_reaches_the_model(self):
        agent = FlowchartAgent(self.llm, max_input_chars=5)
        for text in ["", " ", None, "123456"]:
            with self.assertRaises(FlowchartError):
                agent.generate(text)
        self.llm.invoke.assert_not_called()

    def test_http_flowchart_and_translation_contracts_coexist(self):
        class Handler(TranslatorRequestHandler):
            def _agent_for_provider(self, provider):
                return SimpleNamespace(translate=lambda text, language: "主译：" + text)

        Handler.settings = self.settings
        factory = Mock(side_effect=lambda provider, timeout: Mock(
            model_name=provider + "-configured", invoke=Mock(return_value=SimpleNamespace(content=json.dumps(document())))))
        Handler.models = SimpleNamespace(client=factory)
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{server.server_port}"

        def post(path, payload):
            request = Request(base + path, data=json.dumps(payload).encode(),
                              headers={"Content-Type": "application/json"})
            with urlopen(request, timeout=3) as response:
                return json.load(response)

        try:
            for provider in ("codex", "qwen"):
                result = post("/flowchart", {"text": "-".join(NAMES), "provider": provider})
                self.assertEqual(result["model"], provider + "-configured")
                self.assertEqual(len(result["diagram"]["steps"]), 7)
            self.assertEqual(factory.call_args_list, [call("codex", 2), call("qwen", 2)])
            self.assertEqual(post("/translate", {"text": "hello"}), {"translation": "主译：hello"})
            with self.assertRaises(HTTPError) as failure:
                post("/flowchart", {"text": ""})
            self.assertEqual(failure.exception.code, 400)
            with urlopen(base + "/health", timeout=3) as response:
                self.assertIn("model-switching", json.load(response)["capabilities"])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)


if __name__ == "__main__":
    unittest.main()
