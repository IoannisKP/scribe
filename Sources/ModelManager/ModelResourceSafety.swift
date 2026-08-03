import Foundation

public enum ModelResourceEvidence: Equatable, Codable, Sendable {
    case measured(description: String)
    case upstream(description: String)
}

public struct ModelResourceProfile: Equatable, Codable, Sendable {
    public let downloadBytes: Int64
    public let installedBytes: Int64
    public let peakMemoryBytes: Int64
    public let evidence: ModelResourceEvidence

    public init(
        downloadBytes: Int64,
        installedBytes: Int64,
        peakMemoryBytes: Int64,
        evidence: ModelResourceEvidence
    ) throws {
        guard downloadBytes > 0,
            installedBytes > 0,
            peakMemoryBytes > 0
        else {
            throw ModelResourceProfileError.nonpositiveMeasurement
        }
        let description: String
        switch evidence {
        case let .measured(value), let .upstream(value):
            description = value
        }
        guard !description.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ModelResourceProfileError.missingEvidence
        }
        self.downloadBytes = downloadBytes
        self.installedBytes = installedBytes
        self.peakMemoryBytes = peakMemoryBytes
        self.evidence = evidence
    }
}

public enum ModelResourceProfileError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case nonpositiveMeasurement
    case missingEvidence

    public var errorDescription: String? {
        switch self {
        case .nonpositiveMeasurement:
            "Model disk and memory measurements must all be positive."
        case .missingEvidence:
            "Model resource measurements must name their evidence source."
        }
    }
}

public protocol ModelStorageCapacityProviding: Sendable {
    func availableCapacity(at url: URL) async throws -> Int64
}

public struct VolumeModelStorageCapacityProvider:
    ModelStorageCapacityProviding,
    Sendable
{
    public init() {}

    public func availableCapacity(at url: URL) async throws -> Int64 {
        var candidate = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent != candidate else {
                break
            }
            candidate = parent
        }
        let values = try candidate.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let capacity = values.volumeAvailableCapacityForImportantUsage {
            return max(0, capacity)
        }
        if let capacity = values.volumeAvailableCapacity {
            return Int64(max(0, capacity))
        }
        throw ModelResourceSafetyError.capacityUnavailable
    }
}

public protocol PhysicalMemoryProviding: Sendable {
    func physicalMemoryBytes() async -> Int64
}

public struct SystemPhysicalMemoryProvider:
    PhysicalMemoryProviding,
    Sendable
{
    public init() {}

    public func physicalMemoryBytes() async -> Int64 {
        let bytes = ProcessInfo.processInfo.physicalMemory
        return bytes > UInt64(Int64.max) ? .max : Int64(bytes)
    }
}

public struct ModelResourceSafetyPolicy: Equatable, Sendable {
    public let minimumFreeDiskReserveBytes: Int64
    public let minimumPhysicalMemoryReserveBytes: Int64
    public let maximumPhysicalMemoryFraction: Double

    public init(
        minimumFreeDiskReserveBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
        minimumPhysicalMemoryReserveBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
        maximumPhysicalMemoryFraction: Double = 0.70
    ) {
        self.minimumFreeDiskReserveBytes = max(
            0,
            minimumFreeDiskReserveBytes
        )
        self.minimumPhysicalMemoryReserveBytes = max(
            0,
            minimumPhysicalMemoryReserveBytes
        )
        self.maximumPhysicalMemoryFraction =
            maximumPhysicalMemoryFraction.isFinite
            ? min(max(maximumPhysicalMemoryFraction, 0), 1)
            : 0
    }
}

public enum ModelDiskSafety: Equatable, Sendable {
    case unknownRequirements
    case capacityUnavailable(message: String)
    case sufficient(requiredBytes: Int64, availableBytes: Int64)
    case insufficient(requiredBytes: Int64, availableBytes: Int64)

    public var allowsInstallation: Bool {
        if case .sufficient = self {
            return true
        }
        return false
    }
}

public enum ModelMemorySafety: Equatable, Sendable {
    case unknownRequirements
    case sufficient(
        requiredBytes: Int64,
        budgetBytes: Int64,
        physicalBytes: Int64
    )
    case insufficient(
        requiredBytes: Int64,
        budgetBytes: Int64,
        physicalBytes: Int64
    )

    public var allowsLoading: Bool {
        if case .sufficient = self {
            return true
        }
        return false
    }
}

public struct ModelResourceSafetyEvaluation: Equatable, Sendable {
    public let disk: ModelDiskSafety
    public let memory: ModelMemorySafety

    public var allowsInstallationAndLoading: Bool {
        disk.allowsInstallation && memory.allowsLoading
    }

    public var installationBlocker: ModelResourceSafetyBlocker? {
        switch disk {
        case .sufficient:
            nil
        case .unknownRequirements:
            .diskRequirementsUnknown
        case let .capacityUnavailable(message):
            .diskCapacityUnavailable(message: message)
        case let .insufficient(requiredBytes, availableBytes):
            .insufficientDisk(
                requiredBytes: requiredBytes,
                availableBytes: availableBytes
            )
        }
    }

    public var loadingBlocker: ModelResourceSafetyBlocker? {
        switch memory {
        case .sufficient:
            nil
        case .unknownRequirements:
            .memoryRequirementsUnknown
        case let .insufficient(requiredBytes, budgetBytes, physicalBytes):
            .insufficientMemory(
                requiredBytes: requiredBytes,
                budgetBytes: budgetBytes,
                physicalBytes: physicalBytes
            )
        }
    }
}

public enum ModelResourceSafetyBlocker: Equatable, Sendable {
    case diskRequirementsUnknown
    case diskCapacityUnavailable(message: String)
    case insufficientDisk(requiredBytes: Int64, availableBytes: Int64)
    case memoryRequirementsUnknown
    case insufficientMemory(
        requiredBytes: Int64,
        budgetBytes: Int64,
        physicalBytes: Int64
    )
}

public enum ModelResourceSafetyError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case capacityUnavailable

    public var errorDescription: String? {
        "macOS did not report available model-storage capacity."
    }
}

public actor ModelResourceSafetyEvaluator {
    private let capacityProvider: any ModelStorageCapacityProviding
    private let memoryProvider: any PhysicalMemoryProviding
    private let policy: ModelResourceSafetyPolicy

    public init(
        capacityProvider: any ModelStorageCapacityProviding =
            VolumeModelStorageCapacityProvider(),
        memoryProvider: any PhysicalMemoryProviding =
            SystemPhysicalMemoryProvider(),
        policy: ModelResourceSafetyPolicy = .init()
    ) {
        self.capacityProvider = capacityProvider
        self.memoryProvider = memoryProvider
        self.policy = policy
    }

    public func evaluate(
        _ descriptor: ModelDescriptor,
        in paths: ModelStoragePaths
    ) async -> ModelResourceSafetyEvaluation {
        guard let profile = descriptor.resourceProfile else {
            return ModelResourceSafetyEvaluation(
                disk: .unknownRequirements,
                memory: .unknownRequirements
            )
        }
        let physicalBytes = max(
            0,
            await memoryProvider.physicalMemoryBytes()
        )
        let scaledBudget = Double(physicalBytes)
            * policy.maximumPhysicalMemoryFraction
        let fractionalBudget = scaledBudget < Double(Int64.max)
            ? Int64(scaledBudget)
            : .max
        let reserveBudget = max(
            0,
            physicalBytes - policy.minimumPhysicalMemoryReserveBytes
        )
        let memoryBudget = min(fractionalBudget, reserveBudget)
        let memory: ModelMemorySafety =
            profile.peakMemoryBytes <= memoryBudget
            ? .sufficient(
                requiredBytes: profile.peakMemoryBytes,
                budgetBytes: memoryBudget,
                physicalBytes: physicalBytes
            )
            : .insufficient(
                requiredBytes: profile.peakMemoryBytes,
                budgetBytes: memoryBudget,
                physicalBytes: physicalBytes
            )

        let installation = paths.installationDirectory(for: descriptor)
        var installationIsDirectory: ObjCBool = false
        let isInstalled = FileManager.default.fileExists(
            atPath: installation.path,
            isDirectory: &installationIsDirectory
        ) && installationIsDirectory.boolValue
        let acquisitionBytes = isInstalled
            ? 0
            : max(profile.downloadBytes, profile.installedBytes)
        let requiredDiskBytes = Self.saturatingAdd(
            acquisitionBytes,
            policy.minimumFreeDiskReserveBytes
        )
        let disk: ModelDiskSafety
        do {
            let available = max(
                0,
                try await capacityProvider.availableCapacity(
                    at: paths.modelsDirectory
                )
            )
            disk = available >= requiredDiskBytes
                ? .sufficient(
                    requiredBytes: requiredDiskBytes,
                    availableBytes: available
                )
                : .insufficient(
                    requiredBytes: requiredDiskBytes,
                    availableBytes: available
                )
        } catch {
            disk = .capacityUnavailable(message: error.localizedDescription)
        }
        return ModelResourceSafetyEvaluation(disk: disk, memory: memory)
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }
}
