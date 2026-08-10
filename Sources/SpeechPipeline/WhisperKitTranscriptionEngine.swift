import Foundation
import ModelManager
import WhisperKit

public enum WhisperKitEngineError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case modelNotDownloaded(model: WhisperModel, directory: URL)
    case modelInvalid(model: WhisperModel, message: String)
    case modelLoadFailed(model: WhisperModel, message: String)
    case engineNotPrepared(model: WhisperModel)

    public var errorDescription: String? {
        switch self {
        case let .modelNotDownloaded(model, directory):
            "Whisper model \(model.rawValue) is not downloaded at \(directory.path)."
        case let .modelInvalid(model, message):
            "Whisper model \(model.rawValue) is invalid: \(message)"
        case let .modelLoadFailed(model, message):
            "Whisper model \(model.rawValue) failed to load: \(message)"
        case let .engineNotPrepared(model):
            "Whisper model \(model.rawValue) must be prepared before transcription."
        }
    }
}

struct WhisperBackendWord: Equatable, Sendable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let probability: Float
}

struct WhisperBackendSegment: Equatable, Sendable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Float?
    let words: [WhisperBackendWord]
}

protocol WhisperTranscriptionBackend: Sendable {
    func prepare(modelDirectory: URL, englishOnly: Bool) async throws
    func transcribe(samples: [Float]) async throws
        -> [WhisperBackendSegment]
    func unload() async
}

public actor WhisperKitTranscriptionEngine: TranscriptionEngine {
    public nonisolated let identifier: String
    public nonisolated let supportsStreaming = false
    public nonisolated let requiresNetwork = false
    public nonisolated let supportedLanguages: [String]
    public nonisolated let preferredWindowDuration: TimeInterval
    public nonisolated let preferredOverlap: TimeInterval

    private let model: WhisperModel
    private let modelManager: WhisperKitModelManager
    private let backend: any WhisperTranscriptionBackend
    private var prepared = false

    public init(
        model: WhisperModel,
        modelManager: WhisperKitModelManager,
        verboseLogging: Bool = false
    ) throws {
        let descriptor = try Self.descriptor(for: model)
        self.model = model
        self.modelManager = modelManager
        self.backend = ProductionWhisperTranscriptionBackend(
            verbose: verboseLogging
        )
        self.identifier = descriptor.id.rawValue
        self.supportedLanguages = descriptor.supportedLanguages
        self.preferredWindowDuration = descriptor.windowGeometry?.duration ?? 30
        self.preferredOverlap = descriptor.windowGeometry?.overlap ?? 1.5
    }

    init(
        model: WhisperModel,
        modelManager: WhisperKitModelManager,
        backend: any WhisperTranscriptionBackend
    ) throws {
        let descriptor = try Self.descriptor(for: model)
        self.model = model
        self.modelManager = modelManager
        self.backend = backend
        self.identifier = descriptor.id.rawValue
        self.supportedLanguages = descriptor.supportedLanguages
        self.preferredWindowDuration = descriptor.windowGeometry?.duration ?? 30
        self.preferredOverlap = descriptor.windowGeometry?.overlap ?? 1.5
    }

    public func prepare() async throws {
        let availability: ManagedModelAvailability
        do {
            availability = try await modelManager.availability(of: model)
        } catch {
            throw WhisperKitEngineError.modelInvalid(
                model: model,
                message: error.localizedDescription
            )
        }
        let directory: URL
        switch availability {
        case let .installed(installedDirectory, _):
            directory = installedDirectory
        case let .notInstalled(missingDirectory):
            throw WhisperKitEngineError.modelNotDownloaded(
                model: model,
                directory: missingDirectory
            )
        case let .invalid(_, message):
            throw WhisperKitEngineError.modelInvalid(
                model: model,
                message: message
            )
        }
        do {
            try await backend.prepare(
                modelDirectory: directory,
                englishOnly: model.isEnglishOnly
            )
            prepared = true
        } catch {
            prepared = false
            throw WhisperKitEngineError.modelLoadFailed(
                model: model,
                message: error.localizedDescription
            )
        }
    }

    public func transcribe(
        _ chunk: AudioChunk
    ) async throws -> [TranscriptSegment] {
        guard prepared else {
            throw WhisperKitEngineError.engineNotPrepared(model: model)
        }
        let backendSegments = try await backend.transcribe(
            samples: chunk.samples
        )
        return backendSegments.compactMap { segment in
            let text = segment.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty else { return nil }
            let localStart = Self.clamp(
                segment.startTime,
                maximum: chunk.duration
            )
            let localEnd = max(
                localStart,
                Self.clamp(segment.endTime, maximum: chunk.duration)
            )
            let words = segment.words.compactMap { word -> WordTiming? in
                let wordText = word.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !wordText.isEmpty else { return nil }
                let wordStart = Self.clamp(
                    word.startTime,
                    maximum: chunk.duration
                )
                let wordEnd = max(
                    wordStart,
                    Self.clamp(word.endTime, maximum: chunk.duration)
                )
                return WordTiming(
                    text: wordText,
                    startTime: chunk.startTime + wordStart,
                    endTime: chunk.startTime + wordEnd,
                    confidence: word.probability
                )
            }.orderedByAbsoluteTime
            let absoluteStart = words.first?.startTime
                ?? chunk.startTime + localStart
            let absoluteEnd = words.last?.endTime
                ?? chunk.startTime + localEnd
            return TranscriptSegment(
                text: text,
                startTime: absoluteStart,
                endTime: absoluteEnd,
                source: chunk.source,
                confidence: segment.confidence,
                words: words.isEmpty ? nil : words
            )
        }
    }

    public func finish() async -> [TranscriptSegment] { [] }

    public func unload() async {
        await backend.unload()
        prepared = false
    }

    private nonisolated static func descriptor(
        for model: WhisperModel
    ) throws -> ModelDescriptor {
        let catalogue = try ScribeModelCatalogue.builtIn()
        guard let descriptor = catalogue[model.modelIdentifier] else {
            throw ManagedModelRegistryError.unknownModel(
                model.modelIdentifier
            )
        }
        return descriptor
    }

    private nonisolated static func clamp(
        _ time: TimeInterval,
        maximum: TimeInterval
    ) -> TimeInterval {
        guard time.isFinite else { return 0 }
        return min(max(time, 0), maximum)
    }
}

private actor ProductionWhisperTranscriptionBackend:
    WhisperTranscriptionBackend
{
    private let verbose: Bool
    private var whisperKit: WhisperKit?
    private var englishOnly = false

    init(verbose: Bool) {
        self.verbose = verbose
    }

    func prepare(modelDirectory: URL, englishOnly: Bool) async throws {
        await unload()
        self.englishOnly = englishOnly
        let config = WhisperKitConfig(
            modelFolder: modelDirectory.path,
            tokenizerFolder: modelDirectory,
            verbose: verbose,
            logLevel: verbose ? .debug : .none,
            prewarm: true,
            load: false,
            download: false
        )
        let kit = try await WhisperKit(config)
        _ = try await AutoTokenizerWrapper.from(
            modelFolder: modelDirectory
        )
        try await kit.loadModels()
        whisperKit = kit
    }

    func transcribe(
        samples: [Float]
    ) async throws -> [WhisperBackendSegment] {
        guard let whisperKit else {
            throw WhisperError.modelsUnavailable("Local model is not loaded.")
        }
        let options = DecodingOptions(
            language: englishOnly ? "en" : nil,
            usePrefillPrompt: englishOnly,
            detectLanguage: !englishOnly,
            skipSpecialTokens: true,
            wordTimestamps: true
        )
        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options
        )
        return results.flatMap { result in
            result.segments.map { segment in
                let words = (segment.words ?? []).map {
                    WhisperBackendWord(
                        text: $0.word,
                        startTime: TimeInterval($0.start),
                        endTime: TimeInterval($0.end),
                        probability: $0.probability
                    )
                }
                let confidence: Float? = if words.isEmpty {
                    segment.avgLogprob.isFinite
                        ? min(max(exp(segment.avgLogprob), 0), 1)
                        : nil
                } else {
                    words.reduce(0) { $0 + $1.probability }
                        / Float(words.count)
                }
                return WhisperBackendSegment(
                    text: segment.text,
                    startTime: TimeInterval(segment.start),
                    endTime: TimeInterval(segment.end),
                    confidence: confidence,
                    words: words
                )
            }
        }
    }

    func unload() async {
        if let whisperKit {
            await whisperKit.unloadModels()
        }
        whisperKit = nil
    }

}
