import SwiftUI

extension Notification.Name {
    static let scribeFocusSearch = Notification.Name(
        "Scribe.focusSearch"
    )
}

private enum ScribeShellSelection: Hashable {
    case allSessions
    case needsSummary
    case imported
    case manualFolder(String)
    case recording
    case settings

    var persistenceID: String {
        switch self {
        case .allSessions: "smart.all"
        case .needsSummary: "smart.needsSummary"
        case .imported: "smart.imported"
        case let .manualFolder(path): "manual.\(path)"
        case .recording: "recording"
        case .settings: "settings"
        }
    }

    init(persistenceID: String) {
        switch persistenceID {
        case "smart.needsSummary": self = .needsSummary
        case "smart.imported": self = .imported
        case "recording": self = .recording
        case "settings": self = .settings
        default:
            if persistenceID.hasPrefix("manual.") {
                self = .manualFolder(
                    String(persistenceID.dropFirst("manual.".count))
                )
            } else {
                self = .allSessions
            }
        }
    }
}

struct ScribeShellView: View {
    @ObservedObject var recorder: MeetingRecorderViewModel
    @AppStorage(ScribeShellPreferences.sidebarVisibleKey)
    private var sidebarWasVisible = true
    @AppStorage(ScribeShellPreferences.selectionKey)
    private var persistedSelection = "smart.all"
    @State private var selection = ScribeShellSelection.allSessions
    @State private var columnVisibility =
        NavigationSplitViewVisibility.all
    @State private var searchQuery = ""
    @State private var isDropTargeted = false
    @State private var showsNewFolderPrompt = false
    @State private var newFolderName = ""
    @State private var libraryNavigationTarget:
        SessionLibraryNavigationTarget?
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: 186,
                    ideal: 204,
                    max: 220
                )
        } detail: {
            VStack(spacing: 0) {
                mainHeader
                Divider()
                mainContent
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .dropDestination(
            for: URL.self,
            action: { urls, _ in
                guard recorder.canImportMedia, !urls.isEmpty else {
                    return false
                }
                recorder.importMediaFiles(urls)
                return true
            },
            isTargeted: { isDropTargeted = $0 }
        )
        .onAppear {
            columnVisibility = sidebarWasVisible ? .all : .detailOnly
            let restored = ScribeShellSelection(
                persistenceID: ScribeShellPresentation.resolvedSelectionID(
                    persistedSelection,
                    summaryFeatureAvailable:
                        ScribeFeatureAvailability.summaryGeneration
                )
            )
            selection = validSelection(restored)
        }
        .onChange(of: columnVisibility) { _, newValue in
            sidebarWasVisible = newValue != .detailOnly
        }
        .onChange(of: recorder.showsRecordingWorkspace) { _, isVisible in
            if !isVisible, selection == .recording {
                select(.allSessions)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .scribeFocusSearch)
        ) { _ in
            searchIsFocused = true
        }
        .task(id: searchQuery) {
            await recorder.searchSessionLibrary(searchQuery)
        }
        .alert(
            ScribeCopy.Shell.newFolder,
            isPresented: $showsNewFolderPrompt
        ) {
            TextField(ScribeCopy.Shell.folderName, text: $newFolderName)
            Button(ScribeCopy.Shell.cancel, role: .cancel) {
                newFolderName = ""
            }
            Button(ScribeCopy.Shell.create) {
                recorder.createManualSessionFolder(named: newFolderName)
                newFolderName = ""
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            primarySidebarControl
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 14)

            smartFolders

            Divider()
                .padding(.vertical, 8)

            manualFolders

            Spacer(minLength: 12)
            Divider()
            sidebarRow(
                title: ScribeCopy.Shell.settings,
                systemImage: "gearshape",
                count: nil,
                selection: .settings
            )
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .fill(ScribePalette.accent.opacity(0.12))
                    .stroke(ScribePalette.accent, style: StrokeStyle(
                        lineWidth: 2,
                        dash: [6, 4]
                    ))
                    .overlay {
                        Label(
                            ScribeCopy.Shell.dropToImport,
                            systemImage: "square.and.arrow.down"
                        )
                        .font(.headline.weight(.medium))
                        .foregroundStyle(ScribePalette.accent)
                    }
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var primarySidebarControl: some View {
        if recorder.showsRecordingWorkspace {
            SidebarRecordingControl(
                recorder: recorder,
                onShowRecording: { select(.recording) }
            )
        } else {
            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 0) {
                    Button {
                        select(.recording)
                        recorder.startRecording()
                    } label: {
                        Label(
                            ScribeCopy.Shell.newRecording,
                            systemImage: "record.circle"
                        )
                        .foregroundStyle(ScribePalette.readyToRecord)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(recorder.isBusy)

                    Divider()
                        .frame(height: 22)

                    Menu {
                        Button(ScribeCopy.Shell.importMedia) {
                            recorder.chooseMediaForImport()
                        }
                        .keyboardShortcut("o", modifiers: [.command])
                    } label: {
                        Image(systemName: "chevron.down")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .disabled(!recorder.canImportMedia)
                    .accessibilityLabel(ScribeCopy.Shell.importMedia)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassEffect(
                    .regular
                        .tint(ScribePalette.readyToRecord.opacity(0.16))
                        .interactive()
                )
            }
        }
    }

    private var smartFolders: some View {
        VStack(spacing: 2) {
            sidebarRow(
                title: ScribeCopy.Shell.allSessions,
                systemImage: "tray.full",
                count: recorder.sessionSmartFolderCounts.allSessions,
                selection: .allSessions
            )
            if ScribeFeatureAvailability.summaryGeneration {
                sidebarRow(
                    title: ScribeCopy.Shell.needsSummary,
                    systemImage: "sparkles",
                    count: recorder.sessionSmartFolderCounts.needsSummary,
                    selection: .needsSummary
                )
            }
            sidebarRow(
                title: ScribeCopy.Shell.imported,
                systemImage: "square.and.arrow.down",
                count: recorder.sessionSmartFolderCounts.imported,
                selection: .imported
            )
        }
        .padding(.horizontal, 8)
    }

    private var manualFolders: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(ScribeCopy.Shell.folders)
                    .font(ScribeTypography.sidebarSection)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showsNewFolderPrompt = true
                } label: {
                    Label(
                        ScribeCopy.Shell.newFolder,
                        systemImage: "plus"
                    )
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .help(ScribeCopy.Shell.newFolder)
            }
            .padding(.horizontal, 12)

            ForEach(recorder.manualSessionFolders) { folder in
                sidebarRow(
                    title: folder.name,
                    systemImage: "folder",
                    count: sessionCount(in: folder.directory),
                    selection: .manualFolder(folder.directory.path)
                )
            }
        }
        .padding(.horizontal, 8)
    }

    private func sidebarRow(
        title: String,
        systemImage: String,
        count: Int?,
        selection rowSelection: ScribeShellSelection
    ) -> some View {
        Button {
            select(rowSelection)
        } label: {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(
                        selection == rowSelection
                            ? ScribePalette.accent
                            : Color.clear
                    )
                    .frame(width: 3, height: 20)
                Image(systemName: systemImage)
                    .frame(width: 16)
                    .foregroundStyle(
                        selection == rowSelection
                            ? ScribePalette.accent
                            : Color.secondary
                    )
                Text(title)
                    .font(ScribeTypography.sidebarItem)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text(count, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
            .padding(.trailing, 8)
        }
        .buttonStyle(.plain)
    }

    private var mainHeader: some View {
        HStack {
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(ScribeCopy.Shell.search, text: $searchQuery)
                    .textFieldStyle(.plain)
                    .focused($searchIsFocused)
                Text(ScribeCopy.Shell.searchShortcut)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: 280)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var mainContent: some View {
        if recorder.showsPermissionSetup {
            PermissionSetupView(recorder: recorder)
                .padding(40)
        } else {
            switch selection {
            case .recording where recorder.showsRecordingWorkspace:
                RecordingWorkspaceView(recorder: recorder)
            case .settings:
                RecordingView(recorder: recorder)
                    .padding(40)
            case .allSessions, .needsSummary, .imported, .manualFolder,
                .recording:
                if let target = libraryNavigationTarget,
                    let session = recorder.sessionLibraryItems.first(where: {
                        $0.id == target.sessionID
                    })
                {
                    SessionReadingView(
                        recorder: recorder,
                        session: session,
                        initialStartTime: target.startTime,
                        onClose: { libraryNavigationTarget = nil }
                    )
                    .id(target.sessionID)
                } else {
                    SessionLibraryView(
                        sessions: visibleLibrarySessions,
                        searchQuery: searchQuery,
                        searchGroups: recorder.sessionSearchGroups,
                        navigationTarget: $libraryNavigationTarget,
                        emptyDetail: libraryEmptyDetail,
                        onStartRecording: {
                            select(.recording)
                            recorder.startRecording()
                        },
                        onRename: recorder.renameSession,
                        onMoveToTrash: recorder.moveSessionToTrash
                    )
                }
            }
        }
    }

    private var visibleLibrarySessions: [SessionLibraryItem] {
        switch selection {
        case .needsSummary:
            recorder.sessionLibraryItems.filter { !$0.artifacts.summary }
        case .imported:
            recorder.sessionLibraryItems.filter { $0.source == .importedFile }
        case let .manualFolder(path):
            recorder.sessionLibraryItems.filter {
                $0.directory.deletingLastPathComponent().standardizedFileURL
                    == URL(fileURLWithPath: path).standardizedFileURL
            }
        case .allSessions, .recording, .settings:
            recorder.sessionLibraryItems
        }
    }

    private var libraryEmptyDetail: String {
        switch selection {
        case .needsSummary:
            recorder.sessionSmartFolderCounts.needsSummary == 0
                ? ScribeCopy.Shell.noSummarySessions
                : ScribeCopy.Shell.sessionCount(
                    recorder.sessionSmartFolderCounts.needsSummary
                )
        case .imported:
            recorder.sessionSmartFolderCounts.imported == 0
                ? ScribeCopy.Shell.noImportedSessions
                : ScribeCopy.Shell.sessionCount(
                    recorder.sessionSmartFolderCounts.imported
                )
        case let .manualFolder(path):
            ScribeCopy.Shell.sessionCount(
                sessionCount(in: URL(fileURLWithPath: path))
            )
        case .allSessions, .recording, .settings:
            recorder.sessionSmartFolderCounts.allSessions == 0
                ? ScribeCopy.Library.noRecordingsDetail
                : ScribeCopy.Shell.sessionCount(
                    recorder.sessionSmartFolderCounts.allSessions
                )
        }
    }

    private func select(_ newSelection: ScribeShellSelection) {
        selection = newSelection
        libraryNavigationTarget = nil
        persistedSelection = newSelection.persistenceID
    }

    private func validSelection(
        _ proposed: ScribeShellSelection
    ) -> ScribeShellSelection {
        if proposed == .needsSummary,
            !ScribeFeatureAvailability.summaryGeneration
        {
            return .allSessions
        }
        if case let .manualFolder(path) = proposed,
            !recorder.manualSessionFolders.contains(where: {
                $0.directory.path == path
            })
        {
            return .allSessions
        }
        if proposed == .recording, !recorder.showsRecordingWorkspace {
            return .allSessions
        }
        return proposed
    }

    private func sessionCount(in folder: URL) -> Int {
        recorder.indexedSessions.filter {
            $0.directory.deletingLastPathComponent().standardizedFileURL
                == folder.standardizedFileURL
        }.count
    }
}

private struct SessionLibraryView: View {
    let sessions: [SessionLibraryItem]
    let searchQuery: String
    let searchGroups: [SessionSearchGroup]
    @Binding var navigationTarget: SessionLibraryNavigationTarget?
    let emptyDetail: String
    let onStartRecording: () -> Void
    let onRename: (SessionLibraryItem, String) -> Void
    let onMoveToTrash: (SessionLibraryItem) -> Void

    @State private var renamingSession: SessionLibraryItem?
    @State private var renameTitle = ""
    @State private var deletingSession: SessionLibraryItem?

    private var trimmedSearch: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if !trimmedSearch.isEmpty {
                searchResults
            } else if sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .alert(
            ScribeCopy.Library.renameSession,
            isPresented: Binding(
                get: { renamingSession != nil },
                set: { if !$0 { renamingSession = nil } }
            )
        ) {
            TextField(ScribeCopy.Library.sessionTitle, text: $renameTitle)
            Button(ScribeCopy.Library.cancel, role: .cancel) {
                renamingSession = nil
            }
            Button(ScribeCopy.Library.save) {
                if let renamingSession {
                    onRename(renamingSession, renameTitle)
                }
                renamingSession = nil
            }
            .disabled(
                renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )
        }
        .confirmationDialog(
            deletingSession.map {
                ScribeCopy.Library.moveToTrashTitle($0.title)
            } ?? ScribeCopy.Library.moveToTrash,
            isPresented: Binding(
                get: { deletingSession != nil },
                set: { if !$0 { deletingSession = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(
                ScribeCopy.Library.confirmMoveToTrash,
                role: .destructive
            ) {
                if let deletingSession {
                    onMoveToTrash(deletingSession)
                }
                deletingSession = nil
            }
            Button(ScribeCopy.Library.cancel, role: .cancel) {
                deletingSession = nil
            }
        } message: {
            if let deletingSession {
                Text(ScribeCopy.Library.moveToTrashBody(
                    size: ByteCountFormatter.string(
                        fromByteCount: deletingSession.byteCount,
                        countStyle: .file
                    )
                ))
            }
        }
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(
                    SessionLibraryPresentation().dateGroups(from: sessions)
                ) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            sessionRow(session)
                            Divider().padding(.leading, 22)
                        }
                    } header: {
                        Text(dateHeading(group.date))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                            .padding(.bottom, 8)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
            }
        }
    }

    private var searchResults: some View {
        Group {
            if searchGroups.isEmpty {
                VStack(spacing: 8) {
                    Text(ScribeCopy.Library.noSearchResults)
                        .font(.title2.weight(.medium))
                    Text(ScribeCopy.Library.noSearchResultsDetail)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(searchGroups) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Rectangle()
                                        .fill(
                                            navigationTarget?.sessionID == group.id
                                                ? ScribePalette.accent
                                                : Color.clear
                                        )
                                        .frame(width: 3, height: 28)
                                    Text(group.session.title)
                                        .font(ScribeTypography.sessionTitle)
                                    Spacer()
                                    Text(ScribeCopy.Library.resultCount(
                                        group.hits.count
                                    ))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                }
                                ForEach(group.hits) { hit in
                                    Button {
                                        navigationTarget =
                                            SessionLibraryNavigationTarget(
                                                group: group,
                                                hit: hit
                                            )
                                    } label: {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(hitLabel(hit))
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                                .frame(width: 58, alignment: .leading)
                                            Text(hit.text)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.vertical, 5)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    .padding(.vertical, 18)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            EmptyLibraryWaveformView(sessionCount: sessions.count)
                .padding(.horizontal, 46)
            Text(ScribeCopy.Library.noRecordings)
                .font(.system(size: 17, weight: .medium))
            Text(emptyDetail.isEmpty
                ? ScribeCopy.Library.noRecordingsDetail
                : emptyDetail)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
            Button(ScribeCopy.Library.startRecording, action: onStartRecording)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sessionRow(_ session: SessionLibraryItem) -> some View {
        Button {
            navigationTarget = SessionLibraryNavigationTarget(
                sessionID: session.id,
                startTime: nil
            )
        } label: {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(
                        navigationTarget?.sessionID == session.id
                            ? ScribePalette.accent
                            : Color.clear
                    )
                    .frame(width: 3, height: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(ScribeTypography.sessionTitle)
                        .lineLimit(1)
                    Text(metadata(for: session))
                        .font(ScribeTypography.sessionMetadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                artifactIcons(session.artifacts)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!session.isAvailable)
        .contextMenu {
            Button(ScribeCopy.Library.rename) {
                renamingSession = session
                renameTitle = session.title
            }
            Button(ScribeCopy.Library.moveToTrash, role: .destructive) {
                deletingSession = session
            }
        }
    }

    private func artifactIcons(_ presence: SessionArtifactPresence) -> some View {
        HStack(spacing: 11) {
            artifactIcon(
                "pencil",
                label: ScribeCopy.Library.notes,
                isPresent: presence.notes
            )
            artifactIcon(
                "doc.text",
                label: ScribeCopy.Library.transcript,
                isPresent: presence.transcript
            )
            artifactIcon(
                "sparkles",
                label: ScribeCopy.Library.summary,
                isPresent: presence.summary
            )
            artifactIcon(
                "waveform",
                label: ScribeCopy.Library.audio,
                isPresent: presence.audio
            )
        }
    }

    private func artifactIcon(
        _ name: String,
        label: String,
        isPresent: Bool
    ) -> some View {
        Image(systemName: name)
            .frame(width: 16)
            .foregroundStyle(
                isPresent ? Color.primary : Color.secondary.opacity(0.28)
            )
            .accessibilityLabel(label)
            .accessibilityValue(
                isPresent ? ScribeCopy.Library.present : ScribeCopy.Library.absent
            )
            .help(label)
    }

    private func metadata(for session: SessionLibraryItem) -> String {
        let duration = durationText(session.duration)
        if session.source == .importedFile {
            return "\(duration) · \(ScribeCopy.Library.imported)"
        }
        let time = session.createdAt.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened)
        )
        return "\(duration) · \(time) · \(ScribeCopy.Library.speakerCount(session.speakerCount))"
    }

    private func durationText(_ interval: TimeInterval) -> String {
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

    private func hitLabel(_ hit: SessionSearchHit) -> String {
        guard let startTime = hit.startTime else {
            switch hit.kind {
            case .notes: return ScribeCopy.Library.notes
            case .title: return ScribeCopy.Library.session
            case .transcript: return ScribeCopy.Library.transcript
            }
        }
        return durationText(startTime)
    }

    private func dateHeading(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return ScribeCopy.Library.today }
        if calendar.isDateInYesterday(date) {
            return ScribeCopy.Library.yesterday
        }
        return date.formatted(
            Date.FormatStyle()
                .weekday(.wide)
                .month(.wide)
                .day()
                .year()
        )
    }
}

private struct SidebarRecordingControl: View {
    @ObservedObject var recorder: MeetingRecorderViewModel
    let onShowRecording: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: onShowRecording) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(
                                recorder.isRecording
                                    ? ScribePalette.recordingActive
                                    : Color.secondary
                            )
                            .frame(width: 9, height: 9)
                            .accessibilityHidden(true)
                        Text(ScribeCopy.Shell.recording)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(
                                recorder.isRecording
                                    ? ScribePalette.recordingActive
                                    : Color.primary
                            )
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 1)) {
                            context in
                            Text(elapsedText(at: context.date))
                                .font(
                                    .caption.monospacedDigit().weight(.medium)
                                )
                                .accessibilityLabel(
                                    ScribeCopy.Recording.elapsedTime
                                )
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(ScribeCopy.Shell.currentRecording)

                SidebarSpeechLevelMeter(
                    label: ScribeCopy.Recording.you,
                    accessibilityLabel: ScribeCopy.Recording.microphoneLevel,
                    value: recorder.recordingLevels.microphone,
                    color: ScribePalette.accent
                )
                SidebarSpeechLevelMeter(
                    label: ScribeCopy.Recording.others,
                    accessibilityLabel: ScribeCopy.Recording.systemAudioLevel,
                    value: recorder.recordingLevels.system,
                    color: ScribePalette.others
                )

                if let status = recorder.recordingPinStatus {
                    Text(status.message)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(status.isFailure ? .primary : .secondary)
                    .transition(.opacity)
                } else if let notice = recorder.sidebarRecordingNotice {
                    Text(notice.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    recorder.addRecordingPin()
                } label: {
                    HStack {
                        Label(
                            ScribeCopy.Recording.addPin,
                            systemImage: "pin.fill"
                        )
                        Spacer()
                        Text(ScribeCopy.Recording.pinShortcut)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!recorder.canAddRecordingPin)

                Button {
                    recorder.stopRecording()
                } label: {
                    Label(
                        ScribeCopy.Recording.stop,
                        systemImage: "stop.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!recorder.isRecording || recorder.isBusy)
            }
            .padding(11)
            // glassEffect defaults to a capsule, which on this tall control
            // renders as a circular blob spilling outside the sidebar.
            .glassEffect(
                recorder.isRecording
                    ? .regular
                        .tint(ScribePalette.recordingActive.opacity(0.14))
                        .interactive()
                    : .regular.interactive(),
                in: .rect(cornerRadius: 12)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ScribeCopy.Recording.recordingControls)
    }

    private func elapsedText(at date: Date) -> String {
        let elapsed = Int(recorder.elapsedRecordingTime(at: date))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

}

private struct SidebarSpeechLevelMeter: View {
    let label: String
    let accessibilityLabel: String
    let value: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * value)
                }
            }
            .frame(height: 6)
        }
        .animation(.linear(duration: 0.18), value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(
            ScribeCopy.Recording.speechLevel(
                percent: Int((value * 100).rounded())
            )
        )
    }
}
