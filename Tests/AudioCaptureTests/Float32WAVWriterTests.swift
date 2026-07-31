import AudioCapture
import Foundation
import XCTest

final class Float32WAVWriterTests: XCTestCase {
    func testWritesCanonicalFloat32WAVAndClampsSamples() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("track.wav")
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Unable to remove test directory: \(error)")
            }
        }

        let writer = try Float32WAVWriter(url: url)
        try await writer.append([-2, -0.5, 0, 0.5, 2])
        try await writer.finish()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + (5 * MemoryLayout<Float>.size))
        XCTAssertEqual(data.ascii(at: 0, count: 4), "RIFF")
        XCTAssertEqual(data.uint32LE(at: 4), UInt32(data.count - 8))
        XCTAssertEqual(data.ascii(at: 8, count: 4), "WAVE")
        XCTAssertEqual(data.uint16LE(at: 20), 3)
        XCTAssertEqual(data.uint16LE(at: 22), 1)
        XCTAssertEqual(data.uint32LE(at: 24), 16_000)
        XCTAssertEqual(data.uint16LE(at: 34), 32)
        XCTAssertEqual(data.ascii(at: 36, count: 4), "data")
        XCTAssertEqual(data.uint32LE(at: 40), 20)

        let samples = stride(from: 44, to: data.count, by: 4).map {
            Float(bitPattern: data.uint32LE(at: $0))
        }
        XCTAssertEqual(samples, [-1, -0.5, 0, 0.5, 1])
    }

    func testRefusesToOverwriteExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("existing.wav")
        let marker = Data("preserve".utf8)
        try marker.write(to: url)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Unable to remove test directory: \(error)")
            }
        }

        XCTAssertThrowsError(try Float32WAVWriter(url: url)) { error in
            XCTAssertEqual(
                error as? AudioCaptureError,
                .wavFileAlreadyExists(url)
            )
        }
        XCTAssertEqual(try Data(contentsOf: url), marker)
    }
}

private extension Data {
    func ascii(at offset: Int, count: Int) -> String {
        String(decoding: self[offset..<(offset + count)], as: UTF8.self)
    }

    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset])
            | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
