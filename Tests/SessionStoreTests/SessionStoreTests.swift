import AudioCapture
import Foundation
import SessionStore
import SpeechPipeline
import XCTest

final class SessionStoreTests: XCTestCase {
    func testCreatesHumanReadableSessionFolderAndManifest() throws {
        try withTemporaryDirectory { root in
            let date = Date(timeIntervalSince1970: 1_735_732_800)
            let created = try SessionFolderManager().createLiveSession(
                in: root,
                title: "Design: Review",
                date: date
            )

            XCTAssertTrue(created.directory.lastPathComponent.contains("Design- Review"))
            XCTAssertEqual(created.manifest.title, "Design- Review")
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: created.directory.appendingPathComponent("notes.md").path
                )
            )
            XCTAssertEqual(
                try CaptureSessionManifest.load(from: created.directory).sessionID,
                created.manifest.sessionID
            )
        }
    }

    func testDuplicateFinderCopyGetsFreshUUIDAndInformationalNotice()
        async throws
    {
        try await withTemporaryDirectory { root in
            let first = root.appendingPathComponent("A original", isDirectory: true)
            let second = root.appendingPathComponent("B copy", isDirectory: true)
            let id = UUID()
            let manifest = CaptureSessionManifest.pendingDualTrack(
                sessionID: id,
                title: "Copied meeting",
                createdAt: Date(timeIntervalSince1970: 100)
            )
            try manifest.write(to: first)
            try manifest.write(to: second)
            let index = try SessionIndex(
                databaseURL: root.appendingPathComponent("index.sqlite")
            )
            // Keep the database outside the scanned root in real use. The test
            // index is a file and is therefore never mistaken for a session.
            let report = try await SessionReconciler(index: index).reconcile(
                availability: .available(root)
            )

            XCTAssertEqual(report.indexedSessionCount, 2)
            XCTAssertEqual(
                report.notices.filter { $0.kind == .duplicateCopied }.count,
                1
            )
            XCTAssertEqual(try CaptureSessionManifest.load(from: first).sessionID, id)
            XCTAssertNotEqual(
                try CaptureSessionManifest.load(from: second).sessionID,
                id
            )
        }
    }

    func testUnavailableLocationMarksRowsWithoutDeletingThem() async throws {
        try await withTemporaryDirectory { root in
            let library = root.appendingPathComponent("Library", isDirectory: true)
            let created = try SessionFolderManager().createLiveSession(in: library)
            let index = try SessionIndex(
                databaseURL: root.appendingPathComponent("Index/index.sqlite")
            )
            let reconciler = SessionReconciler(index: index)
            _ = try await reconciler.reconcile(availability: .available(library))
            _ = try await reconciler.reconcile(
                availability: .unavailable(lastKnownURL: library)
            )

            let rows = try await index.sessions()
            XCTAssertEqual(rows.map(\.id), [created.manifest.sessionID])
            XCTAssertEqual(rows.first?.isAvailable, false)
        }
    }

    func testAdditionalArtifactPolicySurfacesPDFButIgnoresMetadataAndAlias()
        throws
    {
        try withTemporaryDirectory { root in
            let pdf = root.appendingPathComponent("agenda.pdf")
            let metadata = root.appendingPathComponent(".DS_Store")
            try Data("pdf".utf8).write(to: pdf)
            try Data().write(to: metadata)
            let keys: Set<URLResourceKey> = [
                .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey,
                .isHiddenKey
            ]
            XCTAssertTrue(SessionArtifactPolicy.shouldSurfaceAdditionalFile(
                pdf,
                resourceValues: try pdf.resourceValues(forKeys: keys)
            ))
            XCTAssertFalse(SessionArtifactPolicy.shouldSurfaceAdditionalFile(
                metadata,
                resourceValues: try metadata.resourceValues(forKeys: keys)
            ))
        }
    }

    func testRebuildIndexesTranscriptAndAdditionalPDF() async throws {
        try await withTemporaryDirectory { root in
            let library = root.appendingPathComponent("Library", isDirectory: true)
            let created = try SessionFolderManager().createLiveSession(
                in: library,
                title: "Architecture"
            )
            try Data("bounded local storage".utf8).write(
                to: created.directory.appendingPathComponent("transcript.md")
            )
            try Data("attachment".utf8).write(
                to: created.directory.appendingPathComponent("agenda.pdf")
            )
            let index = try SessionIndex(
                databaseURL: root.appendingPathComponent("Index/index.sqlite")
            )
            _ = try await SessionReconciler(index: index).reconcile(
                availability: .available(library)
            )

            let searchResults = try await index.search("bounded")
            XCTAssertEqual(searchResults.map(\.id), [created.manifest.sessionID])
            let updated = try CaptureSessionManifest.load(from: created.directory)
            XCTAssertTrue(updated.artifacts.contains {
                $0.relativePath == "agenda.pdf" && $0.kind == .additional
            })
        }
    }

    func testEveryTranscriptionGetsImmutableHistoryAndCurrentExports()
        throws
    {
        try withTemporaryDirectory { root in
            let created = try SessionFolderManager().createLiveSession(in: root)
            let segment = TranscriptSegment(
                text: "Sample text",
                startTime: 1,
                endTime: 2,
                source: .microphone,
                words: [WordTiming(text: "Sample", startTime: 1, endTime: 1.5)]
            )
            let writer = TranscriptArtifactWriter()
            let first = try writer.write(
                segments: [segment],
                modelIdentifier: "parakeet-v3",
                to: created.directory,
                date: Date(timeIntervalSince1970: 1_000)
            )
            let second = try writer.write(
                segments: [segment],
                modelIdentifier: "whisper-large-v3",
                to: created.directory,
                date: Date(timeIntervalSince1970: 2_000)
            )

            XCTAssertEqual(first.revisionFiles.count, 3)
            XCTAssertEqual(second.revisionFiles.count, 3)
            XCTAssertTrue(first.revisionFiles.allSatisfy {
                FileManager.default.fileExists(atPath: $0.path)
            })
            XCTAssertTrue(second.currentFiles.allSatisfy {
                FileManager.default.fileExists(atPath: $0.path)
            })
            XCTAssertEqual(
                try CaptureSessionManifest.load(from: created.directory)
                    .transcriptionHistory.count,
                2
            )
        }
    }

    func testLegacyMigrationMovesFolderAndMarksTimingEstimated() throws {
        try withTemporaryDirectory { root in
            let legacyRoot = root.appendingPathComponent("Legacy", isDirectory: true)
            let library = root.appendingPathComponent("Library", isDirectory: true)
            let legacySession = legacyRoot.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: legacySession,
                withIntermediateDirectories: true
            )
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
                to: legacySession.appendingPathComponent(
                    CaptureSessionManifest.legacyFileName
                )
            )

            let report = LegacySessionMigrator().migrate(
                from: legacyRoot,
                to: library
            )
            XCTAssertTrue(report.failures.isEmpty)
            let moved = try XCTUnwrap(report.migratedDirectories.first)
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacySession.path))
            let manifest = try CaptureSessionManifest.load(from: moved)
            XCTAssertEqual(
                manifest.track(for: .system)?.startSampleOffset,
                747
            )
            XCTAssertEqual(
                manifest.track(for: .system)?.timingPrecision,
                .legacyEstimated
            )
        }
    }

    func testDeletedIndexRebuildsEntirelyFromSessionFolders() async throws {
        try await withTemporaryDirectory { root in
            let library = root.appendingPathComponent("Library", isDirectory: true)
            let created = try SessionFolderManager().createLiveSession(
                in: library,
                title: "Rebuild source"
            )
            let databaseURL = root.appendingPathComponent("Index/sessions.sqlite")
            let firstIndex = try SessionIndex(databaseURL: databaseURL)
            _ = try await SessionReconciler(index: firstIndex).reconcile(
                availability: .available(library)
            )
            try await firstIndex.deleteDatabaseFiles()

            let rebuiltIndex = try SessionIndex(databaseURL: databaseURL)
            _ = try await SessionReconciler(index: rebuiltIndex).reconcile(
                availability: .available(library)
            )
            let rebuiltSessions = try await rebuiltIndex.sessions()
            XCTAssertEqual(
                rebuiltSessions.map(\.id),
                [created.manifest.sessionID]
            )
        }
    }

    private func withTemporaryDirectory<T>(
        _ body: (URL) throws -> T
    ) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScribeSessionStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(root)
    }

    private func withTemporaryDirectory<T>(
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScribeSessionStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        return try await body(root)
    }
}
