import Foundation

public struct IntelligenceHTTPStreamResponse: Sendable {
    public let response: HTTPURLResponse
    public let body: AsyncThrowingStream<Data, any Error>

    public init(
        response: HTTPURLResponse,
        body: AsyncThrowingStream<Data, any Error>
    ) {
        self.response = response
        self.body = body
    }
}

public protocol IntelligenceHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func stream(for request: URLRequest) async throws
        -> IntelligenceHTTPStreamResponse
}

public struct URLSessionIntelligenceHTTPTransport:
    IntelligenceHTTPTransport, @unchecked Sendable
{
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw IntelligenceProviderError.invalidHTTPResponse
        }
        return (data, response)
    }

    public func stream(
        for request: URLRequest
    ) async throws -> IntelligenceHTTPStreamResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw IntelligenceProviderError.invalidHTTPResponse
        }
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                do {
                    var buffer: [UInt8] = []
                    buffer.reserveCapacity(4_096)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        if buffer.count == 4_096 {
                            continuation.yield(Data(buffer))
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(Data(buffer))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return IntelligenceHTTPStreamResponse(response: response, body: body)
    }
}

enum IntelligenceEndpoint {
    static func url(baseURL: URL, path: String) -> URL {
        baseURL.appending(path: path)
    }

    static func authorizedRequest(
        url: URL,
        method: String,
        credential: ProviderCredential,
        requiresKey: Bool,
        providerName: String,
        apiKeyHeader: String = "Authorization",
        apiKeyPrefix: String = "Bearer "
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if requiresKey {
            guard let key = try credential.value(), !key.isEmpty else {
                throw IntelligenceProviderError.missingAPIKey(
                    provider: providerName
                )
            }
            request.setValue(
                apiKeyPrefix + key,
                forHTTPHeaderField: apiKeyHeader
            )
        }
        return request
    }

    static func validate(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw IntelligenceProviderError.requestRejected(
                statusCode: response.statusCode
            )
        }
    }
}

struct ServerSentEventDecoder {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [String] {
        buffer.append(data)
        var payloads: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if let payload = Self.payload(from: lineData) {
                payloads.append(payload)
            }
        }
        return payloads
    }

    mutating func finish() -> [String] {
        defer { buffer.removeAll() }
        guard let payload = Self.payload(from: buffer[...]) else { return [] }
        return [payload]
    }

    private static func payload(
        from bytes: Data.SubSequence
    ) -> String? {
        var line = String(decoding: bytes, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        guard line.hasPrefix("data:") else { return nil }
        line.removeFirst("data:".count)
        if line.first == " " { line.removeFirst() }
        return line
    }
}
