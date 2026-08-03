import AudioCapture
@preconcurrency import CoreML
import FluidAudio
import Foundation
import ModelManager

public enum ParakeetModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case v3Multilingual
    case v2English

    public var id: String { rawValue }

    private static let catalogue: ModelCatalogue = {
        do {
            return try ScribeModelCatalogue.builtIn()
        } catch {
            preconditionFailure(
                "Scribe's built-in model catalogue is invalid: \(error)"
            )
        }
    }()

    public var modelIdentifier: ModelIdentifier {
        switch self {
        case .v3Multilingual:
            ScribeModelIdentifiers.parakeetV3Multilingual
        case .v2English:
            ScribeModelIdentifiers.parakeetV2English
        }
    }

    public var descriptor: ModelDescriptor {
        guard let descriptor = Self.catalogue[modelIdentifier] else {
            preconditionFailure(
                "The built-in catalogue is missing \(modelIdentifier.rawValue)."
            )
        }
        return descriptor
    }

    public var displayName: String {
        descriptor.displayName
    }

    public var detail: String {
        descriptor.detail
    }

    public var directoryName: String {
        descriptor.installationDirectoryName
    }

    public var supportedLanguages: [String] {
        descriptor.supportedLanguages
    }

    var fluidVersion: AsrModelVersion {
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
    public nonisolated var preferredWindowDuration: TimeInterval {
        model.descriptor.windowGeometry?.duration ?? 14
    }
    public nonisolated var preferredOverlap: TimeInterval {
        model.descriptor.windowGeometry?.overlap ?? 1.5
    }

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

        let startTime: TimeInterval
        let endTime: TimeInterval
        if let firstWord = words.first, let lastWord = words.last {
            startTime = firstWord.startTime
            endTime = lastWord.endTime
        } else {
            let fallbackDuration = min(
                max(result.duration, 0),
                chunk.duration
            )
            startTime = chunk.startTime
            endTime = chunk.startTime + fallbackDuration
        }
        guard
            startTime.isFinite,
            endTime.isFinite,
            startTime >= chunk.startTime,
            endTime >= startTime,
            endTime <= chunk.endTime
        else {
            throw ParakeetEngineError.invalidResultTiming
        }
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
