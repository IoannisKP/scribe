import AudioCapture
import Foundation
import SpeechPipeline

public enum SessionReadingArtifactKind: String, Equatable, Sendable {
    case notes
    case transcript
    case summary
    case audio
    case additional
    case transcriptionRevision
    case summaryRevision
}

public struct SummaryProvenance: Equatable, Sendable {
    public let providerDisplayName: String
    public let modelIdentifier: String?

    public init(providerDisplayName: String, modelIdentifier: String? = nil) {
        self.providerDisplayName = providerDisplayName
        self.modelIdentifier = modelIdentifier
    }
}

public struct SessionReadingArtifact: Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: SessionReadingArtifactKind
    public let title: String
    public let detail: String?
    public let urls: [URL]
    public let copyText: String?
    public let revision: CaptureSessionManifest.TranscriptionRevision?
    public let summaryRevision: CaptureSessionManifest.SummaryRevision?
    public let summaryProvenance: SummaryProvenance?

    public var isPresent: Bool { !urls.isEmpty }
    public var primaryURL: URL? { urls.first }

    public init(
        id: String,
        kind: SessionReadingArtifactKind,
        title: String,
        detail: String? = nil,
        urls: [URL],
        copyText: String? = nil,
        revision: CaptureSessionManifest.TranscriptionRevision? = nil,
        summaryRevision: CaptureSessionManifest.SummaryRevision? = nil,
        summaryProvenance: SummaryProvenance? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.urls = urls
        self.copyText = copyText
        self.revision = revision
        self.summaryRevision = summaryRevision
        self.summaryProvenance = summaryProvenance
    }
}

public struct SessionTimelineRegion: Equatable, Sendable {
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(startTime: TimeInterval, endTime: TimeInterval) {
        self.startTime = startTime
        self.endTime = endTime
    }
}

public struct SessionTimelineLane: Equatable, Identifiable, Sendable {
    public let id: String
    public let speakerID: String?
    public let source: AudioSource
    public let displayName: String?
    public let regions: [SessionTimelineRegion]
    public let talkTime: TimeInterval

    public init(
        id: String,
        speakerID: String?,
        source: AudioSource,
        displayName: String?,
        regions: [SessionTimelineRegion],
        talkTime: TimeInterval
    ) {
        self.id = id
        self.speakerID = speakerID
        self.source = source
        self.displayName = displayName
        self.regions = regions
        self.talkTime = talkTime
    }
}

public struct SessionReadingDocument: Equatable, Sendable {
    public let directory: URL
    public let manifest: CaptureSessionManifest
    public let artifacts: [SessionReadingArtifact]
    public let currentSegments: [TranscriptSegment]
    public let currentParagraphs: [TranscriptParagraph]
    public let timelineLanes: [SessionTimelineLane]
    public let duration: TimeInterval

    public var preferredArtifactID: String {
        let preference: [SessionReadingArtifactKind] = [
            .summary, .transcript, .notes, .audio, .additional
        ]
        for kind in preference {
            if let artifact = artifacts.first(where: {
                $0.kind == kind && $0.isPresent
            }) {
                return artifact.id
            }
        }
        return artifacts.first?.id ?? "notes"
    }

    public init(
        directory: URL,
        manifest: CaptureSessionManifest,
        artifacts: [SessionReadingArtifact],
        currentSegments: [TranscriptSegment],
        currentParagraphs: [TranscriptParagraph],
        timelineLanes: [SessionTimelineLane],
        duration: TimeInterval
    ) {
        self.directory = directory
        self.manifest = manifest
        self.artifacts = artifacts
        self.currentSegments = currentSegments
        self.currentParagraphs = currentParagraphs
        self.timelineLanes = timelineLanes
        self.duration = duration
    }
}

public struct SessionReadingPresentation: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func load(from directory: URL) throws -> SessionReadingDocument {
        let manifest = try CaptureSessionManifest.load(from: directory)
        let segments = try loadSegments(
            from: directory.appendingPathComponent("transcript.json")
        )
        let paragraphs = TranscriptParagrapher.paragraphs(from: segments)
        let artifacts = makeArtifacts(
            manifest: manifest,
            directory: directory,
            segmentCount: segments.count
        )
        let duration = sessionDuration(
            manifest: manifest,
            directory: directory,
            segments: segments
        )
        return SessionReadingDocument(
            directory: directory,
            manifest: manifest,
            artifacts: artifacts,
            currentSegments: segments,
            currentParagraphs: paragraphs,
            timelineLanes: makeTimelineLanes(
                segments: segments,
                manifest: manifest
            ),
            duration: duration
        )
    }

    public func paragraphs(for artifact: SessionReadingArtifact) throws
        -> [TranscriptParagraph]
    {
        guard artifact.kind == .transcriptionRevision,
            let jsonURL = artifact.urls.first(where: {
                $0.pathExtension.lowercased() == "json"
            })
        else { return [] }
        return TranscriptParagrapher.paragraphs(
            from: try loadSegments(from: jsonURL)
        )
    }

    public func loadSegments(from url: URL) throws -> [TranscriptSegment] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let rows = try JSONDecoder().decode(
            [StoredTranscriptSegment].self,
            from: Data(contentsOf: url)
        )
        return TranscriptTimeline.merge(rows.compactMap(\.segment))
    }

    public static func playbackTime(
        timelineTime: TimeInterval,
        trackStartTime: TimeInterval,
        trackDuration: TimeInterval
    ) -> TimeInterval? {
        let local = timelineTime - trackStartTime
        guard local >= 0, local <= trackDuration else { return nil }
        return local
    }

    private func makeArtifacts(
        manifest: CaptureSessionManifest,
        directory: URL,
        segmentCount: Int
    ) -> [SessionReadingArtifact] {
        func existing(_ paths: [String]) -> [URL] {
            paths.map { directory.appendingPathComponent($0) }
                .filter { fileManager.fileExists(atPath: $0.path) }
        }
        func text(at url: URL?) -> String? {
            guard let url else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }

        let notesURLs = existing(["notes.md"])
        let transcriptURLs = existing([
            "transcript.md", "transcript.json", "transcript.srt"
        ])
        let summaryURLs = existing(["summary.md"])
        let audioPaths = manifest.artifacts.filter {
            $0.kind == .audio || $0.kind == .originalImport
        }.map(\.relativePath)
        let audioURLs = existing(audioPaths)
        var result = [
            SessionReadingArtifact(
                id: "notes",
                kind: .notes,
                title: "Notes",
                urls: notesURLs,
                copyText: text(at: notesURLs.first)
            ),
            SessionReadingArtifact(
                id: "transcript",
                kind: .transcript,
                title: "Transcript",
                detail: segmentCount == 1
                    ? "1 segment" : "\(segmentCount) segments",
                urls: transcriptURLs,
                copyText: text(at: transcriptURLs.first)
            ),
            SessionReadingArtifact(
                id: "summary",
                kind: .summary,
                title: "Summary",
                urls: summaryURLs,
                copyText: text(at: summaryURLs.first),
                summaryProvenance: manifest.summaryHistory.last.map {
                    SummaryProvenance(
                        providerDisplayName: $0.providerDisplayName,
                        modelIdentifier: $0.modelIdentifier
                    )
                } ?? legacySummaryProvenance(text(at: summaryURLs.first))
            ),
            SessionReadingArtifact(
                id: "audio",
                kind: .audio,
                title: "Audio",
                detail: audioURLs.count == 1
                    ? "1 file" : "\(audioURLs.count) files",
                urls: audioURLs
            )
        ]

        let corePaths = Set(
            notesURLs.map(\.lastPathComponent)
                + transcriptURLs.map(\.lastPathComponent)
                + summaryURLs.map(\.lastPathComponent)
                + audioPaths
        )
        let additional = manifest.artifacts.filter {
            $0.kind == .additional && !corePaths.contains($0.relativePath)
        }.compactMap { artifact -> SessionReadingArtifact? in
            let url = directory.appendingPathComponent(artifact.relativePath)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return SessionReadingArtifact(
                id: "additional:\(artifact.relativePath)",
                kind: .additional,
                title: url.lastPathComponent,
                urls: [url],
                copyText: text(at: url)
            )
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        result.append(contentsOf: additional)

        let revisions = manifest.transcriptionHistory.reversed().map {
            revision -> SessionReadingArtifact in
            let urls = existing(revision.artifacts)
            return SessionReadingArtifact(
                id: "revision:\(revision.id.uuidString)",
                kind: .transcriptionRevision,
                title: revision.createdAt.formatted(
                    date: .abbreviated,
                    time: .shortened
                ),
                detail: revision.modelIdentifier,
                urls: urls,
                copyText: text(at: urls.first(where: {
                    $0.pathExtension.lowercased() == "md"
                })),
                revision: revision
            )
        }
        result.append(contentsOf: revisions)
        let summaryRevisions = manifest.summaryHistory.reversed().map {
            revision -> SessionReadingArtifact in
            let urls = existing(revision.artifacts)
            return SessionReadingArtifact(
                id: "summary-revision:\(revision.id.uuidString)",
                kind: .summaryRevision,
                title: revision.createdAt.formatted(
                    date: .abbreviated,
                    time: .shortened
                ),
                detail: revision.modelIdentifier,
                urls: urls,
                copyText: text(at: urls.first),
                summaryRevision: revision,
                summaryProvenance: SummaryProvenance(
                    providerDisplayName: revision.providerDisplayName,
                    modelIdentifier: revision.modelIdentifier
                )
            )
        }
        result.append(contentsOf: summaryRevisions)
        return result
    }

    private func legacySummaryProvenance(
        _ text: String?
    ) -> SummaryProvenance? {
        guard let text else { return nil }
        let header = text.prefix(1_024).lowercased()
        if header.contains("claude") || header.contains("anthropic") {
            return SummaryProvenance(providerDisplayName: "Anthropic")
        }
        if header.contains("gpt") || header.contains("openai") {
            return SummaryProvenance(providerDisplayName: "OpenAI")
        }
        return SummaryProvenance(providerDisplayName: "Local")
    }

    private func makeTimelineLanes(
        segments: [TranscriptSegment],
        manifest: CaptureSessionManifest
    ) -> [SessionTimelineLane] {
        let grouped = Dictionary(grouping: segments) { segment in
            segment.speakerID ?? "source.\(segment.source.rawValue)"
        }
        return grouped.map { id, segments in
            let ordered = segments.sorted {
                if $0.startTime != $1.startTime {
                    return $0.startTime < $1.startTime
                }
                return $0.endTime < $1.endTime
            }
            let source = ordered.first?.source ?? .imported
            let regions = ordered.map {
                SessionTimelineRegion(
                    startTime: max(0, $0.startTime),
                    endTime: max($0.startTime, $0.endTime)
                )
            }
            let talkTime = regions.reduce(0) {
                $0 + max(0, $1.endTime - $1.startTime)
            }
            let identity = manifest.speakerIdentity(identifiedBy: id)
            let defaultName: String? = switch source {
            case .microphone: "You"
            case .system: "Others"
            case .imported: nil
            }
            return SessionTimelineLane(
                id: id,
                speakerID: ordered.first?.speakerID ?? identity?.id,
                source: source,
                displayName: identity?.displayName ?? defaultName,
                regions: regions,
                talkTime: talkTime
            )
        }.sorted { lhs, rhs in
            if lhs.source != rhs.source {
                return Self.sourceOrder(lhs.source) < Self.sourceOrder(rhs.source)
            }
            return lhs.id < rhs.id
        }
    }

    private func sessionDuration(
        manifest: CaptureSessionManifest,
        directory: URL,
        segments: [TranscriptSegment]
    ) -> TimeInterval {
        let audioEnd = manifest.tracks.reduce(0.0) { current, track in
            let url = directory.appendingPathComponent(track.relativePath)
            return max(current, track.startTime + wavDuration(at: url))
        }
        let transcriptEnd = segments.map(\.endTime).max() ?? 0
        let pinEnd = manifest.pins.map {
            Double($0.sampleOffset) / CanonicalAudioFormat.sampleRate
        }.max() ?? 0
        return max(audioEnd, transcriptEnd, pinEnd)
    }

    private func wavDuration(at url: URL) -> TimeInterval {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return 0
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 44),
            header.count == 44
        else { return 0 }
        let bytes = [UInt8](header[40..<44])
        let declared = UInt64(bytes[0])
            | UInt64(bytes[1]) << 8
            | UInt64(bytes[2]) << 16
            | UInt64(bytes[3]) << 24
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?
            .fileSize ?? 44
        let payload = min(declared, UInt64(max(0, fileSize - 44)))
        return Double(payload / UInt64(MemoryLayout<Int16>.size))
            / CanonicalAudioFormat.sampleRate
    }

    private static func sourceOrder(_ source: AudioSource) -> Int {
        switch source {
        case .microphone: 0
        case .system: 1
        case .imported: 2
        }
    }
}

private struct StoredTranscriptSegment: Decodable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let source: String
    let speakerID: String?
    let confidence: Float?
    let words: [StoredTranscriptWord]?

    var segment: TranscriptSegment? {
        guard let source = AudioSource(rawValue: source) else { return nil }
        return TranscriptSegment(
            text: text,
            startTime: startTime,
            endTime: endTime,
            source: source,
            speakerID: speakerID,
            confidence: confidence,
            words: words?.map(\.word)
        )
    }
}

private struct StoredTranscriptWord: Decodable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Float?

    var word: WordTiming {
        WordTiming(
            text: text,
            startTime: startTime,
            endTime: endTime,
            confidence: confidence
        )
    }
}
