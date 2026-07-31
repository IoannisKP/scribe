import AudioCapture
import Foundation

struct CanonicalWAVFixture: Decodable {
    let samples: [Float]
    let chunkSampleCount: Int

    static func load() throws -> CanonicalWAVFixture {
        guard let url = Bundle.module.url(
            forResource: "canonical-float32-wav",
            withExtension: "json"
        ) else {
            throw SpeechPipelineTestSupportError.fixtureMissing
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(
            CanonicalWAVFixture.self,
            from: data
        )
    }
}

enum SpeechPipelineTestSupportError: Error {
    case fixtureMissing
}

func makeTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "ScribeSpeechPipelineTests-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

func writeCanonicalWAV(
    samples: [Float],
    to url: URL
) async throws {
    let writer = try Float32WAVWriter(url: url)
    try await writer.append(samples)
    try await writer.finish()
}
