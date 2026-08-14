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

    public enum Reading {
        public static let backToSessions = "Back to sessions"
        public static let revealInFinder = "Reveal in Finder"
        public static let dragHint = "Drag any row to Finder or another app"
        public static let copyNotes = "Copy notes"
        public static let copyTranscript = "Copy transcript"
        public static let copySummary = "Copy summary"
        public static let copied = "Copied"
        public static let noNotes = "No notes yet"
        public static let createNotes = "Create notes"
        public static let notesPlaceholder = "Type notes for this session"
        public static let noTranscript = "No transcript yet"
        public static let noTranscriptDetail =
            "This session was recorded without a model installed."
        public static let transcribeNow = "Transcribe now"
        public static let transcribeAgain = "Transcribe again"
        public static let transcribeWith = "Transcribe with"
        public static let transcriptions = "Transcriptions"
        public static let noSummary = "No summary yet"
        public static let generateSummary = "Generate summary"
        public static let regenerateSummary = "Generate again"
        public static let summaries = "Summaries"
        public static let noAudio = "No playable audio is available"
        public static let play = "Play"
        public static let pause = "Pause"
        public static let playAll = "Play all"
        public static let pauseAll = "Pause all"

        public static func playTrack(_ name: String) -> String {
            "Play \(name) only"
        }

        public static func pauseTrack(_ name: String) -> String {
            "Pause \(name)"
        }
        public static let timeline = "Timeline"
        public static let talkTime = "Talk time"
        public static let renameSpeaker = "Rename speaker"
        public static let speakerName = "Speaker name"
        public static let speakerRenameFailed =
            "Couldn't rename the speaker. The transcript and recording are unaffected."
        public static let notesCreateFailed =
            "Couldn't create notes. The recording and transcript are unaffected."
        public static let notesSaveFailed =
            "Couldn't save notes. The recording and transcript are unaffected."
        public static let transcriptionFailed =
            "Transcription failed. The recording and earlier transcripts are unaffected."
        public static let sessionReadFailed =
            "Scribe couldn't read this session. Its files are untouched."

        public static func installModelBeforeTranscribing(
            _ displayName: String
        ) -> String {
            "Install \(displayName) before transcribing. The recording and earlier transcripts are unaffected."
        }

        public static func transcribing(
            modelName: String,
            estimate: String
        ) -> String {
            let sentenceEstimate = estimate.prefix(1).uppercased()
                + estimate.dropFirst()
            return "Transcribing with \(modelName). \(sentenceEstimate)."
        }

        public static func transcriptionComplete(
            preservedPath: String
        ) -> String {
            "Done. Your earlier transcript is kept as \(preservedPath)."
        }

        public static let firstTranscriptionComplete =
            "Done. Transcript files were created."

        public static func segmentCount(_ count: Int) -> String {
            count == 1 ? "1 segment" : "\(count) segments"
        }

        public static func fileCount(_ count: Int) -> String {
            count == 1 ? "1 file" : "\(count) files"
        }
    }

    public enum SummaryGeneration {
        public static let using = "Using"
        public static let provider = "Provider"
        public static let model = "Model"
        public static let template = "Template"
        public static let loadModels = "Load models"
        public static let loadingModels = "Loading models…"
        public static let prepare = "Prepare summary"
        public static let send = "Send"
        public static let cancel = "Cancel"
        public static let tryAgain = "Try again"
        public static let localDisclosure =
            "This provider runs on this Mac. Nothing leaves the machine."
        public static let cloudDisclosure =
            "The transcript and notes will leave this Mac when you confirm."
        public static let missingTranscript =
            "Transcribe this session before generating a summary. The recording and notes are unaffected."
        public static let emptyResponse =
            "The provider returned an empty summary. Your transcript, notes, recording, and earlier summary are untouched."
        public static let noPins = "No moments were marked."
        public static let noNearbyTranscript = "No nearby transcript text."
        public static let you = "You"
        public static let others = "Others"
        public static let importedAudio = "Imported audio"
        public static let systemInstruction =
            "Follow the template precisely. Use only the supplied session material. Do not invent facts, names, decisions, owners, dates, or quotations. Return Markdown only."

        public static func approximatelyTokens(_ count: Int) -> String {
            "About \(count.formatted()) tokens"
        }

        public static func estimatedMaximumCost(_ cost: String) -> String {
            "Estimated maximum cost: \(cost)"
        }

        public static func confirmTitle(provider: String) -> String {
            "Send to \(provider)?"
        }

        public static func confirmBody(
            provider: String,
            tokens: Int,
            cost: String?
        ) -> String {
            let estimate = approximatelyTokens(tokens)
            let costSentence = cost.map {
                " \(estimatedMaximumCost($0))."
            } ?? ""
            return "Your transcript and notes will be sent to \(provider). \(estimate).\(costSentence)"
        }

        public static func generatingLocally(provider: String) -> String {
            "Generating summary on this Mac with \(provider)."
        }

        public static func sending(provider: String) -> String {
            "Sending to \(provider)"
        }

        public static func failed(provider: String) -> String {
            "\(provider) didn't respond. Your transcript, notes, recording, and earlier summary are untouched."
        }

        public static func requiresChunking(
            estimatedTokens: Int,
            contextLimit: Int
        ) -> String {
            "This transcript needs about \(estimatedTokens.formatted()) input tokens, beyond this model's single-pass allowance of \(contextLimit.formatted()) tokens. Long-transcript generation is not available yet. The session files are untouched."
        }
    }

    public enum IntelligenceSettings {
        public static let title = "Summary providers"
        public static let provider = "Provider"
        public static let anthropic = "Anthropic"
        public static let openAI = "OpenAI"
        public static let deepSeek = "DeepSeek"
        public static let groq = "Groq"
        public static let ollama = "Ollama"
        public static let lmStudio = "LM Studio"
        public static let apiKey = "API key"
        public static let apiKeyPlaceholder = "Paste API key"
        public static let keychainHelper =
            "Stored in your Keychain. Never written to disk or logs."
        public static let testKey = "Test key"
        public static let testConnection = "Test connection"
        public static let testing = "Testing…"
        public static let keyWorks = "Key works"
        public static let connectionWorks = "Connection works"
        public static let noKeyProvided = "No key provided."
        public static let keyRejected =
            "That key was rejected. Check it hasn't expired."
        public static let connectionFailed =
            "Scribe couldn't reach this provider. Check its address and that it is running."
        public static let noKeyRequired =
            "No API key needed. Requests stay on this Mac."
        public static let customNoKeyRequired =
            "This provider does not require an API key."
        public static let keyStored = "A key is stored in your Keychain."
        public static let removeKey = "Remove key"
        public static let addCustomProvider = "Add custom provider"
        public static let customProvider = "Custom provider"
        public static let displayName = "Display name"
        public static let baseURL = "Base URL"
        public static let modelIdentifier = "Model identifier"
        public static let usesAPIKey = "This provider uses an API key"
        public static let saveProvider = "Save provider"
        public static let removeProvider = "Remove provider"
        public static let cancel = "Cancel"
        public static let customProviderSaved = "Provider saved"
        public static let configurationFailed =
            "Scribe couldn't save this provider configuration. No API key was written to a settings file."
        public static let missingCustomFields =
            "Enter a display name, base URL, and model identifier."
        public static let invalidProviderURL =
            "Enter a valid provider base URL without credentials, a query, or a fragment."
        public static let insecureProviderURL =
            "Remote providers must use HTTPS. HTTP is allowed only for localhost."
    }

    public enum SummaryTemplates {
        public static let title = "Summary templates"
        public static let template = "Template"
        public static let name = "Name"
        public static let instructions = "Instructions"
        public static let newTemplate = "New template"
        public static let duplicate = "Duplicate"
        public static let save = "Save template"
        public static let remove = "Remove template"
        public static let untitled = "Untitled template"
        public static let newTemplateBody = "{{transcript}}"
        public static let saved = "Template saved"
        public static let created = "Template created"
        public static let duplicated = "Template duplicated"
        public static let removed = "Template removed"
        public static let cancel = "Cancel"
        public static let loadFailed =
            "Scribe couldn't load summary templates. Sessions and their files are unaffected."
        public static let saveFailed =
            "Scribe couldn't save this template. Sessions and their files are unaffected."
        public static let removeFailed =
            "Scribe couldn't remove this template. Sessions and their files are unaffected."
        public static let variables =
            "Variables: {{notes}}, {{transcript}}, {{title}}, {{date}}, {{participants}}, {{pins}}"

        public static func duplicateName(_ name: String) -> String {
            "\(name) copy"
        }

        public static func removeTitle(_ name: String) -> String {
            "Remove “\(name)” template?"
        }

        public static let removeBody =
            "This removes the custom template. Sessions, transcripts, notes, and summaries are unaffected."
        public static let missingName = "A template name is required."
        public static let missingBody = "Template instructions are required."
        public static let notFound = "The template no longer exists."
        public static let builtInCannotBeDeleted =
            "Built-in templates cannot be deleted."
        public static let malformedVariable =
            "A template variable is incomplete or malformed."

        public static func unknownVariable(_ variable: String) -> String {
            "Unknown template variable: {{\(variable)}}."
        }

        public static let meetingSummary = "Meeting summary"
        public static let meetingSummaryBody = """
            Write a concise meeting summary for “{{title}}” on {{date}}.

            Participants:
            {{participants}}

            Notes:
            {{notes}}

            Transcript:
            {{transcript}}

            Important moments marked during the meeting:
            {{pins}}

            Explain what was discussed, what was decided, and what remains outstanding. Do not invent facts, owners, or dates.
            """

        public static let decisionsAndActions = "Decisions and actions"
        public static let decisionsAndActionsBody = """
            Extract decisions and action items from this meeting. For each decision, include its stated rationale. For each action, include its owner and date only when explicitly stated. Give marked moments extra attention, but do not invent missing information.

            Meeting: {{title}}
            Date: {{date}}
            Participants: {{participants}}
            Notes: {{notes}}
            Marked moments: {{pins}}
            Transcript: {{transcript}}
            """

        public static let interviewNotes = "Interview notes"
        public static let interviewNotesBody = """
            Produce interview notes organised by themes. Include notable quotations with their transcript timestamps when available, and finish with open questions. Treat marked moments as the interviewer's signals of importance.

            Interview: {{title}}
            Date: {{date}}
            Participants: {{participants}}
            Notes: {{notes}}
            Marked moments: {{pins}}
            Transcript: {{transcript}}
            """

        public static let oneToOne = "One-to-one"
        public static let oneToOneBody = """
            Summarise this one-to-one by topics raised, commitments made by each person, and follow-ups. Keep sensitive statements factual and do not infer motives.

            Meeting: {{title}}
            Date: {{date}}
            Participants: {{participants}}
            Notes: {{notes}}
            Marked moments: {{pins}}
            Transcript: {{transcript}}
            """

        public static let lectureOrTalk = "Lecture or talk"
        public static let lectureOrTalkBody = """
            Summarise this lecture or talk in presentation order. Capture key points, terminology introduced, examples, and references mentioned. Do not add outside information.

            Title: {{title}}
            Date: {{date}}
            Notes: {{notes}}
            Marked moments: {{pins}}
            Transcript: {{transcript}}
            """

        public static let rawCleanup = "Raw cleanup"
        public static let rawCleanupBody = """
            Clean up the transcript without interpreting or summarising it. Remove disfluencies and obvious false starts, retain every substantive statement, preserve speaker attribution, and arrange the result into readable paragraphs. Do not add facts or conclusions.

            Participants: {{participants}}
            Transcript: {{transcript}}
            """
    }
}
