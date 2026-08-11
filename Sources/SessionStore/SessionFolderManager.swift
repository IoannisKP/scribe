import AudioCapture
import Foundation

public struct CreatedSession: Equatable, Sendable {
    public let directory: URL
    public let manifest: CaptureSessionManifest
}

public struct SessionFolderManager: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func createLiveSession(
        in library: URL,
        title: String = "Meeting",
        date: Date = Date()
    ) throws -> CreatedSession {
        try fileManager.createDirectory(
            at: library,
            withIntermediateDirectories: true
        )
        let cleanTitle = Self.cleanTitle(title)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let baseName = "\(formatter.string(from: date)) — \(cleanTitle)"
        let directory = availableDirectory(in: library, baseName: baseName)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )

        do {
            let createdAt = Date(
                timeIntervalSince1970: floor(date.timeIntervalSince1970)
            )
            let manifest = CaptureSessionManifest.pendingDualTrack(
                sessionID: UUID(),
                title: cleanTitle,
                createdAt: createdAt
            )
            try manifest.write(to: directory)
            let notesURL = directory.appendingPathComponent("notes.md")
            try Data().write(to: notesURL, options: .withoutOverwriting)
            return CreatedSession(directory: directory, manifest: manifest)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private func availableDirectory(in library: URL, baseName: String) -> URL {
        var suffix = 1
        while true {
            let name = suffix == 1 ? baseName : "\(baseName) \(suffix)"
            let candidate = library.appendingPathComponent(
                name,
                isDirectory: true
            )
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    private static func cleanTitle(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:")
        let parts = title.components(separatedBy: forbidden)
        let cleaned = parts.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Meeting" : String(cleaned.prefix(120))
    }
}
