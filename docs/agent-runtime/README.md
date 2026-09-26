# Search Agent Runtime POC

This is an opt-in local browser service inside one Search process. Claude Code and Codex each run a small stdio MCP adapter; both adapters talk to the same loopback Search runtime. Sessions own their tabs and WebKit data stores. Jev is an optional structured element-choice engine, not an action executor.

## Run it on this Mac

From the repository root:

```sh
swift build -c debug
swift scripts/store-jev-key.swift
SEARCH_PROBE=agentpoc swift scripts/run-agent-runtime.swift
```

`store-jev-key.swift` prompts without echoing the key and stores it in macOS Keychain. The debug launcher reads that item and passes the key only to the child Search process. Do not put the key in source, a command argument, or MCP configuration. The launcher needs a built `.build/debug/Search`. To test the runtime without Jev, launch `SEARCH_PROBE=agentpoc SEARCH_AGENT_RUNTIME=1 .build/debug/Search` instead.

The `SEARCH_PROBE=agentpoc` world isolates this POC from your regular Search profile. Its discovery file is `~/Library/Application Support/Search (agentpoc)/agent-runtime/runtime.json` (mode 0600). It contains a local bearer token; do not paste it into logs or issues. The app shows a green dot in the tab strip while the runtime is active. Agent tabs have a person badge and a blocking overlay; **Take control** detaches one from its agent session when no action is running.

The current workstation has `search-browser` registered for both Codex and Claude Code against the `agentpoc` discovery file, with distinct stable client IDs. New client processes may need to reload MCP configuration. If setting up elsewhere, from the repository root:

```sh
codex mcp add search-browser \
  --env "SEARCH_AGENT_DISCOVERY=$HOME/Library/Application Support/Search (agentpoc)/agent-runtime/runtime.json" \
  --env SEARCH_AGENT_CLIENT_ID=codex-search \
  -- python3 "$PWD/mcp/search_mcp.py"

claude mcp add --scope local --transport stdio search-browser \
  --env "SEARCH_AGENT_DISCOVERY=$HOME/Library/Application Support/Search (agentpoc)/agent-runtime/runtime.json" \
  --env SEARCH_AGENT_CLIENT_ID=claude-search \
  -- python3 "$PWD/mcp/search_mcp.py"
```

Use a **different stable client ID for each independent agent** if you want persistent-session reattachment. If several instances of the same client may run concurrently, give each its own ID. Without `SEARCH_AGENT_CLIENT_ID`, every MCP process gets a fresh ID, which is safer for concurrent ephemeral use but cannot reattach after restart. A stable client's persistent session and profile capabilities are cached in a 0600 file beside the discovery record. Reusing another persistent profile requires its separate `profile_token`; merely knowing its `profile_id` is insufficient.

## Try the POC

In either coding client, ask it to use `search_browser_create_session` (`mode: persistent` and a unique `profile_id`, or `mode: ephemeral`), then `search_browser_create_tab`, `search_browser_navigate`, and `search_browser_observe`. The observation returns a `snapshot_id` and `eN` element refs. Pass both to `search_browser_click`, `search_browser_fill`, `search_browser_type`, or `search_browser_keypress`. Re-observe after an `ELEMENT_STALE` error. `search_browser_choose` makes a finite element choice; set `engine: jev` to force the live TypeSafe call. `search_browser_act_goal` performs a choice followed by a click and one stale-ref retry. The caller should inspect `verified` and `verification` before assuming the goal succeeded.

Run the local fixture suite while the test-world app is open:

```sh
SEARCH_TEST_JEV=1 \
SEARCH_AGENT_DISCOVERY="$HOME/Library/Application Support/Search (agentpoc)/agent-runtime/runtime.json" \
python3 -m unittest discover -s tests/agent_runtime -p 'test_*.py' -v
```

Leave out `SEARCH_TEST_JEV=1` for an offline run. The live Jev test uses a real API call. The fixture suite covers two independent MCP clients, cookie isolation, cross-session denial, stale refs, action verification, and persistent MCP reattachment. It is **not** the omitted Playwright benchmark.

## Architecture and boundaries

`AgentHTTP.swift` binds only to `127.0.0.1` on an OS-selected port. The discovery token authenticates the local API; each session also has an opaque ID and a separate capability token. Persistent profile reuse requires its own capability. `AgentRuntime.swift` checks the client ID, session token, and tab ownership, and serializes operations per tab with a FIFO lease queue. Popups remain in the opener's agent session. It restores persistent session/tab metadata on app restart; ephemeral sessions vanish. Persistent WebKit profile IDs reuse their data stores. The MCP adapter never starts a second Search process.

`AgentPage.swift` extracts at most 100 visible interactive/heading elements and short body text, then maps refs to live DOM nodes for one snapshot. Password input values are not returned. `AgentDecision.swift` has mock, deterministic, and Jev engines. Jev receives a bounded candidate list, not executable code; auto-click requires at least 0.7 confidence regardless of caller override. The browser rechecks the element's observed role/name, re-observes after actions, and reports success or uncertainty. Local request and decision traces are written to rolling `events.jsonl` files in the test-world `agent-runtime` folder; they exclude cookies, tokens, raw form input, and full snapshots.

Important limits of this POC:

- Keypress uses DOM keyboard events. Some sites require trusted hardware events, so `keypress` may return an uncertain verification; it does not silently submit a form.
- Click verification recognizes URL, title, or text changes, not every possible visual or network-side effect. Inspect `verified` before proceeding.
- A lease serializes in-process tab operations but does not provide a distributed lock or cancellation of an already-running WebKit/HTTP request.
- Persistent metadata recovery restores tab URLs and ownership, not unsaved form state or an in-flight action. A resumed caller must observe again.
- The high-risk classifier and Playwright benchmark suite were intentionally excluded for this POC. **Do not use it for purchases, messages, deletions, or other irreversible actions.**
- The loopback API is a local development interface, not a hardened remote service. A same-user process that can read the discovery file can use the runtime. Do not enable it on an untrusted machine account.

Before publishing a fork or shipping hosted Jev integration, review [TypeSafe's current Master Customer Agreement](https://typesafe.ai/legal/mca) and get clarification where needed. This POC neither trains on Jev outputs nor exposes Jev as a standalone service.

See [codebase map](codebase-map.md) for the ownership points and [phase notes](../phases/search-agent-runtime.md) for implementation status.
