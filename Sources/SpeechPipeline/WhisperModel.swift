import Foundation
import ModelManager

public enum WhisperModel: String, CaseIterable, Sendable {
    case tiny
    case tinyEnglish
    case base
    case small
    case medium
    case largeV3
    case largeV3Turbo
    case distilLargeV3
    case largeV3TurboCompressed
    case largeV3TurboOptimizedCompressed
    case largeV3OptimizedCompressed
    case distilLargeV3OptimizedCompressed

    public var modelIdentifier: ModelIdentifier {
        switch self {
        case .tiny: ScribeModelIdentifiers.whisperTiny
        case .tinyEnglish: ScribeModelIdentifiers.whisperTinyEnglish
        case .base: ScribeModelIdentifiers.whisperBase
        case .small: ScribeModelIdentifiers.whisperSmall
        case .medium: ScribeModelIdentifiers.whisperMedium
        case .largeV3: ScribeModelIdentifiers.whisperLargeV3
        case .largeV3Turbo: ScribeModelIdentifiers.whisperLargeV3Turbo
        case .distilLargeV3: ScribeModelIdentifiers.whisperDistilLargeV3
        case .largeV3TurboCompressed:
            ScribeModelIdentifiers.whisperLargeV3TurboCompressed
        case .largeV3TurboOptimizedCompressed:
            ScribeModelIdentifiers.whisperLargeV3TurboOptimizedCompressed
        case .largeV3OptimizedCompressed:
            ScribeModelIdentifiers.whisperLargeV3OptimizedCompressed
        case .distilLargeV3OptimizedCompressed:
            ScribeModelIdentifiers.whisperDistilLargeV3OptimizedCompressed
        }
    }

    var upstreamFolder: String {
        switch self {
        case .tiny: "openai_whisper-tiny"
        case .tinyEnglish: "openai_whisper-tiny.en"
        case .base: "openai_whisper-base"
        case .small: "openai_whisper-small"
        case .medium: "openai_whisper-medium"
        case .largeV3: "openai_whisper-large-v3"
        case .largeV3Turbo: "openai_whisper-large-v3-v20240930"
        case .distilLargeV3: "distil-whisper_distil-large-v3"
        case .largeV3TurboCompressed:
            "openai_whisper-large-v3-v20240930_626MB"
        case .largeV3TurboOptimizedCompressed:
            "openai_whisper-large-v3-v20240930_turbo_632MB"
        case .largeV3OptimizedCompressed:
            "openai_whisper-large-v3_turbo_954MB"
        case .distilLargeV3OptimizedCompressed:
            "distil-whisper_distil-large-v3_turbo_600MB"
        }
    }

    var tokenizerRepository: String {
        switch self {
        case .tiny:
            "openai/whisper-tiny"
        case .tinyEnglish:
            "openai/whisper-tiny.en"
        case .base:
            "openai/whisper-base"
        case .small:
            "openai/whisper-small"
        case .medium:
            "openai/whisper-medium"
        case .largeV3, .largeV3Turbo, .largeV3TurboCompressed,
            .largeV3TurboOptimizedCompressed, .largeV3OptimizedCompressed,
            .distilLargeV3, .distilLargeV3OptimizedCompressed:
            "openai/whisper-large-v3"
        }
    }

    var isEnglishOnly: Bool {
        switch self {
        case .tinyEnglish, .distilLargeV3,
            .distilLargeV3OptimizedCompressed:
            true
        default:
            false
        }
    }
}
