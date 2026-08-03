@preconcurrency import CoreML
import FluidAudio
import Foundation
import ModelManager

public enum FluidAudioModelManagerError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case anotherDownloadIsActive(ModelIdentifier)
    case modelValidationFailed(ModelIdentifier, String)

    public var errorDescription: String? {
        switch self {
        case let .anotherDownloadIsActive(identifier):
            "Wait for the active model download (\(identifier.rawValue)) to finish or cancel it first."
        case let .modelValidationFailed(identifier, message):
            "The downloaded model \(identifier.rawValue) failed provider validation: \(message)"
        }
    }
}

/// FluidAudio's provider adapter for the shared ModelManager lifecycle.
/// Inference remains offline; only explicit install/resume calls temporarily
/// enable FluidAudio's network surface.
public actor FluidAudioModelManager {
    public let modelsDirectory: URL

    private let registry: ManagedModelRegistry
    private let catalogue: ModelCatalogue
    private let paths: ModelStoragePaths
    private let manifestResolver: HuggingFaceIntegrityManifestResolver
    private var plans: [ModelIdentifier: ModelDownloadPlan] = [:]
    private var activeDownloadIdentifier: ModelIdentifier?

    public init(modelsDirectory: URL? = nil) throws {
        let paths = if let modelsDirectory {
            ModelStoragePaths(modelsDirectory: modelsDirectory)
        } else {
            try ModelStoragePaths.userApplicationSupport()
        }
        let catalogue = try ScribeModelCatalogue.builtIn()
        self.modelsDirectory = paths.modelsDirectory
        self.paths = paths
        self.catalogue = catalogue
        self.registry = ManagedModelRegistry(
            catalogue: catalogue,
            paths: paths
        )
        self.manifestResolver = HuggingFaceIntegrityManifestResolver()
    }

    init(
        paths: ModelStoragePaths,
        catalogue: ModelCatalogue,
        manifestResolver: HuggingFaceIntegrityManifestResolver
    ) {
        self.modelsDirectory = paths.modelsDirectory
        self.paths = paths
        self.catalogue = catalogue
        self.registry = ManagedModelRegistry(
            catalogue: catalogue,
            paths: paths
        )
        self.manifestResolver = manifestResolver
    }

    public func directory(for model: ParakeetModel) -> URL {
        directory(for: model.modelIdentifier)
    }

    public var sileroModelURL: URL {
        directory(for: ScribeModelIdentifiers.sileroVAD)
            .appendingPathComponent(
                ModelNames.VAD.sileroVadFile,
                isDirectory: true
            )
    }

    public func availability(
        of model: ParakeetModel
    ) async -> ParakeetModelAvailability {
        do {
            let availability = try await registry.availability(
                of: model.modelIdentifier,
                validatedBy: Self.parakeetValidator(for: model)
            )
            return availability.isInstalled ? .available : .notDownloaded
        } catch {
            return .notDownloaded
        }
    }

    public func sileroAvailability() async -> SileroVADModelAvailability {
        do {
            let availability = try await registry.availability(
                of: ScribeModelIdentifiers.sileroVAD,
                validatedBy: Self.sileroValidator
            )
            return availability.isInstalled ? .available : .notDownloaded
        } catch {
            return .notDownloaded
        }
    }

    public func managedAvailability(
        of identifier: ModelIdentifier
    ) async throws -> ManagedModelAvailability {
        if identifier == ScribeModelIdentifiers.sileroVAD {
            return try await registry.availability(
                of: identifier,
                validatedBy: Self.sileroValidator
            )
        }
        guard let model = ParakeetModel.allCases.first(
            where: { $0.modelIdentifier == identifier }
        ) else {
            throw ManagedModelRegistryError.unknownModel(identifier)
        }
        return try await registry.availability(
            of: identifier,
            validatedBy: Self.parakeetValidator(for: model)
        )
    }

    public func downloadState(
        of identifier: ModelIdentifier
    ) async -> ManagedModelDownloadState {
        await registry.downloadState(of: identifier)
    }

    public func diskUsage(
        of identifier: ModelIdentifier
    ) async throws -> ModelDiskUsage {
        try await registry.diskUsage(of: identifier)
    }

    public func resourceSafety(
        of identifier: ModelIdentifier
    ) async throws -> ModelResourceSafetyEvaluation {
        try await registry.resourceSafety(of: identifier)
    }

    @discardableResult
    public func download(
        _ model: ParakeetModel,
        progress: (@Sendable (ParakeetDownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        try await install(
            .parakeet(model),
            detailedProgress: progress.map(DetailedProgress.parakeet)
        )
    }

    @discardableResult
    public func downloadSileroVAD(
        progress: (@Sendable (SileroVADDownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        try await install(
            .silero,
            detailedProgress: progress.map(DetailedProgress.silero)
        )
    }

    public func pauseDownload(
        of identifier: ModelIdentifier
    ) async throws {
        try await registry.pauseInstallation(of: identifier)
        if activeDownloadIdentifier == identifier {
            activeDownloadIdentifier = nil
        }
    }

    @discardableResult
    public func resumeDownload(
        of identifier: ModelIdentifier
    ) async throws -> URL {
        let target = try target(for: identifier)
        guard let plan = plans[identifier] else {
            throw ModelDownloadControllerError.noPausedDownload(identifier)
        }
        try beginDownload(identifier)
        defer { activeDownloadIdentifier = nil }
        let transport = FluidAudioModelDownloadTransport(
            target: target,
            expectedBytes: Self.totalBytes(in: plan.integrityManifest),
            detailedProgress: nil
        )
        let installation = try await registry.resumeInstallation(
            plan,
            using: transport
        )
        plans.removeValue(forKey: identifier)
        return installation
    }

    public func cancelDownload(
        of identifier: ModelIdentifier
    ) async throws {
        try await registry.cancelInstallation(of: identifier)
        plans.removeValue(forKey: identifier)
        if activeDownloadIdentifier == identifier {
            activeDownloadIdentifier = nil
        }
    }

    public func removeModel(
        identifiedBy identifier: ModelIdentifier
    ) async throws {
        try await registry.removeInstallation(of: identifier)
    }

    private func install(
        _ target: FluidAudioManagedTarget,
        detailedProgress: DetailedProgress?
    ) async throws -> URL {
        let identifier = target.identifier
        let currentAvailability = try await managedAvailability(of: identifier)
        if case let .installed(directory, _) = currentAvailability {
            return directory
        }
        try beginDownload(identifier)
        defer { activeDownloadIdentifier = nil }

        let descriptor = descriptor(for: identifier)
        let manifest = try await manifestResolver.resolve(target.source)
        let plan = ModelDownloadPlan(
            model: descriptor,
            integrityManifest: manifest
        )
        plans[identifier] = plan
        let transport = FluidAudioModelDownloadTransport(
            target: target,
            expectedBytes: Self.totalBytes(in: manifest),
            detailedProgress: detailedProgress
        )
        let installation = try await registry.install(plan, using: transport)
        let validated = try await managedAvailability(of: identifier)
        guard case .installed = validated else {
            throw FluidAudioModelManagerError.modelValidationFailed(
                identifier,
                "FluidAudio did not recognize every required local artifact."
            )
        }
        plans.removeValue(forKey: identifier)
        return installation
    }

    private func beginDownload(_ identifier: ModelIdentifier) throws {
        if let activeDownloadIdentifier {
            throw FluidAudioModelManagerError.anotherDownloadIsActive(
                activeDownloadIdentifier
            )
        }
        activeDownloadIdentifier = identifier
    }

    private func target(
        for identifier: ModelIdentifier
    ) throws -> FluidAudioManagedTarget {
        if identifier == ScribeModelIdentifiers.sileroVAD {
            return .silero
        }
        guard let model = ParakeetModel.allCases.first(
            where: { $0.modelIdentifier == identifier }
        ) else {
            throw ManagedModelRegistryError.unknownModel(identifier)
        }
        return .parakeet(model)
    }

    private func descriptor(
        for identifier: ModelIdentifier
    ) -> ModelDescriptor {
        guard let descriptor = catalogue[identifier] else {
            preconditionFailure(
                "The built-in catalogue is missing \(identifier.rawValue)."
            )
        }
        return descriptor
    }

    private func directory(for identifier: ModelIdentifier) -> URL {
        paths.installationDirectory(for: descriptor(for: identifier))
    }

    private nonisolated static func parakeetValidator(
        for model: ParakeetModel
    ) -> ModelInstallationValidator {
        ModelInstallationValidator { _, directory in
            guard AsrModels.modelsExist(
                at: directory,
                version: model.fluidVersion,
                encoderPrecision: .int8
            ) else {
                throw ParakeetEngineError.modelNotDownloaded(
                    model: model,
                    directory: directory
                )
            }
        }
    }

    private nonisolated static let sileroValidator =
        ModelInstallationValidator { _, directory in
            let modelURL = directory.appendingPathComponent(
                ModelNames.VAD.sileroVadFile,
                isDirectory: true
            )
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: modelURL.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw SileroVADError.modelNotDownloaded(modelURL)
            }
        }

    private nonisolated static func totalBytes(
        in manifest: ModelIntegrityManifest
    ) -> Int64 {
        manifest.artifacts.reduce(0) { total, artifact in
            let (sum, overflow) = total.addingReportingOverflow(
                artifact.expectedByteCount
            )
            return overflow ? .max : sum
        }
    }
}

private enum FluidAudioManagedTarget: Sendable {
    case parakeet(ParakeetModel)
    case silero

    var identifier: ModelIdentifier {
        switch self {
        case let .parakeet(model):
            model.modelIdentifier
        case .silero:
            ScribeModelIdentifiers.sileroVAD
        }
    }

    var source: HuggingFaceModelSource {
        get throws {
            switch self {
            case let .parakeet(model):
                let joint = model == .v3Multilingual
                    ? ModelNames.ASR.jointV3File
                    : ModelNames.ASR.jointFile
                let repository = model == .v3Multilingual
                    ? Repo.parakeetV3.remotePath
                    : Repo.parakeetV2.remotePath
                return try HuggingFaceModelSource(
                    repository: repository,
                    requiredRoots: [
                        ModelNames.ASR.preprocessorFile,
                        ModelNames.ASR.encoderFile,
                        ModelNames.ASR.decoderFile,
                        joint,
                        ModelNames.ASR.vocabularyFile,
                    ]
                )
            case .silero:
                return try HuggingFaceModelSource(
                    repository: Repo.vad.remotePath,
                    requiredRoots: [ModelNames.VAD.sileroVadFile]
                )
            }
        }
    }
}

private enum DetailedProgress: Sendable {
    case parakeet(@Sendable (ParakeetDownloadProgress) -> Void)
    case silero(@Sendable (SileroVADDownloadProgress) -> Void)

    func report(_ progress: DownloadProgress) {
        switch self {
        case let .parakeet(callback):
            callback(ParakeetDownloadProgress(fluidProgress: progress))
        case let .silero(callback):
            callback(SileroVADDownloadProgress(fluidProgress: progress))
        }
    }
}

private actor FluidAudioModelDownloadTransport: ModelDownloadTransport {
    private static let resumeMarker = Data("restart-incomplete-files".utf8)

    private let target: FluidAudioManagedTarget
    private let expectedBytes: Int64
    private let detailedProgress: DetailedProgress?
    private var transferTask: Task<Void, any Error>?

    init(
        target: FluidAudioManagedTarget,
        expectedBytes: Int64,
        detailedProgress: DetailedProgress?
    ) {
        self.target = target
        self.expectedBytes = expectedBytes
        self.detailedProgress = detailedProgress
    }

    func transfer(
        to stagingDirectory: URL,
        resumeData _: Data?,
        progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
    ) async throws {
        let target = self.target
        let expectedBytes = self.expectedBytes
        let detailedProgress = self.detailedProgress
        let task = Task {
            ModelHub.offlineMode = false
            defer { ModelHub.offlineMode = true }
            let fluidProgress: @Sendable (DownloadProgress) -> Void = {
                snapshot in
                detailedProgress?.report(snapshot)
                let fraction = snapshot.fractionCompleted.isFinite
                    ? min(max(snapshot.fractionCompleted, 0), 1)
                    : 0
                let downloaded = fraction == 1
                    ? expectedBytes
                    : Int64(Double(expectedBytes) * fraction)
                Task {
                    await progress(
                        ModelDownloadProgress(
                            fractionCompleted: fraction,
                            downloadedBytes: downloaded,
                            totalBytes: expectedBytes
                        )
                    )
                }
            }
            switch target {
            case let .parakeet(model):
                _ = try await AsrModels.download(
                    to: stagingDirectory,
                    version: model.fluidVersion,
                    encoderPrecision: .int8,
                    progressHandler: fluidProgress
                )
                guard AsrModels.modelsExist(
                    at: stagingDirectory,
                    version: model.fluidVersion,
                    encoderPrecision: .int8
                ) else {
                    throw FluidAudioModelManagerError.modelValidationFailed(
                        model.modelIdentifier,
                        "FluidAudio did not find every Parakeet artifact in staging."
                    )
                }
            case .silero:
                try await ModelHub.download(
                    .vad,
                    to: stagingDirectory.deletingLastPathComponent(),
                    progressHandler: fluidProgress
                )
                let modelURL = stagingDirectory.appendingPathComponent(
                    ModelNames.VAD.sileroVadFile,
                    isDirectory: true
                )
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: modelURL.path,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else {
                    throw FluidAudioModelManagerError.modelValidationFailed(
                        ScribeModelIdentifiers.sileroVAD,
                        "FluidAudio did not find the Silero Core ML bundle in staging."
                    )
                }
            }
        }
        transferTask = task
        defer { transferTask = nil }
        do {
            try await task.value
        } catch {
            if task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
        await progress(
            ModelDownloadProgress(
                fractionCompleted: 1,
                downloadedBytes: expectedBytes,
                totalBytes: expectedBytes
            )
        )
    }

    func pause() async -> Data? {
        guard let transferTask else {
            return nil
        }
        transferTask.cancel()
        _ = try? await transferTask.value
        return Self.resumeMarker
    }

    func cancel() async {
        guard let transferTask else {
            return
        }
        transferTask.cancel()
        _ = try? await transferTask.value
    }
}

private extension ParakeetDownloadProgress {
    init(fluidProgress: DownloadProgress) {
        let phase: Phase
        switch fluidProgress.phase {
        case .listing:
            phase = .listing
        case let .downloading(completedFiles, totalFiles):
            phase = .downloading(
                completedFiles: completedFiles,
                totalFiles: totalFiles
            )
        case let .compiling(modelName):
            phase = .compiling(modelName: modelName)
        }
        self.init(
            fractionCompleted: fluidProgress.fractionCompleted,
            phase: phase
        )
    }
}

private extension SileroVADDownloadProgress {
    init(fluidProgress: DownloadProgress) {
        let phase: Phase
        switch fluidProgress.phase {
        case .listing:
            phase = .listing
        case let .downloading(completedFiles, totalFiles):
            phase = .downloading(
                completedFiles: completedFiles,
                totalFiles: totalFiles
            )
        case let .compiling(modelName):
            phase = .compiling(modelName: modelName)
        }
        self.init(
            fractionCompleted: fluidProgress.fractionCompleted,
            phase: phase
        )
    }
}
