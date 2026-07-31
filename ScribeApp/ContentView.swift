@preconcurrency import AppKit
import AudioCapture
import SpeechPipeline
import SwiftUI

struct ContentView: View {
    @StateObject private var recorder = MeetingRecorderViewModel()

    var body: some View {
        Group {
            if recorder.showsPermissionSetup {
                PermissionSetupView(recorder: recorder)
            } else {
                RecordingView(recorder: recorder)
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .padding(40)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            Task {
                await recorder.refreshPermissionStatus()
            }
        }
    }
}

private struct AppHeader: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Scribe")
                    .font(.largeTitle.bold())
                Text("Local-first meeting transcription")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PermissionSetupView: View {
    @ObservedObject var recorder: MeetingRecorderViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            AppHeader()

            VStack(alignment: .leading, spacing: 6) {
                Text("Set up recording")
                    .font(.title2.bold())
                Text(
                    "Scribe needs two separate permissions to keep your voice and everyone else on isolated local tracks."
                )
                .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 18) {
                microphonePermissionCard
                systemAudioPermissionCard
            }

            HStack {
                Label(
                    "Permission checks and recordings stay on this Mac.",
                    systemImage: "lock.fill"
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Continue to Recording") {
                    recorder.finishPermissionSetup()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !recorder.permissionsReady
                        || recorder.isCheckingPermissions
                )
            }

            if let errorMessage = recorder.errorMessage {
                ErrorMessageView(message: errorMessage)
            }

            Spacer()
        }
    }

    private var microphonePermissionCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                PermissionStatusHeader(
                    title: "Microphone",
                    subtitle: "Your voice",
                    systemImage: "mic.fill",
                    status: recorder.microphonePermissionText,
                    isAuthorized:
                        recorder.microphoneAuthorizationStatus == .authorized
                )

                Text(
                    "Allows Scribe to record the selected microphone into microphone.wav."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                switch recorder.microphoneAuthorizationStatus {
                case .notDetermined:
                    Button("Allow Microphone") {
                        recorder.requestMicrophonePermission()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(recorder.isCheckingPermissions)
                case .authorized:
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .denied, .restricted:
                    Button("Open Microphone Settings") {
                        recorder.openMicrophoneSettings()
                    }
                    .disabled(recorder.isCheckingPermissions)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .padding(8)
        }
    }

    private var systemAudioPermissionCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                PermissionStatusHeader(
                    title: "System Audio",
                    subtitle: "Other participants",
                    systemImage: "speaker.wave.2.fill",
                    status: recorder.systemAudioPermissionText,
                    isAuthorized:
                        recorder.systemAudioAuthorizationStatus == .authorized
                )

                Text(
                    "macOS checks this permission only when a Core Audio tap starts. This check briefly opens a tap, discards its audio, and saves nothing."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                HStack {
                    if recorder.systemAudioAuthorizationStatus.requiresSystemSettings {
                        Button("Open System Audio Settings") {
                            recorder.openSystemAudioSettings()
                        }
                        .disabled(recorder.isCheckingPermissions)
                    }

                    if recorder.systemAudioAuthorizationStatus == .notDetermined {
                        Button("Check System Audio Access") {
                            recorder.requestSystemAudioPermission()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(recorder.isCheckingPermissions)
                    } else {
                        Button("Check Again") {
                            recorder.requestSystemAudioPermission()
                        }
                        .disabled(recorder.isCheckingPermissions)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .padding(8)
        }
    }
}

private struct PermissionStatusHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let status: String
    let isAuthorized: Bool

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(
                status,
                systemImage: isAuthorized
                    ? "checkmark.circle.fill"
                    : "circle.dashed"
            )
            .font(.caption)
            .foregroundStyle(isAuthorized ? .green : .secondary)
        }
    }
}

private struct RecordingView: View {
    @ObservedObject var recorder: MeetingRecorderViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    AppHeader()
                    Spacer()
                    Button {
                        recorder.showPermissionSetup()
                    } label: {
                        Label(
                            "Permissions",
                            systemImage: "hand.raised.fill"
                        )
                    }
                    .disabled(
                        recorder.isRecording
                            || recorder.isDownloadingModel
                            || recorder.isDownloadingSileroVAD
                            || recorder.isTranscribing
                    )
                }

                GroupBox("Two-track capture") {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Label(
                                recorder.statusText,
                                systemImage: recorder.isRecording
                                    ? "record.circle.fill"
                                    : "waveform"
                            )
                            .foregroundStyle(
                                recorder.isRecording ? .red : .primary
                            )

                            Spacer()

                            Button {
                                if recorder.isRecording {
                                    recorder.stopRecording()
                                } else {
                                    recorder.startRecording()
                                }
                            } label: {
                                Label(
                                    recorder.isRecording
                                        ? "Stop recording"
                                        : "Record meeting",
                                    systemImage: recorder.isRecording
                                        ? "stop.fill"
                                        : "record.circle"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(
                                recorder.isRecording ? .red : .accentColor
                            )
                            .disabled(
                                recorder.isBusy
                                    || recorder.isDownloadingModel
                                    || recorder.isDownloadingSileroVAD
                                    || recorder.isTranscribing
                            )
                            .keyboardShortcut(
                                .space,
                                modifiers: [.command]
                            )
                        }

                        HStack(spacing: 14) {
                            TrackStatusView(
                                title: "You",
                                detail: recorder.microphoneTrackText,
                                systemImage: "mic.fill",
                                outputURL: recorder.microphoneURL,
                                isRecording: recorder.isRecording
                            )
                            TrackStatusView(
                                title: "Others",
                                detail: recorder.systemAudioTrackText,
                                systemImage: "speaker.wave.2.fill",
                                outputURL: recorder.systemURL,
                                isRecording: recorder.isRecording
                            )
                        }

                        Label(
                            recorder.liveTransportStatusText,
                            systemImage: liveTransportSystemImage
                        )
                        .font(.callout)
                        .foregroundStyle(liveTransportColor)

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(
                                    recorder.sileroVADStatusText,
                                    systemImage:
                                        recorder.sileroVADAvailability
                                            == .available
                                        ? "checkmark.circle.fill"
                                        : "arrow.down.circle"
                                )
                                .foregroundStyle(
                                    recorder.sileroVADAvailability
                                        == .available
                                        ? .green : .secondary
                                )

                                Label(
                                    recorder.liveSpeechPipelineStatusText,
                                    systemImage: liveSpeechSystemImage
                                )
                                .foregroundStyle(liveSpeechColor)

                                Label(
                                    recorder.liveTranscriptionStatusText,
                                    systemImage:
                                        liveTranscriptionSystemImage
                                )
                                .foregroundStyle(
                                    liveTranscriptionColor
                                )
                            }
                            .font(.callout)

                            Spacer()

                            if recorder.sileroVADAvailability
                                == .notDownloaded
                            {
                                Button("Download Live VAD") {
                                    recorder.downloadSileroVAD()
                                }
                                .disabled(
                                    recorder.isDownloadingSileroVAD
                                        || recorder.isDownloadingModel
                                        || recorder.isRecording
                                        || recorder.isTranscribing
                                )
                            }
                        }

                        if recorder.isDownloadingSileroVAD,
                            let progress =
                                recorder.sileroVADDownloadProgress
                        {
                            ProgressView(
                                value: progress.fractionCompleted
                            )
                        }

                        Text(
                            "Live VAD download requires the network once. Recording and Silero inference remain local and work offline afterward."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if recorder.microphoneURL != nil,
                            !recorder.isRecording
                        {
                            Button("Show WAVs in Finder") {
                                recorder.revealOutputs()
                            }
                        }

                        if let errorMessage = recorder.errorMessage {
                            ErrorMessageView(message: errorMessage)
                        }
                    }
                    .padding(8)
                }

                transcriptionBox

                Label(
                    "Two isolated \(Int(CanonicalAudioFormat.sampleRate / 1_000)) kHz mono Int16 WAVs · Float32 processing · stored locally",
                    systemImage: "internaldrive"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var liveTransportSystemImage: String {
        switch recorder.liveTransportState {
        case .bufferingToDisk:
            "externaldrive.badge.timemachine"
        case .catchingUp:
            "arrow.triangle.2.circlepath"
        case .failed:
            "exclamationmark.triangle.fill"
        case .idle, .ready, .keepingUp, .recordingComplete, .drained:
            "waveform.path"
        }
    }

    private var liveTransportColor: Color {
        switch recorder.liveTransportState {
        case .bufferingToDisk, .catchingUp:
            .orange
        case .failed:
            .red
        case .idle, .ready, .keepingUp, .recordingComplete, .drained:
            .secondary
        }
    }

    private var liveSpeechSystemImage: String {
        switch recorder.liveSpeechPipelineState {
        case .preparing:
            "hourglass"
        case .running:
            "waveform.badge.magnifyingglass"
        case .finishing:
            "ellipsis.circle"
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .idle, .modelUnavailable:
            "waveform"
        }
    }

    private var liveSpeechColor: Color {
        switch recorder.liveSpeechPipelineState {
        case .running, .finishing:
            .orange
        case .completed:
            .green
        case .failed:
            .red
        case .idle, .modelUnavailable, .preparing:
            .secondary
        }
    }

    private var liveTranscriptionSystemImage: String {
        switch recorder.liveTranscriptionPipelineState {
        case .preparing:
            "hourglass"
        case .running:
            "text.bubble"
        case .bufferingToDisk:
            "externaldrive.badge.timemachine"
        case .catchingUp:
            "arrow.triangle.2.circlepath"
        case .finishing:
            "ellipsis.circle"
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .idle, .modelUnavailable:
            "text.bubble"
        }
    }

    private var liveTranscriptionColor: Color {
        switch recorder.liveTranscriptionPipelineState {
        case .bufferingToDisk, .catchingUp:
            .orange
        case .completed:
            .green
        case .failed:
            .red
        case .idle, .modelUnavailable, .preparing, .running,
            .finishing:
            .secondary
        }
    }

    private var transcriptionBox: some View {
        GroupBox("Local transcription") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    Picker(
                        "Engine",
                        selection: $recorder.selectedParakeetModel
                    ) {
                        ForEach(ParakeetModel.allCases) { model in
                            VStack(alignment: .leading) {
                                Text(model.displayName)
                                Text(model.detail)
                            }
                            .tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(
                        recorder.isDownloadingModel
                            || recorder.isDownloadingSileroVAD
                            || recorder.isRecording
                            || recorder.isTranscribing
                    )

                    Spacer()

                    modelAction
                }

                HStack {
                    Label(
                        recorder.modelStatusText,
                        systemImage:
                            recorder.modelAvailability == .available
                            ? "checkmark.circle.fill"
                            : "arrow.down.circle"
                    )
                    .foregroundStyle(
                        recorder.modelAvailability == .available
                            ? .green : .secondary
                    )

                    if recorder.isDownloadingModel,
                        let progress = recorder.downloadProgress
                    {
                        ProgressView(value: progress.fractionCompleted)
                            .frame(maxWidth: 220)
                    }
                }
                .font(.callout)

                Text(
                    "Model downloads are the only network steps. Recordings and transcripts are never uploaded; after download, inference runs entirely on this Mac."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()

                Label(
                    recorder.liveTranscriptionStatusText,
                    systemImage:
                        recorder.liveTranscriptRows.contains {
                            !$0.isFinal
                        }
                        ? "text.bubble.fill"
                        : "text.bubble"
                )
                .font(.callout)

                Label(
                    recorder.transcriptionStatusText,
                    systemImage: recorder.isTranscribing
                        ? "waveform.badge.magnifyingglass"
                        : "text.alignleft"
                )
                .font(.callout)

                if
                    recorder.transcriptSegments.isEmpty,
                    recorder.liveTranscriptRows.isEmpty
                {
                    Text(
                        recorder.isRecording
                            ? "Speech appears here while recording. Partial rows are visibly replaced when final."
                            : recorder.hasRecording
                            ? "No transcript generated yet."
                            : "Record and stop a meeting to enable transcription."
                    )
                    .foregroundStyle(.secondary)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 60,
                        alignment: .center
                    )
                } else if !recorder.transcriptSegments.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(
                            Array(
                                recorder.transcriptSegments.enumerated()
                            ),
                            id: \.offset
                        ) { _, segment in
                            TranscriptSegmentRow(segment: segment)
                        }
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(recorder.liveTranscriptRows) { row in
                            TranscriptSegmentRow(
                                segment: row.segment,
                                isFinal: row.isFinal
                            )
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var modelAction: some View {
        switch recorder.modelAvailability {
        case .notDownloaded:
            Button("Download Model") {
                recorder.downloadSelectedModel()
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                recorder.isDownloadingModel
                    || recorder.isDownloadingSileroVAD
                    || recorder.isRecording
                    || recorder.isTranscribing
            )
        case .available:
            Button("Transcribe Recording") {
                recorder.transcribeLatestRecording()
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                !recorder.hasRecording
                    || recorder.isDownloadingModel
                    || recorder.isDownloadingSileroVAD
                    || recorder.isRecording
                    || recorder.isTranscribing
            )
        }
    }
}

private struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let isFinal: Bool?

    init(
        segment: TranscriptSegment,
        isFinal: Bool? = nil
    ) {
        self.segment = segment
        self.isFinal = isFinal
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(Self.timestamp(segment.startTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)

            Text(segment.source == .microphone ? "You" : "Others")
                .font(.caption.bold())
                .foregroundStyle(
                    segment.source == .microphone ? .blue : .purple
                )
                .frame(width: 50, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                if let isFinal {
                    Label(
                        isFinal ? "Final" : "Partial",
                        systemImage:
                            isFinal
                            ? "checkmark.circle.fill"
                            : "ellipsis.circle"
                    )
                    .font(.caption2)
                    .foregroundStyle(
                        isFinal ? .green : .orange
                    )
                }

                Text(segment.text)
                    .textSelection(.enabled)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
            }
        }
        .padding(10)
        .background(
            .quaternary.opacity(0.25),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private static func timestamp(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.rounded(.down)))
        return String(
            format: "%02d:%02d",
            seconds / 60,
            seconds % 60
        )
    }
}

private struct TrackStatusView: View {
    let title: String
    let detail: String
    let systemImage: String
    let outputURL: URL?
    let isRecording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            Text(detail)
                .font(.callout)
                .foregroundStyle(
                    detail.hasPrefix("Failed") ? .red : .secondary
                )

            if let outputURL {
                Text(outputURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else {
                Text(
                    isRecording
                        ? "Preparing output…"
                        : "No recording in this launch"
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 105, alignment: .topLeading)
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ErrorMessageView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .accessibilityLabel("Error: \(message)")
    }
}
