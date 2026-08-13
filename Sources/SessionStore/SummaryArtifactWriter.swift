import AudioCapture
import Foundation

public struct SummaryArtifactWriteResult: Equatable, Sendable {
    public let currentFile: URL
    public let revisionFile: URL
    public let revision: CaptureSessionManifest.SummaryRevision
}

public struct SummaryArtifactWriter: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func write(
        summary: String,
        providerIdentifier: String,
        providerDisplayName: String,
        modelIdentifier: String,
        templateIdentifier: String,
        templateName: String,
        to sessionDirectory: URL,
        date: Date = Date()
    ) async throws -> SummaryArtifactWriteResult {
        let revisionID = UUID()
        let revisionDirectory = sessionDirectory
            .appendingPathComponent("Summaries", isDirectory: true)
            .appendingPathComponent(
                revisionDirectoryName(
                    date: date,
                    provider: providerDisplayName,
                    model: modelIdentifier,
                    id: revisionID
                ),
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: revisionDirectory,
            withIntermediateDirectories: true
        )
        let revisionURL = revisionDirectory.appendingPathComponent("summary.md")
        let currentURL = sessionDirectory.appendingPathComponent("summary.md")
        let previousCurrent = try? Data(contentsOf: currentURL)
        let payload = Data(Self.markdown(
            summary: summary,
            provider: providerDisplayName,
            model: modelIdentifier,
            template: templateName
        ).utf8)

        do {
            try payload.write(to: revisionURL, options: .atomic)
            try payload.write(to: currentURL, options: .atomic)
            let relativeRevisionPath = String(
                revisionURL.path.dropFirst(sessionDirectory.path.count + 1)
            )
            let revision = CaptureSessionManifest.SummaryRevision(
                id: revisionID,
                providerIdentifier: providerIdentifier,
                providerDisplayName: providerDisplayName,
                modelIdentifier: modelIdentifier,
                templateIdentifier: templateIdentifier,
                templateName: templateName,
                createdAt: Date(
                    timeIntervalSince1970: floor(date.timeIntervalSince1970)
                ),
                artifacts: [relativeRevisionPath]
            )
            _ = try await CaptureSessionManifestStore.shared
                .commitSummaryRevision(revision, in: sessionDirectory)
            return SummaryArtifactWriteResult(
                currentFile: currentURL,
                revisionFile: revisionURL,
                revision: revision
            )
        } catch {
            if let previousCurrent {
                try? previousCurrent.write(to: currentURL, options: .atomic)
            } else {
                try? fileManager.removeItem(at: currentURL)
            }
            try? fileManager.removeItem(at: revisionDirectory)
            throw error
        }
    }

    public static func markdown(
        summary: String,
        provider: String,
        model: String,
        template: String
    ) -> String {
        let values = [provider, model, template].map {
            $0.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        return "> Scribe summary · Provider: \(values[0]) · Model: \(values[1]) · Template: \(values[2])\n\n\(summary.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    private func revisionDirectoryName(
        date: Date,
        provider: String,
        model: String,
        id: UUID
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safeIdentity = "\(provider)-\(model)".lowercased().map {
            $0.isLetter || $0.isNumber ? $0 : "-"
        }
        return "\(formatter.string(from: date)) — \(String(safeIdentity)) — \(id.uuidString.prefix(8))"
    }
}
