# Agent Browser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Claude Code, Codex, and OpenCode control Search concurrently through MCP and inspect network traffic in their own tabs.

**Architecture:** Search keeps one socket but owns up to eight independent `AgentSession`s. The optional Full DevTools plugin owns bounded background network captures; Search enforces consent and ownership before invoking it. The bundled Python helper remains a thin stdio MCP adapter.

**Tech Stack:** Swift, SwiftUI, AppKit, WebKit, Python 3 standard library, shell packaging.

**Spec:** `docs/superpowers/specs/2026-11-25-agent-browser-techspec.md`

## Global Constraints

- Eight live connections, four capture tabs total, one capture tab per agent.
- Five minute idle release, 500 network summaries per capture, 128 KiB textual body cap.
- No TCP listener, automatic app launch, arbitrary page JavaScript, or new dependency.
- The saved agent setting starts the socket on browser launch; MCP clients start their own stdio helper.

## Review Focus

- A stopped session must not act from a delayed callback; exercise Stop during a pending request.
- A tab owned by another agent must be invisible even with the user-tab grant; exercise cross-session list and read.
- A stale request handle after capture restart must fail; exercise stop and restart.
- A slow reader must not grow unsent data without bound; exercise eight sessions near the cap.
- A visible inspector taking a captured tab must interrupt capture; exercise both opening orders.

---

### Task 1: Independent agent sessions and tabs

**Files:** `Sources/Search/AgentControl.swift`, `Sources/Search/AgentBanner.swift`, `Tests/SearchTests/AgentControlTests.swift`, `Tests/agent_control.py`

**Interfaces:** `AgentControl.sessions: [UUID: AgentSession]`, `stopSession(_ id: UUID)`, `stopAllSessions()`, per-session consent controls, `owner(of: Tab.ID)`.

- [ ] Add a failing two-client probe for independent requests, eighth/ninth connection behavior, Stop one versus Stop all, and cross-agent tab invisibility.
- [ ] Run the focused probe and confirm the failure.
- [ ] Replace singleton session routing with collection membership checks, queue consent per window, bind UI actions to IDs, and enforce ownership on every tab resolution.
- [ ] Run focused Swift and Python probes; fix all failures.
- [ ] Commit the working concurrent-session slice.

### Task 2: Background network capture

**Files:** `Sources/DevToolsFull/FullAutomation.swift`, `Sources/DevToolsFull/DeveloperTools.swift`, `Sources/Search/AgentControl.swift`, `search-mcp`, `Tests/agent_control.py`

**Interfaces:** MCP `network_start`, `network_requests`, `network_request`, `network_stop`; plugin `perform` commands with the same names; optional `capture_network` on `open_tab`.

- [ ] Add local HTTP fixture assertions for headers, text and binary bodies, request limits, consent, handle scope, and inspector interruption; run to fail.
- [ ] Add bounded Full-plugin capture lifecycle and per-session network consent/ownership in Search.
- [ ] Expose the four MCP tools and first-load capture option; run the network fixture and plugin tests.
- [ ] Commit the working network slice.

### Task 3: Install and verify

**Files:** `build.sh`, `README.md`, `search-mcp`, relevant packaging tests.

**Interfaces:** executable `Search.app/Contents/Resources/search-mcp`, documented absolute-path registration for three clients.

- [ ] Add a packaging check for the bundled helper and missing Python prerequisite; run it to fail.
- [ ] Package the helper before signing and document one-time registration and automatic socket startup.
- [ ] Build the app, test fresh and relaunch connections, run focused tests and 1/2/4/8 agent baseline.
- [ ] Review the full change, fix important findings, and commit.
