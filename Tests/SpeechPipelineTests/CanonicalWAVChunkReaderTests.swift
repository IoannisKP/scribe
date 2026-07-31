import AudioCapture
import Foundation
import SpeechPipeline
import XCTest

final class CanonicalWAVChunkReaderTests: XCTestCase {
    func testReadsLegacyFloat32WAVInBoundedChunksWithTimelineOffset()
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

    func testReadsDurableInt16WAVAsFloatInferenceSamples() async throws {
        let fixture = try CanonicalWAVFixture.load()
        let directory = try makeTestDirectory()
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("durable-int16.wav")
        try await writeDurableSessionWAV(samples: fixture.samples, to: url)
        let reader = try CanonicalWAVChunkReader(
            url: url,
            source: .microphone,
            trackStartTime: 2,
            chunkDuration: 1
        )

        let value = try await reader.nextChunk()
        let chunk = try XCTUnwrap(value)

        XCTAssertEqual(chunk.samples.count, fixture.samples.count)
        XCTAssertEqual(chunk.startTime, 2)
        for (actual, expected) in zip(chunk.samples, fixture.samples) {
            XCTAssertEqual(actual, expected, accuracy: 1 / 32_768)
        }
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
                trackStartTime: 0,
                chunkDuration: 14
            )
        )
    }

    func testOverlappingChunksAdvanceByWindowMinusOverlap() async throws {
        let fixture = try CanonicalWAVFixture.load()
        let directory = try makeTestDirectory()
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("overlap.wav")
        try await writeCanonicalWAV(samples: fixture.samples, to: url)
        let sampleDuration = 1 / CanonicalAudioFormat.sampleRate
        let reader = try CanonicalWAVChunkReader(
            url: url,
            source: .microphone,
            trackStartTime: 0,
            chunkDuration: 4 * sampleDuration,
            overlapDuration: 2 * sampleDuration
        )

        var chunks: [AudioChunk] = []
        while let chunk = try await reader.nextChunk() {
            chunks.append(chunk)
        }

        XCTAssertEqual(
            chunks.map(\.samples),
            [
                Array(fixture.samples[0..<4]),
                Array(fixture.samples[2..<6]),
                Array(fixture.samples[4..<8]),
                Array(fixture.samples[6..<9]),
            ]
        )
        XCTAssertEqual(
            chunks.map { $0.startTime },
            [0, 2 * sampleDuration, 4 * sampleDuration, 6 * sampleDuration]
        )
    }


    func testRejectsOverlapThatDoesNotAdvance() async throws {
        let directory = try makeTestDirectory()
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("invalid-overlap.wav")
        try await writeCanonicalWAV(samples: [0, 0], to: url)

        XCTAssertThrowsError(
            try CanonicalWAVChunkReader(
                url: url,
                source: .microphone,
                trackStartTime: 0,
                chunkDuration: 1,
                overlapDuration: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? SpeechPipelineError,
                .invalidChunkOverlap(1)
            )
        }
    }
}
