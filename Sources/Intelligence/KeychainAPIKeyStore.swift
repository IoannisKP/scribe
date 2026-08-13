import Foundation
import Security

public protocol APIKeyStoring: Sendable {
    func set(_ key: String, for providerID: String) throws
    func key(for providerID: String) throws -> String?
    func removeKey(for providerID: String) throws
}

public struct KeychainAPIKeyStore: APIKeyStoring, Sendable {
    public let service: String

    public init(service: String = "com.localfirst.Scribe.intelligence") {
        self.service = service
    }

    public func set(_ key: String, for providerID: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try removeKey(for: providerID)
            return
        }
        let data = Data(trimmed.utf8)
        let identity = query(for: providerID)
        let status = SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var addition = identity
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addition as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainAPIKeyStoreError.status(addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainAPIKeyStoreError.status(status)
        }
    }

    public func key(for providerID: String) throws -> String? {
        var request = query(for: providerID)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            request as CFDictionary,
            &result
        )
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainAPIKeyStoreError.status(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func removeKey(for providerID: String) throws {
        let status = SecItemDelete(query(for: providerID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainAPIKeyStoreError.status(status)
        }
    }

    public func credential(for providerID: String) -> ProviderCredential {
        ProviderCredential { try key(for: providerID) }
    }

    private func query(for providerID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID
        ]
    }
}

public enum KeychainAPIKeyStoreError: Error, Equatable, LocalizedError,
    Sendable
{
    case status(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .status(status):
            "Keychain operation failed (\(status))."
        }
    }
}

public struct ProviderConnectionTester: Sendable {
    public init() {}

    @discardableResult
    public func test(
        _ provider: any IntelligenceProvider
    ) async throws -> [LLMModel] {
        try await provider.availableModels()
    }
}
