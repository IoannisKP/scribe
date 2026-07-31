@preconcurrency import AppKit
import AudioCapture
import Foundation
import SpeechPipeline
import SwiftUI

@MainActor
final class MeetingRecorderViewModel: ObservableObject {
    @Published private(set) var microphoneAuthorizationStatus:
        MicrophoneAuthorizationStatus = .notDetermined
    @Published private(set) var systemAudioAuthorizationStatus:
        SystemAudioAuthorizationStatus = .notDetermined
    @Published private(set) var captureState: DualTrackRecordingState = .idle
    @Published private(set) var microphoneCaptureState:
        MicrophoneCaptureState = .idle
    @Published private(set) var systemAudioCaptureState:
        SystemAudioCaptureState = .idle
    @Published private(set) var microphoneURL: URL?
    @Published private(set) var systemURL: URL?
    @Published private(set) var isBusy = false
    @Published private(set) var isCheckingPermissions = false
    @Published private(set) var modelAvailability:
        ParakeetModelAvailability = .notDownloaded
    @Published private(set) var isDownloadingModel = false
    @Published private(set) var downloadProgress:
        ParakeetDownloadProgress?
    @Published private(set) var transcriptionState:
        BatchTranscriptionState = .idle
    @Published private(set) var transcriptSegments: [TranscriptSegment] = []
    @Published private(set) var liveTransportState:
        LiveAudioTransportState = .idle
    @Published private(set) var sileroVADAvailability:
        SileroVADModelAvailability = .notDownloaded
    @Published private(set) var isDownloadingSileroVAD = false
    @Published private(set) var sileroVADDownloadProgress:
        SileroVADDownloadProgress?
    @Published private(set) var liveSpeechPipelineState:
        LiveSpeechPipelineState = .idle
    @Published private(set) var liveTranscriptionPipelineState:
        LiveTranscriptionPipelineState = .idle
    @Published private(set) var liveTranscriptRows:
        [LiveTranscriptRow] = []
    @Published var selectedParakeetModel: ParakeetModel = .v3Multilingual {
        didSet {
            transcriptSegments = []
            transcriptionState = .idle
            downloadProgress = nil
            Task {
                await refreshModelAvailability()
            }
        }
    }
    @Published var showsPermissionSetup: Bool
    @Published var errorMessage: String?

    private static let permissionSetupKey =
        "MeetingRecorderViewModel.permissionSetupCompleted"

    private let coordinator: DualTrackRecordingCoordinator
    private let microphoneCapture: MicrophoneCaptureService
    private let systemAudioCapture: SystemAudioCaptureService
    private let microphonePermissionAuthorizer:
        any MicrophonePermissionAuthorizing
    private let systemAudioPermissionAuthorizer:
        any SystemAudioPermissionAuthorizing
    private let modelStore: ParakeetModelStore?
    private let sileroVADModelStore: SileroVADModelStore?
    private let liveTransport: LiveAudioTransport?
    private var liveSpeechPipeline: LiveSpeechPipeline?
    private var liveTranscriptionPipeline:
        LiveTranscriptionPipeline?
    private var stateMonitorTask: Task<Void, Never>?
    private var handledAutomaticStopSessionDirectory: URL?

    init() {
        let microphonePermissionAuthorizer =
            SystemMicrophonePermissionAuthorizer()
        let systemAudioPermissionAuthorizer =
            SystemAudioPermissionAuthorizer()
        let liveTransport: LiveAudioTransport?
        var initializationErrors: [String] = []
        do {
            liveTransport = try LiveAudioTransport()
        } catch {
            liveTransport = nil
            initializationErrors.append(error.localizedDescription)
        }
        let microphoneCapture = MicrophoneCaptureService(
            permissionAuthorizer: microphonePermissionAuthorizer,
            liveSink: liveTransport
        )
        let systemAudioCapture = SystemAudioCaptureService(
            permissionRecorder: systemAudioPermissionAuthorizer,
            liveSink: liveTransport
        )

        self.microphonePermissionAuthorizer =
            microphonePermissionAuthorizer
        self.systemAudioPermissionAuthorizer =
            systemAudioPermissionAuthorizer
        self.microphoneCapture = microphoneCapture
        self.systemAudioCapture = systemAudioCapture
        self.liveTransport = liveTransport
        self.coordinator = DualTrackRecordingCoordinator(
            microphoneCapture: microphoneCapture,
            systemCapture: systemAudioCapture
        )
        do {
            self.modelStore = try ParakeetModelStore()
        } catch {
            self.modelStore = nil
            initializationErrors.append(error.localizedDescription)
        }
        do {
            self.sileroVADModelStore = try SileroVADModelStore()
        } catch {
            self.sileroVADModelStore = nil
            initializationErrors.append(error.localizedDescription)
        }
        self.showsPermissionSetup = !UserDefaults.standard.bool(
            forKey: Self.permissionSetupKey
        )
        self.errorMessage =
            initializationErrors.isEmpty
            ? nil
            : initializationErrors.joined(separator: " ")

        startStateMonitor()
        Task {
            await refreshPermissionStatus()
            await refreshModelAvailability()
            await refreshSileroVADAvailability()
        }
    }

    deinit {
        stateMonitorTask?.cancel()
    }

    var isRecording: Bool {
        if case .recording = captureState {
            return true
        }
        return false
    }

    var permissionsReady: Bool {
        microphoneAuthorizationStatus == .authorized
            && systemAudioAuthorizationStatus == .authorized
    }

    var hasRecording: Bool {
        microphoneURL != nil && systemURL != nil && !isRecording
    }

    var isTranscribing: Bool {
        transcriptionState.isActive
    }

    var transcriptionStatusText: String {
        LivePipelineStatusText.batchTranscription(
            transcriptionState,
            hasRecording: hasRecording,
            isRecording: isRecording,
            modelAvailable: modelAvailability == .available
        )
    }

    var modelStatusText: String {
        if isDownloadingModel {
            guard let downloadProgress else {
                return "Starting download"
            }
            switch downloadProgress.phase {
            case .listing:
                return "Finding model files"
            case let .downloading(completedFiles, totalFiles):
                return "Downloading \(completedFiles) of \(totalFiles) files"
            case let .compiling(modelName):
                return "Compiling \(modelName)"
            }
        }
        switch modelAvailability {
        case .available:
            return "Downloaded · inference stays offline"
        case .notDownloaded:
            return "Not downloaded"
        }
    }

    var liveTransportStatusText: String {
        LivePipelineStatusText.transport(liveTransportState)
    }

    var sileroVADStatusText: String {
        if isDownloadingSileroVAD {
            guard let sileroVADDownloadProgress else {
                return "Starting live VAD download"
            }
            switch sileroVADDownloadProgress.phase {
            case .listing:
                return "Finding Silero VAD files"
            case let .downloading(completedFiles, totalFiles):
                return "Downloading VAD \(completedFiles) of \(totalFiles) files"
            case let .compiling(modelName):
                return "Compiling \(modelName)"
            }
        }
        switch sileroVADAvailability {
        case .notDownloaded:
            return "Live VAD model not downloaded"
        case .available:
            return "Silero VAD downloaded · inference stays offline"
        }
    }

    var liveSpeechPipelineStatusText: String {
        LivePipelineStatusText.speech(liveSpeechPipelineState)
    }

    var liveTranscriptionStatusText: String {
        LivePipelineStatusText.transcription(
            liveTranscriptionPipelineState
        )
    }

    var statusText: String {
        if case let .recovering(reason, _) = microphoneCaptureState {
            return "Recovering microphone: \(reason)"
        }
        if case let .recovering(reason, _) = systemAudioCaptureState {
            return "Recovering system audio: \(reason)"
        }

        switch captureState {
        case .idle:
            return "Ready for two-track recording"
        case .starting:
            return "Starting microphone and system audio"
        case .recording:
            return "Recording microphone and system audio separately"
        case .stopping:
            return "Finishing both WAV files"
        case let .stopped(result):
            switch result.stopReason {
            case .lowDiskSpace:
                return "Both tracks saved before storage filled"
            case .diskSpaceMonitoringFailed:
                return "Both tracks saved after storage monitoring failed"
            case .requested:
                break
            }
            let dropped = result.microphone.droppedSampleCount
                + result.system.droppedSampleCount
            return dropped == 0
                ? "Both tracks saved"
                : "Both tracks saved with \(dropped) total dropped samples"
        case let .failed(message, _):
            return message
        }
    }

    var microphonePermissionText: String {
        switch microphoneAuthorizationStatus {
        case .notDetermined:
            "Not requested"
        case .authorized:
            "Allowed"
        case .denied:
            "Denied"
        case .restricted:
            "Restricted"
        }
    }

    var systemAudioPermissionText: String {
        switch systemAudioAuthorizationStatus {
        case .notDetermined:
            "Not checked"
        case .authorized:
            "Allowed (last checked)"
        case .denied:
            "Denied"
        }
    }

    var microphoneTrackText: String {
        switch microphoneCaptureState {
        case .idle:
            "Ready"
        case .requestingPermission:
            "Requesting access"
        case .starting:
            "Starting"
        case .recording:
            "Recording"
        case let .recovering(reason, _):
            "Recovering — \(reason)"
        case .stopping:
            "Finishing"
        case let .stopped(_, droppedSampleCount):
            droppedSampleCount == 0
                ? "Saved"
                : "Saved · \(droppedSampleCount) dropped samples"
        case let .failed(message):
            "Failed — \(message)"
        }
    }

    var systemAudioTrackText: String {
        switch systemAudioCaptureState {
        case .idle:
            "Ready"
        case .starting:
            "Starting"
        case .recording:
            "Recording"
        case let .recovering(reason, _):
            "Recovering — \(reason)"
        case .stopping:
            "Finishing"
        case let .stopped(_, droppedSampleCount):
            droppedSampleCount == 0
                ? "Saved"
                : "Saved · \(droppedSampleCount) dropped samples"
        case let .failed(message):
            "Failed — \(message)"
        }
    }

    func requestMicrophonePermission() {
        guard !isCheckingPermissions else {
            return
        }
        isCheckingPermissions = true
        errorMessage = nil
        Task {
            _ = await microphonePermissionAuthorizer.requestAuthorization()
            await refreshPermissionStatus()
            isCheckingPermissions = false
        }
    }

    func requestSystemAudioPermission() {
        guard !isCheckingPermissions else {
            return
        }
        isCheckingPermissions = true
        errorMessage = nil
        Task {
            do {
                systemAudioAuthorizationStatus =
                    try await systemAudioPermissionAuthorizer
                        .requestAuthorization()
            } catch {
                errorMessage = error.localizedDescription
            }
            isCheckingPermissions = false
        }
    }

    func finishPermissionSetup() {
        guard permissionsReady else {
            errorMessage =
                "Allow both permissions before continuing to recording."
            return
        }
        UserDefaults.standard.set(
            true,
            forKey: Self.permissionSetupKey
        )
        errorMessage = nil
        showsPermissionSetup = false
    }

    func showPermissionSetup() {
        errorMessage = nil
        showsPermissionSetup = true
        Task {
            await refreshPermissionStatus()
        }
    }

    func startRecording() {
        guard !isBusy, !isRecording else {
            return
        }
        guard permissionsReady else {
            showsPermissionSetup = true
            errorMessage =
                "Check microphone and system-audio access before recording."
            return
        }

        isBusy = true
        errorMessage = nil
        liveSpeechPipeline = nil
        liveSpeechPipelineState = .idle
        liveTranscriptionPipeline = nil
        liveTranscriptionPipelineState = .idle
        liveTranscriptRows = []
        handledAutomaticStopSessionDirectory = nil
        Task {
            do {
                let sessionDirectory = try makeSessionDirectory()
                guard let liveTransport else {
                    throw LiveAudioTransportError.operationFailed(
                        "Scribe could not initialize its bounded live-audio buffer."
                    )
                }
                try await liveTransport.beginSession(in: sessionDirectory)
                let paths = try await coordinator.startRecording(
                    in: sessionDirectory
                )
                microphoneURL = paths.microphoneURL
                systemURL = paths.systemURL
                await startLiveSpeechPipelineIfAvailable(
                    sessionDirectory: sessionDirectory,
                    transport: liveTransport
                )
            } catch {
                var message = error.localizedDescription
                if let transcriptionMessage =
                    await discardLiveTranscriptionPipeline(
                        finalState: .idle
                    )
                {
                    message += " \(transcriptionMessage)"
                }
                if let pipelineMessage =
                    await discardLiveSpeechPipeline(finalState: .idle)
                {
                    message += " \(pipelineMessage)"
                }
                if let cleanupMessage =
                    await discardLiveTransport(finalState: .idle)
                {
                    message += " \(cleanupMessage)"
                }
                errorMessage = message
            }
            await refreshPermissionStatus()
            captureState = await coordinator.state
            if microphoneAuthorizationStatus.requiresSystemSettings
                || systemAudioAuthorizationStatus.requiresSystemSettings
            {
                showsPermissionSetup = true
            }
            isBusy = false
        }
    }

    func stopRecording() {
        guard !isBusy, isRecording else {
            return
        }

        isBusy = true
        errorMessage = nil
        Task {
            do {
                let result = try await coordinator.stopRecording()
                microphoneURL = result.microphone.outputURL
                systemURL = result.system.outputURL
                transcriptSegments = []
                transcriptionState = .idle
            } catch {
                var message = error.localizedDescription
                if let liveProcessingMessage =
                    await finishAndDiscardLiveProcessing()
                {
                    message += " \(liveProcessingMessage)"
                }
                errorMessage = message
                captureState = await coordinator.state
                isBusy = false
                return
            }
            if let liveProcessingMessage =
                await finishAndDiscardLiveProcessing()
            {
                errorMessage = liveProcessingMessage
            }
            captureState = await coordinator.state
            isBusy = false
        }
    }

    func downloadSelectedModel() {
        guard
            !isDownloadingModel,
            !isDownloadingSileroVAD,
            !isTranscribing
        else {
            return
        }
        guard let modelStore else {
            errorMessage =
                "Scribe could not open its local model directory."
            return
        }

        isDownloadingModel = true
        downloadProgress = nil
        errorMessage = nil
        let model = selectedParakeetModel
        Task {
            do {
                _ = try await modelStore.download(model) {
                    [weak self] progress in
                    Task { @MainActor in
                        guard self?.selectedParakeetModel == model else {
                            return
                        }
                        self?.downloadProgress = progress
                    }
                }
                await refreshModelAvailability()
            } catch is CancellationError {
                errorMessage = "The model download was cancelled."
            } catch {
                errorMessage = error.localizedDescription
            }
            isDownloadingModel = false
        }
    }

    func downloadSileroVAD() {
        guard
            !isDownloadingSileroVAD,
            !isDownloadingModel,
            !isTranscribing,
            !isRecording
        else {
            return
        }
        guard let sileroVADModelStore else {
            errorMessage =
                "Scribe could not open its local Silero VAD directory."
            return
        }

        isDownloadingSileroVAD = true
        sileroVADDownloadProgress = nil
        errorMessage = nil
        Task {
            do {
                _ = try await sileroVADModelStore.download {
                    [weak self] progress in
                    Task { @MainActor in
                        self?.sileroVADDownloadProgress = progress
                    }
                }
                await refreshSileroVADAvailability()
            } catch is CancellationError {
                errorMessage = "The Silero VAD download was cancelled."
            } catch {
                errorMessage = error.localizedDescription
            }
            isDownloadingSileroVAD = false
        }
    }

    func transcribeLatestRecording() {
        guard
            hasRecording,
            !isDownloadingModel,
            !isDownloadingSileroVAD,
            !isTranscribing
        else {
            return
        }
        guard modelAvailability == .available else {
            errorMessage =
                "Download \(selectedParakeetModel.displayName) before transcribing."
            return
        }
        guard
            let modelStore,
            let sessionDirectory = recordingSessionDirectory()
        else {
            errorMessage =
                "Scribe could not locate the latest recording session."
            return
        }

        let model = selectedParakeetModel
        transcriptSegments = []
        transcriptionState = .preparing
        errorMessage = nil
        Task {
            do {
                let modelDirectory = await modelStore.directory(for: model)
                let engine = ParakeetTranscriptionEngine(
                    model: model,
                    modelDirectory: modelDirectory
                )
                let pipeline = try BatchTranscriptionPipeline(engine: engine)
                let monitor = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            let state = await pipeline.state
                            await MainActor.run {
                                self?.transcriptionState = state
                            }
                            try await Task.sleep(for: .milliseconds(200))
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        await MainActor.run {
                            self?.errorMessage = error.localizedDescription
                        }
                    }
                }

                do {
                    transcriptSegments = try await pipeline.transcribeSession(
                        at: sessionDirectory
                    )
                    transcriptionState = await pipeline.state
                    monitor.cancel()
                } catch {
                    monitor.cancel()
                    throw error
                }
            } catch is CancellationError {
                transcriptionState = .failed(message: "Cancelled")
                errorMessage = "Transcription was cancelled."
            } catch {
                transcriptionState = .failed(
                    message: error.localizedDescription
                )
                errorMessage = error.localizedDescription
            }
        }
    }

    func openMicrophoneSettings() {
        openSettings(
            url: MicrophoneAuthorizationStatus.systemSettingsURL,
            paneName: "Microphone"
        )
    }

    func openSystemAudioSettings() {
        openSettings(
            url: SystemAudioAuthorizationStatus.systemSettingsURL,
            paneName: "System Audio Recording Only"
        )
    }

    func revealOutputs() {
        let urls = [microphoneURL, systemURL].compactMap { $0 }
        guard !urls.isEmpty else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func refreshPermissionStatus() async {
        microphoneAuthorizationStatus =
            await microphonePermissionAuthorizer.authorizationStatus()
        systemAudioAuthorizationStatus =
            await systemAudioPermissionAuthorizer.authorizationStatus()
        if !permissionsReady {
            showsPermissionSetup = true
        }
    }

    func refreshModelAvailability() async {
        guard let modelStore else {
            modelAvailability = .notDownloaded
            return
        }
        modelAvailability = await modelStore.availability(
            of: selectedParakeetModel
        )
    }

    func refreshSileroVADAvailability() async {
        guard let sileroVADModelStore else {
            sileroVADAvailability = .notDownloaded
            return
        }
        sileroVADAvailability =
            await sileroVADModelStore.availability()
    }

    private func openSettings(url: URL?, paneName: String) {
        guard let url else {
            errorMessage =
                "Unable to construct the \(paneName) settings URL."
            return
        }
        guard NSWorkspace.shared.open(url) else {
            errorMessage =
                "System Settings could not open the \(paneName) privacy pane."
            return
        }
    }

    private func startStateMonitor() {
        stateMonitorTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    guard let self else {
                        return
                    }
                    let observedCaptureState = await coordinator.state
                    captureState = observedCaptureState
                    await handleAutomaticStopIfNeeded(
                        observedCaptureState
                    )
                    microphoneCaptureState = await microphoneCapture.state
                    systemAudioCaptureState = await systemAudioCapture.state
                    if let liveTransport {
                        liveTransportState = await liveTransport.state
                    }
                    if let liveSpeechPipeline {
                        liveSpeechPipelineState =
                            await liveSpeechPipeline.state
                    }
                    if let liveTranscriptionPipeline {
                        liveTranscriptionPipelineState =
                            await liveTranscriptionPipeline.state
                        let currentRows =
                            await liveTranscriptionPipeline.rows
                        if currentRows != liveTranscriptRows {
                            liveTranscriptRows = currentRows
                        }
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func handleAutomaticStopIfNeeded(
        _ observedState: DualTrackRecordingState
    ) async {
        guard case let .stopped(result) = observedState else {
            return
        }
        guard result.stopReason != .requested else {
            return
        }
        let sessionDirectory = result.paths.sessionDirectory
        guard handledAutomaticStopSessionDirectory != sessionDirectory else {
            return
        }

        handledAutomaticStopSessionDirectory = sessionDirectory
        isBusy = true
        microphoneURL = result.microphone.outputURL
        systemURL = result.system.outputURL
        transcriptSegments = []
        transcriptionState = .idle
        var messages: [String] = []
        switch result.stopReason {
        case let .lowDiskSpace(availableBytes, reserveBytes):
            let available = ByteCountFormatter.string(
                fromByteCount: availableBytes,
                countStyle: .file
            )
            let reserve = ByteCountFormatter.string(
                fromByteCount: reserveBytes,
                countStyle: .file
            )
            messages.append(
                "Recording stopped safely because free space reached the configured reserve (\(available) available; \(reserve) reserved)."
            )
        case let .diskSpaceMonitoringFailed(message):
            messages.append(
                "Recording stopped safely because free space could no longer be checked: \(message)"
            )
        case .requested:
            break
        }
        if let liveProcessingMessage = await finishAndDiscardLiveProcessing() {
            messages.append(liveProcessingMessage)
        }
        errorMessage = messages.isEmpty
            ? nil
            : messages.joined(separator: " ")
        isBusy = false
    }

    private func makeSessionDirectory() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("Scribe", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func recordingSessionDirectory() -> URL? {
        guard let microphoneURL, let systemURL else {
            return nil
        }
        let microphoneDirectory = microphoneURL.deletingLastPathComponent()
        let systemDirectory = systemURL.deletingLastPathComponent()
        guard microphoneDirectory == systemDirectory else {
            return nil
        }
        return microphoneDirectory
    }

    private func startLiveSpeechPipelineIfAvailable(
        sessionDirectory: URL,
        transport: LiveAudioTransport
    ) async {
        guard
            sileroVADAvailability == .available,
            let sileroVADModelStore
        else {
            liveSpeechPipeline = nil
            liveSpeechPipelineState = .modelUnavailable
            liveTranscriptionPipeline = nil
            liveTranscriptionPipelineState = .modelUnavailable(
                reason: .voiceActivityModel
            )
            return
        }

        do {
            let modelURL = await sileroVADModelStore.modelURL
            let manifest = try CaptureSessionManifest.load(
                from: sessionDirectory
            )
            let model = selectedParakeetModel
            let modelDirectory = await modelStore?.directory(for: model)
                ?? sessionDirectory
            let engine = ParakeetTranscriptionEngine(
                model: model,
                modelDirectory: modelDirectory
            )
            let pipeline = try LiveSpeechPipeline(
                audioTransport: transport,
                sileroModelURL: modelURL,
                transcriptionEngine: engine
            )
            try await pipeline.beginSession(
                in: sessionDirectory,
                manifest: manifest
            )
            liveSpeechPipeline = pipeline
            liveSpeechPipelineState = await pipeline.state

            guard
                modelAvailability == .available,
                modelStore != nil
            else {
                liveTranscriptionPipeline = nil
                liveTranscriptionPipelineState = .modelUnavailable(
                    reason: .transcriptionModel
                )
                return
            }

            do {
                let transcriptionPipeline =
                    try LiveTranscriptionPipeline(
                        speechPipeline: pipeline,
                        engine: engine
                    )
                try await transcriptionPipeline.beginSession()
                liveTranscriptionPipeline = transcriptionPipeline
                liveTranscriptionPipelineState =
                    await transcriptionPipeline.state
            } catch {
                liveTranscriptionPipeline = nil
                liveTranscriptionPipelineState = .failed(
                    message: error.localizedDescription
                )
                errorMessage =
                    "Recording and speech detection continue, but live transcription could not start: \(error.localizedDescription)"
            }
        } catch {
            liveSpeechPipeline = nil
            liveSpeechPipelineState = .failed(
                message: error.localizedDescription
            )
            liveTranscriptionPipeline = nil
            liveTranscriptionPipelineState = .failed(
                message: "Speech detection was unavailable."
            )
            errorMessage =
                "Recording continues, but live speech detection could not start: \(error.localizedDescription)"
        }
    }

    private func finishAndDiscardLiveProcessing() async -> String? {
        guard let liveTransport else {
            return "The live-audio transport was unavailable."
        }

        var failures: [String] = []
        let stateBeforeFinish = await liveTransport.state
        do {
            try await liveTransport.finishProducing()
        } catch {
            failures.append(error.localizedDescription)
        }

        if let liveSpeechPipeline {
            do {
                try await liveSpeechPipeline.waitUntilFinished()
            } catch {
                failures.append(error.localizedDescription)
            }

            if let liveTranscriptionPipeline {
                do {
                    try await liveTranscriptionPipeline
                        .waitUntilFinished()
                } catch {
                    failures.append(error.localizedDescription)
                }
                liveTranscriptRows =
                    await liveTranscriptionPipeline.rows
                let stateBeforeShutdown =
                    await liveTranscriptionPipeline.state
                let finalState:
                    LiveTranscriptionPipelineState
                if case let .failed(message) = stateBeforeShutdown {
                    finalState = .failed(message: message)
                } else {
                    finalState = .completed(
                        finalRowCount:
                            liveTranscriptRows.filter(\.isFinal).count
                    )
                }
                await liveTranscriptionPipeline.shutdown(
                    finalState: finalState
                )
                liveTranscriptionPipelineState =
                    await liveTranscriptionPipeline.state
                self.liveTranscriptionPipeline = nil
            } else if
                !liveTranscriptionPipelineState.isModelUnavailable
            {
                liveTranscriptionPipelineState = .idle
            }

            if let pipelineFailure =
                await discardLiveSpeechPipeline(
                    finalState: .completed(pendingWindowCount: 0)
                )
            {
                failures.append(pipelineFailure)
            }
        } else if liveSpeechPipelineState != .modelUnavailable {
            liveSpeechPipelineState = .idle
        }

        let finalState: LiveAudioTransportState
        if case let .failed(message) = stateBeforeFinish {
            finalState = .failed(message: message)
        } else {
            finalState = .drained
        }
        if let discardFailure =
            await discardLiveTransport(finalState: finalState)
        {
            failures.append(discardFailure)
        }
        return failures.isEmpty ? nil : failures.joined(separator: " ")
    }

    private func discardLiveTranscriptionPipeline(
        finalState: LiveTranscriptionPipelineState
    ) async -> String? {
        guard let liveTranscriptionPipeline else {
            return nil
        }
        await liveTranscriptionPipeline.shutdown(
            finalState: finalState
        )
        liveTranscriptRows = await liveTranscriptionPipeline.rows
        liveTranscriptionPipelineState =
            await liveTranscriptionPipeline.state
        self.liveTranscriptionPipeline = nil
        return nil
    }

    private func discardLiveSpeechPipeline(
        finalState: LiveSpeechPipelineState
    ) async -> String? {
        guard let liveSpeechPipeline else {
            return nil
        }
        do {
            try await liveSpeechPipeline.cancelAndDiscard(
                finalState: finalState
            )
            liveSpeechPipelineState = await liveSpeechPipeline.state
            self.liveSpeechPipeline = nil
            return nil
        } catch {
            liveSpeechPipelineState = await liveSpeechPipeline.state
            self.liveSpeechPipeline = nil
            return error.localizedDescription
        }
    }

    private func discardLiveTransport(
        finalState: LiveAudioTransportState
    ) async -> String? {
        guard let liveTransport else {
            return nil
        }
        do {
            try await liveTransport.discardSpool(finalState: finalState)
            liveTransportState = await liveTransport.state
            return nil
        } catch {
            liveTransportState = await liveTransport.state
            return error.localizedDescription
        }
    }

}
