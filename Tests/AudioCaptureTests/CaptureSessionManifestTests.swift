import AudioCapture
import Foundation
import XCTest

final class CaptureSessionManifestTests: XCTestCase {
    func testRoundTripsCanonicalDualTrackTimeline() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Unable to remove test directory: \(error)")
            }
        }
        let manifest = CaptureSessionManifest.dualTrack(
            microphoneStartTime: 0,
            systemStartTime: 0.375
        )

        try manifest.write(to: directory)
        let decoded = try CaptureSessionManifest.load(from: directory)

        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(
            decoded.track(for: .system)?.startTime,
            0.375
        )
    }

    func testRejectsUnsafeTrackPath() {
        let manifest = CaptureSessionManifest(
            tracks: [
                .init(
                    source: .microphone,
                    relativePath: "../microphone.wav",
                    startTime: 0
                ),
                .init(
                    source: .system,
                    relativePath: "system.wav",
                    startTime: 0
                )
            ]
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(
                error as? CaptureSessionManifestError,
                .invalidRelativePath("../microphone.wav")
            )
        }
    }

    func testRequiresExactlyOneTrackPerSource() {
        let manifest = CaptureSessionManifest(
            tracks: [
                .init(
                    source: .microphone,
                    relativePath: "microphone.wav",
                    startTime: 0
                )
            ]
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(
                error as? CaptureSessionManifestError,
                .invalidTrackSet
            )
        }
    }

    func testImportedManifestHasOneUnattributedTrackAndImportMetadata()
        throws
    {
        let manifest = CaptureSessionManifest.importedFile(
            title: "Interview",
            createdAt: Date(timeIntervalSince1970: 10),
            originalFilename: "Interview.mov",
            originalFormat: "mov",
            originalRelativePath: "Interview.mov"
        )

        XCTAssertNoThrow(try manifest.validate())
        XCTAssertEqual(manifest.source, .importedFile)
        XCTAssertEqual(manifest.tracks.map(\.source), [.imported])
        XCTAssertEqual(manifest.originalFilename, "Interview.mov")
        XCTAssertEqual(manifest.originalFormat, "mov")
        XCTAssertEqual(manifest.artifacts.map(\.kind), [.originalImport, .audio])
    }

    func testReadsLegacyStartTimeAsEstimatedCanonicalSamples() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
            {
              "version": 1,
              "sampleRate": 16000,
              "channelCount": 1,
              "tracks": [
                {"source":"microphone","relativePath":"microphone.wav","startTime":0},
                {"source":"system","relativePath":"system.wav","startTime":0.0466875}
              ]
            }
            """
        try Data(json.utf8).write(
            to: directory.appendingPathComponent(
                CaptureSessionManifest.legacyFileName
            )
        )

        let manifest = try CaptureSessionManifest.load(from: directory)
        XCTAssertEqual(
            manifest.track(for: .system)?.startSampleOffset,
            747
        )
        XCTAssertEqual(
            manifest.track(for: .system)?.timingPrecision,
            .legacyEstimated
        )
    }

    func testNormalizesHostTimesToCanonicalSampleOffsets() {
        let same = AudioHostTime.normalizedCanonicalOffsets(
            microphoneHostTime: 10,
            systemHostTime: 10
        )
        XCTAssertEqual(same.microphone, 0)
        XCTAssertEqual(same.system, 0)
        let missing = AudioHostTime.normalizedCanonicalOffsets(
            microphoneHostTime: 10,
            systemHostTime: nil
        )
        XCTAssertEqual(missing.microphone, 0)
        XCTAssertNil(missing.system)
    }

    func testRoundTripsSystemAudioStartupStageTimings() throws {
        let timings = SystemAudioStartupStage.allCases.enumerated().map {
            index,
            stage in
            SystemAudioStartupStageTiming(
                stage: stage,
                durationMachTicks: UInt64(index + 1),
                durationNanoseconds: UInt64((index + 1) * 100)
            )
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = CaptureSessionManifest.pendingDualTrack(
            sessionID: UUID(),
            title: "Startup timing",
            createdAt: Date(timeIntervalSince1970: 10)
        ).replacingSystemAudioStartupStageTimings(timings)

        try manifest.write(to: directory)
        let decoded = try CaptureSessionManifest.load(from: directory)

        XCTAssertEqual(decoded.systemAudioStartupStageTimings, timings)
    }
}
