"""验证真实桥接可执行文件的分帧、请求转发、响应和过期请求处理，不连接浏览器。"""
import json
from pathlib import Path
import select
import shutil
import struct
import subprocess
import time
import unittest
import uuid


class WorkspaceNativeHostTests(unittest.TestCase):
    def setUp(self):
        """每个测试使用独立资料令牌，仅清理本次创建的邮箱。"""
        self.token = str(uuid.uuid4())
        self.directory = Path.home() / "Library/Application Support/SelectedTextTranslator/WorkspaceScene/bridge" / self.token
        executable = Path(__file__).resolve().parents[1] / ".build/debug/WorkspaceChromeHost"
        self.process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.send({"protocolVersion": 1, "kind": "hello", "profileToken": self.token})
        self.assertEqual(self.receive()["kind"], "connected")

    def tearDown(self):
        """关闭测试子进程后删除该 UUID 的目录，不处理其他资料的桥接数据。"""
        self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=3)
        self.process.stdout.close()
        self.process.stderr.close()
        shutil.rmtree(self.directory, ignore_errors=True)

    def send(self, message):
        """通过真实 stdin 写入 Native Messaging 小端长度帧。"""
        data = json.dumps(message).encode()
        self.process.stdin.write(struct.pack("<I", len(data)) + data)
        self.process.stdin.flush()

    def receive(self):
        """读取完整输出帧，超时明确失败而不是挂住测试。"""
        self.assertTrue(select.select([self.process.stdout], [], [], 3)[0], "宿主没有返回消息")
        header = self.process.stdout.read(4)
        self.assertEqual(len(header), 4)
        return json.loads(self.process.stdout.read(struct.unpack("<I", header)[0]))

    def test_request_response_and_expiration(self):
        """过期恢复不会被重放，有效请求与响应按 UUID 完整关联。"""
        expired_id = str(uuid.uuid4())
        expired = self.directory / "commands" / f"{expired_id}.json"
        expired.write_text(json.dumps({"requestId": expired_id, "deadline": time.time() - 1}))
        request_id = str(uuid.uuid4())
        request = {"protocolVersion": 1, "requestId": request_id, "command": "capture", "deadline": time.time() + 5}
        (self.directory / "commands" / f"{request_id}.json").write_text(json.dumps(request))
        self.assertEqual(self.receive(), request)
        response = {"protocolVersion": 1, "kind": "result", "requestId": request_id, "ok": True, "payload": {"windows": []}}
        self.send(response)
        target = self.directory / "responses" / f"{request_id}.json"
        deadline = time.monotonic() + 3
        while not target.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertEqual(json.loads(target.read_text()), response)
        self.assertFalse(expired.exists())


if __name__ == "__main__":
    unittest.main()
