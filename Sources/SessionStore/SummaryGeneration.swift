import AudioCapture
import Foundation
#if canImport(Intelligence)
import Intelligence
#endif
import SpeechPipeline

public struct SummaryGenerationInput: Equatable, Sendable {
    public let context: SummaryTemplateContext

    public init(context: SummaryTemplateContext) {
        self.context = context
    }
}

public struct SummaryGenerationInputBuilder: Sendable {
    public init() {}

    public func load(from sessionDirectory: URL) throws
        -> SummaryGenerationInput
    {
        let manifest = try CaptureSessionManifest.load(from: sessionDirectory)
        let transcriptURL = sessionDirectory.appendingPathComponent(
            "transcript.md"
        )
        guard
            let transcript = try? String(
                contentsOf: transcriptURL,
                encoding: .utf8
            ),
            !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw SummaryGenerationError.missingTranscript
        }
        let notesURL = sessionDirectory.appendingPathComponent("notes.md")
        let notes = (try? String(contentsOf: notesURL, encoding: .utf8)) ?? ""
        let segments = try SessionReadingPresentation().loadSegments(
            from: sessionDirectory.appendingPathComponent("transcript.json")
        )
        return SummaryGenerationInput(context: SummaryTemplateContext(
            notes: notes,
            transcript: transcript,
            title: manifest.title,
            date: Self.dateString(manifest.createdAt),
            participants: Self.participants(in: manifest),
            pins: Self.pinContext(manifest.pins, segments: segments)
        ))
    }

    private static func participants(
        in manifest: CaptureSessionManifest
    ) -> String {
        manifest.speakerIdentities.map { speaker in
            if let displayName = speaker.displayName { return displayName }
            return switch speaker.source {
            case .microphone: ScribeCopy.SummaryGeneration.you
            case .system: ScribeCopy.SummaryGeneration.others
            case .imported: ScribeCopy.SummaryGeneration.importedAudio
            }
        }.joined(separator: ", ")
    }

    private static func pinContext(
        _ pins: [CaptureSessionManifest.Pin],
        segments: [TranscriptSegment]
    ) -> String {
        guard !pins.isEmpty else { return ScribeCopy.SummaryGeneration.noPins }
        return pins.map { pin in
            let time = Double(pin.sampleOffset) / CanonicalAudioFormat.sampleRate
            let nearby = segments.filter {
                $0.endTime >= max(0, time - 15) && $0.startTime <= time + 15
            }.map(\.text).joined(separator: " ")
            let label = pin.label.map { " — \($0)" } ?? ""
            let context = nearby.isEmpty
                ? ScribeCopy.SummaryGeneration.noNearbyTranscript
                : nearby
            return "[\(Self.timecode(time))]\(label) \(context)"
        }.joined(separator: "\n")
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func timecode(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds >= 3_600 {
            return String(
                format: "%d:%02d:%02d",
                seconds / 3_600,
                (seconds / 60) % 60,
                seconds % 60
            )
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

public struct SummaryModelPolicy: Equatable, Sendable {
    public let contextTokenLimit: Int
    public let maximumOutputTokens: Int
    public let inputDollarsPerMillionTokens: Decimal?
    public let outputDollarsPerMillionTokens: Decimal?

    public init(
        contextTokenLimit: Int,
        maximumOutputTokens: Int = 4_096,
        inputDollarsPerMillionTokens: Decimal? = nil,
        outputDollarsPerMillionTokens: Decimal? = nil
    ) {
        self.contextTokenLimit = contextTokenLimit
        self.maximumOutputTokens = maximumOutputTokens
        self.inputDollarsPerMillionTokens = inputDollarsPerMillionTokens
        self.outputDollarsPerMillionTokens = outputDollarsPerMillionTokens
    }

    public static func policy(providerID: String, modelID: String)
        -> SummaryModelPolicy
    {
        let id = modelID.lowercased()
        if providerID == IntelligenceProviderPresets.openAI.id {
            if id.hasPrefix("gpt-4.1-nano") {
                return SummaryModelPolicy(
                    contextTokenLimit: 1_047_576,
                    inputDollarsPerMillionTokens: 0.10,
                    outputDollarsPerMillionTokens: 0.40
                )
            }
            if id.hasPrefix("gpt-4.1-mini") {
                return SummaryModelPolicy(
                    contextTokenLimit: 1_047_576,
                    inputDollarsPerMillionTokens: 0.40,
                    outputDollarsPerMillionTokens: 1.60
                )
            }
            if id == "gpt-4.1" || id.hasPrefix("gpt-4.1-") {
                return SummaryModelPolicy(
                    contextTokenLimit: 1_047_576,
                    inputDollarsPerMillionTokens: 2.00,
                    outputDollarsPerMillionTokens: 8.00
                )
            }
        }
        if providerID == IntelligenceProviderPresets.deepSeek.id {
            switch id {
            case "deepseek-v4-flash":
                return SummaryModelPolicy(
                    contextTokenLimit: 1_000_000,
                    inputDollarsPerMillionTokens: 0.14,
                    outputDollarsPerMillionTokens: 0.28
                )
            case "deepseek-v4-pro":
                return SummaryModelPolicy(
                    contextTokenLimit: 1_000_000,
                    inputDollarsPerMillionTokens: 0.435,
                    outputDollarsPerMillionTokens: 0.87
                )
            case "deepseek-chat":
                return SummaryModelPolicy(
                    contextTokenLimit: 65_536,
                    inputDollarsPerMillionTokens: 0.27,
                    outputDollarsPerMillionTokens: 1.10
                )
            case "deepseek-reasoner":
                return SummaryModelPolicy(
                    contextTokenLimit: 65_536,
                    inputDollarsPerMillionTokens: 0.55,
                    outputDollarsPerMillionTokens: 2.19
                )
            default:
                break
            }
        }
        if providerID == IntelligenceProviderPresets.anthropic.id,
            id.hasPrefix("claude-")
        {
            return SummaryModelPolicy(contextTokenLimit: 200_000)
        }
        return SummaryModelPolicy(contextTokenLimit: 16_384)
    }
}

public enum SummaryTokenEstimator {
    public static func estimate(_ text: String) -> Int {
        max(1, Int(ceil(Double(text.utf8.count) / 4.0)))
    }
}

public struct SummaryGenerationPlan: Equatable, Sendable {
    public let providerIdentifier: String
    public let providerDisplayName: String
    public let model: LLMModel
    public let template: SummaryTemplate
    public let prompt: String
    public let estimatedInputTokens: Int
    public let policy: SummaryModelPolicy
    public let isLocal: Bool

    public var requiresConfirmation: Bool { !isLocal }

    public var estimatedMaximumCost: Decimal? {
        guard
            let inputRate = policy.inputDollarsPerMillionTokens,
            let outputRate = policy.outputDollarsPerMillionTokens
        else { return nil }
        return Decimal(estimatedInputTokens) * inputRate / 1_000_000
            + Decimal(policy.maximumOutputTokens) * outputRate / 1_000_000
    }

    public init(
        providerIdentifier: String,
        providerDisplayName: String,
        model: LLMModel,
        template: SummaryTemplate,
        input: SummaryGenerationInput,
        isLocal: Bool,
        policy: SummaryModelPolicy? = nil
    ) throws {
        let prompt = try SummaryTemplateRenderer.render(
            template,
            context: input.context
        )
        let system = ScribeCopy.SummaryGeneration.systemInstruction
        let estimatedInputTokens = SummaryTokenEstimator.estimate(
            system + "\n" + prompt
        )
        let resolvedPolicy = policy ?? SummaryModelPolicy.policy(
            providerID: providerIdentifier,
            modelID: model.identifier
        )
        guard estimatedInputTokens + resolvedPolicy.maximumOutputTokens
            <= resolvedPolicy.contextTokenLimit
        else {
            throw SummaryGenerationError.requiresChunking(
                estimatedTokens: estimatedInputTokens,
                contextLimit: resolvedPolicy.contextTokenLimit
            )
        }
        self.providerIdentifier = providerIdentifier
        self.providerDisplayName = providerDisplayName
        self.model = model
        self.template = template
        self.prompt = prompt
        self.estimatedInputTokens = estimatedInputTokens
        self.policy = resolvedPolicy
        self.isLocal = isLocal
    }
}

public struct SummaryGenerationResult: Equatable, Sendable {
    public let text: String
    public let artifact: SummaryArtifactWriteResult
}

public struct SinglePassSummaryGenerator: Sendable {
    private let writer: SummaryArtifactWriter

    public init(writer: SummaryArtifactWriter = SummaryArtifactWriter()) {
        self.writer = writer
    }

    public func generate(
        plan: SummaryGenerationPlan,
        provider: any IntelligenceProvider,
        sessionDirectory: URL,
        onChunk: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> SummaryGenerationResult {
        var output = ""
        let stream = provider.complete(
            system: ScribeCopy.SummaryGeneration.systemInstruction,
            messages: [LLMMessage(role: .user, content: plan.prompt)],
            model: plan.model
        )
        for try await chunk in stream {
            output += chunk
            await onChunk(chunk)
        }
        let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SummaryGenerationError.emptyResponse }
        let artifact = try await writer.write(
            summary: clean,
            providerIdentifier: plan.providerIdentifier,
            providerDisplayName: plan.providerDisplayName,
            modelIdentifier: plan.model.identifier,
            templateIdentifier: plan.template.id,
            templateName: plan.template.name,
            to: sessionDirectory
        )
        return SummaryGenerationResult(text: clean, artifact: artifact)
    }
}

public enum SummaryGenerationError: Error, Equatable, LocalizedError, Sendable {
    case missingTranscript
    case requiresChunking(estimatedTokens: Int, contextLimit: Int)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .missingTranscript:
            ScribeCopy.SummaryGeneration.missingTranscript
        case let .requiresChunking(estimatedTokens, contextLimit):
            ScribeCopy.SummaryGeneration.requiresChunking(
                estimatedTokens: estimatedTokens,
                contextLimit: contextLimit
            )
        case .emptyResponse:
            ScribeCopy.SummaryGeneration.emptyResponse
        }
    }
}
