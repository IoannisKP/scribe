@testable import AudioCapture
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
            UInt32(committedSampleCount * MemoryLayout<Float>.size)
        )
        XCTAssertEqual(
            wavData.count,
            44 + committedSampleCount * MemoryLayout<Float>.size
        )
    }

    private func write(
        _ samples: [Float],
        to ringBuffer: FloatRingBuffer
    ) -> Int {
        samples.withUnsafeBufferPointer {
            ringBuffer.write($0)
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
