import Foundation
import ModelManager

public enum WhisperKitModelManagerError:
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
            "Whisper model \(identifier.rawValue) failed validation: \(message)"
        }
    }
}

/// WhisperKit's provider adapter for the shared managed-model lifecycle.
/// Model and tokenizer artifacts are acquired only through explicit calls.
public actor WhisperKitModelManager {
    public let modelsDirectory: URL

    private let catalogue: ModelCatalogue
    private let paths: ModelStoragePaths
    private let registry: ManagedModelRegistry
    private let manifestResolver: HuggingFaceIntegrityManifestResolver
    private var plans: [ModelIdentifier: WhisperDownloadPlan] = [:]
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

    public func directory(for model: WhisperModel) -> URL {
        paths.installationDirectory(for: descriptor(for: model))
    }

    public func availability(
        of model: WhisperModel
    ) async throws -> ManagedModelAvailability {
        try await registry.availability(
            of: model.modelIdentifier,
            validatedBy: Self.validator
        )
    }

    public func downloadState(
        of model: WhisperModel
    ) async -> ManagedModelDownloadState {
        await registry.downloadState(of: model.modelIdentifier)
    }

    public func diskUsage(
        of model: WhisperModel
    ) async throws -> ModelDiskUsage {
        try await registry.diskUsage(of: model.modelIdentifier)
    }

    public func resourceSafety(
        of model: WhisperModel
    ) async throws -> ModelResourceSafetyEvaluation {
        try await registry.resourceSafety(of: model.modelIdentifier)
    }

    @discardableResult
    public func download(_ model: WhisperModel) async throws -> URL {
        let currentAvailability = try await availability(of: model)
        if case let .installed(directory, _) = currentAvailability {
            return directory
        }
        try beginDownload(model.modelIdentifier)
        defer { activeDownloadIdentifier = nil }

        let resolved = try await resolvedArtifacts(for: model)
        let manifest = try ModelIntegrityManifest(
            artifacts: resolved.map(\.integrity)
        )
        let modelPlan = ModelDownloadPlan(
            model: descriptor(for: model),
            integrityManifest: manifest
        )
        let plan = WhisperDownloadPlan(
            managed: modelPlan,
            artifacts: resolved
        )
        plans[model.modelIdentifier] = plan
        let installation = try await registry.install(
            modelPlan,
            using: HuggingFaceFileDownloadTransport(artifacts: resolved)
        )
        let validated = try await availability(of: model)
        guard case .installed = validated else {
            throw WhisperKitModelManagerError.modelValidationFailed(
                model.modelIdentifier,
                "Required Core ML or tokenizer files are missing."
            )
        }
        plans.removeValue(forKey: model.modelIdentifier)
        return installation
    }

    public func pauseDownload(of model: WhisperModel) async throws {
        try await registry.pauseInstallation(of: model.modelIdentifier)
        if activeDownloadIdentifier == model.modelIdentifier {
            activeDownloadIdentifier = nil
        }
    }

    @discardableResult
    public func resumeDownload(of model: WhisperModel) async throws -> URL {
        guard let plan = plans[model.modelIdentifier] else {
            throw ModelDownloadControllerError.noPausedDownload(
                model.modelIdentifier
            )
        }
        try beginDownload(model.modelIdentifier)
        defer { activeDownloadIdentifier = nil }
        let installation = try await registry.resumeInstallation(
            plan.managed,
            using: HuggingFaceFileDownloadTransport(
                artifacts: plan.artifacts
            )
        )
        plans.removeValue(forKey: model.modelIdentifier)
        return installation
    }

    public func cancelDownload(of model: WhisperModel) async throws {
        try await registry.cancelInstallation(of: model.modelIdentifier)
        plans.removeValue(forKey: model.modelIdentifier)
        if activeDownloadIdentifier == model.modelIdentifier {
            activeDownloadIdentifier = nil
        }
    }

    private func resolvedArtifacts(
        for model: WhisperModel
    ) async throws -> [HuggingFaceResolvedArtifact] {
        let modelSource = try HuggingFaceModelSource(
            repository: "argmaxinc/whisperkit-coreml",
            requiredRoots: [model.upstreamFolder],
            strippingRemotePrefix: model.upstreamFolder
        )
        let tokenizerSource = try HuggingFaceModelSource(
            repository: model.tokenizerRepository,
            requiredRoots: ["tokenizer.json", "tokenizer_config.json"]
        )
        let modelArtifacts = try await manifestResolver.resolveArtifacts(
            modelSource
        )
        let tokenizerArtifacts = try await manifestResolver.resolveArtifacts(
            tokenizerSource
        )
        return modelArtifacts + tokenizerArtifacts
    }

    private func descriptor(for model: WhisperModel) -> ModelDescriptor {
        guard let descriptor = catalogue[model.modelIdentifier] else {
            preconditionFailure(
                "The built-in catalogue is missing \(model.modelIdentifier.rawValue)."
            )
        }
        return descriptor
    }

    private func beginDownload(_ identifier: ModelIdentifier) throws {
        if let activeDownloadIdentifier {
            throw WhisperKitModelManagerError.anotherDownloadIsActive(
                activeDownloadIdentifier
            )
        }
        activeDownloadIdentifier = identifier
    }

    private nonisolated static let validator =
        ModelInstallationValidator { descriptor, directory in
            let requiredDirectories = [
                "MelSpectrogram.mlmodelc",
                "AudioEncoder.mlmodelc",
                "TextDecoder.mlmodelc",
            ]
            for name in requiredDirectories {
                let url = directory.appendingPathComponent(
                    name,
                    isDirectory: true
                )
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: url.path,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else {
                    throw WhisperKitModelManagerError.modelValidationFailed(
                        descriptor.id,
                        "Missing \(name)."
                    )
                }
            }
            for name in ["tokenizer.json", "tokenizer_config.json"] {
                let url = directory.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: url.path,
                    isDirectory: &isDirectory
                ), !isDirectory.boolValue else {
                    throw WhisperKitModelManagerError.modelValidationFailed(
                        descriptor.id,
                        "Missing \(name)."
                    )
                }
            }
        }
}

private struct WhisperDownloadPlan: Sendable {
    let managed: ModelDownloadPlan
    let artifacts: [HuggingFaceResolvedArtifact]
}

actor HuggingFaceFileDownloadTransport: ModelDownloadTransport {
    typealias Download = @Sendable (URL) async throws -> URL
    private static let resumeMarker = Data("restart-current-file".utf8)

    private let artifacts: [HuggingFaceResolvedArtifact]
    private let download: Download
    private var transferTask: Task<Void, any Error>?

    init(
        artifacts: [HuggingFaceResolvedArtifact],
        download: @escaping Download =
            HuggingFaceFileDownloadTransport.downloadFromNetwork
    ) {
        self.artifacts = artifacts.sorted {
            $0.integrity.relativePath < $1.integrity.relativePath
        }
        self.download = download
    }

    func transfer(
        to stagingDirectory: URL,
        resumeData _: Data?,
        progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
    ) async throws {
        let artifacts = self.artifacts
        let download = self.download
        let totalBytes = Self.totalBytes(in: artifacts)
        let task = Task {
            var completedBytes: Int64 = 0
            for artifact in artifacts {
                try Task.checkCancellation()
                let target = stagingDirectory.appendingPathComponent(
                    artifact.integrity.relativePath
                )
                let existingSize = try? target.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey]
                )
                if existingSize?.isRegularFile == true,
                    Int64(existingSize?.fileSize ?? -1)
                        == artifact.integrity.expectedByteCount
                {
                    completedBytes = Self.adding(
                        completedBytes,
                        artifact.integrity.expectedByteCount
                    )
                    await progress(
                        Self.progress(completedBytes, totalBytes: totalBytes)
                    )
                    continue
                }
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let temporary = try await download(artifact.downloadURL)
                try FileManager.default.moveItem(at: temporary, to: target)
                completedBytes = Self.adding(
                    completedBytes,
                    artifact.integrity.expectedByteCount
                )
                await progress(
                    Self.progress(completedBytes, totalBytes: totalBytes)
                )
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
    }

    func pause() async -> Data? {
        guard let transferTask else { return nil }
        transferTask.cancel()
        _ = try? await transferTask.value
        return Self.resumeMarker
    }

    func cancel() async {
        guard let transferTask else { return }
        transferTask.cancel()
        _ = try? await transferTask.value
    }

    private nonisolated static func progress(
        _ completedBytes: Int64,
        totalBytes: Int64
    ) -> ModelDownloadProgress {
        ModelDownloadProgress(
            fractionCompleted: totalBytes > 0
                ? Double(completedBytes) / Double(totalBytes)
                : 1,
            downloadedBytes: completedBytes,
            totalBytes: totalBytes
        )
    }

    private nonisolated static func totalBytes(
        in artifacts: [HuggingFaceResolvedArtifact]
    ) -> Int64 {
        artifacts.reduce(0) {
            adding($0, $1.integrity.expectedByteCount)
        }
    }

    private nonisolated static func adding(
        _ lhs: Int64,
        _ rhs: Int64
    ) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    nonisolated static func downloadFromNetwork(
        _ url: URL
    ) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(
            from: url
        )
        guard let response = response as? HTTPURLResponse,
            (200..<300).contains(response.statusCode)
        else {
            throw URLError(.badServerResponse)
        }
        return temporary
    }
}
