#!/usr/bin/env python3
"""Dependency-free stdio MCP bridge to one running Search Agent Runtime."""

import json
import hashlib
import os
from pathlib import Path
import sys
import urllib.error
import urllib.request
import uuid


def tool(name, description, properties=None, required=None):
    return {
        "name": "search_browser_" + name,
        "description": description,
        "inputSchema": {
            "type": "object",
            "properties": properties or {},
            "required": required or [],
            "additionalProperties": False,
        },
    }


STRING = {"type": "string"}
TOOLS = [
    tool("status", "Show Search runtime status and recent activity."),
    tool("create_session", "Create an isolated browser session for this agent. Call before creating tabs.",
         {"mode": {"type": "string", "enum": ["ephemeral", "persistent"]}, "profile_id": STRING,
          "profile_token": STRING, "label": STRING}),
    tool("close_session", "Close this agent's browser session and its tabs."),
    tool("create_tab", "Create a visible agent-owned tab in this session.", {"url": STRING}),
    tool("list_tabs", "List tabs owned by this agent's session."),
    tool("close_tab", "Close one owned tab.", {"tab_id": STRING}, ["tab_id"]),
    tool("navigate", "Navigate an owned tab to an HTTP(S) URL and return a structured snapshot.",
         {"tab_id": STRING, "url": STRING}, ["tab_id", "url"]),
    tool("observe", "Get a fresh structured page snapshot with snapshot-aware element references.",
         {"tab_id": STRING}, ["tab_id"]),
    tool("choose", "Select an element for a browser goal using deterministic rules or Jev. Set engine=jev to force a live Jev decision.",
         {"tab_id": STRING, "goal": STRING, "engine": {"type": "string", "enum": ["auto", "jev", "mock"]}, "min_confidence": {"type": "number"}},
         ["tab_id", "goal"]),
    tool("act_goal", "Choose, click, verify, and recover once from a stale reference. Use engine=jev to force Jev.",
         {"tab_id": STRING, "goal": STRING, "engine": {"type": "string", "enum": ["auto", "jev", "mock"]}, "min_confidence": {"type": "number"}},
         ["tab_id", "goal"]),
    tool("click", "Click a snapshot element and verify the page state. Re-observe if ELEMENT_STALE is returned.",
         {"tab_id": STRING, "snapshot_id": STRING, "element_ref": STRING, "expected": {"type": "object"}},
         ["tab_id", "snapshot_id", "element_ref"]),
    tool("fill", "Fill a text field identified by a snapshot reference and verify its value.",
         {"tab_id": STRING, "snapshot_id": STRING, "element_ref": STRING, "text": STRING},
         ["tab_id", "snapshot_id", "element_ref", "text"]),
    tool("type", "Append text to a field identified by a snapshot reference and verify its value.",
         {"tab_id": STRING, "snapshot_id": STRING, "element_ref": STRING, "text": STRING},
         ["tab_id", "snapshot_id", "element_ref", "text"]),
    tool("keypress", "Send a supported key event to a snapshot element. Synthetic events may not trigger every site's native behavior.",
         {"tab_id": STRING, "snapshot_id": STRING, "element_ref": STRING,
          "key": {"type": "string", "enum": ["Enter", "Escape", "Tab", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Backspace", "Delete", "Home", "End"]}},
         ["tab_id", "snapshot_id", "element_ref", "key"]),
    tool("scroll", "Scroll the page vertically by a number of pixels.",
         {"tab_id": STRING, "y": {"type": "number"}}, ["tab_id"]),
    tool("wait", "Wait for navigation, text, URL substring, or an element to appear/disappear, up to 15 seconds.",
         {"tab_id": STRING, "text": STRING, "url_contains": STRING,
          "element": {"type": "object", "properties": {"role": STRING, "name": STRING, "present": {"type": "boolean"}}},
          "seconds": {"type": "number"}}, ["tab_id"]),
    tool("back", "Go back in a tab's history.", {"tab_id": STRING}, ["tab_id"]),
    tool("forward", "Go forward in a tab's history.", {"tab_id": STRING}, ["tab_id"]),
    tool("reload", "Reload a tab.", {"tab_id": STRING}, ["tab_id"]),
    tool("activate", "Show an agent-owned tab in the Search window.", {"tab_id": STRING}, ["tab_id"]),
    tool("screenshot", "Take a screenshot of an owned tab for diagnosis.", {"tab_id": STRING}, ["tab_id"]),
]


class Bridge:
    def __init__(self):
        self.client_id = os.environ.get("SEARCH_AGENT_CLIENT_ID", "mcp-" + uuid.uuid4().hex[:12])
        self.stable_client = bool(os.environ.get("SEARCH_AGENT_CLIENT_ID"))
        self.session_id = None
        self.session_token = None
        self.profile_token = None
        self.mode = None
        self.profile_id = None
        self._discovery_path = None

    def discovery(self):
        if os.environ.get("SEARCH_AGENT_DISCOVERY"):
            files = [Path(os.environ["SEARCH_AGENT_DISCOVERY"])]
        else:
            base = Path.home() / "Library" / "Application Support"
            files = [base / "Search (test)" / "agent-runtime" / "runtime.json",
                     base / "Search" / "agent-runtime" / "runtime.json"]
        for file in files:
            try:
                data = json.loads(file.read_text())
                if isinstance(data.get("port"), int) and data.get("authToken"):
                    with urllib.request.urlopen("http://127.0.0.1:%d/v1/health" % data["port"], timeout=1) as response:
                        health = json.load(response)
                    if health.get("ok") and health.get("data", {}).get("pid") == data.get("pid"):
                        self._discovery_path = file
                        return data
            except (OSError, ValueError, urllib.error.URLError):
                continue
        raise RuntimeError("Search Agent Runtime is not running. Launch Search with SEARCH_AGENT_RUNTIME=1.")

    def cache_path(self):
        if not self.stable_client:
            return None
        if self._discovery_path is None:
            self.discovery()
        slug = hashlib.sha256(self.client_id.encode()).hexdigest()[:24]
        return self._discovery_path.parent / "clients" / (slug + ".json")

    def save_session(self, mode, profile_id):
        path = self.cache_path()
        if path is None or mode != "persistent":
            return
        path.parent.mkdir(mode=0o700, exist_ok=True)
        payload = json.dumps({"client_id": self.client_id, "session_id": self.session_id,
                              "session_token": self.session_token, "mode": mode, "profile_id": profile_id,
                              "profile_token": self.profile_token})
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w") as file:
            file.write(payload)

    def resume_session(self, mode, profile_id):
        path = self.cache_path()
        if path is None or mode != "persistent":
            return None
        try:
            saved = json.loads(path.read_text())
            if saved.get("client_id") != self.client_id or saved.get("mode") != mode or saved.get("profile_id") != profile_id:
                return None
            self.profile_token = saved.get("profile_token")
            self.session_id, self.session_token = saved["session_id"], saved["session_token"]
            if not self.session_id or not self.session_token:
                return None
            data = self.request("GET", "/v1/sessions/" + self.session_id)
            return {"session_id": self.session_id, "client_id": self.client_id, "mode": data["mode"], "reused": True}
        except (OSError, ValueError, KeyError, RuntimeError):
            self.session_id = self.session_token = None
            return None

    def request(self, method, path, payload=None, session=True):
        runtime = self.discovery()
        body = {"request_id": str(uuid.uuid4()), "client_id": self.client_id}
        body.update(payload or {})
        headers = {"Authorization": "Bearer " + runtime["authToken"], "Content-Type": "application/json"}
        if session:
            if not self.session_id:
                raise RuntimeError("Create a browser session first")
            body["session_id"] = self.session_id
            headers["X-Session-Token"] = self.session_token
        request = urllib.request.Request(
            "http://127.0.0.1:%d%s" % (runtime["port"], path),
            data=json.dumps(body).encode(), headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=25) as response:
                result = json.load(response)
        except (OSError, urllib.error.URLError) as exc:
            raise RuntimeError("Cannot reach Search runtime: %s" % exc) from exc
        if not result.get("ok"):
            error = result.get("error") or {}
            raise RuntimeError("%s: %s" % (error.get("code", "ERROR"), error.get("message", "Unknown error")))
        return result.get("data", {})

    def call(self, name, args):
        if name == "status":
            return self.request("GET", "/v1/runtime", session=False)
        if name == "create_session":
            if self.session_id:
                return {"session_id": self.session_id, "client_id": self.client_id, "reused": True}
            mode, profile_id = args.get("mode", "ephemeral"), args.get("profile_id", "")
            self.mode, self.profile_id = mode, profile_id
            self.profile_token = args.get("profile_token")
            resumed = self.resume_session(mode, profile_id)
            if resumed:
                return resumed
            data = self.request("POST", "/v1/sessions", {
                "profile": {"mode": mode, "profile_id": profile_id, "profile_token": self.profile_token},
                "label": args.get("label", self.client_id)}, session=False)
            self.session_id, self.session_token = data["session_id"], data["session_token"]
            self.profile_token = data.get("profile_token")
            self.save_session(mode, profile_id)
            return {"session_id": self.session_id, "client_id": self.client_id, "mode": data["mode"]}
        if name == "close_session":
            data = self.request("DELETE", "/v1/sessions/" + self.session_id)
            self.session_id = self.session_token = None
            path = self.cache_path()
            if path is not None and self.mode == "persistent":
                self.save_session(self.mode, self.profile_id)
            elif path is not None:
                path.unlink(missing_ok=True)
            return data
        if name == "create_tab":
            return self.request("POST", "/v1/sessions/" + self.session_id + "/tabs", args)
        if name == "list_tabs":
            return self.request("GET", "/v1/sessions/" + self.session_id + "/tabs")
        if name == "close_tab":
            return self.request("DELETE", "/v1/sessions/" + self.session_id + "/tabs/" + args["tab_id"])
        if name in {"navigate", "observe", "choose", "act_goal", "click", "fill", "type", "keypress", "scroll", "wait", "back", "forward", "reload", "activate", "screenshot"}:
            return self.request("POST", "/v1/tabs/" + args["tab_id"] + "/" + name, args)
        raise RuntimeError("Unknown tool: " + name)


def respond(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main():
    bridge = Bridge()
    names = {tool["name"] for tool in TOOLS}
    for line in sys.stdin:
        try:
            message = json.loads(line)
            method, ident = message.get("method"), message.get("id")
            if ident is None:
                continue
            if method == "initialize":
                result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                          "serverInfo": {"name": "search-browser", "version": "0.1.0"}}
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": TOOLS}
            elif method == "tools/call":
                params = message.get("params") or {}
                name = params.get("name", "")
                if name not in names:
                    raise ValueError("Unknown tool: " + name)
                try:
                    data = bridge.call(name.removeprefix("search_browser_"), params.get("arguments") or {})
                    if name.endswith("screenshot"):
                        result = {"content": [{"type": "image", "mimeType": data["mime_type"], "data": data["base64"]}]}
                    else:
                        result = {"content": [{"type": "text", "text": json.dumps(data, separators=(",", ":"))}],
                                  "structuredContent": data}
                except Exception as exc:
                    result = {"content": [{"type": "text", "text": str(exc)}], "isError": True}
            else:
                respond({"jsonrpc": "2.0", "id": ident, "error": {"code": -32601, "message": "Method not found"}})
                continue
            respond({"jsonrpc": "2.0", "id": ident, "result": result})
        except Exception as exc:
            if "ident" in locals() and ident is not None:
                respond({"jsonrpc": "2.0", "id": ident, "error": {"code": -32603, "message": str(exc)}})


if __name__ == "__main__":
    main()
