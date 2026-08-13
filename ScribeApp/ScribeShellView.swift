import AudioCapture
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
                persistenceID: persistedSelection
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
                    .fill(.tint.opacity(0.12))
                    .stroke(.tint, style: StrokeStyle(
                        lineWidth: 2,
                        dash: [6, 4]
                    ))
                    .overlay {
                        Label(
                            ScribeCopy.Shell.dropToImport,
                            systemImage: "square.and.arrow.down"
                        )
                        .font(.headline.weight(.medium))
                        .foregroundStyle(.tint)
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
                .glassEffect(.regular.interactive())
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
            sidebarRow(
                title: ScribeCopy.Shell.needsSummary,
                systemImage: "sparkles",
                count: recorder.sessionSmartFolderCounts.needsSummary,
                selection: .needsSummary
            )
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
                    .font(.caption.weight(.medium))
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
                            ? Color.accentColor
                            : Color.clear
                    )
                    .frame(width: 3, height: 20)
                Image(systemName: systemImage)
                    .frame(width: 16)
                    .foregroundStyle(
                        selection == rowSelection
                            ? Color.accentColor
                            : Color.secondary
                    )
                Text(title)
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
                libraryPlaceholder
            }
        }
    }

    private var libraryPlaceholder: some View {
        VStack(spacing: 10) {
            if libraryCount == 0 {
                Image(systemName: "tray")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(libraryTitle)
                    .font(.title2.weight(.medium))
                Text(libraryEmptyDetail)
                    .foregroundStyle(.secondary)
            } else {
                Text(libraryTitle)
                    .font(.title2.weight(.medium))
                Text(ScribeCopy.Shell.sessionListComing(libraryCount))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var libraryCount: Int {
        switch selection {
        case .needsSummary:
            recorder.sessionSmartFolderCounts.needsSummary
        case .imported:
            recorder.sessionSmartFolderCounts.imported
        case let .manualFolder(path):
            sessionCount(in: URL(fileURLWithPath: path))
        case .allSessions, .recording, .settings:
            recorder.sessionSmartFolderCounts.allSessions
        }
    }

    private var libraryTitle: String {
        switch selection {
        case .allSessions: ScribeCopy.Shell.allSessions
        case .needsSummary: ScribeCopy.Shell.needsSummary
        case .imported: ScribeCopy.Shell.imported
        case let .manualFolder(path):
            URL(fileURLWithPath: path).lastPathComponent
        case .recording: ScribeCopy.Shell.sessions
        case .settings: ScribeCopy.Shell.settings
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
                ? ScribeCopy.Shell.noSessionsDetail
                : ScribeCopy.Shell.sessionCount(
                    recorder.sessionSmartFolderCounts.allSessions
                )
        }
    }

    private func select(_ newSelection: ScribeShellSelection) {
        selection = newSelection
        persistedSelection = newSelection.persistenceID
    }

    private func validSelection(
        _ proposed: ScribeShellSelection
    ) -> ScribeShellSelection {
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
                                    ? Color.red
                                    : Color.secondary
                            )
                            .frame(width: 9, height: 9)
                            .accessibilityHidden(true)
                        Text(ScribeCopy.Shell.recording)
                            .font(.callout.weight(.medium))
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
                    color: .accentColor
                )
                SidebarSpeechLevelMeter(
                    label: ScribeCopy.Recording.others,
                    accessibilityLabel: ScribeCopy.Recording.systemAudioLevel,
                    value: recorder.recordingLevels.system,
                    color: .purple
                )

                if let pin = recorder.recentRecordingPin {
                    Text(
                        ScribeCopy.Recording.pinAdded(
                            timecode: pinTimecode(pin.sampleOffset)
                        )
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
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
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!recorder.isRecording || recorder.isBusy)
            }
            .padding(11)
            .glassEffect(.regular.interactive())
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ScribeCopy.Recording.recordingControls)
    }

    private func elapsedText(at date: Date) -> String {
        let elapsed = Int(recorder.elapsedRecordingTime(at: date))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    private func pinTimecode(_ sampleOffset: Int64) -> String {
        let seconds = max(
            0,
            Int(
                Double(sampleOffset)
                    / CanonicalAudioFormat.sampleRate
            )
        )
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
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
