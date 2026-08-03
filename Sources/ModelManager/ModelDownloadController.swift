import Foundation

public struct ModelDownloadProgress: Equatable, Sendable {
    public let fractionCompleted: Double
    public let downloadedBytes: Int64
    public let totalBytes: Int64?

    public init(
        fractionCompleted: Double,
        downloadedBytes: Int64,
        totalBytes: Int64?
    ) {
        self.fractionCompleted = min(max(fractionCompleted, 0), 1)
        self.downloadedBytes = max(0, downloadedBytes)
        self.totalBytes = totalBytes.map { max(0, $0) }
    }

    public static let zero = ModelDownloadProgress(
        fractionCompleted: 0,
        downloadedBytes: 0,
        totalBytes: nil
    )
}

public enum ManagedModelDownloadState: Equatable, Sendable {
    case idle
    case downloading(ModelDownloadProgress)
    case pausing
    case paused(ModelDownloadProgress)
    case verifying
    case installed(URL)
    case cancelled
    case failed(message: String)
}

public protocol ModelDownloadTransport: Sendable {
    func transfer(
        to stagingDirectory: URL,
        resumeData: Data?,
        progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
    ) async throws
    func pause() async throws -> Data?
    func cancel() async
}

public struct ModelDownloadPlan: Equatable, Sendable {
    public let model: ModelDescriptor
    public let integrityManifest: ModelIntegrityManifest

    public init(
        model: ModelDescriptor,
        integrityManifest: ModelIntegrityManifest
    ) {
        self.model = model
        self.integrityManifest = integrityManifest
    }
}

public enum ModelDownloadControllerError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case operationInProgress(ModelIdentifier)
    case noPausedDownload(ModelIdentifier)
    case modelAlreadyInstalled(ModelIdentifier, URL)
    case installationFailed(ModelIdentifier, String)

    public var errorDescription: String? {
        switch self {
        case let .operationInProgress(identifier):
            "A download is already active for \(identifier.rawValue)."
        case let .noPausedDownload(identifier):
            "There is no paused download to resume for \(identifier.rawValue)."
        case let .modelAlreadyInstalled(identifier, url):
            "Model \(identifier.rawValue) is already installed at \(url.path)."
        case let .installationFailed(identifier, message):
            "Model \(identifier.rawValue) could not be installed: \(message)"
        }
    }
}

public actor ModelDownloadController {
    private let paths: ModelStoragePaths
    private let verifier: ModelIntegrityVerifier
    private var states: [ModelIdentifier: ManagedModelDownloadState] = [:]
    private var activeTransports:
        [ModelIdentifier: any ModelDownloadTransport] = [:]
    private var resumeData: [ModelIdentifier: Data] = [:]

    public init(
        paths: ModelStoragePaths,
        verifier: ModelIntegrityVerifier = ModelIntegrityVerifier()
    ) {
        self.paths = paths
        self.verifier = verifier
    }

    public func state(
        for identifier: ModelIdentifier
    ) -> ManagedModelDownloadState {
        states[identifier] ?? .idle
    }

    @discardableResult
    public func start(
        _ plan: ModelDownloadPlan,
        using transport: any ModelDownloadTransport
    ) async throws -> URL {
        try await perform(
            plan,
            using: transport,
            suppliedResumeData: nil,
            clearsStaging: true
        )
    }

    @discardableResult
    public func resume(
        _ plan: ModelDownloadPlan,
        using transport: any ModelDownloadTransport
    ) async throws -> URL {
        guard case .paused = state(for: plan.model.id) else {
            throw ModelDownloadControllerError.noPausedDownload(
                plan.model.id
            )
        }
        return try await perform(
            plan,
            using: transport,
            suppliedResumeData: resumeData[plan.model.id],
            clearsStaging: false
        )
    }

    public func pause(_ identifier: ModelIdentifier) async throws {
        guard let transport = activeTransports[identifier] else {
            throw ModelDownloadControllerError.noPausedDownload(identifier)
        }
        let progress: ModelDownloadProgress
        switch state(for: identifier) {
        case let .downloading(currentProgress):
            progress = currentProgress
        case .pausing:
            throw ModelDownloadControllerError.operationInProgress(identifier)
        default:
            throw ModelDownloadControllerError.noPausedDownload(identifier)
        }
        states[identifier] = .pausing
        do {
            let data = try await transport.pause()
            if let data {
                resumeData[identifier] = data
            } else {
                resumeData.removeValue(forKey: identifier)
            }
            activeTransports.removeValue(forKey: identifier)
            states[identifier] = .paused(progress)
        } catch {
            states[identifier] = .failed(message: error.localizedDescription)
            throw error
        }
    }

    public func cancel(
        _ descriptor: ModelDescriptor
    ) async {
        let identifier = descriptor.id
        states[identifier] = .cancelled
        if let transport = activeTransports.removeValue(
            forKey: identifier
        ) {
            await transport.cancel()
        }
        resumeData.removeValue(forKey: identifier)
        try? removeIfPresent(paths.stagingDirectory(for: descriptor))
    }

    public func resetState(_ identifier: ModelIdentifier) throws {
        switch state(for: identifier) {
        case .downloading, .pausing, .verifying:
            throw ModelDownloadControllerError.operationInProgress(identifier)
        case .idle, .paused, .installed, .cancelled, .failed:
            states[identifier] = .idle
            resumeData.removeValue(forKey: identifier)
        }
    }

    private func perform(
        _ plan: ModelDownloadPlan,
        using transport: any ModelDownloadTransport,
        suppliedResumeData: Data?,
        clearsStaging: Bool
    ) async throws -> URL {
        let identifier = plan.model.id
        switch state(for: identifier) {
        case .downloading, .pausing, .verifying:
            throw ModelDownloadControllerError.operationInProgress(identifier)
        default:
            break
        }
        let installation = paths.installationDirectory(for: plan.model)
        guard !FileManager.default.fileExists(atPath: installation.path) else {
            states[identifier] = .installed(installation)
            throw ModelDownloadControllerError.modelAlreadyInstalled(
                identifier,
                installation
            )
        }
        let staging = paths.stagingDirectory(for: plan.model)
        if clearsStaging {
            try removeIfPresent(staging)
        }
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        states[identifier] = .downloading(.zero)
        activeTransports[identifier] = transport

        do {
            try await transport.transfer(
                to: staging,
                resumeData: suppliedResumeData
            ) { [weak self] progress in
                await self?.receive(progress, for: identifier)
            }
            activeTransports.removeValue(forKey: identifier)
            switch state(for: identifier) {
            case .paused, .pausing, .cancelled:
                throw CancellationError()
            default:
                break
            }
            states[identifier] = .verifying
            try await verifier.verify(
                directory: staging,
                manifest: plan.integrityManifest
            )
            try FileManager.default.createDirectory(
                at: paths.modelsDirectory,
                withIntermediateDirectories: true
            )
            do {
                try FileManager.default.moveItem(
                    at: staging,
                    to: installation
                )
            } catch {
                throw ModelDownloadControllerError.installationFailed(
                    identifier,
                    error.localizedDescription
                )
            }
            resumeData.removeValue(forKey: identifier)
            states[identifier] = .installed(installation)
            return installation
        } catch {
            activeTransports.removeValue(forKey: identifier)
            switch state(for: identifier) {
            case .paused, .pausing, .cancelled:
                break
            default:
                if error is ModelIntegrityError {
                    try? removeIfPresent(staging)
                }
                states[identifier] = .failed(
                    message: error.localizedDescription
                )
            }
            throw error
        }
    }

    private func receive(
        _ progress: ModelDownloadProgress,
        for identifier: ModelIdentifier
    ) {
        guard case .downloading = state(for: identifier) else {
            return
        }
        states[identifier] = .downloading(progress)
    }

    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }
}
