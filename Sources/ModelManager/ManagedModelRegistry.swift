import Foundation

/// Moves complete model folders to recoverable storage.
public struct ModelFolderTrash: Sendable {
    private let moveOperation: @Sendable (URL) throws -> URL

    public init(
        moveOperation: @escaping @Sendable (URL) throws -> URL
    ) {
        self.moveOperation = moveOperation
    }

    @discardableResult
    public func move(_ directory: URL) throws -> URL {
        try moveOperation(directory)
    }

    public static let system = ModelFolderTrash { directory in
        var resultingURL: NSURL?
        try FileManager.default.trashItem(
            at: directory,
            resultingItemURL: &resultingURL
        )
        guard let resultingURL else {
            throw CocoaError(.fileWriteUnknown)
        }
        return resultingURL as URL
    }
}

public struct ModelInstallationValidator: Sendable {
    private let validation:
        @Sendable (_ descriptor: ModelDescriptor, _ directory: URL) async throws
            -> Void

    public init(
        validation: @escaping @Sendable (
            _ descriptor: ModelDescriptor,
            _ directory: URL
        ) async throws -> Void
    ) {
        self.validation = validation
    }

    public func validate(
        _ descriptor: ModelDescriptor,
        at directory: URL
    ) async throws {
        try await validation(descriptor, directory)
    }
}

public enum ManagedModelAvailability: Equatable, Sendable {
    case notInstalled(directory: URL)
    case installed(directory: URL, diskUsage: ModelDiskUsage)
    case invalid(directory: URL, message: String)

    public var isInstalled: Bool {
        if case .installed = self {
            return true
        }
        return false
    }
}

public enum ManagedModelRegistryError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case unknownModel(ModelIdentifier)
    case downloadInProgress(ModelIdentifier)
    case invalidUnrecognizedDirectoryName(String)
    case managedDirectoryCannotBeRemoved(String)
    case unrecognizedDirectoryNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownModel(identifier):
            "The model catalogue does not contain \(identifier.rawValue)."
        case let .downloadInProgress(identifier):
            "Cancel or finish the download for \(identifier.rawValue) before deleting it."
        case let .invalidUnrecognizedDirectoryName(name):
            "The unrecognized model folder name is unsafe: \(name)."
        case let .managedDirectoryCannotBeRemoved(name):
            "\(name) is managed by Scribe and cannot be removed as unrecognized data."
        case let .unrecognizedDirectoryNotFound(name):
            "The unrecognized model folder \(name) is no longer present."
        }
    }
}

/// Owns provider-neutral model identity, paths, availability, disk accounting,
/// resource evaluation, and download lifecycle. Provider frameworks stay in
/// adapters that supply validation and transport behavior.
public actor ManagedModelRegistry {
    public let catalogue: ModelCatalogue
    public let paths: ModelStoragePaths

    private let downloads: ModelDownloadController
    private let diskAccounting: ModelDiskAccounting
    private let safetyEvaluator: ModelResourceSafetyEvaluator
    private let folderTrash: ModelFolderTrash

    public init(
        catalogue: ModelCatalogue,
        paths: ModelStoragePaths,
        downloads: ModelDownloadController? = nil,
        diskAccounting: ModelDiskAccounting = ModelDiskAccounting(),
        safetyEvaluator: ModelResourceSafetyEvaluator =
            ModelResourceSafetyEvaluator(),
        folderTrash: ModelFolderTrash = .system
    ) {
        self.catalogue = catalogue
        self.paths = paths
        self.downloads = downloads ?? ModelDownloadController(paths: paths)
        self.diskAccounting = diskAccounting
        self.safetyEvaluator = safetyEvaluator
        self.folderTrash = folderTrash
    }

    public func descriptor(
        for identifier: ModelIdentifier
    ) throws -> ModelDescriptor {
        guard let descriptor = catalogue[identifier] else {
            throw ManagedModelRegistryError.unknownModel(identifier)
        }
        return descriptor
    }

    public func installationDirectory(
        for identifier: ModelIdentifier
    ) throws -> URL {
        paths.installationDirectory(for: try descriptor(for: identifier))
    }

    public func availability(
        of identifier: ModelIdentifier,
        validatedBy validator: ModelInstallationValidator
    ) async throws -> ManagedModelAvailability {
        let descriptor = try descriptor(for: identifier)
        let directory = paths.installationDirectory(for: descriptor)
        let usage = try await diskAccounting.usage(
            of: descriptor,
            in: paths
        )
        guard usage.isInstalled else {
            return .notInstalled(directory: directory)
        }
        do {
            try await validator.validate(descriptor, at: directory)
            return .installed(directory: directory, diskUsage: usage)
        } catch {
            return .invalid(
                directory: directory,
                message: error.localizedDescription
            )
        }
    }

    public func diskUsage(
        of identifier: ModelIdentifier
    ) async throws -> ModelDiskUsage {
        try await diskAccounting.usage(
            of: try descriptor(for: identifier),
            in: paths
        )
    }

    public func resourceSafety(
        of identifier: ModelIdentifier
    ) async throws -> ModelResourceSafetyEvaluation {
        await safetyEvaluator.evaluate(
            try descriptor(for: identifier),
            in: paths
        )
    }

    public func unrecognizedDirectories()
        async throws -> [UnrecognizedModelDirectory]
    {
        let fileManager = FileManager.default
        var modelsIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: paths.modelsDirectory.path,
            isDirectory: &modelsIsDirectory
        ) else {
            return []
        }
        guard modelsIsDirectory.boolValue else {
            throw ModelDiskAccountingError.unableToEnumerate(
                paths.modelsDirectory
            )
        }
        let managedNames = Set(
            catalogue.models.map(\.installationDirectoryName)
        )
        let internalNames: Set<String> = [".Downloads"]
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]
        let children = try fileManager.contentsOfDirectory(
            at: paths.modelsDirectory,
            includingPropertiesForKeys: Array(keys),
            options: []
        )
        var result: [UnrecognizedModelDirectory] = []
        for child in children {
            let name = child.lastPathComponent
            guard !managedNames.contains(name),
                !internalNames.contains(name)
            else {
                continue
            }
            let values = try child.resourceValues(forKeys: keys)
            guard values.isDirectory == true,
                values.isSymbolicLink != true
            else {
                continue
            }
            let usage = try await diskAccounting.usage(
                ofDirectory: child
            )
            result.append(
                UnrecognizedModelDirectory(
                    name: name,
                    url: child.standardizedFileURL,
                    diskUsage: usage
                )
            )
        }
        return result.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    @discardableResult
    public func removeUnrecognizedDirectory(named name: String)
        async throws -> URL
    {
        guard Self.isSafePathComponent(name) else {
            throw ManagedModelRegistryError
                .invalidUnrecognizedDirectoryName(name)
        }
        let managedNames = Set(
            catalogue.models.map(\.installationDirectoryName)
        )
        guard !managedNames.contains(name), name != ".Downloads" else {
            throw ManagedModelRegistryError
                .managedDirectoryCannotBeRemoved(name)
        }
        let directory = paths.modelsDirectory
            .appendingPathComponent(name, isDirectory: true)
            .standardizedFileURL
        guard directory.deletingLastPathComponent()
            == paths.modelsDirectory.standardizedFileURL
        else {
            throw ManagedModelRegistryError
                .invalidUnrecognizedDirectoryName(name)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue
        else {
            throw ManagedModelRegistryError
                .unrecognizedDirectoryNotFound(name)
        }
        let values = try directory.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        )
        guard values.isSymbolicLink != true else {
            throw ManagedModelRegistryError
                .invalidUnrecognizedDirectoryName(name)
        }
        return try folderTrash.move(directory)
    }

    public func downloadState(
        of identifier: ModelIdentifier
    ) async -> ManagedModelDownloadState {
        await downloads.state(for: identifier)
    }

    @discardableResult
    public func install(
        _ plan: ModelDownloadPlan,
        using transport: any ModelDownloadTransport
    ) async throws -> URL {
        guard catalogue[plan.model.id] == plan.model else {
            throw ManagedModelRegistryError.unknownModel(plan.model.id)
        }
        return try await downloads.start(plan, using: transport)
    }

    @discardableResult
    public func resumeInstallation(
        _ plan: ModelDownloadPlan,
        using transport: any ModelDownloadTransport
    ) async throws -> URL {
        guard catalogue[plan.model.id] == plan.model else {
            throw ManagedModelRegistryError.unknownModel(plan.model.id)
        }
        return try await downloads.resume(plan, using: transport)
    }

    public func pauseInstallation(
        of identifier: ModelIdentifier
    ) async throws {
        try await downloads.pause(identifier)
    }

    public func cancelInstallation(
        of identifier: ModelIdentifier
    ) async throws {
        await downloads.cancel(try descriptor(for: identifier))
    }

    @discardableResult
    public func removeInstallation(
        of identifier: ModelIdentifier
    ) async throws -> URL? {
        switch await downloads.state(for: identifier) {
        case .downloading, .pausing, .paused, .verifying:
            throw ManagedModelRegistryError.downloadInProgress(identifier)
        case .idle, .installed, .cancelled, .failed:
            break
        }
        let descriptor = try descriptor(for: identifier)
        let directory = paths.installationDirectory(for: descriptor)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ) else {
            try await downloads.resetState(identifier)
            return nil
        }
        guard isDirectory.boolValue else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let trashedDirectory = try folderTrash.move(directory)
        try await downloads.resetState(identifier)
        return trashedDirectory
    }

    private static func isSafePathComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.contains("/")
            && !component.contains(":")
            && !component.contains("\\")
    }
}
