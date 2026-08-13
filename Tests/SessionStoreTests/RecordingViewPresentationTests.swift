import AudioCapture
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
            base.notice(
                transcription: .bufferingToDisk(pendingWindowCount: 4)
            )?.message,
            ScribeCopy.Recording.buffering
        )
        XCTAssertEqual(
            base.notice(transcription: .catchingUp(pendingWindowCount: 1))?.message,
            ScribeCopy.Recording.catchingUp
        )
        XCTAssertEqual(
            base.notice(
                transcription: .modelUnavailable(
                    reason: .transcriptionModel
                )
            )?.message,
            ScribeCopy.Recording.modelMissing("Parakeet v3")
        )
        XCTAssertEqual(
            base.notice(speech: .modelUnavailable)?.message,
            ScribeCopy.Recording.sileroMissing
        )
        XCTAssertEqual(
            base.notice(
                transcription: .failed(message: "backend detail")
            ),
            .modelFailed(
                displayName: "Parakeet v3",
                details: "backend detail"
            )
        )
        XCTAssertEqual(
            base.notice(systemSilent: true)?.message,
            ScribeCopy.Recording.systemTrackSilent
        )
        XCTAssertEqual(
            base.notice()?.message,
            ScribeCopy.Recording.waiting(firstTextSeconds: 16)
        )
    }

    func testPreparingStateOutranksRecordingNotices() {
        let notice = RecordingViewPresentation.notice(
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

        XCTAssertEqual(notice, .preparingSystemAudio)
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
    func notice(
        speech: LiveSpeechPipelineState = .running(pendingWindowCount: 0),
        transcription: LiveTranscriptionPipelineState = .running(
            pendingWindowCount: 0
        ),
        systemSilent: Bool = false
    ) -> RecordingStatusNotice? {
        RecordingViewPresentation.notice(
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
