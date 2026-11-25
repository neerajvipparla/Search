#!/usr/bin/env python3
"""Settings › Let agents in without asking, and each agent's tabs grouped
under its name, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/agent_unasked.py`. Started
hidden in a world of its own with "Let coding agents use Search" and "Let
agents in without asking" on; the agents' side is ./search-mcp over stdio.

Checked: no question goes up and the tab opens at once, with your tabs
seen; two Claude Code connections share one "Claude" group, Codex's and
OpenCode's tabs go in groups of their own, each in its colour; your own tab
stays out of them; a group goes with its last tab; and with the setting
off, the question is back.
"""

import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("agent-unasked")
ROOT = Path(__file__).resolve().parents[1]
AGENT_SOCK = f"{sv.SUPPORT}/Agent/agent.sock"


class Client:
    """./search-mcp, as an agent runs it, calling itself `name`."""

    def __init__(self, name):
        self.p = subprocess.Popen([str(ROOT / "search-mcp"), "--world", sv.W],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  text=True, start_new_session=True)
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": name}})

    def send(self, method, params=None):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}}) + "\n")
        self.p.stdin.flush()
        return self.n

    def rpc(self, method, params=None):
        n = self.send(method, params)
        out = json.loads(self.p.stdout.readline())
        assert out["id"] == n, out
        return out["result"]

    def tool(self, which, /, **args):
        out = self.rpc("tools/call", {"name": which, "arguments": args})
        content = out["content"]
        if len(content) == 1 and content[0]["type"] == "text":
            return json.loads(content[0]["text"]), bool(out.get("isError"))
        return content, bool(out.get("isError"))

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(5)
        except Exception:
            self.p.kill()
        try:
            os.killpg(self.p.pid, 9)
        except OSError:
            pass


class ac:
    """The bits of agent_control.py this uses, without its world."""

    AGENT_SOCK = AGENT_SOCK
    Client = Client

    @staticmethod
    def agents(action="state", **f):
        return sv.cmd({"do": "agents", "action": action, **f})

    @staticmethod
    def until(check, within=10):
        end = time.time() + within
        while time.time() < end:
            if check():
                return True
            time.sleep(0.1)
        return False


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        data = f"<!doctype html><title>{self.path}</title><p>{self.path}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"
t = sv.T()


def groups():
    return {g["name"]: g for g in sv.cmd({"do": "group"}).get("groups", [])}


def tab_group(url_end):
    found = [x for x in sv.cmd({"do": "tabs"})["tabs"] if x["url"].endswith(url_end)]
    return found[0].get("group") if found else None


def main():
    clients = []
    try:
        sv.setup(**{"agents": True, "agents.unasked": True})
        sv.launch()
        t.ok("the socket is there", ac.until(lambda: Path(ac.AGENT_SOCK).exists()))
        sv.cmd({"do": "open", "url": f"{BASE}/yours"})
        time.sleep(1)

        # ---- no question: the tab opens at once
        claude = ac.Client("claude-code"); clients.append(claude)
        start = time.time()
        opened, err = claude.tool("open_tab", url=f"{BASE}/claude-1")
        t.ok("Claude Code: open_tab answered without a question", not err and opened.get("page"), opened)
        t.ok("and quickly", time.time() - start < 15, time.time() - start)
        st = ac.agents()
        t.ok("allowed, never asked", st.get("state") == "allowed" and st.get("auto"), st)
        t.ok("with your tabs", st.get("seesTabs") is True, st)
        listed, err = claude.tool("list_tabs")
        t.ok("list_tabs sees your tab", not err and any("/yours" in str(x) for x in (listed.get("tabs") or [])), listed)

        t.ok("Claude's tab is in the Claude group", ac.until(lambda: tab_group("/claude-1") == "Claude"),
             sv.cmd({"do": "tabs"}))
        t.ok("your tab is in no group", tab_group("/yours") == "", tab_group("/yours"))

        # ---- a second Claude Code connection: the same group
        claude2 = ac.Client("claude-code"); clients.append(claude2)
        _, err = claude2.tool("open_tab", url=f"{BASE}/claude-2")
        t.ok("second Claude Code connection let in", not err)
        t.ok("and its tab joins the same Claude group", ac.until(lambda: tab_group("/claude-2") == "Claude"))
        g = groups()
        t.ok("one Claude group holding both tabs", list(g).count("Claude") == 1 and len(g["Claude"]["tabs"]) == 2, g)
        t.ok("Claude's group is orange", g.get("Claude", {}).get("colour") == 3, g.get("Claude"))

        # ---- Codex and OpenCode: groups of their own
        codex = ac.Client("codex-mcp-client"); clients.append(codex)
        _, err = codex.tool("open_tab", url=f"{BASE}/codex-1")
        t.ok("Codex let in without a question", not err)
        opencode = ac.Client("opencode"); clients.append(opencode)
        _, err = opencode.tool("open_tab", url=f"{BASE}/opencode-1")
        t.ok("OpenCode let in without a question", not err)
        t.ok("Codex's tab in the Codex group", ac.until(lambda: tab_group("/codex-1") == "Codex"))
        t.ok("OpenCode's tab in the OpenCode group", ac.until(lambda: tab_group("/opencode-1") == "OpenCode"))
        g = groups()
        t.ok("three groups, one per agent", set(g) == {"Claude", "Codex", "OpenCode"}, list(g))
        t.ok("each its own colour", (g["Codex"]["colour"], g["OpenCode"]["colour"]) == (1, 2), g)

        # ---- a group goes with its last tab
        opened, _ = codex.tool("list_tabs")
        page = next((x["page"] for x in opened.get("tabs", []) if x.get("mine")), None)
        _, err = codex.tool("close_tab", page=page)
        t.ok("Codex closes its tab", not err and page, opened)
        t.ok("and the Codex group goes", ac.until(lambda: "Codex" not in groups()), list(groups()))

        # ---- the setting off: asked again
        for c in clients:
            c.close()
        clients.clear()
        time.sleep(1)
        sv.quit()
        sv.setup(**{"agents": True, "agents.unasked": False})
        sv.launch()
        ac.until(lambda: Path(ac.AGENT_SOCK).exists())
        asked = ac.Client("claude-code"); clients.append(asked)
        asked.send("tools/call", {"name": "open_tab", "arguments": {"url": f"{BASE}/asked"}})
        t.ok("setting off: the question is back", ac.until(lambda: ac.agents().get("state") == "asking"), ac.agents())
    finally:
        for c in clients:
            c.close()
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
