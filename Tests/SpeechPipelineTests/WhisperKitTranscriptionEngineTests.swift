import AudioCapture
import Foundation
import ModelManager
@testable import SpeechPipeline
import XCTest

final class WhisperKitTranscriptionEngineTests: XCTestCase {
    func testMissingExactModelFailsWithoutPreparingBackend() async throws {
        let root = try makeTestDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let manager = try WhisperKitModelManager(modelsDirectory: root)
        let backend = MockWhisperBackend()
        let engine = try WhisperKitTranscriptionEngine(
            model: .base,
            modelManager: manager,
            backend: backend
        )

        do {
            try await engine.prepare()
            XCTFail("Expected the exact selected model to be missing.")
        } catch let error as WhisperKitEngineError {
            guard case let .modelNotDownloaded(model, directory) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(model, .base)
            XCTAssertTrue(directory.path.hasSuffix("openai_whisper-base"))
        }
        let preparedDirectories = await backend.preparedDirectories
        XCTAssertEqual(preparedDirectories, [])
    }

    func testUsesThirtySecondGeometryAndMapsWordTimings() async throws {
        let root = try makeTestDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let manager = try WhisperKitModelManager(modelsDirectory: root)
        let modelDirectory = await manager.directory(for: .tiny)
        try Self.makeValidInstallation(at: modelDirectory)
        let backend = MockWhisperBackend(
            segments: [
                WhisperBackendSegment(
                    text: " hello world ",
                    startTime: 0,
                    endTime: 2,
                    confidence: 0.8,
                    words: [
                        WhisperBackendWord(
                            text: " hello",
                            startTime: 0.25,
                            endTime: 0.75,
                            probability: 0.9
                        ),
                        WhisperBackendWord(
                            text: " world",
                            startTime: 1.0,
                            endTime: 1.5,
                            probability: 0.8
                        ),
                    ]
                ),
            ]
        )
        let engine = try WhisperKitTranscriptionEngine(
            model: .tiny,
            modelManager: manager,
            backend: backend
        )
        XCTAssertEqual(engine.preferredWindowDuration, 30)
        XCTAssertEqual(engine.preferredOverlap, 1.5)
        XCTAssertFalse(engine.requiresNetwork)

        try await engine.prepare()
        let segments = try await engine.transcribe(
            AudioChunk(
                samples: Array(repeating: 0, count: 32_000),
                startTime: 10,
                source: .system
            )
        )
        await engine.unload()

        let preparedDirectories = await backend.preparedDirectories
        let preparedAsEnglishOnly = await backend.preparedAsEnglishOnly
        XCTAssertEqual(preparedDirectories, [modelDirectory])
        XCTAssertEqual(preparedAsEnglishOnly, [false])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "hello world")
        XCTAssertEqual(segments[0].startTime, 10.25, accuracy: 0.000_1)
        XCTAssertEqual(segments[0].endTime, 11.5, accuracy: 0.000_1)
        XCTAssertEqual(segments[0].source, .system)
        XCTAssertEqual(segments[0].words?.map(\.text), ["hello", "world"])
        let unloadCount = await backend.unloadCount
        XCTAssertEqual(unloadCount, 1)
    }

    func testLoadFailureNamesSelectedModelWithoutSubstitution() async throws {
        let root = try makeTestDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let manager = try WhisperKitModelManager(modelsDirectory: root)
        let modelDirectory = await manager.directory(for: .largeV3TurboCompressed)
        try Self.makeValidInstallation(at: modelDirectory)
        let backend = MockWhisperBackend(
            prepareError: TestError.intentional
        )
        let engine = try WhisperKitTranscriptionEngine(
            model: .largeV3TurboCompressed,
            modelManager: manager,
            backend: backend
        )

        do {
            try await engine.prepare()
            XCTFail("Expected the selected model load to fail.")
        } catch let error as WhisperKitEngineError {
            guard case let .modelLoadFailed(model, message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(model, .largeV3TurboCompressed)
            XCTAssertTrue(message.contains("intentional"))
        }
        let preparedDirectories = await backend.preparedDirectories
        XCTAssertEqual(preparedDirectories, [modelDirectory])
    }

    func testEnglishOnlyModelsDeclareEnglishPreparation() async throws {
        let root = try makeTestDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let manager = try WhisperKitModelManager(modelsDirectory: root)
        let modelDirectory = await manager.directory(for: .distilLargeV3)
        try Self.makeValidInstallation(at: modelDirectory)
        let backend = MockWhisperBackend()
        let engine = try WhisperKitTranscriptionEngine(
            model: .distilLargeV3,
            modelManager: manager,
            backend: backend
        )

        try await engine.prepare()

        let preparedAsEnglishOnly = await backend.preparedAsEnglishOnly
        XCTAssertEqual(preparedAsEnglishOnly, [true])
        XCTAssertEqual(engine.supportedLanguages, ["en"])
    }

    private static func makeValidInstallation(at directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        for name in [
            "MelSpectrogram.mlmodelc",
            "AudioEncoder.mlmodelc",
            "TextDecoder.mlmodelc",
        ] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        try Data("{}".utf8).write(
            to: directory.appendingPathComponent("tokenizer.json")
        )
        try Data("{}".utf8).write(
            to: directory.appendingPathComponent("tokenizer_config.json")
        )
    }
}

private actor MockWhisperBackend: WhisperTranscriptionBackend {
    private(set) var preparedDirectories: [URL] = []
    private(set) var preparedAsEnglishOnly: [Bool] = []
    private(set) var unloadCount = 0

    private let segments: [WhisperBackendSegment]
    private let prepareError: (any Error)?

    init(
        segments: [WhisperBackendSegment] = [],
        prepareError: (any Error)? = nil
    ) {
        self.segments = segments
        self.prepareError = prepareError
    }

    func prepare(modelDirectory: URL, englishOnly: Bool) throws {
        preparedDirectories.append(modelDirectory)
        preparedAsEnglishOnly.append(englishOnly)
        if let prepareError { throw prepareError }
    }

    func transcribe(
        samples _: [Float]
    ) -> [WhisperBackendSegment] {
        segments
    }

    func unload() {
        unloadCount += 1
    }
}

private enum TestError: Error, LocalizedError {
    case intentional

    var errorDescription: String? { "intentional backend failure" }
}
