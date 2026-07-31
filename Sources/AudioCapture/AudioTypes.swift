import Foundation

public enum AudioSource: String, Codable, CaseIterable, Hashable, Sendable {
    case microphone
    case system
}

public struct AudioTrackCaptureResult: Equatable, Sendable {
    public let source: AudioSource
    public let outputURL: URL
    public let droppedSampleCount: UInt64

    public init(
        source: AudioSource,
        outputURL: URL,
        droppedSampleCount: UInt64
    ) {
        self.source = source
        self.outputURL = outputURL
        self.droppedSampleCount = droppedSampleCount
    }
}

public protocol AudioTrackCapturing: Sendable {
    func startRecording(to outputURL: URL) async throws
    func stopCapture() async throws -> AudioTrackCaptureResult
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
    case microphoneFormatUnsupported
    case microphoneCaptureAlreadyRunning
    case microphoneCaptureNotRunning
    case microphoneEngineStartFailed(String)
    case microphoneRecoveryFailed(String)
    case microphoneConsumerFailed(String)
    case audioConsumerFailed(String)
    case audioFormatChangedBeforeBufferedSamplesDrained
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
        case let .microphoneConsumerFailed(message):
            "Microphone audio could not be processed or written: \(message)"
        case let .audioConsumerFailed(message):
            "Captured audio could not be processed or written: \(message)"
        case .audioFormatChangedBeforeBufferedSamplesDrained:
            "The input format changed before previously captured samples could be drained safely."
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
        case let .dualTrackStartFailed(message):
            "The two-track recording could not start: \(message)"
        case let .dualTrackStopFailed(message):
            "The two-track recording stopped with an error: \(message)"
        }
    }
}
