@preconcurrency import AppKit
@preconcurrency import AVFoundation
@preconcurrency import CoreAudio
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
    private let livenessPolicy: MicrophoneLivenessPolicy
    private let engine = AVAudioEngine()

    private var ringBuffer: FloatRingBuffer?
    private var realtimeSink: MicrophoneRealtimeSink?
    private var firstSampleTime: FirstSampleHostTime?
    private var acceptedFrameCounter: RealtimeCallbackCounter?
    private var consumer: CanonicalAudioFileConsumer?
    private var drainTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var outputURL: URL?
    private var isTapInstalled = false
    private var isRecovering = false
    private var isSleeping = false
    private var lastAcceptedFrameCount: UInt64 = 0
    private var lastFrameProgressAt: ContinuousClock.Instant?
    private var consecutiveRebuilds = 0
    private var capturedSampleCount: UInt64 = 0
    private var selectedInputDevice: MicrophoneInputDeviceIdentity?
    private var inputRouteChanges: [MicrophoneInputRouteChange] = []
    private var observerRegistrations: [ObserverRegistration] = []

    public init(
        permissionAuthorizer: any MicrophonePermissionAuthorizing =
            SystemMicrophonePermissionAuthorizer(),
        liveSink: (any CanonicalAudioBlockSink)? = nil,
        livenessPolicy: MicrophoneLivenessPolicy = MicrophoneLivenessPolicy()
    ) {
        self.permissionAuthorizer = permissionAuthorizer
        self.liveSink = liveSink
        self.livenessPolicy = livenessPolicy
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
        inputRouteChanges = []
        capturedSampleCount = 0
        do {
            let resolvedRoute = try currentCaptureRoute(
                reason: .recordingStarted
            )
            let captureFormat = resolvedRoute.tapFormat
            selectedInputDevice = resolvedRoute.change.device
            inputRouteChanges = [resolvedRoute.change]
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
            let acceptedFrameCounter = try RealtimeCallbackCounter()
            let realtimeSink = MicrophoneRealtimeSink(
                ringBuffer: ringBuffer,
                firstSampleTime: firstSampleTime,
                acceptedFrameCounter: acceptedFrameCounter
            )

            self.ringBuffer = ringBuffer
            self.consumer = consumer
            self.realtimeSink = realtimeSink
            self.firstSampleTime = firstSampleTime
            self.acceptedFrameCounter = acceptedFrameCounter
            self.outputURL = outputURL
            startDrainTask(consumer: consumer)
            try installTap(format: captureFormat, sink: realtimeSink)
            registerForInterruptions()
            engine.prepare()
            try engine.start()
            state = .recording(outputURL: outputURL)
            startLivenessMonitoring()
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
        livenessTask?.cancel()
        livenessTask = nil
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
        capturedSampleCount = await consumer?.canonicalSampleCount ?? 0
        clearPipelineReferences()
        state = .stopped(
            outputURL: outputURL,
            droppedSampleCount: droppedSampleCount
        )
        return outputURL
    }

    private func currentCaptureRoute(
        reason: MicrophoneInputRouteChangeReason
    ) throws -> ResolvedMicrophoneCaptureRoute {
        let inputNode = engine.inputNode
        let resolver = MicrophoneInputRouteResolver(
            defaultInputDevice: CoreAudioProperties.defaultInputDevice,
            inputDeviceIdentity: CoreAudioProperties.inputDeviceIdentity,
            bindAndVerify: { deviceID in
                guard let audioUnit = inputNode.audioUnit else {
                    throw AudioCaptureError.microphoneInputUnavailable
                }
                try CoreAudioProperties.bindInputDevice(
                    deviceID,
                    to: audioUnit
                )
            },
            boundInputFormat: {
                inputNode.inputFormat(forBus: 0)
            }
        )
        return try resolver.resolve(reason: reason)
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

    /// Watches the realtime accepted-frame counter and rebuilds the input route
    /// when the installed tap is not delivering.
    ///
    /// A tap installed against a Bluetooth device that is still switching into
    /// headset mode reports no error and keeps `AVAudioEngine.isRunning` true
    /// while delivering nothing, and no Core Audio property distinguishes that
    /// transient state from a settled one. Arriving frames are the only
    /// trustworthy evidence that capture works, and they arrive in silence too,
    /// so this never mistakes a quiet room for a fault.
    private func startLivenessMonitoring() {
        livenessTask?.cancel()
        lastAcceptedFrameCount = 0
        lastFrameProgressAt = ContinuousClock.now
        consecutiveRebuilds = 0

        let interval = livenessPolicy.pollInterval
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self else {
                    return
                }
                await self.evaluateCaptureLiveness()
            }
        }
    }

    private func evaluateCaptureLiveness() async {
        guard
            case .recording = state,
            !isRecovering,
            !isSleeping,
            let acceptedFrameCounter,
            let lastProgress = lastFrameProgressAt
        else {
            return
        }

        let acceptedFrameCount = acceptedFrameCounter.value
        if acceptedFrameCount > lastAcceptedFrameCount {
            lastAcceptedFrameCount = acceptedFrameCount
            lastFrameProgressAt = ContinuousClock.now
            consecutiveRebuilds = 0
            return
        }

        let decision = livenessPolicy.decide(
            hasCapturedAudio: acceptedFrameCount > 0,
            sinceLastAcceptedFrame: ContinuousClock.now - lastProgress,
            consecutiveRebuilds: consecutiveRebuilds
        )

        switch decision {
        case .keepWaiting:
            return
        case .rebuildRoute:
            consecutiveRebuilds += 1
            await recoverAfterInterruption(
                reason: acceptedFrameCount > 0
                    ? "The microphone stopped sending audio. Rebuilding the input route."
                    : "Waiting for the microphone to start sending audio.",
                routeReason: .captureDeliveredNoAudio
            )
            // The rebuilt tap earns its own grace period.
            lastFrameProgressAt = ContinuousClock.now
        case .failNoAudio:
            await failBecauseMicrophoneDeliveredNoAudio()
        }
    }

    private func failBecauseMicrophoneDeliveredNoAudio() async {
        let attempts = consecutiveRebuilds
        livenessTask?.cancel()
        livenessTask = nil
        stopEngineAndRemoveTap()
        unregisterForInterruptions()
        drainTask?.cancel()
        if let drainTask {
            await drainTask.value
        }

        var message = AudioCaptureError
            .microphoneDeliveredNoAudio(rebuildAttempts: attempts)
            .localizedDescription
        if let consumer {
            do {
                try await consumer.finish()
            } catch {
                message += " Finalizing the captured audio also failed: \(error.localizedDescription)"
            }
        }

        capturedSampleCount = acceptedFrameCounter?.value ?? 0
        clearPipelineReferences()
        state = .failed(message: message)
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

        capturedSampleCount = acceptedFrameCounter?.value ?? 0
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
        await recoverAfterInterruption(
            reason: "The audio input device changed.",
            routeReason: .inputConfigurationChanged
        )
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
        await recoverAfterInterruption(
            reason: "The Mac woke from sleep.",
            routeReason: .wakeRecovery
        )
    }

    private func recoverAfterInterruption(
        reason: String,
        routeReason: MicrophoneInputRouteChangeReason
    ) async {
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
            let resolvedRoute = try await restartAfterInputRouteChange(
                reason: routeReason,
                consumer: consumer,
                realtimeSink: realtimeSink
            )
            recordInputRouteChangeIfNeeded(resolvedRoute.change)
            isRecovering = false
            state = .recording(outputURL: outputURL)
        } catch {
            let message = error.localizedDescription
            await failAfterRecovery(message: message)
        }
    }

    private func restartAfterInputRouteChange(
        reason: MicrophoneInputRouteChangeReason,
        consumer: CanonicalAudioFileConsumer,
        realtimeSink: MicrophoneRealtimeSink
    ) async throws -> ResolvedMicrophoneCaptureRoute {
        let maximumAttemptCount = 30
        var mostRecentError: (any Error)?

        for attempt in 0..<maximumAttemptCount {
            stopEngineAndRemoveTap()
            do {
                let resolvedRoute = try currentCaptureRoute(reason: reason)
                let captureFormat = resolvedRoute.tapFormat
                try await consumer.reconfigure(
                    inputSampleRate: captureFormat.sampleRate
                )
                try installTap(format: captureFormat, sink: realtimeSink)
                engine.prepare()
                try engine.start()
                return resolvedRoute
            } catch {
                mostRecentError = error
                stopEngineAndRemoveTap()
                guard
                    attempt + 1 < maximumAttemptCount,
                    shouldRetryInputRouteRecovery(after: error)
                else {
                    throw error
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        throw mostRecentError ?? AudioCaptureError.microphoneInputUnavailable
    }

    private func shouldRetryInputRouteRecovery(after error: any Error) -> Bool {
        guard let captureError = error as? AudioCaptureError else {
            return true
        }
        switch captureError {
        case .microphoneInputResolvedToSystemTap,
            .microphoneInputDeviceBindingMismatch,
            .microphoneFormatUnsupported:
            return false
        default:
            return true
        }
    }

    private func recordInputRouteChangeIfNeeded(
        _ change: MicrophoneInputRouteChange
    ) {
        selectedInputDevice = change.device
        guard
            inputRouteChanges.last?.hasSameCaptureRoute(as: change) != true
        else {
            return
        }
        inputRouteChanges.append(change)
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
        livenessTask?.cancel()
        livenessTask = nil
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

        capturedSampleCount = acceptedFrameCounter?.value ?? 0
        clearPipelineReferences()
        isRecovering = false
        state = .failed(
            message: AudioCaptureError
                .microphoneRecoveryFailed(finalMessage)
                .localizedDescription
        )
    }

    private func shutDownPipelineAfterFailure() async -> String? {
        livenessTask?.cancel()
        livenessTask = nil
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
        capturedSampleCount = acceptedFrameCounter?.value ?? 0
        clearPipelineReferences()
        return cleanupMessage
    }

    private func clearPipelineReferences() {
        livenessTask?.cancel()
        livenessTask = nil
        ringBuffer = nil
        realtimeSink = nil
        firstSampleTime = nil
        acceptedFrameCounter = nil
        consumer = nil
        drainTask = nil
        outputURL = nil
        isSleeping = false
        isRecovering = false
        lastAcceptedFrameCount = 0
        lastFrameProgressAt = nil
        consecutiveRebuilds = 0
    }
}

struct ResolvedMicrophoneCaptureRoute {
    let tapFormat: AVAudioFormat
    let change: MicrophoneInputRouteChange
}

struct MicrophoneInputRouteResolver {
    let defaultInputDevice: () throws -> AudioDeviceID
    let inputDeviceIdentity:
        (AudioDeviceID) throws -> MicrophoneInputDeviceIdentity
    let bindAndVerify: (AudioDeviceID) throws -> Void
    let boundInputFormat: () -> AVAudioFormat
    let now: () -> Date

    init(
        defaultInputDevice: @escaping () throws -> AudioDeviceID,
        inputDeviceIdentity: @escaping (AudioDeviceID) throws
            -> MicrophoneInputDeviceIdentity,
        bindAndVerify: @escaping (AudioDeviceID) throws -> Void,
        boundInputFormat: @escaping () -> AVAudioFormat,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaultInputDevice = defaultInputDevice
        self.inputDeviceIdentity = inputDeviceIdentity
        self.bindAndVerify = bindAndVerify
        self.boundInputFormat = boundInputFormat
        self.now = now
    }

    func resolve(
        reason: MicrophoneInputRouteChangeReason
    ) throws -> ResolvedMicrophoneCaptureRoute {
        let deviceID = try defaultInputDevice()
        let identity = try inputDeviceIdentity(deviceID)
        guard !identity.uid.hasPrefix("com.localfirst.Scribe.SystemTap.") else {
            throw AudioCaptureError.microphoneInputResolvedToSystemTap
        }

        try bindAndVerify(deviceID)
        let format = boundInputFormat()
        guard
            format.sampleRate.isFinite,
            format.sampleRate > 0,
            format.channelCount > 0
        else {
            throw AudioCaptureError.microphoneInputUnavailable
        }
        guard
            format.commonFormat == .pcmFormatFloat32,
            !format.isInterleaved
        else {
            throw AudioCaptureError.microphoneFormatUnsupported
        }

        return ResolvedMicrophoneCaptureRoute(
            tapFormat: format,
            change: MicrophoneInputRouteChange(
                recordedAt: now(),
                reason: reason,
                device: identity,
                inputSampleRate: format.sampleRate,
                inputChannelCount: format.channelCount
            )
        )
    }
}

private final class MicrophoneRealtimeSink: @unchecked Sendable {
    private let ringBuffer: FloatRingBuffer
    private let firstSampleTime: FirstSampleHostTime
    private let acceptedFrameCounter: RealtimeCallbackCounter

    init(
        ringBuffer: FloatRingBuffer,
        firstSampleTime: FirstSampleHostTime,
        acceptedFrameCounter: RealtimeCallbackCounter
    ) {
        self.ringBuffer = ringBuffer
        self.firstSampleTime = firstSampleTime
        self.acceptedFrameCounter = acceptedFrameCounter
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
        if written > 0 {
            acceptedFrameCounter.add(UInt64(written))
            if time.isHostTimeValid {
                firstSampleTime.capture(time.hostTime)
            }
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

    public func microphoneInputRouteChanges() async
        -> [MicrophoneInputRouteChange]
    {
        inputRouteChanges
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
            capturedSampleCount: capturedSampleCount,
            firstSampleHostTime: capturedFirstSampleHostTime
        )
    }
}
