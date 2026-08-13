import AudioCapture
import Foundation

public struct LegacySessionMigrationReport: Equatable, Sendable {
    public let migratedDirectories: [URL]
    public let failures: [String]
}

public struct LegacySessionMigrator: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func migrate(
        from legacyRoot: URL,
        to libraryRoot: URL
    ) -> LegacySessionMigrationReport {
        guard
            legacyRoot.standardizedFileURL != libraryRoot.standardizedFileURL,
            fileManager.fileExists(atPath: legacyRoot.path)
        else { return .init(migratedDirectories: [], failures: []) }

        do {
            try fileManager.createDirectory(
                at: libraryRoot,
                withIntermediateDirectories: true
            )
        } catch {
            return .init(
                migratedDirectories: [],
                failures: [error.localizedDescription]
            )
        }

        let directories: [URL]
        do {
            directories = try fileManager.contentsOfDirectory(
                at: legacyRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return .init(
                migratedDirectories: [],
                failures: [error.localizedDescription]
            )
        }

        var migrated: [URL] = []
        var failures: [String] = []
        for directory in directories {
            do {
                let values = try directory.resourceValues(forKeys: [
                    .isDirectoryKey, .creationDateKey
                ])
                guard values.isDirectory == true else { continue }
                var manifest = try CaptureSessionManifest.load(from: directory)
                let date = values.creationDate ?? manifest.createdAt
                let title = manifest.title == "Recovered Session"
                    ? "Recovered Meeting"
                    : manifest.title
                manifest = CaptureSessionManifest(
                    sessionID: manifest.sessionID,
                    title: title,
                    createdAt: date,
                    source: manifest.source,
                    tracks: manifest.tracks,
                    speakerIdentities: manifest.speakerIdentities,
                    artifacts: manifest.artifacts,
                    transcriptionHistory: manifest.transcriptionHistory,
                    originalFilename: manifest.originalFilename,
                    originalFormat: manifest.originalFormat,
                    systemAudioStartupStageTimings:
                        manifest.systemAudioStartupStageTimings,
                    systemAudioGraphPreparation:
                        manifest.systemAudioGraphPreparation,
                    microphoneInputDevice:
                        manifest.microphoneInputDevice
                )
                try manifest.write(to: directory)

                let destination = availableDestination(
                    root: libraryRoot,
                    title: title,
                    date: date
                )
                try fileManager.moveItem(at: directory, to: destination)
                migrated.append(destination)
            } catch {
                failures.append(
                    "\(directory.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
        return .init(migratedDirectories: migrated, failures: failures)
    }

    private func availableDestination(
        root: URL,
        title: String,
        date: Date
    ) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
        let base = "\(formatter.string(from: date)) — \(safeTitle)"
        var index = 1
        while true {
            let name = index == 1 ? base : "\(base) \(index)"
            let candidate = root.appendingPathComponent(name, isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }
}
