import Foundation

public enum AudioSource: String, Codable, CaseIterable, Hashable, Sendable {
    case microphone
    case system
    case imported

    /// Sources that exist only for a live, isolated two-track capture.
    public static let liveCaptureSources: [AudioSource] = [
        .microphone,
        .system
    ]
}

public struct MicrophoneInputDeviceIdentity:
    Codable,
    Equatable,
    Sendable
{
    public let audioDeviceID: UInt32
    public let uid: String
    public let name: String

    public init(audioDeviceID: UInt32, uid: String, name: String) {
        self.audioDeviceID = audioDeviceID
        self.uid = uid
        self.name = name
    }
}

public enum MicrophoneInputRouteChangeReason: String, Codable, Sendable {
    case recordingStarted
    case inputConfigurationChanged
    case wakeRecovery

    /// The installed tap stopped delivering frames, or never delivered any, so
    /// the route was rebound and the tap reinstalled. A Bluetooth input that is
    /// still switching into headset mode reports a transient format that is
    /// valid when read and dead once the route settles.
    case captureDeliveredNoAudio
}

public struct MicrophoneInputRouteChange: Codable, Equatable, Sendable {
    public let recordedAt: Date
    public let reason: MicrophoneInputRouteChangeReason
    public let device: MicrophoneInputDeviceIdentity
    public let inputSampleRate: Double
    public let inputChannelCount: UInt32

    public init(
        recordedAt: Date = Date(),
        reason: MicrophoneInputRouteChangeReason,
        device: MicrophoneInputDeviceIdentity,
        inputSampleRate: Double,
        inputChannelCount: UInt32
    ) {
        self.recordedAt = recordedAt
        self.reason = reason
        self.device = device
        self.inputSampleRate = inputSampleRate
        self.inputChannelCount = inputChannelCount
    }

    public func hasSameCaptureRoute(
        as other: MicrophoneInputRouteChange
    ) -> Bool {
        device == other.device
            && inputSampleRate == other.inputSampleRate
            && inputChannelCount == other.inputChannelCount
    }
}

public struct AudioTrackCaptureResult: Equatable, Sendable {
    public let source: AudioSource
    public let outputURL: URL
    public let droppedSampleCount: UInt64

    /// Frames accepted from the realtime callback across the whole session,
    /// including recovery. Zero means the capture callback never delivered
    /// anything, which is distinct from delivering silence.
    public let capturedSampleCount: UInt64
    public let firstSampleHostTime: UInt64?

    public init(
        source: AudioSource,
        outputURL: URL,
        droppedSampleCount: UInt64,
        capturedSampleCount: UInt64 = 0,
        firstSampleHostTime: UInt64? = nil
    ) {
        self.source = source
        self.outputURL = outputURL
        self.droppedSampleCount = droppedSampleCount
        self.capturedSampleCount = capturedSampleCount
        self.firstSampleHostTime = firstSampleHostTime
    }
}

public enum SystemAudioStartupStage: String, Codable, CaseIterable, Sendable {
    case processTapCreation
    case tapFormatLookup
    case aggregateDeviceCreation
    case ioProcRegistration
    case wavWriterCreationAndHeaderFlush
    case listenerRegistration
    case audioDeviceStart
}

public struct SystemAudioStartupStageTiming:
    Codable,
    Equatable,
    Sendable
{
    public let stage: SystemAudioStartupStage
    public let durationMachTicks: UInt64
    public let durationNanoseconds: UInt64

    public init(
        stage: SystemAudioStartupStage,
        durationMachTicks: UInt64,
        durationNanoseconds: UInt64
    ) {
        self.stage = stage
        self.durationMachTicks = durationMachTicks
        self.durationNanoseconds = durationNanoseconds
    }
}

public enum SystemAudioGraphPreparation: String, Codable, Sendable {
    /// Recording reused the graph completed by launch-time or lifecycle
    /// prewarming, including waiting for an in-flight preparation.
    case prewarmed

    /// No launch-time preparation had started, so the recording request
    /// initiated the one shared preparation operation itself.
    case builtAtRecordingStart
}

public struct SystemTapProcessMetrics: Codable, Equatable, Sendable {
    public let processID: Int32
    public let processName: String
    public let residentBytes: UInt64
    public let physicalFootprintBytes: UInt64
    public let packageIdleWakeups: UInt64
    public let interruptWakeups: UInt64

    public init(
        processID: Int32,
        processName: String,
        residentBytes: UInt64,
        physicalFootprintBytes: UInt64,
        packageIdleWakeups: UInt64,
        interruptWakeups: UInt64
    ) {
        self.processID = processID
        self.processName = processName
        self.residentBytes = residentBytes
        self.physicalFootprintBytes = physicalFootprintBytes
        self.packageIdleWakeups = packageIdleWakeups
        self.interruptWakeups = interruptWakeups
    }
}

public struct SystemTapResourceSnapshot: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let app: SystemTapProcessMetrics?
    public let coreaudiod: SystemTapProcessMetrics?

    public init(
        capturedAt: Date,
        app: SystemTapProcessMetrics?,
        coreaudiod: SystemTapProcessMetrics?
    ) {
        self.capturedAt = capturedAt
        self.app = app
        self.coreaudiod = coreaudiod
    }
}

public enum SystemTapDiagnosticProgress: Equatable, Sendable {
    case preparing
    case holding(secondsRemaining: Int, callbackCount: UInt64)
    case registeringComparison
    case cleaningUp
}

public struct SystemTapPrivacyDiagnosticReport:
    Codable,
    Equatable,
    Sendable
{
    public let runID: UUID
    public let startedAt: Date
    public let completedAt: Date
    public let holdSeconds: Int
    public let outputDeviceUID: String
    public let preparationTimings: [SystemAudioStartupStageTiming]
    public let secondIOProcRegistrationTiming: SystemAudioStartupStageTiming
    public let primaryCallbackCount: UInt64
    public let secondIOProcCallbackCount: UInt64
    public let resourcesBeforePreparation: SystemTapResourceSnapshot
    public let resourcesAfterPreparation: SystemTapResourceSnapshot
    public let resourcesAfterHold: SystemTapResourceSnapshot
    public let ringBufferAllocated: Bool
    public let wavWriterCreated: Bool
}

public struct SystemTapTimingSample: Codable, Equatable, Sendable {
    public let runID: UUID
    public let capturedAt: Date
    public let outputDeviceUID: String
    public let timings: [SystemAudioStartupStageTiming]
    public let callbackCount: UInt64
    public let ringBufferAllocated: Bool
    public let wavWriterCreated: Bool
}

public protocol AudioTrackCapturing: Sendable {
    func startRecording(to outputURL: URL) async throws
    func stopCapture() async throws -> AudioTrackCaptureResult
    func firstSampleHostTime() async -> UInt64?
    func systemStartupStageTimings() async -> [SystemAudioStartupStageTiming]
    func systemAudioGraphPreparation() async -> SystemAudioGraphPreparation?
    func microphoneInputDeviceIdentity() async
        -> MicrophoneInputDeviceIdentity?
    func microphoneInputRouteChanges() async
        -> [MicrophoneInputRouteChange]
}

public extension AudioTrackCapturing {
    func firstSampleHostTime() async -> UInt64? { nil }
    func systemStartupStageTimings() async -> [SystemAudioStartupStageTiming] {
        []
    }
    func systemAudioGraphPreparation() async -> SystemAudioGraphPreparation? {
        nil
    }
    func microphoneInputDeviceIdentity() async
        -> MicrophoneInputDeviceIdentity?
    {
        nil
    }
    func microphoneInputRouteChanges() async
        -> [MicrophoneInputRouteChange]
    {
        []
    }
}

public enum CanonicalAudioFormat {
    public static let sampleRate: Double = 16_000
    public static let channelCount: UInt32 = 1
    public static let bitsPerSample: UInt16 = 32
    public static let bytesPerSample: UInt16 = bitsPerSample / 8
}

public enum AudioCaptureError: Error, Equatable, LocalizedError, Sendable {
    case invalidRingBufferCapacity(Int)
    case ringBufferAllocationFailed(Int)
    case invalidSampleRate(Double)
    case audioFormatCreationFailed
    case audioConverterCreationFailed
    case audioBufferAllocationFailed
    case audioConversionFailed(String)
    case audioConversionProducedNoChannelData
    case wavFileAlreadyExists(URL)
    case wavFileCreationFailed(URL)
    case wavFileTooLarge
    case wavWriterFinalized
    case microphonePermissionDenied
    case microphonePermissionRestricted
    case microphoneInputUnavailable
    case audioDeviceIdentityUnavailable
    case microphoneInputDeviceBindingMismatch(requested: UInt32, bound: UInt32)
    case microphoneInputResolvedToSystemTap
    case microphoneFormatUnsupported
    case microphoneCaptureAlreadyRunning
    case microphoneCaptureNotRunning
    case microphoneEngineStartFailed(String)
    case microphoneRecoveryFailed(String)
    case microphoneDeliveredNoAudio(rebuildAttempts: Int)
    case microphoneCapturedNoAudio
    case microphoneConsumerFailed(String)
    case audioConsumerFailed(String)
    case audioFormatChangedBeforeBufferedSamplesDrained
    case hostTimeLatchAllocationFailed
    case diagnosticCounterAllocationFailed
    case realtimeRouterAllocationFailed
    case systemCaptureAlreadyRunning
    case systemCaptureNotRunning
    case systemOutputDeviceUnavailable
    case systemProcessObjectUnavailable
    case systemTapFormatUnsupported
    case systemAudioPermissionDenied
    case systemAudioPermissionCheckFailed(String)
    case coreAudioOperationFailed(
        operation: String,
        status: Int32,
        statusDescription: String
    )
    case systemGraphTeardownFailed(String)
    case systemRecoveryFailed(String)
    case recordingDiskSpaceCheckFailed(String)
    case insufficientRecordingDiskSpace(
        requiredBytes: Int64,
        availableBytes: Int64
    )
    case dualTrackStartFailed(String)
    case dualTrackStopFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRingBufferCapacity(capacity):
            "Ring buffer capacity must be positive; received \(capacity)."
        case let .ringBufferAllocationFailed(capacity):
            "Unable to allocate a ring buffer for \(capacity) samples."
        case let .invalidSampleRate(sampleRate):
            "Sample rate must be finite and positive; received \(sampleRate)."
        case .audioFormatCreationFailed:
            "Unable to create the requested mono Float32 audio format."
        case .audioConverterCreationFailed:
            "Unable to create an AVAudioConverter for the requested formats."
        case .audioBufferAllocationFailed:
            "Unable to allocate an audio conversion buffer."
        case let .audioConversionFailed(message):
            "Audio conversion failed: \(message)"
        case .audioConversionProducedNoChannelData:
            "Audio conversion completed without accessible Float32 channel data."
        case let .wavFileAlreadyExists(url):
            "Refusing to overwrite the existing WAV file at \(url.path)."
        case let .wavFileCreationFailed(url):
            "Unable to create a WAV file at \(url.path)."
        case .wavFileTooLarge:
            "The WAV recording exceeded the 4 GB limit of the RIFF WAV format."
        case .wavWriterFinalized:
            "The WAV writer has already been finalized."
        case .microphonePermissionDenied:
            "Microphone access is denied. Allow Scribe in System Settings → Privacy & Security → Microphone, then try again."
        case .microphonePermissionRestricted:
            "Microphone access is restricted by this Mac's policy. Ask the device administrator to allow microphone recording."
        case .microphoneInputUnavailable:
            "No usable microphone input is available. Connect or select an input device, then try again."
        case .audioDeviceIdentityUnavailable:
            "Core Audio could not identify the selected audio device. Select the input and output devices again, then retry."
        case .microphoneInputDeviceBindingMismatch:
            "The microphone route didn't match the selected input, so recording didn't start. Select a physical microphone and try again."
        case .microphoneInputResolvedToSystemTap:
            "The selected microphone resolved to Scribe's system-audio tap, so recording didn't start. Select a physical microphone and try again."
        case .microphoneFormatUnsupported:
            "The selected microphone does not provide a usable noninterleaved Float32 format."
        case .microphoneCaptureAlreadyRunning:
            "Microphone recording is already active."
        case .microphoneCaptureNotRunning:
            "There is no active microphone recording to stop."
        case let .microphoneEngineStartFailed(message):
            "The microphone audio engine could not start: \(message)"
        case let .microphoneRecoveryFailed(message):
            "Microphone recording could not recover after an audio-device interruption: \(message)"
        case let .microphoneDeliveredNoAudio(rebuildAttempts):
            "The microphone stopped sending audio to Scribe and did not recover after \(rebuildAttempts) attempts to rebuild the input route. If you are using Bluetooth headphones, disconnect them or select a different microphone, then record again."
        case .microphoneCapturedNoAudio:
            "The microphone recorded no audio at all for this session, so only the system-audio track is usable. This is usually a Bluetooth input that never finished switching into headset mode. Select a different microphone, or reconnect the headset, then record again."
        case let .microphoneConsumerFailed(message):
            "Microphone audio could not be processed or written: \(message)"
        case let .audioConsumerFailed(message):
            "Captured audio could not be processed or written: \(message)"
        case .audioFormatChangedBeforeBufferedSamplesDrained:
            "The input format changed before previously captured samples could be drained safely."
        case .hostTimeLatchAllocationFailed:
            "Scribe could not allocate first-sample timing storage."
        case .diagnosticCounterAllocationFailed:
            "Scribe could not allocate the system-tap diagnostic callback counter."
        case .realtimeRouterAllocationFailed:
            "Scribe could not allocate the system-audio realtime routing slot."
        case .systemCaptureAlreadyRunning:
            "System-audio recording is already active."
        case .systemCaptureNotRunning:
            "There is no active system-audio recording to stop."
        case .systemOutputDeviceUnavailable:
            "No usable default output device is available. Select a speaker or headphones, then try again."
        case .systemProcessObjectUnavailable:
            "Core Audio could not identify Scribe's own audio process, so capture was stopped to prevent self-audio feedback."
        case .systemTapFormatUnsupported:
            "The system-audio tap did not provide mono Float32 PCM in a format Scribe can capture safely."
        case .systemAudioPermissionDenied:
            "System-audio recording permission was denied. Allow Scribe in System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only, then try again."
        case let .systemAudioPermissionCheckFailed(message):
            "System-audio permission could not be checked: \(message)"
        case let .coreAudioOperationFailed(
            operation,
            status,
            statusDescription
        ):
            "\(operation) failed with Core Audio status \(status) (\(statusDescription))."
        case let .systemGraphTeardownFailed(message):
            "Core Audio capture stopped, but one or more temporary audio objects could not be removed: \(message)"
        case let .systemRecoveryFailed(message):
            "System-audio recording could not recover after an output-device interruption: \(message)"
        case let .recordingDiskSpaceCheckFailed(message):
            "Scribe could not check free recording space: \(message)"
        case let .insufficientRecordingDiskSpace(
            requiredBytes,
            availableBytes
        ):
            "Recording was not started because Scribe needs \(Self.formattedByteCount(requiredBytes)) free for the expected session and safety reserve; \(Self.formattedByteCount(availableBytes)) is available."
        case let .dualTrackStartFailed(message):
            "The two-track recording could not start: \(message)"
        case let .dualTrackStopFailed(message):
            "The two-track recording stopped with an error: \(message)"
        }
    }

    private static func formattedByteCount(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }
}
