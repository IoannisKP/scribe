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
                    "parakeet-tdt-0.6b-v3-coreml",
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
                )
            ),
            try ModelDescriptor(
                id: ScribeModelIdentifiers.parakeetV2English,
                displayName: "Parakeet v2 · English",
                detail: "English-only transcription",
                provider: .fluidAudio,
                task: .transcription,
                installationDirectoryName:
                    "parakeet-tdt-0.6b-v2-coreml",
                supportedLanguages: ["en"],
                supportsLiveProcessing: true,
                windowGeometry: ModelWindowGeometry(
                    duration: 14,
                    overlap: 1.5
                )
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
        ])
    }
}
