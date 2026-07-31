import AudioCapture
import Foundation
import XCTest

final class Int16WAVWriterTests: XCTestCase {
    func testWritesCanonicalInt16PCMAndClampsSamples() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("track.wav")
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        let writer = try Int16WAVWriter(url: url)

        try await writer.append([
            -2, -1, -0.5, 0, 0.5, 1, 2, .nan,
        ])
        try await writer.finish()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + (8 * MemoryLayout<Int16>.size))
        XCTAssertEqual(data.ascii(at: 0, count: 4), "RIFF")
        XCTAssertEqual(data.uint32LE(at: 4), UInt32(data.count - 8))
        XCTAssertEqual(data.ascii(at: 8, count: 4), "WAVE")
        XCTAssertEqual(data.uint16LE(at: 20), 1)
        XCTAssertEqual(data.uint16LE(at: 22), 1)
        XCTAssertEqual(data.uint32LE(at: 24), 16_000)
        XCTAssertEqual(data.uint32LE(at: 28), 32_000)
        XCTAssertEqual(data.uint16LE(at: 32), 2)
        XCTAssertEqual(data.uint16LE(at: 34), 16)
        XCTAssertEqual(data.ascii(at: 36, count: 4), "data")
        XCTAssertEqual(data.uint32LE(at: 40), 16)
        XCTAssertEqual(
            stride(from: 44, to: data.count, by: 2).map {
                data.int16LE(at: $0)
            },
            [.min, .min, -16_384, 0, 16_384, .max, .max, 0]
        )
    }

    func testUsesHalfTheFloat32PayloadForSameSamples() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        let int16URL = directory.appendingPathComponent("int16.wav")
        let float32URL = directory.appendingPathComponent("float32.wav")
        let samples = (0..<16_000).map {
            sin(Float($0) * 0.01)
        }
        let int16Writer = try Int16WAVWriter(url: int16URL)
        let float32Writer = try Float32WAVWriter(url: float32URL)

        try await int16Writer.append(samples)
        try await int16Writer.finish()
        try await float32Writer.append(samples)
        try await float32Writer.finish()

        let int16Payload = try Data(contentsOf: int16URL).count - 44
        let float32Payload = try Data(contentsOf: float32URL).count - 44
        XCTAssertEqual(int16Payload * 2, float32Payload)
    }
}

private extension Data {
    func ascii(at offset: Int, count: Int) -> String {
        String(decoding: self[offset..<(offset + count)], as: UTF8.self)
    }

    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func int16LE(at offset: Int) -> Int16 {
        Int16(bitPattern: uint16LE(at: offset))
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
