"""Model selection tests use disposable CLI homes and in-process HTTP transports only."""

from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Thread
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import httpx
from langchain_openai import ChatOpenAI

from backend.translator_agent.agent import TranslatorAgent
from backend.translator_agent.config import ConfigError, Settings
from backend.translator_agent.flowchart import FlowchartAgent
from backend.translator_agent.model_config import ModelConfigurationError, ModelConfigurationReader
from backend.translator_agent.server import TranslatorRequestHandler


class ModelConfigurationTests(unittest.TestCase):
    """Protect source ownership, fresh reads and the two providers' different wire protocols."""

    def test_runtime_timeout_ignores_legacy_short_limit_and_accepts_shared_budget(self) -> None:
        with patch.dict("os.environ", {"QWEN_REQUEST_TIMEOUT_SECONDS": "30"}, clear=True):
            self.assertEqual(Settings.from_env().request_timeout_seconds, 120)
        with patch.dict("os.environ", {"TRANSLATOR_REQUEST_TIMEOUT_SECONDS": "180"}, clear=True):
            self.assertEqual(Settings.from_env().request_timeout_seconds, 180)
        for value in ("0", "-1", "nan", "inf"):
            with patch.dict("os.environ", {"TRANSLATOR_REQUEST_TIMEOUT_SECONDS": value}, clear=True):
                with self.assertRaises(ConfigError):
                    Settings.from_env()

    def setUp(self) -> None:
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.home = Path(self.directory.name)
        (self.home / ".codex").mkdir()
        (self.home / ".qwen").mkdir()
        self.codex_path = self.home / ".codex/config.toml"
        self.codex_path.write_text(
            'model = "gpt-test"\nmodel_provider = "custom"\nmodel_reasoning_effort = "high"\n'
            '[model_providers.custom]\nbase_url = "https://codex.example/v1"\n'
            'wire_api = "responses"\nrequires_openai_auth = true\n', encoding="utf-8"
        )
        (self.home / ".codex/auth.json").write_text(json.dumps({"OPENAI_API_KEY": "fake-codex-key"}))
        self.qwen_path = self.home / ".qwen/settings.json"
        self.qwen = {
            "model": {"name": "qwen-test", "baseUrl": "https://qwen.example/v1"},
            "security": {"auth": {"selectedType": "openai"}},
            "env": {"DASHSCOPE_API_KEY": "fake-qwen-key", "CODING_KEY": "fake-other-key"},
            "modelProviders": {"openai": [
                {"id": "qwen-test", "baseUrl": "https://qwen.example/v1", "envKey": "DASHSCOPE_API_KEY",
                 "generationConfig": {"extra_body": {"enable_thinking": True}, "contextWindowSize": 1000000}},
                {"id": "qwen-test", "baseUrl": "https://coding.example/v1", "envKey": "CODING_KEY"},
            ]},
        }
        self.qwen_path.write_text(json.dumps(self.qwen))
        self.reader = ModelConfigurationReader(self.home, {"DASHSCOPE_API_KEY": "stale-translator-key"})

    def test_metadata_does_not_copy_secrets_and_configuration_remains_unchanged(self) -> None:
        originals = {path: path.read_bytes() for path in self.home.rglob("*") if path.is_file()}
        codex = self.reader.read("codex", include_credentials=True)
        qwen = self.reader.read("qwen", include_credentials=True)
        self.assertEqual(codex.options["api_key"], "fake-codex-key")
        self.assertEqual(qwen.options["api_key"], "fake-qwen-key")
        self.assertEqual(qwen.options["extra_body"], {"enable_thinking": True})
        self.assertEqual(codex.options["reasoning_effort"], "high")
        for snapshot in (codex, qwen):
            self.assertEqual(set(snapshot.metadata()), {"provider", "model", "source"})
            self.assertNotIn("fake-", json.dumps(snapshot.metadata()))
            self.assertNotIn("fake-", repr(snapshot))
        self.assertEqual(originals, {path: path.read_bytes() for path in originals})

    def test_external_edits_are_read_again_without_changing_existing_request_snapshot(self) -> None:
        first = self.reader.read("codex", include_credentials=True)
        self.codex_path.write_text(self.codex_path.read_text().replace("gpt-test", "gpt-updated"))
        self.assertEqual(self.reader.read("codex").model, "gpt-updated")
        self.assertEqual(first.model, "gpt-test")
        self.qwen["model"]["baseUrl"] = "https://coding.example/v1"
        self.qwen_path.write_text(json.dumps(self.qwen))
        changed = self.reader.read("qwen", include_credentials=True)
        self.assertEqual(changed.options["api_key"], "fake-other-key")
        self.assertEqual(changed.options["extra_body"], {})

    def test_invalid_or_missing_configuration_never_falls_back_or_echoes_file_contents(self) -> None:
        self.qwen_path.write_text('{"env": "secret-in-invalid-json" INVALID}')
        with self.assertRaises(ModelConfigurationError) as caught:
            self.reader.read("qwen")
        self.assertNotIn("secret-in-invalid-json", str(caught.exception))
        self.assertIn("~/.qwen/settings.json", str(caught.exception))
        self.assertEqual(self.reader.read("codex").model, "gpt-test")
        (self.home / ".codex/auth.json").unlink()
        self.assertEqual(self.reader.read("codex").model, "gpt-test")
        with self.assertRaises(ModelConfigurationError):
            self.reader.read("codex", include_credentials=True)
        with self.assertRaises(ModelConfigurationError):
            self.reader.read("../qwen")

    def test_actual_sdk_overrides_reasoning_without_changing_cli_settings(self) -> None:
        originals = {path: path.read_bytes() for path in self.home.rglob("*") if path.is_file()}
        requests = []
        diagram = {"title": "流程", "steps": [{"title": "步骤", "icon_id": "settings", "kind": "process"}]}
        answer = json.dumps(diagram)

        def respond(request: httpx.Request) -> httpx.Response:
            """Capture the actual SDK payload, returning a minimal Responses or streamed chat answer."""
            body = json.loads(request.content)
            requests.append((request.url, body, request.headers["authorization"]))
            if request.url.path == "/v1/responses":
                return httpx.Response(200, json={
                    "id": "resp_test", "object": "response", "created_at": 1,
                    "status": "completed", "model": "gpt-test",
                    "output": [{"id": "msg_test", "type": "message", "role": "assistant", "status": "completed",
                                "content": [{"type": "output_text", "text": answer, "annotations": []}]}],
                    "parallel_tool_calls": True, "tools": [], "tool_choice": "auto",
                })
            chunk = {"id": "chat_test", "object": "chat.completion.chunk", "created": 1,
                     "model": "qwen-test", "choices": [{"index": 0, "delta": {"role": "assistant", "content": answer},
                                                          "finish_reason": "stop"}]}
            return httpx.Response(200, headers={"content-type": "text/event-stream"},
                                  text="data: " + json.dumps(chunk) + "\n\ndata: [DONE]\n\n")

        with httpx.Client(transport=httpx.MockTransport(respond)) as transport:
            with patch("backend.translator_agent.model_config.ChatOpenAI",
                       side_effect=lambda **options: ChatOpenAI(http_client=transport, **options)):
                choices = [("codex", "fastest"), ("qwen", "fastest"), ("codex", "medium"),
                           ("codex", "high"), ("codex", "xhigh"), ("qwen", "thinking")]
                for provider, reasoning in choices:
                    client = self.reader.client(provider, timeout=30, reasoning=reasoning)
                    result = FlowchartAgent(client, max_input_chars=8000).generate("test")
                    self.assertEqual(result["diagram"]["steps"][0]["title"], "步骤")
                    self.assertEqual(result["model"], self.reader.read(provider).model)
        codex_url, codex_body, codex_auth = requests[0]
        self.assertEqual(str(codex_url), "https://codex.example/v1/responses")
        self.assertEqual(codex_body["reasoning"]["effort"], "low")
        self.assertNotIn("temperature", codex_body)
        self.assertNotIn("enable_thinking", codex_body)
        self.assertEqual(codex_auth, "Bearer fake-codex-key")
        qwen_url, qwen_body, qwen_auth = requests[1]
        self.assertEqual(str(qwen_url), "https://qwen.example/v1/chat/completions")
        self.assertFalse(qwen_body["enable_thinking"])
        self.assertTrue(qwen_body["stream"])
        self.assertNotIn("contextWindowSize", qwen_body)
        self.assertEqual(qwen_auth, "Bearer fake-qwen-key")
        self.assertEqual([body["reasoning"]["effort"] for _, body, _ in requests[2:5]],
                         ["medium", "high", "xhigh"])
        self.assertTrue(requests[5][1]["enable_thinking"])
        self.assertEqual(originals, {path: path.read_bytes() for path in originals})
        self.assertEqual(self.reader.read("codex").options["reasoning_effort"], "high")
        self.assertTrue(self.reader.read("qwen").options["extra_body"]["enable_thinking"])

    def test_default_fastest_does_not_mutate_loaded_snapshots_or_other_options(self) -> None:
        """Even a reused snapshot keeps nested generation settings intact across overrides."""
        for provider in ("codex", "qwen"):
            snapshot = self.reader.read(provider, include_credentials=True)
            before = json.dumps(snapshot.options, sort_keys=True)
            with patch.object(self.reader, "read", return_value=snapshot), \
                 patch("backend.translator_agent.model_config.ChatOpenAI") as factory:
                self.reader.client(provider, timeout=30)
                sent = factory.call_args.kwargs
                if provider == "codex":
                    self.assertEqual(sent["reasoning_effort"], "low")
                else:
                    self.assertFalse(sent["extra_body"]["enable_thinking"])
                self.assertEqual(sent["base_url"], snapshot.options["base_url"])
                self.assertEqual(sent["temperature"], snapshot.options["temperature"])
                self.assertEqual(json.dumps(snapshot.options, sort_keys=True), before)
        for provider, reasoning in [("codex", "thinking"), ("qwen", "high"), ("qwen", None)]:
            with self.assertRaises(ModelConfigurationError):
                self.reader.client(provider, timeout=30, reasoning=reasoning)

    def test_local_http_routes_provider_and_exposes_only_metadata(self) -> None:
        reader = self.reader
        selected = []

        class Handler(TranslatorRequestHandler):
            models = reader
            settings = SimpleNamespace(max_input_chars=8000)

            def _agent_for_provider(self, provider, reasoning):
                configuration = self.models.read(provider, include_credentials=True)
                selected.append((configuration.provider, reasoning))
                llm = Mock()
                llm.invoke.return_value = SimpleNamespace(content=configuration.model)
                return TranslatorAgent(llm)

            def log_message(self, format, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            for provider in ("codex", "qwen"):
                connection = HTTPConnection(*server.server_address, timeout=3)
                connection.request("GET", "/models/" + provider)
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertEqual(json.loads(response.read()), reader.read(provider).metadata())
                connection.close()
                for path in ("/translate", "/polish"):
                    connection = HTTPConnection(*server.server_address, timeout=3)
                    connection.request("POST", path, json.dumps({"provider": provider, "reasoning": "fastest",
                        "text": "one two three four five six", "role": "开发", "scenario": "办公", "tone": "polite"}),
                        {"Content-Type": "application/json"})
                    response = connection.getresponse()
                    self.assertEqual(response.status, 200)
                    self.assertIn(reader.read(provider).model, response.read().decode())
                    connection.close()
            self.assertEqual(selected, [(provider, "fastest") for provider in ("codex", "codex", "qwen", "qwen")])
            with patch.dict("os.environ", {}, clear=True):
                self.assertEqual(Settings.from_env().port, 8765)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
