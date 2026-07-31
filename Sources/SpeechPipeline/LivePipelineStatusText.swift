import AudioCapture
import Foundation

public enum LivePipelineStatusText {
    public static func batchTranscription(
        _ state: BatchTranscriptionState,
        hasRecording: Bool,
        isRecording: Bool,
        modelAvailable: Bool
    ) -> String {
        switch state {
        case .idle where isRecording:
            "Batch transcription is available after recording stops"
        case .idle where !hasRecording:
            "No recording is available to transcribe"
        case .idle where !modelAvailable:
            "Recording ready · download the selected Parakeet model to transcribe"
        case .idle:
            "Ready to transcribe the latest recording"
        case .preparing:
            "Loading the local model"
        case let .transcribing(processedChunkCount):
            "Transcribing locally · \(processedChunkCount) chunks processed"
        case let .finished(segmentCount):
            "Finished · \(segmentCount) transcript segments"
        case let .failed(message):
            "Failed · \(message)"
        }
    }

    public static func transport(
        _ state: LiveAudioTransportState
    ) -> String {
        switch state {
        case .idle:
            "Live feed idle"
        case .ready:
            "Live feed ready"
        case let .keepingUp(pendingSampleCount):
            "Live feed keeping up · \(duration(pendingSampleCount)) queued"
        case let .bufferingToDisk(pendingSampleCount):
            "Live audio backlog buffered safely to disk · \(duration(pendingSampleCount)) queued"
        case let .catchingUp(pendingSampleCount):
            "Live feed catching up · \(duration(pendingSampleCount)) queued"
        case let .recordingComplete(pendingSampleCount):
            "Recording complete · \(duration(pendingSampleCount)) buffered"
        case .drained:
            "Live feed stopped cleanly"
        case let .failed(message):
            "Live feed failed · \(message)"
        }
    }

    public static func speech(
        _ state: LiveSpeechPipelineState
    ) -> String {
        switch state {
        case .idle:
            "Speech detection idle"
        case .modelUnavailable:
            "Recording only · download Silero Live VAD to detect speech"
        case .preparing:
            "Loading local Silero VAD"
        case let .running(pendingWindowCount):
            "Speech detection running · \(pendingWindowCount) windows buffered"
        case let .finishing(pendingWindowCount):
            "Finishing speech detection · \(pendingWindowCount) windows buffered"
        case let .completed(pendingWindowCount):
            "Speech detection complete · \(pendingWindowCount) windows buffered"
        case let .failed(message):
            "Speech detection failed · \(message)"
        }
    }

    public static func transcription(
        _ state: LiveTranscriptionPipelineState
    ) -> String {
        switch state {
        case .idle:
            "Live transcription idle"
        case .modelUnavailable(reason: .voiceActivityModel):
            "Recording only · download Silero Live VAD to enable live text"
        case .modelUnavailable(reason: .transcriptionModel):
            "Recording and speech detection only · download the selected Parakeet model for live text"
        case .preparing:
            "Loading local Parakeet for live transcription"
        case let .running(pendingWindowCount):
            "Live transcription keeping up · \(pendingWindowCount) windows queued"
        case let .bufferingToDisk(pendingWindowCount):
            "ASR behind real time · \(pendingWindowCount) windows buffered safely to disk"
        case let .catchingUp(pendingWindowCount):
            "Live transcription catching up · \(pendingWindowCount) windows queued"
        case let .finishing(pendingWindowCount):
            "Finalizing live transcript · \(pendingWindowCount) windows queued"
        case let .completed(finalRowCount):
            "Live transcript complete · \(finalRowCount) final rows"
        case let .failed(message):
            "Live transcription failed · \(message)"
        }
    }

    private static func duration(_ sampleCount: UInt64) -> String {
        let seconds = Double(sampleCount)
            / CanonicalAudioFormat.sampleRate
        if seconds < 10 {
            return String(format: "%.1f s", seconds)
        }
        return String(format: "%.0f s", seconds)
    }
}
