import Foundation
#if canImport(Security)
import Security
#endif

public protocol CredentialStore: Sendable {
    func apiKey(for providerID: String) -> String?
}

public struct EnvironmentCredentialStore: CredentialStore {
    private let values: [String: String]
    public init(values: [String: String] = ProcessInfo.processInfo.environment) { self.values = values }

    public func apiKey(for providerID: String) -> String? {
        let variables: [String]
        switch providerID {
        case "anthropic": variables = ["ANTHROPIC_API_KEY"]
        case "gemini": variables = ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        default: variables = ["OPENAI_API_KEY"]
        }
        for variable in variables {
            if let value = values[variable], !value.isEmpty { return value }
        }
        return nil
    }
}

public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    public init(service: String = "apple-agent") { self.service = service }

    public func apiKey(for providerID: String) -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
        #else
        return nil
        #endif
    }
}

public struct CompositeCredentialStore: CredentialStore {
    private let stores: [any CredentialStore]
    public init(_ stores: [any CredentialStore] = [EnvironmentCredentialStore(), KeychainCredentialStore()]) {
        self.stores = stores
    }
    public func apiKey(for providerID: String) -> String? { stores.lazy.compactMap { $0.apiKey(for: providerID) }.first }
}
