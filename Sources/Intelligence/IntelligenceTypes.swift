import Foundation

public struct LLMModel: Codable, Hashable, Identifiable, Sendable {
    public let identifier: String
    public let displayName: String

    public var id: String { identifier }

    public init(identifier: String, displayName: String? = nil) {
        self.identifier = identifier
        self.displayName = displayName ?? identifier
    }
}

public enum LLMMessageRole: String, Codable, Sendable {
    case user
    case assistant
}

public struct LLMMessage: Codable, Equatable, Sendable {
    public let role: LLMMessageRole
    public let content: String

    public init(role: LLMMessageRole, content: String) {
        self.role = role
        self.content = content
    }
}

public protocol IntelligenceProvider: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    var requiresKey: Bool { get }

    func availableModels() async throws -> [LLMModel]

    func complete(
        system: String,
        messages: [LLMMessage],
        model: LLMModel
    ) -> AsyncThrowingStream<String, any Error>
}

public enum IntelligenceProviderError: Error, Equatable, LocalizedError,
    Sendable
{
    case invalidBaseURL
    case insecureRemoteBaseURL
    case missingAPIKey(provider: String)
    case invalidHTTPResponse
    case requestRejected(statusCode: Int)
    case malformedResponse
    case emptyModelList

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "The provider base URL is invalid."
        case .insecureRemoteBaseURL:
            "Remote providers must use HTTPS. HTTP is allowed only for localhost."
        case let .missingAPIKey(provider):
            "Add an API key for \(provider)."
        case .invalidHTTPResponse:
            "The provider returned an invalid response."
        case let .requestRejected(statusCode):
            "The provider rejected the request (HTTP \(statusCode))."
        case .malformedResponse:
            "The provider returned data Scribe could not read."
        case .emptyModelList:
            "The provider returned no available models."
        }
    }
}

public struct ProviderCredential: @unchecked Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    private let resolver: @Sendable () throws -> String?

    public var description: String { "<redacted credential>" }
    public var debugDescription: String { description }

    public init(resolver: @escaping @Sendable () throws -> String?) {
        self.resolver = resolver
    }

    public func value() throws -> String? {
        try resolver()?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let none = ProviderCredential { nil }

    public static func volatile(_ value: String?) -> ProviderCredential {
        ProviderCredential { value }
    }
}
