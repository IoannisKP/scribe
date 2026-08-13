@testable import AudioCapture
import Foundation
import XCTest

final class SourceIsolationRegressionTests: XCTestCase {
    func testDistinguishableSourceSignalsProduceDifferentWAVPayloads()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ScribeSourceIsolationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }

        let microphoneURL = directory.appendingPathComponent("microphone.wav")
        let systemURL = directory.appendingPathComponent("system.wav")
        let microphoneRing = try FloatRingBuffer(capacity: 8_192)
        let systemRing = try FloatRingBuffer(capacity: 8_192)
        let microphoneSink = SourceBlockCollector()
        let systemSink = SourceBlockCollector()
        let microphoneConsumer = try CanonicalAudioFileConsumer(
            source: .microphone,
            ringBuffer: microphoneRing,
            inputSampleRate: CanonicalAudioFormat.sampleRate,
            outputURL: microphoneURL,
            liveSink: microphoneSink
        )
        let systemConsumer = try CanonicalAudioFileConsumer(
            source: .system,
            ringBuffer: systemRing,
            inputSampleRate: CanonicalAudioFormat.sampleRate,
            outputURL: systemURL,
            liveSink: systemSink
        )
        let sampleCount = 4_096
        let microphoneSignal = (0..<sampleCount).map { index in
            Float(sin(Double(index) * 0.031)) * 0.35
        }
        let systemSignal = (0..<sampleCount).map { index in
            Float(cos(Double(index) * 0.079)) * 0.70
        }

        XCTAssertEqual(
            write(microphoneSignal, to: microphoneRing),
            sampleCount
        )
        XCTAssertEqual(write(systemSignal, to: systemRing), sampleCount)
        try await microphoneConsumer.finish()
        try await systemConsumer.finish()

        let microphoneData = try Data(contentsOf: microphoneURL)
        let systemData = try Data(contentsOf: systemURL)
        let microphonePayload = microphoneData.dropFirst(44)
        let systemPayload = systemData.dropFirst(44)
        XCTAssertEqual(microphonePayload.count, sampleCount * 2)
        XCTAssertEqual(systemPayload.count, sampleCount * 2)
        XCTAssertNotEqual(microphonePayload, systemPayload)

        let microphoneBlocks = await microphoneSink.snapshot()
        let systemBlocks = await systemSink.snapshot()
        XCTAssertEqual(microphoneBlocks.map(\.source), [.microphone])
        XCTAssertEqual(systemBlocks.map(\.source), [.system])
        XCTAssertEqual(microphoneBlocks.first?.samples, microphoneSignal)
        XCTAssertEqual(systemBlocks.first?.samples, systemSignal)
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

private actor SourceBlockCollector: CanonicalAudioBlockSink {
    private var blocks: [CanonicalAudioBlock] = []

    func receive(_ block: CanonicalAudioBlock) async {
        blocks.append(block)
    }

    func snapshot() -> [CanonicalAudioBlock] {
        blocks
    }
}
