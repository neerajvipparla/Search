# Search as a browser for coding agents — technical specification

Status: proposed. Scope: bare MCP browser control, concurrent agents, and network inspection. No autonomous action model or task runner is part of this version.

## Outcome

Claude Code, Codex, and OpenCode can use the Search app already running on this Mac. After one-time MCP registration and one-time enablement in Search, opening Search makes browser control available automatically. Agents can browse at the same time in one Search process, each in its own tabs, and inspect network traffic from those tabs. A stopped or crashed agent cannot continue acting. The user's tabs and another agent's tabs are not controllable by it.

## Existing implementation to reuse

- `search-mcp` is a Python standard-library stdio MCP server. The client launches it on first use; it forwards JSON lines to `AgentControl` over a user-only Unix socket. It already exposes `list_tabs`, `open_tab`, `navigate`, `back`, `forward`, `read_page`, `click`, `type`, `press`, `scroll`, `wait_for`, `screenshot`, and `disconnect`.
- `AgentControl.swift` owns consent, per-connection page and element handles, tab ownership, pace limits, request timeouts, and secret-field protection. `Browser.swift` already calls `AgentControl.start()` at launch when the saved `prefs.agents` setting is enabled. Keep that launch behavior.
- `PageHands.swift` returns visible roles, names, values, and boxes, and rejects stale, hidden, disabled, or covered targets. Preserve those checks and the refusal of arbitrary page JavaScript.
- DevTools Full's `DeveloperToolsSession` collects network requests; `requestDetails(_:)` reads request and response headers, sent data, and response body on demand. It uses WebKit's private inspector through `DeveloperInspectorLink`. `DeveloperTools.shared` currently owns one visible inspector session.
- `bench-mcp` launches separate temporary test worlds. It remains a separate test-oriented option; this spec concerns `search-mcp` and the regular browser profile.

## Startup and installation

1. A user enables **Settings › About › Developer › Let coding agents use Search** once. The saved setting causes Search to create its existing `Agent/agent.sock` automatically on every later launch. If Search quits or the setting is turned off, all connections end and the socket is removed. Never listen on a TCP port.
2. Each MCP client registers the installed `search-mcp` helper once. Claude Code, Codex, and OpenCode then start the stdio helper themselves when they need a tool. A stdio helper cannot be usefully prestarted by Search because its input and output pipes belong to the client. The user opens Search normally; no separate launch command is needed for the helper or socket. If Search is quit, the helper returns `not_listening` with an instruction to open Search. Automatic app launch from an agent is outside this version.
3. `build.sh` places an executable helper at a stable path inside `Search.app` and preserves it through signing, ZIP, and DMG packaging. README gives commands for all three clients using an absolute app path, plus the repo-root path for development. This first version targets Macs used to build Search: it retains the Python 3 standard-library helper, checks for Python 3 at helper startup, and reports a clear installation prerequisite if absent. A self-contained helper for clean Macs without Python is outside this version.
4. On the first tool call, `search-mcp` connects and Search displays the existing per-agent Allow/Don't Allow question. The socket's owner, mode, and peer UID checks remain in place. There is no automatic grant merely because a client was registered. Remembered grants keep their existing code-signature and expiry checks.

## Concurrent sessions

- Replace `AgentControl.session` with a collection keyed by server-generated session ID, limited to **8 live connections** initially. The ninth receives a stable `too_many_agents` response. Raise the socket listen backlog accordingly. Each connection retains its own input/output buffers, pending work, pace tokens, timeout, consent, browser window, page handles, element snapshot numbers, and owned tab IDs. Do not use global mutable current-page or current-agent state for a request.
- Each MCP connection receives one session. Requests on that connection stay ordered. Work for different sessions may proceed independently on the main actor; a page load, missing reply, or slow client in one session cannot hold another session's queue. Every asynchronous completion checks that its session is still live and still owns the target tab before sending data or acting.
- Queue consent questions in arrival order, showing at most one question per window at a time. Bind buttons, checkboxes, event-time validation, and the answer callback to the ID of the question shown. A delayed click cannot answer a later question. An unanswered question times out or disconnects without blocking another session's question. A refusal retains the current short reconnect cooldown without ending already allowed sessions.
- Show each allowed agent's name and Stop control in its window. Stop on a card/pill ends that session only. The File menu/shortcut becomes **Stop All Agents** and ends all active sessions. Turning off the setting or closing a window ends its applicable sessions. The tab's activity mark reflects only its owner. On disconnect or idle release, remove the mark and control rights; leave the tabs in place under their current session/history rules.
- Keep the existing five-minute idle release and bounded request/output buffers for each session. Apply an app-wide bound to total unsent bytes as well, so eight slow readers cannot multiply memory without limit.

## Tab isolation

- Maintain one active owner mapping from `Tab.ID` to session ID. An agent owns tabs it opens and tabs opened by those tabs. Ownership is assigned when a popup tab is created, before it can be listed or driven. Closing or disconnecting removes the active owner mapping. A leftover tab is never adopted by the next agent.
- An agent can drive only its own tabs. With the existing optional **Let it see my open tabs** grant, it can list and read the person's ordinary tabs, but cannot drive them. Tabs owned by other active agents are excluded from listing and reading even with that grant. Private tabs and bench tabs remain invisible.
- Page handles and element handles are scoped to the connection. A handle string from another connection, a previous page snapshot, a closed tab, or a prior connection fails with `stale_page` or `stale_element`; it never resolves by title, URL, or index as a fallback.
- Preserve current http/https navigation restrictions, secret-field redaction, screenshot blackout, key restrictions, and no cookies/storage/keychain access through page tools.

## Network inspection

Network tools are for the agent's own tabs only. They do not open the visible DevTools panel and cannot inspect the person's tabs, another agent's tabs, private tabs, or extension pages.

| MCP tool | Input | Result |
| --- | --- | --- |
| `network_start` | `page` | Starts capture of requests initiated after attachment, including future navigation; returns capture state. The first network call in a session asks for separate, session-only consent. |
| `network_requests` | `page`, optional `limit` (1–100) | Recent requests in chronological order: opaque request handle, scrubbed URL, method, type, status, duration if known, failed/cached flags, plus count of evicted requests. |
| `network_request` | `page`, request handle | One request's metadata, request/response headers, request body and text response body when WebKit supplies them; explicit unavailable/truncated flags. |
| `network_stop` | `page` | Stops capture and releases its inspector state. |

- The extra consent question says network details may contain cookies, authorization headers, tokens, and private response data. It is off by default, applies to this connection only, is never remembered by **Always allow**, and is revoked immediately on Stop/disconnect. No network data is returned while that question is pending or after refusal. Raw headers and bodies are available only after this explicit grant; the UI should not imply that field-name redaction can make an arbitrary response safe.
- `network_start` cannot recover earlier requests or the initial load of a tab that is already open. Add optional `capture_network: true` to `open_tab`: obtain network consent, create the tab, attach capture, then load the URL, so the first navigation is recorded. A capture started on an existing tab includes requests initiated after attachment and may include completion of an in-flight request only when WebKit supplies its start event; otherwise report that gap rather than invent a partial row.
- Use DevTools Full's existing network event and request-detail code through `SearchDevToolsPlugin.perform`, rather than a new proxy or JavaScript patch to `fetch`. The package is optional: return `network_tools_unavailable` with install instructions if it is absent, fails signature/version checks, or WebKit lacks the inspector hooks. Do not download it silently. Do not change the plugin API version unless its Objective-C protocol changes.
- Keep at most **4 active capture tabs** app-wide and at most one per agent in this version. The next start returns `too_many_captures`. Keep at most **500 request summaries per capture**; evict oldest first and report the count. Request handles are generated by Search and scoped to session, tab, and capture generation; raw WebKit IDs never become cross-session handles. Fetch details only when asked. Cap each textual body returned to **128 KiB**, set `truncated: true`, and return an explicit `body_unavailable` reason for binary, missing, expired, or failed responses. No body is written to disk.
- A visible DevTools inspector has priority over a background capture on the same tab. Starting capture while that tab's inspector is visible returns `inspector_in_use`. If the person opens DevTools there during capture, stop that capture and report `capture_interrupted` on the next network call. Capture on other tabs must not replace `DeveloperTools.shared.session`. A page close, unload, agent Stop, plugin shutdown, or capture stop releases the background inspector and stored summaries.
- If WebKit drops events or the 500-request limit evicts data, report that in the next list result. Never present an incomplete capture as complete. Do not replay requests, disable cache, throttle the profile, or modify network traffic.

## MCP and error contract

- Keep the existing stdio MCP names and JSON response pattern. Add only the four network tools above. `search-mcp` remains a thin argument/response adapter; permissions and tab ownership are enforced in Search on every request.
- Stable errors include `not_listening`, `not_allowed`, `stopped`, `too_many_agents`, `not_yours`, `stale_page`, `stale_element`, `network_tools_unavailable`, `network_not_allowed`, `too_many_captures`, `inspector_in_use`, `capture_interrupted`, and `stale_request`. Return hints where a user action can fix an error.
- A browser restart or socket loss ends the prior connection. The helper reconnects on the next call only after a clean idle release; Stop or refusal never auto-retries against the person's decision.

## Verification and baseline

1. Unit tests cover consent queue binding, per-agent tab ownership, stale handles, caps, and Stop-one versus Stop-all behavior. Preserve all current secret-field and socket-permission tests.
2. Extend the hidden `Tests/agent_control.py` probe with two to eight simultaneous MCP clients. Verify that a stalled page or client does not block the others, popups inherit only their opener's owner, user-tab read permission excludes agent tabs, and each Stop/close/idle path revokes access.
3. Use a local HTTP fixture for request/response headers, redirects, fetches, text and binary bodies, delayed responses, and a response containing a test token. Check separate network consent, no pre-consent data, request ordering, handle scope, eviction/truncation, inspector interruption, and teardown. Run DevTools Full tests with a visible inspector on another tab.
4. Build `Search.app`, quit and relaunch it with the setting already enabled, and verify that `agent.sock` appears without a shell command. Run the packaged MCP helper from each client's configured absolute path and verify first-call consent and a successful `open_tab`/`read_page`. Check the helper after app signing and packaging, and verify its Python 3 prerequisite error on a controlled missing-runtime path. When the app is fully quit, verify the helper returns `not_listening` rather than connecting elsewhere.
5. Before changing performance behavior, record a bare baseline on the deterministic local fixture: task completion rate; median and p95 latency for open/read/click/type/network calls; and app plus WebKit process memory with 1, 2, 4, and 8 simultaneous agents. Record the same after implementation. Do not claim a speed improvement from a different browser or model benchmark.

## Out of scope

No CDP endpoint, remote HTTP MCP service, automatic app launch, automatic client-config edits, site-specific scripts, arbitrary page JavaScript, autonomous task runner, request modification, downloads, network capture of the user's tabs, self-contained Python-free packaging, or model-based action selection.
