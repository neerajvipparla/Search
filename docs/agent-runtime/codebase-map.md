# Agent Runtime codebase map

The existing browser remains the owner of tabs and WebKit views; this POC adds a narrow runtime around it.

| Area | Actual file | Role |
|---|---|---|
| App/window entry | `Sources/Search/App.swift` | Creates and displays the SwiftUI browser window. |
| Browser model | `Sources/Search/Browser.swift` | Owns the tab array, selection, navigation delegates, and opt-in runtime startup. |
| Tab and WKWebView | `Sources/Search/Tab.swift` | Lazily creates each `PageView` with its supplied `WKWebViewConfiguration`; exposes the agent-owner label. |
| WebKit profile precedent | `Sources/Search/Spaces.swift` | Existing named `WKWebsiteDataStore` pattern. |
| Persistence | `Sources/Search/Store.swift`, `Sources/Search/Session.swift` | Application Support paths/settings and ordinary manual tab restore. Agent tabs stay separate. |
| Existing script control | `Sources/Search/Bench.swift` | Independent local testing socket; Agent Runtime does not replace it. |
| Runtime API | `Sources/Search/AgentHTTP.swift` | Loopback HTTP framing, request size cap, bearer-token envelope. |
| Runtime ownership | `Sources/Search/AgentRuntime.swift` | Sessions, profiles, tab ownership, leases, actions, verification, restoration, tracing. |
| Page state | `Sources/Search/AgentPage.swift` | Bounded DOM snapshot and snapshot-aware element actions. |
| Decisions | `Sources/Search/AgentDecision.swift` | Mock/heuristic/Jev strategy and TypeSafe HTTP adapter. |
| MCP bridge | `mcp/search_mcp.py` | Stdio MCP tools, client identity, runtime discovery, persistent-session reattachment. |
| Local tests | `tests/agent_runtime/` | Fixture site and protocol/integration checks. |

For each agent tab, the runtime supplies either an ephemeral `WKWebsiteDataStore` or a named persistent one to the existing `Tab` initializer. The browser process is shared; tab and data-store ownership are partitioned. The HTTP server does not hold WebKit objects. All WebKit access is on the main actor, while Jev network work is asynchronous.
