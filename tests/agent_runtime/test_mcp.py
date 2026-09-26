import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
import uuid


SCRIPT = Path(__file__).resolve().parents[2] / "mcp" / "search_mcp.py"


class MCPTest(unittest.TestCase):
    def exchange(self, process, ident, method, params=None):
        process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": ident, "method": method, "params": params or {}}) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())["result"]

    def test_handshake_and_tools(self):
        process = subprocess.Popen([sys.executable, str(SCRIPT)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, text=True)
        try:
            process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                            "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}}) + "\n")
            process.stdin.flush()
            initialized = json.loads(process.stdout.readline())
            self.assertEqual(initialized["result"]["serverInfo"]["name"], "search-browser")
            process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
            process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}) + "\n")
            process.stdin.flush()
            tools = json.loads(process.stdout.readline())["result"]["tools"]
            self.assertIn("search_browser_act_goal", {item["name"] for item in tools})
            self.assertIn("search_browser_create_session", {item["name"] for item in tools})
        finally:
            process.terminate()
            process.wait(timeout=5)
            process.stdin.close()
            process.stdout.close()

    @unittest.skipUnless(os.environ.get("SEARCH_AGENT_DISCOVERY"), "Runtime discovery not supplied")
    def test_two_mcp_clients_share_one_runtime(self):
        processes = [subprocess.Popen([sys.executable, str(SCRIPT)], stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, text=True) for _ in range(2)]
        try:
            sessions = []
            for process in processes:
                self.exchange(process, 1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}})
                created = self.exchange(process, 2, "tools/call", {"name": "search_browser_create_session", "arguments": {"mode": "ephemeral"}})
                self.assertFalse(created.get("isError"), created)
                sessions.append(created["structuredContent"]["session_id"])
                tab = self.exchange(process, 3, "tools/call", {"name": "search_browser_create_tab", "arguments": {"url": "about:blank"}})
                self.assertFalse(tab.get("isError"), tab)
            self.assertNotEqual(sessions[0], sessions[1])
            status = self.exchange(processes[0], 4, "tools/call", {"name": "search_browser_status", "arguments": {}})
            self.assertFalse(status.get("isError"), status)
            self.assertGreaterEqual(status["structuredContent"]["sessions"], 2)
            for process in processes:
                closed = self.exchange(process, 5, "tools/call", {"name": "search_browser_close_session", "arguments": {}})
                self.assertFalse(closed.get("isError"), closed)
        finally:
            for process in processes:
                process.terminate()
                process.wait(timeout=5)
                process.stdin.close()
                process.stdout.close()

    @unittest.skipUnless(os.environ.get("SEARCH_AGENT_DISCOVERY"), "Runtime discovery not supplied")
    def test_persistent_mcp_client_reattaches(self):
        client = "mcp-resume-test-" + uuid.uuid4().hex
        env = dict(os.environ, SEARCH_AGENT_CLIENT_ID=client)
        def start():
            return subprocess.Popen([sys.executable, str(SCRIPT)], stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE, text=True, env=env)
        def stop(process):
            process.terminate()
            process.wait(timeout=5)
            process.stdin.close()
            process.stdout.close()
        first = start()
        second = None
        try:
            created = self.exchange(first, 1, "tools/call", {"name": "search_browser_create_session",
                                                             "arguments": {"mode": "persistent", "profile_id": client}})
            self.assertFalse(created.get("isError"), created)
            session_id = created["structuredContent"]["session_id"]
            stop(first)
            first = None
            second = start()
            resumed = self.exchange(second, 1, "tools/call", {"name": "search_browser_create_session",
                                                              "arguments": {"mode": "persistent", "profile_id": client}})
            self.assertFalse(resumed.get("isError"), resumed)
            self.assertEqual(resumed["structuredContent"]["session_id"], session_id)
            self.assertTrue(resumed["structuredContent"]["reused"])
            closed = self.exchange(second, 2, "tools/call", {"name": "search_browser_close_session", "arguments": {}})
            self.assertFalse(closed.get("isError"), closed)
        finally:
            if first is not None:
                stop(first)
            if second is not None:
                stop(second)


if __name__ == "__main__":
    unittest.main()
