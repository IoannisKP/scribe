@preconcurrency import AppKit
import AudioCapture
import ModelManager
import SpeechPipeline
import SwiftUI

struct ContentView: View {
    @ObservedObject var recorder: MeetingRecorderViewModel

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
        .dropDestination(for: URL.self) { urls, _ in
            guard recorder.canImportMedia, !urls.isEmpty else { return false }
            recorder.importMediaFiles(urls)
            return true
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            Task {
                await recorder.refreshPermissionStatus()
            }
        }
        .sheet(isPresented: $recorder.showsSystemTapDiagnostic) {
            SystemTapDiagnosticView(recorder: recorder)
                .interactiveDismissDisabled(
                    recorder.systemTapDiagnosticIsActive
                )
        }
    }
}

private struct SystemTapDiagnosticView: View {
    @ObservedObject var recorder: MeetingRecorderViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("System Tap Diagnostic")
                        .font(.title2.bold())
                    Text("The aggregate device is never started")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            statusContent

            GroupBox("Privacy observation") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "During the 90-second hold, play audible browser audio. Check the upper-right menu bar for a purple recording dot, then open Control Center and look for Scribe under the system-audio recording disclosure."
                    )
                    Text(
                        "A passing result requires no purple dot, no Scribe recording entry, and a callback count of zero."
                    )
                    .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            if let logURL = recorder.systemTapDiagnosticLogURL {
                Text("Log: \(logURL.path)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            HStack {
                Button("Reveal log") {
                    recorder.revealSystemTapDiagnosticLog()
                }

                Spacer()

                if recorder.systemTapDiagnosticIsActive {
                    Button("Stop and tear down") {
                        recorder.cancelSystemTapDiagnostic()
                    }
                    .keyboardShortcut(.cancelAction)
                } else {
                    Button("Close") {
                        recorder.showsSystemTapDiagnostic = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 650, maxWidth: 650, minHeight: 500)
    }

    @ViewBuilder
    private var statusContent: some View {
        switch recorder.systemTapDiagnosticState {
        case .idle:
            Text("Ready")
        case .preparing:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView()
                Text("Preparing the unstarted tap and registering the first IOProc…")
                    .font(.headline)
                Text("The first registration may take about 14 seconds.")
                    .foregroundStyle(.secondary)
            }
        case let .holding(secondsRemaining, callbackCount):
            VStack(alignment: .leading, spacing: 8) {
                Text("HELD — DO NOT CLOSE")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text("\(secondsRemaining) seconds remaining")
                    .font(.system(.title, design: .monospaced).bold())
                ProgressView(
                    value: Double(90 - secondsRemaining),
                    total: 90
                )
                Text("Unstarted IOProc callbacks: \(callbackCount)")
                    .font(.body.monospaced())
                    .foregroundStyle(
                        callbackCount == 0
                            ? Color.primary
                            : Color.red
                    )
            }
        case .registeringComparison:
            ProgressView("Registering the second IOProc for comparison…")
        case .cleaningUp:
            ProgressView("Destroying IOProcs, aggregate device, and process tap…")
        case let .completed(report):
            diagnosticReport(report)
        case let .timingSampleCompleted(sample):
            VStack(alignment: .leading, spacing: 8) {
                Label("Timing sample appended", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text(
                    "IOProc registration: \(milliseconds(ioProcTiming(in: sample.timings))) ms"
                )
                    .font(.body.monospaced())
                Text("Callbacks before teardown: \(sample.callbackCount)")
                    .font(.body.monospaced())
            }
        case .cancelled:
            Label(
                "Stopped cleanly; both IOProcs, the aggregate device, and the tap were removed.",
                systemImage: "checkmark.circle"
            )
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Diagnostic failed", systemImage: "xmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(message)
                    .textSelection(.enabled)
            }
        }
    }

    private func diagnosticReport(
        _ report: SystemTapPrivacyDiagnosticReport
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Diagnostic completed and cleaned up", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text(
                "First IOProc registration: \(milliseconds(ioProcTiming(in: report.preparationTimings))) ms"
            )
            Text(
                "Second IOProc registration: \(milliseconds(report.secondIOProcRegistrationTiming)) ms"
            )
            Text("Callbacks during hold: \(report.primaryCallbackCount)")
            Text(
                "Callbacks on second unstarted IOProc: \(report.secondIOProcCallbackCount)"
            )
            Text(
                "App RSS preparation delta: \(memoryDelta(from: report.resourcesBeforePreparation.app, to: report.resourcesAfterPreparation.app))"
            )
            Text(
                "coreaudiod RSS preparation delta: \(memoryDelta(from: report.resourcesBeforePreparation.coreaudiod, to: report.resourcesAfterPreparation.coreaudiod))"
            )
            Text(
                "App idle wakeups during hold: \(wakeupsDelta(from: report.resourcesAfterPreparation.app, to: report.resourcesAfterHold.app))"
            )
            Text(
                "coreaudiod idle wakeups during hold: \(wakeupsDelta(from: report.resourcesAfterPreparation.coreaudiod, to: report.resourcesAfterHold.coreaudiod))"
            )
            Text("Ring buffer allocated: no")
            Text("WAV writer created: no")
        }
        .font(.body.monospaced())
        .textSelection(.enabled)
    }

    private func ioProcTiming(
        in timings: [SystemAudioStartupStageTiming]
    ) -> SystemAudioStartupStageTiming? {
        timings.first { $0.stage == .ioProcRegistration }
    }

    private func milliseconds(
        _ timing: SystemAudioStartupStageTiming?
    ) -> String {
        guard let timing else { return "unavailable" }
        return String(
            format: "%.2f",
            Double(timing.durationNanoseconds) / 1_000_000
        )
    }

    private func memoryDelta(
        from before: SystemTapProcessMetrics?,
        to after: SystemTapProcessMetrics?
    ) -> String {
        guard
            let before,
            let after,
            before.processID == after.processID
        else {
            return "unavailable"
        }
        let delta = Int64(after.residentBytes) - Int64(before.residentBytes)
        return ByteCountFormatter.string(
            fromByteCount: delta,
            countStyle: .memory
        )
    }

    private func wakeupsDelta(
        from before: SystemTapProcessMetrics?,
        to after: SystemTapProcessMetrics?
    ) -> String {
        guard
            let before,
            let after,
            before.processID == after.processID,
            after.packageIdleWakeups >= before.packageIdleWakeups,
            after.interruptWakeups >= before.interruptWakeups
        else {
            return "unavailable"
        }
        let packageDelta = after.packageIdleWakeups
            - before.packageIdleWakeups
        let interruptDelta = after.interruptWakeups
            - before.interruptWakeups
        return "\(packageDelta) package-idle, \(interruptDelta) interrupt"
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
    @State private var showsDeleteModelConfirmation = false
    @State private var showsDeleteVADConfirmation = false
    @State private var unrecognizedDirectoryPendingRemoval:
        UnrecognizedModelDirectory?

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

                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                recorder.liveSpeechPipelineStatusText,
                                systemImage: liveSpeechSystemImage
                            )
                            .foregroundStyle(liveSpeechColor)

                            Label(
                                recorder.liveTranscriptionStatusText,
                                systemImage: liveTranscriptionSystemImage
                            )
                            .foregroundStyle(liveTranscriptionColor)
                        }
                        .font(.callout)

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
        GroupBox("Models and local transcription") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    Picker(
                        "Transcription model",
                        selection: $recorder.selectedTranscriptionModel
                    ) {
                        ForEach(recorder.modelOptions) { selection in
                            Text(selection.descriptor.displayName)
                                .tag(selection)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(
                        recorder.isBusy
                            || recorder.isDownloadingModel
                            || recorder.isDownloadingSileroVAD
                            || recorder.isRecording
                            || recorder.isTranscribing
                    )

                    Spacer()

                    modelLifecycleActions
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(recorder.selectedModelDescriptor.displayName)
                        .font(.headline)
                    Text(recorder.selectedModelDescriptor.detail)
                        .foregroundStyle(.secondary)
                    Text(
                        "\(recorder.modelProviderText) · \(recorder.modelLanguagesText)"
                    )
                    .font(.caption)
                    Text(recorder.modelPerformanceText)
                        .font(.caption)
                    Text(recorder.modelResourceText)
                        .font(.caption.monospacedDigit())
                    if let latencyNote = recorder
                        .selectedModelDescriptor.liveLatencyNote
                    {
                        Label(
                            latencyNote,
                            systemImage: "clock.badge.exclamationmark"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }

                HStack {
                    Label(
                        recorder.modelStatusText,
                        systemImage:
                            recorder.isSelectedModelAvailable
                            ? "checkmark.circle.fill"
                            : "arrow.down.circle"
                    )
                    .foregroundStyle(
                        recorder.isSelectedModelAvailable
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

                if let suggestedModelText = recorder.suggestedModelText {
                    Button(suggestedModelText) {
                        recorder.selectSuggestedModel()
                    }
                    .font(.callout)
                    .disabled(
                        recorder.isDownloadingModel
                            || recorder.isDownloadingSileroVAD
                            || recorder.isRecording
                            || recorder.isTranscribing
                    )
                }

                Label(
                    recorder.modelSafetyText,
                    systemImage: recorder.modelSafetyAllowsUse
                        ? "checkmark.shield.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(
                    recorder.modelSafetyAllowsUse ? .green : .orange
                )

                Text(recorder.totalModelDiskText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if !recorder.unrecognizedModelDirectories.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "Unrecognized model data",
                            systemImage: "externaldrive.badge.questionmark"
                        )
                        .font(.headline)
                        .foregroundStyle(.orange)

                        Text(
                            "These folders are not managed by the model catalogue. Review them before removing anything."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        ForEach(
                            recorder.unrecognizedModelDirectories
                        ) { directory in
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(directory.name)
                                        .font(.callout.monospaced())
                                    Text(
                                        "\(recorder.unrecognizedModelDirectorySizeText(directory)) · \(directory.diskUsage.regularFileCount) files"
                                    )
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("Move to Trash…", role: .destructive) {
                                    unrecognizedDirectoryPendingRemoval =
                                        directory
                                }
                                .disabled(
                                    recorder
                                        .removingUnrecognizedModelDirectoryName
                                        != nil
                                        || recorder.isDownloadingModel
                                        || recorder.isDownloadingSileroVAD
                                        || recorder.isRecording
                                        || recorder.isTranscribing
                                )
                            }
                            .padding(8)
                            .background(
                                .orange.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                        }
                    }
                }

                Divider()

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Live speech detection")
                            .font(.headline)
                        Text(recorder.sileroVADStatusText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if recorder.sileroVADAvailability == .notDownloaded {
                        Button("Install Silero VAD") {
                            recorder.downloadSileroVAD()
                        }
                        .disabled(
                            recorder.isDownloadingSileroVAD
                                || recorder.isDownloadingModel
                                || recorder.isRecording
                                || recorder.isTranscribing
                        )
                    } else {
                        Button("Move to Trash…", role: .destructive) {
                            showsDeleteVADConfirmation = true
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
                    let progress = recorder.sileroVADDownloadProgress
                {
                    ProgressView(value: progress.fractionCompleted)
                }

                Text(
                    "Installs are the only network steps. Recordings and transcripts are never uploaded; model verification and inference run on this Mac. Your transcription choice is saved as the default and is fixed for each recording once it starts."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()

                HStack {
                    Label(
                        recorder.transcriptionStatusText,
                        systemImage: recorder.isTranscribing
                            ? "waveform.badge.magnifyingglass"
                            : "text.alignleft"
                    )
                    .font(.callout)

                    Spacer()

                    Button("Transcribe Recording") {
                        recorder.transcribeLatestRecording()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !recorder.hasRecording
                            || !recorder.isSelectedModelAvailable
                            || recorder.isDownloadingModel
                            || recorder.isDownloadingSileroVAD
                            || recorder.isRecording
                            || recorder.isTranscribing
                    )
                }

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

                if let importStatus = recorder.mediaImportStatusText {
                    Label(importStatus, systemImage: "square.and.arrow.down")
                        .font(.callout)
                        .foregroundStyle(
                            recorder.isImportingMedia ? .orange : .secondary
                        )
                }

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
        .confirmationDialog(
            "Move \(recorder.selectedModelDescriptor.displayName) to Trash?",
            isPresented: $showsDeleteModelConfirmation
        ) {
            Button("Move to Trash", role: .destructive) {
                recorder.deleteSelectedModel()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The model folder moves to Trash and can be recovered there. Recordings and transcripts are not affected."
            )
        }
        .confirmationDialog(
            "Move Silero VAD to Trash?",
            isPresented: $showsDeleteVADConfirmation
        ) {
            Button("Move to Trash", role: .destructive) {
                recorder.deleteSileroVAD()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The model folder moves to Trash and can be recovered there. Live speech detection will be unavailable until it is restored or installed again."
            )
        }
        .confirmationDialog(
            "Move unrecognized model data to Trash?",
            isPresented: Binding(
                get: {
                    unrecognizedDirectoryPendingRemoval != nil
                },
                set: { isPresented in
                    if !isPresented {
                        unrecognizedDirectoryPendingRemoval = nil
                    }
                }
            )
        ) {
            if let directory = unrecognizedDirectoryPendingRemoval {
                Button(
                    "Move \(directory.name) to Trash",
                    role: .destructive
                ) {
                    recorder.removeUnrecognizedModelDirectory(directory)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let directory = unrecognizedDirectoryPendingRemoval {
                Text(
                    "This moves the \(recorder.unrecognizedModelDirectorySizeText(directory)) folder to Trash, where it can be recovered. Recordings and transcripts are not affected."
                )
            }
        }
    }

    @ViewBuilder
    private var modelLifecycleActions: some View {
        HStack(spacing: 8) {
            if recorder.modelDownloadCanPause {
                Button("Pause") {
                    recorder.pauseSelectedModelDownload()
                }
            } else if recorder.modelDownloadCanResume {
                Button("Resume") {
                    recorder.resumeSelectedModelDownload()
                }
                .buttonStyle(.borderedProminent)
            } else if recorder.selectedModelCanDelete {
                Button("Move to Trash…", role: .destructive) {
                    showsDeleteModelConfirmation = true
                }
                .disabled(
                    recorder.isDownloadingModel
                        || recorder.isDownloadingSileroVAD
                        || recorder.isRecording
                        || recorder.isTranscribing
                )
            } else {
                Button("Install") {
                    recorder.downloadSelectedModel()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    recorder.isDownloadingModel
                        || recorder.isDownloadingSileroVAD
                        || recorder.isRecording
                        || recorder.isTranscribing
                )
            }

            if recorder.modelDownloadCanCancel {
                Button("Cancel", role: .destructive) {
                    recorder.cancelSelectedModelDownload()
                }
            }
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

            if segment.source != .imported {
                Text(segment.source == .microphone ? "You" : "Others")
                    .font(.caption.bold())
                    .foregroundStyle(
                        segment.source == .microphone ? .blue : .purple
                    )
                    .frame(width: 50, alignment: .leading)
            }

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
