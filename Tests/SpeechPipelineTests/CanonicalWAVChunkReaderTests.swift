import AudioCapture
import Foundation
import SpeechPipeline
import XCTest

final class CanonicalWAVChunkReaderTests: XCTestCase {
    func testReadsFixtureBackedWAVInBoundedChunksWithTimelineOffset()
        async throws
    {
        let fixture = try CanonicalWAVFixture.load()
        let directory = try makeTestDirectory()
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Unable to remove test directory: \(error)")
            }
        }
        let url = directory.appendingPathComponent("fixture.wav")
        try await writeCanonicalWAV(samples: fixture.samples, to: url)

        let chunkDuration = Double(fixture.chunkSampleCount)
            / CanonicalAudioFormat.sampleRate
        let reader = try CanonicalWAVChunkReader(
            url: url,
            source: .system,
            trackStartTime: 1.25,
            chunkDuration: chunkDuration
        )

        let firstValue = try await reader.nextChunk()
        let secondValue = try await reader.nextChunk()
        let thirdValue = try await reader.nextChunk()
        let end = try await reader.nextChunk()
        let first = try XCTUnwrap(firstValue)
        let second = try XCTUnwrap(secondValue)
        let third = try XCTUnwrap(thirdValue)

        XCTAssertEqual(first.samples, Array(fixture.samples[0..<4]))
        XCTAssertEqual(second.samples, Array(fixture.samples[4..<8]))
        XCTAssertEqual(third.samples, Array(fixture.samples[8..<9]))
        XCTAssertEqual(first.startTime, 1.25, accuracy: 0.000_001)
        XCTAssertEqual(
            second.startTime,
            1.25 + chunkDuration,
            accuracy: 0.000_001
        )
        XCTAssertEqual(first.source, .system)
        XCTAssertNil(end)
        let remaining = await reader.remainingSampleCount
        XCTAssertEqual(remaining, 0)
    }

    func testRejectsNoncanonicalWAV() async throws {
        let directory = try makeTestDirectory()
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Unable to remove test directory: \(error)")
            }
        }
        let url = directory.appendingPathComponent("not-a-wave.wav")
        try Data("not a wave".utf8).write(to: url)

        XCTAssertThrowsError(
            try CanonicalWAVChunkReader(
                url: url,
                source: .microphone,
                trackStartTime: 0
            )
        )
    }
}
