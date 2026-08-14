@testable import AudioCapture
import CoreAudioTypes
import Foundation
import XCTest

final class CanonicalAudioBlockTests: XCTestCase {
    func testCanonicalTimingUsesSourceRelativeSampleIndices() {
        let block = CanonicalAudioBlock(
            source: .system,
            firstSampleIndex: 24_000,
            samples: Array(repeating: 0.25, count: 8_000)
        )

        XCTAssertEqual(block.startTime, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(block.duration, 0.5, accuracy: 0.000_001)
    }

    func testFileConsumerCommitsContiguousCanonicalBlocks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ScribeCanonicalBlockTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let outputURL = directory.appendingPathComponent("microphone.wav")
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }

        let ringBuffer = try FloatRingBuffer(capacity: 8_192)
        let sink = CanonicalBlockCollector()
        let consumer = try CanonicalAudioFileConsumer(
            source: .microphone,
            ringBuffer: ringBuffer,
            inputSampleRate: CanonicalAudioFormat.sampleRate,
            outputURL: outputURL,
            liveSink: sink
        )
        let firstInput = (0..<2_048).map {
            Float($0) / 4_096
        }
        let secondInput = (0..<1_024).map {
            -Float($0) / 2_048
        }

        XCTAssertEqual(write(firstInput, to: ringBuffer), firstInput.count)
        let firstProcessedCount = try await consumer.processAvailable()
        XCTAssertEqual(firstProcessedCount, firstInput.count)
        XCTAssertEqual(write(secondInput, to: ringBuffer), secondInput.count)
        let secondProcessedCount = try await consumer.processAvailable()
        XCTAssertEqual(secondProcessedCount, secondInput.count)
        try await consumer.finish()

        let blocks = await sink.snapshot()
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].source, .microphone)
        XCTAssertEqual(blocks[0].firstSampleIndex, 0)
        XCTAssertEqual(
            blocks[1].firstSampleIndex,
            UInt64(blocks[0].samples.count)
        )

        let committedSampleCount = blocks.reduce(0) {
            $0 + $1.samples.count
        }
        let wavData = try Data(contentsOf: outputURL)
        XCTAssertEqual(
            wavData.uint32LE(at: 40),
            UInt32(committedSampleCount * MemoryLayout<Int16>.size)
        )
        XCTAssertEqual(
            wavData.count,
            44 + committedSampleCount * MemoryLayout<Int16>.size
        )
    }

    func testThirtySecondSystemRenderGapKeepsTimelineAligned()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ScribeSystemGapTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        let microphoneRing = try FloatRingBuffer(capacity: 20_000)
        let systemRing = try FloatRingBuffer(capacity: 20_000)
        let microphoneSink = CanonicalBlockCollector()
        let systemSink = CanonicalBlockCollector()
        let microphoneConsumer = try CanonicalAudioFileConsumer(
            source: .microphone,
            ringBuffer: microphoneRing,
            inputSampleRate: CanonicalAudioFormat.sampleRate,
            outputURL: directory.appendingPathComponent("microphone.wav"),
            liveSink: microphoneSink
        )
        let systemConsumer = try CanonicalAudioFileConsumer(
            source: .system,
            ringBuffer: systemRing,
            inputSampleRate: CanonicalAudioFormat.sampleRate,
            outputURL: directory.appendingPathComponent("system.wav"),
            liveSink: systemSink
        )
        let samplesPerSecond = Int(CanonicalAudioFormat.sampleRate)
        let microphoneSecond = Array(
            repeating: Float(0.25),
            count: samplesPerSecond
        )
        let systemSpeechSecond = Array(
            repeating: Float(0.75),
            count: samplesPerSecond
        )

        for second in 0..<32 {
            XCTAssertEqual(
                writeRender(microphoneSecond, to: microphoneRing),
                samplesPerSecond
            )
            while try await microphoneConsumer.processAvailable() > 0 {}

            let systemRender = second == 0 || second == 31
                ? systemSpeechSecond
                : nil
            XCTAssertEqual(
                writeRender(
                    systemRender,
                    silentFrameCount: samplesPerSecond,
                    to: systemRing
                ),
                samplesPerSecond
            )
            while try await systemConsumer.processAvailable() > 0 {}
        }
        try await microphoneConsumer.finish()
        try await systemConsumer.finish()

        let microphoneBlocks = await microphoneSink.snapshot()
        let systemBlocks = await systemSink.snapshot()
        let expectedSampleCount = UInt64(32 * samplesPerSecond)
        XCTAssertEqual(
            microphoneBlocks.reduce(UInt64(0)) {
                $0 + UInt64($1.samples.count)
            },
            expectedSampleCount
        )
        XCTAssertEqual(
            systemBlocks.reduce(UInt64(0)) {
                $0 + UInt64($1.samples.count)
            },
            expectedSampleCount
        )
        let postGapSampleIndex = UInt64(31 * samplesPerSecond)
        let microphoneAfterGap = try XCTUnwrap(
            microphoneBlocks.first {
                $0.firstSampleIndex == postGapSampleIndex
            }
        )
        let systemAfterGap = try XCTUnwrap(
            systemBlocks.first {
                $0.firstSampleIndex == postGapSampleIndex
                    && $0.samples.contains { $0 != 0 }
            }
        )
        let manifest = CaptureSessionManifest.dualTrack(
            microphoneStartTime: 0,
            systemStartTime: 0.375
        )
        let microphoneTimelineTime =
            try XCTUnwrap(manifest.track(for: .microphone)?.startTime)
            + microphoneAfterGap.startTime
        let systemTimelineTime =
            try XCTUnwrap(manifest.track(for: .system)?.startTime)
            + systemAfterGap.startTime
        XCTAssertEqual(microphoneTimelineTime, 31, accuracy: 0.000_001)
        XCTAssertEqual(systemTimelineTime, 31.375, accuracy: 0.000_001)
        XCTAssertEqual(
            systemTimelineTime - microphoneTimelineTime,
            0.375,
            accuracy: 0.000_001
        )
    }

    func testTwentyFourKilohertzInputProducesCanonicalOutput()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ScribeAirPodsRateTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let outputURL = directory.appendingPathComponent("microphone.wav")
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        let inputSampleRate = 24_000.0
        let duration = 0.5
        let inputFrameCount = Int(inputSampleRate * duration)
        let input = (0..<inputFrameCount).map { frame -> Float in
            let time = Double(frame) / inputSampleRate
            return Float(0.6 * sin(2 * Double.pi * 440 * time))
        }
        let ringBuffer = try FloatRingBuffer(capacity: inputFrameCount)
        let sink = CanonicalBlockCollector()
        let consumer = try CanonicalAudioFileConsumer(
            source: .microphone,
            ringBuffer: ringBuffer,
            inputSampleRate: inputSampleRate,
            outputURL: outputURL,
            liveSink: sink
        )

        XCTAssertEqual(write(input, to: ringBuffer), input.count)
        try await consumer.finish()

        let blocks = await sink.snapshot()
        let canonicalSamples = blocks.flatMap(\.samples)
        XCTAssertEqual(Set(blocks.map(\.source)), [.microphone])
        XCTAssertLessThanOrEqual(
            abs(
                canonicalSamples.count
                    - Int(CanonicalAudioFormat.sampleRate * duration)
            ),
            64
        )
        XCTAssertTrue(
            canonicalSamples.allSatisfy {
                $0.isFinite && (-1...1).contains($0)
            }
        )
        let rootMeanSquare = sqrt(
            canonicalSamples.reduce(0.0) { $0 + Double($1 * $1) }
                / Double(canonicalSamples.count)
        )
        XCTAssertGreaterThan(rootMeanSquare, 0.35)
        XCTAssertLessThan(rootMeanSquare, 0.50)

        let wavData = try Data(contentsOf: outputURL)
        XCTAssertEqual(wavData.uint32LE(at: 24), 16_000)
        XCTAssertEqual(wavData.uint32LE(at: 40), UInt32(wavData.count - 44))
        XCTAssertEqual(wavData.count, 44 + canonicalSamples.count * 2)
    }

    private func write(
        _ samples: [Float],
        to ringBuffer: FloatRingBuffer
    ) -> Int {
        samples.withUnsafeBufferPointer {
            ringBuffer.write($0)
        }
    }

    private func writeRender(
        _ samples: [Float]?,
        silentFrameCount: Int? = nil,
        to ringBuffer: FloatRingBuffer
    ) -> Int {
        if var samples {
            return samples.withUnsafeMutableBytes { bytes in
                var bufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(bytes.count),
                        mData: bytes.baseAddress
                    )
                )
                return withUnsafePointer(to: &bufferList) {
                    ringBuffer.writeAudioBufferListMix($0)
                }
            }
        }
        let frameCount = silentFrameCount ?? 0
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize:
                    UInt32(frameCount * MemoryLayout<Float>.size),
                mData: nil
            )
        )
        return withUnsafePointer(to: &bufferList) {
            ringBuffer.writeAudioBufferListMix($0)
        }
    }
}

private actor CanonicalBlockCollector: CanonicalAudioBlockSink {
    private var blocks: [CanonicalAudioBlock] = []

    func receive(_ block: CanonicalAudioBlock) async {
        blocks.append(block)
    }

    func snapshot() -> [CanonicalAudioBlock] {
        blocks
    }
}

private extension Data {
    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
