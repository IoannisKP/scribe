@preconcurrency import AppKit
@preconcurrency import AVFoundation
import Foundation

public enum MicrophoneCaptureState: Equatable, Sendable {
    case idle
    case requestingPermission
    case starting
    case recording(outputURL: URL)
    case recovering(reason: String, outputURL: URL)
    case stopping
    case stopped(outputURL: URL, droppedSampleCount: UInt64)
    case failed(message: String)

    public var isActive: Bool {
        switch self {
        case .requestingPermission, .starting, .recording, .recovering, .stopping:
            true
        case .idle, .stopped, .failed:
            false
        }
    }
}

public actor MicrophoneCaptureService {
    public private(set) var state: MicrophoneCaptureState = .idle

    private let permissionAuthorizer: any MicrophonePermissionAuthorizing
    private let liveSink: (any CanonicalAudioBlockSink)?
    private let engine = AVAudioEngine()

    private var ringBuffer: FloatRingBuffer?
    private var realtimeSink: MicrophoneRealtimeSink?
    private var firstSampleTime: FirstSampleHostTime?
    private var consumer: CanonicalAudioFileConsumer?
    private var drainTask: Task<Void, Never>?
    private var outputURL: URL?
    private var isTapInstalled = false
    private var isRecovering = false
    private var isSleeping = false
    private var selectedInputDevice: MicrophoneInputDeviceIdentity?
    private var observerRegistrations: [ObserverRegistration] = []

    public init(
        permissionAuthorizer: any MicrophonePermissionAuthorizing =
            SystemMicrophonePermissionAuthorizer(),
        liveSink: (any CanonicalAudioBlockSink)? = nil
    ) {
        self.permissionAuthorizer = permissionAuthorizer
        self.liveSink = liveSink
    }

    public func permissionStatus() async -> MicrophoneAuthorizationStatus {
        await permissionAuthorizer.authorizationStatus()
    }

    public func startRecording(to outputURL: URL) async throws {
        guard !state.isActive else {
            throw AudioCaptureError.microphoneCaptureAlreadyRunning
        }

        state = .requestingPermission
        let initialStatus = await permissionAuthorizer.authorizationStatus()
        let finalStatus: MicrophoneAuthorizationStatus
        if initialStatus == .notDetermined {
            let granted = await permissionAuthorizer.requestAuthorization()
            finalStatus = granted ? .authorized : .denied
        } else {
            finalStatus = initialStatus
        }

        switch finalStatus {
        case .authorized:
            break
        case .denied, .notDetermined:
            state = .failed(
                message: AudioCaptureError.microphonePermissionDenied.localizedDescription
            )
            throw AudioCaptureError.microphonePermissionDenied
        case .restricted:
            state = .failed(
                message: AudioCaptureError.microphonePermissionRestricted.localizedDescription
            )
            throw AudioCaptureError.microphonePermissionRestricted
        }

        state = .starting
        selectedInputDevice = nil
        do {
            let captureFormat = try currentCaptureFormat()
            let capacity = try ringCapacity(sampleRate: captureFormat.sampleRate)
            let ringBuffer = try FloatRingBuffer(capacity: capacity)
            let consumer = try CanonicalAudioFileConsumer(
                source: .microphone,
                ringBuffer: ringBuffer,
                inputSampleRate: captureFormat.sampleRate,
                outputURL: outputURL,
                liveSink: liveSink
            )
            let firstSampleTime = try FirstSampleHostTime()
            let realtimeSink = MicrophoneRealtimeSink(
                ringBuffer: ringBuffer,
                firstSampleTime: firstSampleTime
            )

            self.ringBuffer = ringBuffer
            self.consumer = consumer
            self.realtimeSink = realtimeSink
            self.firstSampleTime = firstSampleTime
            self.outputURL = outputURL
            startDrainTask(consumer: consumer)
            try installTap(format: captureFormat, sink: realtimeSink)
            registerForInterruptions()
            engine.prepare()
            try engine.start()
            state = .recording(outputURL: outputURL)
        } catch {
            let cleanupMessage = await shutDownPipelineAfterFailure()
            let originalMessage = error.localizedDescription
            let combinedMessage = cleanupMessage.map {
                "\(originalMessage) Cleanup also failed: \($0)"
            } ?? originalMessage
            state = .failed(message: combinedMessage)

            if let captureError = error as? AudioCaptureError {
                throw captureError
            }
            throw AudioCaptureError.microphoneEngineStartFailed(combinedMessage)
        }
    }

    @discardableResult
    public func stopRecording() async throws -> URL {
        guard state.isActive, let outputURL else {
            throw AudioCaptureError.microphoneCaptureNotRunning
        }

        state = .stopping
        stopEngineAndRemoveTap()
        unregisterForInterruptions()

        drainTask?.cancel()
        if let drainTask {
            await drainTask.value
        }
        self.drainTask = nil

        do {
            if let consumer {
                try await consumer.finish()
            }
        } catch {
            let message = error.localizedDescription
            clearPipelineReferences()
            state = .failed(message: message)
            throw AudioCaptureError.microphoneConsumerFailed(message)
        }

        let droppedSampleCount = ringBuffer?.droppedSampleCount ?? 0
        clearPipelineReferences()
        state = .stopped(
            outputURL: outputURL,
            droppedSampleCount: droppedSampleCount
        )
        return outputURL
    }

    private func currentCaptureFormat() throws -> AVAudioFormat {
        let inputNode = engine.inputNode
        let deviceID = try CoreAudioProperties.defaultInputDevice()
        let identity = try CoreAudioProperties.inputDeviceIdentity(deviceID)
        guard !identity.uid.hasPrefix("com.localfirst.Scribe.SystemTap.") else {
            throw AudioCaptureError.microphoneInputResolvedToSystemTap
        }
        guard let audioUnit = inputNode.audioUnit else {
            throw AudioCaptureError.microphoneInputUnavailable
        }
        try CoreAudioProperties.bindInputDevice(deviceID, to: audioUnit)
        selectedInputDevice = identity

        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard
            hardwareFormat.sampleRate.isFinite,
            hardwareFormat.sampleRate > 0,
            hardwareFormat.channelCount > 0
        else {
            throw AudioCaptureError.microphoneInputUnavailable
        }
        guard let captureFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hardwareFormat.sampleRate,
            channels: hardwareFormat.channelCount,
            interleaved: false
        ) else {
            throw AudioCaptureError.microphoneFormatUnsupported
        }
        return captureFormat
    }

    private func ringCapacity(sampleRate: Double) throws -> Int {
        let tenSeconds = sampleRate * 10
        guard tenSeconds.isFinite, tenSeconds <= Double(Int.max) else {
            throw AudioCaptureError.microphoneFormatUnsupported
        }
        return max(4_096, Int(tenSeconds.rounded(.up)))
    }

    private func installTap(
        format: AVAudioFormat,
        sink: MicrophoneRealtimeSink
    ) throws {
        guard !isTapInstalled else {
            throw AudioCaptureError.microphoneCaptureAlreadyRunning
        }

        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format
        ) { buffer, time in
            sink.receive(buffer, time: time)
        }
        isTapInstalled = true
    }

    private func stopEngineAndRemoveTap() {
        engine.stop()
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        engine.reset()
    }

    private func startDrainTask(consumer: CanonicalAudioFileConsumer) {
        drainTask = Task.detached(priority: .high) { [weak self] in
            do {
                while !Task.isCancelled {
                    let processedSamples = try await consumer.processAvailable()
                    if processedSamples == 0 {
                        try await Task.sleep(for: .milliseconds(5))
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                let message = error.localizedDescription
                await consumer.recordBackgroundFailure(message)
                await self?.handleConsumerFailure(message: message)
            }
        }
    }

    private func handleConsumerFailure(message: String) async {
        switch state {
        case .recording, .recovering:
            break
        case .idle, .requestingPermission, .starting, .stopping, .stopped, .failed:
            return
        }

        stopEngineAndRemoveTap()
        unregisterForInterruptions()

        var finalMessage = message
        if let consumer {
            do {
                try await consumer.finalizeAfterBackgroundFailure()
            } catch {
                finalMessage += " Finalizing the WAV also failed: \(error.localizedDescription)"
            }
        }

        clearPipelineReferences()
        state = .failed(
            message: AudioCaptureError
                .microphoneConsumerFailed(finalMessage)
                .localizedDescription
        )
    }

    private func registerForInterruptions() {
        guard observerRegistrations.isEmpty else {
            return
        }

        let engineCenter = NotificationCenter.default
        let configurationToken = engineCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else {
                return
            }
            Task {
                await self.handleConfigurationChange()
            }
        }
        observerRegistrations.append(
            ObserverRegistration(center: engineCenter, token: configurationToken)
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let sleepToken = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else {
                return
            }
            Task {
                await self.handleWillSleep()
            }
        }
        observerRegistrations.append(
            ObserverRegistration(center: workspaceCenter, token: sleepToken)
        )

        let wakeToken = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else {
                return
            }
            Task {
                await self.handleDidWake()
            }
        }
        observerRegistrations.append(
            ObserverRegistration(center: workspaceCenter, token: wakeToken)
        )
    }

    private func unregisterForInterruptions() {
        for registration in observerRegistrations {
            registration.center.removeObserver(registration.token)
        }
        observerRegistrations.removeAll(keepingCapacity: true)
    }

    private func handleConfigurationChange() async {
        guard state.isActive, !isRecovering, !isSleeping else {
            return
        }
        await recoverAfterInterruption(reason: "The audio input device changed.")
    }

    private func handleWillSleep() {
        guard state.isActive, !isSleeping, let outputURL else {
            return
        }
        isSleeping = true
        isRecovering = true
        state = .recovering(
            reason: "Recording is paused while this Mac sleeps.",
            outputURL: outputURL
        )
        stopEngineAndRemoveTap()
    }

    private func handleDidWake() async {
        guard state.isActive, isSleeping else {
            return
        }
        isSleeping = false
        isRecovering = false
        await recoverAfterInterruption(reason: "The Mac woke from sleep.")
    }

    private func recoverAfterInterruption(reason: String) async {
        guard
            let ringBuffer,
            let consumer,
            let realtimeSink,
            let outputURL
        else {
            return
        }

        isRecovering = true
        state = .recovering(reason: reason, outputURL: outputURL)
        stopEngineAndRemoveTap()

        do {
            try await waitUntilDrained(ringBuffer)
            let captureFormat = try currentCaptureFormat()
            try await consumer.reconfigure(
                inputSampleRate: captureFormat.sampleRate
            )
            try installTap(format: captureFormat, sink: realtimeSink)
            engine.prepare()
            try engine.start()
            isRecovering = false
            state = .recording(outputURL: outputURL)
        } catch {
            let message = error.localizedDescription
            await failAfterRecovery(message: message)
        }
    }

    private func waitUntilDrained(_ ringBuffer: FloatRingBuffer) async throws {
        for _ in 0..<400 {
            if ringBuffer.readableCount == 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw AudioCaptureError.audioFormatChangedBeforeBufferedSamplesDrained
    }

    private func failAfterRecovery(message: String) async {
        stopEngineAndRemoveTap()
        unregisterForInterruptions()
        drainTask?.cancel()
        if let drainTask {
            await drainTask.value
        }

        var finalMessage = message
        if let consumer {
            do {
                try await consumer.finish()
            } catch {
                finalMessage += " Finalizing the captured audio also failed: \(error.localizedDescription)"
            }
        }

        clearPipelineReferences()
        isRecovering = false
        state = .failed(
            message: AudioCaptureError
                .microphoneRecoveryFailed(finalMessage)
                .localizedDescription
        )
    }

    private func shutDownPipelineAfterFailure() async -> String? {
        stopEngineAndRemoveTap()
        unregisterForInterruptions()
        drainTask?.cancel()
        if let drainTask {
            await drainTask.value
        }

        var cleanupMessage: String?
        if let consumer {
            do {
                try await consumer.finish()
            } catch {
                cleanupMessage = error.localizedDescription
            }
        }
        clearPipelineReferences()
        return cleanupMessage
    }

    private func clearPipelineReferences() {
        ringBuffer = nil
        realtimeSink = nil
        firstSampleTime = nil
        consumer = nil
        drainTask = nil
        outputURL = nil
        isSleeping = false
        isRecovering = false
    }
}

private final class MicrophoneRealtimeSink: @unchecked Sendable {
    private let ringBuffer: FloatRingBuffer
    private let firstSampleTime: FirstSampleHostTime

    init(
        ringBuffer: FloatRingBuffer,
        firstSampleTime: FirstSampleHostTime
    ) {
        self.ringBuffer = ringBuffer
        self.firstSampleTime = firstSampleTime
    }

    func receive(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard
            let channels = buffer.floatChannelData,
            buffer.frameLength > 0,
            buffer.format.channelCount > 0
        else {
            return
        }

        let written = ringBuffer.writePlanarMix(
            channels: channels,
            channelCount: Int(buffer.format.channelCount),
            frameCount: Int(buffer.frameLength)
        )
        if written > 0, time.isHostTimeValid {
            firstSampleTime.capture(time.hostTime)
        }
    }
}

private struct ObserverRegistration: @unchecked Sendable {
    let center: NotificationCenter
    let token: any NSObjectProtocol
}

extension MicrophoneCaptureService: AudioTrackCapturing {
    public func microphoneInputDeviceIdentity() async
        -> MicrophoneInputDeviceIdentity?
    {
        selectedInputDevice
    }

    public func firstSampleHostTime() async -> UInt64? {
        firstSampleTime?.value
    }

    public func stopCapture() async throws -> AudioTrackCaptureResult {
        let capturedFirstSampleHostTime = firstSampleTime?.value
        let outputURL = try await stopRecording()
        let droppedSampleCount: UInt64
        if case let .stopped(_, capturedDroppedSampleCount) = state {
            droppedSampleCount = capturedDroppedSampleCount
        } else {
            droppedSampleCount = 0
        }
        return AudioTrackCaptureResult(
            source: .microphone,
            outputURL: outputURL,
            droppedSampleCount: droppedSampleCount,
            firstSampleHostTime: capturedFirstSampleHostTime
        )
    }
}
