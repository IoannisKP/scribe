import AudioCapture
@preconcurrency import CoreML
import FluidAudio
import Foundation

public enum ParakeetModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case v3Multilingual
    case v2English

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .v3Multilingual:
            "Parakeet v3 · Multilingual"
        case .v2English:
            "Parakeet v2 · English"
        }
    }

    public var detail: String {
        switch self {
        case .v3Multilingual:
            "25 languages, including Greek"
        case .v2English:
            "English-only model"
        }
    }

    public var directoryName: String {
        switch self {
        case .v3Multilingual:
            "parakeet-tdt-0.6b-v3-coreml"
        case .v2English:
            "parakeet-tdt-0.6b-v2-coreml"
        }
    }

    public var supportedLanguages: [String] {
        switch self {
        case .v3Multilingual:
            [
                "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr",
                "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt",
                "ro", "ru", "sk", "sl", "es", "sv", "uk",
            ]
        case .v2English:
            ["en"]
        }
    }

    fileprivate var fluidVersion: AsrModelVersion {
        switch self {
        case .v3Multilingual:
            .v3
        case .v2English:
            .v2
        }
    }
}

public enum ParakeetModelAvailability: Equatable, Sendable {
    case notDownloaded
    case available
}

public struct ParakeetDownloadProgress: Equatable, Sendable {
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

public enum ParakeetEngineError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedPlatform
    case modelNotDownloaded(model: ParakeetModel, directory: URL)
    case invalidResultTiming

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            "Parakeet transcription requires an Apple Silicon Mac."
        case let .modelNotDownloaded(model, directory):
            "\(model.displayName) is not downloaded at \(directory.path). Use Download Model before transcribing."
        case .invalidResultTiming:
            "Parakeet returned timestamps that could not be mapped to the recording timeline."
        }
    }
}

public actor ParakeetModelStore {
    public let rootDirectory: URL

    public init(rootDirectory: URL? = nil) throws {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
            return
        }

        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        self.rootDirectory = applicationSupport
            .appendingPathComponent("Scribe", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    public func directory(for model: ParakeetModel) -> URL {
        rootDirectory.appendingPathComponent(
            model.directoryName,
            isDirectory: true
        )
    }

    public func availability(
        of model: ParakeetModel
    ) -> ParakeetModelAvailability {
        AsrModels.modelsExist(
            at: directory(for: model),
            version: model.fluidVersion,
            encoderPrecision: .int8
        )
            ? .available
            : .notDownloaded
    }

    @discardableResult
    public func download(
        _ model: ParakeetModel,
        progress: (@Sendable (ParakeetDownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        ModelHub.offlineMode = false
        defer {
            ModelHub.offlineMode = true
        }
        let targetDirectory = directory(for: model)
        let downloadedDirectory = try await AsrModels.download(
            to: targetDirectory,
            version: model.fluidVersion,
            encoderPrecision: .int8
        ) { fluidProgress in
            progress?(Self.mapProgress(fluidProgress))
        }

        guard availability(of: model) == .available else {
            throw ParakeetEngineError.modelNotDownloaded(
                model: model,
                directory: downloadedDirectory
            )
        }
        return downloadedDirectory
    }

    private nonisolated static func mapProgress(
        _ progress: DownloadProgress
    ) -> ParakeetDownloadProgress {
        let phase: ParakeetDownloadProgress.Phase
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
        return ParakeetDownloadProgress(
            fractionCompleted: progress.fractionCompleted,
            phase: phase
        )
    }
}

struct ParakeetBackendResult: Sendable {
    let text: String
    let confidence: Float
    let duration: TimeInterval
    let words: [ParakeetBackendWord]
}

struct ParakeetBackendWord: Sendable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

protocol ParakeetEngineBackend: Sendable {
    func prepare(
        model: ParakeetModel,
        directory: URL
    ) async throws
    func transcribe(samples: [Float]) async throws -> ParakeetBackendResult
    func unload() async
}

actor FluidAudioParakeetBackend: ParakeetEngineBackend {
    private var manager: AsrManager?

    func prepare(
        model: ParakeetModel,
        directory: URL
    ) async throws {
        #if arch(arm64)
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

        ModelHub.offlineMode = true
        let models = try await AsrModels.load(
            from: directory,
            version: model.fluidVersion,
            encoderPrecision: .int8
        )
        manager = AsrManager(config: .default, models: models)
        #else
        throw ParakeetEngineError.unsupportedPlatform
        #endif
    }

    func transcribe(
        samples: [Float]
    ) async throws -> ParakeetBackendResult {
        guard let manager else {
            throw ASRError.notInitialized
        }
        let minimumSampleCount = ASRConstants.minimumRequiredSamples(
            forSampleRate: ASRConstants.sampleRate
        )
        var inferenceSamples = samples
        if inferenceSamples.count < minimumSampleCount {
            inferenceSamples.append(
                contentsOf: repeatElement(
                    0,
                    count: minimumSampleCount - inferenceSamples.count
                )
            )
        }
        var decoderState = try TdtDecoderState(decoderLayers: 2)
        let result = try await manager.transcribe(
            inferenceSamples,
            decoderState: &decoderState
        )
        let words = buildWordTimings(from: result.tokenTimings ?? []).map {
            ParakeetBackendWord(
                text: $0.word,
                startTime: $0.startTime,
                endTime: $0.endTime
            )
        }
        return ParakeetBackendResult(
            text: result.text,
            confidence: result.confidence,
            duration: result.duration,
            words: words
        )
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }
}

public actor ParakeetTranscriptionEngine: TranscriptionEngine {
    public nonisolated let model: ParakeetModel
    public nonisolated let modelDirectory: URL
    private let backend: any ParakeetEngineBackend

    public nonisolated var identifier: String {
        "fluidaudio.parakeet.\(model.rawValue)"
    }

    public nonisolated let supportsStreaming = false
    public nonisolated let requiresNetwork = false
    public nonisolated let preferredWindowDuration: TimeInterval = 14
    public nonisolated let preferredOverlap: TimeInterval = 1.5

    public nonisolated var supportedLanguages: [String] {
        model.supportedLanguages
    }

    public init(
        model: ParakeetModel,
        modelDirectory: URL
    ) {
        self.model = model
        self.modelDirectory = modelDirectory
        self.backend = FluidAudioParakeetBackend()
    }

    init(
        model: ParakeetModel,
        modelDirectory: URL,
        backend: any ParakeetEngineBackend
    ) {
        self.model = model
        self.modelDirectory = modelDirectory
        self.backend = backend
    }

    public func prepare() async throws {
        try await backend.prepare(
            model: model,
            directory: modelDirectory
        )
    }

    public func transcribe(
        _ chunk: AudioChunk
    ) async throws -> [TranscriptSegment] {
        let result = try await backend.transcribe(samples: chunk.samples)
        return try Self.map(result: result, onto: chunk)
    }

    public func finish() async throws -> [TranscriptSegment] {
        []
    }

    public func unload() async {
        await backend.unload()
    }

    static func map(
        result: ParakeetBackendResult,
        onto chunk: AudioChunk
    ) throws -> [TranscriptSegment] {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return []
        }

        let words = result.words.compactMap { word -> WordTiming? in
            guard word.startTime.isFinite,
                word.endTime.isFinite,
                word.startTime >= 0,
                word.endTime >= word.startTime
            else {
                return nil
            }
            let start = min(chunk.endTime, chunk.startTime + word.startTime)
            let end = min(chunk.endTime, chunk.startTime + word.endTime)
            guard end >= start else {
                return nil
            }
            return WordTiming(
                text: word.text,
                startTime: start,
                endTime: end,
                confidence: result.confidence
            )
        }

        let localStart = words.first.map { $0.startTime - chunk.startTime } ?? 0
        let fallbackDuration = min(max(result.duration, 0), chunk.duration)
        let localEnd =
            words.last.map { $0.endTime - chunk.startTime }
            ?? fallbackDuration
        guard localStart.isFinite,
            localEnd.isFinite,
            localStart >= 0,
            localEnd >= localStart
        else {
            throw ParakeetEngineError.invalidResultTiming
        }

        let startTime = min(chunk.endTime, chunk.startTime + localStart)
        let endTime = min(
            chunk.endTime,
            max(startTime, chunk.startTime + localEnd)
        )
        return [
            TranscriptSegment(
                text: text,
                startTime: startTime,
                endTime: endTime,
                source: chunk.source,
                confidence: result.confidence,
                words: words.isEmpty ? nil : words
            )
        ]
    }
}
