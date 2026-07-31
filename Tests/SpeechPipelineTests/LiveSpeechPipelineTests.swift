import AudioCapture
import Foundation
@testable import SpeechPipeline
import XCTest

final class LiveSpeechPipelineTests: XCTestCase {
    func testSelectedEngineControlsLiveWindowGeometry() async throws {
        let engine = GeometryTranscriptionEngine(
            preferredWindowDuration: 4,
            preferredOverlap: 1
        )
        let configuration = LiveSpeechSegmentationConfiguration.default
            .usingWindowGeometry(from: engine)
        var processor = LiveSpeechSourceProcessor(
            source: .microphone,
            trackStartTime: 0,
            configuration: configuration
        )
        let detector = EnergyVoiceActivityDetector()
        let samplesPerSecond = Int(CanonicalAudioFormat.sampleRate)
        var windows: [LiveSpeechWindow] = []

        for second in 0..<9 {
            let result = try await processor.ingest(
                CanonicalAudioBlock(
                    source: .microphone,
                    firstSampleIndex: UInt64(second * samplesPerSecond),
                    samples: Array(
                        repeating: Float(0.8),
                        count: samplesPerSecond
                    )
                ),
                detector: detector
            )
            windows.append(contentsOf: result.windows)
        }
        let finish = try await processor.finish(detector: detector)
        windows.append(contentsOf: finish.windows)

        XCTAssertEqual(
            windows.map(\.firstSampleIndex),
            [0, 48_000, 96_000]
        )
        XCTAssertEqual(
            windows.map(\.overlapSampleCount),
            [0, 16_000, 16_000]
        )
        XCTAssertEqual(
            windows.map(\.samples.count),
            [64_000, 64_000, 48_000]
        )
    }

    func testContinuousSpeechUsesThirtySecondCeilingAndOverlappingWindows()
        async throws
    {
        let detector = EnergyVoiceActivityDetector()
        var processor = LiveSpeechSourceProcessor(
            source: .microphone,
            trackStartTime: 0,
            configuration: .default
        )
        var windows: [LiveSpeechWindow] = []
        var segmentCount = 0
        let samplesPerSecond = Int(CanonicalAudioFormat.sampleRate)
        let speech = Array(repeating: Float(0.8), count: samplesPerSecond)
        let silence = Array(repeating: Float.zero, count: samplesPerSecond)

        for second in 0..<32 {
            let result = try await processor.ingest(
                CanonicalAudioBlock(
                    source: .microphone,
                    firstSampleIndex: UInt64(second * samplesPerSecond),
                    samples: speech
                ),
                detector: detector
            )
            windows.append(contentsOf: result.windows)
            segmentCount += result.emittedSegmentCount
        }
        let silenceResult = try await processor.ingest(
            CanonicalAudioBlock(
                source: .microphone,
                firstSampleIndex: UInt64(32 * samplesPerSecond),
                samples: silence
            ),
            detector: detector
        )
        windows.append(contentsOf: silenceResult.windows)
        segmentCount += silenceResult.emittedSegmentCount
        let finishResult = try await processor.finish(
            detector: detector
        )
        windows.append(contentsOf: finishResult.windows)
        segmentCount += finishResult.emittedSegmentCount

        XCTAssertEqual(segmentCount, 2)
        let firstSegment = windows.filter {
            $0.speechSegmentIndex == 0
        }
        let secondSegment = windows.filter {
            $0.speechSegmentIndex == 1
        }
        XCTAssertEqual(firstSegment.count, 3)
        XCTAssertEqual(secondSegment.count, 1)
        XCTAssertEqual(
            firstSegment.map(\.firstSampleIndex),
            [0, 200_000, 400_000]
        )
        XCTAssertEqual(
            firstSegment.map(\.overlapSampleCount),
            [0, 24_000, 24_000]
        )
        XCTAssertEqual(
            firstSegment.map(\.isFinalWindow),
            [false, false, true]
        )
        XCTAssertEqual(secondSegment.map(\.isFinalWindow), [true])
        XCTAssertTrue(
            windows.allSatisfy {
                $0.samples.count <= 224_000
            }
        )
        XCTAssertEqual(secondSegment[0].firstSampleIndex, 480_000)
        XCTAssertLessThanOrEqual(
            secondSegment[0].samples.count,
            224_000
        )
    }

    func testLongActiveSpeechEmitsAPartialWindowBeforeBoundary()
        async throws
    {
        let detector = EnergyVoiceActivityDetector()
        var processor = LiveSpeechSourceProcessor(
            source: .microphone,
            trackStartTime: 0,
            configuration: .default
        )
        let samplesPerSecond = Int(CanonicalAudioFormat.sampleRate)
        let speech = Array(
            repeating: Float(0.8),
            count: samplesPerSecond
        )
        var windows: [LiveSpeechWindow] = []

        for second in 0..<16 {
            let result = try await processor.ingest(
                CanonicalAudioBlock(
                    source: .microphone,
                    firstSampleIndex:
                        UInt64(second * samplesPerSecond),
                    samples: speech
                ),
                detector: detector
            )
            windows.append(contentsOf: result.windows)
        }

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.samples.count, 224_000)
        XCTAssertEqual(windows.first?.isFinalWindow, false)
    }

    func testOneHourSilenceKeepsSourceBufferBounded() async throws {
        let detector = EnergyVoiceActivityDetector()
        var processor = LiveSpeechSourceProcessor(
            source: .system,
            trackStartTime: 0,
            configuration: .default
        )
        let samplesPerSecond = Int(CanonicalAudioFormat.sampleRate)
        let silence = Array(repeating: Float.zero, count: samplesPerSecond)
        var windowCount = 0

        for second in 0..<3_600 {
            let result = try await processor.ingest(
                CanonicalAudioBlock(
                    source: .system,
                    firstSampleIndex: UInt64(second * samplesPerSecond),
                    samples: silence
                ),
                detector: detector
            )
            windowCount += result.windows.count
        }
        let finishResult = try await processor.finish(
            detector: detector
        )
        windowCount += finishResult.windows.count

        XCTAssertEqual(windowCount, 0)
        XCTAssertLessThan(processor.peakBufferedSampleCount, 32_000)
        let processedFrames = await detector.processedFrameCount
        XCTAssertGreaterThan(processedFrames, 14_000)
    }

    func testPipelineDrainsBothSourcesAndRoundTripsWindowSpools()
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
        let detector = EnergyVoiceActivityDetector()
        let pipeline = try LiveSpeechPipeline(
            audioTransport: transport,
            detector: detector,
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
        let manifest = CaptureSessionManifest.dualTrack(
            microphoneStartTime: 0,
            systemStartTime: 2
        )
        try await pipeline.beginSession(
            in: directory,
            manifest: manifest
        )

        let speech = Array(repeating: Float(0.8), count: 16_000)
        let silence = Array(repeating: Float.zero, count: 16_000)
        let samples = speech + silence
        await transport.receive(
            CanonicalAudioBlock(
                source: .microphone,
                firstSampleIndex: 0,
                samples: samples
            )
        )
        await transport.receive(
            CanonicalAudioBlock(
                source: .system,
                firstSampleIndex: 0,
                samples: samples
            )
        )
        try await transport.finishProducing()
        try await pipeline.waitUntilFinished()

        let pipelineState = await pipeline.state
        let pipelineMetrics = await pipeline.metrics
        XCTAssertEqual(
            pipelineState,
            .completed(pendingWindowCount: 2)
        )
        XCTAssertEqual(pipelineMetrics.processedBlockCount, 2)
        XCTAssertEqual(pipelineMetrics.emittedSpeechSegmentCount, 2)
        XCTAssertEqual(pipelineMetrics.emittedWindowCount, 2)

        let microphoneWindow = try await pipeline.nextWindow(
            for: .microphone
        )
        let systemWindow = try await pipeline.nextWindow(for: .system)
        XCTAssertEqual(microphoneWindow?.source, .microphone)
        XCTAssertEqual(systemWindow?.source, .system)
        XCTAssertEqual(microphoneWindow?.startTime, 0)
        XCTAssertEqual(systemWindow?.startTime, 2)
        XCTAssertEqual(
            microphoneWindow?.samples,
            systemWindow?.samples
        )

        try await pipeline.cancelAndDiscard(finalState: .idle)
        try await transport.discardSpool(finalState: .drained)
    }

    func testRejectsInvalidSegmentationConfiguration() throws {
        let transport = try LiveAudioTransport()
        let detector = EnergyVoiceActivityDetector()
        XCTAssertThrowsError(
            try LiveSpeechPipeline(
                audioTransport: transport,
                detector: detector,
                configuration: LiveSpeechSegmentationConfiguration(
                    windowDuration: 14,
                    windowOverlap: 14
                ),
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
        )
    }
}

private actor GeometryTranscriptionEngine: TranscriptionEngine {
    nonisolated let identifier = "test.geometry"
    nonisolated let supportsStreaming = false
    nonisolated let requiresNetwork = false
    nonisolated let supportedLanguages = ["en"]
    nonisolated let preferredWindowDuration: TimeInterval
    nonisolated let preferredOverlap: TimeInterval

    init(
        preferredWindowDuration: TimeInterval,
        preferredOverlap: TimeInterval
    ) {
        self.preferredWindowDuration = preferredWindowDuration
        self.preferredOverlap = preferredOverlap
    }

    func prepare() async throws {}
    func transcribe(_ chunk: AudioChunk) async throws
        -> [TranscriptSegment]
    {
        []
    }
    func finish() async throws -> [TranscriptSegment] { [] }
    func unload() async {}
}

private actor EnergyVoiceActivityDetector:
    LiveVoiceActivityDetecting
{
    private(set) var processedFrameCount = 0

    func prepare() async throws {}

    func speechProbability(
        for samples: [Float],
        source: AudioSource
    ) async throws -> Float {
        processedFrameCount += 1
        let meanMagnitude = samples.reduce(Float.zero) {
            $0 + abs($1)
        } / Float(samples.count)
        return meanMagnitude > 0.5 ? 0.95 : 0.05
    }

    func unload() async {}
}
