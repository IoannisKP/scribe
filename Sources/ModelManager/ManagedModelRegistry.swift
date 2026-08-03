import Foundation

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

    public var errorDescription: String? {
        switch self {
        case let .unknownModel(identifier):
            "The model catalogue does not contain \(identifier.rawValue)."
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

    public init(
        catalogue: ModelCatalogue,
        paths: ModelStoragePaths,
        downloads: ModelDownloadController? = nil,
        diskAccounting: ModelDiskAccounting = ModelDiskAccounting(),
        safetyEvaluator: ModelResourceSafetyEvaluator =
            ModelResourceSafetyEvaluator()
    ) {
        self.catalogue = catalogue
        self.paths = paths
        self.downloads = downloads ?? ModelDownloadController(paths: paths)
        self.diskAccounting = diskAccounting
        self.safetyEvaluator = safetyEvaluator
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
}
