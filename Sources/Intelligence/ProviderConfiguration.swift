import Foundation

public enum IntelligenceProviderKind: String, Codable, Sendable {
    case openAICompatible
    case anthropic
}

public struct IntelligenceProviderPreset: Codable, Hashable, Identifiable,
    Sendable
{
    public let id: String
    public let displayName: String
    public let baseURL: URL
    public let kind: IntelligenceProviderKind
    public let requiresKey: Bool

    public init(
        id: String,
        displayName: String,
        baseURL: URL,
        kind: IntelligenceProviderKind,
        requiresKey: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.kind = kind
        self.requiresKey = requiresKey
    }

    public func provider(
        credential: ProviderCredential = .none,
        transport: any IntelligenceHTTPTransport =
            URLSessionIntelligenceHTTPTransport()
    ) -> any IntelligenceProvider {
        switch kind {
        case .openAICompatible:
            OpenAICompatibleProvider(
                identifier: id,
                displayName: displayName,
                baseURL: baseURL,
                requiresKey: requiresKey,
                credential: credential,
                transport: transport
            )
        case .anthropic:
            AnthropicProvider(
                identifier: id,
                displayName: displayName,
                baseURL: baseURL,
                credential: credential,
                transport: transport
            )
        }
    }
}

public enum IntelligenceProviderPresets {
    public static let anthropic = preset(
        id: "anthropic",
        displayName: "Anthropic",
        baseURL: "https://api.anthropic.com/v1",
        kind: .anthropic,
        requiresKey: true
    )
    public static let openAI = preset(
        id: "openai",
        displayName: "OpenAI",
        baseURL: "https://api.openai.com/v1",
        kind: .openAICompatible,
        requiresKey: true
    )
    public static let deepSeek = preset(
        id: "deepseek",
        displayName: "DeepSeek",
        baseURL: "https://api.deepseek.com",
        kind: .openAICompatible,
        requiresKey: true
    )
    public static let groq = preset(
        id: "groq",
        displayName: "Groq",
        baseURL: "https://api.groq.com/openai/v1",
        kind: .openAICompatible,
        requiresKey: true
    )
    public static let ollama = preset(
        id: "ollama",
        displayName: "Ollama",
        baseURL: "http://localhost:11434/v1",
        kind: .openAICompatible,
        requiresKey: false
    )
    public static let lmStudio = preset(
        id: "lm-studio",
        displayName: "LM Studio",
        baseURL: "http://localhost:1234/v1",
        kind: .openAICompatible,
        requiresKey: false
    )

    public static let all: [IntelligenceProviderPreset] = [
        anthropic,
        openAI,
        deepSeek,
        groq,
        ollama,
        lmStudio
    ]

    private static func preset(
        id: String,
        displayName: String,
        baseURL: String,
        kind: IntelligenceProviderKind,
        requiresKey: Bool
    ) -> IntelligenceProviderPreset {
        IntelligenceProviderPreset(
            id: id,
            displayName: displayName,
            baseURL: URL(string: baseURL)!,
            kind: kind,
            requiresKey: requiresKey
        )
    }
}

public struct CustomIntelligenceProvider: Codable, Hashable, Identifiable,
    Sendable
{
    public let id: String
    public var displayName: String
    public var baseURL: URL
    public var modelIdentifier: String
    public var usesAPIKey: Bool

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        baseURL: URL,
        modelIdentifier: String,
        usesAPIKey: Bool
    ) throws {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !id.isEmpty, !name.isEmpty, !model.isEmpty else {
            throw CustomProviderValidationError.missingRequiredField
        }
        let validatedURL = try Self.validate(baseURL: baseURL)
        self.id = id
        self.displayName = name
        self.baseURL = validatedURL
        self.modelIdentifier = model
        self.usesAPIKey = usesAPIKey
    }

    public var model: LLMModel {
        LLMModel(identifier: modelIdentifier)
    }

    public func provider(
        credential: ProviderCredential = .none,
        transport: any IntelligenceHTTPTransport =
            URLSessionIntelligenceHTTPTransport()
    ) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            identifier: id,
            displayName: displayName,
            baseURL: baseURL,
            requiresKey: usesAPIKey,
            credential: credential,
            transport: transport
        )
    }

    private static func validate(baseURL: URL) throws -> URL {
        guard
            var components = URLComponents(
                url: baseURL,
                resolvingAgainstBaseURL: false
            ),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.port.map({ (1...65_535).contains($0) }) ?? true
        else {
            throw CustomProviderValidationError.invalidBaseURL
        }
        let isLoopback = host == "localhost" || host == "127.0.0.1"
            || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            throw CustomProviderValidationError.insecureRemoteBaseURL
        }
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard let normalized = components.url else {
            throw CustomProviderValidationError.invalidBaseURL
        }
        return normalized
    }
}

public enum CustomProviderValidationError: Error, Equatable, LocalizedError,
    Sendable
{
    case missingRequiredField
    case invalidBaseURL
    case insecureRemoteBaseURL

    public var errorDescription: String? {
        switch self {
        case .missingRequiredField:
            "Enter a display name, base URL, and model identifier."
        case .invalidBaseURL:
            "Enter a valid provider base URL without credentials, a query, or a fragment."
        case .insecureRemoteBaseURL:
            "Remote providers must use HTTPS. HTTP is allowed only for localhost."
        }
    }
}

public struct IntelligenceProviderSettings: Codable, Equatable, Sendable {
    public var selectedProviderID: String
    public var customProviders: [CustomIntelligenceProvider]

    public init(
        selectedProviderID: String = IntelligenceProviderPresets.openAI.id,
        customProviders: [CustomIntelligenceProvider] = []
    ) {
        self.selectedProviderID = selectedProviderID
        self.customProviders = customProviders
    }
}

public struct IntelligenceProviderSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = "intelligenceProviderSettings.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> IntelligenceProviderSettings {
        guard
            let data = defaults.data(forKey: key),
            let settings = try? JSONDecoder().decode(
                IntelligenceProviderSettings.self,
                from: data
            )
        else {
            return IntelligenceProviderSettings()
        }
        return settings
    }

    public func save(_ settings: IntelligenceProviderSettings) throws {
        defaults.set(try JSONEncoder().encode(settings), forKey: key)
    }
}
