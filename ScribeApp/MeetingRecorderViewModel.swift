@preconcurrency import AppKit
import AudioCapture
import Darwin
import Foundation
import ModelManager
import SpeechPipeline
import SwiftUI
import UniformTypeIdentifiers

enum SelectedModelAvailability: Equatable {
    case checking
    case notDownloaded
    case available
    case invalid(message: String)
}

private enum ModelManagementUIError: Error, LocalizedError {
    case resourceSafety(ModelResourceSafetyBlocker)

    var errorDescription: String? {
        switch self {
        case let .resourceSafety(blocker):
            Self.description(for: blocker)
        }
    }

    private static func description(
        for blocker: ModelResourceSafetyBlocker
    ) -> String {
        switch blocker {
        case .diskRequirementsUnknown:
            "Scribe has no verified disk measurement for this model. Choose a model with measured requirements."
        case let .diskCapacityUnavailable(message):
            "Scribe could not confirm enough model storage: \(message)"
        case let .insufficientDisk(requiredBytes, availableBytes):
            "This model needs \(bytes(requiredBytes)) of free space including Scribe's safety reserve, but only \(bytes(availableBytes)) is available."
        case .memoryRequirementsUnknown:
            "Scribe has no verified peak-memory measurement for this model. Choose a model with measured requirements."
        case let .insufficientMemory(requiredBytes, budgetBytes, _):
            "This model needs up to \(bytes(requiredBytes)) of memory, above this Mac's safe \(bytes(budgetBytes)) model budget. Choose a smaller model."
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

enum MediaImportState: Equatable {
    case idle
    case copying(filename: String)
    case converting(filename: String)
    case transcribing(filename: String)
    case finished(filename: String, sessionDirectory: URL)
    case failed(filename: String, message: String)
}

enum SessionRetranscriptionState: Equatable {
    case idle
    case running(
        sessionID: UUID,
        modelName: String,
        estimate: String
    )
    case completed(sessionID: UUID, message: String)
    case failed(sessionID: UUID, message: String)

    func belongs(to sessionID: UUID) -> Bool {
        switch self {
        case .idle:
            false
        case let .running(id, _, _), let .completed(id, _),
            let .failed(id, _):
            id == sessionID
        }
    }
}

enum SystemTapDiagnosticUIState {
    case idle
    case preparing
    case holding(secondsRemaining: Int, callbackCount: UInt64)
    case registeringComparison
    case cleaningUp
    case completed(SystemTapPrivacyDiagnosticReport)
    case timingSampleCompleted(SystemTapTimingSample)
    case cancelled
    case failed(message: String)
}

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
    @Published private(set) var systemAudioPrewarmState:
        SystemAudioPrewarmState = .preparing
    @Published private(set) var microphoneURL: URL?
    @Published private(set) var systemURL: URL?
    @Published private(set) var isBusy = false
    @Published private(set) var isCheckingPermissions = false
    @Published private(set) var modelAvailability:
        SelectedModelAvailability = .checking
    @Published private(set) var isDownloadingModel = false
    @Published private(set) var downloadProgress:
        ModelDownloadProgress?
    @Published private(set) var modelDownloadState:
        ManagedModelDownloadState = .idle
    @Published private(set) var modelResourceSafety:
        ModelResourceSafetyEvaluation?
    @Published private(set) var modelDiskUsage: ModelDiskUsage?
    @Published private(set) var totalModelDiskUsageBytes: Int64 = 0
    @Published private(set) var unrecognizedModelDirectories:
        [UnrecognizedModelDirectory] = []
    @Published private(set) var removingUnrecognizedModelDirectoryName:
        String?
    @Published private(set) var suggestedAvailableModel:
        TranscriptionModelSelection?
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
    @Published private(set) var recordingTranscriptRows:
        [RecordingTranscriptPresentationRow] = []
    @Published private(set) var liveSpeechMetrics:
        LiveSpeechPipelineMetrics = .zero
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var activeNotesURL: URL?
    @Published private(set) var notesText = ""
    @Published private(set) var systemTrackHasBeenSilent = false
    @Published private(set) var indexedSessions: [IndexedSession] = []
    @Published private(set) var sessionLibraryItems:
        [SessionLibraryItem] = []
    @Published private(set) var sessionSearchGroups:
        [SessionSearchGroup] = []
    @Published private(set) var sessionSmartFolderCounts:
        SessionSmartFolderCounts = .zero
    @Published private(set) var manualSessionFolders:
        [ManualSessionFolder] = []
    @Published private(set) var recordingPinStatus:
        RecordingPinFeedback?
    @Published private(set) var mediaImportState: MediaImportState = .idle
    @Published private(set) var sessionRetranscriptionState:
        SessionRetranscriptionState = .idle
    @Published private(set) var sessionContentRevision: UInt64 = 0
    @Published private(set) var systemTapDiagnosticState:
        SystemTapDiagnosticUIState = .idle
    @Published private(set) var systemTapDiagnosticLogURL: URL?
    @Published var showsSystemTapDiagnostic = false
    @Published var selectedTranscriptionModel:
        TranscriptionModelSelection = MeetingRecorderViewModel
            .savedModelSelection()
    {
        didSet {
            UserDefaults.standard.set(
                selectedTranscriptionModel.id.rawValue,
                forKey: Self.defaultModelKey
            )
            transcriptSegments = []
            transcriptionState = .idle
            downloadProgress = nil
            modelDownloadState = .idle
            modelAvailability = .checking
            suggestedAvailableModel = nil
            Task {
                await refreshModelAvailability()
            }
        }
    }
    @Published var showsPermissionSetup: Bool
    @Published var errorMessage: String?

    private static let permissionSetupKey =
        "MeetingRecorderViewModel.permissionSetupCompleted"
    private static let defaultModelKey =
        "MeetingRecorderViewModel.defaultTranscriptionModel"

    private let coordinator: DualTrackRecordingCoordinator
    private let microphoneCapture: MicrophoneCaptureService
    private let systemAudioCapture: SystemAudioCaptureService
    private let microphonePermissionAuthorizer:
        any MicrophonePermissionAuthorizing
    private let systemAudioPermissionAuthorizer:
        any SystemAudioPermissionAuthorizing
    private let fluidAudioModelManager: FluidAudioModelManager?
    private let whisperKitModelManager: WhisperKitModelManager?
    private let residentEngineCoordinator =
        ResidentTranscriptionEngineCoordinator()
    private let sessionLocationStore: SessionLibraryLocationStore
    private let sessionFolderManager = SessionFolderManager()
    private let sessionManualFolderManager = SessionManualFolderManager()
    private let sessionLibraryPresentation = SessionLibraryPresentation()
    private let sessionLibraryOperations = SessionLibraryOperations()
    private let transcriptArtifactWriter = TranscriptArtifactWriter()
    private let sessionMediaImporter = SessionMediaImporter()
    private let legacySessionMigrator = LegacySessionMigrator()
    private let sessionLibraryMonitor = SessionLibraryMonitor()
    private let systemTapDiagnostic = SystemTapPrewarmDiagnostic()
    private let notesWriter = SessionNotesFileWriter()
    private let sessionIndex: SessionIndex?
    private let sessionReconciler: SessionReconciler?
    private let liveTransport: LiveAudioTransport?
    private var liveSpeechPipeline: LiveSpeechPipeline?
    private var liveTranscriptionPipeline:
        LiveTranscriptionPipeline?
    private var stateMonitorTask: Task<Void, Never>?
    private var modelDownloadStateMonitorTask: Task<Void, Never>?
    private var handledAutomaticStopSessionDirectory: URL?
    private var libraryAccessURL: URL?
    private var systemTapDiagnosticTask: Task<Void, Never>?
    private var notesRevision: UInt64 = 0
    private var lastSystemSpeechAt: Date?
    private let recordingPinWriter = RecordingPinWriter()
    private var recordingPinHotKey: GlobalHotKeyMonitor?
    private var pinConfirmationTask: Task<Void, Never>?
    private var pinWriteTasks: [UUID: Task<Void, Never>] = [:]
    private var pinHotKeyRegistrationFailedForSession = false
    private var isFinalizingRecording = false
    private var transcriptPresentationCache =
        RecordingTranscriptPresentationCache()

    init() {
        let microphonePermissionAuthorizer =
            SystemMicrophonePermissionAuthorizer()
        let systemAudioPermissionAuthorizer =
            SystemAudioPermissionAuthorizer()
        var initializationErrors: [String] = []
        let sessionLocationStore = SessionLibraryLocationStore()
        self.sessionLocationStore = sessionLocationStore
        let sessionIndex: SessionIndex?
        do {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            sessionIndex = try SessionIndex(
                databaseURL: applicationSupport
                    .appendingPathComponent("Scribe/Index", isDirectory: true)
                    .appendingPathComponent("sessions.sqlite")
            )
        } catch {
            sessionIndex = nil
            initializationErrors.append(
                "Scribe could not open its rebuildable session index: \(error.localizedDescription)"
            )
        }
        self.sessionIndex = sessionIndex
        self.sessionReconciler = sessionIndex.map {
            SessionReconciler(index: $0)
        }
        let liveTransport: LiveAudioTransport?
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
            self.fluidAudioModelManager = try FluidAudioModelManager()
        } catch {
            self.fluidAudioModelManager = nil
            initializationErrors.append(error.localizedDescription)
        }
        do {
            self.whisperKitModelManager = try WhisperKitModelManager()
        } catch {
            self.whisperKitModelManager = nil
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
            await systemAudioCapture.prewarm()
        }
        Task {
            await prepareSessionStorage()
            await refreshPermissionStatus()
            await refreshModelAvailability()
            await refreshTotalModelDiskUsage()
            await refreshSileroVADAvailability()
        }
    }

    deinit {
        recordingPinHotKey?.stop()
        pinConfirmationTask?.cancel()
        systemTapDiagnosticTask?.cancel()
        stateMonitorTask?.cancel()
        modelDownloadStateMonitorTask?.cancel()
        sessionLibraryMonitor.stop()
        if let libraryAccessURL {
            sessionLocationStore.endAccessing(libraryAccessURL)
        }
    }

    var isRecording: Bool {
        if case .recording = captureState {
            return true
        }
        return false
    }

    var isWaitingToStartRecording: Bool {
        isBusy
            && !isRecording
            && systemAudioPrewarmState == .preparing
    }

    var canAddRecordingPin: Bool {
        isRecording && !isFinalizingRecording
    }

    var showsRecordingWorkspace: Bool {
        switch captureState {
        case .starting, .recording, .stopping:
            true
        case .idle, .stopped, .failed:
            isWaitingToStartRecording
        }
    }

    var recordingLevels: RecordingLevelSnapshot {
        RecordingViewPresentation.levels(from: liveSpeechMetrics)
    }

    var expectedFirstTextDelay: Int {
        guard let geometry = selectedModelDescriptor.windowGeometry else {
            return 0
        }
        return RecordingViewPresentation.firstTextDelay(
            windowDuration: geometry.duration,
            overlap: geometry.overlap
        )
    }

    private var recordingNotices: RecordingStatusNotices {
        RecordingViewPresentation.notices(
            isPreparingSystemAudio: isWaitingToStartRecording,
            isRecording: isRecording,
            selectedModelDisplayName: selectedModelDescriptor.displayName,
            firstTextDelay: expectedFirstTextDelay,
            rowsAreEmpty: recordingTranscriptRows.isEmpty,
            systemTrackHasBeenSilent: systemTrackHasBeenSilent,
            speechState: liveSpeechPipelineState,
            transcriptionState: liveTranscriptionPipelineState,
            transportState: liveTransportState
        )
    }

    var sidebarRecordingNotice: RecordingStatusNotice? {
        recordingNotices.sidebar
    }

    var transcriptRailNotice: RecordingStatusNotice? {
        recordingNotices.transcriptRail
    }

    func elapsedRecordingTime(at date: Date = Date()) -> TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return max(0, date.timeIntervalSince(recordingStartedAt))
    }

    func updateNotes(_ text: String) {
        guard text != notesText else { return }
        notesText = text
        guard let activeNotesURL else { return }
        notesRevision &+= 1
        let revision = notesRevision
        Task {
            do {
                try await notesWriter.write(
                    text,
                    to: activeNotesURL,
                    revision: revision
                )
            } catch {
                errorMessage = ScribeCopy.Recording.notesSaveFailed
            }
        }
    }

    func addRecordingPin() {
        guard
            canAddRecordingPin,
            let sessionDirectory = recordingSessionDirectory()
        else {
            return
        }
        let hostTime = mach_absolute_time()
        let createdAt = Date()
        let pinID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { pinWriteTasks[pinID] = nil }
            let sampleOffset = await recordingPinSampleOffset(
                atHostTime: hostTime
            )
            guard let sampleOffset else {
                showRecordingPinStatus(
                    .failed(message: ScribeCopy.Recording.pinUnavailable),
                    duration: .seconds(4)
                )
                return
            }
            let pin = CaptureSessionManifest.Pin(
                id: pinID,
                sampleOffset: sampleOffset,
                createdAt: createdAt
            )
            do {
                try await recordingPinWriter.append(
                    pin,
                    to: sessionDirectory
                )
                showRecordingPinStatus(
                    .saved(sampleOffset: pin.sampleOffset),
                    duration: .seconds(2)
                )
            } catch {
                showRecordingPinStatus(
                    .failed(message: ScribeCopy.Recording.pinSaveFailed),
                    duration: .seconds(4)
                )
            }
        }
        pinWriteTasks[pinID] = task
    }

    var systemTapDiagnosticIsActive: Bool {
        switch systemTapDiagnosticState {
        case .preparing, .holding, .registeringComparison, .cleaningUp:
            true
        case .idle, .completed, .timingSampleCompleted, .cancelled, .failed:
            false
        }
    }

    var canRunSystemTapDiagnostic: Bool {
        !isBusy
            && !isRecording
            && !isTranscribing
            && !isImportingMedia
            && !isDownloadingModel
            && !isDownloadingSileroVAD
            && !systemTapDiagnosticIsActive
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

    var isImportingMedia: Bool {
        switch mediaImportState {
        case .copying, .converting, .transcribing:
            true
        case .idle, .finished, .failed:
            false
        }
    }

    var canImportMedia: Bool {
        !isBusy
            && !isRecording
            && !isTranscribing
            && !isImportingMedia
            && !isDownloadingModel
            && !isDownloadingSileroVAD
    }

    var mediaImportStatusText: String? {
        switch mediaImportState {
        case .idle:
            nil
        case let .copying(filename):
            "Copying \(filename)"
        case let .converting(filename):
            "Converting \(filename) to 16 kHz mono audio"
        case let .transcribing(filename):
            "Transcribing \(filename) with \(selectedModelDescriptor.displayName)"
        case let .finished(filename, _):
            "Imported and transcribed \(filename)"
        case let .failed(filename, _):
            "Import failed for \(filename)"
        }
    }

    var transcriptionStatusText: String {
        LivePipelineStatusText.batchTranscription(
            transcriptionState,
            hasRecording: hasRecording,
            isRecording: isRecording,
            modelAvailable: isSelectedModelAvailable
        )
    }

    var modelOptions: [TranscriptionModelSelection] {
        TranscriptionModelSelection.allCases
    }

    var selectedModelDescriptor: ModelDescriptor {
        selectedTranscriptionModel.descriptor
    }

    var isSelectedModelAvailable: Bool {
        if case .available = modelAvailability {
            return true
        }
        return false
    }

    var selectedModelCanDelete: Bool {
        switch modelAvailability {
        case .available, .invalid:
            true
        case .checking, .notDownloaded:
            false
        }
    }

    var modelStatusText: String {
        switch modelDownloadState {
        case .idle:
            break
        case let .downloading(progress):
            return "Downloading · \(Self.percent(progress.fractionCompleted))"
        case .pausing:
            return "Pausing download"
        case let .paused(progress):
            return "Download paused · \(Self.percent(progress.fractionCompleted))"
        case .verifying:
            return "Verifying checksums"
        case .installed:
            return "Installed · inference stays offline"
        case .cancelled:
            return "Download cancelled"
        case let .failed(message):
            return "Download failed · \(message)"
        }
        switch modelAvailability {
        case .available:
            return "Installed · inference stays offline"
        case .checking:
            return "Checking local model"
        case .notDownloaded:
            return "Not installed"
        case let .invalid(message):
            return "Local model is invalid · \(message)"
        }
    }

    var modelProviderText: String {
        switch selectedModelDescriptor.provider {
        case .fluidAudio: "FluidAudio"
        case .whisperKit: "WhisperKit"
        }
    }

    var modelLanguagesText: String {
        let languages = selectedModelDescriptor.supportedLanguages
        if languages == ["en"] {
            return "English only"
        }
        let greek = languages.contains("el") ? " · includes Greek" : ""
        return "\(languages.count) languages\(greek)"
    }

    var modelPerformanceText: String {
        var parts: [String] = []
        if let quantization = selectedModelDescriptor.quantization {
            switch quantization {
            case .uncompressedCoreML:
                parts.append("Uncompressed Core ML")
            case .int8:
                parts.append("8-bit")
            case .fourBitCompressed:
                parts.append("4-bit compressed")
            case .qloraCompressed:
                parts.append("QLoRA compressed")
            }
        }
        if let speed = selectedModelDescriptor.speedRating {
            switch speed {
            case .fastest: parts.append("Fastest")
            case .fast: parts.append("Fast")
            case .balanced: parts.append("Balanced")
            case .quality: parts.append("Quality focused")
            }
        }
        return parts.joined(separator: " · ")
    }

    var modelResourceText: String {
        guard let profile = selectedModelDescriptor.resourceProfile else {
            return "Disk and peak-memory measurements are not available"
        }
        let download = Self.bytes(profile.downloadBytes)
        let installed = Self.bytes(profile.installedBytes)
        let memory = Self.bytes(profile.peakMemoryBytes)
        return "\(download) download · \(installed) installed · up to \(memory) memory"
    }

    var totalModelDiskText: String {
        "All local model data uses \(Self.bytes(totalModelDiskUsageBytes))"
    }

    func unrecognizedModelDirectorySizeText(
        _ directory: UnrecognizedModelDirectory
    ) -> String {
        Self.bytes(directory.diskUsage.logicalBytes)
    }

    var modelSafetyText: String {
        guard selectedModelDescriptor.resourceProfile != nil else {
            return "Verified disk and peak-memory measurements are unavailable for this legacy model"
        }
        guard let modelResourceSafety else {
            return "Checking this Mac's storage and memory"
        }
        if !isSelectedModelAvailable,
            let blocker = modelResourceSafety.installationBlocker
        {
            return ModelManagementUIError.resourceSafety(blocker)
                .localizedDescription
        }
        if let blocker = modelResourceSafety.loadingBlocker {
            return ModelManagementUIError.resourceSafety(blocker)
                .localizedDescription
        }
        return "Fits this Mac's current storage and safe memory budget"
    }

    var modelSafetyAllowsUse: Bool {
        guard selectedModelDescriptor.resourceProfile != nil else {
            return false
        }
        guard let modelResourceSafety else { return false }
        if isSelectedModelAvailable {
            return modelResourceSafety.loadingBlocker == nil
        }
        return modelResourceSafety.installationBlocker == nil
            && modelResourceSafety.loadingBlocker == nil
    }

    var modelDownloadCanPause: Bool {
        if case .downloading = modelDownloadState { return true }
        return false
    }

    var modelDownloadCanResume: Bool {
        if case .paused = modelDownloadState { return true }
        return false
    }

    var modelDownloadCanCancel: Bool {
        switch modelDownloadState {
        case .downloading, .pausing, .paused, .verifying:
            true
        case .idle, .installed, .cancelled, .failed:
            false
        }
    }

    var suggestedModelText: String? {
        guard let suggestedAvailableModel else { return nil }
        return "Use installed \(suggestedAvailableModel.descriptor.displayName) instead"
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
        if systemAudioPrewarmState == .preparing, !isRecording {
            return "Preparing system audio before recording"
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

    func runSystemTapPrivacyDiagnostic() {
        guard canRunSystemTapDiagnostic else {
            return
        }
        showsSystemTapDiagnostic = true
        systemTapDiagnosticState = .preparing
        systemTapDiagnosticLogURL = nil
        isBusy = true
        errorMessage = nil

        systemTapDiagnosticTask = Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await systemTapDiagnostic
                    .runPrivacyDiagnostic { [weak self] progress in
                        await MainActor.run {
                            self?.applySystemTapDiagnosticProgress(progress)
                        }
                    }
                systemTapDiagnosticLogURL = try await systemTapDiagnostic
                    .logURL()
                systemTapDiagnosticState = .completed(report)
            } catch is CancellationError {
                systemTapDiagnosticState = .cancelled
            } catch {
                systemTapDiagnosticState = .failed(
                    message: error.localizedDescription
                )
            }
            systemTapDiagnosticTask = nil
            isBusy = false
        }
    }

    func runSystemTapTimingSample() {
        guard canRunSystemTapDiagnostic else {
            return
        }
        showsSystemTapDiagnostic = true
        systemTapDiagnosticState = .preparing
        systemTapDiagnosticLogURL = nil
        isBusy = true
        errorMessage = nil

        systemTapDiagnosticTask = Task { [weak self] in
            guard let self else { return }
            do {
                let sample = try await systemTapDiagnostic.runTimingSample()
                systemTapDiagnosticLogURL = try await systemTapDiagnostic
                    .logURL()
                systemTapDiagnosticState = .timingSampleCompleted(sample)
            } catch is CancellationError {
                systemTapDiagnosticState = .cancelled
            } catch {
                systemTapDiagnosticState = .failed(
                    message: error.localizedDescription
                )
            }
            systemTapDiagnosticTask = nil
            isBusy = false
        }
    }

    func cancelSystemTapDiagnostic() {
        guard systemTapDiagnosticIsActive else {
            return
        }
        systemTapDiagnosticState = .cleaningUp
        systemTapDiagnosticTask?.cancel()
    }

    func revealSystemTapDiagnosticLog() {
        Task {
            do {
                let url = try await systemTapDiagnostic.logURL()
                systemTapDiagnosticLogURL = url
                if FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.open(url.deletingLastPathComponent())
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applySystemTapDiagnosticProgress(
        _ progress: SystemTapDiagnosticProgress
    ) {
        switch progress {
        case .preparing:
            systemTapDiagnosticState = .preparing
        case let .holding(secondsRemaining, callbackCount):
            systemTapDiagnosticState = .holding(
                secondsRemaining: secondsRemaining,
                callbackCount: callbackCount
            )
        case .registeringComparison:
            systemTapDiagnosticState = .registeringComparison
        case .cleaningUp:
            systemTapDiagnosticState = .cleaningUp
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
        replaceLiveTranscriptRows(with: [])
        liveSpeechMetrics = .zero
        recordingStartedAt = nil
        activeNotesURL = nil
        notesText = ""
        systemTrackHasBeenSilent = false
        recordingPinStatus = nil
        pinConfirmationTask?.cancel()
        lastSystemSpeechAt = nil
        handledAutomaticStopSessionDirectory = nil
        isFinalizingRecording = false
        Task {
            do {
                let sessionDirectory = try makeSessionDirectory()
                let notesURL = sessionDirectory.appendingPathComponent(
                    "notes.md",
                    isDirectory: false
                )
                activeNotesURL = notesURL
                notesText = (try? String(
                    contentsOf: notesURL,
                    encoding: .utf8
                )) ?? ""
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
                recordingStartedAt = Date()
                lastSystemSpeechAt = recordingStartedAt
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
                recordingStartedAt = nil
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
        isFinalizingRecording = true
        recordingPinHotKey?.stop()
        recordingPinHotKey = nil
        errorMessage = nil
        Task {
            var messages: [String] = []
            await waitForPendingRecordingPins()
            if let activeNotesURL {
                notesRevision &+= 1
                do {
                    try await notesWriter.write(
                        notesText,
                        to: activeNotesURL,
                        revision: notesRevision
                    )
                } catch {
                    messages.append(ScribeCopy.Recording.notesSaveFailed)
                }
            }
            do {
                let result = try await coordinator.stopRecording()
                microphoneURL = result.microphone.outputURL
                systemURL = result.system.outputURL
                transcriptSegments = []
                transcriptionState = .idle
            } catch {
                messages.append(error.localizedDescription)
                if let liveProcessingMessage =
                    await finishAndDiscardLiveProcessing()
                {
                    messages.append(liveProcessingMessage)
                }
                errorMessage = messages.joined(separator: " ")
                captureState = await coordinator.state
                isFinalizingRecording = false
                isBusy = false
                return
            }
            if let liveProcessingMessage =
                await finishAndDiscardLiveProcessing()
            {
                messages.append(liveProcessingMessage)
            }
            errorMessage = messages.isEmpty
                ? nil
                : messages.joined(separator: " ")
            captureState = await coordinator.state
            recordingStartedAt = nil
            isFinalizingRecording = false
            isBusy = false
        }
    }

    func downloadSelectedModel() {
        guard
            !isDownloadingModel,
            !isDownloadingSileroVAD,
            !isTranscribing,
            !isImportingMedia,
            !isRecording
        else {
            return
        }
        beginSelectedModelOperation(resuming: false)
    }

    func pauseSelectedModelDownload() {
        guard modelDownloadCanPause else { return }
        let selection = selectedTranscriptionModel
        errorMessage = nil
        Task {
            do {
                try await pauseDownload(of: selection)
                await refreshDownloadState(for: selection)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func resumeSelectedModelDownload() {
        guard
            modelDownloadCanResume,
            !isDownloadingModel,
            !isDownloadingSileroVAD,
            !isTranscribing,
            !isImportingMedia,
            !isRecording
        else {
            return
        }
        beginSelectedModelOperation(resuming: true)
    }

    func cancelSelectedModelDownload() {
        guard modelDownloadCanCancel else { return }
        let selection = selectedTranscriptionModel
        errorMessage = nil
        Task {
            do {
                try await cancelDownload(of: selection)
                await refreshDownloadState(for: selection)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func deleteSelectedModel() {
        guard
            selectedModelCanDelete,
            !isDownloadingModel,
            !isDownloadingSileroVAD,
            !isTranscribing,
            !isImportingMedia,
            !isRecording
        else {
            return
        }
        let selection = selectedTranscriptionModel
        errorMessage = nil
        Task {
            do {
                try await removeModel(selection)
                await refreshModelAvailability()
                await refreshTotalModelDiskUsage()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func removeUnrecognizedModelDirectory(
        _ directory: UnrecognizedModelDirectory
    ) {
        guard
            removingUnrecognizedModelDirectoryName == nil,
            !isDownloadingModel,
            !isDownloadingSileroVAD,
            !isTranscribing,
            !isImportingMedia,
            !isRecording
        else {
            return
        }
        removingUnrecognizedModelDirectoryName = directory.name
        errorMessage = nil
        Task {
            do {
                try await removeUnrecognizedModelDirectory(
                    named: directory.name
                )
                await refreshTotalModelDiskUsage()
            } catch {
                errorMessage = error.localizedDescription
            }
            removingUnrecognizedModelDirectoryName = nil
        }
    }

    func selectSuggestedModel() {
        guard let suggestedAvailableModel else { return }
        selectedTranscriptionModel = suggestedAvailableModel
    }

    func downloadSileroVAD() {
        guard
            !isDownloadingSileroVAD,
            !isDownloadingModel,
            !isTranscribing,
            !isImportingMedia,
            !isRecording
        else {
            return
        }
        guard let modelManager = fluidAudioModelManager else {
            errorMessage =
                "Scribe could not open its local Silero VAD directory."
            return
        }

        isDownloadingSileroVAD = true
        sileroVADDownloadProgress = nil
        errorMessage = nil
        Task {
            do {
                _ = try await modelManager.downloadSileroVAD {
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

    func deleteSileroVAD() {
        guard
            sileroVADAvailability == .available,
            !isDownloadingSileroVAD,
            !isDownloadingModel,
            !isTranscribing,
            !isImportingMedia,
            !isRecording,
            let fluidAudioModelManager
        else {
            return
        }
        errorMessage = nil
        Task {
            do {
                try await fluidAudioModelManager.removeModel(
                    identifiedBy: ScribeModelIdentifiers.sileroVAD
                )
                await refreshSileroVADAvailability()
                await refreshTotalModelDiskUsage()
            } catch {
                errorMessage = error.localizedDescription
            }
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
                "Install \(selectedModelDescriptor.displayName) before transcribing."
            return
        }
        guard
            let sessionDirectory = recordingSessionDirectory()
        else {
            errorMessage =
                "Scribe could not locate the latest recording session."
            return
        }

        let selection = selectedTranscriptionModel
        transcriptSegments = []
        transcriptionState = .preparing
        errorMessage = nil
        Task {
            do {
                let completedSegments = try await performBatchTranscription(
                    sessionDirectory: sessionDirectory,
                    selection: selection
                )
                _ = try await transcriptArtifactWriter.write(
                    segments: completedSegments,
                    modelIdentifier: selection.id.rawValue,
                    to: sessionDirectory
                )
                transcriptSegments = completedSegments
                await reconcileSessionLibrary()
            } catch is CancellationError {
                transcriptionState = .failed(message: "Cancelled")
                errorMessage = "Transcription was cancelled."
            } catch {
                transcriptionState = .failed(
                    message: error.localizedDescription
                )
                await refreshSuggestedAvailableModel(for: selection)
                errorMessage = error.localizedDescription
            }
        }
    }

    func retranscribeSession(_ session: SessionLibraryItem) {
        guard
            session.isAvailable,
            !isDownloadingModel,
            !isDownloadingSileroVAD,
            !isTranscribing,
            !isImportingMedia,
            !isRecording
        else { return }
        guard modelAvailability == .available else {
            let message = ScribeCopy.Reading.installModelBeforeTranscribing(
                selectedModelDescriptor.displayName
            )
            sessionRetranscriptionState = .failed(
                sessionID: session.id,
                message: message
            )
            return
        }

        let selection = selectedTranscriptionModel
        let previousRevision = try? CaptureSessionManifest.load(
            from: session.directory
        ).transcriptionHistory.last
        transcriptionState = .preparing
        sessionRetranscriptionState = .running(
            sessionID: session.id,
            modelName: selection.descriptor.displayName,
            estimate: transcriptionEstimate(
                duration: session.duration,
                model: selection.descriptor
            )
        )
        errorMessage = nil
        Task {
            do {
                let segments = try await performBatchTranscription(
                    sessionDirectory: session.directory,
                    selection: selection
                )
                _ = try await transcriptArtifactWriter.write(
                    segments: segments,
                    modelIdentifier: selection.id.rawValue,
                    to: session.directory
                )
                let preservedPath = previousRevision?.artifacts.first(where: {
                    $0.hasSuffix("transcript.md")
                })
                sessionRetranscriptionState = .completed(
                    sessionID: session.id,
                    message: preservedPath.map {
                        ScribeCopy.Reading.transcriptionComplete(
                            preservedPath: $0
                        )
                    } ?? ScribeCopy.Reading.firstTranscriptionComplete
                )
                sessionContentRevision &+= 1
                await reconcileSessionLibrary()
            } catch {
                transcriptionState = .failed(
                    message: error.localizedDescription
                )
                sessionRetranscriptionState = .failed(
                    sessionID: session.id,
                    message: ScribeCopy.Reading.transcriptionFailed
                )
                errorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    func renameSpeaker(
        in session: SessionLibraryItem,
        speakerID: String,
        to displayName: String
    ) async -> Bool {
        do {
            _ = try await SpeakerIdentityStore().renameSpeaker(
                identifiedBy: speakerID,
                to: displayName,
                in: session.directory
            )
            sessionContentRevision &+= 1
            await reconcileSessionLibrary()
            return true
        } catch {
            errorMessage = ScribeCopy.Reading.speakerRenameFailed
            return false
        }
    }

    @discardableResult
    func saveNotes(
        _ text: String,
        in session: SessionLibraryItem
    ) async -> Bool {
        let url = session.directory.appendingPathComponent("notes.md")
        notesRevision &+= 1
        let revision = notesRevision
        do {
            try await notesWriter.write(text, to: url, revision: revision)
            await reconcileSessionLibrary()
            return true
        } catch {
            errorMessage = ScribeCopy.Reading.notesSaveFailed
            return false
        }
    }

    func summaryDidChange() async {
        sessionContentRevision &+= 1
        await reconcileSessionLibrary()
    }

    private func transcriptionEstimate(
        duration: TimeInterval,
        model: ModelDescriptor
    ) -> String {
        let factor: Double = switch model.speedRating {
        case .fastest: 0.08
        case .fast: 0.12
        case .balanced: 0.20
        case .quality: 0.35
        case nil: 0.25
        }
        let seconds = max(10, Int((duration * factor).rounded(.up)))
        if seconds < 60 { return "about \(seconds) seconds" }
        let minutes = max(1, Int((Double(seconds) / 60).rounded(.up)))
        return minutes == 1 ? "about 1 minute" : "about \(minutes) minutes"
    }

    func chooseMediaForImport() {
        guard canImportMedia else { return }
        let panel = NSOpenPanel()
        panel.title = "Import audio or video"
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importMediaFiles([url])
    }

    func importMediaFiles(_ urls: [URL]) {
        guard canImportMedia, let sourceURL = urls.first else { return }
        guard modelAvailability == .available else {
            errorMessage =
                "Install \(selectedModelDescriptor.displayName) before importing. No session was created."
            return
        }

        let selection = selectedTranscriptionModel
        let filename = sourceURL.lastPathComponent
        isBusy = true
        transcriptSegments = []
        replaceLiveTranscriptRows(with: [])
        transcriptionState = .idle
        errorMessage = nil
        mediaImportState = .copying(filename: filename)
        Task {
            var importedSession: ImportedSessionResult?
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
                isBusy = false
            }
            do {
                let library = try availableSessionLibrary()
                let result = try await sessionMediaImporter.importFile(
                    at: sourceURL,
                    into: library
                ) { [weak self] progress in
                    Task { @MainActor in
                        switch progress {
                        case let .copying(filename):
                            self?.mediaImportState = .copying(
                                filename: filename
                            )
                        case let .converting(filename):
                            self?.mediaImportState = .converting(
                                filename: filename
                            )
                        }
                    }
                }
                importedSession = result
                mediaImportState = .transcribing(filename: filename)
                transcriptionState = .preparing
                let completedSegments = try await performBatchTranscription(
                    sessionDirectory: result.directory,
                    selection: selection
                )
                do {
                    _ = try await transcriptArtifactWriter.write(
                        segments: completedSegments,
                        modelIdentifier: selection.id.rawValue,
                        to: result.directory
                    )
                } catch {
                    let message =
                        "Couldn't save transcript files for “\(filename)”. The imported original and audio.wav are unaffected."
                    mediaImportState = .failed(
                        filename: filename,
                        message: message
                    )
                    errorMessage = message
                    await reconcileSessionLibrary()
                    return
                }
                transcriptSegments = completedSegments
                mediaImportState = .finished(
                    filename: filename,
                    sessionDirectory: result.directory
                )
                await reconcileSessionLibrary()
            } catch is CancellationError {
                transcriptionState = .failed(message: "Cancelled")
                let message = importedSession == nil
                    ? "Import cancelled. The original file is untouched."
                    : "Transcription was cancelled. The imported original and audio.wav are unaffected."
                mediaImportState = .failed(
                    filename: filename,
                    message: message
                )
                errorMessage = message
                await reconcileSessionLibrary()
            } catch {
                let message: String
                if importedSession == nil {
                    message = error.localizedDescription
                } else {
                    transcriptionState = .failed(
                        message: error.localizedDescription
                    )
                    await refreshSuggestedAvailableModel(for: selection)
                    message =
                        "Couldn't transcribe “\(filename)”. The imported original and audio.wav are unaffected."
                }
                mediaImportState = .failed(
                    filename: filename,
                    message: message
                )
                errorMessage = message
                await reconcileSessionLibrary()
            }
        }
    }

    func createManualSessionFolder(named name: String) {
        Task {
            do {
                let library = try availableSessionLibrary()
                _ = try sessionManualFolderManager.createFolder(
                    named: name,
                    in: library
                )
                await reconcileSessionLibrary()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func searchSessionLibrary(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            sessionSearchGroups = []
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(150))
            guard let sessionIndex else { return }
            let matches = try await sessionIndex.search(trimmed)
            let presentation = sessionLibraryPresentation
            let groups = await Task.detached {
                let items = presentation.items(from: matches)
                return presentation.searchGroups(
                    query: trimmed,
                    sessions: items
                )
            }.value
            try Task.checkCancellation()
            sessionSearchGroups = groups
        } catch is CancellationError {
            return
        } catch {
            errorMessage = ScribeCopy.Library.searchFailed(
                error.localizedDescription
            )
        }
    }

    func renameSession(_ session: SessionLibraryItem, to title: String) {
        Task {
            do {
                _ = try await sessionLibraryOperations.rename(
                    session: session,
                    to: title
                )
                await reconcileSessionLibrary()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func moveSessionToTrash(_ session: SessionLibraryItem) {
        Task {
            do {
                _ = try sessionLibraryOperations.moveToTrash(session: session)
                await reconcileSessionLibrary()
            } catch {
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
        let selection = selectedTranscriptionModel
        do {
            let availability = try await managedAvailability(of: selection)
            guard selectedTranscriptionModel == selection else { return }
            switch availability {
            case .notInstalled:
                modelAvailability = .notDownloaded
                modelDiskUsage = nil
            case let .installed(_, diskUsage):
                modelAvailability = .available
                modelDiskUsage = diskUsage
            case let .invalid(_, message):
                modelAvailability = .invalid(message: message)
                modelDiskUsage = try? await diskUsage(of: selection)
            }
            modelResourceSafety = try await resourceSafety(of: selection)
            await refreshDownloadState(for: selection)
            if !availability.isInstalled {
                await refreshSuggestedAvailableModel(for: selection)
            } else {
                suggestedAvailableModel = nil
            }
        } catch {
            guard selectedTranscriptionModel == selection else { return }
            modelAvailability = .notDownloaded
            modelResourceSafety = nil
            modelDiskUsage = nil
            await refreshSuggestedAvailableModel(for: selection)
            errorMessage = error.localizedDescription
        }
    }

    func refreshSileroVADAvailability() async {
        guard let modelManager = fluidAudioModelManager else {
            sileroVADAvailability = .notDownloaded
            return
        }
        sileroVADAvailability =
            await modelManager.sileroAvailability()
    }

    private func beginSelectedModelOperation(resuming: Bool) {
        let selection = selectedTranscriptionModel
        isDownloadingModel = true
        downloadProgress = nil
        errorMessage = nil
        startDownloadStateMonitor(for: selection)
        Task {
            do {
                let safety = try await resourceSafety(of: selection)
                guard selection.descriptor.resourceProfile == nil
                    || safety.installationBlocker == nil
                else {
                    throw ModelManagementUIError.resourceSafety(
                        safety.installationBlocker ?? .diskRequirementsUnknown
                    )
                }
                if resuming {
                    _ = try await resumeDownload(of: selection)
                } else {
                    _ = try await download(selection)
                }
            } catch {
                let state = await downloadState(of: selection)
                switch state {
                case .paused, .cancelled:
                    break
                default:
                    errorMessage = error.localizedDescription
                }
            }
            modelDownloadStateMonitorTask?.cancel()
            isDownloadingModel = false
            await refreshModelAvailability()
            await refreshTotalModelDiskUsage()
        }
    }

    private func startDownloadStateMonitor(
        for selection: TranscriptionModelSelection
    ) {
        modelDownloadStateMonitorTask?.cancel()
        modelDownloadStateMonitorTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    guard let self else { return }
                    await refreshDownloadState(for: selection)
                    try await Task.sleep(for: .milliseconds(150))
                }
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshDownloadState(
        for selection: TranscriptionModelSelection
    ) async {
        let state = await downloadState(of: selection)
        guard selectedTranscriptionModel == selection else { return }
        modelDownloadState = state
        switch state {
        case let .downloading(progress), let .paused(progress):
            downloadProgress = progress
        case .idle, .pausing, .verifying, .installed, .cancelled,
            .failed:
            break
        }
    }

    private func managedAvailability(
        of selection: TranscriptionModelSelection
    ) async throws -> ManagedModelAvailability {
        switch selection {
        case let .parakeet(model):
            guard let fluidAudioModelManager else {
                throw LiveAudioTransportError.operationFailed(
                    "Scribe could not open FluidAudio's local model directory."
                )
            }
            return try await fluidAudioModelManager.managedAvailability(
                of: model.modelIdentifier
            )
        case let .whisper(model):
            guard let whisperKitModelManager else {
                throw LiveAudioTransportError.operationFailed(
                    "Scribe could not open WhisperKit's local model directory."
                )
            }
            return try await whisperKitModelManager.availability(of: model)
        }
    }

    private func refreshTotalModelDiskUsage() async {
        var total: Int64 = 0
        for selection in TranscriptionModelSelection.allCases {
            guard let usage = try? await diskUsage(of: selection) else {
                continue
            }
            let (sum, overflow) = total.addingReportingOverflow(
                usage.logicalBytes
            )
            total = overflow ? .max : sum
        }
        if let fluidAudioModelManager,
            let usage = try? await fluidAudioModelManager.diskUsage(
                of: ScribeModelIdentifiers.sileroVAD
            )
        {
            let (sum, overflow) = total.addingReportingOverflow(
                usage.logicalBytes
            )
            total = overflow ? .max : sum
        }
        do {
            let unrecognized = try await loadUnrecognizedModelDirectories()
            unrecognizedModelDirectories = unrecognized
            for directory in unrecognized {
                let (sum, overflow) = total.addingReportingOverflow(
                    directory.diskUsage.logicalBytes
                )
                total = overflow ? .max : sum
            }
        } catch {
            unrecognizedModelDirectories = []
            errorMessage =
                "Scribe could not scan unrecognized model data: \(error.localizedDescription)"
        }
        totalModelDiskUsageBytes = total
    }

    private func loadUnrecognizedModelDirectories()
        async throws -> [UnrecognizedModelDirectory]
    {
        if let fluidAudioModelManager {
            return try await fluidAudioModelManager
                .unrecognizedModelDirectories()
        }
        if let whisperKitModelManager {
            return try await whisperKitModelManager
                .unrecognizedModelDirectories()
        }
        throw LiveAudioTransportError.operationFailed(
            "Local model storage is unavailable."
        )
    }

    private func removeUnrecognizedModelDirectory(named name: String)
        async throws
    {
        if let fluidAudioModelManager {
            try await fluidAudioModelManager
                .removeUnrecognizedModelDirectory(named: name)
            return
        }
        if let whisperKitModelManager {
            try await whisperKitModelManager
                .removeUnrecognizedModelDirectory(named: name)
            return
        }
        throw LiveAudioTransportError.operationFailed(
            "Local model storage is unavailable."
        )
    }

    private func refreshSuggestedAvailableModel(
        for selection: TranscriptionModelSelection
    ) async {
        for candidate in selection.smallerFallbackCandidates {
            guard let availability = try? await managedAvailability(
                of: candidate
            ), availability.isInstalled else {
                continue
            }
            guard selectedTranscriptionModel == selection else { return }
            suggestedAvailableModel = candidate
            return
        }
        guard selectedTranscriptionModel == selection else { return }
        suggestedAvailableModel = nil
    }

    private func downloadState(
        of selection: TranscriptionModelSelection
    ) async -> ManagedModelDownloadState {
        switch selection {
        case let .parakeet(model):
            guard let fluidAudioModelManager else { return .idle }
            return await fluidAudioModelManager.downloadState(
                of: model.modelIdentifier
            )
        case let .whisper(model):
            guard let whisperKitModelManager else { return .idle }
            return await whisperKitModelManager.downloadState(of: model)
        }
    }

    private func diskUsage(
        of selection: TranscriptionModelSelection
    ) async throws -> ModelDiskUsage {
        switch selection {
        case let .parakeet(model):
            guard let fluidAudioModelManager else {
                throw LiveAudioTransportError.operationFailed(
                    "FluidAudio model storage is unavailable."
                )
            }
            return try await fluidAudioModelManager.diskUsage(
                of: model.modelIdentifier
            )
        case let .whisper(model):
            guard let whisperKitModelManager else {
                throw LiveAudioTransportError.operationFailed(
                    "WhisperKit model storage is unavailable."
                )
            }
            return try await whisperKitModelManager.diskUsage(of: model)
        }
    }

    private func resourceSafety(
        of selection: TranscriptionModelSelection
    ) async throws -> ModelResourceSafetyEvaluation {
        switch selection {
        case let .parakeet(model):
            guard let fluidAudioModelManager else {
                throw LiveAudioTransportError.operationFailed(
                    "FluidAudio model storage is unavailable."
                )
            }
            return try await fluidAudioModelManager.resourceSafety(
                of: model.modelIdentifier
            )
        case let .whisper(model):
            guard let whisperKitModelManager else {
                throw LiveAudioTransportError.operationFailed(
                    "WhisperKit model storage is unavailable."
                )
            }
            return try await whisperKitModelManager.resourceSafety(of: model)
        }
    }

    @discardableResult
    private func download(
        _ selection: TranscriptionModelSelection
    ) async throws -> URL {
        switch selection {
        case let .parakeet(model):
            guard let fluidAudioModelManager else {
                throw LiveAudioTransportError.operationFailed(
                    "FluidAudio model storage is unavailable."
                )
            }
            return try await fluidAudioModelManager.download(model)
        case let .whisper(model):
            guard let whisperKitModelManager else {
                throw LiveAudioTransportError.operationFailed(
                    "WhisperKit model storage is unavailable."
                )
            }
            return try await whisperKitModelManager.download(model)
        }
    }

    private func pauseDownload(
        of selection: TranscriptionModelSelection
    ) async throws {
        switch selection {
        case let .parakeet(model):
            guard let fluidAudioModelManager else {
                throw LiveAudioTransportError.operationFailed(
                    "FluidAudio model storage is unavailable."
                )
            }
            try await fluidAudioModelManager.pauseDownload(
                of: model.modelIdentifier
            )
        case let .whisper(model):
            guard let whisperKitModelManager else {
                throw LiveAudioTransportError.operationFailed(
                    "WhisperKit model storage is unavailable."
                )
            }
            try await whisperKitModelManager.pauseDownload(of: model)
        }
    }

    @discardableResult
    private func resumeDownload(
        of selection: TranscriptionModelSelection
    ) async throws -> URL {
        switch selection {
        case let .parakeet(model):
            guard let fluidAudioModelManager else {
                throw LiveAudioTransportError.operationFailed(
                    "FluidAudio model storage is unavailable."
                )
            }
            return try await fluidAudioModelManager.resumeDownload(
                of: model.modelIdentifier
            )
        case let .whisper(model):
            guard let whisperKitModelManager else {
                throw LiveAudioTransportError.operationFailed(
                    "WhisperKit model storage is unavailable."
                )
            }
            return try await whisperKitModelManager.resumeDownload(of: model)
        }
    }

    private func cancelDownload(
        of selection: TranscriptionModelSelection
    ) async throws {
        switch selection {
        case let .parakeet(model):
            guard let fluidAudioModelManager else {
                throw LiveAudioTransportError.operationFailed(
                    "FluidAudio model storage is unavailable."
                )
            }
            try await fluidAudioModelManager.cancelDownload(
                of: model.modelIdentifier
            )
        case let .whisper(model):
            guard let whisperKitModelManager else {
                throw LiveAudioTransportError.operationFailed(
                    "WhisperKit model storage is unavailable."
                )
            }
            try await whisperKitModelManager.cancelDownload(of: model)
        }
    }

    private func removeModel(
        _ selection: TranscriptionModelSelection
    ) async throws {
        switch selection {
        case let .parakeet(model):
            guard let fluidAudioModelManager else {
                throw LiveAudioTransportError.operationFailed(
                    "FluidAudio model storage is unavailable."
                )
            }
            try await fluidAudioModelManager.removeModel(
                identifiedBy: model.modelIdentifier
            )
        case let .whisper(model):
            guard let whisperKitModelManager else {
                throw LiveAudioTransportError.operationFailed(
                    "WhisperKit model storage is unavailable."
                )
            }
            try await whisperKitModelManager.removeModel(model)
        }
    }

    private func makeTranscriptionEngine(
        for selection: TranscriptionModelSelection,
        enforcingMemorySafety: Bool = true
    ) async throws -> any TranscriptionEngine {
        if enforcingMemorySafety {
            try await validateLoadingSafety(for: selection)
        }

        let engine: any TranscriptionEngine
        switch selection {
        case let .parakeet(model):
            guard let fluidAudioModelManager else {
                throw LiveAudioTransportError.operationFailed(
                    "FluidAudio model storage is unavailable."
                )
            }
            let directory = await fluidAudioModelManager.directory(for: model)
            engine = ParakeetTranscriptionEngine(
                model: model,
                modelDirectory: directory
            )
        case let .whisper(model):
            guard let whisperKitModelManager else {
                throw LiveAudioTransportError.operationFailed(
                    "WhisperKit model storage is unavailable."
                )
            }
            engine = try WhisperKitTranscriptionEngine(
                model: model,
                modelManager: whisperKitModelManager
            )
        }
        return CoordinatedTranscriptionEngine(
            engine: engine,
            coordinator: residentEngineCoordinator
        )
    }

    private func validateLoadingSafety(
        for selection: TranscriptionModelSelection
    ) async throws {
        guard selection.descriptor.resourceProfile != nil else { return }
        let safety = try await resourceSafety(of: selection)
        if let blocker = safety.loadingBlocker {
            throw ModelManagementUIError.resourceSafety(blocker)
        }
    }

    private static func savedModelSelection()
        -> TranscriptionModelSelection
    {
        guard
            let rawValue = UserDefaults.standard.string(
                forKey: defaultModelKey
            )
        else {
            return .parakeet(.v3Multilingual)
        }
        return TranscriptionModelSelection(
            identifier: ModelIdentifier(rawValue: rawValue)
        ) ?? .parakeet(.v3Multilingual)
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
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
                    updateRecordingPinHotKeyRegistration()
                    await handleAutomaticStopIfNeeded(
                        observedCaptureState
                    )
                    microphoneCaptureState = await microphoneCapture.state
                    systemAudioCaptureState = await systemAudioCapture.state
                    systemAudioPrewarmState =
                        await systemAudioCapture.prewarmState
                    if let liveTransport {
                        liveTransportState = await liveTransport.state
                    }
                    if let liveSpeechPipeline {
                        liveSpeechPipelineState =
                            await liveSpeechPipeline.state
                        liveSpeechMetrics = await liveSpeechPipeline.metrics
                        updateSystemSilenceState()
                    } else {
                        liveSpeechMetrics = .zero
                        systemTrackHasBeenSilent = false
                    }
                    if let liveTranscriptionPipeline {
                        liveTranscriptionPipelineState =
                            await liveTranscriptionPipeline.state
                        let currentRows =
                            await liveTranscriptionPipeline.rows
                        if currentRows != liveTranscriptRows {
                            replaceLiveTranscriptRows(with: currentRows)
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
        isFinalizingRecording = true
        await waitForPendingRecordingPins()
        var messages: [String] = []
        if let activeNotesURL {
            notesRevision &+= 1
            do {
                try await notesWriter.write(
                    notesText,
                    to: activeNotesURL,
                    revision: notesRevision
                )
            } catch {
                messages.append(ScribeCopy.Recording.notesSaveFailed)
            }
        }
        microphoneURL = result.microphone.outputURL
        systemURL = result.system.outputURL
        transcriptSegments = []
        transcriptionState = .idle
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
        recordingStartedAt = nil
        isFinalizingRecording = false
        isBusy = false
    }

    private func makeSessionDirectory() throws -> URL {
        let library = try availableSessionLibrary()
        return try sessionFolderManager.createLiveSession(
            in: library
        ).directory
    }

    private func availableSessionLibrary() throws -> URL {
        guard case let .available(library) = sessionLocationStore.resolve()
        else {
            throw CocoaError(
                .fileNoSuchFile,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The selected session folder is unavailable. Reconnect its volume or choose another folder."
                ]
            )
        }
        if libraryAccessURL == nil {
            guard sessionLocationStore.beginAccessing(library) else {
                throw CocoaError(
                    .fileReadNoPermission,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Scribe no longer has access to the selected session folder. Choose it again in Settings. Your recordings and transcripts are untouched."
                    ]
                )
            }
            libraryAccessURL = library
        }
        return library
    }

    private func performBatchTranscription(
        sessionDirectory: URL,
        selection: TranscriptionModelSelection
    ) async throws -> [TranscriptSegment] {
        let engine = try await makeTranscriptionEngine(for: selection)
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
        defer { monitor.cancel() }
        let completedSegments = try await pipeline.transcribeSession(
            at: sessionDirectory
        )
        transcriptionState = await pipeline.state
        return completedSegments
    }

    private func prepareSessionStorage() async {
        let availability = sessionLocationStore.resolve()
        guard case let .available(library) = availability else {
            await reconcileSessionLibrary()
            return
        }
        if libraryAccessURL == nil,
            sessionLocationStore.beginAccessing(library)
        {
            libraryAccessURL = library
        }

        if let applicationSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            let legacyRoot = applicationSupport
                .appendingPathComponent("Scribe/Sessions", isDirectory: true)
            let report = legacySessionMigrator.migrate(
                from: legacyRoot,
                to: library
            )
            if !report.failures.isEmpty {
                errorMessage =
                    "Some earlier sessions could not be moved: "
                    + report.failures.joined(separator: " ")
            }
        }
        await reconcileSessionLibrary()
        do {
            try sessionLibraryMonitor.start(root: library) {
                [weak self] _ in
                Task { @MainActor in
                    await self?.reconcileSessionLibrary()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reconcileSessionLibrary() async {
        guard let sessionReconciler, let sessionIndex else { return }
        let availability = sessionLocationStore.resolve()
        do {
            _ = try await sessionReconciler.reconcile(
                availability: availability
            )
            indexedSessions = try await sessionIndex.sessions()
            let sessions = indexedSessions
            let presentation = sessionLibraryPresentation
            sessionLibraryItems = await Task.detached {
                presentation.items(from: sessions)
            }.value
            sessionSmartFolderCounts = try await sessionIndex
                .smartFolderCounts()
            if case let .available(library) = availability {
                manualSessionFolders = try sessionManualFolderManager
                    .folders(in: library)
            } else {
                manualSessionFolders = []
            }
        } catch {
            errorMessage =
                "Scribe could not refresh its session index. Session folders are untouched: \(error.localizedDescription)"
        }
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
            let modelManager = fluidAudioModelManager
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
            let modelURL = await modelManager.sileroModelURL
            let manifest = try CaptureSessionManifest.load(
                from: sessionDirectory
            )
            let selection = selectedTranscriptionModel
            let engine = try await makeTranscriptionEngine(
                for: selection,
                enforcingMemorySafety: false
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

            guard isSelectedModelAvailable else {
                liveTranscriptionPipeline = nil
                liveTranscriptionPipelineState = .modelUnavailable(
                    reason: .transcriptionModel
                )
                return
            }

            do {
                try await validateLoadingSafety(for: selection)
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
                await refreshSuggestedAvailableModel(for: selection)
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
        var rowsReadyForPersistence: [LiveTranscriptRow]?
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
                var finishFailureMessage: String?
                do {
                    try await liveTranscriptionPipeline
                        .waitUntilFinished()
                } catch {
                    finishFailureMessage = error.localizedDescription
                    failures.append(error.localizedDescription)
                }
                replaceLiveTranscriptRows(
                    with: await liveTranscriptionPipeline.rows
                )
                let stateBeforeShutdown =
                    await liveTranscriptionPipeline.state
                let finalState:
                    LiveTranscriptionPipelineState
                if case let .failed(message) = stateBeforeShutdown {
                    finalState = .failed(message: message)
                } else if let finishFailureMessage {
                    finalState = .failed(message: finishFailureMessage)
                } else {
                    rowsReadyForPersistence = liveTranscriptRows
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

        if let rowsReadyForPersistence {
            if let sessionDirectory = recordingSessionDirectory() {
                do {
                    _ = try await transcriptArtifactWriter.write(
                        liveRows: rowsReadyForPersistence,
                        modelIdentifier:
                            selectedTranscriptionModel.id.rawValue,
                        to: sessionDirectory
                    )
                    transcriptSegments = rowsReadyForPersistence.map(\.segment)
                    await reconcileSessionLibrary()
                } catch {
                    failures.append(
                        "Live transcript files couldn't be saved. The recording is unaffected and can be transcribed again: \(error.localizedDescription)"
                    )
                }
            } else {
                failures.append(
                    "Live transcript files couldn't be saved because Scribe could not locate the recording session. The recording is unaffected and can be transcribed again."
                )
            }
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
        replaceLiveTranscriptRows(
            with: await liveTranscriptionPipeline.rows
        )
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

    private func updateSystemSilenceState(now: Date = Date()) {
        guard isRecording, let recordingStartedAt else {
            systemTrackHasBeenSilent = false
            return
        }
        if (liveSpeechMetrics.speechProbabilities[.system] ?? 0) >= 0.10 {
            lastSystemSpeechAt = now
            systemTrackHasBeenSilent = false
            return
        }
        let lastActivity = lastSystemSpeechAt ?? recordingStartedAt
        systemTrackHasBeenSilent = now.timeIntervalSince(lastActivity) >= 30
    }

    private func replaceLiveTranscriptRows(with rows: [LiveTranscriptRow]) {
        liveTranscriptRows = rows
        if transcriptPresentationCache.update(with: rows) {
            recordingTranscriptRows =
                transcriptPresentationCache.presentationRows
        } else if rows.isEmpty, !recordingTranscriptRows.isEmpty {
            recordingTranscriptRows = []
        }
    }

    private func updateRecordingPinHotKeyRegistration() {
        if isRecording {
            guard
                recordingPinHotKey == nil,
                !pinHotKeyRegistrationFailedForSession
            else {
                return
            }
            let monitor = GlobalHotKeyMonitor { [weak self] in
                self?.addRecordingPin()
            }
            do {
                try monitor.start()
                recordingPinHotKey = monitor
            } catch {
                pinHotKeyRegistrationFailedForSession = true
                errorMessage = ScribeCopy.Recording.pinShortcutUnavailable
            }
        } else {
            recordingPinHotKey?.stop()
            recordingPinHotKey = nil
            pinHotKeyRegistrationFailedForSession = false
        }
    }

    private func recordingPinSampleOffset(
        atHostTime hostTime: UInt64
    ) async -> Int64? {
        for attempt in 0..<12 {
            let microphoneHostTime =
                await microphoneCapture.firstSampleHostTime()
            let systemHostTime =
                await systemAudioCapture.firstSampleHostTime()
            if let offset = AudioHostTime.recordingSampleOffset(
                atHostTime: hostTime,
                microphoneFirstSampleHostTime: microphoneHostTime,
                systemFirstSampleHostTime: systemHostTime
            ) {
                return offset
            }
            guard attempt < 11 else { break }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return nil
            }
        }
        return nil
    }

    private func waitForPendingRecordingPins() async {
        let pending = Array(pinWriteTasks.values)
        for task in pending {
            await task.value
        }
    }

    private func showRecordingPinStatus(
        _ status: RecordingPinFeedback,
        duration: Duration
    ) {
        recordingPinStatus = status
        pinConfirmationTask?.cancel()
        pinConfirmationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
                guard self?.recordingPinStatus == status else { return }
                self?.recordingPinStatus = nil
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

}

private actor RecordingPinWriter {
    func append(
        _ pin: CaptureSessionManifest.Pin,
        to sessionDirectory: URL
    ) async throws {
        try await CaptureSessionManifestStore.shared.appendPin(
            pin,
            in: sessionDirectory
        )
    }
}
