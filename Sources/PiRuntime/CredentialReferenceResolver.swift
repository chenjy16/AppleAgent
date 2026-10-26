import Foundation
#if canImport(Security)
import Security
#endif

/// Resolves a complete header value reference without interpolating or logging secret material.
public enum CredentialReferenceResolver {
    public static func resolve(_ values: [String: String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> [String: String] {
        try values.mapValues { original in
            var value = original
            var searchStart = value.startIndex
            while let start = value.range(of: "${", range: searchStart..<value.endIndex) {
                guard let close = value[start.upperBound...].firstIndex(of: "}") else {
                    throw CredentialReferenceError.invalidReference
                }
                let reference = String(value[start.upperBound..<close])
                let secret = try resolveReference(reference, environment: environment)
                let after = value.index(after: close)
                value.replaceSubrange(start.lowerBound..<after, with: secret)
                searchStart = value.index(start.lowerBound, offsetBy: secret.count)
                if searchStart >= value.endIndex { break }
            }
            return value
        }
    }

    private static func resolveReference(_ reference: String, environment: [String: String]) throws -> String {
        if reference.hasPrefix("ENV:") {
            let name = String(reference.dropFirst(4))
            guard !name.isEmpty, let secret = environment[name], !secret.isEmpty else {
                throw CredentialReferenceError.missingEnvironmentValue(name)
            }
            return secret
        }
        if reference.hasPrefix("KEYCHAIN:") {
            let components = reference.dropFirst(9).split(separator: ":", maxSplits: 1).map(String.init)
            guard components.count == 2, !components[0].isEmpty, !components[1].isEmpty else {
                throw CredentialReferenceError.invalidReference
            }
            guard let secret = keychainValue(service: components[0], account: components[1]) else {
                throw CredentialReferenceError.missingKeychainValue(components[0], components[1])
            }
            return secret
        }
        throw CredentialReferenceError.invalidReference
    }

    private static func keychainValue(service: String, account: String) -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }
}

public enum CredentialReferenceError: Error, LocalizedError {
    case invalidReference
    case missingEnvironmentValue(String)
    case missingKeychainValue(String, String)

    public var errorDescription: String? {
        switch self {
        case .invalidReference: "Invalid credential reference; use ${ENV:NAME} or ${KEYCHAIN:service:account}"
        case .missingEnvironmentValue(let name): "Credential environment variable '\(name)' is unavailable"
        case .missingKeychainValue(let service, let account): "No Keychain credential exists for service '\(service)' and account '\(account)'"
        }
    }
}
