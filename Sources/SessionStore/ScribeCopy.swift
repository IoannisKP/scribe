import Foundation

public enum ScribeCopy {
    public enum Shell {
        public static let newRecording = "New recording"
        public static let recording = "Recording"
        public static let importMedia = "Import audio or video…"
        public static let allSessions = "All sessions"
        public static let needsSummary = "Needs summary"
        public static let imported = "Imported"
        public static let folders = "Folders"
        public static let newFolder = "New folder"
        public static let folderName = "Folder name"
        public static let create = "Create"
        public static let cancel = "Cancel"
        public static let settings = "Settings"
        public static let search = "Search"
        public static let searchShortcut = "⌘K"
        public static let dropToImport = "Drop to import"
        public static let sessions = "Sessions"
        public static let noSummarySessions =
            "Every session has a summary"
        public static let noImportedSessions = "No imported sessions"
        public static let currentRecording = "Current recording"
        public static let invalidFolderName = "Enter a folder name."

        public static func folderAlreadyExists(_ name: String) -> String {
            "A folder named “\(name)” already exists."
        }

        public static func notASessionFolder(_ name: String) -> String {
            "“\(name)” is not a Scribe session folder."
        }

        public static let folderOutsideLibrary =
            "The destination is outside the Scribe save location."

        public static func sessionCount(_ count: Int) -> String {
            count == 1 ? "1 session" : "\(count) sessions"
        }

    }

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
        public static let pinShortcut = "⌘⇧K"
        public static let addPin = "Add pin"
        public static let pinSaveFailed =
            "Couldn't save the pin. The recording and notes are unaffected."
        public static let pinUnavailable =
            "Pins become available when captured audio starts."
        public static let pinShortcutUnavailable =
            "The pin shortcut couldn't be registered. Recording still works."

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

        public static func pinAdded(timecode: String) -> String {
            "Pin added at \(timecode)"
        }

        public static let keepRecordingWithoutTranscription =
            "Keep recording without transcription"
    }

    public enum Library {
        public static let noRecordings = "No recordings yet"
        public static let noRecordingsDetail =
            "Start one from the menu bar or press the record button above."
        public static let startRecording = "Start recording"
        public static let noSearchResults = "No matching sessions"
        public static let noSearchResultsDetail =
            "Try another word or phrase."
        public static let rename = "Rename…"
        public static let renameSession = "Rename session"
        public static let sessionTitle = "Session title"
        public static let save = "Save"
        public static let moveToTrash = "Move to Trash…"
        public static let confirmMoveToTrash = "Move to Trash"
        public static let cancel = "Cancel"
        public static let imported = "Imported"
        public static let notes = "Notes"
        public static let transcript = "Transcript"
        public static let summary = "Summary"
        public static let audio = "Audio"
        public static let session = "Session"
        public static let present = "Present"
        public static let absent = "Not present"
        public static let today = "Today"
        public static let yesterday = "Yesterday"
        public static let invalidTitle = "Enter a session title."
        public static let sessionUnavailable =
            "The session folder is unavailable. Reconnect its save location and try again."

        public static func speakerCount(_ count: Int) -> String {
            count == 1 ? "1 speaker" : "\(count) speakers"
        }

        public static func resultCount(_ count: Int) -> String {
            count == 1 ? "1 result" : "\(count) results"
        }

        public static func moveToTrashTitle(_ title: String) -> String {
            "Move “\(title)” to Trash?"
        }

        public static func moveToTrashBody(size: String) -> String {
            "The \(size) session folder moves to Trash and can be recovered there. Its audio, transcript, notes, and other artifacts move together."
        }

        public static func searchFailed(_ detail: String) -> String {
            "Scribe couldn't search sessions. Session folders are untouched: \(detail)"
        }
    }
}
