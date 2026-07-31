@testable import SpeechPipeline
import XCTest

final class LivePipelineStatusTextTests: XCTestCase {
    func testIdleBatchStatusReflectsMissingRecording() {
        let text = LivePipelineStatusText.batchTranscription(
            .idle,
            hasRecording: false,
            isRecording: false,
            modelAvailable: true
        )

        XCTAssertEqual(text, "No recording is available to transcribe")
    }

    func testIdleBatchStatusReflectsMissingSelectedModel() {
        let text = LivePipelineStatusText.batchTranscription(
            .idle,
            hasRecording: true,
            isRecording: false,
            modelAvailable: false
        )

        XCTAssertTrue(text.contains("download"))
        XCTAssertTrue(text.contains("Parakeet"))
        XCTAssertFalse(text.contains("Ready to transcribe"))
    }

    func testMissingSileroStatusDoesNotBlameParakeet() {
        let text = LivePipelineStatusText.transcription(
            .modelUnavailable(reason: .voiceActivityModel)
        )

        XCTAssertTrue(text.contains("Silero Live VAD"))
        XCTAssertFalse(text.contains("Parakeet"))
    }

    func testMissingParakeetStatusSaysSpeechDetectionContinues() {
        let text = LivePipelineStatusText.transcription(
            .modelUnavailable(reason: .transcriptionModel)
        )

        XCTAssertTrue(text.contains("speech detection only"))
        XCTAssertTrue(text.contains("Parakeet"))
        XCTAssertFalse(text.contains("Silero"))
    }

    func testSpeechModelUnavailableNamesSilero() {
        let text = LivePipelineStatusText.speech(.modelUnavailable)

        XCTAssertTrue(text.contains("Silero Live VAD"))
        XCTAssertFalse(text.contains("Parakeet"))
    }

    func testTransportBacklogDoesNotClaimASRIsTheCause() {
        let text = LivePipelineStatusText.transport(
            .bufferingToDisk(pendingSampleCount: 16_000)
        )

        XCTAssertTrue(text.contains("Live audio backlog"))
        XCTAssertFalse(text.contains("ASR"))
        XCTAssertTrue(text.contains("1.0 s"))
    }
}
