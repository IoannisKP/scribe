import AudioCapture
@testable import SpeechPipeline
import XCTest

final class ParakeetTranscriptionEngineTests: XCTestCase {
    func testMetadataDeclaresOfflineInferenceAndExpectedLanguages() async {
        let backend = ParakeetBackendSpy(
            result: ParakeetBackendResult(
                text: "",
                confidence: 0,
                duration: 0,
                words: []
            )
        )
        let engine = ParakeetTranscriptionEngine(
            model: .v3Multilingual,
            modelDirectory: URL(fileURLWithPath: "/tmp/model"),
            backend: backend
        )

        XCTAssertEqual(engine.identifier, "fluidaudio.parakeet.v3Multilingual")
        XCTAssertFalse(engine.supportsStreaming)
        XCTAssertFalse(engine.requiresNetwork)
        XCTAssertEqual(engine.supportedLanguages.count, 25)
        XCTAssertTrue(engine.supportedLanguages.contains("el"))
        XCTAssertEqual(engine.preferredWindowDuration, 14)
        XCTAssertEqual(engine.preferredOverlap, 1.5)
    }

    func testMapsChunkLocalWordTimingsOntoSharedTimeline() async throws {
        let backend = ParakeetBackendSpy(
            result: ParakeetBackendResult(
                text: "Hello world.",
                confidence: 0.91,
                duration: 1.2,
                words: [
                    ParakeetBackendWord(
                        text: "Hello",
                        startTime: 0.1,
                        endTime: 0.5
                    ),
                    ParakeetBackendWord(
                        text: "world.",
                        startTime: 0.6,
                        endTime: 1.1
                    ),
                ]
            )
        )
        let engine = ParakeetTranscriptionEngine(
            model: .v2English,
            modelDirectory: URL(fileURLWithPath: "/tmp/model"),
            backend: backend
        )
        let chunk = AudioChunk(
            samples: Array(repeating: 0, count: 32_000),
            startTime: 7.25,
            source: .system
        )

        try await engine.prepare()
        let segments = try await engine.transcribe(chunk)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].source, .system)
        XCTAssertEqual(segments[0].startTime, 7.35, accuracy: 0.000_1)
        XCTAssertEqual(segments[0].endTime, 8.35, accuracy: 0.000_1)
        XCTAssertEqual(segments[0].confidence, 0.91)
        XCTAssertEqual(segments[0].words?.first?.startTime, 7.35)
        let preparedModel = await backend.preparedModel
        let transcribedSampleCount = await backend.transcribedSampleCount
        XCTAssertEqual(preparedModel, .v2English)
        XCTAssertEqual(transcribedSampleCount, 32_000)
    }

    func testEmptyASRTextProducesNoSegment() async throws {
        let backend = ParakeetBackendSpy(
            result: ParakeetBackendResult(
                text: "  \n",
                confidence: 1,
                duration: 0.5,
                words: []
            )
        )
        let engine = ParakeetTranscriptionEngine(
            model: .v3Multilingual,
            modelDirectory: URL(fileURLWithPath: "/tmp/model"),
            backend: backend
        )
        let chunk = AudioChunk(
            samples: Array(repeating: 0, count: 16_000),
            startTime: 0,
            source: .microphone
        )

        let segments = try await engine.transcribe(chunk)
        XCTAssertEqual(segments, [])
    }

    func testUnloadReleasesBackend() async {
        let backend = ParakeetBackendSpy(
            result: ParakeetBackendResult(
                text: "",
                confidence: 0,
                duration: 0,
                words: []
            )
        )
        let engine = ParakeetTranscriptionEngine(
            model: .v3Multilingual,
            modelDirectory: URL(fileURLWithPath: "/tmp/model"),
            backend: backend
        )

        await engine.unload()

        let didUnload = await backend.didUnload
        XCTAssertTrue(didUnload)
    }

    func testModelStoreReportsMissingModelWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let store = try ParakeetModelStore(rootDirectory: root)

        let availability = await store.availability(of: .v3Multilingual)

        XCTAssertEqual(availability, .notDownloaded)
    }

    func testProductionEngineRejectsMissingModelBeforeInference()
        async throws
    {
        #if arch(arm64)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let modelDirectory = root.appendingPathComponent(
            ParakeetModel.v3Multilingual.directoryName,
            isDirectory: true
        )
        let engine = ParakeetTranscriptionEngine(
            model: .v3Multilingual,
            modelDirectory: modelDirectory
        )

        do {
            try await engine.prepare()
            XCTFail("Expected a missing-model error.")
        } catch let error as ParakeetEngineError {
            XCTAssertEqual(
                error,
                .modelNotDownloaded(
                    model: .v3Multilingual,
                    directory: modelDirectory
                )
            )
        }
        #else
        throw XCTSkip("The production engine only runs on Apple Silicon.")
        #endif
    }
}

private actor ParakeetBackendSpy: ParakeetEngineBackend {
    private let result: ParakeetBackendResult
    private(set) var preparedModel: ParakeetModel?
    private(set) var transcribedSampleCount = 0
    private(set) var didUnload = false

    init(result: ParakeetBackendResult) {
        self.result = result
    }

    func prepare(
        model: ParakeetModel,
        directory: URL
    ) async throws {
        preparedModel = model
    }

    func transcribe(
        samples: [Float]
    ) async throws -> ParakeetBackendResult {
        transcribedSampleCount = samples.count
        return result
    }

    func unload() async {
        didUnload = true
    }
}
