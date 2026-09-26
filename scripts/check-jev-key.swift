import Foundation
import Security

let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: "com.officecommun.search.agent-runtime.jev",
                            kSecAttrAccount as String: "default",
                            kSecReturnData as String: true,
                            kSecMatchLimit as String: kSecMatchLimitOne]
var result: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &result)
print("Keychain status: \(status); key accessible: \(status == errSecSuccess && result is Data)")
