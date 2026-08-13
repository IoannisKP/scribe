import AudioCapture
import Foundation

public struct SessionArtifactPresence: Equatable, Sendable {
    public let notes: Bool
    public let transcript: Bool
    public let summary: Bool
    public let audio: Bool

    public static let none = SessionArtifactPresence(
        notes: false,
        transcript: false,
        summary: false,
        audio: false
    )

    public init(
        notes: Bool,
        transcript: Bool,
        summary: Bool,
        audio: Bool
    ) {
        self.notes = notes
        self.transcript = transcript
        self.summary = summary
        self.audio = audio
    }

    public init(artifacts: [CaptureSessionManifest.Artifact]) {
        let currentPaths = Set(artifacts.map(\.relativePath))
        notes = currentPaths.contains("notes.md")
        transcript = currentPaths.contains("transcript.md")
            || currentPaths.contains("transcript.json")
            || currentPaths.contains("transcript.srt")
        summary = currentPaths.contains("summary.md")
        audio = artifacts.contains { $0.kind == .audio }
    }
}

public struct SessionLibraryItem: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let createdAt: Date
    public let directory: URL
    public let source: CaptureSessionManifest.SessionSource
    public let duration: TimeInterval
    public let speakerCount: Int
    public let artifacts: SessionArtifactPresence
    public let byteCount: Int64
    public let isAvailable: Bool

    public init(
        id: UUID,
        title: String,
        createdAt: Date,
        directory: URL,
        source: CaptureSessionManifest.SessionSource,
        duration: TimeInterval,
        speakerCount: Int,
        artifacts: SessionArtifactPresence,
        byteCount: Int64,
        isAvailable: Bool
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.directory = directory
        self.source = source
        self.duration = duration
        self.speakerCount = speakerCount
        self.artifacts = artifacts
        self.byteCount = byteCount
        self.isAvailable = isAvailable
    }
}

public struct SessionDateGroup: Equatable, Identifiable, Sendable {
    public let date: Date
    public let sessions: [SessionLibraryItem]

    public var id: Date { date }

    public init(date: Date, sessions: [SessionLibraryItem]) {
        self.date = date
        self.sessions = sessions
    }
}

public enum SessionSearchHitKind: String, Equatable, Sendable {
    case title
    case notes
    case transcript
}

public struct SessionSearchHit: Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: SessionSearchHitKind
    public let text: String
    public let startTime: TimeInterval?

    public init(
        id: String,
        kind: SessionSearchHitKind,
        text: String,
        startTime: TimeInterval?
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.startTime = startTime
    }
}

public struct SessionSearchGroup: Equatable, Identifiable, Sendable {
    public let session: SessionLibraryItem
    public let hits: [SessionSearchHit]

    public var id: UUID { session.id }

    public init(session: SessionLibraryItem, hits: [SessionSearchHit]) {
        self.session = session
        self.hits = hits
    }
}

public struct SessionLibraryNavigationTarget: Equatable, Sendable {
    public let sessionID: UUID
    public let startTime: TimeInterval?

    public init(sessionID: UUID, startTime: TimeInterval?) {
        self.sessionID = sessionID
        self.startTime = startTime
    }

    public init(group: SessionSearchGroup, hit: SessionSearchHit) {
        self.init(sessionID: group.session.id, startTime: hit.startTime)
    }
}

public struct SessionLibraryPresentation: @unchecked Sendable {
    private let calendar: Calendar
    private let fileManager: FileManager

    public init(
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) {
        self.calendar = calendar
        self.fileManager = fileManager
    }

    public func items(from sessions: [IndexedSession]) -> [SessionLibraryItem] {
        sessions.map(item(from:)).sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.title.localizedStandardCompare($1.title)
                == .orderedAscending
        }
    }

    public func dateGroups(
        from sessions: [SessionLibraryItem]
    ) -> [SessionDateGroup] {
        let grouped = Dictionary(grouping: sessions) {
            calendar.startOfDay(for: $0.createdAt)
        }
        return grouped.keys.sorted(by: >).map { date in
            SessionDateGroup(
                date: date,
                sessions: grouped[date, default: []].sorted {
                    if $0.createdAt != $1.createdAt {
                        return $0.createdAt > $1.createdAt
                    }
                    return $0.title.localizedStandardCompare($1.title)
                        == .orderedAscending
                }
            )
        }
    }

    public func searchGroups(
        query: String,
        sessions: [SessionLibraryItem]
    ) -> [SessionSearchGroup] {
        let terms = normalizedTerms(query)
        guard !terms.isEmpty else { return [] }
        return sessions.compactMap { session in
            var hits: [SessionSearchHit] = []
            if containsAllTerms(session.title, terms: terms) {
                hits.append(SessionSearchHit(
                    id: "title",
                    kind: .title,
                    text: session.title,
                    startTime: nil
                ))
            }

            let transcriptURL = session.directory.appendingPathComponent(
                "transcript.json"
            )
            if let data = try? Data(contentsOf: transcriptURL),
                let segments = try? JSONDecoder().decode(
                    [SearchTranscriptSegment].self,
                    from: data
                )
            {
                for (index, segment) in segments.enumerated()
                where containsAllTerms(segment.text, terms: terms) {
                    hits.append(SessionSearchHit(
                        id: "transcript-\(index)",
                        kind: .transcript,
                        text: excerpt(segment.text),
                        startTime: max(0, segment.startTime)
                    ))
                }
            }

            let notesURL = session.directory.appendingPathComponent("notes.md")
            if let notes = try? String(contentsOf: notesURL, encoding: .utf8) {
                let paragraphs = notes.components(
                    separatedBy: CharacterSet.newlines
                ).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                for (index, paragraph) in paragraphs.enumerated()
                where containsAllTerms(paragraph, terms: terms) {
                    hits.append(SessionSearchHit(
                        id: "notes-\(index)",
                        kind: .notes,
                        text: excerpt(paragraph),
                        startTime: nil
                    ))
                }
            }

            guard !hits.isEmpty else { return nil }
            return SessionSearchGroup(session: session, hits: hits)
        }
    }

    private func item(from indexed: IndexedSession) -> SessionLibraryItem {
        guard indexed.isAvailable,
            let manifest = try? CaptureSessionManifest.load(
                from: indexed.directory
            )
        else {
            return SessionLibraryItem(
                id: indexed.id,
                title: indexed.title,
                createdAt: indexed.createdAt,
                directory: indexed.directory,
                source: CaptureSessionManifest.SessionSource(
                    rawValue: indexed.source
                ) ?? .liveCapture,
                duration: 0,
                speakerCount: 0,
                artifacts: .none,
                byteCount: 0,
                isAvailable: indexed.isAvailable
            )
        }

        let presence = SessionArtifactPresence(artifacts: manifest.artifacts)
        return SessionLibraryItem(
            id: manifest.sessionID,
            title: manifest.title,
            createdAt: manifest.createdAt,
            directory: indexed.directory,
            source: manifest.source,
            duration: duration(of: manifest, in: indexed.directory),
            speakerCount: manifest.source == .liveCapture
                ? manifest.speakerIdentities.count
                : 1,
            artifacts: presence,
            byteCount: directoryByteCount(indexed.directory),
            isAvailable: true
        )
    }

    private func duration(
        of manifest: CaptureSessionManifest,
        in directory: URL
    ) -> TimeInterval {
        manifest.tracks.reduce(0) { result, track in
            let url = directory.appendingPathComponent(track.relativePath)
            let sampleCount = canonicalSampleCount(at: url)
            let endSample = max(0, track.startSampleOffset ?? 0)
                + Int64(sampleCount)
            return max(
                result,
                Double(endSample) / CanonicalAudioFormat.sampleRate
            )
        }
    }

    private func canonicalSampleCount(at url: URL) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 44), header.count == 44,
            String(data: header[0..<4], encoding: .ascii) == "RIFF",
            String(data: header[8..<12], encoding: .ascii) == "WAVE",
            String(data: header[36..<40], encoding: .ascii) == "data"
        else { return 0 }
        let bytes = [UInt8](header[40..<44])
        let payload = UInt64(bytes[0])
            | UInt64(bytes[1]) << 8
            | UInt64(bytes[2]) << 16
            | UInt64(bytes[3]) << 24
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?
            .fileSize ?? 44
        let actualPayload = UInt64(max(0, fileSize - 44))
        return min(payload, actualPayload)
            / UInt64(MemoryLayout<Int16>.size)
    }

    private func directoryByteCount(_ directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true,
                values.isSymbolicLink != true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private func normalizedTerms(_ query: String) -> [String] {
        query.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private func containsAllTerms(_ text: String, terms: [String]) -> Bool {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return terms.allSatisfy(folded.contains)
    }

    private func excerpt(_ text: String) -> String {
        let clean = text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard clean.count > 180 else { return clean }
        return String(clean.prefix(177)) + "…"
    }
}

public struct SessionFolderTrash: Sendable {
    private let operation: @Sendable (URL) throws -> URL

    public init(operation: @escaping @Sendable (URL) throws -> URL) {
        self.operation = operation
    }

    public func move(_ directory: URL) throws -> URL {
        try operation(directory)
    }

    public static let system = SessionFolderTrash { directory in
        var result: NSURL?
        try FileManager.default.trashItem(
            at: directory,
            resultingItemURL: &result
        )
        return (result as URL?) ?? directory
    }
}

public enum SessionLibraryOperationError: Error, LocalizedError, Sendable {
    case invalidTitle
    case sessionUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidTitle:
            ScribeCopy.Library.invalidTitle
        case .sessionUnavailable:
            ScribeCopy.Library.sessionUnavailable
        }
    }
}

public struct SessionLibraryOperations: @unchecked Sendable {
    private let fileManager: FileManager
    private let trash: SessionFolderTrash

    public init(
        fileManager: FileManager = .default,
        trash: SessionFolderTrash = .system
    ) {
        self.fileManager = fileManager
        self.trash = trash
    }

    @discardableResult
    public func rename(
        session: SessionLibraryItem,
        to proposedTitle: String
    ) async throws -> URL {
        guard session.isAvailable else {
            throw SessionLibraryOperationError.sessionUnavailable
        }
        let title = cleanTitle(proposedTitle)
        guard !title.isEmpty else {
            throw SessionLibraryOperationError.invalidTitle
        }
        guard title != session.title else { return session.directory }
        let parent = session.directory.deletingLastPathComponent()
        let baseName = folderBaseName(title: title, date: session.createdAt)
        let destination = availableDirectory(in: parent, baseName: baseName)
        if destination.standardizedFileURL != session.directory.standardizedFileURL {
            try fileManager.moveItem(at: session.directory, to: destination)
        }
        do {
            _ = try await CaptureSessionManifestStore.shared.replaceTitle(
                title,
                in: destination
            )
            return destination
        } catch {
            if destination.standardizedFileURL
                != session.directory.standardizedFileURL
            {
                try? fileManager.moveItem(
                    at: destination,
                    to: session.directory
                )
            }
            throw error
        }
    }

    @discardableResult
    public func moveToTrash(session: SessionLibraryItem) throws -> URL {
        guard session.isAvailable else {
            throw SessionLibraryOperationError.sessionUnavailable
        }
        return try trash.move(session.directory)
    }

    private func cleanTitle(_ title: String) -> String {
        title.components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(120)
            .description
    }

    private func folderBaseName(title: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "\(formatter.string(from: date)) — \(title)"
    }

    private func availableDirectory(in parent: URL, baseName: String) -> URL {
        var suffix = 1
        while true {
            let name = suffix == 1 ? baseName : "\(baseName) \(suffix)"
            let candidate = parent.appendingPathComponent(name, isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }
}

private struct SearchTranscriptSegment: Decodable {
    let text: String
    let startTime: TimeInterval
}
