import AudioCapture
@preconcurrency import CoreML
import FluidAudio
import Foundation

public enum SileroVADModelAvailability: Equatable, Sendable {
    case notDownloaded
    case available
}

public struct SileroVADDownloadProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case listing
        case downloading(completedFiles: Int, totalFiles: Int)
        case compiling(modelName: String)
    }

    public let fractionCompleted: Double
    public let phase: Phase

    public init(fractionCompleted: Double, phase: Phase) {
        self.fractionCompleted = min(max(fractionCompleted, 0), 1)
        self.phase = phase
    }
}

public enum SileroVADError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case modelNotDownloaded(URL)
    case modelLoadFailed(String)
    case detectorNotPrepared
    case invalidFrameSize(Int)
    case invalidProbability(Float)

    public var errorDescription: String? {
        switch self {
        case let .modelNotDownloaded(url):
            "Silero VAD is not downloaded at \(url.path). Use Download Live VAD before recording with live processing."
        case let .modelLoadFailed(message):
            "Silero VAD could not be loaded: \(message)"
        case .detectorNotPrepared:
            "Silero VAD was used before its local model was prepared."
        case let .invalidFrameSize(sampleCount):
            "Silero VAD requires 1 through \(VadManager.chunkSize) samples per frame; received \(sampleCount)."
        case let .invalidProbability(probability):
            "Silero VAD returned an invalid speech probability: \(probability)."
        }
    }
}

public actor SileroVADModelStore {
    public let modelsDirectory: URL

    public init(modelsDirectory: URL? = nil) throws {
        if let modelsDirectory {
            self.modelsDirectory = modelsDirectory
            return
        }

        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        self.modelsDirectory = applicationSupport
            .appendingPathComponent("Scribe", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    public var modelURL: URL {
        modelsDirectory
            .appendingPathComponent(
                Repo.vad.folderName,
                isDirectory: true
            )
            .appendingPathComponent(
                ModelNames.VAD.sileroVadFile,
                isDirectory: true
            )
    }

    public func availability() -> SileroVADModelAvailability {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: modelURL.path,
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
            ? .available
            : .notDownloaded
    }

    @discardableResult
    public func download(
        progress: (@Sendable (SileroVADDownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        ModelHub.offlineMode = false
        defer {
            ModelHub.offlineMode = true
        }
        try await ModelHub.download(
            .vad,
            to: modelsDirectory
        ) { fluidProgress in
            progress?(Self.mapProgress(fluidProgress))
        }
        guard availability() == .available else {
            throw SileroVADError.modelNotDownloaded(modelURL)
        }
        return modelURL
    }

    private nonisolated static func mapProgress(
        _ progress: DownloadProgress
    ) -> SileroVADDownloadProgress {
        let phase: SileroVADDownloadProgress.Phase
        switch progress.phase {
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
        return SileroVADDownloadProgress(
            fractionCompleted: progress.fractionCompleted,
            phase: phase
        )
    }
}

protocol LiveVoiceActivityDetecting: Sendable {
    func prepare() async throws
    func speechProbability(
        for samples: [Float],
        source: AudioCapture.AudioSource
    ) async throws -> Float
    func unload() async
}

actor FluidAudioSileroVAD: LiveVoiceActivityDetecting {
    private let modelURL: URL
    private var manager: VadManager?
    private var streamStates:
        [AudioCapture.AudioSource: VadStreamState] = [:]

    init(modelURL: URL) {
        self.modelURL = modelURL
    }

    func prepare() async throws {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: modelURL.path,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else {
            throw SileroVADError.modelNotDownloaded(modelURL)
        }

        do {
            ModelHub.offlineMode = true
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(
                contentsOf: modelURL,
                configuration: configuration
            )
            manager = VadManager(
                config: VadConfig(
                    defaultThreshold: 0.85,
                    debugMode: false,
                    computeUnits: .cpuAndNeuralEngine
                ),
                vadModel: model
            )
            streamStates = Dictionary(
                uniqueKeysWithValues:
                    AudioCapture.AudioSource.allCases.map {
                    ($0, VadStreamState.initial())
                }
            )
        } catch {
            throw SileroVADError.modelLoadFailed(
                error.localizedDescription
            )
        }
    }

    func speechProbability(
        for samples: [Float],
        source: AudioCapture.AudioSource
    ) async throws -> Float {
        guard let manager else {
            throw SileroVADError.detectorNotPrepared
        }
        guard
            !samples.isEmpty,
            samples.count <= VadManager.chunkSize
        else {
            throw SileroVADError.invalidFrameSize(samples.count)
        }

        let state = streamStates[source] ?? VadStreamState.initial()
        let result = try await manager.processStreamingChunk(
            samples,
            state: state
        )
        guard
            result.probability.isFinite,
            (0...1).contains(result.probability)
        else {
            throw SileroVADError.invalidProbability(
                result.probability
            )
        }
        streamStates[source] = result.state
        return result.probability
    }

    func unload() async {
        manager = nil
        streamStates.removeAll(keepingCapacity: false)
    }
}
