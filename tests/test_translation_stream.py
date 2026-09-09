"""Exercise flushed HTTP delivery with a producer that waits for the first client read."""

from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
import json
from threading import Event, Thread
from types import SimpleNamespace
import unittest

from backend.translator_agent.server import TranslatorRequestHandler


class TranslationStreamHTTPTests(unittest.TestCase):
    def test_first_event_precedes_generation_completion_and_errors_are_terminal(self) -> None:
        release = Event()
        fail = False

        class Agent:
            def translate(self, text, language, on_delta=None):
                on_delta("主译：你")
                if not release.wait(3):
                    raise RuntimeError("client failed to read first event")
                if fail:
                    raise RuntimeError("private upstream credential details")
                on_delta("好\n音标：hello /həˈloʊ/\n候选：\n- 你好")
                return "主译：你好\n音标：hello /həˈloʊ/\n候选：\n- 你好"

        class Handler(TranslatorRequestHandler):
            settings = SimpleNamespace(max_input_chars=8000)

            def _agent_for_provider(self, provider, reasoning):
                return Agent()

            def log_message(self, format, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            for fail in (False, True):
                release.clear()
                connection = HTTPConnection(*server.server_address, timeout=4)
                try:
                    connection.request("POST", "/translate", json.dumps({"text": "hello", "stream": True}),
                                       {"Content-Type": "application/json"})
                    response = connection.getresponse()
                    self.assertEqual(response.status, 200)
                    self.assertIn("application/x-ndjson", response.getheader("Content-Type"))
                    self.assertEqual(json.loads(response.readline()), {"type": "delta", "text": "主译：你"})
                    release.set()
                    events = [json.loads(line) for line in response.read().splitlines()]
                    if fail:
                        self.assertEqual([event["type"] for event in events], ["error"])
                        self.assertNotIn("private", json.dumps(events))
                    else:
                        self.assertEqual([event["type"] for event in events], ["delta", "complete"])
                        self.assertTrue(events[-1]["translation"].startswith("主译：你好"))
                        self.assertGreaterEqual(events[-1]["ai_ms"], 0)
                finally:
                    release.set()
                    connection.close()
        finally:
            release.set()
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
