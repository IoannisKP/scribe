import AudioCapture
import Foundation
@testable import SpeechPipeline
import XCTest

final class LiveTranscriptionPipelineTests: XCTestCase {
    func testPartialRowIsReplacedByFinalDeduplicatedRow()
        async throws
    {
        let provider = ControlledWindowProvider()
        let engine = SeamTranscriptionEngine()
        let pipeline = try LiveTranscriptionPipeline(
            windowProvider: provider,
            engine: engine
        )
        await provider.append(
            window(
                source: .microphone,
                segmentIndex: 0,
                firstSampleIndex: 0,
                isFinal: false
            )
        )
        try await pipeline.beginSession()

        try await waitUntil {
            await pipeline.metrics.processedWindowCount == 1
        }
        let partialRows = await pipeline.rows
        XCTAssertEqual(partialRows.count, 1)
        XCTAssertEqual(
            partialRows.first?.segment.text,
            "hello new world"
        )
        XCTAssertEqual(partialRows.first?.isFinal, false)

        await provider.append(
            window(
                source: .microphone,
                segmentIndex: 0,
                firstSampleIndex: 12_000,
                isFinal: true
            )
        )
        await provider.finish()
        try await pipeline.waitUntilFinished()

        let finalRows = await pipeline.rows
        let finalState = await pipeline.state
        XCTAssertEqual(finalRows.count, 1)
        XCTAssertEqual(
            finalRows.first?.segment.text,
            "hello new world today"
        )
        XCTAssertEqual(finalRows.first?.isFinal, true)
        XCTAssertEqual(finalState, .completed(finalRowCount: 1))
        let unloadCount = await engine.unloadCount
        XCTAssertEqual(unloadCount, 1)
    }

    func testLiveTimedSeamRemovesCorruptedBoundaryDuplicate()
        async throws
    {
        let provider = ControlledWindowProvider()
        let pipeline = try LiveTranscriptionPipeline(
            windowProvider: provider,
            engine: CorruptedSeamTranscriptionEngine()
        )
        await provider.append(
            window(
                source: .microphone,
                segmentIndex: 0,
                firstSampleIndex: 0,
                isFinal: false
            )
        )
        try await pipeline.beginSession()
        try await waitUntil {
            await pipeline.metrics.processedWindowCount == 1
        }

        await provider.append(
            window(
                source: .microphone,
                segmentIndex: 0,
                firstSampleIndex: 12_000,
                isFinal: true
            )
        )
        await provider.finish()
        try await pipeline.waitUntilFinished()

        let rows = await pipeline.rows
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(
            rows.first?.segment.text,
            "we test offline transition workflow"
        )
        XCTAssertEqual(
            rows.first?.segment.words?.map(\.text),
            ["we", "test", "offline", "transition", "workflow"]
        )
        XCTAssertEqual(rows.first?.isFinal, true)
    }

    func testForcedContinuationRewritesFinalizedBoundaryWithCurrentText()
        async throws
    {
        let provider = ControlledWindowProvider()
        let pipeline = try LiveTranscriptionPipeline(
            windowProvider: provider,
            engine: ForcedContinuationTranscriptionEngine()
        )
        await provider.append(
            window(
                source: .microphone,
                segmentIndex: 0,
                firstSampleIndex: 0,
                isFinal: true
            )
        )
        try await pipeline.beginSession()
        try await waitUntil {
            await pipeline.metrics.processedWindowCount == 1
        }
        let displayedFinalRows = await pipeline.rows
        XCTAssertEqual(
            displayedFinalRows.first?.segment.text,
            "clear time step camps"
        )
        XCTAssertEqual(displayedFinalRows.first?.isFinal, true)

        await provider.append(
            window(
                source: .microphone,
                segmentIndex: 1,
                firstSampleIndex: 12_000,
                isFinal: true
            )
        )
        await provider.finish()
        try await pipeline.waitUntilFinished()

        let rows = await pipeline.rows
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].id, displayedFinalRows[0].id)
        XCTAssertEqual(rows[0].segment.text, "clear")
        XCTAssertEqual(
            rows[1].segment.text,
            "timestamps help everyone"
        )
        XCTAssertTrue(rows.allSatisfy(\.isFinal))
        XCTAssertNotEqual(
            rows[0].segment.words?.last?.text,
            rows[1].segment.words?.first?.text
        )
    }

    func testBackpressureUsesDiskBufferingHysteresis() {
        var tracker = LiveTranscriptionBackpressureTracker(
            configuration: LiveTranscriptionBackpressureConfiguration(
                bufferingWindowCount: 3,
                recoveredWindowCount: 1
            )
        )

        XCTAssertEqual(
            tracker.update(pendingWindowCount: 2),
            .keepingUp
        )
        XCTAssertEqual(
            tracker.update(pendingWindowCount: 3),
            .bufferingToDisk
        )
        XCTAssertEqual(
            tracker.update(pendingWindowCount: 2),
            .catchingUp
        )
        XCTAssertEqual(
            tracker.update(pendingWindowCount: 1),
            .keepingUp
        )
    }

    func testEqualLiveStartsOrderMicrophoneBeforeShorterSystemRow()
        async throws
    {
        let provider = ControlledWindowProvider()
        let pipeline = try LiveTranscriptionPipeline(
            windowProvider: provider,
            engine: TieOrderingTranscriptionEngine()
        )
        await provider.append(
            window(
                source: .system,
                segmentIndex: 0,
                firstSampleIndex: 0,
                isFinal: true
            )
        )
        await provider.append(
            window(
                source: .microphone,
                segmentIndex: 0,
                firstSampleIndex: 0,
                isFinal: true
            )
        )
        await provider.finish()

        try await pipeline.beginSession()
        try await pipeline.waitUntilFinished()

        let rows = await pipeline.rows
        XCTAssertEqual(rows.map(\.segment.source), [.microphone, .system])
        XCTAssertEqual(rows.map(\.segment.startTime), [0, 0])
        XCTAssertGreaterThan(
            rows[0].segment.endTime,
            rows[1].segment.endTime
        )
    }

    func testUnorderedTimedWordsSetChronologicalRowBoundsAndOrder()
        async throws
    {
        let provider = ControlledWindowProvider()
        let pipeline = try LiveTranscriptionPipeline(
            windowProvider: provider,
            engine: UnorderedWordsTranscriptionEngine()
        )
        await provider.append(
            window(
                source: .microphone,
                segmentIndex: 0,
                firstSampleIndex: 0,
                isFinal: true
            )
        )
        await provider.append(
            window(
                source: .system,
                segmentIndex: 0,
                firstSampleIndex: 0,
                isFinal: true
            )
        )
        await provider.finish()

        try await pipeline.beginSession()
        try await pipeline.waitUntilFinished()

        let rows = await pipeline.rows
        XCTAssertEqual(rows.map(\.segment.source), [.system, .microphone])
        XCTAssertEqual(rows.map(\.segment.startTime), [0.1, 0.5])
        XCTAssertEqual(rows[0].segment.endTime, 0.9)
        XCTAssertEqual(
            rows[0].segment.words?.map(\.text),
            ["early", "late"]
        )
    }

    func testVirtualOneHourTwoSourceSoakKeepsInFlightAudioBounded()
        async throws
    {
        let provider = VirtualHourWindowProvider(
            windowCountPerSource: 120,
            samplesPerWindow: 160
        )
        let engine = SoakTranscriptionEngine()
        let pipeline = try LiveTranscriptionPipeline(
            windowProvider: provider,
            engine: engine
        )

        try await pipeline.beginSession()
        try await pipeline.waitUntilFinished()

        let metrics = await pipeline.metrics
        let rows = await pipeline.rows
        XCTAssertEqual(metrics.processedWindowCount, 240)
        XCTAssertEqual(metrics.peakInFlightSampleCount, 160)
        XCTAssertEqual(metrics.peakActivePartialRowCount, 0)
        XCTAssertEqual(metrics.finalRowCount, 240)
        XCTAssertEqual(rows.count, 240)
        XCTAssertTrue(rows.allSatisfy(\.isFinal))
        XCTAssertGreaterThanOrEqual(
            rows.last?.segment.startTime ?? 0,
            3_570
        )
    }

    func testRawTransportVADSpoolAndLiveASRCompleteTogether()
        async throws
    {
        let directory = try makeTestDirectory()
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        let transport = try LiveAudioTransport(
            bufferingThreshold: 60,
            recoveredThreshold: 1
        )
        try await transport.beginSession(in: directory)
        let speechPipeline = try LiveSpeechPipeline(
            audioTransport: transport,
            detector: TestEnergyVAD(),
            storageFactory: {
                directory,
                source,
                trackStartTime in
                try FileLiveSpeechWindowSpoolStorage(
                    directory: directory,
                    source: source,
                    trackStartTime: trackStartTime
                )
            }
        )
        try await speechPipeline.beginSession(
            in: directory,
            manifest: .dualTrack(
                microphoneStartTime: 0,
                systemStartTime: 0.25
            )
        )
        let transcriptionPipeline =
            try LiveTranscriptionPipeline(
                speechPipeline: speechPipeline,
                engine: SoakTranscriptionEngine()
            )
        try await transcriptionPipeline.beginSession()
        // Exercise the production case where both consumers poll before the
        // first capture block reaches either append-only file.
        try await Task.sleep(for: .milliseconds(60))

        let speech = Array(repeating: Float(0.8), count: 16_000)
        let silence = Array(repeating: Float.zero, count: 16_000)
        let samples = speech + silence
        for source in AudioSource.allCases {
            await transport.receive(
                CanonicalAudioBlock(
                    source: source,
                    firstSampleIndex: 0,
                    samples: samples
                )
            )
        }
        try await transport.finishProducing()
        try await speechPipeline.waitUntilFinished()
        try await transcriptionPipeline.waitUntilFinished()

        let rows = await transcriptionPipeline.rows
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy(\.isFinal))
        XCTAssertEqual(
            rows.map(\.segment.source),
            [.microphone, .system]
        )
        XCTAssertEqual(rows[0].segment.startTime, 0)
        XCTAssertEqual(rows[1].segment.startTime, 0.25)

        await transcriptionPipeline.shutdown(finalState: .idle)
        try await speechPipeline.cancelAndDiscard(
            finalState: .idle
        )
        try await transport.discardSpool(finalState: .drained)
    }

    func testRejectsSourceMismatch() async throws {
        let provider = ControlledWindowProvider()
        let engine = WrongSourceTranscriptionEngine()
        let pipeline = try LiveTranscriptionPipeline(
            windowProvider: provider,
            engine: engine
        )
        await provider.append(
            window(
                source: .microphone,
                segmentIndex: 0,
                firstSampleIndex: 0,
                isFinal: true
            )
        )
        await provider.finish()

        try await pipeline.beginSession()
        do {
            try await pipeline.waitUntilFinished()
            XCTFail("Expected the source mismatch to fail.")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "system output while processing the microphone"
                )
            )
        }
        if case .failed = await pipeline.state {
            // Expected.
        } else {
            XCTFail("Expected a failed pipeline state.")
        }
    }

    private func window(
        source: AudioSource,
        segmentIndex: UInt64,
        firstSampleIndex: UInt64,
        isFinal: Bool
    ) -> LiveSpeechWindow {
        LiveSpeechWindow(
            source: source,
            speechSegmentIndex: segmentIndex,
            firstSampleIndex: firstSampleIndex,
            trackStartTime: 0,
            overlapSampleCount: firstSampleIndex == 0 ? 0 : 4_000,
            isFinalWindow: isFinal,
            samples: Array(repeating: 0.5, count: 16_000)
        )
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<100 {
            if await predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for live pipeline progress.")
    }
}

private actor ControlledWindowProvider: LiveSpeechWindowProviding {
    private var windows:
        [AudioSource: [LiveSpeechWindow]] = [:]
    private var isFinished = false

    func append(_ window: LiveSpeechWindow) {
        windows[window.source, default: []].append(window)
    }

    func finish() {
        isFinished = true
    }

    func nextWindow(
        for source: AudioSource
    ) async throws -> LiveSpeechWindow? {
        guard
            var sourceWindows = windows[source],
            !sourceWindows.isEmpty
        else {
            return nil
        }
        let next = sourceWindows.removeFirst()
        windows[source] = sourceWindows
        return next
    }

    func pipelineState() async -> LiveSpeechPipelineState {
        let pending = windows.values.reduce(0) {
            $0 + UInt64($1.count)
        }
        return isFinished
            ? .completed(pendingWindowCount: pending)
            : .running(pendingWindowCount: pending)
    }
}

private actor VirtualHourWindowProvider:
    LiveSpeechWindowProviding
{
    private let windowCountPerSource: UInt64
    private let samplesPerWindow: Int
    private var delivered:
        [AudioSource: UInt64] = [.microphone: 0, .system: 0]

    init(windowCountPerSource: UInt64, samplesPerWindow: Int) {
        self.windowCountPerSource = windowCountPerSource
        self.samplesPerWindow = samplesPerWindow
    }

    func nextWindow(
        for source: AudioSource
    ) async throws -> LiveSpeechWindow? {
        let index = delivered[source] ?? 0
        guard index < windowCountPerSource else {
            return nil
        }
        delivered[source] = index + 1
        let startTime = Double(index) * 30
            + (source == .system ? 0.1 : 0)
        return LiveSpeechWindow(
            source: source,
            speechSegmentIndex: index,
            firstSampleIndex: UInt64(
                startTime * CanonicalAudioFormat.sampleRate
            ),
            trackStartTime: 0,
            overlapSampleCount: 0,
            isFinalWindow: true,
            samples: Array(
                repeating: source == .microphone ? 0.25 : 0.5,
                count: samplesPerWindow
            )
        )
    }

    func pipelineState() async -> LiveSpeechPipelineState {
        let deliveredCount = delivered.values.reduce(0, +)
        let total = windowCountPerSource
            * UInt64(AudioSource.allCases.count)
        return .completed(
            pendingWindowCount: total - deliveredCount
        )
    }
}

private actor TieOrderingTranscriptionEngine: TranscriptionEngine {
    nonisolated let identifier = "test.tie-ordering"
    nonisolated let supportsStreaming = false
    nonisolated let requiresNetwork = false
    nonisolated let supportedLanguages = ["en"]

    func prepare() async throws {}

    func transcribe(_ chunk: AudioChunk) async throws
        -> [TranscriptSegment]
    {
        [
            TranscriptSegment(
                text: chunk.source.rawValue,
                startTime: chunk.startTime,
                endTime: chunk.startTime
                    + (chunk.source == .microphone ? 1 : 0.25),
                source: chunk.source
            )
        ]
    }

    func finish() async throws -> [TranscriptSegment] { [] }
    func unload() async {}
}

private actor UnorderedWordsTranscriptionEngine:
    TranscriptionEngine
{
    nonisolated let identifier = "test.unordered-words"
    nonisolated let supportsStreaming = false
    nonisolated let requiresNetwork = false
    nonisolated let supportedLanguages = ["en"]

    func prepare() async throws {}

    func transcribe(
        _ chunk: AudioChunk
    ) async throws -> [TranscriptSegment] {
        if chunk.source == .system {
            return [
                TranscriptSegment(
                    text: "early late",
                    startTime: 0.8,
                    endTime: 0.9,
                    source: .system,
                    words: [
                        WordTiming(
                            text: "late",
                            startTime: 0.8,
                            endTime: 0.9
                        ),
                        WordTiming(
                            text: "early",
                            startTime: 0.1,
                            endTime: 0.2
                        ),
                    ]
                )
            ]
        }
        return [
            TranscriptSegment(
                text: "middle end",
                startTime: 0.7,
                endTime: 0.8,
                source: .microphone,
                words: [
                    WordTiming(
                        text: "end",
                        startTime: 0.7,
                        endTime: 0.8
                    ),
                    WordTiming(
                        text: "middle",
                        startTime: 0.5,
                        endTime: 0.6
                    ),
                ]
            )
        ]
    }

    func finish() async throws -> [TranscriptSegment] { [] }
    func unload() async {}
}

private actor SeamTranscriptionEngine: TranscriptionEngine {
    nonisolated let identifier = "test.seam"
    nonisolated let supportsStreaming = false
    nonisolated let requiresNetwork = false
    nonisolated let supportedLanguages = ["en"]
    private(set) var unloadCount = 0

    func prepare() async throws {}

    func transcribe(
        _ chunk: AudioChunk
    ) async throws -> [TranscriptSegment] {
        if chunk.startTime < 0.5 {
            return [
                TranscriptSegment(
                    text: "hello new world",
                    startTime: 0,
                    endTime: 1,
                    source: chunk.source,
                    words: [
                        WordTiming(text: "hello", startTime: 0, endTime: 0.5),
                        WordTiming(text: "new", startTime: 0.6, endTime: 0.8),
                        WordTiming(text: "world", startTime: 0.8, endTime: 1),
                    ]
                )
            ]
        }
        return [
            TranscriptSegment(
                text: "new world today",
                startTime: 0.75,
                endTime: 1.5,
                source: chunk.source,
                words: [
                    WordTiming(text: "new", startTime: 0.75, endTime: 0.85),
                    WordTiming(text: "world", startTime: 0.85, endTime: 1),
                    WordTiming(text: "today", startTime: 1.2, endTime: 1.5),
                ]
            )
        ]
    }

    func finish() async throws -> [TranscriptSegment] {
        []
    }

    func unload() async {
        unloadCount += 1
    }
}

private actor CorruptedSeamTranscriptionEngine:
    TranscriptionEngine
{
    nonisolated let identifier = "test.corrupted-seam"
    nonisolated let supportsStreaming = false
    nonisolated let requiresNetwork = false
    nonisolated let supportedLanguages = ["en"]

    func prepare() async throws {}

    func transcribe(
        _ chunk: AudioChunk
    ) async throws -> [TranscriptSegment] {
        if chunk.startTime < 0.5 {
            return [
                TranscriptSegment(
                    text: "we test offline transition",
                    startTime: 0,
                    endTime: 1,
                    source: chunk.source,
                    words: [
                        WordTiming(text: "we", startTime: 0, endTime: 0.2),
                        WordTiming(text: "test", startTime: 0.25, endTime: 0.5),
                        WordTiming(text: "offline", startTime: 0.5, endTime: 0.75),
                        WordTiming(text: "transition", startTime: 0.75, endTime: 1),
                    ]
                )
            ]
        }
        return [
            TranscriptSegment(
                text: "test offline transcription workflow",
                startTime: 0.75,
                endTime: 1.5,
                source: chunk.source,
                words: [
                    WordTiming(text: "test", startTime: 0.75, endTime: 0.82),
                    WordTiming(text: "offline", startTime: 0.82, endTime: 0.9),
                    WordTiming(text: "transcription", startTime: 0.9, endTime: 1),
                    WordTiming(text: "workflow", startTime: 1.2, endTime: 1.5),
                ]
            )
        ]
    }

    func finish() async throws -> [TranscriptSegment] { [] }
    func unload() async {}
}

private actor ForcedContinuationTranscriptionEngine:
    TranscriptionEngine
{
    nonisolated let identifier = "test.forced-continuation"
    nonisolated let supportsStreaming = false
    nonisolated let requiresNetwork = false
    nonisolated let supportedLanguages = ["en"]

    func prepare() async throws {}

    func transcribe(
        _ chunk: AudioChunk
    ) async throws -> [TranscriptSegment] {
        if chunk.startTime < 0.5 {
            return [
                TranscriptSegment(
                    text: "clear time step camps",
                    startTime: 0,
                    endTime: 1,
                    source: chunk.source,
                    words: [
                        WordTiming(
                            text: "clear",
                            startTime: 0,
                            endTime: 0.5
                        ),
                        WordTiming(
                            text: "time",
                            startTime: 0.76,
                            endTime: 0.80
                        ),
                        WordTiming(
                            text: "step",
                            startTime: 0.80,
                            endTime: 0.90
                        ),
                        WordTiming(
                            text: "camps",
                            startTime: 0.90,
                            endTime: 1
                        ),
                    ]
                )
            ]
        }
        return [
            TranscriptSegment(
                text: "timestamps help everyone",
                startTime: 0.75,
                endTime: 1.70,
                source: chunk.source,
                words: [
                    WordTiming(
                        text: "timestamps",
                        startTime: 0.75,
                        endTime: 1.05
                    ),
                    WordTiming(
                        text: "help",
                        startTime: 1.10,
                        endTime: 1.35
                    ),
                    WordTiming(
                        text: "everyone",
                        startTime: 1.40,
                        endTime: 1.70
                    ),
                ]
            )
        ]
    }

    func finish() async throws -> [TranscriptSegment] { [] }
    func unload() async {}
}

private actor SoakTranscriptionEngine: TranscriptionEngine {
    nonisolated let identifier = "test.soak"
    nonisolated let supportsStreaming = false
    nonisolated let requiresNetwork = false
    nonisolated let supportedLanguages = ["en"]

    func prepare() async throws {}

    func transcribe(
        _ chunk: AudioChunk
    ) async throws -> [TranscriptSegment] {
        [
            TranscriptSegment(
                text: "word",
                startTime: chunk.startTime,
                endTime: chunk.endTime,
                source: chunk.source
            )
        ]
    }

    func finish() async throws -> [TranscriptSegment] {
        []
    }

    func unload() async {}
}

private actor WrongSourceTranscriptionEngine:
    TranscriptionEngine
{
    nonisolated let identifier = "test.wrong-source"
    nonisolated let supportsStreaming = false
    nonisolated let requiresNetwork = false
    nonisolated let supportedLanguages = ["en"]

    func prepare() async throws {}

    func transcribe(
        _ chunk: AudioChunk
    ) async throws -> [TranscriptSegment] {
        [
            TranscriptSegment(
                text: "wrong",
                startTime: chunk.startTime,
                endTime: chunk.endTime,
                source: .system
            )
        ]
    }

    func finish() async throws -> [TranscriptSegment] {
        []
    }

    func unload() async {}
}

private actor TestEnergyVAD: LiveVoiceActivityDetecting {
    func prepare() async throws {}

    func speechProbability(
        for samples: [Float],
        source: AudioSource
    ) async throws -> Float {
        let meanMagnitude = samples.reduce(Float.zero) {
            $0 + abs($1)
        } / Float(samples.count)
        return meanMagnitude > 0.5 ? 0.95 : 0.05
    }

    func unload() async {}
}
