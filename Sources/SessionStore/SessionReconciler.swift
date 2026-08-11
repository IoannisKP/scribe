import AudioCapture
import Foundation

public enum SessionReconciliationNoticeKind: String, Sendable {
    case duplicateCopied
    case invalidSession
    case manifestUpdated
}

public struct SessionReconciliationNotice: Equatable, Sendable {
    public let kind: SessionReconciliationNoticeKind
    public let directory: URL
    public let message: String
}

public struct SessionReconciliationReport: Equatable, Sendable {
    public let indexedSessionCount: Int
    public let locationAvailable: Bool
    public let notices: [SessionReconciliationNotice]
}

public actor SessionReconciler {
    private let index: SessionIndex
    private let fileManager: FileManager

    public init(
        index: SessionIndex,
        fileManager: FileManager = .default
    ) {
        self.index = index
        self.fileManager = fileManager
    }

    public func reconcile(
        availability: SessionLibraryAvailability
    ) async throws -> SessionReconciliationReport {
        guard case let .available(root) = availability else {
            try await index.markAllUnavailable()
            return SessionReconciliationReport(
                indexedSessionCount: 0,
                locationAvailable: false,
                notices: []
            )
        }

        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
        } catch {
            try await index.markAllUnavailable()
            return SessionReconciliationReport(
                indexedSessionCount: 0,
                locationAvailable: false,
                notices: []
            )
        }

        let directories = try sessionDirectories(in: root)
        var candidates: [Candidate] = []
        var notices: [SessionReconciliationNotice] = []
        for directory in directories {
            do {
                var manifest = try CaptureSessionManifest.load(from: directory)
                let currentManifestURL = directory.appendingPathComponent(
                    CaptureSessionManifest.fileName
                )
                if !fileManager.fileExists(atPath: currentManifestURL.path) {
                    manifest = manifest.replacing()
                    try manifest.write(to: directory)
                    notices.append(.init(
                        kind: .manifestUpdated,
                        directory: directory,
                        message: "Migrated legacy capture metadata to session.json. Its track timing remains estimated."
                    ))
                }
                let values = try directory.resourceValues(forKeys: [
                    .creationDateKey, .contentModificationDateKey
                ])
                candidates.append(Candidate(
                    directory: directory,
                    manifest: manifest,
                    age: values.creationDate
                        ?? values.contentModificationDate
                        ?? manifest.createdAt
                ))
            } catch {
                notices.append(.init(
                    kind: .invalidSession,
                    directory: directory,
                    message: error.localizedDescription
                ))
            }
        }

        candidates.sort {
            if $0.age != $1.age { return $0.age < $1.age }
            return $0.directory.path < $1.directory.path
        }

        var claimedIDs: Set<UUID> = []
        var seenIDs: Set<UUID> = []
        for candidate in candidates {
            var manifest = candidate.manifest
            if claimedIDs.contains(manifest.sessionID) {
                let oldID = manifest.sessionID
                manifest = manifest.replacing(sessionID: UUID())
                try manifest.write(to: candidate.directory)
                notices.append(.init(
                    kind: .duplicateCopied,
                    directory: candidate.directory,
                    message: "Finder copy detected. The older folder keeps \(oldID.uuidString); this newer copy is now an independent session."
                ))
            }
            claimedIDs.insert(manifest.sessionID)
            seenIDs.insert(manifest.sessionID)

            let inventory = try buildInventory(
                directory: candidate.directory,
                manifest: manifest
            )
            if inventory.manifestArtifacts != manifest.artifacts {
                manifest = manifest.replacing(
                    artifacts: inventory.manifestArtifacts
                )
                try manifest.write(to: candidate.directory)
            }
            try await index.replace(
                session: IndexedSession(
                    id: manifest.sessionID,
                    title: manifest.title,
                    createdAt: manifest.createdAt,
                    directory: candidate.directory,
                    source: manifest.source.rawValue,
                    isAvailable: true
                ),
                artifacts: inventory.indexArtifacts,
                transcript: readText(
                    candidate.directory.appendingPathComponent("transcript.md")
                ),
                notes: readText(
                    candidate.directory.appendingPathComponent("notes.md")
                ),
                summary: readText(
                    candidate.directory.appendingPathComponent("summary.md")
                )
            )
        }

        // This deletion is safe only after the root itself was reached and read.
        try await index.removeSessions(notIn: seenIDs)
        return SessionReconciliationReport(
            indexedSessionCount: seenIDs.count,
            locationAvailable: true,
            notices: notices
        )
    }

    private func sessionDirectories(in root: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .isHiddenKey
            ]) else { return false }
            return values.isDirectory == true && values.isHidden != true
        }
    }

    private func buildInventory(
        directory: URL,
        manifest: CaptureSessionManifest
    ) throws -> Inventory {
        let trackPaths = Set(manifest.tracks.map(\.relativePath))
        var declaredKinds: [String: CaptureSessionManifest.ArtifactKind] = [:]
        for artifact in manifest.artifacts {
            declaredKinds[artifact.relativePath] = artifact.kind
        }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey,
            .isHiddenKey, .fileSizeKey, .contentModificationDateKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return Inventory(manifestArtifacts: [], indexArtifacts: []) }

        var manifestArtifacts: [CaptureSessionManifest.Artifact] = []
        var indexArtifacts: [IndexedArtifact] = []
        for case let url as URL in enumerator {
            let relativePath = String(url.path.dropFirst(directory.path.count + 1))
            if relativePath.hasPrefix("LiveSpool/")
                || relativePath.hasPrefix("LiveSpeechWindows/")
            {
                continue
            }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            guard let kind = artifactKind(
                url: url,
                relativePath: relativePath,
                trackPaths: trackPaths,
                declaredKinds: declaredKinds,
                values: values
            ) else { continue }
            manifestArtifacts.append(.init(
                relativePath: relativePath,
                kind: kind
            ))
            indexArtifacts.append(.init(
                relativePath: relativePath,
                kind: kind.rawValue,
                byteCount: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate
            ))
        }
        manifestArtifacts.sort { $0.relativePath < $1.relativePath }
        indexArtifacts.sort { $0.relativePath < $1.relativePath }
        return Inventory(
            manifestArtifacts: manifestArtifacts,
            indexArtifacts: indexArtifacts
        )
    }

    private func artifactKind(
        url: URL,
        relativePath: String,
        trackPaths: Set<String>,
        declaredKinds: [String: CaptureSessionManifest.ArtifactKind],
        values: URLResourceValues
    ) -> CaptureSessionManifest.ArtifactKind? {
        if relativePath == CaptureSessionManifest.fileName
            || relativePath == CaptureSessionManifest.legacyFileName
        { return nil }
        if let declared = declaredKinds[relativePath] { return declared }
        if trackPaths.contains(relativePath) { return .audio }
        let name = url.lastPathComponent.lowercased()
        if name == "transcript.md" { return .transcriptMarkdown }
        if name == "transcript.json" { return .transcriptJSON }
        if name == "transcript.srt" { return .subtitles }
        if name == "notes.md" { return .notes }
        if name == "summary.md" { return .summary }
        if relativePath.hasPrefix("Transcriptions/") {
            if name.hasSuffix(".md") { return .transcriptMarkdown }
            if name.hasSuffix(".json") { return .transcriptJSON }
            if name.hasSuffix(".srt") { return .subtitles }
        }
        if SessionArtifactPolicy.shouldSurfaceAdditionalFile(
            url,
            resourceValues: values
        ) { return .additional }
        return nil
    }

    private func readText(_ url: URL) -> String {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize,
            size <= 50 * 1_024 * 1_024,
            let data = try? Data(contentsOf: url),
            let string = String(data: data, encoding: .utf8)
        else { return "" }
        return string
    }
}

private struct Candidate {
    let directory: URL
    let manifest: CaptureSessionManifest
    let age: Date
}

private struct Inventory {
    let manifestArtifacts: [CaptureSessionManifest.Artifact]
    let indexArtifacts: [IndexedArtifact]
}
