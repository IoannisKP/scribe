@preconcurrency import AppKit
@preconcurrency import AVFoundation
import AudioCapture
import SpeechPipeline
import SwiftUI

@MainActor
private final class SessionPlaybackController: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false

    private struct TrackPlayer {
        let player: AVAudioPlayer
        let startTime: TimeInterval
    }

    private var tracks: [TrackPlayer] = []
    private var delayedStartTasks: [Task<Void, Never>] = []
    private var clockTask: Task<Void, Never>?
    private var anchorDate = Date()
    private var anchorTime: TimeInterval = 0
    private var generation: UInt64 = 0

    func load(_ document: SessionReadingDocument) {
        stopTasks()
        tracks.forEach { $0.player.stop() }
        tracks = document.manifest.tracks.compactMap { track in
            let url = document.directory.appendingPathComponent(
                track.relativePath
            )
            guard let player = try? AVAudioPlayer(contentsOf: url) else {
                return nil
            }
            player.prepareToPlay()
            return TrackPlayer(player: player, startTime: track.startTime)
        }
        duration = document.duration
        currentTime = min(currentTime, duration)
        isPlaying = false
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard !tracks.isEmpty, duration > 0 else { return }
        if currentTime >= duration { currentTime = 0 }
        stopTasks()
        isPlaying = true
        anchorDate = Date()
        anchorTime = currentTime
        generation &+= 1
        let activeGeneration = generation

        for track in tracks {
            let local = currentTime - track.startTime
            if local >= 0, local < track.player.duration {
                track.player.currentTime = local
                track.player.play()
            } else if local < 0 {
                let delay = -local
                let task = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard let self,
                        self.isPlaying,
                        self.generation == activeGeneration
                    else { return }
                    track.player.currentTime = 0
                    track.player.play()
                }
                delayedStartTasks.append(task)
            }
        }

        clockTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.isPlaying {
                self.currentTime = min(
                    self.duration,
                    self.anchorTime
                        + Date().timeIntervalSince(self.anchorDate)
                )
                if self.currentTime >= self.duration {
                    self.pause(resetAnchor: false)
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func pause() {
        pause(resetAnchor: true)
    }

    func seek(to time: TimeInterval) {
        let shouldResume = isPlaying
        pause(resetAnchor: false)
        currentTime = min(max(0, time), duration)
        for track in tracks {
            let local = currentTime - track.startTime
            track.player.currentTime = min(
                max(0, local),
                track.player.duration
            )
        }
        if shouldResume { play() }
    }

    private func pause(resetAnchor: Bool) {
        if resetAnchor, isPlaying {
            currentTime = min(
                duration,
                anchorTime + Date().timeIntervalSince(anchorDate)
            )
        }
        isPlaying = false
        generation &+= 1
        tracks.forEach { $0.player.pause() }
        stopTasks()
    }

    private func stopTasks() {
        clockTask?.cancel()
        clockTask = nil
        delayedStartTasks.forEach { $0.cancel() }
        delayedStartTasks = []
    }
}

struct SessionReadingView: View {
    @ObservedObject var recorder: MeetingRecorderViewModel
    let session: SessionLibraryItem
    let initialStartTime: TimeInterval?
    let onClose: () -> Void

    @StateObject private var playback = SessionPlaybackController()
    @State private var document: SessionReadingDocument?
    @State private var selectedArtifactID = ""
    @State private var revisionParagraphs: [TranscriptParagraph] = []
    @State private var loadError: String?
    @State private var copiedArtifactID: String?

    var body: some View {
        VStack(spacing: 0) {
            readerHeader
            Divider()
            if let document {
                HStack(spacing: 0) {
                    artifactRail(document)
                        .frame(width: 194)
                    Divider()
                    artifactContent(document)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                SessionTimelineView(
                    document: document,
                    playback: playback
                )
            } else if let loadError {
                ContentUnavailableView(
                    ScribeCopy.Reading.sessionReadFailed,
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: "\(session.id.uuidString):\(recorder.sessionContentRevision)") {
            await loadDocument(selectPreferred: selectedArtifactID.isEmpty)
        }
        .onChange(of: selectedArtifactID) { _, _ in
            loadRevisionParagraphs()
        }
        .onDisappear { playback.pause() }
    }

    private var readerHeader: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Label(
                    ScribeCopy.Reading.backToSessions,
                    systemImage: "chevron.left"
                )
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .help(ScribeCopy.Reading.backToSessions)

            VStack(alignment: .leading, spacing: 3) {
                Text(document?.manifest.title ?? session.title)
                    .font(ScribeTypography.sessionTitle)
                    .lineLimit(1)
                Text(sessionMetadata)
                    .font(ScribeTypography.sessionMetadata)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            Button(ScribeCopy.Reading.revealInFinder) {
                NSWorkspace.shared.activateFileViewerSelecting([session.directory])
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func artifactRail(
        _ document: SessionReadingDocument
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(coreArtifacts(in: document)) { artifact in
                        artifactRow(artifact)
                    }
                    let additional = document.artifacts.filter {
                        $0.kind == .additional
                    }
                    if !additional.isEmpty {
                        sectionHeader(ScribeCopy.Library.session)
                        ForEach(additional) { artifact in
                            artifactRow(artifact)
                        }
                    }
                    let revisions = document.artifacts.filter {
                        $0.kind == .transcriptionRevision
                    }
                    if !revisions.isEmpty {
                        sectionHeader(ScribeCopy.Reading.transcriptions)
                        ForEach(revisions) { artifact in
                            artifactRow(artifact)
                        }
                    }
                }
                .padding(8)
            }
            Divider()
            Text(ScribeCopy.Reading.dragHint)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func artifactRow(
        _ artifact: SessionReadingArtifact
    ) -> some View {
        Button {
            selectedArtifactID = artifact.id
        } label: {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(
                        selectedArtifactID == artifact.id
                            ? ScribePalette.accent : Color.clear
                    )
                    .frame(width: 3, height: 30)
                Image(systemName: icon(for: artifact.kind))
                    .frame(width: 16)
                    .foregroundStyle(artifact.isPresent ? .primary : .tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.title)
                        .font(.system(size: 13, weight: .regular))
                        .lineLimit(1)
                    if let detail = artifact.detail {
                        Text(detail)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 2)
                if let provenance = artifact.summaryProvenance {
                    Text(provenance.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .padding(.trailing, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag {
            guard let url = artifact.primaryURL else {
                return NSItemProvider()
            }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .contextMenu {
            if let copyTitle = copyTitle(for: artifact),
                artifact.copyText != nil
            {
                Button(copyTitle) { copy(artifact) }
            }
            if let url = artifact.primaryURL {
                Button(ScribeCopy.Reading.revealInFinder) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .disabled(!artifact.isPresent && artifact.kind == .additional)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(ScribeTypography.sidebarSection)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func artifactContent(
        _ document: SessionReadingDocument
    ) -> some View {
        if let artifact = selectedArtifact(in: document) {
            switch artifact.kind {
            case .notes:
                notesView(artifact)
            case .transcript:
                transcriptView(document.currentParagraphs, document: document)
            case .transcriptionRevision:
                transcriptView(revisionParagraphs, document: document)
            case .summary:
                summaryView(artifact)
            case .audio:
                audioView(artifact)
            case .additional:
                additionalView(artifact)
            }
        }
    }

    private func notesView(_ artifact: SessionReadingArtifact) -> some View {
        Group {
            if let text = artifact.copyText, !text.isEmpty {
                ScrollView {
                    Text(text)
                        .font(ScribeTypography.notesBody)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(28)
                }
                .overlay(alignment: .topTrailing) { copyButton(for: artifact) }
            } else {
                missingArtifact(
                    title: ScribeCopy.Reading.noNotes,
                    actionTitle: ScribeCopy.Reading.createNotes
                ) {
                    Task { await recorder.createNotes(in: session) }
                }
            }
        }
    }

    private func transcriptView(
        _ paragraphs: [TranscriptParagraph],
        document: SessionReadingDocument
    ) -> some View {
        Group {
            if paragraphs.isEmpty {
                missingArtifact(
                    title: ScribeCopy.Reading.noTranscript,
                    detail: ScribeCopy.Reading.noTranscriptDetail,
                    actionTitle: ScribeCopy.Reading.transcribeNow
                ) {
                    recorder.retranscribeSession(session)
                }
            } else {
                VStack(spacing: 0) {
                    retranscriptionBar(document)
                    Divider()
                    TranscriptReadingScrollView(
                        paragraphs: paragraphs,
                        manifest: document.manifest,
                        playback: playback,
                        initialStartTime: initialStartTime,
                        onRename: { speakerID, name in
                            await recorder.renameSpeaker(
                                in: session,
                                speakerID: speakerID,
                                to: name
                            )
                        }
                    )
                }
            }
        }
    }

    private func retranscriptionBar(
        _ document: SessionReadingDocument
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(ScribeCopy.Reading.transcribeWith)
                    .font(.system(size: 12, weight: .medium))
                Picker(
                    ScribeCopy.Reading.transcribeWith,
                    selection: $recorder.selectedTranscriptionModel
                ) {
                    ForEach(recorder.modelOptions, id: \.id) { model in
                        Text(model.descriptor.displayName).tag(model)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 250)
                Button(ScribeCopy.Reading.transcribeAgain) {
                    recorder.retranscribeSession(session)
                }
                .buttonStyle(.bordered)
                .disabled(
                    recorder.isTranscribing
                        || !recorder.isSelectedModelAvailable
                )
                Spacer()
                if let artifact = selectedArtifact(in: document),
                    artifact.copyText != nil
                {
                    copyButton(for: artifact)
                        .padding(0)
                }
            }
            retranscriptionStatus
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var retranscriptionStatus: some View {
        if recorder.sessionRetranscriptionState.belongs(to: session.id) {
            switch recorder.sessionRetranscriptionState {
            case let .running(_, modelName, estimate):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(ScribeCopy.Reading.transcribing(
                        modelName: modelName,
                        estimate: estimate
                    ))
                }
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
            case let .completed(_, message), let .failed(_, message):
                Text(message)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
            case .idle:
                EmptyView()
            }
        }
    }

    private func summaryView(_ artifact: SessionReadingArtifact) -> some View {
        Group {
            if let text = artifact.copyText {
                ScrollView {
                    Text(text)
                        .font(ScribeTypography.notesBody)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(28)
                }
                .overlay(alignment: .topTrailing) { copyButton(for: artifact) }
            } else {
                VStack(spacing: 8) {
                    Text(ScribeCopy.Reading.noSummary)
                        .font(.system(size: 17, weight: .medium))
                    Text(ScribeCopy.Reading.summaryMilestone)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                    Button(ScribeCopy.Reading.generateSummary) {}
                        .buttonStyle(.bordered)
                        .disabled(true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func audioView(_ artifact: SessionReadingArtifact) -> some View {
        Group {
            if artifact.urls.isEmpty {
                missingArtifact(title: ScribeCopy.Reading.noAudio)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(ScribeCopy.Reading.fileCount(artifact.urls.count))
                        .font(.system(size: 13, weight: .medium))
                    ForEach(artifact.urls, id: \.self) { url in
                        fileRow(url)
                    }
                    Spacer()
                }
                .padding(28)
            }
        }
    }

    private func additionalView(
        _ artifact: SessionReadingArtifact
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(artifact.title)
                .font(.system(size: 17, weight: .medium))
            if let text = artifact.copyText {
                ScrollView {
                    Text(text)
                        .font(ScribeTypography.notesBody)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let url = artifact.primaryURL {
                fileRow(url)
            }
            Spacer()
        }
        .padding(28)
    }

    private func fileRow(_ url: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .regular))
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey])
                    .fileSize
                {
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(size),
                        countStyle: .file
                    ))
                    .font(.system(
                        size: 11,
                        weight: .regular,
                        design: .monospaced
                    ))
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(ScribeCopy.Reading.revealInFinder) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
    }

    private func missingArtifact(
        title: String,
        detail: String? = nil,
        actionTitle: String? = nil,
        action: @escaping () -> Void = {}
    ) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 17, weight: .medium))
            if let detail {
                Text(detail)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyButton(
        for artifact: SessionReadingArtifact
    ) -> some View {
        Button(copiedArtifactID == artifact.id
            ? ScribeCopy.Reading.copied
            : copyTitle(for: artifact) ?? ScribeCopy.Reading.copied
        ) {
            copy(artifact)
        }
        .buttonStyle(.bordered)
        .padding(14)
    }

    private func copy(_ artifact: SessionReadingArtifact) {
        guard let text = artifact.copyText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copiedArtifactID = artifact.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if copiedArtifactID == artifact.id { copiedArtifactID = nil }
        }
    }

    private func copyTitle(
        for artifact: SessionReadingArtifact
    ) -> String? {
        switch artifact.kind {
        case .notes: ScribeCopy.Reading.copyNotes
        case .transcript, .transcriptionRevision:
            ScribeCopy.Reading.copyTranscript
        case .summary: ScribeCopy.Reading.copySummary
        case .audio, .additional: nil
        }
    }

    private func coreArtifacts(
        in document: SessionReadingDocument
    ) -> [SessionReadingArtifact] {
        document.artifacts.filter {
            [.notes, .transcript, .summary, .audio].contains($0.kind)
        }
    }

    private func selectedArtifact(
        in document: SessionReadingDocument
    ) -> SessionReadingArtifact? {
        document.artifacts.first { $0.id == selectedArtifactID }
            ?? document.artifacts.first
    }

    private func icon(for kind: SessionReadingArtifactKind) -> String {
        switch kind {
        case .notes: "pencil"
        case .transcript, .transcriptionRevision: "doc.text"
        case .summary: "sparkles"
        case .audio: "waveform"
        case .additional: "paperclip"
        }
    }

    private var sessionMetadata: String {
        let date = session.createdAt.formatted(date: .abbreviated, time: .shortened)
        let source = session.source == .importedFile
            ? ScribeCopy.Library.imported
            : ScribeCopy.Library.speakerCount(session.speakerCount)
        return "\(date) · \(source) · \(timecode(session.duration))"
    }

    private func timecode(_ interval: TimeInterval) -> String {
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

    private func loadDocument(selectPreferred: Bool) async {
        do {
            let presentation = SessionReadingPresentation()
            let loaded = try await Task.detached {
                try presentation.load(from: session.directory)
            }.value
            document = loaded
            loadError = nil
            if selectPreferred || !loaded.artifacts.contains(where: {
                $0.id == selectedArtifactID
            }) {
                selectedArtifactID = loaded.preferredArtifactID
            }
            playback.load(loaded)
            if let initialStartTime {
                playback.seek(to: initialStartTime)
            }
            loadRevisionParagraphs()
        } catch {
            loadError = error.localizedDescription
            document = nil
        }
    }

    private func loadRevisionParagraphs() {
        guard let document,
            let artifact = selectedArtifact(in: document),
            artifact.kind == .transcriptionRevision
        else {
            revisionParagraphs = []
            return
        }
        revisionParagraphs = (try? SessionReadingPresentation()
            .paragraphs(for: artifact)) ?? []
    }
}

private struct TranscriptReadingScrollView: View {
    let paragraphs: [TranscriptParagraph]
    let manifest: CaptureSessionManifest
    @ObservedObject var playback: SessionPlaybackController
    let initialStartTime: TimeInterval?
    let onRename: (String, String) async -> Bool

    @State private var renamingSpeakerID: String?
    @State private var speakerName = ""
    @State private var followedParagraphID: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(paragraphs) { paragraph in
                        paragraphRow(paragraph)
                            .id(paragraph.id)
                        Divider().padding(.leading, 28)
                    }
                }
            }
            .onAppear {
                if let initialStartTime,
                    let target = paragraph(at: initialStartTime)
                {
                    proxy.scrollTo(target.id, anchor: .center)
                }
            }
            .onChange(of: playback.currentTime) { _, newTime in
                guard playback.isPlaying,
                    let target = paragraph(at: newTime),
                    followedParagraphID != target.id
                else { return }
                followedParagraphID = target.id
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(target.id, anchor: .center)
                }
            }
        }
    }

    private func paragraphRow(
        _ paragraph: TranscriptParagraph
    ) -> some View {
        Button {
            playback.seek(to: paragraph.startTime)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    if paragraph.source != .imported,
                        let speakerID = resolvedSpeakerID(paragraph)
                    {
                        if renamingSpeakerID == speakerID {
                            TextField(
                                ScribeCopy.Reading.speakerName,
                                text: $speakerName
                            )
                            .font(ScribeTypography.transcriptSpeaker)
                            .textFieldStyle(.plain)
                            .frame(maxWidth: 180)
                            .onSubmit { commitRename(speakerID) }
                        } else {
                            Text(speakerName(for: paragraph))
                                .font(ScribeTypography.transcriptSpeaker)
                                .foregroundStyle(speakerColor(for: paragraph))
                                .onTapGesture {
                                    renamingSpeakerID = speakerID
                                    speakerName = speakerName(for: paragraph)
                                }
                                .help(ScribeCopy.Reading.renameSpeaker)
                        }
                    }
                    Text(timecode(paragraph.startTime))
                        .font(ScribeTypography.timestamp)
                        .foregroundStyle(.secondary)
                }
                Text(paragraph.text)
                    .font(ScribeTypography.transcriptBody)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func commitRename(_ speakerID: String) {
        let name = speakerName
        Task {
            if await onRename(speakerID, name) {
                renamingSpeakerID = nil
            }
        }
    }

    private func resolvedSpeakerID(
        _ paragraph: TranscriptParagraph
    ) -> String? {
        paragraph.speakerID
            ?? manifest.soleSpeakerIdentity(for: paragraph.source)?.id
    }

    private func speakerName(for paragraph: TranscriptParagraph) -> String {
        if let id = resolvedSpeakerID(paragraph),
            let name = manifest.speakerIdentity(identifiedBy: id)?.displayName
        {
            return name
        }
        return paragraph.source == .microphone
            ? ScribeCopy.Recording.you : ScribeCopy.Recording.others
    }

    private func speakerColor(for paragraph: TranscriptParagraph) -> Color {
        ScribePalette.speaker(
            id: resolvedSpeakerID(paragraph)
                ?? "source.\(paragraph.source.rawValue)",
            source: paragraph.source
        )
    }

    private func paragraph(at time: TimeInterval) -> TranscriptParagraph? {
        paragraphs.last(where: { $0.startTime <= time }) ?? paragraphs.first
    }

    private func timecode(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct SessionTimelineView: View {
    let document: SessionReadingDocument
    @ObservedObject var playback: SessionPlaybackController

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    playback.toggle()
                } label: {
                    Label(
                        playback.isPlaying
                            ? ScribeCopy.Reading.pause
                            : ScribeCopy.Reading.play,
                        systemImage: playback.isPlaying ? "pause.fill" : "play.fill"
                    )
                }
                .buttonStyle(.bordered)
                Text(timecode(playback.currentTime))
                    .font(.system(
                        size: 12,
                        weight: .regular,
                        design: .monospaced
                    ))
                Text("/")
                    .foregroundStyle(.secondary)
                Text(timecode(document.duration))
                    .font(.system(
                        size: 12,
                        weight: .regular,
                        design: .monospaced
                    ))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ScribeCopy.Reading.timeline)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            ForEach(document.timelineLanes) { lane in
                HStack(spacing: 10) {
                    Text(lane.displayName ?? ScribeCopy.Library.audio)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 72, alignment: .leading)
                        .foregroundStyle(
                            ScribePalette.speaker(
                                id: lane.id,
                                source: lane.source
                            )
                        )
                    timelineLane(lane)
                    Text(timecode(lane.talkTime))
                        .font(.system(
                            size: 10,
                            weight: .regular,
                            design: .monospaced
                        ))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                        .help(ScribeCopy.Reading.talkTime)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func timelineLane(
        _ lane: SessionTimelineLane
    ) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                ForEach(Array(lane.regions.enumerated()), id: \.offset) {
                    _, region in
                    let start = x(region.startTime, width: geometry.size.width)
                    let end = x(region.endTime, width: geometry.size.width)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ScribePalette.speaker(id: lane.id, source: lane.source))
                        .frame(width: max(1, end - start), height: 8)
                        .offset(x: start)
                }
                ForEach(document.manifest.pins) { pin in
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 1, height: 14)
                        .offset(x: x(
                            Double(pin.sampleOffset)
                                / CanonicalAudioFormat.sampleRate,
                            width: geometry.size.width
                        ))
                }
                Rectangle()
                    .fill(.primary)
                    .frame(width: 1, height: 16)
                    .offset(x: x(
                        playback.currentTime,
                        width: geometry.size.width
                    ))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        guard geometry.size.width > 0 else { return }
                        let fraction = min(
                            max(0, value.location.x / geometry.size.width),
                            1
                        )
                        playback.seek(to: fraction * document.duration)
                    }
            )
        }
        .frame(height: 16)
    }

    private func x(_ time: TimeInterval, width: Double) -> Double {
        guard document.duration > 0 else { return 0 }
        return min(max(0, time / document.duration), 1) * width
    }

    private func timecode(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        if seconds >= 3_600 {
            return String(
                format: "%d:%02d:%02d",
                seconds / 3_600,
                (seconds / 60) % 60,
                seconds % 60
            )
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
