import Foundation

public struct ModelIdentifier:
    RawRepresentable,
    Hashable,
    Codable,
    Sendable
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum ModelProvider: String, Codable, Sendable {
    case fluidAudio
    case whisperKit
}

public enum ModelTask: String, Codable, Sendable {
    case transcription
    case voiceActivityDetection
}

public enum ModelQuantization: String, Codable, Sendable {
    case uncompressedCoreML
    case int8
    case fourBitCompressed
    case qloraCompressed
}

public enum ModelSpeedRating: String, Codable, Sendable {
    case fastest
    case fast
    case balanced
    case quality
}

public struct ModelWindowGeometry: Equatable, Codable, Sendable {
    public let duration: TimeInterval
    public let overlap: TimeInterval

    public init(duration: TimeInterval, overlap: TimeInterval) {
        self.duration = duration
        self.overlap = overlap
    }
}

public struct ModelDescriptor: Identifiable, Equatable, Codable, Sendable {
    public let id: ModelIdentifier
    public let displayName: String
    public let detail: String
    public let provider: ModelProvider
    public let task: ModelTask
    public let installationDirectoryName: String
    public let supportedLanguages: [String]
    public let supportsLiveProcessing: Bool
    public let windowGeometry: ModelWindowGeometry?
    public let parameterCountMillions: Int?
    public let quantization: ModelQuantization?
    public let speedRating: ModelSpeedRating?
    public let resourceProfile: ModelResourceProfile?

    public init(
        id: ModelIdentifier,
        displayName: String,
        detail: String,
        provider: ModelProvider,
        task: ModelTask,
        installationDirectoryName: String,
        supportedLanguages: [String],
        supportsLiveProcessing: Bool,
        windowGeometry: ModelWindowGeometry?,
        parameterCountMillions: Int? = nil,
        quantization: ModelQuantization? = nil,
        speedRating: ModelSpeedRating? = nil,
        resourceProfile: ModelResourceProfile? = nil
    ) throws {
        guard !id.rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ModelCatalogueError.emptyIdentifier
        }
        guard !displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ModelCatalogueError.emptyDisplayName(id)
        }
        guard Self.isSafePathComponent(installationDirectoryName) else {
            throw ModelCatalogueError.invalidInstallationDirectory(
                installationDirectoryName
            )
        }
        switch task {
        case .transcription:
            guard !supportedLanguages.isEmpty else {
                throw ModelCatalogueError.missingTranscriptionLanguages(id)
            }
            guard let windowGeometry else {
                throw ModelCatalogueError.missingWindowGeometry(id)
            }
            guard windowGeometry.duration.isFinite,
                windowGeometry.duration > 0
            else {
                throw ModelCatalogueError.invalidWindowDuration(
                    id,
                    windowGeometry.duration
                )
            }
            guard windowGeometry.overlap.isFinite,
                windowGeometry.overlap >= 0,
                windowGeometry.overlap < windowGeometry.duration
            else {
                throw ModelCatalogueError.invalidWindowOverlap(
                    id,
                    windowGeometry.overlap
                )
            }
        case .voiceActivityDetection:
            guard windowGeometry == nil else {
                throw ModelCatalogueError.unexpectedWindowGeometry(id)
            }
        }
        if let parameterCountMillions, parameterCountMillions <= 0 {
            throw ModelCatalogueError.invalidParameterCount(
                id,
                parameterCountMillions
            )
        }

        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.provider = provider
        self.task = task
        self.installationDirectoryName = installationDirectoryName
        self.supportedLanguages = Array(Set(supportedLanguages)).sorted()
        self.supportsLiveProcessing = supportsLiveProcessing
        self.windowGeometry = windowGeometry
        self.parameterCountMillions = parameterCountMillions
        self.quantization = quantization
        self.speedRating = speedRating
        self.resourceProfile = resourceProfile
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

public enum ModelCatalogueError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case emptyIdentifier
    case emptyDisplayName(ModelIdentifier)
    case invalidInstallationDirectory(String)
    case missingTranscriptionLanguages(ModelIdentifier)
    case missingWindowGeometry(ModelIdentifier)
    case unexpectedWindowGeometry(ModelIdentifier)
    case invalidWindowDuration(ModelIdentifier, TimeInterval)
    case invalidWindowOverlap(ModelIdentifier, TimeInterval)
    case invalidParameterCount(ModelIdentifier, Int)
    case duplicateIdentifier(ModelIdentifier)
    case duplicateInstallationDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .emptyIdentifier:
            "A model descriptor has an empty identifier."
        case let .emptyDisplayName(identifier):
            "Model \(identifier.rawValue) has an empty display name."
        case let .invalidInstallationDirectory(directory):
            "Model installation directory ‘\(directory)’ is not one safe path component."
        case let .missingTranscriptionLanguages(identifier):
            "Transcription model \(identifier.rawValue) declares no supported languages."
        case let .missingWindowGeometry(identifier):
            "Transcription model \(identifier.rawValue) declares no window geometry."
        case let .unexpectedWindowGeometry(identifier):
            "Non-transcription model \(identifier.rawValue) unexpectedly declares transcription window geometry."
        case let .invalidWindowDuration(identifier, duration):
            "Model \(identifier.rawValue) has invalid window duration \(duration)."
        case let .invalidWindowOverlap(identifier, overlap):
            "Model \(identifier.rawValue) has invalid window overlap \(overlap)."
        case let .invalidParameterCount(identifier, count):
            "Model \(identifier.rawValue) has invalid parameter count \(count) million."
        case let .duplicateIdentifier(identifier):
            "Model identifier \(identifier.rawValue) appears more than once."
        case let .duplicateInstallationDirectory(directory):
            "Model installation directory \(directory) appears more than once."
        }
    }
}
