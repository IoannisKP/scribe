import AudioCapture
import Foundation
import SpeechPipeline
import XCTest

final class BatchTranscriptionPipelineTests: XCTestCase {
    func testInterleavesTrackChunksBySharedSessionTimeline() async throws {
        let directory = try makeTestDirectory()
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Unable to remove test directory: \(error)")
            }
        }
        try await writeDualTrackSession(
            directory: directory,
            microphoneSamples: Array(repeating: 0.25, count: 8),
            systemSamples: Array(repeating: -0.25, count: 8),
            systemStartTime: 2.0 / CanonicalAudioFormat.sampleRate
        )

        let engine = LifecycleMockEngine(
            preferredWindowDuration:
                4.0 / CanonicalAudioFormat.sampleRate
        )
        let pipeline = try BatchTranscriptionPipeline(engine: engine)
        let segments = try await pipeline.transcribeSession(at: directory)

        XCTAssertEqual(
            segments.map(\.source),
            [.microphone, .system, .microphone, .system]
        )
        let expectedStartTimes = [
            0,
            2.0 / CanonicalAudioFormat.sampleRate,
            4.0 / CanonicalAudioFormat.sampleRate,
            6.0 / CanonicalAudioFormat.sampleRate
        ]
        XCTAssertEqual(segments.count, expectedStartTimes.count)
        for (segment, expected) in zip(segments, expectedStartTimes) {
            XCTAssertEqual(
                segment.startTime,
                expected,
                accuracy: 0.000_001
            )
        }

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.prepareCount, 1)
        XCTAssertEqual(snapshot.finishCount, 1)
        XCTAssertEqual(snapshot.unloadCount, 1)
        XCTAssertEqual(snapshot.processedChunkCount, 4)
        let state = await pipeline.state
        XCTAssertEqual(state, .finished(segmentCount: 4))
    }

    func testSourceMismatchFailsAndStillUnloadsEngine() async throws {
        let directory = try makeTestDirectory()
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Unable to remove test directory: \(error)")
            }
        }
        try await writeDualTrackSession(
            directory: directory,
            microphoneSamples: [0.1, 0.2, 0.3, 0.4],
            systemSamples: [-0.1, -0.2, -0.3, -0.4],
            systemStartTime: 0
        )

        let engine = LifecycleMockEngine(
            returnsWrongSource: true,
            preferredWindowDuration: 1
        )
        let pipeline = try BatchTranscriptionPipeline(engine: engine)

        do {
            _ = try await pipeline.transcribeSession(at: directory)
            XCTFail("Expected mismatched attribution to fail.")
        } catch {
            XCTAssertEqual(
                error as? SpeechPipelineError,
                .segmentSourceMismatch(
                    expected: .microphone,
                    actual: .system
                )
            )
        }

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.prepareCount, 1)
        XCTAssertEqual(snapshot.finishCount, 0)
        XCTAssertEqual(snapshot.unloadCount, 1)
        if case .failed = await pipeline.state {
            // Expected terminal state.
        } else {
            XCTFail("Expected a failed pipeline state.")
        }
    }

    func testTimelineMergeHasDeterministicTieBreaking() {
        let segments = [
            TranscriptSegment(
                text: "system",
                startTime: 2,
                endTime: 3,
                source: .system
            ),
            TranscriptSegment(
                text: "microphone",
                startTime: 2,
                endTime: 3,
                source: .microphone
            ),
            TranscriptSegment(
                text: "first",
                startTime: 1,
                endTime: 1.5,
                source: .system
            )
        ]

        XCTAssertEqual(
            TranscriptTimeline.merge(segments).map(\.text),
            ["first", "microphone", "system"]
        )
    }

    private func writeDualTrackSession(
        directory: URL,
        microphoneSamples: [Float],
        systemSamples: [Float],
        systemStartTime: TimeInterval
    ) async throws {
        try await writeCanonicalWAV(
            samples: microphoneSamples,
            to: directory.appendingPathComponent("microphone.wav")
        )
        try await writeCanonicalWAV(
            samples: systemSamples,
            to: directory.appendingPathComponent("system.wav")
        )
        try CaptureSessionManifest.dualTrack(
            microphoneStartTime: 0,
            systemStartTime: systemStartTime
        ).write(to: directory)
    }
}

private actor LifecycleMockEngine: TranscriptionEngine {
    struct Snapshot: Equatable, Sendable {
        let prepareCount: Int
        let processedChunkCount: Int
        let finishCount: Int
        let unloadCount: Int
    }

    nonisolated let identifier = "test.lifecycle"
    nonisolated let supportsStreaming = false
    nonisolated let requiresNetwork = false
    nonisolated let supportedLanguages = ["en"]
    nonisolated let preferredWindowDuration: TimeInterval
    nonisolated let preferredOverlap: TimeInterval

    private let returnsWrongSource: Bool
    private var prepareCount = 0
    private var processedChunkCount = 0
    private var finishCount = 0
    private var unloadCount = 0

    init(
        returnsWrongSource: Bool = false,
        preferredWindowDuration: TimeInterval = 14,
        preferredOverlap: TimeInterval = 1.5
    ) {
        self.returnsWrongSource = returnsWrongSource
        self.preferredWindowDuration = preferredWindowDuration
        self.preferredOverlap = preferredOverlap
    }

    func prepare() {
        prepareCount += 1
    }

    func transcribe(_ chunk: AudioChunk) -> [TranscriptSegment] {
        processedChunkCount += 1
        let source: AudioSource
        if returnsWrongSource {
            source = chunk.source == .microphone ? .system : .microphone
        } else {
            source = chunk.source
        }
        return [
            TranscriptSegment(
                text: "\(chunk.source.rawValue)-\(processedChunkCount)",
                startTime: chunk.startTime,
                endTime: chunk.endTime,
                source: source,
                confidence: 1
            )
        ]
    }

    func finish() -> [TranscriptSegment] {
        finishCount += 1
        return []
    }

    func unload() {
        unloadCount += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(
            prepareCount: prepareCount,
            processedChunkCount: processedChunkCount,
            finishCount: finishCount,
            unloadCount: unloadCount
        )
    }
}
