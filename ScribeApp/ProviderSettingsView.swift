import SwiftUI

struct ProviderSettingsView: View {
    @StateObject private var model = ProviderSettingsViewModel()

    var body: some View {
        GroupBox(ScribeCopy.IntelligenceSettings.title) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Picker(
                        ScribeCopy.IntelligenceSettings.provider,
                        selection: $model.selectedProviderID
                    ) {
                        ForEach(model.options) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: model.selectedProviderID) { _, value in
                        model.select(value)
                    }

                    Spacer()

                    Button(ScribeCopy.IntelligenceSettings.addCustomProvider) {
                        model.beginCustomProvider()
                    }
                }

                if model.isEditingCustomProvider {
                    customProviderForm
                } else {
                    credentialForm
                }

                if let status = model.status {
                    Label(status.message, systemImage: status.systemImage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var credentialForm: some View {
        if model.selectedProviderRequiresKey {
            VStack(alignment: .leading, spacing: 8) {
                Text(ScribeCopy.IntelligenceSettings.apiKey)
                    .font(.callout.weight(.medium))
                SecureField(
                    ScribeCopy.IntelligenceSettings.apiKeyPlaceholder,
                    text: $model.apiKey
                )
                .textContentType(.password)

                Text(ScribeCopy.IntelligenceSettings.keychainHelper)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.hasStoredKey {
                    Text(ScribeCopy.IntelligenceSettings.keyStored)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(ScribeCopy.IntelligenceSettings.testKey) {
                        model.testSelectedProvider()
                    }
                    .disabled(model.isTesting)

                    if model.hasStoredKey {
                        Button(
                            ScribeCopy.IntelligenceSettings.removeKey,
                            role: .destructive
                        ) {
                            model.removeSelectedKey()
                        }
                        .disabled(model.isTesting)
                    }

                    if model.isSelectedCustomProvider {
                        Spacer()
                        Button(ScribeCopy.IntelligenceSettings.customProvider) {
                            model.editSelectedCustomProvider()
                        }
                    }
                }
            }
        } else {
            HStack {
                Text(
                    model.selectedProviderIsLocal
                        ? ScribeCopy.IntelligenceSettings.noKeyRequired
                        : ScribeCopy.IntelligenceSettings.customNoKeyRequired
                )
                    .foregroundStyle(.secondary)
                Spacer()
                Button(ScribeCopy.IntelligenceSettings.testConnection) {
                    model.testSelectedProvider()
                }
                .disabled(model.isTesting)
                if model.isSelectedCustomProvider {
                    Button(ScribeCopy.IntelligenceSettings.customProvider) {
                        model.editSelectedCustomProvider()
                    }
                }
            }
        }
    }

    private var customProviderForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(
                ScribeCopy.IntelligenceSettings.displayName,
                text: $model.customDisplayName
            )
            TextField(
                ScribeCopy.IntelligenceSettings.baseURL,
                text: $model.customBaseURL
            )
            TextField(
                ScribeCopy.IntelligenceSettings.modelIdentifier,
                text: $model.customModelIdentifier
            )
            Toggle(
                ScribeCopy.IntelligenceSettings.usesAPIKey,
                isOn: $model.customUsesAPIKey
            )
            if model.customUsesAPIKey {
                Text(ScribeCopy.IntelligenceSettings.apiKey)
                    .font(.callout.weight(.medium))
                SecureField(
                    ScribeCopy.IntelligenceSettings.apiKeyPlaceholder,
                    text: $model.apiKey
                )
                .textContentType(.password)
                Text(ScribeCopy.IntelligenceSettings.keychainHelper)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(ScribeCopy.IntelligenceSettings.saveProvider) {
                    model.saveCustomProvider()
                }
                Button(ScribeCopy.IntelligenceSettings.cancel) {
                    model.cancelCustomProvider()
                }
                if model.editingCustomProviderID != nil {
                    Spacer()
                    Button(
                        ScribeCopy.IntelligenceSettings.removeProvider,
                        role: .destructive
                    ) {
                        model.removeEditingCustomProvider()
                    }
                }
            }
        }
        .textFieldStyle(.roundedBorder)
    }
}

@MainActor
private final class ProviderSettingsViewModel: ObservableObject {
    struct Option: Identifiable {
        let id: String
        let displayName: String
    }

    struct Status {
        let message: String
        let systemImage: String
    }

    @Published var selectedProviderID: String
    @Published var apiKey = ""
    @Published var hasStoredKey = false
    @Published var isTesting = false
    @Published var status: Status?
    @Published var isEditingCustomProvider = false
    @Published var editingCustomProviderID: String?
    @Published var customDisplayName = ""
    @Published var customBaseURL = ""
    @Published var customModelIdentifier = ""
    @Published var customUsesAPIKey = true

    private var settings: IntelligenceProviderSettings
    private let settingsStore: IntelligenceProviderSettingsStore
    private let keyStore: KeychainAPIKeyStore
    private let tester = ProviderConnectionTester()

    init(
        settingsStore: IntelligenceProviderSettingsStore =
            IntelligenceProviderSettingsStore(),
        keyStore: KeychainAPIKeyStore = KeychainAPIKeyStore()
    ) {
        self.settingsStore = settingsStore
        self.keyStore = keyStore
        let loaded = settingsStore.load()
        settings = loaded
        selectedProviderID = loaded.selectedProviderID
        if !Self.contains(loaded, id: loaded.selectedProviderID) {
            selectedProviderID = IntelligenceProviderPresets.openAI.id
            settings.selectedProviderID = selectedProviderID
        }
        refreshStoredKeyState()
    }

    var options: [Option] {
        IntelligenceProviderPresets.all.map {
            Option(id: $0.id, displayName: Self.presetDisplayName(for: $0.id))
        } + settings.customProviders.map {
            Option(id: $0.id, displayName: $0.displayName)
        }
    }

    var selectedProviderRequiresKey: Bool {
        if let preset = preset { return preset.requiresKey }
        return customProvider?.usesAPIKey ?? false
    }

    var isSelectedCustomProvider: Bool { customProvider != nil }

    var selectedProviderIsLocal: Bool {
        guard let host = preset?.baseURL.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    func select(_ id: String) {
        settings.selectedProviderID = id
        try? settingsStore.save(settings)
        apiKey = ""
        status = nil
        isEditingCustomProvider = false
        refreshStoredKeyState()
    }

    func testSelectedProvider() {
        guard !isTesting else { return }
        do {
            if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try keyStore.set(apiKey, for: selectedProviderID)
                apiKey = ""
                hasStoredKey = true
            }
            let provider = try makeSelectedProvider()
            isTesting = true
            status = Status(
                message: ScribeCopy.IntelligenceSettings.testing,
                systemImage: "ellipsis.circle"
            )
            Task {
                do {
                    _ = try await tester.test(provider)
                    isTesting = false
                    status = Status(
                        message: selectedProviderRequiresKey
                            ? ScribeCopy.IntelligenceSettings.keyWorks
                            : ScribeCopy.IntelligenceSettings.connectionWorks,
                        systemImage: "checkmark.circle"
                    )
                } catch {
                    isTesting = false
                    status = Status(
                        message: selectedProviderRequiresKey
                            ? ScribeCopy.IntelligenceSettings.keyRejected
                            : ScribeCopy.IntelligenceSettings.connectionFailed,
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }
        } catch {
            status = Status(
                message: ScribeCopy.IntelligenceSettings.keyRejected,
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    func removeSelectedKey() {
        try? keyStore.removeKey(for: selectedProviderID)
        apiKey = ""
        hasStoredKey = false
        status = nil
    }

    func beginCustomProvider() {
        editingCustomProviderID = nil
        customDisplayName = ""
        customBaseURL = "https://"
        customModelIdentifier = ""
        customUsesAPIKey = true
        apiKey = ""
        status = nil
        isEditingCustomProvider = true
    }

    func editSelectedCustomProvider() {
        guard let customProvider else { return }
        editingCustomProviderID = customProvider.id
        customDisplayName = customProvider.displayName
        customBaseURL = customProvider.baseURL.absoluteString
        customModelIdentifier = customProvider.modelIdentifier
        customUsesAPIKey = customProvider.usesAPIKey
        apiKey = ""
        status = nil
        isEditingCustomProvider = true
    }

    func cancelCustomProvider() {
        isEditingCustomProvider = false
        apiKey = ""
        status = nil
    }

    func saveCustomProvider() {
        do {
            guard let url = URL(string: customBaseURL) else {
                throw CustomProviderValidationError.invalidBaseURL
            }
            let provider = try CustomIntelligenceProvider(
                id: editingCustomProviderID ?? UUID().uuidString,
                displayName: customDisplayName,
                baseURL: url,
                modelIdentifier: customModelIdentifier,
                usesAPIKey: customUsesAPIKey
            )
            if let index = settings.customProviders.firstIndex(where: {
                $0.id == provider.id
            }) {
                settings.customProviders[index] = provider
            } else {
                settings.customProviders.append(provider)
            }
            if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try keyStore.set(apiKey, for: provider.id)
            }
            settings.selectedProviderID = provider.id
            try settingsStore.save(settings)
            selectedProviderID = provider.id
            isEditingCustomProvider = false
            apiKey = ""
            refreshStoredKeyState()
            status = Status(
                message: ScribeCopy.IntelligenceSettings.customProviderSaved,
                systemImage: "checkmark.circle"
            )
        } catch {
            status = Status(
                message: validationMessage(for: error),
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    func removeEditingCustomProvider() {
        guard let id = editingCustomProviderID else { return }
        settings.customProviders.removeAll { $0.id == id }
        try? keyStore.removeKey(for: id)
        selectedProviderID = IntelligenceProviderPresets.openAI.id
        settings.selectedProviderID = selectedProviderID
        try? settingsStore.save(settings)
        isEditingCustomProvider = false
        apiKey = ""
        refreshStoredKeyState()
        status = nil
    }

    private var preset: IntelligenceProviderPreset? {
        IntelligenceProviderPresets.all.first { $0.id == selectedProviderID }
    }

    private var customProvider: CustomIntelligenceProvider? {
        settings.customProviders.first { $0.id == selectedProviderID }
    }

    private func makeSelectedProvider() throws -> any IntelligenceProvider {
        let credential = keyStore.credential(for: selectedProviderID)
        if let preset { return preset.provider(credential: credential) }
        if let customProvider {
            return customProvider.provider(credential: credential)
        }
        throw CustomProviderValidationError.missingRequiredField
    }

    private func refreshStoredKeyState() {
        hasStoredKey = (try? keyStore.key(for: selectedProviderID)) != nil
    }

    private func validationMessage(for error: any Error) -> String {
        switch error as? CustomProviderValidationError {
        case .missingRequiredField:
            ScribeCopy.IntelligenceSettings.missingCustomFields
        case .invalidBaseURL:
            ScribeCopy.IntelligenceSettings.invalidProviderURL
        case .insecureRemoteBaseURL:
            ScribeCopy.IntelligenceSettings.insecureProviderURL
        case nil:
            ScribeCopy.IntelligenceSettings.configurationFailed
        }
    }

    private static func contains(
        _ settings: IntelligenceProviderSettings,
        id: String
    ) -> Bool {
        IntelligenceProviderPresets.all.contains { $0.id == id }
            || settings.customProviders.contains { $0.id == id }
    }

    private static func presetDisplayName(for id: String) -> String {
        switch id {
        case IntelligenceProviderPresets.anthropic.id:
            ScribeCopy.IntelligenceSettings.anthropic
        case IntelligenceProviderPresets.openAI.id:
            ScribeCopy.IntelligenceSettings.openAI
        case IntelligenceProviderPresets.deepSeek.id:
            ScribeCopy.IntelligenceSettings.deepSeek
        case IntelligenceProviderPresets.groq.id:
            ScribeCopy.IntelligenceSettings.groq
        case IntelligenceProviderPresets.ollama.id:
            ScribeCopy.IntelligenceSettings.ollama
        case IntelligenceProviderPresets.lmStudio.id:
            ScribeCopy.IntelligenceSettings.lmStudio
        default:
            id
        }
    }
}
