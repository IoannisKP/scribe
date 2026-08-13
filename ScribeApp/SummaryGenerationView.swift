import SwiftUI

@MainActor
final class SummaryGenerationController: ObservableObject {
    struct ProviderOption: Identifiable, Equatable {
        let id: String
        let displayName: String
        let isLocal: Bool
        let customModel: LLMModel?
    }

    @Published var providerID: String
    @Published var templateID = ""
    @Published var modelID = ""
    @Published private(set) var templates: [SummaryTemplate] = []
    @Published private(set) var models: [LLMModel] = []
    @Published private(set) var input: SummaryGenerationInput?
    @Published private(set) var isPreparing = false
    @Published private(set) var isLoadingModels = false
    @Published private(set) var isGenerating = false
    @Published private(set) var streamedText = ""
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?

    private let settingsStore: IntelligenceProviderSettingsStore
    private let keyStore: KeychainAPIKeyStore
    private var settings: IntelligenceProviderSettings

    init(
        settingsStore: IntelligenceProviderSettingsStore =
            IntelligenceProviderSettingsStore(),
        keyStore: KeychainAPIKeyStore = KeychainAPIKeyStore()
    ) {
        self.settingsStore = settingsStore
        self.keyStore = keyStore
        let loaded = settingsStore.load()
        settings = loaded
        providerID = Self.contains(loaded, id: loaded.selectedProviderID)
            ? loaded.selectedProviderID
            : IntelligenceProviderPresets.openAI.id
    }

    var providerOptions: [ProviderOption] {
        IntelligenceProviderPresets.all.map { preset in
            ProviderOption(
                id: preset.id,
                displayName: preset.displayName,
                isLocal: Self.isLocal(preset.baseURL),
                customModel: nil
            )
        } + settings.customProviders.map { custom in
            ProviderOption(
                id: custom.id,
                displayName: custom.displayName,
                isLocal: Self.isLocal(custom.baseURL),
                customModel: custom.model
            )
        }
    }

    var selectedProvider: ProviderOption? {
        providerOptions.first { $0.id == providerID }
    }

    var selectedTemplate: SummaryTemplate? {
        templates.first { $0.id == templateID }
    }

    var selectedModel: LLMModel? {
        selectedProvider?.customModel
            ?? models.first { $0.identifier == modelID }
    }

    var canPrepareGeneration: Bool {
        input != nil && selectedTemplate != nil && selectedModel != nil
            && !isPreparing && !isLoadingModels && !isGenerating
    }

    func prepare(sessionDirectory: URL) async {
        isPreparing = true
        errorMessage = nil
        do {
            async let loadedInput = Task.detached {
                try SummaryGenerationInputBuilder().load(
                    from: sessionDirectory
                )
            }.value
            let databaseURL = try SummaryTemplateStore.defaultDatabaseURL()
            let store = try SummaryTemplateStore(databaseURL: databaseURL)
            async let loadedTemplates = store.templates()
            input = try await loadedInput
            templates = try await loadedTemplates
            if !templates.contains(where: { $0.id == templateID }) {
                templateID = templates.first?.id ?? ""
            }
            selectProvider(providerID)
        } catch {
            errorMessage = error.localizedDescription
        }
        isPreparing = false
    }

    func selectProvider(_ id: String) {
        providerID = id
        settings.selectedProviderID = id
        try? settingsStore.save(settings)
        models = []
        modelID = selectedProvider?.customModel?.identifier ?? ""
        errorMessage = nil
    }

    func loadModels() {
        guard !isLoadingModels else { return }
        do {
            let provider = try makeProvider()
            isLoadingModels = true
            errorMessage = nil
            Task {
                do {
                    let loaded = try await provider.availableModels()
                    models = loaded
                    if !loaded.contains(where: { $0.identifier == modelID }) {
                        modelID = preferredModel(in: loaded)?.identifier
                            ?? loaded.first?.identifier
                            ?? ""
                    }
                    isLoadingModels = false
                } catch {
                    errorMessage = error.localizedDescription
                    isLoadingModels = false
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func plan() throws -> SummaryGenerationPlan {
        guard
            let provider = selectedProvider,
            let model = selectedModel,
            let template = selectedTemplate,
            let input
        else { throw SummaryGenerationError.missingTranscript }
        return try SummaryGenerationPlan(
            providerIdentifier: provider.id,
            providerDisplayName: provider.displayName,
            model: model,
            template: template,
            input: input,
            isLocal: provider.isLocal
        )
    }

    func generate(
        plan: SummaryGenerationPlan,
        sessionDirectory: URL,
        onCompleted: @escaping @MainActor () async -> Void
    ) {
        guard !isGenerating else { return }
        do {
            let provider = try makeProvider()
            isGenerating = true
            streamedText = ""
            errorMessage = nil
            statusMessage = plan.isLocal
                ? ScribeCopy.SummaryGeneration.generatingLocally(
                    provider: plan.providerDisplayName
                )
                : ScribeCopy.SummaryGeneration.sending(
                    provider: plan.providerDisplayName
                )
            Task {
                do {
                    _ = try await SinglePassSummaryGenerator().generate(
                        plan: plan,
                        provider: provider,
                        sessionDirectory: sessionDirectory,
                        onChunk: { [weak self] chunk in
                            await MainActor.run {
                                self?.streamedText += chunk
                            }
                        }
                    )
                    isGenerating = false
                    statusMessage = nil
                    await onCompleted()
                } catch {
                    isGenerating = false
                    statusMessage = nil
                    errorMessage = error is SummaryGenerationError
                        ? error.localizedDescription
                        : ScribeCopy.SummaryGeneration.failed(
                            provider: plan.providerDisplayName
                        )
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func recordFailure(_ error: any Error) {
        errorMessage = error.localizedDescription
    }

    private func makeProvider() throws -> any IntelligenceProvider {
        let credential = keyStore.credential(for: providerID)
        if let preset = IntelligenceProviderPresets.all.first(where: {
            $0.id == providerID
        }) {
            return preset.provider(credential: credential)
        }
        if let custom = settings.customProviders.first(where: {
            $0.id == providerID
        }) {
            return custom.provider(credential: credential)
        }
        throw CustomProviderValidationError.missingRequiredField
    }

    private static func contains(
        _ settings: IntelligenceProviderSettings,
        id: String
    ) -> Bool {
        IntelligenceProviderPresets.all.contains { $0.id == id }
            || settings.customProviders.contains { $0.id == id }
    }

    private static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func preferredModel(in models: [LLMModel]) -> LLMModel? {
        let preferredID: String? = switch providerID {
        case IntelligenceProviderPresets.openAI.id: "gpt-4.1-nano"
        case IntelligenceProviderPresets.deepSeek.id: "deepseek-v4-flash"
        default: nil
        }
        return preferredID.flatMap { preferredID in
            models.first { $0.identifier == preferredID }
                ?? models.first { $0.identifier.hasPrefix(preferredID) }
        }
    }
}

struct SummaryGenerationConfigurationView: View {
    struct Confirmation: Identifiable {
        let id = UUID()
        let plan: SummaryGenerationPlan
        let cost: String?
    }

    @ObservedObject var model: SummaryGenerationController
    let session: SessionLibraryItem
    let onDismiss: () -> Void
    let onCompleted: @MainActor () async -> Void

    @State private var confirmation: Confirmation?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ScribeCopy.Reading.generateSummary)
                .font(.title3.weight(.medium))

            if model.isPreparing {
                ProgressView().controlSize(.small)
            } else {
                form
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                Button(ScribeCopy.SummaryGeneration.cancel, action: onDismiss)
                Spacer()
                Button(ScribeCopy.SummaryGeneration.prepare) {
                    prepareGeneration()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canPrepareGeneration)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task { await model.prepare(sessionDirectory: session.directory) }
        .alert(item: $confirmation) { confirmation in
            Alert(
                title: Text(ScribeCopy.SummaryGeneration.confirmTitle(
                    provider: confirmation.plan.providerDisplayName
                )),
                message: Text(ScribeCopy.SummaryGeneration.confirmBody(
                    provider: confirmation.plan.providerDisplayName,
                    tokens: confirmation.plan.estimatedInputTokens,
                    cost: confirmation.cost
                )),
                primaryButton: .default(Text(ScribeCopy.SummaryGeneration.send)) {
                    start(confirmation.plan)
                },
                secondaryButton: .cancel(
                    Text(ScribeCopy.SummaryGeneration.cancel)
                )
            )
        }
    }

    @ViewBuilder
    private var form: some View {
        Picker(
            ScribeCopy.SummaryGeneration.provider,
            selection: $model.providerID
        ) {
            ForEach(model.providerOptions) { option in
                Text(option.displayName).tag(option.id)
            }
        }
        .onChange(of: model.providerID) { _, id in model.selectProvider(id) }

        Picker(
            ScribeCopy.SummaryGeneration.template,
            selection: $model.templateID
        ) {
            ForEach(model.templates) { template in
                Text(template.name).tag(template.id)
            }
        }

        if let fixedModel = model.selectedProvider?.customModel {
            LabeledContent(ScribeCopy.SummaryGeneration.model) {
                Text(fixedModel.displayName).textSelection(.enabled)
            }
        } else if model.models.isEmpty {
            Button(
                model.isLoadingModels
                    ? ScribeCopy.SummaryGeneration.loadingModels
                    : ScribeCopy.SummaryGeneration.loadModels
            ) {
                model.loadModels()
            }
            .disabled(model.isLoadingModels)
        } else {
            Picker(
                ScribeCopy.SummaryGeneration.model,
                selection: $model.modelID
            ) {
                ForEach(model.models) { availableModel in
                    Text(availableModel.displayName)
                        .tag(availableModel.identifier)
                }
            }
        }

        if let plan = try? model.plan() {
            VStack(alignment: .leading, spacing: 5) {
                Label(
                    plan.isLocal
                        ? ScribeCopy.SummaryGeneration.localDisclosure
                        : ScribeCopy.SummaryGeneration.cloudDisclosure,
                    systemImage: plan.isLocal
                        ? "desktopcomputer" : "icloud.and.arrow.up"
                )
                .font(.callout.weight(.medium))
                Text(ScribeCopy.SummaryGeneration.approximatelyTokens(
                    plan.estimatedInputTokens
                ))
                .font(.callout.monospacedDigit())
                if let cost = Self.costString(plan.estimatedMaximumCost) {
                    Text(ScribeCopy.SummaryGeneration.estimatedMaximumCost(cost))
                        .font(.callout.monospacedDigit())
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func prepareGeneration() {
        do {
            let plan = try model.plan()
            if !plan.requiresConfirmation {
                start(plan)
            } else {
                confirmation = Confirmation(
                    plan: plan,
                    cost: Self.costString(plan.estimatedMaximumCost)
                )
            }
        } catch {
            model.recordFailure(error)
        }
    }

    private func start(_ plan: SummaryGenerationPlan) {
        model.generate(
            plan: plan,
            sessionDirectory: session.directory,
            onCompleted: onCompleted
        )
        onDismiss()
    }

    private static func costString(_ value: Decimal?) -> String? {
        guard let value else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 4
        formatter.maximumFractionDigits = 4
        return formatter.string(from: value as NSDecimalNumber)
    }
}
