import Foundation
import Security

// MODULE: AgentDecision
// PURPOSE: Select one bounded DOM candidate without granting authority to execute it.
// CORE DATA STRUCTURES: Candidate arrays are capped at 40; each decision is request scoped.
// TO MODIFY BEHAVIOR: Add a DecisionEngine implementation and select it in AgentRuntime.
// DO NOT: Put API keys or unrestricted page text in logs; execute model output as code.
// EXTENSION POINT: DecisionEngine allows another provider without changing browser actions.

struct AgentChoice {
    let ref: String
    let confidence: Double
    let engine: String
    let latencyMS: Int
}

enum AgentJevKey {
    static let service = "com.officecommun.search.agent-runtime.jev"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

protocol AgentDecisionEngine {
    func choose(goal: String, candidates: [[String: Any]]) async throws -> AgentChoice
}

struct MockAgentDecisionEngine: AgentDecisionEngine {
    func choose(goal: String, candidates: [[String: Any]]) async throws -> AgentChoice {
        guard let ref = candidates.first?["ref"] as? String else { throw AgentError("DECISION_INVALID", "No candidates") }
        return AgentChoice(ref: ref, confidence: 1, engine: "mock", latencyMS: 0)
    }
}

struct HeuristicAgentDecisionEngine: AgentDecisionEngine {
    func choose(goal: String, candidates: [[String: Any]]) async throws -> AgentChoice {
        let words = Set(goal.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let ranked = candidates.compactMap { item -> (String, Int)? in
            guard let ref = item["ref"] as? String, item["disabled"] as? Bool != true else { return nil }
            let label = ((item["name"] as? String) ?? "").lowercased()
            let href = ((item["href"] as? String) ?? "").lowercased()
            let role = (item["role"] as? String) ?? ""
            let tokens = Set(label.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            var score = words.intersection(tokens).count * 10
            if !label.isEmpty && goal.lowercased().contains(label) { score += 20 }
            if words.contains("click") { score += ["button", "link"].contains(role) ? 15 : -15 }
            if !words.isDisjoint(with: ["type", "fill", "enter"]) { score += role == "textbox" ? 20 : -20 }
            if words.contains("search") && role == "textbox" && !words.contains("click") { score += 4 }
            if words.contains(where: { href.contains($0) }) { score += 2 }
            return (ref, score)
        }.sorted { $0.1 > $1.1 }
        guard let first = ranked.first, first.1 > 0 else { throw AgentError("DECISION_LOW_CONFIDENCE", "No matching element") }
        let second = ranked.dropFirst().first?.1 ?? 0
        let confidence = min(0.99, first.1 >= second + 15 ? 0.95 : 0.55)
        return AgentChoice(ref: first.0, confidence: confidence, engine: "heuristic", latencyMS: 0)
    }
}

struct JevAgentDecisionEngine: AgentDecisionEngine {
    let key: String
    let model: String

    func choose(goal: String, candidates: [[String: Any]]) async throws -> AgentChoice {
        guard !candidates.isEmpty else { throw AgentError("DECISION_INVALID", "No candidates") }
        let choices = Dictionary(uniqueKeysWithValues: candidates.prefix(40).compactMap { item -> (String, String)? in
            guard let ref = item["ref"] as? String else { return nil }
            let role = item["role"] as? String ?? "element"
            let name = item["name"] as? String ?? ""
            let rawHref = item["href"] as? String ?? ""
            var safeHref = URLComponents(string: rawHref)
            safeHref?.query = nil
            safeHref?.fragment = nil
            return (ref, "\(role): \(name) \((safeHref?.string ?? "").prefix(120))")
        })
        let body: [String: Any] = [
            "model": model,
            "state": ["goal": String(goal.prefix(500)), "candidates": choices],
            "questions": ["element": ["type": "choice", "instructions": "Select the visible element best matching the browser goal. Use only the listed choices.", "criteria": choices]]
        ]
        var request = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = min(30, max(3, Double(ProcessInfo.processInfo.environment["TYPESAFE_TIMEOUT_SECONDS"] ?? "12") ?? 12))
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let start = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw AgentError("JEV_TIMEOUT", "TypeSafe did not respond before the configured timeout")
        } catch {
            throw AgentError("DECISION_ENGINE_UNAVAILABLE", "TypeSafe request failed: \(error.localizedDescription)")
        }
        let latency = Int(Date().timeIntervalSince(start) * 1000)
        guard let http = response as? HTTPURLResponse else { throw AgentError("DECISION_ENGINE_UNAVAILABLE", "No HTTP response") }
        if http.statusCode == 401 || http.statusCode == 403 { throw AgentError("JEV_AUTH_FAILED", "TypeSafe authorization failed") }
        if http.statusCode == 429 { throw AgentError("JEV_RATE_LIMITED", "TypeSafe rate limit") }
        guard (200..<300).contains(http.statusCode) else { throw AgentError("DECISION_ENGINE_UNAVAILABLE", "TypeSafe HTTP \(http.statusCode)") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["answers"] as? [String: Any],
              let element = answers["element"] as? [String: Any],
              let ref = element["choice"] as? String,
              let confidence = element["confidence"] as? Double,
              choices[ref] != nil
        else { throw AgentError("DECISION_INVALID", "TypeSafe returned an invalid choice") }
        return AgentChoice(ref: ref, confidence: confidence, engine: "jev", latencyMS: latency)
    }
}
