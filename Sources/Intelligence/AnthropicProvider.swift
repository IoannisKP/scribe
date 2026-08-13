import Foundation

public struct AnthropicProvider: IntelligenceProvider, @unchecked Sendable {
    public let identifier: String
    public let displayName: String
    public let requiresKey = true

    private let baseURL: URL
    private let credential: ProviderCredential
    private let transport: any IntelligenceHTTPTransport

    public init(
        identifier: String = "anthropic",
        displayName: String = "Anthropic",
        baseURL: URL = URL(string: "https://api.anthropic.com/v1")!,
        credential: ProviderCredential,
        transport: any IntelligenceHTTPTransport =
            URLSessionIntelligenceHTTPTransport()
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.baseURL = baseURL
        self.credential = credential
        self.transport = transport
    }

    public func availableModels() async throws -> [LLMModel] {
        var request = try anthropicRequest(path: "models", method: "GET")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await transport.data(for: request)
        try IntelligenceEndpoint.validate(response)
        let result: AnthropicModelList
        do {
            result = try JSONDecoder().decode(
                AnthropicModelList.self,
                from: data
            )
        } catch {
            throw IntelligenceProviderError.malformedResponse
        }
        let models = result.data.map {
            LLMModel(identifier: $0.id, displayName: $0.displayName)
        }
        guard !models.isEmpty else {
            throw IntelligenceProviderError.emptyModelList
        }
        return models
    }

    public func complete(
        system: String,
        messages: [LLMMessage],
        model: LLMModel
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try anthropicRequest(
                        path: "messages",
                        method: "POST"
                    )
                    request.setValue(
                        "application/json",
                        forHTTPHeaderField: "Content-Type"
                    )
                    request.setValue(
                        "2023-06-01",
                        forHTTPHeaderField: "anthropic-version"
                    )
                    request.httpBody = try JSONEncoder().encode(
                        AnthropicMessageRequest(
                            model: model.identifier,
                            maxTokens: 4_096,
                            system: system,
                            messages: messages.map {
                                AnthropicWireMessage(
                                    role: $0.role.rawValue,
                                    content: $0.content
                                )
                            },
                            stream: true
                        )
                    )
                    let result = try await transport.stream(for: request)
                    try IntelligenceEndpoint.validate(result.response)
                    var decoder = ServerSentEventDecoder()
                    for try await data in result.body {
                        try Task.checkCancellation()
                        try Self.emit(
                            decoder.append(data),
                            to: continuation
                        )
                    }
                    try Self.emit(decoder.finish(), to: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func anthropicRequest(
        path: String,
        method: String
    ) throws -> URLRequest {
        try IntelligenceEndpoint.authorizedRequest(
            url: IntelligenceEndpoint.url(baseURL: baseURL, path: path),
            method: method,
            credential: credential,
            requiresKey: true,
            providerName: displayName,
            apiKeyHeader: "x-api-key",
            apiKeyPrefix: ""
        )
    }

    private static func emit(
        _ payloads: [String],
        to continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) throws {
        for payload in payloads {
            guard let data = payload.data(using: .utf8) else {
                throw IntelligenceProviderError.malformedResponse
            }
            let event: AnthropicStreamEvent
            do {
                event = try JSONDecoder().decode(
                    AnthropicStreamEvent.self,
                    from: data
                )
            } catch {
                throw IntelligenceProviderError.malformedResponse
            }
            if event.type == "error" {
                throw IntelligenceProviderError.requestRejected(
                    statusCode: 200
                )
            }
            if event.type == "content_block_delta",
                event.delta?.type == "text_delta",
                let text = event.delta?.text,
                !text.isEmpty
            {
                continuation.yield(text)
            }
        }
    }
}

private struct AnthropicModelList: Decodable {
    let data: [AnthropicWireModel]
}

private struct AnthropicWireModel: Decodable {
    let id: String
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

private struct AnthropicMessageRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [AnthropicWireMessage]
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case stream
    }
}

private struct AnthropicWireMessage: Encodable {
    let role: String
    let content: String
}

private struct AnthropicStreamEvent: Decodable {
    let type: String
    let delta: AnthropicStreamDelta?
}

private struct AnthropicStreamDelta: Decodable {
    let type: String?
    let text: String?
}
