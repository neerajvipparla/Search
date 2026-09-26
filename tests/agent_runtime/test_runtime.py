"""Local fixture and end-to-end tests for the opt-in Search runtime.

Run with SEARCH_AGENT_DISCOVERY pointing at a running test build's runtime.json.
"""

import http.server
import json
import os
from pathlib import Path
import threading
import time
import unittest
import urllib.request
import uuid


class Fixture(http.server.BaseHTTPRequestHandler):
    slow_started = threading.Event()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        cookie = self.headers.get("Cookie", "")
        body = "<h1>Fixture</h1><input aria-label='Search'><button id='run'>Search</button>"
        if path == "/set-alpha":
            self.send_response(200)
            self.send_header("Set-Cookie", "agent=alpha; Path=/")
        elif path == "/who":
            self.send_response(200)
            body += "<p>cookie: %s</p>" % cookie
        elif path == "/dynamic":
            self.send_response(200)
            body += "<script>setTimeout(()=>document.querySelector('#run').replaceWith(document.createElement('button')),300)</script>"
        elif path == "/actions":
            self.send_response(200)
            body += ("<p id='state'>idle</p><script>"
                     "document.querySelector('#run').addEventListener('click',()=>document.querySelector('#state').textContent='clicked');"
                     "document.querySelector('input').addEventListener('keydown',e=>{if(e.key==='Enter')document.querySelector('#state').textContent='entered'});"
                     "</script>")
        elif path == "/long":
            self.send_response(200)
            body += "<p>%s</p>" % ("long-page-text " * 100)
        elif path == "/popup":
            self.send_response(200)
            body += "<a target='_blank' href='/who'>Open detail</a>"
        elif path == "/repurpose":
            self.send_response(200)
            body += "<script>setTimeout(()=>document.querySelector('#run').textContent='Different action',1500)</script>"
        elif path == "/slow":
            self.slow_started.set()
            time.sleep(1)
            self.send_response(200)
        elif path == "/late":
            self.send_response(200)
            body += ("<script>setTimeout(()=>{const b=document.createElement('button');b.textContent='Later';"
                     "document.body.appendChild(b);setTimeout(()=>b.remove(),700)},400)</script>")
        else:
            self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *_):
        pass


class RuntimeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = "http://127.0.0.1:%d" % cls.server.server_port
        cls.discovery = json.loads(Path(os.environ["SEARCH_AGENT_DISCOVERY"]).read_text())

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def request(self, method, path, payload=None, token=None):
        body = {"request_id": str(uuid.uuid4())}
        body.update(payload or {})
        headers = {"Authorization": "Bearer " + self.discovery["authToken"], "Content-Type": "application/json"}
        if token:
            headers["X-Session-Token"] = token
        request = urllib.request.Request("http://127.0.0.1:%s%s" % (self.discovery["port"], path),
                                         data=json.dumps(body).encode(), headers=headers, method=method)
        with urllib.request.urlopen(request, timeout=25) as response:
            return json.load(response)

    def test_runtime_status(self):
        status = self.request("GET", "/v1/runtime")
        self.assertTrue(status["ok"])
        self.assertIn("sessions", status["data"])

    def test_two_isolated_sessions_and_stale_reference(self):
        a = self.request("POST", "/v1/sessions", {"client_id": "fixture-a", "profile": {"mode": "ephemeral"}})["data"]
        b = self.request("POST", "/v1/sessions", {"client_id": "fixture-b", "profile": {"mode": "ephemeral"}})["data"]
        def call(session, method, path, extra=None):
            payload = {"client_id": "fixture-a" if session is a else "fixture-b", "session_id": session["session_id"]}
            payload.update(extra or {})
            return self.request(method, path, payload, session["session_token"])
        try:
            ta = call(a, "POST", "/v1/sessions/%s/tabs" % a["session_id"], {"url": self.base + "/set-alpha"})["data"]["tab_id"]
            tb = call(b, "POST", "/v1/sessions/%s/tabs" % b["session_id"], {"url": self.base + "/who"})["data"]["tab_id"]
            who_a = call(a, "POST", "/v1/tabs/%s/navigate" % ta, {"url": self.base + "/who"})
            who_b = call(b, "POST", "/v1/tabs/%s/observe" % tb)
            self.assertIn("agent=alpha", who_a["data"]["text"])
            self.assertNotIn("agent=alpha", who_b["data"]["text"])
            denied = call(b, "POST", "/v1/tabs/%s/observe" % ta)
            self.assertFalse(denied["ok"])
            self.assertEqual(denied["error"]["code"], "TAB_NOT_FOUND")
            observed = call(a, "POST", "/v1/tabs/%s/observe" % ta)["data"]
            button = next(item for item in observed["elements"] if item["role"] == "button")
            call(a, "POST", "/v1/tabs/%s/navigate" % ta, {"url": self.base + "/dynamic"})
            stale = call(a, "POST", "/v1/tabs/%s/click" % ta,
                         {"snapshot_id": observed["snapshot_id"], "element_ref": button["ref"]})
            self.assertFalse(stale["ok"])
            self.assertEqual(stale["error"]["code"], "ELEMENT_STALE")
        finally:
            call(a, "DELETE", "/v1/sessions/%s" % a["session_id"])
            call(b, "DELETE", "/v1/sessions/%s" % b["session_id"])

    def test_two_blank_tabs(self):
        sessions = []
        try:
            for client in ["blank-a", "blank-b"]:
                session = self.request("POST", "/v1/sessions", {"client_id": client, "profile": {"mode": "ephemeral"}})["data"]
                sessions.append((client, session))
                result = self.request("POST", "/v1/sessions/%s/tabs" % session["session_id"],
                                      {"client_id": client, "session_id": session["session_id"], "url": "about:blank"},
                                      session["session_token"])
                self.assertTrue(result["ok"], result.get("error"))
                self.assertTrue(self.request("GET", "/v1/runtime")["ok"], "Runtime died after " + client)
            status = self.request("GET", "/v1/runtime")
            self.assertTrue(status["ok"])
            self.assertGreaterEqual(status["data"]["sessions"], 2)
        finally:
            for client, session in sessions:
                try:
                    self.request("DELETE", "/v1/sessions/%s" % session["session_id"],
                                 {"client_id": client, "session_id": session["session_id"]},
                                 session["session_token"])
                except OSError:
                    pass

    def test_fill_type_keypress_and_click(self):
        client = "fixture-actions"
        session = self.request("POST", "/v1/sessions", {"client_id": client, "profile": {"mode": "ephemeral"}})["data"]
        def call(method, path, extra=None):
            payload = {"client_id": client, "session_id": session["session_id"]}
            payload.update(extra or {})
            return self.request(method, path, payload, session["session_token"])
        try:
            tab = call("POST", "/v1/sessions/%s/tabs" % session["session_id"], {"url": self.base + "/actions"})["data"]["tab_id"]
            state = call("POST", "/v1/tabs/%s/observe" % tab)["data"]
            field = next(item for item in state["elements"] if item["role"] == "textbox")
            filled = call("POST", "/v1/tabs/%s/fill" % tab,
                          {"snapshot_id": state["snapshot_id"], "element_ref": field["ref"], "text": "alp"})
            self.assertTrue(filled["ok"], filled.get("error"))
            self.assertTrue(filled["data"]["verified"])
            state = filled["data"]["after"]
            field = next(item for item in state["elements"] if item["role"] == "textbox")
            typed = call("POST", "/v1/tabs/%s/type" % tab,
                         {"snapshot_id": state["snapshot_id"], "element_ref": field["ref"], "text": "ha"})
            self.assertTrue(typed["ok"], typed.get("error"))
            self.assertEqual(next(item for item in typed["data"]["after"]["elements"] if item["role"] == "textbox")["value"], "alpha")
            state = typed["data"]["after"]
            field = next(item for item in state["elements"] if item["role"] == "textbox")
            pressed = call("POST", "/v1/tabs/%s/keypress" % tab,
                           {"snapshot_id": state["snapshot_id"], "element_ref": field["ref"], "key": "Enter"})
            self.assertTrue(pressed["ok"], pressed.get("error"))
            self.assertIn("entered", pressed["data"]["after"]["text"])
            state = pressed["data"]["after"]
            button = next(item for item in state["elements"] if item["role"] == "button")
            clicked = call("POST", "/v1/tabs/%s/click" % tab,
                           {"snapshot_id": state["snapshot_id"], "element_ref": button["ref"]})
            self.assertTrue(clicked["ok"], clicked.get("error"))
            self.assertTrue(clicked["data"]["verified"])
            self.assertIn("clicked", clicked["data"]["after"]["text"])
        finally:
            call("DELETE", "/v1/sessions/%s" % session["session_id"])

    def test_observation_text_is_bounded_but_not_truncated_to_element_limit(self):
        client = "fixture-long"
        session = self.request("POST", "/v1/sessions", {"client_id": client, "profile": {"mode": "ephemeral"}})["data"]
        def call(method, path, extra=None):
            payload = {"client_id": client, "session_id": session["session_id"]}
            payload.update(extra or {})
            return self.request(method, path, payload, session["session_token"])
        try:
            tab = call("POST", "/v1/sessions/%s/tabs" % session["session_id"], {"url": self.base + "/long"})["data"]["tab_id"]
            state = call("POST", "/v1/tabs/%s/observe" % tab)["data"]
            self.assertGreater(len(state["text"]), 240)
            self.assertLessEqual(len(state["text"]), 6000)
        finally:
            call("DELETE", "/v1/sessions/%s" % session["session_id"])

    def test_persistent_profile_requires_capability(self):
        profile_id = "profile-test-" + uuid.uuid4().hex
        a = self.request("POST", "/v1/sessions", {"client_id": "profile-owner", "profile": {"mode": "persistent", "profile_id": profile_id}})["data"]
        try:
            denied = self.request("POST", "/v1/sessions", {"client_id": "other-client", "profile": {"mode": "persistent", "profile_id": profile_id}})
            self.assertFalse(denied["ok"])
            self.assertEqual(denied["error"]["code"], "UNAUTHORIZED")
            shared = self.request("POST", "/v1/sessions", {"client_id": "other-client", "profile": {
                "mode": "persistent", "profile_id": profile_id, "profile_token": a["profile_token"]}})
            self.assertTrue(shared["ok"], shared.get("error"))
            b = shared["data"]
            self.request("DELETE", "/v1/sessions/%s" % b["session_id"],
                         {"client_id": "other-client", "session_id": b["session_id"]}, b["session_token"])
        finally:
            self.request("DELETE", "/v1/sessions/%s" % a["session_id"],
                         {"client_id": "profile-owner", "session_id": a["session_id"]}, a["session_token"])

    def test_popup_stays_in_agent_session_and_repurposed_ref_is_stale(self):
        client = "fixture-popup"
        session = self.request("POST", "/v1/sessions", {"client_id": client, "profile": {"mode": "ephemeral"}})["data"]
        def call(method, path, extra=None):
            payload = {"client_id": client, "session_id": session["session_id"]}
            payload.update(extra or {})
            return self.request(method, path, payload, session["session_token"])
        try:
            tab = call("POST", "/v1/sessions/%s/tabs" % session["session_id"], {"url": self.base + "/popup"})["data"]["tab_id"]
            state = call("POST", "/v1/tabs/%s/observe" % tab)["data"]
            link = next(item for item in state["elements"] if item["role"] == "link")
            clicked = call("POST", "/v1/tabs/%s/click" % tab,
                           {"snapshot_id": state["snapshot_id"], "element_ref": link["ref"]})
            self.assertTrue(clicked["ok"], clicked.get("error"))
            tabs = call("GET", "/v1/sessions/%s/tabs" % session["session_id"])["data"]["tabs"]
            self.assertEqual(len(tabs), 2, tabs)
            other = next(item["id"] for item in tabs if item["id"] != tab)
            self.assertTrue(call("POST", "/v1/tabs/%s/observe" % other)["ok"])
            call("POST", "/v1/tabs/%s/navigate" % tab, {"url": self.base + "/repurpose"})
            state = call("POST", "/v1/tabs/%s/observe" % tab)["data"]
            button = next(item for item in state["elements"] if item["role"] == "button")
            self.assertEqual(button["name"], "Search")
            time.sleep(1.7)
            stale = call("POST", "/v1/tabs/%s/click" % tab,
                         {"snapshot_id": state["snapshot_id"], "element_ref": button["ref"]})
            self.assertFalse(stale["ok"])
            self.assertEqual(stale["error"]["code"], "ELEMENT_STALE")
        finally:
            call("DELETE", "/v1/sessions/%s" % session["session_id"])

    def test_close_rejects_in_flight_navigation(self):
        client = "fixture-busy"
        session = self.request("POST", "/v1/sessions", {"client_id": client, "profile": {"mode": "ephemeral"}})["data"]
        def call(method, path, extra=None):
            payload = {"client_id": client, "session_id": session["session_id"]}
            payload.update(extra or {})
            return self.request(method, path, payload, session["session_token"])
        tab = call("POST", "/v1/sessions/%s/tabs" % session["session_id"], {"url": self.base + "/actions"})["data"]["tab_id"]
        self.server.RequestHandlerClass.slow_started.clear()
        result = []
        worker = threading.Thread(target=lambda: result.append(call("POST", "/v1/tabs/%s/navigate" % tab,
                                                                  {"url": self.base + "/slow"})))
        worker.start()
        try:
            self.assertTrue(self.server.RequestHandlerClass.slow_started.wait(3), "Slow navigation did not start")
            close_tab = call("DELETE", "/v1/sessions/%s/tabs/%s" % (session["session_id"], tab))
            close_session = call("DELETE", "/v1/sessions/%s" % session["session_id"])
            self.assertEqual(close_tab["error"]["code"], "TAB_BUSY")
            self.assertEqual(close_session["error"]["code"], "TAB_BUSY")
        finally:
            worker.join(timeout=5)
            call("DELETE", "/v1/sessions/%s" % session["session_id"])
        self.assertEqual(len(result), 1)
        self.assertTrue(result[0]["ok"], result[0].get("error"))

    def test_back_forward_reload_wait_for_committed_navigation(self):
        client = "fixture-history"
        session = self.request("POST", "/v1/sessions", {"client_id": client, "profile": {"mode": "ephemeral"}})["data"]
        def call(method, path, extra=None):
            payload = {"client_id": client, "session_id": session["session_id"]}
            payload.update(extra or {})
            return self.request(method, path, payload, session["session_token"])
        try:
            tab = call("POST", "/v1/sessions/%s/tabs" % session["session_id"], {"url": self.base + "/actions"})["data"]["tab_id"]
            self.assertTrue(call("POST", "/v1/tabs/%s/navigate" % tab, {"url": self.base + "/who"})["ok"])
            back = call("POST", "/v1/tabs/%s/back" % tab)
            self.assertTrue(back["ok"], back.get("error"))
            self.assertTrue(back["data"]["url"].endswith("/actions"), back["data"]["url"])
            forward = call("POST", "/v1/tabs/%s/forward" % tab)
            self.assertTrue(forward["ok"], forward.get("error"))
            self.assertTrue(forward["data"]["url"].endswith("/who"), forward["data"]["url"])
            reloaded = call("POST", "/v1/tabs/%s/reload" % tab)
            self.assertTrue(reloaded["ok"], reloaded.get("error"))
            self.assertTrue(reloaded["data"]["url"].endswith("/who"), reloaded["data"]["url"])
        finally:
            call("DELETE", "/v1/sessions/%s" % session["session_id"])

    def test_retried_mutation_does_not_type_twice(self):
        client = "fixture-idempotency"
        session = self.request("POST", "/v1/sessions", {"client_id": client, "profile": {"mode": "ephemeral"}})["data"]
        def call(method, path, extra=None):
            payload = {"client_id": client, "session_id": session["session_id"]}
            payload.update(extra or {})
            return self.request(method, path, payload, session["session_token"])
        try:
            tab = call("POST", "/v1/sessions/%s/tabs" % session["session_id"], {"url": self.base + "/actions"})["data"]["tab_id"]
            state = call("POST", "/v1/tabs/%s/observe" % tab)["data"]
            field = next(item for item in state["elements"] if item["role"] == "textbox")
            request_id = str(uuid.uuid4())
            payload = {"request_id": request_id, "snapshot_id": state["snapshot_id"], "element_ref": field["ref"], "text": "x"}
            first = call("POST", "/v1/tabs/%s/type" % tab, payload)
            repeated = call("POST", "/v1/tabs/%s/type" % tab, payload)
            self.assertTrue(first["ok"], first.get("error"))
            self.assertEqual(repeated, first)
            changed = call("POST", "/v1/tabs/%s/type" % tab, dict(payload, text="y"))
            self.assertEqual(changed["error"]["code"], "INVALID_ACTION")
            state = call("POST", "/v1/tabs/%s/observe" % tab)["data"]
            self.assertEqual(next(item for item in state["elements"] if item["role"] == "textbox")["value"], "x")
        finally:
            call("DELETE", "/v1/sessions/%s" % session["session_id"])

    def test_wait_for_element_appearance_and_disappearance(self):
        client = "fixture-wait"
        session = self.request("POST", "/v1/sessions", {"client_id": client, "profile": {"mode": "ephemeral"}})["data"]
        def call(method, path, extra=None):
            payload = {"client_id": client, "session_id": session["session_id"]}
            payload.update(extra or {})
            return self.request(method, path, payload, session["session_token"])
        try:
            tab = call("POST", "/v1/sessions/%s/tabs" % session["session_id"], {"url": self.base + "/late"})["data"]["tab_id"]
            appeared = call("POST", "/v1/tabs/%s/wait" % tab,
                            {"seconds": 3, "element": {"role": "button", "name": "Later", "present": True}})
            self.assertTrue(appeared["ok"], appeared.get("error"))
            gone = call("POST", "/v1/tabs/%s/wait" % tab,
                        {"seconds": 3, "element": {"role": "button", "name": "Later", "present": False}})
            self.assertTrue(gone["ok"], gone.get("error"))
        finally:
            call("DELETE", "/v1/sessions/%s" % session["session_id"])

    @unittest.skipUnless(os.environ.get("SEARCH_TEST_JEV") == "1", "Live Jev test is opt-in")
    def test_live_jev_selection(self):
        client = "fixture-jev"
        session = self.request("POST", "/v1/sessions", {"client_id": client, "profile": {"mode": "ephemeral"}})["data"]
        def call(method, path, extra=None):
            payload = {"client_id": client, "session_id": session["session_id"]}
            payload.update(extra or {})
            return self.request(method, path, payload, session["session_token"])
        try:
            tab = call("POST", "/v1/sessions/%s/tabs" % session["session_id"], {"url": self.base + "/"})["data"]["tab_id"]
            result = call("POST", "/v1/tabs/%s/choose" % tab,
                          {"goal": "Click the Search button", "engine": "jev", "min_confidence": 0})
            self.assertTrue(result["ok"], result.get("error"))
            self.assertEqual(result["data"]["engine"], "jev")
            self.assertGreaterEqual(result["data"]["latency_ms"], 0)
            self.assertIn(result["data"]["element_ref"], ["e1", "e2", "e3"])
        finally:
            call("DELETE", "/v1/sessions/%s" % session["session_id"])

    @unittest.skipUnless(os.environ.get("SEARCH_TEST_JEV") == "1", "Live Jev test is opt-in")
    def test_live_jev_click_goal(self):
        client = "fixture-jev-action"
        session = self.request("POST", "/v1/sessions", {"client_id": client, "profile": {"mode": "ephemeral"}})["data"]
        def call(method, path, extra=None):
            payload = {"client_id": client, "session_id": session["session_id"]}
            payload.update(extra or {})
            return self.request(method, path, payload, session["session_token"])
        try:
            tab = call("POST", "/v1/sessions/%s/tabs" % session["session_id"], {"url": self.base + "/actions"})["data"]["tab_id"]
            result = call("POST", "/v1/tabs/%s/act_goal" % tab,
                          {"goal": "Click the Search button", "engine": "jev", "min_confidence": 0})
            self.assertTrue(result["ok"], result.get("error"))
            self.assertEqual(result["data"]["decision"]["engine"], "jev")
            self.assertTrue(result["data"]["action"]["verified"], result["data"])
            self.assertIn("clicked", result["data"]["action"]["after"]["text"])
        finally:
            call("DELETE", "/v1/sessions/%s" % session["session_id"])


if __name__ == "__main__":
    unittest.main()
