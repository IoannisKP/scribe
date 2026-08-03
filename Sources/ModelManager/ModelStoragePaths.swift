import Foundation

public struct ModelStoragePaths: Equatable, Sendable {
    public let applicationSupportDirectory: URL
    public let scribeDirectory: URL
    public let modelsDirectory: URL

    public init(applicationSupportDirectory: URL) {
        let applicationSupportDirectory = applicationSupportDirectory
            .standardizedFileURL
        self.applicationSupportDirectory = applicationSupportDirectory
        self.scribeDirectory = applicationSupportDirectory.appendingPathComponent(
            "Scribe",
            isDirectory: true
        )
        self.modelsDirectory = scribeDirectory.appendingPathComponent(
            "Models",
            isDirectory: true
        )
    }

    /// Preserves dependency-injected model roots used by existing stores/tests.
    public init(modelsDirectory: URL) {
        let modelsDirectory = modelsDirectory.standardizedFileURL
        self.modelsDirectory = modelsDirectory
        self.scribeDirectory = modelsDirectory.deletingLastPathComponent()
        self.applicationSupportDirectory = scribeDirectory
            .deletingLastPathComponent()
    }

    public static func userApplicationSupport(
        fileManager: FileManager = .default
    ) throws -> ModelStoragePaths {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return ModelStoragePaths(
            applicationSupportDirectory: applicationSupport
        )
    }

    public func installationDirectory(
        for descriptor: ModelDescriptor
    ) -> URL {
        modelsDirectory.appendingPathComponent(
            descriptor.installationDirectoryName,
            isDirectory: true
        )
    }

    public func stagingDirectory(for descriptor: ModelDescriptor) -> URL {
        modelsDirectory
            .appendingPathComponent(".Downloads", isDirectory: true)
            .appendingPathComponent(
                descriptor.installationDirectoryName,
                isDirectory: true
            )
    }
}
