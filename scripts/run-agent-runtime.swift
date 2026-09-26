import Foundation
import Security

let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: "com.officecommun.search.agent-runtime.jev",
                            kSecAttrAccount as String: "default",
                            kSecReturnData as String: true,
                            kSecMatchLimit as String: kSecMatchLimitOne]
var result: CFTypeRef?
guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
    fputs("TypeSafe key is unavailable. Run swift scripts/store-jev-key.swift first.\n", stderr)
    exit(1)
}
let search = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(".build/debug/Search")
guard FileManager.default.isExecutableFile(atPath: search.path) else {
    fputs("Build Search first: swift build -c debug\n", stderr)
    exit(1)
}
let process = Process()
process.executableURL = search
var environment = ProcessInfo.processInfo.environment
environment["SEARCH_AGENT_RUNTIME"] = "1"
environment["TYPESAFE_API_KEY"] = key
process.environment = environment
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
