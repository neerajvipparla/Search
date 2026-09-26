# Search Agent Runtime — 2026-09-24

## Why POC

The open question is whether one Search process can safely serve two coding agents and whether Jev improves ambiguous element selection. The browser API and decision policy need measurements before becoming a stable product interface.

## What we are trying to prove

- Two clients can own separate tabs and WebKit stores in one process.
- Agents can observe, act, and verify through a local API and MCP.
- Jev can choose from a bounded set of page elements, with a recorded confidence and latency.

## POC decisions

- Agent tabs appear in the normal tab strip and are excluded from manual session restore.
- The runtime starts only when `SEARCH_AGENT_RUNTIME=1` is set.
- A loopback HTTP server and a same-user discovery file connect MCP clients.
- Jev uses TypeSafe's documented HTTP API. The local debug launcher reads the key from macOS Keychain and passes it to the child process environment.
- The high-risk classifier and Playwright benchmark suite are outside this POC, as requested.

## What must change for production

| POC shortcut | Production requirement | Why |
|---|---|---|
| Keychain-backed debug launcher | Signed-app Keychain onboarding and rotation UI | The Swift interpreter and unsigned debug app do not share Keychain access automatically. |
| Local discovery bearer token | Explicit per-client capabilities and threat review | A same-user local process can read the discovery file. |
| JSON session metadata and stable-client cache | Hardened recovery and capability lifecycle | The POC restores persistent tabs, not in-flight work or unsaved form state. |
| Small local fixtures | Wider site corpus and Playwright comparison | POC success does not establish general reliability or speed. |
