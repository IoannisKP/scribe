import AudioCapture
import Foundation
@testable import SpeechPipeline
import XCTest

final class LiveAudioTransportTests: XCTestCase {
    func testRejectsUnsafeBackpressureThresholds() {
        XCTAssertThrowsError(
            try LiveAudioTransport(
                bufferingThreshold: 1,
                recoveredThreshold: 1
            )
        )
        XCTAssertThrowsError(
            try LiveAudioTransport(
                bufferingThreshold: .greatestFiniteMagnitude,
                recoveredThreshold: 0
            )
        )
        XCTAssertThrowsError(
            try LiveAudioTransport(
                bufferingThreshold:
                    Double(UInt64.max)
                    / CanonicalAudioFormat.sampleRate,
                recoveredThreshold: 0
            )
        )
        XCTAssertThrowsError(
            try LiveAudioTransport(
                bufferingThreshold: 0.000_001,
                recoveredThreshold: 0
            )
        )
    }

    func testFileSpoolRoundTripsIndependentSourceStreams() async throws {
        let directory = try makeTestDirectory()
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        let transport = try LiveAudioTransport(
            bufferingThreshold: 60,
            recoveredThreshold: 1
        )
        try await transport.beginSession(in: directory)

        let microphoneA = CanonicalAudioBlock(
            source: .microphone,
            firstSampleIndex: 0,
            samples: [0.1, 0.2, 0.3]
        )
        let microphoneB = CanonicalAudioBlock(
            source: .microphone,
            firstSampleIndex: 3,
            samples: [0.4, 0.5]
        )
        let system = CanonicalAudioBlock(
            source: .system,
            firstSampleIndex: 0,
            samples: [-0.1, -0.2]
        )
        await transport.receive(microphoneA)
        await transport.receive(system)
        await transport.receive(microphoneB)
        try await transport.finishProducing()

        let metricsBeforeRead = await transport.metrics
        XCTAssertEqual(metricsBeforeRead.acceptedBlockCount, 3)
        XCTAssertEqual(metricsBeforeRead.pendingBlockCount, 3)
        XCTAssertEqual(metricsBeforeRead.pendingSampleCount, 7)
        let recordingCompleteState = await transport.state
        XCTAssertEqual(
            recordingCompleteState,
            .recordingComplete(pendingSampleCount: 7)
        )

        let readMicrophoneA = try await transport.nextBlock(
            for: .microphone
        )
        let readMicrophoneB = try await transport.nextBlock(
            for: .microphone
        )
        let readSystem = try await transport.nextBlock(for: .system)
        let exhaustedMicrophone = try await transport.nextBlock(
            for: .microphone
        )
        let drainedState = await transport.state
        XCTAssertEqual(readMicrophoneA, microphoneA)
        XCTAssertEqual(readMicrophoneB, microphoneB)
        XCTAssertEqual(readSystem, system)
        XCTAssertNil(exhaustedMicrophone)
        XCTAssertEqual(drainedState, .drained)

        let metricsAfterRead = await transport.metrics
        XCTAssertEqual(metricsAfterRead.deliveredBlockCount, 3)
        XCTAssertEqual(metricsAfterRead.pendingBlockCount, 0)
        XCTAssertEqual(metricsAfterRead.pendingSampleCount, 0)

        try await transport.discardSpool(finalState: .drained)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory
                    .appendingPathComponent("LiveSpool")
                    .path
            )
        )
    }

    func testPollingBeforeFirstAppendDoesNotPinFileReaderAtEndOfFile()
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

        let beforeFirstAppend = try await transport.nextBlock(
            for: .microphone
        )
        XCTAssertNil(beforeFirstAppend)

        let block = CanonicalAudioBlock(
            source: .microphone,
            firstSampleIndex: 0,
            samples: [0.1, 0.2, 0.3]
        )
        await transport.receive(block)

        let delivered = try await transport.nextBlock(for: .microphone)
        XCTAssertEqual(delivered, block)

        try await transport.finishProducing()
        let state = await transport.state
        XCTAssertEqual(state, .drained)
        try await transport.discardSpool(finalState: .drained)
    }

    func testBackpressureStateUsesHysteresis() async throws {
        let directory = try makeTestDirectory()
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        let transport = LiveAudioTransport(
            bufferingThresholdSamples: 10,
            recoveredThresholdSamples: 2,
            storageFactory: { directory, source in
                MemoryLiveAudioSpoolStorage(
                    directory: directory,
                    source: source
                )
            }
        )
        try await transport.beginSession(in: directory)

        await transport.receive(
            CanonicalAudioBlock(
                source: .microphone,
                firstSampleIndex: 0,
                samples: Array(repeating: 0.1, count: 5)
            )
        )
        await transport.receive(
            CanonicalAudioBlock(
                source: .microphone,
                firstSampleIndex: 5,
                samples: Array(repeating: 0.2, count: 5)
            )
        )
        let bufferingState = await transport.state
        XCTAssertEqual(
            bufferingState,
            .bufferingToDisk(pendingSampleCount: 10)
        )

        _ = try await transport.nextBlock(for: .microphone)
        let catchingUpState = await transport.state
        XCTAssertEqual(
            catchingUpState,
            .catchingUp(pendingSampleCount: 5)
        )
        _ = try await transport.nextBlock(for: .microphone)
        let keepingUpState = await transport.state
        XCTAssertEqual(
            keepingUpState,
            .keepingUp(pendingSampleCount: 0)
        )

        try await transport.finishProducing()
        let drainedState = await transport.state
        XCTAssertEqual(drainedState, .drained)
        try await transport.discardSpool(finalState: .drained)
    }

    func testNoncontiguousInputFailsClosedWithoutThrowingFromSink() async throws {
        let directory = try makeTestDirectory()
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        let transport = LiveAudioTransport(
            bufferingThresholdSamples: 100,
            recoveredThresholdSamples: 10,
            storageFactory: { directory, source in
                MemoryLiveAudioSpoolStorage(
                    directory: directory,
                    source: source
                )
            }
        )
        try await transport.beginSession(in: directory)

        await transport.receive(
            CanonicalAudioBlock(
                source: .system,
                firstSampleIndex: 0,
                samples: [0.1, 0.2]
            )
        )
        await transport.receive(
            CanonicalAudioBlock(
                source: .system,
                firstSampleIndex: 3,
                samples: [0.3]
            )
        )

        guard case let .failed(message) = await transport.state else {
            return XCTFail("Expected the live transport to fail.")
        }
        XCTAssertTrue(message.contains("skipped from sample 2 to 3"))
        let metrics = await transport.metrics
        XCTAssertEqual(metrics.acceptedBlockCount, 1)

        try await transport.finishProducing()
        guard case .failed = await transport.state else {
            return XCTFail("Finishing storage must preserve the feed failure.")
        }
        try await transport.discardSpool(finalState: .idle)
    }

    func testOneHourTwoSourceFeedKeepsOnlyOneBlockInMemory() async throws {
        let directory = try makeTestDirectory()
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        let transport = LiveAudioTransport(
            bufferingThresholdSamples: 160_000,
            recoveredThresholdSamples: 32_000,
            storageFactory: { directory, source in
                CountingLiveAudioSpoolStorage(
                    directory: directory,
                    source: source
                )
            }
        )
        try await transport.beginSession(in: directory)

        let samplesPerSecond = Int(CanonicalAudioFormat.sampleRate)
        let oneSecond = Array(repeating: Float.zero, count: samplesPerSecond)
        for second in 0..<3_600 {
            let firstSampleIndex = UInt64(second * samplesPerSecond)
            await transport.receive(
                CanonicalAudioBlock(
                    source: .microphone,
                    firstSampleIndex: firstSampleIndex,
                    samples: oneSecond
                )
            )
            await transport.receive(
                CanonicalAudioBlock(
                    source: .system,
                    firstSampleIndex: firstSampleIndex,
                    samples: oneSecond
                )
            )
        }
        try await transport.finishProducing()

        let metrics = await transport.metrics
        let expectedSamples = UInt64(
            2 * 3_600 * samplesPerSecond
        )
        XCTAssertEqual(metrics.acceptedBlockCount, 7_200)
        XCTAssertEqual(metrics.pendingBlockCount, 7_200)
        XCTAssertEqual(metrics.pendingSampleCount, expectedSamples)
        XCTAssertEqual(metrics.peakPendingSampleCount, expectedSamples)
        XCTAssertEqual(
            metrics.peakInMemorySampleCount,
            samplesPerSecond
        )
        let recordingCompleteState = await transport.state
        XCTAssertEqual(
            recordingCompleteState,
            .recordingComplete(pendingSampleCount: expectedSamples)
        )

        try await transport.discardSpool(finalState: .drained)
    }
}

/// Tests inject this mutable storage only behind `LiveAudioTransport`'s actor
/// boundary, so its unchecked conformance preserves the production invariant:
/// one serial caller owns every storage instance.
private final class MemoryLiveAudioSpoolStorage:
    LiveAudioSpoolStorage,
    @unchecked Sendable
{
    let source: AudioSource
    let url: URL

    private var blocks: [CanonicalAudioBlock] = []
    private var readIndex = 0

    init(directory: URL, source: AudioSource) {
        self.source = source
        self.url = directory.appendingPathComponent(
            "\(source.rawValue).memory"
        )
    }

    func append(_ block: CanonicalAudioBlock) throws {
        blocks.append(block)
    }

    func next() throws -> CanonicalAudioBlock? {
        guard readIndex < blocks.count else {
            return nil
        }
        defer {
            readIndex += 1
        }
        return blocks[readIndex]
    }

    func finishWriting() throws {}

    func discard() throws {
        blocks.removeAll(keepingCapacity: false)
        readIndex = 0
    }
}

/// A virtual spool used by the one-hour soak. It deliberately retains no sample
/// arrays, allowing the test to verify transport memory independently of disk
/// capacity or filesystem speed.
private final class CountingLiveAudioSpoolStorage:
    LiveAudioSpoolStorage,
    @unchecked Sendable
{
    let source: AudioSource
    let url: URL

    init(directory: URL, source: AudioSource) {
        self.source = source
        self.url = directory.appendingPathComponent(
            "\(source.rawValue).counting"
        )
    }

    func append(_ block: CanonicalAudioBlock) throws {}

    func next() throws -> CanonicalAudioBlock? {
        nil
    }

    func finishWriting() throws {}

    func discard() throws {}
}
