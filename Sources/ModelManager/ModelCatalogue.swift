import Foundation

public struct ModelCatalogue: Equatable, Sendable {
    public let models: [ModelDescriptor]
    private let modelsByIdentifier: [ModelIdentifier: ModelDescriptor]

    public init(models: [ModelDescriptor]) throws {
        var byIdentifier: [ModelIdentifier: ModelDescriptor] = [:]
        var installationDirectories: Set<String> = []
        for model in models {
            guard byIdentifier.updateValue(model, forKey: model.id) == nil else {
                throw ModelCatalogueError.duplicateIdentifier(model.id)
            }
            guard installationDirectories.insert(
                model.installationDirectoryName
            ).inserted else {
                throw ModelCatalogueError.duplicateInstallationDirectory(
                    model.installationDirectoryName
                )
            }
        }
        self.models = models
        self.modelsByIdentifier = byIdentifier
    }

    public subscript(identifier: ModelIdentifier) -> ModelDescriptor? {
        modelsByIdentifier[identifier]
    }

    public func models(for task: ModelTask) -> [ModelDescriptor] {
        models.filter { $0.task == task }
    }
}

public enum ScribeModelIdentifiers {
    public static let parakeetV3Multilingual = ModelIdentifier(
        rawValue: "fluidaudio.parakeet.v3Multilingual"
    )
    public static let parakeetV2English = ModelIdentifier(
        rawValue: "fluidaudio.parakeet.v2English"
    )
    public static let sileroVAD = ModelIdentifier(
        rawValue: "fluidaudio.silero.vad"
    )
    public static let whisperTiny = ModelIdentifier(
        rawValue: "whisperkit.openai.tiny"
    )
    public static let whisperTinyEnglish = ModelIdentifier(
        rawValue: "whisperkit.openai.tiny.en"
    )
    public static let whisperBase = ModelIdentifier(
        rawValue: "whisperkit.openai.base"
    )
    public static let whisperSmall = ModelIdentifier(
        rawValue: "whisperkit.openai.small"
    )
    public static let whisperMedium = ModelIdentifier(
        rawValue: "whisperkit.openai.medium"
    )
    public static let whisperLargeV3 = ModelIdentifier(
        rawValue: "whisperkit.openai.large-v3"
    )
    public static let whisperLargeV3Turbo = ModelIdentifier(
        rawValue: "whisperkit.openai.large-v3-turbo"
    )
    public static let whisperDistilLargeV3 = ModelIdentifier(
        rawValue: "whisperkit.distil.large-v3"
    )
    public static let whisperLargeV3TurboCompressed = ModelIdentifier(
        rawValue: "whisperkit.openai.large-v3-turbo.626mb"
    )
    public static let whisperLargeV3TurboOptimizedCompressed = ModelIdentifier(
        rawValue: "whisperkit.openai.large-v3-turbo.optimized.632mb"
    )
    public static let whisperLargeV3OptimizedCompressed = ModelIdentifier(
        rawValue: "whisperkit.openai.large-v3.optimized.954mb"
    )
    public static let whisperDistilLargeV3OptimizedCompressed = ModelIdentifier(
        rawValue: "whisperkit.distil.large-v3.optimized.600mb"
    )

    public static let whisper: [ModelIdentifier] = [
        whisperTiny,
        whisperTinyEnglish,
        whisperBase,
        whisperSmall,
        whisperMedium,
        whisperLargeV3,
        whisperLargeV3Turbo,
        whisperDistilLargeV3,
        whisperLargeV3TurboCompressed,
        whisperLargeV3TurboOptimizedCompressed,
        whisperLargeV3OptimizedCompressed,
        whisperDistilLargeV3OptimizedCompressed,
    ]
}

public enum ScribeModelCatalogue {
    public static func builtIn() throws -> ModelCatalogue {
        try ModelCatalogue(models: [
            try ModelDescriptor(
                id: ScribeModelIdentifiers.parakeetV3Multilingual,
                displayName: "Parakeet v3 · Multilingual",
                detail: "25 European languages, including Greek",
                provider: .fluidAudio,
                task: .transcription,
                installationDirectoryName:
                    "parakeet-tdt-0.6b-v3",
                supportedLanguages: [
                    "bg", "hr", "cs", "da", "nl", "en", "et", "fi",
                    "fr", "de", "el", "hu", "it", "lv", "lt", "mt",
                    "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv",
                    "uk",
                ],
                supportsLiveProcessing: true,
                windowGeometry: ModelWindowGeometry(
                    duration: 14,
                    overlap: 1.5
                ),
                parameterCountMillions: 600,
                quantization: .int8,
                speedRating: .fast
            ),
            try ModelDescriptor(
                id: ScribeModelIdentifiers.parakeetV2English,
                displayName: "Parakeet v2 · English",
                detail: "English-only transcription",
                provider: .fluidAudio,
                task: .transcription,
                installationDirectoryName:
                    "parakeet-tdt-0.6b-v2",
                supportedLanguages: ["en"],
                supportsLiveProcessing: true,
                windowGeometry: ModelWindowGeometry(
                    duration: 14,
                    overlap: 1.5
                ),
                parameterCountMillions: 600,
                quantization: .int8,
                speedRating: .fast
            ),
            try ModelDescriptor(
                id: ScribeModelIdentifiers.sileroVAD,
                displayName: "Silero VAD",
                detail: "Local speech boundary detection",
                provider: .fluidAudio,
                task: .voiceActivityDetection,
                installationDirectoryName: "silero-vad",
                supportedLanguages: [],
                supportsLiveProcessing: true,
                windowGeometry: nil
            ),
        ] + whisperDescriptors())
    }

    private static func whisperDescriptors() throws -> [ModelDescriptor] {
        let multilingual = whisperLanguageCodes
        let geometry = ModelWindowGeometry(duration: 30, overlap: 1.5)
        return [
            try whisper(
                id: ScribeModelIdentifiers.whisperTiny,
                name: "Whisper Tiny",
                detail: "Fastest multilingual Whisper model",
                folder: "openai_whisper-tiny",
                languages: multilingual,
                parameters: 39,
                quantization: .uncompressedCoreML,
                speed: .fastest,
                installedBytes: 79_398_546,
                peakMemoryBytes: 229_294_080,
                geometry: geometry
            ),
            try whisper(
                id: ScribeModelIdentifiers.whisperTinyEnglish,
                name: "Whisper Tiny · English",
                detail: "Fastest English-only Whisper model",
                folder: "openai_whisper-tiny.en",
                languages: ["en"],
                parameters: 39,
                quantization: .uncompressedCoreML,
                speed: .fastest,
                installedBytes: 155_399_288,
                peakMemoryBytes: 302_841_856,
                geometry: geometry
            ),
            try whisper(
                id: ScribeModelIdentifiers.whisperBase,
                name: "Whisper Base",
                detail: "Compact multilingual Whisper model",
                folder: "openai_whisper-base",
                languages: multilingual,
                parameters: 74,
                quantization: .uncompressedCoreML,
                speed: .fast,
                installedBytes: 149_482_602,
                peakMemoryBytes: 344_489_984,
                geometry: geometry
            ),
            try whisper(
                id: ScribeModelIdentifiers.whisperSmall,
                name: "Whisper Small",
                detail: "Standard multilingual Whisper Small model",
                folder: "openai_whisper-small",
                languages: multilingual,
                parameters: 244,
                quantization: .uncompressedCoreML,
                speed: .balanced,
                installedBytes: 489_250_614,
                peakMemoryBytes: 895_385_600,
                geometry: geometry
            ),
            try whisper(
                id: ScribeModelIdentifiers.whisperMedium,
                name: "Whisper Medium",
                detail: "Higher-accuracy multilingual Whisper model",
                folder: "openai_whisper-medium",
                languages: multilingual,
                parameters: 769,
                quantization: .uncompressedCoreML,
                speed: .quality,
                installedBytes: 1_532_417_382,
                peakMemoryBytes: 2_553_430_016,
                geometry: geometry
            ),
            try whisper(
                id: ScribeModelIdentifiers.whisperLargeV3,
                name: "Whisper Large v3",
                detail: "Full-quality multilingual Whisper model",
                folder: "openai_whisper-large-v3",
                languages: multilingual,
                parameters: 1_550,
                quantization: .uncompressedCoreML,
                speed: .quality,
                installedBytes: 3_093_083_359,
                peakMemoryBytes: 4_440_883_200,
                geometry: geometry
            ),
            try whisper(
                id: ScribeModelIdentifiers.whisperLargeV3Turbo,
                name: "Whisper Large v3 Turbo",
                detail: "OpenAI's 2024 multilingual turbo architecture",
                folder: "openai_whisper-large-v3-v20240930",
                languages: multilingual,
                parameters: 798,
                quantization: .uncompressedCoreML,
                speed: .fast,
                installedBytes: 1_622_294_723,
                peakMemoryBytes: 3_020_783_616,
                geometry: geometry
            ),
            try whisper(
                id: ScribeModelIdentifiers.whisperDistilLargeV3,
                name: "Distil-Whisper Large v3 · English",
                detail: "Distilled English-only large-v3 model",
                folder: "distil-whisper_distil-large-v3",
                languages: ["en"],
                parameters: 756,
                quantization: .uncompressedCoreML,
                speed: .fast,
                installedBytes: 1_517_298_160,
                peakMemoryBytes: 2_907_111_424,
                geometry: geometry
            ),
            try whisper(
                id: ScribeModelIdentifiers.whisperLargeV3TurboCompressed,
                name: "Whisper Large v3 Turbo · 4-bit",
                detail: "Compressed 2024 turbo architecture",
                folder: "openai_whisper-large-v3-v20240930_626MB",
                languages: multilingual,
                parameters: 798,
                quantization: .fourBitCompressed,
                speed: .fast,
                installedBytes: 629_481_698,
                peakMemoryBytes: 1_173_094_400,
                geometry: geometry
            ),
            try whisper(
                id: ScribeModelIdentifiers.whisperLargeV3TurboOptimizedCompressed,
                name: "Whisper Large v3 Turbo · Optimized 4-bit",
                detail: "Compressed 2024 turbo with Argmax streaming optimization",
                folder: "openai_whisper-large-v3-v20240930_turbo_632MB",
                languages: multilingual,
                parameters: 798,
                quantization: .fourBitCompressed,
                speed: .fastest,
                installedBytes: 648_432_373,
                peakMemoryBytes: 1_477_410_816,
                geometry: geometry
            ),
            try whisper(
                id: ScribeModelIdentifiers.whisperLargeV3OptimizedCompressed,
                name: "Whisper Large v3 · Optimized compressed",
                detail: "QLoRA-compressed large-v3 with Argmax streaming optimization",
                folder: "openai_whisper-large-v3_turbo_954MB",
                languages: multilingual,
                parameters: 1_550,
                quantization: .qloraCompressed,
                speed: .balanced,
                installedBytes: 1_055_612_340,
                peakMemoryBytes: 1_828_929_536,
                geometry: geometry
            ),
            try whisper(
                id: ScribeModelIdentifiers.whisperDistilLargeV3OptimizedCompressed,
                name: "Distil-Whisper Large v3 · Optimized compressed",
                detail: "QLoRA-compressed English model with Argmax streaming optimization",
                folder: "distil-whisper_distil-large-v3_turbo_600MB",
                languages: ["en"],
                parameters: 756,
                quantization: .qloraCompressed,
                speed: .fastest,
                installedBytes: 609_877_791,
                peakMemoryBytes: 1_376_993_280,
                geometry: geometry
            ),
        ]
    }

    private static func whisper(
        id: ModelIdentifier,
        name: String,
        detail: String,
        folder: String,
        languages: [String],
        parameters: Int,
        quantization: ModelQuantization,
        speed: ModelSpeedRating,
        installedBytes: Int64,
        peakMemoryBytes: Int64,
        geometry: ModelWindowGeometry
    ) throws -> ModelDescriptor {
        try ModelDescriptor(
            id: id,
            displayName: name,
            detail: detail,
            provider: .whisperKit,
            task: .transcription,
            installationDirectoryName: folder,
            supportedLanguages: languages,
            supportsLiveProcessing: true,
            windowGeometry: geometry,
            parameterCountMillions: parameters,
            quantization: quantization,
            speedRating: speed,
            resourceProfile: try ModelResourceProfile(
                downloadBytes: installedBytes,
                installedBytes: installedBytes,
                peakMemoryBytes: peakMemoryBytes,
                evidence: .measured(
                    description: "Scribe golden fixture on an M4 Pro Mac, macOS 26.5.2, 2026-08-03, WhisperKit 1.0.0. Download bytes came from the SHA-256 manifest, installed bytes from recursive regular-file accounting after verification, and peak RSS from getrusage in a fresh first-load test process."
                )
            )
        )
    }

    private static let whisperLanguageCodes = [
        "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo",
        "br", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es",
        "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw",
        "he", "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja",
        "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo",
        "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt",
        "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt",
        "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq",
        "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl",
        "tr", "tt", "uk", "ur", "uz", "vi", "yo", "yue", "zh",
    ]
}
