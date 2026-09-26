import AppKit
import Foundation
import WebKit

// MODULE: AgentRuntime
// PURPOSE: Enforce session ownership and serialize verified browser mutations in one Search process.
// CORE DATA STRUCTURES: Session and tab dictionaries (8 x 8 max), per-tab FIFO lease queues, one snapshot per tab.
// TO MODIFY BEHAVIOR: Add a route in dispatch; browser mutations must use withLease and re-observe.
// DO NOT: Trust client IDs as authorization or call Jev while holding the main actor synchronously.
// EXTENSION POINT: DecisionEngine is selected per request; add routes without changing the HTTP transport.

struct AgentError: Error {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

@MainActor
final class AgentRuntime {
    static let shared = AgentRuntime()

    private final class SessionRecord {
        let id: String
        let token: String
        let client: String
        let label: String
        let mode: String
        let profile: String
        let store: WKWebsiteDataStore
        var tabs: [String] = []
        init(id: String, token: String, client: String, label: String, mode: String, profile: String, store: WKWebsiteDataStore) {
            self.id = id; self.token = token; self.client = client; self.label = label
            self.mode = mode; self.profile = profile; self.store = store
        }
    }

    private struct TabRecord {
        let session: String
        let tab: Tab
        var snapshot: [String: Any]?
    }

    private weak var browser: Browser?
    private let server = AgentHTTPServer()
    private var sessions: [String: SessionRecord] = [:]
    private var profileTokens: [String: String] = [:]
    private var tabs: [String: TabRecord] = [:]
    private var busy = Set<String>()
    private var queued: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var pendingClose = Set<String>()
    private var room: NSWindow?
    private var terminationObserver: NSObjectProtocol?
    private var token = UUID().uuidString + UUID().uuidString
    private var events: [[String: Any]] = []
    private struct CachedRequest {
        let fingerprint: Data
        let response: [String: Any]
    }
    private var completedRequests: [String: CachedRequest] = [:]
    private var completedOrder: [String] = []
    private var pendingRequests: [String: (fingerprint: Data, replies: [([String: Any]) -> Void])] = [:]
    private let traceQueue = DispatchQueue(label: "search.agent-runtime.trace")
    private let started = Date()

    private init() {}

    var isRunning: Bool { browser != nil && server.port != 0 }

    func takeOver(_ tab: Tab) -> Bool {
        guard let (id, record) = tabs.first(where: { $0.value.tab === tab }),
              !busy.contains(id), queued[id]?.isEmpty != false else { return false }
        tabs[id] = nil
        sessions[record.session]?.tabs.removeAll { $0 == id }
        tab.agentOwner = nil
        savePersistentSessions()
        trace("tab_taken_over", ["tab_id": id, "session_id": record.session])
        return true
    }

    func prepareClose(_ tab: Tab) -> Bool {
        guard let (id, record) = tabs.first(where: { $0.value.tab === tab }) else { return true }
        if busy.contains(id) {
            pendingClose.insert(id)
            return false
        }
        pendingClose.remove(id)
        tabs[id] = nil
        sessions[record.session]?.tabs.removeAll { $0 == id }
        savePersistentSessions()
        trace("tab_closed", ["session_id": record.session, "tab_id": id])
        return true
    }

    func openPopup(from opener: Tab, configuration: WKWebViewConfiguration, url: URL?) -> WKWebView? {
        guard let (openerID, record) = tabs.first(where: { $0.value.tab === opener }),
              let session = sessions[record.session], session.tabs.count < 8, let browser else { return nil }
        configuration.websiteDataStore = session.store
        let tab = browser.agentOpen(URL(string: "about:blank")!, configuration: configuration, owner: session.label)
        tab.opener = opener.id
        if let url { tab.setAddressOptimistically(url) }
        let id = tab.id.uuidString.lowercased()
        tabs[id] = TabRecord(session: session.id, tab: tab)
        session.tabs.append(id)
        browser.select(tab)
        savePersistentSessions()
        trace("popup_created", ["session_id": session.id, "tab_id": id, "opener_tab_id": openerID])
        return tab.web
    }

    func start(for browser: Browser) {
        guard self.browser == nil else { return }
        self.browser = browser
        guard server.start({ [weak self] method, path, headers, body, reply in
            Task { @MainActor in
                guard let self else { reply(["ok": false, "error": ["code": "INTERNAL_ERROR", "message": "Runtime stopped"]]); return }
                if path != "/v1/health" && headers["authorization"] != "Bearer \(self.token)" {
                    reply(["ok": false, "error": ["code": "UNAUTHORIZED", "message": "Missing runtime token"]])
                    return
                }
                let isMutation = method != "GET"
                let requestID = body["request_id"] as? String ?? ""
                if isMutation && UUID(uuidString: requestID) == nil {
                    reply(["ok": false, "error": ["code": "INVALID_ACTION", "message": "A UUID request_id is required"]])
                    return
                }
                let fingerprint = (try? JSONSerialization.data(withJSONObject: ["method": method, "path": path, "body": body,
                                                                                   "session_capability": headers["x-session-token"] ?? ""], options: [.sortedKeys])) ?? Data()
                if isMutation, let cached = self.completedRequests[requestID] {
                    if cached.fingerprint == fingerprint { reply(cached.response) }
                    else { reply(["ok": false, "error": ["code": "INVALID_ACTION", "message": "request_id was reused with a different request"]]) }
                    return
                }
                if isMutation, var pending = self.pendingRequests[requestID] {
                    if pending.fingerprint == fingerprint {
                        pending.replies.append(reply)
                        self.pendingRequests[requestID] = pending
                    } else { reply(["ok": false, "error": ["code": "INVALID_ACTION", "message": "request_id was reused with a different request"]]) }
                    return
                }
                if isMutation { self.pendingRequests[requestID] = (fingerprint, [reply]) }
                let begun = Date()
                let context: [String: Any] = ["request_id": body["request_id"] ?? "", "client_id": body["client_id"] ?? "",
                                              "session_id": body["session_id"] ?? "", "tab_id": body["tab_id"] ?? "",
                                              "path": path, "method": method]
                self.trace("request_started", context)
                do {
                    let data = try await self.dispatch(method, path, headers, body)
                    self.trace("request_completed", context.merging(["duration_ms": Int(Date().timeIntervalSince(begun) * 1000)]) { _, new in new })
                    self.finishRequest(requestID, isMutation, fingerprint, ["ok": true, "data": data, "request_id": body["request_id"] ?? NSNull()], reply)
                } catch let error as AgentError {
                    self.trace("request_failed", context.merging(["code": error.code, "duration_ms": Int(Date().timeIntervalSince(begun) * 1000)]) { _, new in new })
                    self.finishRequest(requestID, isMutation, fingerprint, ["ok": false, "error": ["code": error.code, "message": error.message], "request_id": body["request_id"] ?? NSNull()], reply)
                } catch {
                    self.trace("request_failed", context.merging(["code": "INTERNAL_ERROR", "duration_ms": Int(Date().timeIntervalSince(begun) * 1000)]) { _, new in new })
                    self.finishRequest(requestID, isMutation, fingerprint, ["ok": false, "error": ["code": "INTERNAL_ERROR", "message": error.localizedDescription], "request_id": body["request_id"] ?? NSNull()], reply)
                }
            }
        }) else { self.browser = nil; return }
        let record: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "port": server.port,
                                      "protocolVersion": "1", "authToken": token]
        let file = Store.file("agent-runtime/runtime.json")
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: record)
            try data.write(to: file, options: .atomic)
            chmod(file.path, 0o600)
        } catch { server.stop(); self.browser = nil; return }
        loadProfileTokens()
        restorePersistentSessions()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
    }

    private func finishRequest(_ id: String, _ mutation: Bool, _ fingerprint: Data,
                               _ response: [String: Any], _ directReply: @escaping ([String: Any]) -> Void) {
        guard mutation else { directReply(response); return }
        let replies = pendingRequests.removeValue(forKey: id)?.replies ?? [directReply]
        completedRequests[id] = CachedRequest(fingerprint: fingerprint, response: response)
        completedOrder.append(id)
        if completedOrder.count > 256 {
            let oldest = completedOrder.removeFirst()
            completedRequests[oldest] = nil
        }
        replies.forEach { $0(response) }
    }

    func stop() {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver); self.terminationObserver = nil }
        savePersistentSessions()
        server.stop()
        for record in Array(tabs.values) { browser?.close(record.tab) }
        tabs = [:]; sessions = [:]
        try? FileManager.default.removeItem(at: Store.file("agent-runtime/runtime.json"))
        browser = nil
    }

    private func trace(_ event: String, _ fields: [String: Any] = [:]) {
        var row = fields
        row["event"] = event
        row["ts"] = ISO8601DateFormatter().string(from: Date())
        events.append(row)
        if events.count > 500 { events.removeFirst(events.count - 500) }
        guard JSONSerialization.isValidJSONObject(row),
              var line = try? JSONSerialization.data(withJSONObject: row) else { return }
        line.append(0x0A)
        let file = Store.file("agent-runtime/events.jsonl")
        traceQueue.async {
            let previous = file.deletingLastPathComponent().appendingPathComponent("events.previous.jsonl")
            let manager = FileManager.default
            if (try? manager.attributesOfItem(atPath: file.path)[.size] as? Int).map({ $0 > 2_000_000 }) == true {
                try? manager.removeItem(at: previous)
                try? manager.moveItem(at: file, to: previous)
            }
            if !manager.fileExists(atPath: file.path) { manager.createFile(atPath: file.path, contents: nil) }
            chmod(file.path, 0o600)
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        }
    }

    private var stateFile: URL { Store.file("agent-runtime/sessions.json") }
    private var profileFile: URL { Store.file("agent-runtime/profiles.json") }

    private func loadProfileTokens() {
        guard let data = try? Data(contentsOf: profileFile),
              let tokens = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        profileTokens = tokens
    }

    private func profileCapability(_ profile: String, offered: String?) throws -> String {
        if let token = profileTokens[profile] {
            guard offered == token else { throw AgentError("UNAUTHORIZED", "Persistent profile capability does not match") }
            return token
        }
        let token = UUID().uuidString + UUID().uuidString
        profileTokens[profile] = token
        do {
            let data = try JSONSerialization.data(withJSONObject: profileTokens)
            try data.write(to: profileFile, options: .atomic)
            chmod(profileFile.path, 0o600)
        } catch {
            profileTokens[profile] = nil
            throw AgentError("INTERNAL_ERROR", "Cannot secure the persistent profile")
        }
        return token
    }

    private func savePersistentSessions() {
        let rows: [[String: Any]] = sessions.values.filter { $0.mode == "persistent" }.map { session in
            let tabRows: [[String: String]] = session.tabs.compactMap { id in
                guard let tab = tabs[id]?.tab, browser?.tabs.contains(where: { $0.id == tab.id }) == true else { return nil }
                return ["id": id, "url": tab.address?.absoluteString ?? tab.web.url?.absoluteString ?? "about:blank"]
            }
            return ["id": session.id, "token": session.token, "client": session.client,
                    "label": session.label, "profile": session.profile, "tabs": tabRows]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": rows])
            try data.write(to: stateFile, options: .atomic)
            chmod(stateFile.path, 0o600)
        } catch { trace("persistence_failed", ["reason": "write"]) }
    }

    private func restorePersistentSessions() {
        guard let data = try? Data(contentsOf: stateFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == 1,
              let rows = object["sessions"] as? [[String: Any]], let browser else { return }
        for row in rows.prefix(8) {
            guard let id = row["id"] as? String, UUID(uuidString: id) != nil,
                  let token = row["token"] as? String, token.count >= 32,
                  let client = row["client"] as? String, !client.isEmpty,
                  let label = row["label"] as? String,
                  let profile = row["profile"] as? String,
                  let store = try? profileStore(mode: "persistent", profile: profile) else { continue }
            let session = SessionRecord(id: id, token: token, client: client, label: label,
                                        mode: "persistent", profile: profile, store: store)
            sessions[id] = session
            for saved in (row["tabs"] as? [[String: String]] ?? []).prefix(8) {
                guard let tabID = saved["id"], UUID(uuidString: tabID) != nil,
                      let urlText = saved["url"], let url = URL(string: urlText),
                      ["http", "https", "about"].contains(url.scheme ?? "") else { continue }
                let config = Web.configuration(shy: true)
                config.websiteDataStore = store
                let tab = browser.agentOpen(url, configuration: config, owner: label)
                house(tab)
                tabs[tabID] = TabRecord(session: id, tab: tab)
                session.tabs.append(tabID)
            }
            trace("session_restored", ["session_id": id, "tab_count": session.tabs.count])
        }
    }

    private func profileStore(mode: String, profile: String) throws -> WKWebsiteDataStore {
        if mode == "ephemeral" { return .nonPersistent() }
        guard mode == "persistent", !profile.isEmpty, profile.count <= 80 else {
            throw AgentError("INVALID_ACTION", "Profile must be persistent with an ID or ephemeral")
        }
        let key = "agent.profile.\(profile)"
        let id: UUID
        if let existing = Store.settings.string(forKey: key).flatMap(UUID.init(uuidString:)) { id = existing }
        else { id = UUID(); Store.settings.set(id.uuidString, forKey: key) }
        return WKWebsiteDataStore(forIdentifier: id)
    }

    private func session(_ body: [String: Any], _ headers: [String: String]) throws -> SessionRecord {
        guard let id = body["session_id"] as? String, let record = sessions[id] else {
            throw AgentError("SESSION_NOT_FOUND", "Unknown session")
        }
        guard headers["x-session-token"] == record.token, body["client_id"] as? String == record.client else {
            throw AgentError("UNAUTHORIZED", "Session capability does not match")
        }
        return record
    }

    private func ownedTab(_ id: String, _ session: SessionRecord) throws -> Tab {
        guard let record = tabs[id], record.session == session.id else { throw AgentError("TAB_NOT_FOUND", "Tab is not in this session") }
        guard browser?.tabs.contains(where: { $0.id == record.tab.id }) == true else {
            tabs[id] = nil
            session.tabs.removeAll { $0 == id }
            savePersistentSessions()
            throw AgentError("TAB_NOT_FOUND", "Tab was closed")
        }
        return record.tab
    }

    private func house(_ tab: Tab) {
        guard tab.web.window == nil else { return }
        if room == nil {
            room = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800),
                            styleMask: .borderless, backing: .buffered, defer: false)
            room?.isReleasedWhenClosed = false
            room?.isExcludedFromWindowsMenu = true
            room?.collectionBehavior = [.transient, .ignoresCycle, .stationary]
            room?.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
            room?.hasShadow = false
            room?.orderBack(nil)
        }
        tab.web.frame = room?.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        tab.web.autoresizingMask = [.width, .height]
        room?.contentView?.addSubview(tab.web)
    }

    private func acquire(_ id: String) async {
        if busy.insert(id).inserted { return }
        await withCheckedContinuation { continuation in queued[id, default: []].append(continuation) }
    }

    private func release(_ id: String) {
        if pendingClose.contains(id), let tab = tabs[id]?.tab {
            pendingClose.remove(id)
            busy.remove(id)
            let waiters = queued.removeValue(forKey: id) ?? []
            browser?.close(tab)
            waiters.forEach { $0.resume() }
            return
        }
        if var pending = queued[id], !pending.isEmpty {
            let first = pending.removeFirst()
            queued[id] = pending.isEmpty ? nil : pending
            first.resume()
        } else { busy.remove(id) }
    }

    private func capture(_ id: String, _ tab: Tab) async throws -> [String: Any] {
        guard tabs[id]?.tab === tab, browser?.tabs.contains(where: { $0.id == tab.id }) == true else {
            throw AgentError("TAB_NOT_FOUND", "Tab is no longer owned by this session")
        }
        house(tab)
        let snapshot = try await AgentPage.observe(tab)
        tabs[id]?.snapshot = snapshot
        trace("snapshot", ["tab_id": id, "elements": (snapshot["elements"] as? [[String: Any]])?.count ?? 0])
        return snapshot
    }

    private func observe(_ id: String, _ tab: Tab) async throws -> [String: Any] {
        await acquire(id); defer { release(id) }
        return try await capture(id, tab)
    }

    private func waitForPage(_ tab: Tab, expected: URL? = nil, previous: String? = nil,
                             afterVersion: Int? = nil, seconds: TimeInterval = 15) async throws {
        // KVO may not have delivered isLoading yet in the same turn as load().
        try await Task.sleep(nanoseconds: 150_000_000)
        let deadline = Date().addingTimeInterval(seconds)
        var sawLoading = tab.loading
        while Date() < deadline {
            sawLoading = sawLoading || tab.loading
            if let failure = tab.failure, afterVersion == nil || tab.agentNavigationVersion > afterVersion! {
                throw AgentError("PAGE_LOAD_FAILED", failure)
            }
            let ready = (try? await AgentPage.evaluate(tab, "document.readyState")) as? String
            let liveURL = tab.web.url?.absoluteString ?? ""
            let arrived = afterVersion.map { tab.agentNavigationVersion > $0 } ??
                (expected == nil || liveURL == expected?.absoluteString || sawLoading ||
                 (previous == nil && liveURL != "about:blank") || (previous != nil && liveURL != previous))
            if arrived && !tab.loading && (ready == "interactive" || ready == "complete") && !liveURL.isEmpty && liveURL != "about:blank" {
                try await Task.sleep(nanoseconds: 150_000_000)
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw AgentError("NAVIGATION_TIMEOUT", "Page did not become ready")
    }

    private func navigate(_ id: String, _ tab: Tab, url: URL) async throws -> [String: Any] {
        await acquire(id); defer { release(id) }
        guard tabs[id]?.tab === tab else { throw AgentError("TAB_NOT_FOUND", "Tab was closed before navigation") }
        house(tab)
        let previous = tab.web.url?.absoluteString
        let version = tab.agentNavigationVersion
        tabs[id]?.snapshot = nil
        tab.go(to: url)
        try await waitForPage(tab, expected: url, previous: previous, afterVersion: version)
        if let failure = tab.failure { throw AgentError("PAGE_LOAD_FAILED", failure) }
        let snapshot = try await capture(id, tab)
        var safeURL = tab.address.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        safeURL?.query = nil
        safeURL?.fragment = nil
        trace("navigate", ["tab_id": id, "url": safeURL?.url?.absoluteString ?? ""])
        savePersistentSessions()
        return snapshot
    }

    private func mutate(_ id: String, _ tab: Tab, _ body: [String: Any], verb: String) async throws -> [String: Any] {
        await acquire(id); defer { release(id) }
        guard tabs[id]?.tab === tab else { throw AgentError("TAB_NOT_FOUND", "Tab was closed before the action") }
        guard let old = tabs[id]?.snapshot,
              let snapshotID = body["snapshot_id"] as? String,
              snapshotID == old["snapshot_id"] as? String,
              let ref = body["element_ref"] as? String else { throw AgentError("ELEMENT_STALE", "Observe the tab again") }
        guard let element = (old["elements"] as? [[String: Any]])?.first(where: { $0["ref"] as? String == ref }) else {
            throw AgentError("ELEMENT_STALE", "Element is not in the current snapshot")
        }
        house(tab)
        let expected: [String: Any] = ["role": element["role"] as? String ?? "",
                                       "name": element["name"] as? String ?? ""]
        if let requested = body["expected"] as? [String: Any],
           (requested["role"] as? String).map({ $0 != expected["role"] as? String }) == true ||
           (requested["name"] as? String).map({ $0 != expected["name"] as? String }) == true {
            throw AgentError("ELEMENT_STALE", "Expected element does not match the snapshot")
        }
        let text = verb == "keypress" ? (body["key"] as? String ?? "") : (body["text"] as? String ?? "")
        guard text.count <= 10_000 else { throw AgentError("INVALID_ACTION", "Text is too long") }
        if verb == "keypress" && !["Enter", "Escape", "Tab", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Backspace", "Delete", "Home", "End"].contains(text) {
            throw AgentError("INVALID_ACTION", "Unsupported key")
        }
        let result = try await AgentPage.act(tab, verb: verb, snapshotID: snapshotID, ref: ref, text: text, expected: expected)
        if let code = result["error"] as? String { throw AgentError(code, "Element cannot be used; observe again") }
        if verb == "fill", result["value"] as? String != text { throw AgentError("VERIFICATION_FAILED", "Field value did not match") }
        if verb == "type", result["value"] as? String != (result["previous"] as? String ?? "") + text {
            throw AgentError("VERIFICATION_FAILED", "Field value did not append the text")
        }
        if verb == "click" { try await Task.sleep(nanoseconds: 350_000_000) }
        let after = try await capture(id, tab)
        let changed = (old["url"] as? String != after["url"] as? String) ||
                      (old["text"] as? String != after["text"] as? String) ||
                      (old["title"] as? String != after["title"] as? String)
        let verified = verb == "fill" || verb == "type" || changed
        trace("action", ["tab_id": id, "verb": verb, "verified": verified])
        return ["verified": verified, "verification": verified ? "success" : "uncertain", "after": after]
    }

    private func choose(_ id: String, _ tab: Tab, _ body: [String: Any]) async throws -> [String: Any] {
        let snapshot = try await observe(id, tab)
        let goal = body["goal"] as? String ?? ""
        guard !goal.isEmpty else { throw AgentError("INVALID_ACTION", "Goal is required") }
        let elements = (snapshot["elements"] as? [[String: Any]] ?? []).filter {
            let role = $0["role"] as? String ?? ""
            return ["link", "button", "textbox", "combobox", "checkbox"].contains(role) && $0["disabled"] as? Bool != true
        }
        guard !elements.isEmpty else { throw AgentError("DECISION_INVALID", "No actionable elements") }
        let heuristic = try? await HeuristicAgentDecisionEngine().choose(goal: goal, candidates: elements)
        let engine: AgentDecisionEngine
        if body["engine"] as? String == "mock" { engine = MockAgentDecisionEngine() }
        else if heuristic?.confidence ?? 0 >= 0.9 && body["engine"] as? String != "jev" { engine = HeuristicAgentDecisionEngine() }
        else if let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] ?? AgentJevKey.load(), !key.isEmpty {
            engine = JevAgentDecisionEngine(key: key, model: ProcessInfo.processInfo.environment["TYPESAFE_MODEL"] ?? "jev-latest")
        } else if body["engine"] as? String == "jev" { throw AgentError("DECISION_ENGINE_UNAVAILABLE", "Set a TypeSafe API key in Keychain or TYPESAFE_API_KEY") }
        else { engine = HeuristicAgentDecisionEngine() }
        let choice: AgentChoice
        do {
            choice = try await engine.choose(goal: goal, candidates: Array(elements.prefix(40)))
        } catch {
            guard body["engine"] as? String != "jev", engine is JevAgentDecisionEngine,
                  let fallback = heuristic else { throw error }
            trace("decision_fallback", ["tab_id": id, "reason": "provider_unavailable"])
            choice = fallback
        }
        guard choice.confidence >= (body["min_confidence"] as? Double ?? 0.7) else {
            throw AgentError("DECISION_LOW_CONFIDENCE", "Decision confidence \(choice.confidence) is below threshold")
        }
        guard tabs[id]?.tab === tab else { throw AgentError("TAB_NOT_FOUND", "Tab was closed during the decision") }
        trace("decision", ["tab_id": id, "engine": choice.engine, "confidence": choice.confidence, "latency_ms": choice.latencyMS])
        return ["snapshot_id": snapshot["snapshot_id"] ?? "", "element_ref": choice.ref,
                "confidence": choice.confidence, "engine": choice.engine, "latency_ms": choice.latencyMS,
                "candidate_count": elements.count]
    }

    private func dispatch(_ method: String, _ path: String, _ headers: [String: String], _ body: [String: Any]) async throws -> [String: Any] {
        if method == "GET" && path == "/v1/health" { return ["version": "poc-1", "protocolVersion": "1", "pid": ProcessInfo.processInfo.processIdentifier] }
        guard headers["authorization"] == "Bearer \(token)" else { throw AgentError("UNAUTHORIZED", "Missing runtime token") }
        if method == "GET" && path == "/v1/runtime" {
            return ["sessions": sessions.count, "tabs": tabs.count, "uptime_s": Int(Date().timeIntervalSince(started)), "port": server.port, "events": Array(events.suffix(30))]
        }
        if method == "GET" && path == "/v1/sessions" {
            return ["sessions": sessions.values.map { ["id": $0.id, "client_id": $0.client, "label": $0.label, "mode": $0.mode, "profile_id": $0.profile, "tab_count": $0.tabs.count] }]
        }
        if method == "POST" && path == "/v1/sessions" {
            guard sessions.count < 8, let client = body["client_id"] as? String, !client.isEmpty else { throw AgentError("INVALID_ACTION", "Client ID required or session limit reached") }
            let profile = body["profile"] as? [String: Any] ?? [:]
            let mode = profile["mode"] as? String ?? "ephemeral"
            let name = profile["profile_id"] as? String ?? ""
            let store = try profileStore(mode: mode, profile: name)
            let profileToken = mode == "persistent" ? try profileCapability(name, offered: profile["profile_token"] as? String) : nil
            let record = SessionRecord(id: UUID().uuidString.lowercased(), token: UUID().uuidString + UUID().uuidString,
                                       client: client, label: String((body["label"] as? String ?? client).prefix(30)),
                                       mode: mode, profile: name, store: store)
            sessions[record.id] = record
            savePersistentSessions()
            trace("session_created", ["session_id": record.id, "client_id": client])
            var response: [String: Any] = ["session_id": record.id, "session_token": record.token, "mode": mode, "profile_id": name]
            if let profileToken { response["profile_token"] = profileToken }
            return response
        }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 3 && parts[0] == "v1" && parts[1] == "sessions" {
            let record = try session(body, headers)
            guard parts[2] == record.id else { throw AgentError("UNAUTHORIZED", "Session path mismatch") }
            if parts.count == 3 && method == "GET" {
                return ["session_id": record.id, "client_id": record.client, "label": record.label,
                        "mode": record.mode, "profile_id": record.profile, "tab_count": record.tabs.count]
            }
            if parts.count == 3 && method == "DELETE" {
                guard !record.tabs.contains(where: { busy.contains($0) }) else {
                    throw AgentError("TAB_BUSY", "An action is still running; retry closing the session")
                }
                for id in Array(record.tabs) { if let tab = tabs[id]?.tab { browser?.close(tab) }; tabs[id] = nil }
                sessions[record.id] = nil
                savePersistentSessions()
                trace("session_closed", ["session_id": record.id])
                return ["closed": true]
            }
            if parts.count == 4 && parts[3] == "tabs" && method == "GET" {
                return ["tabs": record.tabs.compactMap { id -> [String: Any]? in
                    guard let tab = tabs[id]?.tab else { return nil }
                    return ["id": id, "url": tab.address?.absoluteString ?? "", "title": tab.title, "loading": tab.loading]
                }]
            }
            if parts.count == 4 && parts[3] == "tabs" && method == "POST" {
                guard record.tabs.count < 8, let browser else { throw AgentError("INVALID_ACTION", "Tab limit reached") }
                let url = (body["url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "about:blank")!
                guard ["http", "https", "about"].contains(url.scheme ?? "") else { throw AgentError("INVALID_ACTION", "HTTP(S) URL required") }
                let config = Web.configuration(shy: true)
                config.websiteDataStore = record.store
                let tab = browser.agentOpen(url, configuration: config, owner: record.label)
                house(tab)
                let id = tab.id.uuidString.lowercased()
                tabs[id] = TabRecord(session: record.id, tab: tab)
                record.tabs.append(id)
                trace("tab_created", ["session_id": record.id, "tab_id": id])
                if url.scheme == "http" || url.scheme == "https" { try await waitForPage(tab, expected: url) }
                savePersistentSessions()
                return ["tab_id": id, "url": url.absoluteString]
            }
            if parts.count == 5 && parts[3] == "tabs" && method == "DELETE" {
                let tab = try ownedTab(parts[4], record)
                guard !busy.contains(parts[4]) else { throw AgentError("TAB_BUSY", "An action is still running; retry closing the tab") }
                browser?.close(tab); tabs[parts[4]] = nil; record.tabs.removeAll { $0 == parts[4] }
                savePersistentSessions()
                return ["closed": true]
            }
        }
        if parts.count == 4 && parts[0] == "v1" && parts[1] == "tabs" {
            let record = try session(body, headers)
            let id = parts[2]
            let tab = try ownedTab(id, record)
            let action = parts[3]
            if method == "POST" && action == "observe" { return try await observe(id, tab) }
            if method == "POST" && action == "choose" { return try await choose(id, tab, body) }
            if method == "POST" && action == "act_goal" {
                for attempt in 0..<2 {
                    var safeBody = body
                    safeBody["min_confidence"] = max(0.7, body["min_confidence"] as? Double ?? 0.7)
                    let selected = try await choose(id, tab, safeBody)
                    do {
                        var actionBody = body
                        actionBody["snapshot_id"] = selected["snapshot_id"]
                        actionBody["element_ref"] = selected["element_ref"]
                        let outcome = try await mutate(id, tab, actionBody, verb: "click")
                        return ["decision": selected, "action": outcome, "retries": attempt]
                    } catch let error as AgentError where error.code == "ELEMENT_STALE" && attempt == 0 {
                        trace("recovery", ["tab_id": id, "reason": "ELEMENT_STALE"])
                    }
                }
                throw AgentError("ELEMENT_STALE", "Element changed during both attempts")
            }
            if method == "POST" && action == "navigate" {
                guard let text = body["url"] as? String, let url = URL(string: text), ["http", "https"].contains(url.scheme ?? "") else { throw AgentError("INVALID_ACTION", "HTTP(S) URL required") }
                return try await navigate(id, tab, url: url)
            }
            if method == "POST" && ["click", "fill", "type", "keypress"].contains(action) { return try await mutate(id, tab, body, verb: action) }
            if method == "POST" && action == "scroll" {
                await acquire(id); defer { release(id) }
                let result = try await AgentPage.scroll(tab, y: body["y"] as? Double ?? 600)
                let after = try await capture(id, tab)
                return ["verified": (result["before"] as? Double) != (result["after"] as? Double), "after": after]
            }
            if method == "POST" && ["back", "forward", "reload"].contains(action) {
                await acquire(id); defer { release(id) }
                guard tabs[id]?.tab === tab else { throw AgentError("TAB_NOT_FOUND", "Tab was closed before navigation") }
                if action == "back" && !tab.canGoBack { throw AgentError("INVALID_ACTION", "No previous page") }
                if action == "forward" && !tab.canGoForward { throw AgentError("INVALID_ACTION", "No next page") }
                if action == "reload" && tab.isBlank { throw AgentError("INVALID_ACTION", "Blank tab cannot reload") }
                let version = tab.agentNavigationVersion
                tabs[id]?.snapshot = nil
                if action == "back" { tab.back() } else if action == "forward" { tab.forward() } else { tab.reload() }
                try await waitForPage(tab, afterVersion: version)
                let snapshot = try await capture(id, tab)
                savePersistentSessions()
                return snapshot
            }
            if method == "POST" && action == "wait" {
                let seconds = min(15.0, max(0.1, body["seconds"] as? Double ?? 5))
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline {
                    guard sessions[record.id] === record, tabs[id]?.tab === tab else {
                        throw AgentError("TAB_NOT_FOUND", "Tab was closed while waiting")
                    }
                    if !tab.loading {
                        let snapshot = try await observe(id, tab)
                        let textMatches = (body["text"] as? String).map { (snapshot["text"] as? String ?? "").contains($0) } ?? true
                        let urlMatches = (body["url_contains"] as? String).map { (snapshot["url"] as? String ?? "").contains($0) } ?? true
                        let element = body["element"] as? [String: Any]
                        let elements = snapshot["elements"] as? [[String: Any]] ?? []
                        let found = elements.contains { item in
                            let roleMatches = (element?["role"] as? String).map { item["role"] as? String == $0 } ?? true
                            let nameMatches = (element?["name"] as? String).map { item["name"] as? String == $0 } ?? true
                            return roleMatches && nameMatches
                        }
                        let elementMatches = element == nil || ((element?["present"] as? Bool ?? true) == found)
                        if textMatches && urlMatches && elementMatches { return snapshot }
                    }
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                throw AgentError("NAVIGATION_TIMEOUT", "Wait condition was not met")
            }
            if method == "POST" && action == "screenshot" {
                await acquire(id); defer { release(id) }
                house(tab)
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    tab.web.takeSnapshot(with: nil) { image, error in
                        if let error { continuation.resume(throwing: error); return }
                        guard let tiff = image?.tiffRepresentation,
                              let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                        else { continuation.resume(throwing: AgentError("INTERNAL_ERROR", "No screenshot")); return }
                        continuation.resume(returning: data)
                    }
                }
                return ["mime_type": "image/png", "base64": data.base64EncodedString()]
            }
            if method == "POST" && action == "activate" { browser?.select(tab); return ["active": true] }
        }
        throw AgentError("INVALID_ACTION", "Unknown route")
    }
}
