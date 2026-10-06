"""Check the chat UI regression fixture and its actual SSE wire format."""
import json
from pathlib import Path
import socket
import subprocess
import sys
import time
import unittest
from urllib.request import Request, urlopen


class ChatStandinTests(unittest.TestCase):
    def setUp(self):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        self.base = "http://127.0.0.1:%d" % port
        script = Path(__file__).resolve().parents[1] / "standin.py"
        self.process = subprocess.Popen([sys.executable, str(script), str(port)],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(self.stop)
        for _ in range(50):
            try:
                self.get("/api/ping")
                break
            except OSError:
                time.sleep(0.05)
        else:
            self.fail("stand-in did not start")

    def stop(self):
        self.process.terminate()
        self.process.wait(timeout=5)

    def get(self, path):
        with urlopen(self.base + path, timeout=5) as response:
            return json.load(response)

    def event(self, stream):
        for _ in range(10):
            line = stream.readline().decode()
            if line.startswith("data: "):
                return json.loads(line[6:])
        self.fail("no chat event")

    def test_offline_default_is_unchanged(self):
        self.assertEqual(self.get("/api/chat"), {"running": False, "messages": []})
        self.assertEqual(self.get("/api/session")["script"],
                         "The first line of the script.\n\nThe second paragraph.")

    def test_long_reply_keeps_identity_and_streams_completion(self):
        self.get("/test/chat/start")
        chat = self.get("/api/chat")
        # 24 earlier messages, 5 + 2 tool steps, a reply and the latest one.
        self.assertEqual(len(chat["messages"]), 33)
        self.assertTrue(chat["running"])
        last = chat["messages"][-1]
        with urlopen(self.base + "/api/events", timeout=5) as stream:
            event = self.event(stream)
            self.assertEqual(event["type"], "chat")
            self.assertEqual(event["id"], "Tests/offline-video")
            self.assertEqual(event["count"], 33)
            self.assertEqual(event["tail"], [last])
            self.get("/test/chat/grow")
            event = self.event(stream)
            self.assertEqual(event["tail"][0]["id"], last["id"])
            self.assertGreater(len(event["tail"][0]["text"]), 4000)
            self.assertEqual(self.get("/api/session")["chat"], self.get("/api/chat"))
            self.get("/test/chat/finish")
            event = self.event(stream)
            self.assertFalse(event["running"])
            self.assertTrue(event["tail"][0]["done"])
            request = Request(self.base + "/api/chat?id=Tests/offline-video",
                              data=json.dumps({"text": "A message from history"}).encode(),
                              headers={"Content-Type": "application/json"})
            with urlopen(request, timeout=5) as response:
                self.assertEqual(response.status, 200)
            event = self.event(stream)
            self.assertEqual(event["count"], 34)
            self.assertEqual(event["tail"][0]["role"], "user")
            self.assertEqual(event["tail"][0]["text"], "A message from history")


if __name__ == "__main__":
    unittest.main()
