import WebKit

/// Background Network inspection for agent-owned tabs. Search authenticates
/// the caller and grants access; this package owns only bounded inspector data.
@MainActor
enum AgentNetwork {
    @MainActor
    private final class Capture {
        let key: String
        let owner: String
        weak var web: WKWebView?
        let session: DeveloperToolsSession
        var handles: [String: String] = [:]
        var ids: [String: String] = [:]
        var next = 0

        init(key: String, owner: String, web: WKWebView, after closing: Task<Void, Never>?) {
            self.key = key
            self.owner = owner
            self.web = web
            session = DeveloperToolsSession(web: web, after: closing)
            session.networkRequestLimit = 500
        }

        func refresh() {
            let kept = Set(session.requests.suffix(500).map(\.id))
            for id in handles.keys.filter({ !kept.contains($0) }) {
                if let handle = handles.removeValue(forKey: id) { ids[handle] = nil }
            }
            for request in session.requests.suffix(500) where handles[request.id] == nil {
                next += 1
                let handle = "r\(key).\(next)"
                handles[request.id] = handle
                ids[handle] = request.id
            }
        }
    }

    private static var captures: [String: Capture] = [:]
    private static var interrupted: Set<String> = []

    @discardableResult
    static func interrupt(_ web: WKWebView) -> Task<Void, Never>? {
        var closing: Task<Void, Never>?
        for key in captures.keys.filter({ captures[$0]?.web === web }) {
            guard let capture = captures[key] else { continue }
            closing = capture.session.disconnect()
            captures[key] = nil
            interrupted.insert(key)
        }
        return closing
    }

    static func stopAll() {
        for capture in captures.values { _ = capture.session.disconnect() }
        captures = [:]
        interrupted = []
    }

    static func perform(_ command: String, _ args: [String: Any], web: WKWebView) async -> [String: Any] {
        guard let key = args["capture"] as? String, !key.isEmpty else { return ["error": "stale_request"] }
        for stale in captures.keys.filter({ captures[$0]?.web == nil || captures[$0]?.session.isClosed == true }) {
            captures[stale] = nil
            interrupted.insert(stale)
        }
        if command == "network_stop" {
            if let capture = captures.removeValue(forKey: key) { _ = capture.session.disconnect() }
            interrupted.remove(key)
            return ["stopped": true]
        }
        if command == "network_start" {
            if interrupted.remove(key) != nil { return ["error": "capture_interrupted"] }
            guard !DeveloperTools.shared.isOpen(on: web) else { return ["error": "inspector_in_use"] }
            if let capture = captures[key] {
                return capture.web === web ? ["capturing": true] : ["error": "stale_request"]
            }
            guard captures.count < 4,
                  let owner = args["owner"] as? String,
                  !captures.values.contains(where: { $0.owner == owner }) else {
                return ["error": "too_many_captures"]
            }
            let capture = Capture(key: key, owner: owner, web: web, after: DeveloperTools.shared.closing)
            captures[key] = capture
            let ready = await wait(10) { capture.session.ready || capture.session.connectionFailed }
            guard captures[key] === capture else { return ["error": "capture_interrupted"] }
            guard ready, capture.session.ready else {
                let why = capture.session.message ?? (ready ? "the inspector failed" : "the inspector didn't connect in time")
                captures[key] = nil
                _ = capture.session.disconnect()
                return ["error": "network_tools_unavailable", "message": why]
            }
            return ["capturing": true, "first_load": "requests after attachment only"]
        }
        if interrupted.remove(key) != nil { return ["error": "capture_interrupted"] }
        guard let capture = captures[key], capture.web === web, !capture.session.isClosed else {
            return ["error": "stale_request"]
        }
        if DeveloperTools.shared.isOpen(on: web) {
            interrupt(web)
            interrupted.remove(key)
            return ["error": "capture_interrupted"]
        }
        capture.refresh()
        switch command {
        case "network_requests":
            let limit = min(max(args["limit"] as? Int ?? 100, 1), 100)
            let rows: [[String: Any]] = capture.session.requests.suffix(limit).map { request in
                var row: [String: Any] = ["request": capture.handles[request.id] ?? "", "url": request.url,
                                          "method": request.method, "type": request.type, "failed": request.failed,
                                          "cached": request.cached]
                if let status = request.status { row["status"] = status }
                if let duration = request.time { row["duration_ms"] = duration }
                return row
            }
            let evicted = max(0, capture.session.networkRequestCount - capture.session.requests.count)
            return ["requests": rows, "evicted": evicted,
                    "incomplete": evicted > 0 || capture.session.connectionFailed]
        case "network_request":
            guard let handle = args["request"] as? String, let id = capture.ids[handle],
                  capture.session.requests.contains(where: { $0.id == id }),
                  let details = await capture.session.requestDetails(id), captures[key] === capture else {
                return ["error": "stale_request"]
            }
            var out: [String: Any] = ["request": handle, "url": details.url, "method": details.method,
                                      "request_headers": details.requestHeaders.map { [$0.name, $0.value] },
                                      "response_headers": details.responseHeaders.map { [$0.name, $0.value] }]
            if let status = details.status { out["status"] = status }
            if let post = details.postData { out["request_body"] = clipped(post) }
            else { out["request_body_unavailable"] = "WebKit did not provide it" }
            if let body = details.body, !details.base64Encoded, textual(details.mimeType) {
                out["response_body"] = clipped(body)
            } else {
                out["body_unavailable"] = details.bodyError ?? details.failure
                    ?? (details.base64Encoded ? "binary response" : "WebKit did not provide a text body")
            }
            return out
        default:
            return ["error": "unknown command"]
        }
    }

    private static func clipped(_ body: String) -> [String: Any] {
        let bytes = body.utf8
        let prefix = Array(bytes.prefix(128 << 10))
        var length = prefix.count
        while String(bytes: prefix[..<length], encoding: .utf8) == nil { length -= 1 }
        return ["text": String(bytes: prefix[..<length], encoding: .utf8) ?? "",
                "truncated": bytes.count > (128 << 10)]
    }

    private static func textual(_ mime: String?) -> Bool {
        guard let mime = mime?.lowercased() else { return false }
        return mime.hasPrefix("text/") || mime.contains("json") || mime.contains("xml") || mime.contains("javascript")
    }

    private static func wait(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
