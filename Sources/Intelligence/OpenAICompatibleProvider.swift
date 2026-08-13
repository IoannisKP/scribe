import Foundation

public struct OpenAICompatibleProvider: IntelligenceProvider,
    @unchecked Sendable
{
    public let identifier: String
    public let displayName: String
    public let requiresKey: Bool

    private let baseURL: URL
    private let credential: ProviderCredential
    private let transport: any IntelligenceHTTPTransport

    public init(
        identifier: String,
        displayName: String,
        baseURL: URL,
        requiresKey: Bool,
        credential: ProviderCredential,
        transport: any IntelligenceHTTPTransport =
            URLSessionIntelligenceHTTPTransport()
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.baseURL = baseURL
        self.requiresKey = requiresKey
        self.credential = credential
        self.transport = transport
    }

    public func availableModels() async throws -> [LLMModel] {
        let request = try IntelligenceEndpoint.authorizedRequest(
            url: IntelligenceEndpoint.url(baseURL: baseURL, path: "models"),
            method: "GET",
            credential: credential,
            requiresKey: requiresKey,
            providerName: displayName
        )
        let (data, response) = try await transport.data(for: request)
        try IntelligenceEndpoint.validate(response)
        let result: ModelList
        do {
            result = try JSONDecoder().decode(ModelList.self, from: data)
        } catch {
            throw IntelligenceProviderError.malformedResponse
        }
        let models = result.data
            .map { LLMModel(identifier: $0.id) }
            .sorted { $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending }
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
                    var request = try IntelligenceEndpoint.authorizedRequest(
                        url: IntelligenceEndpoint.url(
                            baseURL: baseURL,
                            path: "chat/completions"
                        ),
                        method: "POST",
                        credential: credential,
                        requiresKey: requiresKey,
                        providerName: displayName
                    )
                    request.setValue(
                        "application/json",
                        forHTTPHeaderField: "Content-Type"
                    )
                    request.httpBody = try JSONEncoder().encode(
                        CompletionRequest(
                            model: model.identifier,
                            messages: Self.wireMessages(
                                system: system,
                                messages: messages
                            ),
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

    private static func wireMessages(
        system: String,
        messages: [LLMMessage]
    ) -> [WireMessage] {
        var result: [WireMessage] = []
        if !system.isEmpty {
            result.append(WireMessage(role: "system", content: system))
        }
        result.append(contentsOf: messages.map {
            WireMessage(role: $0.role.rawValue, content: $0.content)
        })
        return result
    }

    private static func emit(
        _ payloads: [String],
        to continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) throws {
        for payload in payloads where payload != "[DONE]" {
            guard let data = payload.data(using: .utf8) else {
                throw IntelligenceProviderError.malformedResponse
            }
            let chunk: CompletionChunk
            do {
                chunk = try JSONDecoder().decode(
                    CompletionChunk.self,
                    from: data
                )
            } catch {
                throw IntelligenceProviderError.malformedResponse
            }
            for choice in chunk.choices {
                if let content = choice.delta.content, !content.isEmpty {
                    continuation.yield(content)
                }
            }
        }
    }
}

private struct ModelList: Decodable {
    let data: [WireModel]
}

private struct WireModel: Decodable {
    let id: String
}

private struct CompletionRequest: Encodable {
    let model: String
    let messages: [WireMessage]
    let stream: Bool
}

private struct WireMessage: Codable {
    let role: String
    let content: String
}

private struct CompletionChunk: Decodable {
    let choices: [CompletionChoice]
}

private struct CompletionChoice: Decodable {
    let delta: CompletionDelta
}

private struct CompletionDelta: Decodable {
    let content: String?
}
