import AudioCapture
import CoreAudioTypes
import Foundation
import XCTest

final class FloatRingBufferTests: XCTestCase {
    func testRejectsNonPositiveCapacity() {
        XCTAssertThrowsError(try FloatRingBuffer(capacity: 0)) { error in
            XCTAssertEqual(
                error as? AudioCaptureError,
                .invalidRingBufferCapacity(0)
            )
        }
    }

    func testPreservesFIFOOrderAcrossWraparound() throws {
        let buffer = try FloatRingBuffer(capacity: 5)

        let firstWrite: [Float] = [1, 2, 3, 4]
        let writtenFirst = firstWrite.withUnsafeBufferPointer(buffer.write)
        XCTAssertEqual(writtenFirst, 4)
        XCTAssertEqual(buffer.readableCount, 4)
        XCTAssertEqual(buffer.writableCount, 1)

        var firstRead = Array(repeating: Float.zero, count: 3)
        let readFirst = firstRead.withUnsafeMutableBufferPointer {
            buffer.read(into: $0)
        }
        XCTAssertEqual(readFirst, 3)
        XCTAssertEqual(firstRead, [1, 2, 3])

        let secondWrite: [Float] = [5, 6, 7, 8]
        let writtenSecond = secondWrite.withUnsafeBufferPointer(buffer.write)
        XCTAssertEqual(writtenSecond, 4)
        XCTAssertEqual(buffer.readableCount, 5)

        var secondRead = Array(repeating: Float.zero, count: 5)
        let readSecond = secondRead.withUnsafeMutableBufferPointer {
            buffer.read(into: $0)
        }
        XCTAssertEqual(readSecond, 5)
        XCTAssertEqual(secondRead, [4, 5, 6, 7, 8])
        XCTAssertEqual(buffer.readableCount, 0)
    }

    func testPartialWriteDoesNotOverwriteUnreadSamples() throws {
        let buffer = try FloatRingBuffer(capacity: 3)
        let initial: [Float] = [10, 20, 30]
        XCTAssertEqual(initial.withUnsafeBufferPointer(buffer.write), 3)

        let overflow: [Float] = [40, 50]
        XCTAssertEqual(overflow.withUnsafeBufferPointer(buffer.write), 0)

        var output = Array(repeating: Float.zero, count: 3)
        XCTAssertEqual(
            output.withUnsafeMutableBufferPointer { buffer.read(into: $0) },
            3
        )
        XCTAssertEqual(output, initial)
    }

    func testPlanarMixdownClampsAndCountsDroppedFrames() throws {
        let buffer = try FloatRingBuffer(capacity: 4)
        var left: [Float] = [1, 0.5, -1, 2]
        var right: [Float] = [-1, 0.5, 1, 2]

        let written = left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                guard
                    let leftAddress = leftBuffer.baseAddress,
                    let rightAddress = rightBuffer.baseAddress
                else {
                    return -1
                }
                let channels = [leftAddress, rightAddress]
                return channels.withUnsafeBufferPointer {
                    guard let channelAddress = $0.baseAddress else {
                        return -1
                    }
                    return buffer.writePlanarMix(
                        channels: channelAddress,
                        channelCount: channels.count,
                        frameCount: leftBuffer.count
                    )
                }
            }
        }
        XCTAssertEqual(written, 4)

        var overflowChannel: [Float] = [0.25]
        let overflowWritten = overflowChannel.withUnsafeMutableBufferPointer {
            guard let overflowAddress = $0.baseAddress else {
                return -1
            }
            let channels = [overflowAddress]
            return channels.withUnsafeBufferPointer {
                guard let channelAddress = $0.baseAddress else {
                    return -1
                }
                return buffer.writePlanarMix(
                    channels: channelAddress,
                    channelCount: channels.count,
                    frameCount: 1
                )
            }
        }
        XCTAssertEqual(overflowWritten, 0)
        XCTAssertEqual(buffer.droppedSampleCount, 1)

        var output = Array(repeating: Float.zero, count: 4)
        XCTAssertEqual(
            output.withUnsafeMutableBufferPointer { buffer.read(into: $0) },
            4
        )
        XCTAssertEqual(output, [0, 0.5, 0, 1])
    }

    func testInterleavedAudioBufferListMixdown() throws {
        let buffer = try FloatRingBuffer(capacity: 3)
        var interleavedStereo: [Float] = [
            1, -1,
            0.5, 0.5,
            2, 2
        ]

        let written = interleavedStereo.withUnsafeMutableBytes { bytes in
            var audioBufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress
                )
            )
            return withUnsafePointer(to: &audioBufferList) {
                buffer.writeAudioBufferListMix($0)
            }
        }
        XCTAssertEqual(written, 3)

        var output = Array(repeating: Float.zero, count: 3)
        XCTAssertEqual(
            output.withUnsafeMutableBufferPointer { buffer.read(into: $0) },
            3
        )
        XCTAssertEqual(output, [0, 0.5, 1])
    }

    func testDisabledCoreAudioBufferWritesReportedFramesAsSilence()
        throws
    {
        let buffer = try FloatRingBuffer(capacity: 8)
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: 8 * UInt32(MemoryLayout<Float>.size),
                mData: nil
            )
        )

        let written = withUnsafePointer(to: &audioBufferList) {
            buffer.writeAudioBufferListMix($0)
        }

        XCTAssertEqual(written, 8)
        var output = Array(repeating: Float.nan, count: 8)
        XCTAssertEqual(
            output.withUnsafeMutableBufferPointer { buffer.read(into: $0) },
            8
        )
        XCTAssertEqual(output, Array(repeating: 0, count: 8))
    }

    func testClearDiscardsBufferedSamplesWhileIdle() throws {
        let buffer = try FloatRingBuffer(capacity: 4)
        let input: [Float] = [1, 2, 3]
        XCTAssertEqual(input.withUnsafeBufferPointer(buffer.write), 3)

        buffer.clear()

        XCTAssertEqual(buffer.readableCount, 0)
        XCTAssertEqual(buffer.writableCount, 4)
    }

    func testConcurrentProducerAndConsumerPreserveEverySample() throws {
        let sampleCount = 100_000
        let input = (0..<sampleCount).map { Float($0) }
        let buffer = try FloatRingBuffer(capacity: 257)
        let output = SampleCollector()
        let group = DispatchGroup()
        let producerQueue = DispatchQueue(
            label: "scribe.ring-buffer-test.producer",
            qos: .userInitiated
        )
        let consumerQueue = DispatchQueue(
            label: "scribe.ring-buffer-test.consumer",
            qos: .userInitiated
        )

        group.enter()
        producerQueue.async {
            input.withUnsafeBufferPointer { source in
                guard let sourceAddress = source.baseAddress else {
                    group.leave()
                    return
                }

                var offset = 0
                while offset < source.count {
                    let remaining = UnsafeBufferPointer(
                        start: sourceAddress.advanced(by: offset),
                        count: source.count - offset
                    )
                    offset += buffer.write(remaining)
                }
            }
            group.leave()
        }

        group.enter()
        consumerQueue.async {
            var temporary = Array(repeating: Float.zero, count: 113)
            while output.samples.count < sampleCount {
                let readCount = temporary.withUnsafeMutableBufferPointer {
                    buffer.read(into: $0)
                }
                if readCount > 0 {
                    output.samples.append(contentsOf: temporary.prefix(readCount))
                }
            }
            group.leave()
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(output.samples, input)
        XCTAssertEqual(buffer.readableCount, 0)
    }
}

/// Written by the test's single consumer queue and read only after the dispatch
/// group establishes completion.
private final class SampleCollector: @unchecked Sendable {
    var samples: [Float] = []
}
