import Foundation
import Intelligence

@main
struct ProviderEndpointProbe {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 2 else {
                throw ProbeError.usage
            }
            let providerName = arguments[0].lowercased()
            let modelID = arguments[1]
            let environment = ProcessInfo.processInfo.environment
            let preset: IntelligenceProviderPreset
            let keyVariable: String
            switch providerName {
            case "openai":
                preset = IntelligenceProviderPresets.openAI
                keyVariable = "OPENAI_API_KEY"
            case "deepseek":
                preset = IntelligenceProviderPresets.deepSeek
                keyVariable = "DEEPSEEK_API_KEY"
            default:
                throw ProbeError.unsupportedProvider
            }
            guard let key = environment[keyVariable], !key.isEmpty else {
                throw ProbeError.missingEnvironmentVariable(keyVariable)
            }

            let provider = preset.provider(
                credential: .volatile(key)
            )
            let models = try await provider.availableModels()
            guard models.contains(where: { $0.identifier == modelID }) else {
                let sample = models.prefix(12).map(\.identifier).joined(
                    separator: ", "
                )
                throw ProbeError.modelUnavailable(
                    requested: modelID,
                    availableSample: sample
                )
            }

            let stream = provider.complete(
                system: "Follow the user's output instruction exactly.",
                messages: [
                    LLMMessage(
                        role: .user,
                        content: "Reply with exactly: provider probe ok"
                    )
                ],
                model: LLMModel(identifier: modelID)
            )
            var output = ""
            var chunkCount = 0
            for try await chunk in stream {
                chunkCount += 1
                output += chunk
            }
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            else {
                throw ProbeError.emptyCompletion
            }
            print("Provider: \(preset.displayName)")
            print("Base URL: \(preset.baseURL.absoluteString)")
            print("Model listing: ok (\(models.count) models)")
            print("Streaming chunks: \(chunkCount)")
            print("Completion: \(output)")
            print("RESULT: PASS")
        } catch {
            let message: String
            if case let ProbeError.missingEnvironmentVariable(name) = error {
                message = "RESULT: FAIL — No key provided (\(name))."
            } else {
                message = "RESULT: FAIL — \(error.localizedDescription)"
            }
            print(message)
            fflush(stdout)
            Foundation.exit(EXIT_FAILURE)
        }
    }
}

private enum ProbeError: Error, LocalizedError {
    case usage
    case unsupportedProvider
    case missingEnvironmentVariable(String)
    case modelUnavailable(requested: String, availableSample: String)
    case emptyCompletion

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: swift run ProviderEndpointProbe <openai|deepseek> <model-id>"
        case .unsupportedProvider:
            "Only openai and deepseek are supported by this real-endpoint probe."
        case let .missingEnvironmentVariable(name):
            "No key provided (\(name))."
        case let .modelUnavailable(requested, availableSample):
            "Model \(requested) was not returned by the endpoint. Available sample: \(availableSample)"
        case .emptyCompletion:
            "The streaming request completed without text."
        }
    }
}
