import Foundation

public enum ScribeCopy {
    public enum Recording {
        public static let notes = "Notes"
        public static let transcript = "Transcript"
        public static let start = "Start recording"
        public static let stop = "Stop recording"
        public static let you = "You"
        public static let others = "Others"
        public static let partial = "Partial"
        public static let emptyNotes = "Type while you listen"
        public static let preparingSystemAudio =
            "Preparing system audio before recording"
        public static let preparingSystemAudioButton =
            "Preparing system audio…"
        public static let systemTrackSilent =
            "Nothing plays through your Mac right now"
        public static let catchingUp =
            "Catching up on transcription. Recording is unaffected."
        public static let buffering =
            "Transcription is buffering. Recording is unaffected."
        public static let sileroMissing =
            "Live transcription needs Silero. Recording and the full "
            + "transcript afterwards work without it."
        public static let downloadSilero = "Download Silero"
        public static let downloadSelectedModel = "Download it"
        public static let chooseAnotherModel = "Choose another model"
        public static let details = "Details"
        public static let showTranscript = "Show transcript"
        public static let hideTranscript = "Hide transcript"
        public static let transcriptWidth = "Transcript width"
        public static let recordingControls = "Recording controls"
        public static let elapsedTime = "Elapsed recording time"
        public static let microphoneLevel = "You speech level"
        public static let systemAudioLevel = "Others speech level"
        public static let notesSaveFailed =
            "Couldn't save notes. The recording is unaffected."

        public static func waiting(firstTextSeconds: Int) -> String {
            "Listening. First text in about \(firstTextSeconds) seconds."
        }

        public static func modelMissing(_ displayName: String) -> String {
            "Recording without transcription. \(displayName) isn't installed."
        }

        public static func modelFailed(_ displayName: String) -> String {
            "Recording without transcription. \(displayName) couldn't load."
        }

        public static func switchOffer(_ displayName: String) -> String {
            "\(displayName) is installed and would fit. Switch to it?"
        }

        public static func switchTo(_ displayName: String) -> String {
            "Switch to \(displayName)"
        }

        public static func speechLevel(percent: Int) -> String {
            "\(percent) percent"
        }

        public static let keepRecordingWithoutTranscription =
            "Keep recording without transcription"
    }
}
