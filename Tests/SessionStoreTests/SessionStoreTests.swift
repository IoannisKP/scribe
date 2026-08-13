import AudioCapture
import Foundation
import SessionStore
import SpeechPipeline
import XCTest

final class SessionStoreTests: XCTestCase {
    func testSmartFolderCountsMatchIndexedArtifactsAndSources() async throws {
        try await withTemporaryDirectory { root in
            let index = try SessionIndex(
                databaseURL: root.appendingPathComponent("Index/index.sqlite")
            )
            let live = IndexedSession(
                id: UUID(),
                title: "Live",
                createdAt: Date(timeIntervalSince1970: 1),
                directory: root.appendingPathComponent("Live"),
                source: "liveCapture",
                isAvailable: true
            )
            let imported = IndexedSession(
                id: UUID(),
                title: "Imported",
                createdAt: Date(timeIntervalSince1970: 2),
                directory: root.appendingPathComponent("Imported"),
                source: "importedFile",
                isAvailable: true
            )
            try await index.replace(
                session: live,
                artifacts: [
                    IndexedArtifact(
                        relativePath: "summary.md",
                        kind: "summary",
                        byteCount: 4,
                        modifiedAt: nil
                    )
                ],
                transcript: "",
                notes: "",
                summary: "done"
            )
            try await index.replace(
                session: imported,
                artifacts: [],
                transcript: "",
                notes: "",
                summary: ""
            )

            let counts = try await index.smartFolderCounts()
            XCTAssertEqual(counts.allSessions, 2)
            XCTAssertEqual(counts.needsSummary, 1)
            XCTAssertEqual(counts.imported, 1)
        }
    }

    func testHeaderOnlySystemTrackKeepsPinsThroughOffsetAndReconciliation()
        async throws
    {
        try await withTemporaryDirectory { root in
            let library = root.appendingPathComponent(
                "Library",
                isDirectory: true
            )
            let created = try SessionFolderManager().createLiveSession(
                in: library,
                title: "Silent remote"
            )
            let microphoneURL = created.directory.appendingPathComponent(
                "microphone.wav"
            )
            let systemURL = created.directory.appendingPathComponent(
                "system.wav"
            )
            let microphoneWriter = try Int16WAVWriter(url: microphoneURL)
            try await microphoneWriter.append(
                Array(repeating: 0.25, count: 16_000)
            )
            try await microphoneWriter.finish()
            let systemWriter = try Int16WAVWriter(url: systemURL)
            try await systemWriter.finish()
            XCTAssertEqual(
                try systemURL.resourceValues(forKeys: [.fileSizeKey])
                    .fileSize,
                44
            )

            // Reproduce the old race: reconciliation held this snapshot while
            // pins and final offsets were committed by the recording path.
            let staleReconciliationSnapshot = try CaptureSessionManifest.load(
                from: created.directory
            )
            let pins = [
                CaptureSessionManifest.Pin(sampleOffset: 3_180),
                CaptureSessionManifest.Pin(sampleOffset: 5_760),
                CaptureSessionManifest.Pin(sampleOffset: 9_410)
            ]
            for pin in pins {
                try await CaptureSessionManifestStore.shared.appendPin(
                    pin,
                    in: created.directory
                )
            }
            try await CaptureSessionManifestStore.shared.replaceTrackOffsets(
                microphone: 602,
                system: nil,
                in: created.directory
            )
            let staleArtifacts = staleReconciliationSnapshot.artifacts + [
                CaptureSessionManifest.Artifact(
                    relativePath: "notes.md",
                    kind: .notes
                )
            ]
            _ = try await CaptureSessionManifestStore.shared.replaceArtifacts(
                staleArtifacts,
                in: created.directory
            )

            let index = try SessionIndex(
                databaseURL: root.appendingPathComponent("Index/index.sqlite")
            )
            _ = try await SessionReconciler(index: index).reconcile(
                availability: .available(library)
            )
            let manifest = try CaptureSessionManifest.load(
                from: created.directory
            )

            XCTAssertEqual(manifest.pins.map(\.id), pins.map(\.id))
            XCTAssertEqual(
                manifest.track(for: .microphone)?.startSampleOffset,
                602
            )
            XCTAssertNil(
                manifest.track(for: .system)?.startSampleOffset
            )
            XCTAssertEqual(
                manifest.track(for: .system)?.timingPrecision,
                .unavailable
            )
        }
    }

    func testManualFoldersMapToDirectoriesAndNestedSessionsReconcile()
        async throws
    {
        try await withTemporaryDirectory { root in
            let library = root.appendingPathComponent(
                "Library",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: library,
                withIntermediateDirectories: true
            )
            let manager = SessionManualFolderManager()
            let folder = try manager.createFolder(
                named: "Client: Calls",
                in: library
            )
            XCTAssertEqual(folder.name, "Client- Calls")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: folder.directory.path)
            )

            let created = try SessionFolderManager().createLiveSession(
                in: library,
                title: "Nested"
            )
            let moved = try manager.moveSession(
                at: created.directory,
                to: folder,
                in: library
            )
            let index = try SessionIndex(
                databaseURL: root.appendingPathComponent("Index/index.sqlite")
            )
            let report = try await SessionReconciler(index: index).reconcile(
                availability: .available(library)
            )

            XCTAssertEqual(report.indexedSessionCount, 1)
            let indexedSessions = try await index.sessions()
            XCTAssertEqual(
                indexedSessions.first?.directory.standardizedFileURL.path,
                moved.standardizedFileURL.path
            )
            let folders = try manager.folders(in: library)
            XCTAssertEqual(folders.map(\.name), [folder.name])
            XCTAssertEqual(
                folders.first?.directory.standardizedFileURL.path,
                folder.directory.standardizedFileURL.path
            )
        }
    }

    func testShellControlAndPaneStateDoNotCoupleCaptureToNavigation() {
        XCTAssertTrue(ScribeShellPresentation.primaryControlShowsRecording(
            captureIsStarting: false,
            captureIsRecording: true,
            captureIsStopping: false
        ))
        XCTAssertFalse(ScribeShellPresentation.shouldShowRecordingPane(
            selectedRecording: false,
            captureIsActive: true
        ))
        XCTAssertTrue(ScribeShellPresentation.shouldShowRecordingPane(
            selectedRecording: true,
            captureIsActive: true
        ))
    }

    func testShellSidebarVisibilityAndSelectionPersist() throws {
        let suiteName = "ScribeShellTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = ScribeShellPreferences(defaults: defaults)

        XCTAssertTrue(preferences.sidebarVisible)
        XCTAssertEqual(preferences.selectionID, "smart.all")
        preferences.sidebarVisible = false
        preferences.selectionID = "smart.imported"

        preferences = ScribeShellPreferences(defaults: defaults)
        XCTAssertFalse(preferences.sidebarVisible)
        XCTAssertEqual(preferences.selectionID, "smart.imported")
    }

    func testNeedsSummarySelectionIsAvailableWithSummaryGeneration() {
        XCTAssertTrue(ScribeFeatureAvailability.summaryGeneration)
        XCTAssertEqual(
            ScribeShellPresentation.resolvedSelectionID(
                "smart.needsSummary",
                summaryFeatureAvailable: false
            ),
            "smart.all"
        )
        XCTAssertEqual(
            ScribeShellPresentation.resolvedSelectionID(
                "smart.needsSummary",
                summaryFeatureAvailable: true
            ),
            "smart.needsSummary"
        )
        XCTAssertEqual(
            ScribeShellPresentation.resolvedSelectionID(
                "smart.imported",
                summaryFeatureAvailable: false
            ),
            "smart.imported"
        )
    }

    func testLibraryEmptyStateUsesFinalCopy() {
        XCTAssertEqual(
            ScribeCopy.Library.noRecordings,
            "No recordings yet"
        )
        XCTAssertEqual(ScribeCopy.Shell.sessionCount(1), "1 session")
    }

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
        async throws
    {
        try await withTemporaryDirectory { root in
            let created = try SessionFolderManager().createLiveSession(in: root)
            let segment = TranscriptSegment(
                text: "Sample text",
                startTime: 1,
                endTime: 2,
                source: .microphone,
                words: [WordTiming(text: "Sample", startTime: 1, endTime: 1.5)]
            )
            let writer = TranscriptArtifactWriter()
            let first = try await writer.write(
                segments: [segment],
                modelIdentifier: "parakeet-v3",
                to: created.directory,
                date: Date(timeIntervalSince1970: 1_000)
            )
            let second = try await writer.write(
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

    func testSpeakerRenamePersistsAcrossRetranscriptionAndLabelsExports()
        async throws
    {
        try await withTemporaryDirectory { root in
            let created = try SessionFolderManager().createLiveSession(
                in: root
            )
            let segment = TranscriptSegment(
                text: "Remote words.",
                startTime: 1,
                endTime: 2,
                source: .system,
                words: [
                    WordTiming(
                        text: "Remote",
                        startTime: 1,
                        endTime: 1.4
                    ),
                    WordTiming(
                        text: "words.",
                        startTime: 1.5,
                        endTime: 2
                    )
                ]
            )
            let writer = TranscriptArtifactWriter()
            _ = try await writer.write(
                segments: [segment],
                modelIdentifier: "first-model",
                to: created.directory
            )
            _ = try await SpeakerIdentityStore().renameSpeaker(
                identifiedBy: "source.system",
                to: "Maria",
                in: created.directory
            )

            _ = try await writer.write(
                segments: [segment],
                modelIdentifier: "second-model",
                to: created.directory
            )

            let manifest = try CaptureSessionManifest.load(
                from: created.directory
            )
            let speaker = try XCTUnwrap(
                manifest.speakerIdentity(identifiedBy: "source.system")
            )
            XCTAssertEqual(speaker.displayName, "Maria")
            XCTAssertEqual(speaker.nameAssignment, .userAssigned)
            XCTAssertEqual(manifest.transcriptionHistory.count, 2)
            let markdown = try String(
                contentsOf: created.directory.appendingPathComponent(
                    "transcript.md"
                ),
                encoding: .utf8
            )
            XCTAssertTrue(markdown.contains("**Maria · 00:01**"))
            XCTAssertFalse(markdown.contains("**Others ·"))
            let json = try String(
                contentsOf: created.directory.appendingPathComponent(
                    "transcript.json"
                ),
                encoding: .utf8
            )
            XCTAssertTrue(json.contains(
                "\"speakerID\" : \"source.system\""
            ))
        }
    }

    func testTranscriptMarkdownUsesSharedParagraphBoundaries() async throws {
        try await withTemporaryDirectory { root in
            let created = try SessionFolderManager().createLiveSession(
                in: root
            )
            let segment = TranscriptSegment(
                text: "First sentence. Second sentence.",
                startTime: 0,
                endTime: 2,
                source: .microphone,
                words: [
                    WordTiming(
                        text: "First",
                        startTime: 0,
                        endTime: 0.2
                    ),
                    WordTiming(
                        text: "sentence.",
                        startTime: 0.2,
                        endTime: 0.5
                    ),
                    WordTiming(
                        text: "Second",
                        startTime: 1.1,
                        endTime: 1.4
                    ),
                    WordTiming(
                        text: "sentence.",
                        startTime: 1.4,
                        endTime: 2
                    )
                ]
            )

            _ = try await TranscriptArtifactWriter().write(
                segments: [segment],
                modelIdentifier: "test",
                to: created.directory
            )
            let markdown = try String(
                contentsOf: created.directory.appendingPathComponent(
                    "transcript.md"
                ),
                encoding: .utf8
            )
            XCTAssertEqual(
                markdown.components(separatedBy: "**You ·").count - 1,
                2
            )
            XCTAssertTrue(markdown.contains("**You · 00:00**"))
            XCTAssertTrue(markdown.contains("**You · 00:01**"))
        }
    }

    func testLiveTranscriptionWritesSameArtifactSetAsBatch() async throws {
        try await withTemporaryDirectory { root in
            let folderManager = SessionFolderManager()
            let batchSession = try folderManager.createLiveSession(
                in: root,
                title: "Batch",
                date: Date(timeIntervalSince1970: 1_000)
            )
            let liveSession = try folderManager.createLiveSession(
                in: root,
                title: "Live",
                date: Date(timeIntervalSince1970: 2_000)
            )
            let segments = [
                TranscriptSegment(
                    text: "Local words",
                    startTime: 1,
                    endTime: 2,
                    source: .microphone
                ),
                TranscriptSegment(
                    text: "Remote words",
                    startTime: 2.5,
                    endTime: 3.5,
                    source: .system
                )
            ]
            let liveRows = segments.enumerated().map { index, segment in
                LiveTranscriptRow(
                    source: segment.source,
                    speechSegmentIndex: UInt64(index),
                    segment: segment,
                    isFinal: true
                )
            }
            let writer = TranscriptArtifactWriter()

            let batchResult = try await writer.write(
                segments: segments,
                modelIdentifier: "parakeet-v3",
                to: batchSession.directory
            )
            let liveResult = try await writer.write(
                liveRows: liveRows,
                modelIdentifier: "parakeet-v3",
                to: liveSession.directory
            )

            let batchManifest = try CaptureSessionManifest.load(
                from: batchSession.directory
            )
            let liveManifest = try CaptureSessionManifest.load(
                from: liveSession.directory
            )
            let artifactDescription:
                (CaptureSessionManifest.Artifact) -> String = {
                    "\($0.relativePath):\($0.kind.rawValue)"
                }
            let liveArtifactDescriptions = Set(
                liveManifest.artifacts.map(artifactDescription)
            )
            XCTAssertEqual(
                Set(batchManifest.artifacts.map(artifactDescription)),
                liveArtifactDescriptions
            )
            XCTAssertTrue(liveArtifactDescriptions.contains(
                "transcript.md:transcriptMarkdown"
            ))
            XCTAssertTrue(liveArtifactDescriptions.contains(
                "transcript.json:transcriptJSON"
            ))
            XCTAssertTrue(liveArtifactDescriptions.contains(
                "transcript.srt:subtitles"
            ))
            XCTAssertEqual(batchManifest.transcriptionHistory.count, 1)
            XCTAssertEqual(liveManifest.transcriptionHistory.count, 1)
            XCTAssertEqual(
                Set(liveResult.currentFiles.map(\.lastPathComponent)),
                ["transcript.md", "transcript.json", "transcript.srt"]
            )
            XCTAssertEqual(
                try batchResult.currentFiles.map { try Data(contentsOf: $0) },
                try liveResult.currentFiles.map { try Data(contentsOf: $0) }
            )
        }
    }

    func testImportedTranscriptOmitsLiveSourceLabels() async throws {
        try await withTemporaryDirectory { root in
            let created = try SessionFolderManager().createImportedSession(
                in: root,
                title: "Lecture",
                originalFilename: "lecture.m4a",
                originalFormat: "m4a",
                originalRelativePath: "lecture.m4a"
            )
            _ = try await TranscriptArtifactWriter().write(
                segments: [
                    TranscriptSegment(
                        text: "Imported words",
                        startTime: 1,
                        endTime: 2,
                        source: .imported
                    )
                ],
                modelIdentifier: "test",
                to: created.directory
            )

            let markdown = try String(
                contentsOf: created.directory.appendingPathComponent(
                    "transcript.md"
                ),
                encoding: .utf8
            )
            XCTAssertTrue(markdown.contains("**00:01**"))
            XCTAssertFalse(markdown.contains("You"))
            XCTAssertFalse(markdown.contains("Others"))
            let json = try String(
                contentsOf: created.directory.appendingPathComponent(
                    "transcript.json"
                ),
                encoding: .utf8
            )
            XCTAssertTrue(json.contains("\"source\" : \"imported\""))
        }
    }

    func testCanonicalNamedImportKeepsOriginalIntactAndCreatesDerivative()
        async throws
    {
        try await withTemporaryDirectory { root in
            let sourceDirectory = root.appendingPathComponent("Source")
            let library = root.appendingPathComponent("Library")
            try FileManager.default.createDirectory(
                at: sourceDirectory,
                withIntermediateDirectories: true
            )
            let source = sourceDirectory.appendingPathComponent("audio.wav")
            let writer = try Int16WAVWriter(url: source)
            try await writer.append(
                (0..<1_600).map { index in
                    sin(Float(index) * 2 * .pi * 440 / 16_000) * 0.5
                }
            )
            try await writer.finish()
            let original = try Data(contentsOf: source)

            let imported = try await SessionMediaImporter().importFile(
                at: source,
                into: library,
                date: Date(timeIntervalSince1970: 1_735_732_800)
            )

            XCTAssertEqual(
                imported.originalURL.lastPathComponent,
                "audio.wav"
            )
            XCTAssertEqual(
                imported.originalURL.deletingLastPathComponent()
                    .lastPathComponent,
                "Original"
            )
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(try Data(contentsOf: imported.originalURL), original)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: imported.canonicalAudioURL.path
                )
            )
            let manifest = try CaptureSessionManifest.load(
                from: imported.directory
            )
            XCTAssertEqual(manifest.source, .importedFile)
            XCTAssertEqual(manifest.title, "audio")
            XCTAssertEqual(manifest.originalFilename, "audio.wav")
            XCTAssertEqual(manifest.originalFormat, "wav")
            XCTAssertEqual(manifest.tracks.map(\.source), [.imported])
            XCTAssertEqual(manifest.tracks.count, 1)
            XCTAssertEqual(manifest.artifacts.count, 2)

            let index = try SessionIndex(
                databaseURL: root.appendingPathComponent("Index/index.sqlite")
            )
            _ = try await SessionReconciler(index: index).reconcile(
                availability: .available(library)
            )
            let reconciled = try CaptureSessionManifest.load(
                from: imported.directory
            )
            XCTAssertEqual(
                reconciled.artifacts.first {
                    $0.relativePath == "Original/audio.wav"
                }?.kind,
                .originalImport
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

    func testAllInPlaceManifestWritersPreserveIndependentFields()
        async throws
    {
        try await withTemporaryDirectory { root in
            let created = try SessionFolderManager().createLiveSession(
                in: root,
                title: "Original"
            )
            let staleArtifacts = created.manifest.artifacts
            let pin = CaptureSessionManifest.Pin(sampleOffset: 4_800)
            try await CaptureSessionManifestStore.shared.appendPin(
                pin,
                in: created.directory
            )
            _ = try await SpeakerIdentityStore().renameSpeaker(
                identifiedBy: "source.system",
                to: "Maria",
                in: created.directory
            )
            _ = try await TranscriptArtifactWriter().write(
                segments: [
                    TranscriptSegment(
                        text: "A durable transcript.",
                        startTime: 1,
                        endTime: 2,
                        source: .system
                    )
                ],
                modelIdentifier: "test",
                to: created.directory
            )
            _ = try await SummaryArtifactWriter().write(
                summary: "A durable summary.",
                providerIdentifier: "mock",
                providerDisplayName: "Mock",
                modelIdentifier: "mock-model",
                templateIdentifier: "mock-template",
                templateName: "Mock template",
                to: created.directory
            )

            let reconciledArtifacts = staleArtifacts + [
                .init(relativePath: "notes.md", kind: .notes),
                .init(
                    relativePath: "transcript.md",
                    kind: .transcriptMarkdown
                ),
                .init(relativePath: "transcript.json", kind: .transcriptJSON),
                .init(relativePath: "transcript.srt", kind: .subtitles),
                .init(relativePath: "summary.md", kind: .summary)
            ]
            _ = try await CaptureSessionManifestStore.shared.replaceArtifacts(
                reconciledArtifacts,
                in: created.directory
            )

            let manifest = try CaptureSessionManifest.load(
                from: created.directory
            )
            XCTAssertEqual(manifest.pins.map(\.id), [pin.id])
            XCTAssertEqual(
                manifest.speakerIdentity(identifiedBy: "source.system")?
                    .displayName,
                "Maria"
            )
            XCTAssertEqual(manifest.transcriptionHistory.count, 1)
            XCTAssertEqual(manifest.summaryHistory.count, 1)
            XCTAssertTrue(manifest.artifacts.contains {
                $0.relativePath == "transcript.json"
            })
        }
    }

    func testReconciliationKeepsSummaryRevisionAsSummaryArtifact()
        async throws
    {
        try await withTemporaryDirectory { root in
            let created = try SessionFolderManager().createLiveSession(
                in: root,
                title: "Summary revision"
            )
            let result = try await SummaryArtifactWriter().write(
                summary: "Durable output.",
                providerIdentifier: "mock",
                providerDisplayName: "Mock",
                modelIdentifier: "mock-model",
                templateIdentifier: "mock-template",
                templateName: "Mock template",
                to: created.directory
            )
            let index = try SessionIndex(
                databaseURL: root.appendingPathComponent("Index/index.sqlite")
            )
            _ = try await SessionReconciler(index: index).reconcile(
                availability: .available(root)
            )

            let manifest = try CaptureSessionManifest.load(
                from: created.directory
            )
            let relativeRevision = try XCTUnwrap(
                result.revision.artifacts.first
            )
            XCTAssertEqual(manifest.summaryHistory, [result.revision])
            XCTAssertEqual(
                manifest.artifacts.first(where: {
                    $0.relativePath == relativeRevision
                })?.kind,
                .summary
            )
        }
    }

    func testLibraryGroupsSessionsNewestFirstWithinNewestDateFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let presentation = SessionLibraryPresentation(calendar: calendar)
        let dayOne = Date(timeIntervalSince1970: 86_400)
        let dayTwo = Date(timeIntervalSince1970: 172_800)
        let items = [
            libraryItem(title: "Earlier", date: dayOne.addingTimeInterval(100)),
            libraryItem(title: "Newest", date: dayTwo.addingTimeInterval(500)),
            libraryItem(title: "Later", date: dayOne.addingTimeInterval(500))
        ]

        let groups = presentation.dateGroups(from: items)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].sessions.map(\.title), ["Newest"])
        XCTAssertEqual(
            groups[1].sessions.map(\.title),
            ["Later", "Earlier"]
        )
    }

    func testArtifactPresenceCoversEveryIconCombination() {
        let definitions: [(String, CaptureSessionManifest.ArtifactKind)] = [
            ("notes.md", .notes),
            ("transcript.json", .transcriptJSON),
            ("summary.md", .summary),
            ("microphone.wav", .audio)
        ]
        for mask in 0..<16 {
            let artifacts = definitions.enumerated().compactMap {
                index, definition in
                mask & (1 << index) == 0
                    ? nil
                    : CaptureSessionManifest.Artifact(
                        relativePath: definition.0,
                        kind: definition.1
                    )
            }
            let presence = SessionArtifactPresence(artifacts: artifacts)
            XCTAssertEqual(presence.notes, mask & 1 != 0)
            XCTAssertEqual(presence.transcript, mask & 2 != 0)
            XCTAssertEqual(presence.summary, mask & 4 != 0)
            XCTAssertEqual(presence.audio, mask & 8 != 0)
        }
        XCTAssertFalse(SessionArtifactPresence(artifacts: [
            .init(
                relativePath: "Transcriptions/earlier/transcript.json",
                kind: .transcriptJSON
            )
        ]).transcript)
    }

    func testSearchGroupsHitsBySessionAndCarriesTranscriptTimecodes()
        throws
    {
        try withTemporaryDirectory { root in
            let directory = root.appendingPathComponent("Search")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let transcript = """
                [
                  {"text":"Budget review starts here","startTime":12.5},
                  {"text":"Unrelated words","startTime":20},
                  {"text":"Budget approval follows","startTime":33.25}
                ]
                """
            try Data(transcript.utf8).write(
                to: directory.appendingPathComponent("transcript.json")
            )
            try Data("Budget notes\nAnother line".utf8).write(
                to: directory.appendingPathComponent("notes.md")
            )
            let session = SessionLibraryItem(
                id: UUID(),
                title: "Planning",
                createdAt: Date(),
                directory: directory,
                source: .liveCapture,
                duration: 40,
                speakerCount: 2,
                artifacts: .none,
                byteCount: 0,
                isAvailable: true
            )

            let groups = SessionLibraryPresentation().searchGroups(
                query: "budget",
                sessions: [session]
            )

            XCTAssertEqual(groups.count, 1)
            XCTAssertEqual(groups[0].hits.count, 3)
            XCTAssertEqual(
                groups[0].hits.compactMap(\.startTime),
                [12.5, 33.25]
            )
            let timedHit = try XCTUnwrap(
                groups[0].hits.first { $0.startTime == 33.25 }
            )
            XCTAssertEqual(
                SessionLibraryNavigationTarget(
                    group: groups[0],
                    hit: timedHit
                ),
                SessionLibraryNavigationTarget(
                    sessionID: session.id,
                    startTime: 33.25
                )
            )
        }
    }

    func testLibraryMetadataUsesWAVPayloadOffsetsAndLiveSpeakerCount()
        async throws
    {
        try await withTemporaryDirectory { root in
            let library = root.appendingPathComponent("Library")
            let created = try SessionFolderManager().createLiveSession(
                in: library,
                title: "Timing"
            )
            let microphone = try Int16WAVWriter(
                url: created.directory.appendingPathComponent("microphone.wav")
            )
            try await microphone.append(Array(repeating: 0, count: 32_000))
            try await microphone.finish()
            let system = try Int16WAVWriter(
                url: created.directory.appendingPathComponent("system.wav")
            )
            try await system.append(Array(repeating: 0, count: 16_000))
            try await system.finish()
            try await CaptureSessionManifestStore.shared.replaceTrackOffsets(
                microphone: 0,
                system: 16_000,
                in: created.directory
            )
            let index = try SessionIndex(
                databaseURL: root.appendingPathComponent("Index/index.sqlite")
            )
            _ = try await SessionReconciler(index: index).reconcile(
                availability: .available(library)
            )
            let indexed = try await index.sessions()

            let item = try XCTUnwrap(
                SessionLibraryPresentation().items(from: indexed).first
            )
            XCTAssertEqual(item.duration, 2, accuracy: 0.000_001)
            XCTAssertEqual(item.speakerCount, 2)
            XCTAssertTrue(item.artifacts.notes)
            XCTAssertTrue(item.artifacts.audio)
            XCTAssertGreaterThan(item.byteCount, 96_000)
        }
    }

    func testSessionRenameMovesFolderAndPreservesManifestData() async throws {
        try await withTemporaryDirectory { root in
            let created = try SessionFolderManager().createLiveSession(
                in: root,
                title: "Before",
                date: Date(timeIntervalSince1970: 1_000)
            )
            let pin = CaptureSessionManifest.Pin(sampleOffset: 2_000)
            try await CaptureSessionManifestStore.shared.appendPin(
                pin,
                in: created.directory
            )
            let indexed = IndexedSession(
                id: created.manifest.sessionID,
                title: created.manifest.title,
                createdAt: created.manifest.createdAt,
                directory: created.directory,
                source: created.manifest.source.rawValue,
                isAvailable: true
            )
            let item = try XCTUnwrap(
                SessionLibraryPresentation().items(from: [indexed]).first
            )

            let renamed = try await SessionLibraryOperations().rename(
                session: item,
                to: "After: Review"
            )

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: created.directory.path)
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
            XCTAssertTrue(renamed.lastPathComponent.hasSuffix("— After- Review"))
            let manifest = try CaptureSessionManifest.load(from: renamed)
            XCTAssertEqual(manifest.title, "After- Review")
            XCTAssertEqual(manifest.pins.map(\.id), [pin.id])
        }
    }

    func testSessionRemovalMovesCompleteFolderThroughRecoverableTrash()
        throws
    {
        try withTemporaryDirectory { root in
            let created = try SessionFolderManager().createLiveSession(
                in: root,
                title: "Trash me"
            )
            try Data("keep".utf8).write(
                to: created.directory.appendingPathComponent("agenda.pdf")
            )
            let indexed = IndexedSession(
                id: created.manifest.sessionID,
                title: created.manifest.title,
                createdAt: created.manifest.createdAt,
                directory: created.directory,
                source: created.manifest.source.rawValue,
                isAvailable: true
            )
            let item = try XCTUnwrap(
                SessionLibraryPresentation().items(from: [indexed]).first
            )
            let trashDirectory = root.appendingPathComponent(".Trash")
            let operations = SessionLibraryOperations(
                trash: SessionFolderTrash { directory in
                    try FileManager.default.createDirectory(
                        at: trashDirectory,
                        withIntermediateDirectories: true
                    )
                    let destination = trashDirectory.appendingPathComponent(
                        directory.lastPathComponent
                    )
                    try FileManager.default.moveItem(
                        at: directory,
                        to: destination
                    )
                    return destination
                }
            )

            let trashed = try operations.moveToTrash(session: item)

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: created.directory.path)
            )
            XCTAssertEqual(
                try String(
                    contentsOf: trashed.appendingPathComponent("agenda.pdf"),
                    encoding: .utf8
                ),
                "keep"
            )
            XCTAssertNoThrow(try CaptureSessionManifest.load(from: trashed))
        }
    }

    func testFTSSearchScopesToNotesAndTranscriptNotSummary() async throws {
        try await withTemporaryDirectory { root in
            let index = try SessionIndex(
                databaseURL: root.appendingPathComponent("Index/index.sqlite")
            )
            let session = IndexedSession(
                id: UUID(),
                title: "Search scope",
                createdAt: Date(),
                directory: root,
                source: "liveCapture",
                isAvailable: true
            )
            try await index.replace(
                session: session,
                artifacts: [],
                transcript: "transcript needle",
                notes: "notes marker",
                summary: "summary secret"
            )

            let transcriptMatches = try await index.search("needle")
            let notesMatches = try await index.search("marker")
            let summaryMatches = try await index.search("secret")
            XCTAssertEqual(transcriptMatches.map(\.id), [session.id])
            XCTAssertEqual(notesMatches.map(\.id), [session.id])
            XCTAssertTrue(summaryMatches.isEmpty)
        }
    }

    func testReadingPresentationBuildsIsolatedArtifactsAndRevisionRail()
        async throws
    {
        try await withTemporaryDirectory { root in
            let created = try SessionFolderManager().createLiveSession(
                in: root,
                title: "Reader"
            )
            try Data("private notes".utf8).write(
                to: created.directory.appendingPathComponent("notes.md")
            )
            _ = try await TranscriptArtifactWriter().write(
                segments: [
                    TranscriptSegment(
                        text: "A transcript sentence.",
                        startTime: 0,
                        endTime: 12.5,
                        source: .microphone,
                        words: [
                            WordTiming(
                                text: "A transcript sentence.",
                                startTime: 0,
                                endTime: 12.5
                            )
                        ]
                    )
                ],
                modelIdentifier: "parakeet-v3",
                to: created.directory,
                date: Date(timeIntervalSince1970: 10)
            )

            let document = try SessionReadingPresentation().load(
                from: created.directory
            )
            let notes = try XCTUnwrap(
                document.artifacts.first { $0.kind == .notes }
            )
            let transcript = try XCTUnwrap(
                document.artifacts.first { $0.kind == .transcript }
            )
            let revision = try XCTUnwrap(
                document.artifacts.first {
                    $0.kind == .transcriptionRevision
                }
            )

            XCTAssertEqual(notes.copyText, "private notes")
            XCTAssertTrue(transcript.copyText?.contains(
                "A transcript sentence."
            ) == true)
            XCTAssertFalse(transcript.copyText?.contains("private notes") == true)
            XCTAssertEqual(transcript.urls.count, 3)
            XCTAssertEqual(revision.urls.count, 3)
            XCTAssertEqual(document.preferredArtifactID, "transcript")
        }
    }

    func testReadingPresentationHandlesLiveAndBatchTranscriptShapes()
        async throws
    {
        try await withTemporaryDirectory { root in
            let created = try SessionFolderManager().createLiveSession(
                in: root,
                title: "Shapes"
            )
            let segments = [
                TranscriptSegment(
                    text: "Live-sized row.",
                    startTime: 0,
                    endTime: 29.6,
                    source: .microphone
                ),
                TranscriptSegment(
                    text: "Batch-sized row.",
                    startTime: 30,
                    endTime: 42.5,
                    source: .system
                )
            ]
            _ = try await TranscriptArtifactWriter().write(
                segments: segments,
                modelIdentifier: "shape-test",
                to: created.directory
            )

            let document = try SessionReadingPresentation().load(
                from: created.directory
            )

            XCTAssertEqual(document.currentSegments.count, 2)
            XCTAssertEqual(
                document.currentSegments[0].endTime
                    - document.currentSegments[0].startTime,
                29.6,
                accuracy: 0.000_001
            )
            XCTAssertEqual(
                document.currentSegments[1].endTime
                    - document.currentSegments[1].startTime,
                12.5,
                accuracy: 0.000_001
            )
            XCTAssertEqual(document.currentParagraphs.count, 2)
        }
    }

    func testReadingTimelineIncludesPinsTalkTimeAndDirectionIndependentSeek()
        async throws
    {
        try await withTemporaryDirectory { root in
            let created = try SessionFolderManager().createLiveSession(
                in: root,
                title: "Timeline"
            )
            try await CaptureSessionManifestStore.shared.appendPin(
                CaptureSessionManifest.Pin(sampleOffset: 80_000),
                in: created.directory
            )
            _ = try await TranscriptArtifactWriter().write(
                segments: [
                    TranscriptSegment(
                        text: "You",
                        startTime: 2,
                        endTime: 7,
                        source: .microphone
                    ),
                    TranscriptSegment(
                        text: "Others",
                        startTime: 4,
                        endTime: 7.5,
                        source: .system
                    )
                ],
                modelIdentifier: "timeline-test",
                to: created.directory
            )

            let document = try SessionReadingPresentation().load(
                from: created.directory
            )
            XCTAssertEqual(document.manifest.pins.first?.sampleOffset, 80_000)
            XCTAssertEqual(document.timelineLanes.count, 2)
            XCTAssertEqual(
                document.timelineLanes.first(where: {
                    $0.source == .microphone
                })?.talkTime,
                5
            )
            XCTAssertEqual(
                SessionReadingPresentation.playbackTime(
                    timelineTime: 4,
                    trackStartTime: 2,
                    trackDuration: 8
                ),
                2
            )
            XCTAssertNil(SessionReadingPresentation.playbackTime(
                timelineTime: 1,
                trackStartTime: 2,
                trackDuration: 8
            ))
        }
    }

    func testReadingPresentationKeepsSpeakerRenameAcrossRetranscription()
        async throws
    {
        try await withTemporaryDirectory { root in
            let created = try SessionFolderManager().createLiveSession(
                in: root,
                title: "Rename"
            )
            _ = try await SpeakerIdentityStore().renameSpeaker(
                identifiedBy: "source.system",
                to: "Alex",
                in: created.directory
            )
            _ = try await TranscriptArtifactWriter().write(
                segments: [
                    TranscriptSegment(
                        text: "Still Alex",
                        startTime: 0,
                        endTime: 3,
                        source: .system
                    )
                ],
                modelIdentifier: "new-model",
                to: created.directory
            )

            let document = try SessionReadingPresentation().load(
                from: created.directory
            )
            XCTAssertEqual(
                document.manifest.speakerIdentity(
                    identifiedBy: "source.system"
                )?.displayName,
                "Alex"
            )
            XCTAssertEqual(
                document.currentSegments.first?.speakerID,
                "source.system"
            )
        }
    }

    func testReadingPresentationRepresentsMissingArtifactsHonestly() throws {
        try withTemporaryDirectory { root in
            let created = try SessionFolderManager().createLiveSession(
                in: root,
                title: "Empty"
            )
            let document = try SessionReadingPresentation().load(
                from: created.directory
            )

            XCTAssertTrue(document.currentParagraphs.isEmpty)
            XCTAssertEqual(document.preferredArtifactID, "notes")
            XCTAssertTrue(document.artifacts[0].isPresent)
            XCTAssertTrue(document.artifacts[1...3].allSatisfy {
                !$0.isPresent
            })
        }
    }

    func testCreateNotesActivatesEditorAndPersistsEdits() async throws {
        try await withTemporaryDirectory { root in
            let session = try SessionFolderManager().createLiveSession(
                in: root,
                title: "Editable notes"
            )
            let initial = try SessionReadingPresentation().load(
                from: session.directory
            )
            let initialText = initial.artifacts.first(where: {
                $0.kind == .notes
            })?.copyText ?? ""
            var state = SessionNotesEditingState(text: initialText)

            XCTAssertFalse(state.isEditing)
            state.beginEditing()
            XCTAssertTrue(state.isEditing)

            let text = "Follow up with the design team."
            state.updateText(text)
            try await SessionNotesFileWriter().write(
                state.text,
                to: session.directory.appendingPathComponent("notes.md"),
                revision: 1
            )

            XCTAssertEqual(
                try SessionReadingPresentation().load(from: session.directory)
                    .artifacts.first(where: { $0.kind == .notes })?.copyText,
                text
            )
        }
    }

    private func libraryItem(title: String, date: Date) -> SessionLibraryItem {
        SessionLibraryItem(
            id: UUID(),
            title: title,
            createdAt: date,
            directory: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)"),
            source: .liveCapture,
            duration: 0,
            speakerCount: 2,
            artifacts: .none,
            byteCount: 0,
            isAvailable: true
        )
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
