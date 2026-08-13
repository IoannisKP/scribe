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
        XCTAssertEqual(manifest.speakerIdentities.count, 1)
        XCTAssertEqual(manifest.speakerIdentities[0].id, "source.imported")
        XCTAssertEqual(manifest.speakerIdentities[0].source, .imported)
        XCTAssertNil(manifest.speakerIdentities[0].displayName)
        XCTAssertNil(manifest.speakerIdentities[0].nameAssignment)
    }

    func testLiveManifestStartsWithOneUnnamedSpeakerPerSource() {
        let manifest = CaptureSessionManifest.pendingDualTrack(
            sessionID: UUID(),
            title: "Meeting",
            createdAt: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(
            manifest.speakerIdentities.map(\.id),
            ["source.microphone", "source.system"]
        )
        XCTAssertEqual(
            manifest.speakerIdentities.map(\.source),
            [.microphone, .system]
        )
        XCTAssertTrue(manifest.speakerIdentities.allSatisfy {
            $0.displayName == nil && $0.nameAssignment == nil
        })
    }

    func testArbitrarySpeakerCountRoundTripsWithAssignmentProvenance()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = CaptureSessionManifest.pendingDualTrack(
            sessionID: UUID(),
            title: "Group",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let speakers = [
            CaptureSessionManifest.SpeakerIdentity(
                id: "local",
                displayName: "Ioannis",
                source: .microphone,
                nameAssignment: .userAssigned
            ),
            CaptureSessionManifest.SpeakerIdentity(
                id: "remote-1",
                displayName: "Speaker 1",
                source: .system,
                nameAssignment: .machineAssigned
            ),
            CaptureSessionManifest.SpeakerIdentity(
                id: "remote-2",
                displayName: "Maria",
                source: .system,
                nameAssignment: .userAssigned
            )
        ]
        let manifest = base.replacing(speakerIdentities: speakers)

        try manifest.write(to: directory)
        let decoded = try CaptureSessionManifest.load(from: directory)

        XCTAssertEqual(decoded.speakerIdentities, speakers)
        XCTAssertEqual(decoded.version, CaptureSessionManifest.currentVersion)
    }

    func testVersionTwoManifestDerivesStableSourceSpeakers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
            {
              "version": 2,
              "title": "Existing",
              "createdAt": "2026-08-13T07:00:00Z",
              "source": "liveCapture",
              "sampleRate": 16000,
              "channelCount": 1,
              "tracks": [
                {"source":"microphone","relativePath":"microphone.wav","startSampleOffset":0,"timingPrecision":"sampleAccurate"},
                {"source":"system","relativePath":"system.wav","startSampleOffset":0,"timingPrecision":"sampleAccurate"}
              ]
            }
            """
        try Data(json.utf8).write(
            to: directory.appendingPathComponent(
                CaptureSessionManifest.fileName
            )
        )

        let first = try CaptureSessionManifest.load(from: directory)
        let second = try CaptureSessionManifest.load(from: directory)

        XCTAssertEqual(first.version, 2)
        XCTAssertEqual(
            first.speakerIdentities.map(\.id),
            ["source.microphone", "source.system"]
        )
        XCTAssertEqual(first.speakerIdentities, second.speakerIdentities)
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

    func testRoundTripsSystemAudioGraphPreparation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = CaptureSessionManifest.pendingDualTrack(
            sessionID: UUID(),
            title: "Prepared capture",
            createdAt: Date(timeIntervalSince1970: 10)
        ).replacingSystemAudioGraphPreparation(.prewarmed)

        try manifest.write(to: directory)
        let decoded = try CaptureSessionManifest.load(from: directory)

        XCTAssertEqual(decoded.systemAudioGraphPreparation, .prewarmed)
    }
}
