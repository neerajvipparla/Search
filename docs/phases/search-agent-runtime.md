# Search Agent Runtime — implementation phases

## Design

Primary pattern: Strategy (behavioral). `DecisionEngine` selects among heuristic, mock, and Jev implementations without coupling WebKit execution to TypeSafe. The trade-off is an interface and result type for a small POC.

The runtime owns session and tab maps keyed by opaque UUIDs. These are bounded by configured session/tab limits and cleaned on close. A set of busy tab IDs enforces one mutation per tab. Snapshots are kept only per tab and replaced on each observation. WebKit access remains on the main actor. The HTTP transport owns no browser state.

## Phase 1.0: Runtime and isolation
- What: opt-in loopback server, discovery, session/profile/tab ownership, visible agent tabs.
- Data structures: dictionaries keyed by session and tab UUID; bounded by 8 sessions and 8 tabs per session.
- Done when: two sessions can open tabs with distinct data stores and cross-session access fails.
- Status: [x] Two isolated sessions, ownership denial, profile reuse, and restart restoration checked locally.

## Phase 2.0: Structured interaction
- What: snapshot observation, references, click/fill/navigation/wait/screenshot, verification, bounded recovery and tab leases.
- Data structures: one replaceable snapshot per tab; busy-tab set and per-tab wait queue.
- Inputs: Phase 1.0.
- Done when: fixture tasks execute and stale refs fail safely.
- Status: [x] Fixture tests cover stale refs and fill/type/keypress/click verification; per-tab serialization is implemented but not stress-tested.

## Phase 3.0: Decision layer
- What: heuristic, mock, and live Jev choice adapter; confidence and latency trace.
- Data structures: candidate array capped at 40.
- Inputs: Phase 2.0.
- Done when: ambiguous fixture selection calls Jev and returns its decision without direct execution by the model.
- Status: [x] Mock/heuristic/live Jev selection and confidence/latency responses checked.

## Phase 4.0: MCP and end-to-end demonstration
- What: stdio MCP companion, Claude Code and Codex setup, two-client fixture demo and documentation.
- Inputs: Phases 1.0–3.0.
- Done when: both clients can connect to one running Search process and run separate fixture tasks.
- Status: [~] Both clients are configured; two independent MCP adapters passed the fixture test. An interactive task from both clients has not yet been observed.
