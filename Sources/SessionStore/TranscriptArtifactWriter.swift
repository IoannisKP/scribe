import AudioCapture
import Foundation
import SpeechPipeline

public struct TranscriptArtifactWriteResult: Equatable, Sendable {
    public let currentFiles: [URL]
    public let revisionFiles: [URL]
    public let revision: CaptureSessionManifest.TranscriptionRevision
}

public struct TranscriptArtifactWriter: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func write(
        segments: [TranscriptSegment],
        modelIdentifier: String,
        to sessionDirectory: URL,
        date: Date = Date()
    ) throws -> TranscriptArtifactWriteResult {
        var manifest = try CaptureSessionManifest.load(from: sessionDirectory)
        let revisionID = UUID()
        let revisionDirectory = sessionDirectory
            .appendingPathComponent("Transcriptions", isDirectory: true)
            .appendingPathComponent(
                revisionDirectoryName(
                    date: date,
                    modelIdentifier: modelIdentifier,
                    id: revisionID
                ),
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: revisionDirectory,
            withIntermediateDirectories: true
        )

        let payloads = try makePayloads(segments: segments)
        let names = ["transcript.md", "transcript.json", "transcript.srt"]
        var revisionFiles: [URL] = []
        var currentFiles: [URL] = []
        do {
            for (name, data) in zip(names, payloads) {
                let revisionURL = revisionDirectory.appendingPathComponent(name)
                try data.write(to: revisionURL, options: .atomic)
                revisionFiles.append(revisionURL)

                let currentURL = sessionDirectory.appendingPathComponent(name)
                try data.write(to: currentURL, options: .atomic)
                currentFiles.append(currentURL)
            }
            let relativeRevisionFiles = revisionFiles.map {
                String($0.path.dropFirst(sessionDirectory.path.count + 1))
            }
            let revision = CaptureSessionManifest.TranscriptionRevision(
                id: revisionID,
                modelIdentifier: modelIdentifier,
                createdAt: Date(
                    timeIntervalSince1970: floor(date.timeIntervalSince1970)
                ),
                artifacts: relativeRevisionFiles
            )
            manifest = manifest.replacing(
                transcriptionHistory: manifest.transcriptionHistory + [revision]
            )
            try manifest.write(to: sessionDirectory)
            return TranscriptArtifactWriteResult(
                currentFiles: currentFiles,
                revisionFiles: revisionFiles,
                revision: revision
            )
        } catch {
            try? fileManager.removeItem(at: revisionDirectory)
            throw error
        }
    }

    private func revisionDirectoryName(
        date: Date,
        modelIdentifier: String,
        id: UUID
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safeModel = modelIdentifier
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "\(formatter.string(from: date)) — \(String(safeModel)) — \(id.uuidString.prefix(8))"
    }

    private func makePayloads(
        segments: [TranscriptSegment]
    ) throws -> [Data] {
        let ordered = TranscriptTimeline.merge(segments)
        let markdown = ordered.map { segment in
            let label = segment.source == .microphone ? "You" : "Others"
            return "**\(label) · \(Self.markdownTime(segment.startTime))**\n\n\(segment.text)"
        }.joined(separator: "\n\n") + (ordered.isEmpty ? "" : "\n")

        let jsonRows = ordered.map(TranscriptJSONSegment.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(jsonRows)

        let srt = ordered.enumerated().map { index, segment in
            """
            \(index + 1)
            \(Self.srtTime(segment.startTime)) --> \(Self.srtTime(segment.endTime))
            \(segment.text)
            """
        }.joined(separator: "\n\n") + (ordered.isEmpty ? "" : "\n")

        return [Data(markdown.utf8), json, Data(srt.utf8)]
    }

    private static func markdownTime(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private static func srtTime(_ interval: TimeInterval) -> String {
        let milliseconds = max(0, Int((interval * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(
            format: "%02d:%02d:%02d,%03d",
            hours,
            minutes,
            seconds,
            remainder
        )
    }
}

private struct TranscriptJSONSegment: Encodable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let source: String
    let speakerID: String?
    let confidence: Float?
    let words: [TranscriptJSONWord]?

    init(_ segment: TranscriptSegment) {
        text = segment.text
        startTime = segment.startTime
        endTime = segment.endTime
        source = segment.source.rawValue
        speakerID = segment.speakerID
        confidence = segment.confidence
        words = segment.words?.map(TranscriptJSONWord.init)
    }
}

private struct TranscriptJSONWord: Encodable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Float?

    init(_ word: WordTiming) {
        text = word.text
        startTime = word.startTime
        endTime = word.endTime
        confidence = word.confidence
    }
}
