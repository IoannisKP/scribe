import AudioCapture
import Foundation

public struct ManualSessionFolder: Equatable, Hashable, Identifiable, Sendable {
    public let name: String
    public let directory: URL

    public var id: String { directory.standardizedFileURL.path }

    public init(name: String, directory: URL) {
        self.name = name
        self.directory = directory
    }
}

public enum SessionManualFolderError: Error, LocalizedError, Sendable {
    case invalidName
    case folderAlreadyExists(String)
    case sourceIsNotSession(URL)
    case destinationOutsideLibrary

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            ScribeCopy.Shell.invalidFolderName
        case let .folderAlreadyExists(name):
            ScribeCopy.Shell.folderAlreadyExists(name)
        case let .sourceIsNotSession(url):
            ScribeCopy.Shell.notASessionFolder(url.lastPathComponent)
        case .destinationOutsideLibrary:
            ScribeCopy.Shell.folderOutsideLibrary
        }
    }
}

public struct SessionManualFolderManager: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func folders(in library: URL) throws -> [ManualSessionFolder] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey,
            .isAliasFileKey, .isPackageKey
        ]
        return try fileManager.contentsOfDirectory(
            at: library,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ).compactMap { url in
            let values = try url.resourceValues(forKeys: keys)
            guard values.isDirectory == true,
                values.isHidden != true,
                values.isSymbolicLink != true,
                values.isAliasFile != true,
                values.isPackage != true,
                !containsSessionManifest(url)
            else {
                return nil
            }
            return ManualSessionFolder(
                name: url.lastPathComponent,
                directory: url
            )
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    @discardableResult
    public func createFolder(
        named proposedName: String,
        in library: URL
    ) throws -> ManualSessionFolder {
        let name = cleanName(proposedName)
        guard !name.isEmpty else {
            throw SessionManualFolderError.invalidName
        }
        let directory = library.appendingPathComponent(
            name,
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw SessionManualFolderError.folderAlreadyExists(name)
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return ManualSessionFolder(name: name, directory: directory)
    }

    @discardableResult
    public func moveSession(
        at sessionDirectory: URL,
        to folder: ManualSessionFolder,
        in library: URL
    ) throws -> URL {
        let root = library.standardizedFileURL
        let destinationFolder = folder.directory.standardizedFileURL
        guard destinationFolder.deletingLastPathComponent() == root else {
            throw SessionManualFolderError.destinationOutsideLibrary
        }
        guard containsSessionManifest(sessionDirectory) else {
            throw SessionManualFolderError.sourceIsNotSession(
                sessionDirectory
            )
        }
        let destination = availableDestination(
            named: sessionDirectory.lastPathComponent,
            in: destinationFolder
        )
        try fileManager.moveItem(at: sessionDirectory, to: destination)
        return destination
    }

    private func availableDestination(named name: String, in folder: URL) -> URL {
        var suffix = 1
        while true {
            let candidateName = suffix == 1 ? name : "\(name) \(suffix)"
            let candidate = folder.appendingPathComponent(
                candidateName,
                isDirectory: true
            )
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    private func containsSessionManifest(_ directory: URL) -> Bool {
        fileManager.fileExists(atPath: directory.appendingPathComponent(
            CaptureSessionManifest.fileName,
            isDirectory: false
        ).path)
            || fileManager.fileExists(atPath: directory.appendingPathComponent(
                CaptureSessionManifest.legacyFileName,
                isDirectory: false
            ).path)
    }

    private func cleanName(_ proposedName: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:")
        let cleaned = proposedName.components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.hasPrefix(".") else { return "" }
        return String(cleaned.prefix(120))
    }
}
