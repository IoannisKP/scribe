import Foundation
import XCTest
@testable import Intelligence

final class IntelligenceProviderTests: XCTestCase {
    func testPresetsAreConfigurationWithExpectedEndpointsAndKeyRules() {
        XCTAssertEqual(
            IntelligenceProviderPresets.all.map(\.displayName),
            ["Anthropic", "OpenAI", "DeepSeek", "Groq", "Ollama", "LM Studio"]
        )
        XCTAssertEqual(
            IntelligenceProviderPresets.openAI.baseURL.absoluteString,
            "https://api.openai.com/v1"
        )
        XCTAssertEqual(
            IntelligenceProviderPresets.deepSeek.baseURL.absoluteString,
            "https://api.deepseek.com"
        )
        XCTAssertEqual(
            IntelligenceProviderPresets.groq.baseURL.absoluteString,
            "https://api.groq.com/openai/v1"
        )
        XCTAssertTrue(IntelligenceProviderPresets.anthropic.requiresKey)
        XCTAssertTrue(IntelligenceProviderPresets.openAI.requiresKey)
        XCTAssertTrue(IntelligenceProviderPresets.deepSeek.requiresKey)
        XCTAssertTrue(IntelligenceProviderPresets.groq.requiresKey)
        XCTAssertFalse(IntelligenceProviderPresets.ollama.requiresKey)
        XCTAssertFalse(IntelligenceProviderPresets.lmStudio.requiresKey)
    }

    func testCustomProviderValidatesRequiredFieldsAndTransportSecurity()
        throws
    {
        let remote = try CustomIntelligenceProvider(
            displayName: "Future provider",
            baseURL: XCTUnwrap(URL(string: "https://future.example/v1/")),
            modelIdentifier: "future-small",
            usesAPIKey: true
        )
        XCTAssertEqual(remote.baseURL.absoluteString, "https://future.example/v1")
        XCTAssertEqual(remote.model.identifier, "future-small")

        XCTAssertNoThrow(try CustomIntelligenceProvider(
            displayName: "Local",
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:8080/v1")),
            modelIdentifier: "local",
            usesAPIKey: false
        ))
        XCTAssertThrowsError(try CustomIntelligenceProvider(
            displayName: "Unsafe",
            baseURL: XCTUnwrap(URL(string: "http://provider.example/v1")),
            modelIdentifier: "model",
            usesAPIKey: true
        )) { error in
            XCTAssertEqual(
                error as? CustomProviderValidationError,
                .insecureRemoteBaseURL
            )
        }
        XCTAssertThrowsError(try CustomIntelligenceProvider(
            displayName: "",
            baseURL: XCTUnwrap(URL(string: "https://provider.example/v1")),
            modelIdentifier: "model",
            usesAPIKey: true
        ))
        XCTAssertThrowsError(try CustomIntelligenceProvider(
            displayName: "Embedded key",
            baseURL: XCTUnwrap(URL(
                string: "https://secret@provider.example/v1"
            )),
            modelIdentifier: "model",
            usesAPIKey: true
        ))
    }

    func testOpenAICompatibleModelsAndStreamingUseConfiguredBaseURL()
        async throws
    {
        let recorder = RequestRecorder()
        let transport = TestTransport(
            recorder: recorder,
            data: Data(#"{"data":[{"id":"z-model"},{"id":"a-model"}]}"#.utf8),
            streamChunks: [
                Data("data: {\"choices\":[{\"delta\":{\"content\":\"hel".utf8),
                Data("lo\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\r\n".utf8),
                Data("data: [DONE]\n\n".utf8)
            ]
        )
        let provider = OpenAICompatibleProvider(
            identifier: "different-vendor",
            displayName: "Different Vendor",
            baseURL: try XCTUnwrap(URL(
                string: "https://different.example/openai/v1"
            )),
            requiresKey: true,
            credential: .volatile("top-secret-value"),
            transport: transport
        )

        let models = try await provider.availableModels()
        XCTAssertEqual(models.map(\.identifier), ["a-model", "z-model"])
        let chunks = try await collect(provider.complete(
            system: "System instruction",
            messages: [LLMMessage(role: .user, content: "Hello")],
            model: LLMModel(identifier: "a-model")
        ))
        XCTAssertEqual(chunks, ["hello", " world"])

        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests[0].url?.absoluteString,
            "https://different.example/openai/v1/models"
        )
        XCTAssertEqual(
            requests[1].url?.absoluteString,
            "https://different.example/openai/v1/chat/completions"
        )
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Authorization"),
            "Bearer top-secret-value"
        )
        let body = try XCTUnwrap(requests[1].httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["model"] as? String, "a-model")
        XCTAssertEqual(object["stream"] as? Bool, true)
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
    }

    func testAnthropicUsesMessagesWireFormatAndAssemblesStreamingText()
        async throws
    {
        let recorder = RequestRecorder()
        let transport = TestTransport(
            recorder: recorder,
            data: Data(#"{"data":[{"id":"claude-test","display_name":"Claude Test"}]}"#.utf8),
            streamChunks: [
                Data("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"first\"}}\n\n".utf8),
                Data("data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" second\"}}\n\n".utf8),
                Data("data: {\"type\":\"message_stop\"}\n\n".utf8)
            ]
        )
        let provider = AnthropicProvider(
            credential: .volatile("anthropic-secret"),
            transport: transport
        )

        let models = try await provider.availableModels()
        XCTAssertEqual(
            models,
            [LLMModel(identifier: "claude-test", displayName: "Claude Test")]
        )
        let chunks = try await collect(provider.complete(
            system: "System",
            messages: [LLMMessage(role: .user, content: "Prompt")],
            model: models[0]
        ))
        XCTAssertEqual(chunks, ["first", " second"])

        let requests = await recorder.requests
        XCTAssertEqual(requests[0].url?.path, "/v1/models")
        XCTAssertEqual(requests[1].url?.path, "/v1/messages")
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "x-api-key"),
            "anthropic-secret"
        )
        XCTAssertEqual(
            requests[1].value(forHTTPHeaderField: "anthropic-version"),
            "2023-06-01"
        )
        let body = try XCTUnwrap(requests[1].httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["system"] as? String, "System")
        XCTAssertEqual(object["max_tokens"] as? Int, 4_096)
        XCTAssertEqual(object["stream"] as? Bool, true)
    }

    func testMissingKeyFailsBeforeTransport() async throws {
        let recorder = RequestRecorder()
        let provider = IntelligenceProviderPresets.openAI.provider(
            transport: TestTransport(
                recorder: recorder,
                data: Data(),
                streamChunks: []
            )
        )
        do {
            _ = try await provider.availableModels()
            XCTFail("Expected a missing-key failure")
        } catch {
            XCTAssertEqual(
                error as? IntelligenceProviderError,
                .missingAPIKey(provider: "OpenAI")
            )
        }
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testKeylessProviderNeitherResolvesNorSendsCredential() async throws {
        let recorder = RequestRecorder()
        let provider = OpenAICompatibleProvider(
            identifier: "local",
            displayName: "Local",
            baseURL: try XCTUnwrap(URL(string: "http://localhost:11434/v1")),
            requiresKey: false,
            credential: ProviderCredential {
                XCTFail("A keyless provider must not resolve a credential")
                return "must-not-be-sent"
            },
            transport: TestTransport(
                recorder: recorder,
                data: Data(#"{"data":[{"id":"local-model"}]}"#.utf8),
                streamChunks: []
            )
        )

        _ = try await provider.availableModels()
        let requests = await recorder.requests
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
    }

    func testCredentialNeverSerializesOrAppearsInDescriptionsAndErrors()
        throws
    {
        let secret = "never-persist-this-secret"
        let custom = try CustomIntelligenceProvider(
            displayName: "Custom",
            baseURL: XCTUnwrap(URL(string: "https://custom.example/v1")),
            modelIdentifier: "custom-model",
            usesAPIKey: true
        )
        let settings = IntelligenceProviderSettings(
            selectedProviderID: custom.id,
            customProviders: [custom]
        )
        let encoded = try JSONEncoder().encode(settings)
        let serialized = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(serialized.contains(secret))
        XCTAssertEqual(
            String(describing: ProviderCredential.volatile(secret)),
            "<redacted credential>"
        )
        let error = IntelligenceProviderError.requestRejected(statusCode: 401)
        XCTAssertFalse(error.localizedDescription.contains(secret))
    }

    func testSettingsStoreRoundTripsConfigurationWithoutCredentials()
        throws
    {
        let suite = "IntelligenceProviderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IntelligenceProviderSettingsStore(
            defaults: defaults,
            key: "settings"
        )
        let custom = try CustomIntelligenceProvider(
            displayName: "Custom",
            baseURL: XCTUnwrap(URL(string: "https://custom.example/v1")),
            modelIdentifier: "custom-model",
            usesAPIKey: true
        )
        let expected = IntelligenceProviderSettings(
            selectedProviderID: custom.id,
            customProviders: [custom]
        )
        try store.save(expected)
        XCTAssertEqual(store.load(), expected)
    }

    func testKeychainRoundTripUsesGenericPasswordItem() throws {
        let store = KeychainAPIKeyStore(
            service: "com.localfirst.Scribe.tests.\(UUID().uuidString)"
        )
        let account = UUID().uuidString
        let secret = "key-\(UUID().uuidString)"
        defer { try? store.removeKey(for: account) }

        XCTAssertNil(try store.key(for: account))
        try store.set(secret, for: account)
        XCTAssertEqual(try store.key(for: account), secret)
        XCTAssertEqual(try store.credential(for: account).value(), secret)
        try store.removeKey(for: account)
        XCTAssertNil(try store.key(for: account))
    }

    private func collect(
        _ stream: AsyncThrowingStream<String, any Error>
    ) async throws -> [String] {
        var result: [String] = []
        for try await value in stream { result.append(value) }
        return result
    }
}

private actor RequestRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }
}

private struct TestTransport: IntelligenceHTTPTransport, Sendable {
    let recorder: RequestRecorder
    let data: Data
    let streamChunks: [Data]
    var statusCode = 200

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        await recorder.record(request)
        return (data, response(for: request))
    }

    func stream(
        for request: URLRequest
    ) async throws -> IntelligenceHTTPStreamResponse {
        await recorder.record(request)
        let chunks = streamChunks
        return IntelligenceHTTPStreamResponse(
            response: response(for: request),
            body: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        )
    }

    private func response(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}
