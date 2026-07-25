import Foundation
import Security

/// Keychain wrapper for provider API keys. Keys live only on-device, encrypted
/// at rest, and survive standalone launches (no cable / no server needed).
enum KeychainStore {
    private static let service = "com.jerry.jarvis"

    static var openAIKey: String? {
        get { read("openai-api-key") }
        set { write("openai-api-key", newValue) }
    }

    static var deepSeekKey: String? {
        get { read("deepseek-api-key") }
        set { write("deepseek-api-key", newValue) }
    }

    static var elevenLabsKey: String? {
        get { read("elevenlabs-api-key") }
        set { write("elevenlabs-api-key", newValue) }
    }

    static var dashScopeKey: String? {
        get { read("dashscope-api-key") }
        set { write("dashscope-api-key", newValue) }
    }

    private static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty else {
            return nil
        }
        return string
    }

    private static func write(_ account: String, _ value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
