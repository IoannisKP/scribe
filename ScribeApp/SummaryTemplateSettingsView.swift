import SwiftUI

struct SummaryTemplateSettingsView: View {
    @StateObject private var model = SummaryTemplateSettingsViewModel()
    @State private var confirmsRemoval = false

    var body: some View {
        GroupBox(ScribeCopy.SummaryTemplates.title) {
            VStack(alignment: .leading, spacing: 12) {
                if model.isLoading {
                    ProgressView().controlSize(.small)
                } else if model.templates.isEmpty {
                    Text(ScribeCopy.SummaryTemplates.loadFailed)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    controls
                    editor
                }

                if let status = model.status {
                    Label(status.message, systemImage: status.systemImage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
        .task { await model.load() }
        .confirmationDialog(
            ScribeCopy.SummaryTemplates.removeTitle(model.name),
            isPresented: $confirmsRemoval
        ) {
            Button(ScribeCopy.SummaryTemplates.remove, role: .destructive) {
                Task { await model.removeSelected() }
            }
            Button(ScribeCopy.SummaryTemplates.cancel, role: .cancel) {}
        } message: {
            Text(ScribeCopy.SummaryTemplates.removeBody)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker(
                ScribeCopy.SummaryTemplates.template,
                selection: $model.selectedID
            ) {
                ForEach(model.templates) { template in
                    Text(template.name).tag(template.id)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: model.selectedID) { _, id in model.select(id) }

            Spacer()

            Button(ScribeCopy.SummaryTemplates.newTemplate) {
                Task { await model.createTemplate() }
            }
            Button(ScribeCopy.SummaryTemplates.duplicate) {
                Task { await model.duplicateSelected() }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ScribeCopy.SummaryTemplates.name)
                .font(.callout.weight(.medium))
            TextField(ScribeCopy.SummaryTemplates.name, text: $model.name)
                .textFieldStyle(.roundedBorder)

            Text(ScribeCopy.SummaryTemplates.instructions)
                .font(.callout.weight(.medium))
            TextEditor(text: $model.body)
                .font(.body)
                .frame(minHeight: 170)
                .padding(4)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.separator, lineWidth: 1)
                }

            Text(ScribeCopy.SummaryTemplates.variables)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack {
                Button(ScribeCopy.SummaryTemplates.save) {
                    Task { await model.saveSelected() }
                }
                .buttonStyle(.borderedProminent)

                if !model.selectedIsBuiltIn {
                    Button(
                        ScribeCopy.SummaryTemplates.remove,
                        role: .destructive
                    ) {
                        confirmsRemoval = true
                    }
                }
            }
        }
    }
}

@MainActor
private final class SummaryTemplateSettingsViewModel: ObservableObject {
    struct Status {
        let message: String
        let systemImage: String
    }

    @Published private(set) var templates: [SummaryTemplate] = []
    @Published var selectedID = ""
    @Published var name = ""
    @Published var body = ""
    @Published private(set) var isLoading = true
    @Published private(set) var status: Status?

    private var store: SummaryTemplateStore?
    private var didLoad = false

    var selectedIsBuiltIn: Bool {
        templates.first(where: { $0.id == selectedID })?.isBuiltIn ?? true
    }

    func load() async {
        guard !didLoad else { return }
        didLoad = true
        isLoading = true
        do {
            let store = try SummaryTemplateStore(
                databaseURL: SummaryTemplateStore.defaultDatabaseURL()
            )
            self.store = store
            try await refresh(preferredID: nil)
        } catch {
            status = Status(
                message: ScribeCopy.SummaryTemplates.loadFailed,
                systemImage: "exclamationmark.triangle"
            )
        }
        isLoading = false
    }

    func select(_ id: String) {
        guard let template = templates.first(where: { $0.id == id }) else {
            return
        }
        selectedID = template.id
        name = template.name
        body = template.body
        status = nil
    }

    func createTemplate() async {
        guard let store else { return }
        do {
            let template = try await store.create(
                name: ScribeCopy.SummaryTemplates.untitled,
                body: ScribeCopy.SummaryTemplates.newTemplateBody
            )
            try await refresh(preferredID: template.id)
            status = Status(
                message: ScribeCopy.SummaryTemplates.created,
                systemImage: "checkmark.circle"
            )
        } catch {
            failure(ScribeCopy.SummaryTemplates.saveFailed)
        }
    }

    func duplicateSelected() async {
        guard let store, !selectedID.isEmpty else { return }
        do {
            let template = try await store.duplicate(
                id: selectedID,
                name: ScribeCopy.SummaryTemplates.duplicateName(name)
            )
            try await refresh(preferredID: template.id)
            status = Status(
                message: ScribeCopy.SummaryTemplates.duplicated,
                systemImage: "checkmark.circle"
            )
        } catch {
            failure(ScribeCopy.SummaryTemplates.saveFailed)
        }
    }

    func saveSelected() async {
        guard let store, !selectedID.isEmpty else { return }
        do {
            let saved = try await store.save(
                id: selectedID,
                name: name,
                body: body
            )
            try await refresh(preferredID: saved.id)
            status = Status(
                message: ScribeCopy.SummaryTemplates.saved,
                systemImage: "checkmark.circle"
            )
        } catch {
            failure(ScribeCopy.SummaryTemplates.saveFailed)
        }
    }

    func removeSelected() async {
        guard let store, !selectedID.isEmpty, !selectedIsBuiltIn else { return }
        do {
            try await store.delete(id: selectedID)
            try await refresh(preferredID: nil)
            status = Status(
                message: ScribeCopy.SummaryTemplates.removed,
                systemImage: "checkmark.circle"
            )
        } catch {
            failure(ScribeCopy.SummaryTemplates.removeFailed)
        }
    }

    private func refresh(preferredID: String?) async throws {
        guard let store else { return }
        templates = try await store.templates()
        let id = preferredID.flatMap { preferred in
            templates.contains(where: { $0.id == preferred }) ? preferred : nil
        } ?? templates.first?.id ?? ""
        select(id)
    }

    private func failure(_ message: String) {
        status = Status(
            message: message,
            systemImage: "exclamationmark.triangle"
        )
    }
}
