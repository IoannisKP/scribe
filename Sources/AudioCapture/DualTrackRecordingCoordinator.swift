import Foundation

public struct DualTrackRecordingPaths: Equatable, Sendable {
    public let sessionDirectory: URL
    public let microphoneURL: URL
    public let systemURL: URL
    public let manifestURL: URL

    public init(sessionDirectory: URL) {
        self.sessionDirectory = sessionDirectory
        self.microphoneURL = sessionDirectory.appendingPathComponent(
            "microphone.wav",
            isDirectory: false
        )
        self.systemURL = sessionDirectory.appendingPathComponent(
            "system.wav",
            isDirectory: false
        )
        self.manifestURL = sessionDirectory.appendingPathComponent(
            CaptureSessionManifest.fileName,
            isDirectory: false
        )
    }
}

public struct DualTrackCaptureResult: Equatable, Sendable {
    public let paths: DualTrackRecordingPaths
    public let microphone: AudioTrackCaptureResult
    public let system: AudioTrackCaptureResult
    public let stopReason: DualTrackRecordingStopReason

    public init(
        paths: DualTrackRecordingPaths,
        microphone: AudioTrackCaptureResult,
        system: AudioTrackCaptureResult,
        stopReason: DualTrackRecordingStopReason = .requested
    ) {
        self.paths = paths
        self.microphone = microphone
        self.system = system
        self.stopReason = stopReason
    }
}

public enum DualTrackRecordingStopReason: Equatable, Sendable {
    case requested
    case lowDiskSpace(availableBytes: Int64, reserveBytes: Int64)
    case diskSpaceMonitoringFailed(message: String)
}

public enum DualTrackRecordingState: Equatable, Sendable {
    case idle
    case starting(paths: DualTrackRecordingPaths)
    case recording(paths: DualTrackRecordingPaths)
    case stopping(paths: DualTrackRecordingPaths)
    case stopped(result: DualTrackCaptureResult)
    case failed(message: String, paths: DualTrackRecordingPaths?)

    public var isActive: Bool {
        switch self {
        case .starting, .recording, .stopping:
            true
        case .idle, .stopped, .failed:
            false
        }
    }
}

public actor DualTrackRecordingCoordinator {
    public private(set) var state: DualTrackRecordingState = .idle

    private let microphoneCapture: any AudioTrackCapturing
    private let systemCapture: any AudioTrackCapturing
    private let freeSpaceProvider: any RecordingFreeSpaceProviding
    private let diskSpaceConfiguration: RecordingDiskSpaceConfiguration
    private var activePaths: DualTrackRecordingPaths?
    private var diskMonitorTask: Task<Void, Never>?

    public init(
        microphoneCapture: any AudioTrackCapturing =
            MicrophoneCaptureService(),
        systemCapture: any AudioTrackCapturing =
            SystemAudioCaptureService(),
        freeSpaceProvider: any RecordingFreeSpaceProviding =
            VolumeRecordingFreeSpaceProvider(),
        diskSpaceConfiguration: RecordingDiskSpaceConfiguration = .init()
    ) {
        self.microphoneCapture = microphoneCapture
        self.systemCapture = systemCapture
        self.freeSpaceProvider = freeSpaceProvider
        self.diskSpaceConfiguration = diskSpaceConfiguration
    }

    @discardableResult
    public func startRecording(
        in sessionDirectory: URL
    ) async throws -> DualTrackRecordingPaths {
        guard !state.isActive else {
            throw AudioCaptureError.dualTrackStartFailed(
                "A recording is already active."
            )
        }

        let paths = DualTrackRecordingPaths(
            sessionDirectory: sessionDirectory
        )
        let availableCapacity: Int64
        do {
            availableCapacity = try await freeSpaceProvider
                .availableCapacity(at: sessionDirectory)
        } catch {
            let wrappedError = (error as? AudioCaptureError)
                ?? AudioCaptureError.recordingDiskSpaceCheckFailed(
                    error.localizedDescription
                )
            state = .failed(
                message: wrappedError.localizedDescription,
                paths: paths
            )
            throw wrappedError
        }
        let requiredCapacity = diskSpaceConfiguration
            .requiredFreeSpaceBeforeRecordingBytes
        guard availableCapacity >= requiredCapacity else {
            let error = AudioCaptureError.insufficientRecordingDiskSpace(
                requiredBytes: requiredCapacity,
                availableBytes: availableCapacity
            )
            state = .failed(
                message: error.localizedDescription,
                paths: paths
            )
            throw error
        }

        activePaths = paths
        state = .starting(paths: paths)

        do {
            try await systemCapture.startRecording(to: paths.systemURL)
        } catch {
            activePaths = nil
            state = .failed(
                message: error.localizedDescription,
                paths: paths
            )
            throw AudioCaptureError.dualTrackStartFailed(
                error.localizedDescription
            )
        }
        do {
            try await microphoneCapture.startRecording(
                to: paths.microphoneURL
            )
        } catch {
            var message = error.localizedDescription
            do {
                _ = try await systemCapture.stopCapture()
            } catch {
                message += " Stopping system audio also failed: \(error.localizedDescription)"
            }
            activePaths = nil
            state = .failed(message: message, paths: paths)
            throw AudioCaptureError.dualTrackStartFailed(message)
        }
        let systemStartupStageTimings =
            await systemCapture.systemStartupStageTimings()
        let systemAudioGraphPreparation =
            await systemCapture.systemAudioGraphPreparation()
        let microphoneInputDevice =
            await microphoneCapture.microphoneInputDeviceIdentity()
        do {
            let manifest: CaptureSessionManifest
            if !FileManager.default.fileExists(
                atPath: paths.manifestURL.path
            ) {
                manifest = CaptureSessionManifest.pendingDualTrack(
                    sessionID: UUID(),
                    title: paths.sessionDirectory.lastPathComponent,
                    createdAt: Date()
                )
            } else {
                manifest = try CaptureSessionManifest.load(
                    from: paths.sessionDirectory
                )
            }
            var manifestWithCaptureDiagnostics = systemStartupStageTimings.isEmpty
                ? manifest
                : manifest.replacingSystemAudioStartupStageTimings(
                    systemStartupStageTimings
                )
            if let systemAudioGraphPreparation {
                manifestWithCaptureDiagnostics = manifestWithCaptureDiagnostics
                    .replacingSystemAudioGraphPreparation(
                        systemAudioGraphPreparation
                    )
            }
            if let microphoneInputDevice {
                manifestWithCaptureDiagnostics = manifestWithCaptureDiagnostics
                    .replacingMicrophoneInputDevice(microphoneInputDevice)
            }
            try manifestWithCaptureDiagnostics.write(
                to: paths.sessionDirectory
            )
        } catch {
            var message =
                "Writing session metadata failed: \(error.localizedDescription)"
            do {
                _ = try await systemCapture.stopCapture()
            } catch {
                message += " Stopping system audio also failed: \(error.localizedDescription)"
            }
            do {
                _ = try await microphoneCapture.stopCapture()
            } catch {
                message += " Stopping the microphone also failed: \(error.localizedDescription)"
            }
            activePaths = nil
            state = .failed(message: message, paths: paths)
            throw AudioCaptureError.dualTrackStartFailed(message)
        }

        state = .recording(paths: paths)
        startDiskMonitoring()
        return paths
    }

    public func stopRecording() async throws -> DualTrackCaptureResult {
        try await stopRecording(reason: .requested)
    }

    /// Performs one injected/provider-backed monitoring pass immediately.
    /// Tests use this entry point without waiting for wall-clock polling.
    @discardableResult
    public func checkAvailableDiskSpace()
        async throws -> DualTrackCaptureResult?
    {
        guard case .recording = state, let paths = activePaths else {
            return nil
        }

        let availableCapacity: Int64
        do {
            availableCapacity = try await freeSpaceProvider
                .availableCapacity(at: paths.sessionDirectory)
        } catch {
            return try await stopRecording(
                reason: .diskSpaceMonitoringFailed(
                    message: error.localizedDescription
                )
            )
        }
        let reserve = diskSpaceConfiguration.minimumFreeSpaceReserveBytes
        guard availableCapacity <= reserve else {
            return nil
        }
        return try await stopRecording(
            reason: .lowDiskSpace(
                availableBytes: availableCapacity,
                reserveBytes: reserve
            )
        )
    }

    private func stopRecording(
        reason: DualTrackRecordingStopReason
    ) async throws -> DualTrackCaptureResult {
        guard state.isActive, let paths = activePaths else {
            throw AudioCaptureError.dualTrackStopFailed(
                "There is no active two-track recording."
            )
        }

        diskMonitorTask?.cancel()
        diskMonitorTask = nil
        state = .stopping(paths: paths)
        var failures: [String] = []
        var systemResult: AudioTrackCaptureResult?
        var microphoneResult: AudioTrackCaptureResult?

        do {
            systemResult = try await systemCapture.stopCapture()
        } catch {
            failures.append(error.localizedDescription)
        }
        do {
            microphoneResult = try await microphoneCapture.stopCapture()
        } catch {
            failures.append(error.localizedDescription)
        }

        activePaths = nil
        guard
            failures.isEmpty,
            let microphoneResult,
            let systemResult
        else {
            let message = failures.isEmpty
                ? "One or both capture services returned no result."
                : failures.joined(separator: " ")
            state = .failed(message: message, paths: paths)
            throw AudioCaptureError.dualTrackStopFailed(message)
        }

        do {
            let offsets = AudioHostTime.normalizedCanonicalOffsets(
                microphoneHostTime: microphoneResult.firstSampleHostTime,
                systemHostTime: systemResult.firstSampleHostTime
            )
            try await CaptureSessionManifestStore.shared
                .replaceTrackOffsets(
                    microphone: offsets.microphone,
                    system: offsets.system,
                    in: paths.sessionDirectory
                )
        } catch {
            let message =
                "The audio files were finalized, but sample-accurate track timing could not be saved: \(error.localizedDescription)"
            state = .failed(message: message, paths: paths)
            throw AudioCaptureError.dualTrackStopFailed(message)
        }

        let result = DualTrackCaptureResult(
            paths: paths,
            microphone: microphoneResult,
            system: systemResult,
            stopReason: reason
        )
        state = .stopped(result: result)
        return result
    }

    private func startDiskMonitoring() {
        diskMonitorTask?.cancel()
        let interval = diskSpaceConfiguration.monitoringInterval
        diskMonitorTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: interval)
                    guard let self else {
                        return
                    }
                    _ = try await self.checkAvailableDiskSpace()
                }
            } catch is CancellationError {
                return
            } catch {
                // stopRecording records any finalization failure in state.
                return
            }
        }
    }

}
