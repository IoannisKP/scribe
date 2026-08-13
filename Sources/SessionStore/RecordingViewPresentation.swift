import AudioCapture
import Foundation
import SpeechPipeline

public struct RecordingTranscriptPresentationRow:
    Equatable,
    Identifiable,
    Sendable
{
    public let id: String
    public let liveRowID: String
    public let paragraph: TranscriptParagraph
    public let isPartial: Bool

    public init(
        id: String,
        liveRowID: String,
        paragraph: TranscriptParagraph,
        isPartial: Bool
    ) {
        self.id = id
        self.liveRowID = liveRowID
        self.paragraph = paragraph
        self.isPartial = isPartial
    }
}

public struct RecordingLevelSnapshot: Equatable, Sendable {
    public let microphone: Double
    public let system: Double

    public init(microphone: Double, system: Double) {
        self.microphone = Self.clamped(microphone)
        self.system = Self.clamped(system)
    }

    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public enum RecordingStatusNotice: Equatable, Sendable {
    case preparingSystemAudio
    case waiting(firstTextSeconds: Int)
    case buffering
    case catchingUp
    case systemTrackSilent
    case modelMissing(displayName: String)
    case modelFailed(displayName: String, details: String)
    case sileroMissing

    public var message: String {
        switch self {
        case .preparingSystemAudio:
            ScribeCopy.Recording.preparingSystemAudio
        case let .waiting(seconds):
            ScribeCopy.Recording.waiting(firstTextSeconds: seconds)
        case .buffering:
            ScribeCopy.Recording.buffering
        case .catchingUp:
            ScribeCopy.Recording.catchingUp
        case .systemTrackSilent:
            ScribeCopy.Recording.systemTrackSilent
        case let .modelMissing(displayName):
            ScribeCopy.Recording.modelMissing(displayName)
        case let .modelFailed(displayName, _):
            ScribeCopy.Recording.modelFailed(displayName)
        case .sileroMissing:
            ScribeCopy.Recording.sileroMissing
        }
    }
}

public enum RecordingWorkspaceLayout {
    public static let notesFraction = 0.60
    public static let transcriptFraction = 0.40
    public static let defaultTranscriptWidth: Double = 360
    public static let minimumTranscriptWidth: Double = 260
    public static let maximumTranscriptWidth: Double = 620
    public static let minimumNotesWidth: Double = 360
}

public enum RecordingViewPresentation {
    public static func transcriptRows(
        from liveRows: [LiveTranscriptRow]
    ) -> [RecordingTranscriptPresentationRow] {
        let orderedRows = liveRows.enumerated().sorted { lhs, rhs in
            let left = lhs.element.segment
            let right = rhs.element.segment
            if left.startTime != right.startTime {
                return left.startTime < right.startTime
            }
            if left.endTime != right.endTime {
                return left.endTime < right.endTime
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        let paragraphs = TranscriptParagrapher.paragraphs(
            from: orderedRows.map(\.segment)
        )
        var paragraphCountByFirstRowID: [String: Int] = [:]

        return paragraphs.map { paragraph in
            let contributors = orderedRows.filter { row in
                row.segment.source == paragraph.source
                    && row.segment.speakerID == paragraph.speakerID
                    && row.segment.endTime > paragraph.startTime
                    && row.segment.startTime < paragraph.endTime
            }
            let firstRow = contributors.first
                ?? orderedRows.first(where: { row in
                    row.segment.source == paragraph.source
                        && row.segment.speakerID == paragraph.speakerID
                })
            let firstRowID = firstRow?.id ?? paragraph.id
            let ordinal = paragraphCountByFirstRowID[firstRowID, default: 0]
            paragraphCountByFirstRowID[firstRowID] = ordinal + 1
            return RecordingTranscriptPresentationRow(
                id: "\(firstRowID):paragraph-\(ordinal)",
                liveRowID: firstRowID,
                paragraph: paragraph,
                isPartial: contributors.contains(where: { !$0.isFinal })
            )
        }
    }

    public static func firstTextDelay(
        windowDuration: TimeInterval,
        overlap: TimeInterval
    ) -> Int {
        guard
            windowDuration.isFinite,
            overlap.isFinite,
            windowDuration > 0,
            overlap >= 0
        else {
            return 0
        }
        return Int((windowDuration + overlap).rounded(.up))
    }

    public static func levels(
        from metrics: LiveSpeechPipelineMetrics
    ) -> RecordingLevelSnapshot {
        RecordingLevelSnapshot(
            microphone: Double(
                metrics.speechProbabilities[.microphone] ?? 0
            ),
            system: Double(metrics.speechProbabilities[.system] ?? 0)
        )
    }

    public static func notice(
        isPreparingSystemAudio: Bool,
        isRecording: Bool,
        selectedModelDisplayName: String,
        firstTextDelay: Int,
        rowsAreEmpty: Bool,
        systemTrackHasBeenSilent: Bool,
        speechState: LiveSpeechPipelineState,
        transcriptionState: LiveTranscriptionPipelineState,
        transportState: LiveAudioTransportState
    ) -> RecordingStatusNotice? {
        if isPreparingSystemAudio {
            return .preparingSystemAudio
        }
        guard isRecording else { return nil }

        if case .modelUnavailable = speechState {
            return .sileroMissing
        }
        switch transcriptionState {
        case let .modelUnavailable(reason):
            switch reason {
            case .voiceActivityModel:
                return .sileroMissing
            case .transcriptionModel:
                return .modelMissing(
                    displayName: selectedModelDisplayName
                )
            }
        case let .failed(message):
            return .modelFailed(
                displayName: selectedModelDisplayName,
                details: message
            )
        case .bufferingToDisk:
            return .buffering
        case .catchingUp:
            return .catchingUp
        case .idle, .preparing, .running, .finishing, .completed:
            break
        }

        switch transportState {
        case .bufferingToDisk:
            return .buffering
        case .catchingUp:
            return .catchingUp
        case .idle, .ready, .keepingUp, .recordingComplete, .drained,
            .failed:
            break
        }
        if systemTrackHasBeenSilent {
            return .systemTrackSilent
        }
        if rowsAreEmpty, firstTextDelay > 0 {
            return .waiting(firstTextSeconds: firstTextDelay)
        }
        return nil
    }

    public static func paletteIndex(
        for stableSpeakerID: String,
        paletteCount: Int
    ) -> Int {
        guard paletteCount > 0 else { return 0 }
        let value = stableSpeakerID.utf8.reduce(UInt64(5381)) {
            (($0 << 5) &+ $0) &+ UInt64($1)
        }
        return Int(value % UInt64(paletteCount))
    }
}
