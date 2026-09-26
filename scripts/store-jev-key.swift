import Foundation
import Security
import Darwin

// Reads the key from a private terminal prompt; no command-line argument or file contains it.
var original = termios()
let terminal = tcgetattr(STDIN_FILENO, &original) == 0
if terminal {
    var hidden = original
    hidden.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &hidden)
}
fputs("TypeSafe API key: ", stderr)
let key = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
if terminal { tcsetattr(STDIN_FILENO, TCSANOW, &original); fputs("\n", stderr) }
guard !key.isEmpty else { fputs("No key supplied\n", stderr); exit(1) }

let service = "com.officecommun.search.agent-runtime.jev"
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: service,
                            kSecAttrAccount as String: "default"]
let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                 kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
let status = updated == errSecItemNotFound
    ? SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    : updated
guard status == errSecSuccess else { fputs("Keychain error: \(status)\n", stderr); exit(1) }
fputs("TypeSafe key stored in Keychain for Search Agent Runtime.\n", stderr)
