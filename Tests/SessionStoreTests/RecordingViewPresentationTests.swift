import AudioCapture
import Foundation
import SessionStore
import SpeechPipeline
import XCTest

final class RecordingViewPresentationTests: XCTestCase {
    func testPartialAndFinalRowsKeepIdentityThroughTailRewrite() {
        let partial = liveRow(
            text: "A time step",
            endTime: 2,
            isFinal: false
        )
        let final = liveRow(
            text: "A timestamp",
            endTime: 2.2,
            isFinal: true
        )

        let partialRows = RecordingViewPresentation.transcriptRows(
            from: [partial]
        )
        let finalRows = RecordingViewPresentation.transcriptRows(
            from: [final]
        )

        XCTAssertTrue(partialRows[0].isPartial)
        XCTAssertFalse(finalRows[0].isPartial)
        XCTAssertEqual(partialRows[0].liveRowID, finalRows[0].liveRowID)
        XCTAssertEqual(partialRows[0].id, finalRows[0].id)
        XCTAssertEqual(finalRows[0].paragraph.text, "A timestamp")
    }

    func testTranscriptRowsAreContentDrivenForShortAndLongSegments() {
        let short = liveRow(
            text: "Short block",
            endTime: 12,
            isFinal: true,
            index: 1
        )
        let long = liveRow(
            text: "Long live row",
            endTime: 30,
            isFinal: true,
            index: 2
        )

        let rows = RecordingViewPresentation.transcriptRows(
            from: [short, long]
        )

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.paragraph.endTime), [12, 30])
        XCTAssertNotEqual(rows[0].id, rows[1].id)
    }

    func testParagraphingContinuesAcrossEngineWindowRows() {
        let first = liveRow(
            text: "Continuous",
            startTime: 0,
            endTime: 12,
            isFinal: true,
            index: 1,
            words: [
                WordTiming(text: "Continuous", startTime: 0, endTime: 12)
            ]
        )
        let second = liveRow(
            text: "speech",
            startTime: 12,
            endTime: 30,
            isFinal: false,
            index: 2,
            words: [
                WordTiming(text: "speech", startTime: 12, endTime: 30)
            ]
        )

        let rows = RecordingViewPresentation.transcriptRows(
            from: [second, first]
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].paragraph.text, "Continuous speech")
        XCTAssertEqual(rows[0].paragraph.startTime, 0)
        XCTAssertEqual(rows[0].paragraph.endTime, 30)
        XCTAssertEqual(rows[0].liveRowID, first.id)
        XCTAssertTrue(rows[0].isPartial)
    }

    func testWaitingDelayComesFromEngineGeometry() {
        XCTAssertEqual(
            RecordingViewPresentation.firstTextDelay(
                windowDuration: 14,
                overlap: 1.5
            ),
            16
        )
        XCTAssertEqual(
            RecordingViewPresentation.firstTextDelay(
                windowDuration: 30,
                overlap: 1.5
            ),
            32
        )
    }

    func testLevelMetersReadVADMetricsNotTranscriptionState() {
        let metrics = LiveSpeechPipelineMetrics(
            processedBlockCount: 4,
            processedSampleCount: 16_384,
            emittedSpeechSegmentCount: 0,
            emittedWindowCount: 0,
            deliveredWindowCount: 0,
            pendingWindowCount: 0,
            peakBufferedSampleCountPerSource: 8_192,
            speechProbabilities: [
                .microphone: 0.75,
                .system: 0.25
            ]
        )

        let levels = RecordingViewPresentation.levels(from: metrics)

        XCTAssertEqual(levels.microphone, 0.75, accuracy: 0.001)
        XCTAssertEqual(levels.system, 0.25, accuracy: 0.001)
    }

    func testLevelSnapshotClampsInvalidValues() {
        let levels = RecordingLevelSnapshot(
            microphone: 2,
            system: -.infinity
        )

        XCTAssertEqual(levels.microphone, 1)
        XCTAssertEqual(levels.system, 0)
    }

    func testRecordingNoticesUseRequiredCopyForEveryFailureState() {
        let base = NoticeInput()

        XCTAssertEqual(
            base.notices(
                transcription: .bufferingToDisk(pendingWindowCount: 4)
            ).sidebar?.message,
            ScribeCopy.Recording.buffering
        )
        XCTAssertEqual(
            base.notices(
                transcription: .catchingUp(pendingWindowCount: 1)
            ).sidebar?.message,
            ScribeCopy.Recording.catchingUp
        )
        XCTAssertEqual(
            base.notices(
                transcription: .modelUnavailable(
                    reason: .transcriptionModel
                )
            ).transcriptRail?.message,
            ScribeCopy.Recording.modelMissing("Parakeet v3")
        )
        XCTAssertEqual(
            base.notices(speech: .modelUnavailable)
                .transcriptRail?.message,
            ScribeCopy.Recording.sileroMissing
        )
        XCTAssertEqual(
            base.notices(
                transcription: .failed(message: "backend detail")
            ).transcriptRail,
            .modelFailed(
                displayName: "Parakeet v3",
                details: "backend detail"
            )
        )
        XCTAssertEqual(
            base.notices(systemSilent: true).sidebar?.message,
            ScribeCopy.Recording.systemTrackSilent
        )
        XCTAssertEqual(
            base.notices().transcriptRail?.message,
            ScribeCopy.Recording.waiting(firstTextSeconds: 16)
        )
    }

    func testCaptureAndTranscriptionNoticesCanCoexistOnTheirOwnSurfaces() {
        let notices = NoticeInput().notices(
            speech: .modelUnavailable,
            transcription: .bufferingToDisk(pendingWindowCount: 4),
            systemSilent: true
        )

        XCTAssertEqual(notices.sidebar, .buffering)
        XCTAssertEqual(notices.transcriptRail, .sileroMissing)
    }

    func testPreparingStateOutranksRecordingNotices() {
        let notices = RecordingViewPresentation.notices(
            isPreparingSystemAudio: true,
            isRecording: false,
            selectedModelDisplayName: "Whisper Large v3",
            firstTextDelay: 32,
            rowsAreEmpty: true,
            systemTrackHasBeenSilent: false,
            speechState: .idle,
            transcriptionState: .idle,
            transportState: .ready
        )

        XCTAssertEqual(notices.sidebar, .preparingSystemAudio)
        XCTAssertNil(notices.transcriptRail)
    }

    func testResizableRailConstantsPreserveSixtyFortyLayout() {
        XCTAssertEqual(
            RecordingWorkspaceLayout.notesFraction
                + RecordingWorkspaceLayout.transcriptFraction,
            1,
            accuracy: 0.001
        )
        XCTAssertLessThan(
            RecordingWorkspaceLayout.minimumTranscriptWidth,
            RecordingWorkspaceLayout.maximumTranscriptWidth
        )
        XCTAssertEqual(
            RecordingWorkspaceLayout.constrainedTranscriptWidth(
                100,
                totalWidth: 1_000
            ),
            RecordingWorkspaceLayout.minimumTranscriptWidth
        )
        XCTAssertEqual(
            RecordingWorkspaceLayout.constrainedTranscriptWidth(
                900,
                totalWidth: 1_000
            ),
            RecordingWorkspaceLayout.maximumTranscriptWidth
        )
    }

    func testRecordingLayoutPreferenceKeysPersistWidthAndCollapseState() {
        let suiteName = "RecordingViewPresentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            412.0,
            forKey: RecordingWorkspacePreferences.transcriptWidthKey
        )
        defaults.set(
            true,
            forKey: RecordingWorkspacePreferences.transcriptCollapsedKey
        )

        XCTAssertEqual(
            defaults.double(
                forKey: RecordingWorkspacePreferences.transcriptWidthKey
            ),
            412
        )
        XCTAssertTrue(
            defaults.bool(
                forKey: RecordingWorkspacePreferences
                    .transcriptCollapsedKey
            )
        )
    }

    func testTranscriptPresentationCacheDoesNotRecomputeForNotesRedraws() {
        let liveRows = (0..<120).map { index in
            liveRow(
                text: "Transcription row \(index).",
                startTime: Double(index),
                endTime: Double(index + 1),
                isFinal: true,
                index: UInt64(index)
            )
        }
        var cache = RecordingTranscriptPresentationCache()

        XCTAssertTrue(cache.update(with: liveRows))
        let revisionAfterTranscription = cache.revision
        var notes = ""
        for index in 0..<1_000 {
            notes.append(String(index % 10))
            XCTAssertFalse(cache.update(with: liveRows))
        }

        XCTAssertEqual(notes.count, 1_000)
        XCTAssertEqual(cache.revision, revisionAfterTranscription)
        XCTAssertFalse(cache.presentationRows.isEmpty)
    }

    func testSpeakerPaletteExtendsPastTwoAndIsStable() {
        let identifiers = (0..<8).map { "speaker-\($0)" }
        let first = identifiers.map {
            RecordingViewPresentation.paletteIndex(
                for: $0,
                paletteCount: 8
            )
        }
        let second = identifiers.map {
            RecordingViewPresentation.paletteIndex(
                for: $0,
                paletteCount: 8
            )
        }

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.allSatisfy { (0..<8).contains($0) })
        XCTAssertGreaterThan(Set(first).count, 2)
    }

    private func liveRow(
        text: String,
        startTime: TimeInterval = 0,
        endTime: TimeInterval,
        isFinal: Bool,
        index: UInt64 = 0,
        words: [WordTiming]? = nil
    ) -> LiveTranscriptRow {
        LiveTranscriptRow(
            source: .microphone,
            speechSegmentIndex: index,
            segment: TranscriptSegment(
                text: text,
                startTime: startTime,
                endTime: endTime,
                source: .microphone,
                speakerID: "source.microphone",
                words: words
            ),
            isFinal: isFinal
        )
    }
}

private struct NoticeInput {
    func notices(
        speech: LiveSpeechPipelineState = .running(pendingWindowCount: 0),
        transcription: LiveTranscriptionPipelineState = .running(
            pendingWindowCount: 0
        ),
        systemSilent: Bool = false
    ) -> RecordingStatusNotices {
        RecordingViewPresentation.notices(
            isPreparingSystemAudio: false,
            isRecording: true,
            selectedModelDisplayName: "Parakeet v3",
            firstTextDelay: 16,
            rowsAreEmpty: true,
            systemTrackHasBeenSilent: systemSilent,
            speechState: speech,
            transcriptionState: transcription,
            transportState: .keepingUp(pendingSampleCount: 0)
        )
    }
}
