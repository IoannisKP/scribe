import Foundation

public enum SessionLibraryAvailability: Equatable, Sendable {
    case available(URL)
    case unavailable(lastKnownURL: URL?)
}

public final class SessionLibraryLocationStore: @unchecked Sendable {
    public static let bookmarkKey = "Scribe.SessionLibraryBookmark"
    public static let pathKey = "Scribe.SessionLibraryLastKnownPath"

    private let defaults: UserDefaults
    private let fileManager: FileManager

    public init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    public func defaultLocation() throws -> URL {
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return documents.appendingPathComponent("Scribe", isDirectory: true)
    }

    public func setLocation(_ url: URL) throws {
        let normalized = url.standardizedFileURL
        let bookmark = try normalized.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: [
                .volumeIdentifierKey,
                .isDirectoryKey
            ],
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        defaults.set(normalized.path, forKey: Self.pathKey)
    }

    public func resolve() -> SessionLibraryAvailability {
        let lastKnown = defaults.string(forKey: Self.pathKey).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else {
            do {
                let url = try defaultLocation()
                return .available(url)
            } catch {
                return .unavailable(lastKnownURL: lastKnown)
            }
        }

        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard fileManager.fileExists(atPath: url.path) else {
                return .unavailable(lastKnownURL: lastKnown ?? url)
            }
            if stale {
                try setLocation(url)
            }
            return .available(url)
        } catch {
            return .unavailable(lastKnownURL: lastKnown)
        }
    }

    @discardableResult
    public func beginAccessing(_ url: URL) -> Bool {
        defaults.data(forKey: Self.bookmarkKey) == nil
            || url.startAccessingSecurityScopedResource()
    }

    public func endAccessing(_ url: URL) {
        guard defaults.data(forKey: Self.bookmarkKey) != nil else { return }
        url.stopAccessingSecurityScopedResource()
    }
}
