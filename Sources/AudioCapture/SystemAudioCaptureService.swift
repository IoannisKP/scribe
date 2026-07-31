@preconcurrency import AppKit
@preconcurrency import CoreAudio
import Foundation

public enum SystemAudioCaptureState: Equatable, Sendable {
    case idle
    case starting
    case recording(outputURL: URL)
    case recovering(reason: String, outputURL: URL)
    case stopping
    case stopped(outputURL: URL, droppedSampleCount: UInt64)
    case failed(message: String)

    public var isActive: Bool {
        switch self {
        case .starting, .recording, .recovering, .stopping:
            true
        case .idle, .stopped, .failed:
            false
        }
    }
}

public actor SystemAudioCaptureService: AudioTrackCapturing {
    public private(set) var state: SystemAudioCaptureState = .idle

    private let listenerQueue = DispatchQueue(
        label: "com.localfirst.Scribe.system-audio-listeners",
        qos: .userInitiated
    )

    private var ringBuffer: FloatRingBuffer?
    private var consumer: CanonicalAudioFileConsumer?
    private var drainTask: Task<Void, Never>?
    private var graph: CoreAudioSystemTapGraph?
    private var outputURL: URL?
    private var isRecovering = false
    private var isSleeping = false
    private var coreAudioListeners: [CoreAudioListenerRegistration] = []
    private var workspaceObservers: [SystemWorkspaceObserver] = []
    private let permissionRecorder: any SystemAudioPermissionRecording
    private let liveSink: (any CanonicalAudioBlockSink)?

    public init(
        permissionRecorder: any SystemAudioPermissionRecording =
            SystemAudioPermissionAuthorizer(),
        liveSink: (any CanonicalAudioBlockSink)? = nil
    ) {
        self.permissionRecorder = permissionRecorder
        self.liveSink = liveSink
    }

    public func startRecording(to outputURL: URL) async throws {
        guard !state.isActive else {
            throw AudioCaptureError.systemCaptureAlreadyRunning
        }

        state = .starting
        do {
            // Ten seconds at the highest conventional Core Audio hardware rate.
            let ringBuffer = try FloatRingBuffer(capacity: 1_920_000)
            let graph = CoreAudioSystemTapGraph(ringBuffer: ringBuffer)
            try graph.prepare()
            self.graph = graph

            let consumer = try CanonicalAudioFileConsumer(
                source: .system,
                ringBuffer: ringBuffer,
                inputSampleRate: graph.sampleRate,
                outputURL: outputURL,
                liveSink: liveSink
            )
            self.ringBuffer = ringBuffer
            self.consumer = consumer
            self.outputURL = outputURL
            startDrainTask(consumer: consumer)
            try registerCoreAudioListeners(for: graph)
            registerWorkspaceObservers()
            try graph.start()
            await permissionRecorder.recordAuthorizationStatus(.authorized)
            state = .recording(outputURL: outputURL)
        } catch {
            if error as? AudioCaptureError
                == .systemAudioPermissionDenied
            {
                await permissionRecorder.recordAuthorizationStatus(.denied)
            }
            let cleanupMessage = await shutDownPipelineAfterFailure()
            let originalMessage = error.localizedDescription
            let combinedMessage = cleanupMessage.map {
                "\(originalMessage) Cleanup also failed: \($0)"
            } ?? originalMessage
            state = .failed(message: combinedMessage)

            if let captureError = error as? AudioCaptureError {
                throw captureError
            }
            throw AudioCaptureError.coreAudioOperationFailed(
                operation: "Starting system-audio capture",
                status: kAudioHardwareUnspecifiedError,
                statusDescription: combinedMessage
            )
        }
    }

    public func stopCapture() async throws -> AudioTrackCaptureResult {
        guard state.isActive, let outputURL else {
            throw AudioCaptureError.systemCaptureNotRunning
        }

        state = .stopping
        var failures: [String] = []
        failures.append(contentsOf: unregisterCoreAudioListeners())
        unregisterWorkspaceObservers()

        if let graph {
            do {
                try graph.tearDown()
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        self.graph = nil

        drainTask?.cancel()
        if let drainTask {
            await drainTask.value
        }
        self.drainTask = nil

        if let consumer {
            do {
                try await consumer.finish()
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        let droppedSampleCount = ringBuffer?.droppedSampleCount ?? 0
        let result = AudioTrackCaptureResult(
            source: .system,
            outputURL: outputURL,
            droppedSampleCount: droppedSampleCount
        )
        clearPipelineReferences()

        if !failures.isEmpty {
            let message = failures.joined(separator: " ")
            state = .failed(message: message)
            throw AudioCaptureError.systemGraphTeardownFailed(message)
        }

        state = .stopped(
            outputURL: outputURL,
            droppedSampleCount: droppedSampleCount
        )
        return result
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
        case .idle, .starting, .stopping, .stopped, .failed:
            return
        }

        var finalMessage = message
        let listenerFailures = unregisterCoreAudioListeners()
        if !listenerFailures.isEmpty {
            finalMessage += " " + listenerFailures.joined(separator: " ")
        }
        unregisterWorkspaceObservers()

        if let graph {
            do {
                try graph.tearDown()
            } catch {
                finalMessage += " \(error.localizedDescription)"
            }
        }
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
                .audioConsumerFailed(finalMessage)
                .localizedDescription
        )
    }

    private func registerCoreAudioListeners(
        for graph: CoreAudioSystemTapGraph
    ) throws {
        guard coreAudioListeners.isEmpty else {
            return
        }

        try addCoreAudioListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            reason: "The default output device changed."
        )
        try addCoreAudioListener(
            objectID: graph.aggregateDeviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            reason: "The private system-audio aggregate device changed."
        )
        try addCoreAudioListener(
            objectID: graph.tapID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            reason: "The system-audio tap format changed."
        )
        try addCoreAudioListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyServiceRestarted,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            reason: "The Core Audio service restarted."
        )
    }

    private func addCoreAudioListener(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        reason: String
    ) throws {
        let listenerBlock: AudioObjectPropertyListenerBlock = {
            [weak self] _, _ in
            guard let self else {
                return
            }
            Task {
                await self.handleCoreAudioChange(reason: reason)
            }
        }
        var mutableAddress = address
        try CoreAudioCallError.check(
            AudioObjectAddPropertyListenerBlock(
                objectID,
                &mutableAddress,
                listenerQueue,
                listenerBlock
            ),
            operation: "Registering a Core Audio recovery listener"
        )
        coreAudioListeners.append(
            CoreAudioListenerRegistration(
                objectID: objectID,
                address: address,
                queue: listenerQueue,
                block: listenerBlock
            )
        )
    }

    private func unregisterCoreAudioListeners() -> [String] {
        var failures: [String] = []
        for registration in coreAudioListeners {
            var address = registration.address
            let status = AudioObjectRemovePropertyListenerBlock(
                registration.objectID,
                &address,
                registration.queue,
                registration.block
            )
            if status != noErr {
                failures.append(
                    CoreAudioCallError(
                        operation: "Removing a Core Audio recovery listener",
                        status: status
                    ).localizedDescription
                )
            }
        }
        coreAudioListeners.removeAll(keepingCapacity: true)
        return failures
    }

    private func registerWorkspaceObservers() {
        guard workspaceObservers.isEmpty else {
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        let sleepToken = center.addObserver(
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
        workspaceObservers.append(
            SystemWorkspaceObserver(center: center, token: sleepToken)
        )

        let wakeToken = center.addObserver(
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
        workspaceObservers.append(
            SystemWorkspaceObserver(center: center, token: wakeToken)
        )
    }

    private func unregisterWorkspaceObservers() {
        for observer in workspaceObservers {
            observer.center.removeObserver(observer.token)
        }
        workspaceObservers.removeAll(keepingCapacity: true)
    }

    private func handleCoreAudioChange(reason: String) async {
        guard state.isActive, !isRecovering, !isSleeping else {
            return
        }
        await recoverGraph(reason: reason)
    }

    private func handleWillSleep() async {
        guard
            state.isActive,
            !isSleeping,
            let outputURL
        else {
            return
        }

        isSleeping = true
        isRecovering = true
        state = .recovering(
            reason: "System audio is paused while this Mac sleeps.",
            outputURL: outputURL
        )

        let listenerFailures = unregisterCoreAudioListeners()
        if !listenerFailures.isEmpty {
            await failRecovery(
                message: listenerFailures.joined(separator: " ")
            )
            return
        }
        if let graph {
            do {
                try graph.tearDown()
                self.graph = nil
            } catch {
                await failRecovery(message: error.localizedDescription)
            }
        }
    }

    private func handleDidWake() async {
        guard state.isActive, isSleeping else {
            return
        }
        isSleeping = false
        isRecovering = false
        await recoverGraph(reason: "The Mac woke from sleep.")
    }

    private func recoverGraph(reason: String) async {
        guard
            let ringBuffer,
            let consumer,
            let outputURL
        else {
            return
        }

        isRecovering = true
        state = .recovering(reason: reason, outputURL: outputURL)
        let listenerFailures = unregisterCoreAudioListeners()

        do {
            guard listenerFailures.isEmpty else {
                throw AudioCaptureError.systemGraphTeardownFailed(
                    listenerFailures.joined(separator: " ")
                )
            }
            if let graph {
                try graph.tearDown()
                self.graph = nil
            }
            try await waitUntilDrained(ringBuffer)

            let replacementGraph = CoreAudioSystemTapGraph(
                ringBuffer: ringBuffer
            )
            try replacementGraph.prepare()
            try await consumer.reconfigure(
                inputSampleRate: replacementGraph.sampleRate
            )
            self.graph = replacementGraph
            try registerCoreAudioListeners(for: replacementGraph)
            try replacementGraph.start()
            isRecovering = false
            state = .recording(outputURL: outputURL)
        } catch {
            await failRecovery(message: error.localizedDescription)
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

    private func failRecovery(message: String) async {
        var finalMessage = message
        let listenerFailures = unregisterCoreAudioListeners()
        if !listenerFailures.isEmpty {
            finalMessage += " " + listenerFailures.joined(separator: " ")
        }
        unregisterWorkspaceObservers()

        if let graph {
            do {
                try graph.tearDown()
            } catch {
                finalMessage += " \(error.localizedDescription)"
            }
        }
        drainTask?.cancel()
        if let drainTask {
            await drainTask.value
        }
        if let consumer {
            do {
                try await consumer.finish()
            } catch {
                finalMessage += " Finalizing captured audio failed: \(error.localizedDescription)"
            }
        }

        clearPipelineReferences()
        state = .failed(
            message: AudioCaptureError
                .systemRecoveryFailed(finalMessage)
                .localizedDescription
        )
    }

    private func shutDownPipelineAfterFailure() async -> String? {
        var failures: [String] = []
        failures.append(contentsOf: unregisterCoreAudioListeners())
        unregisterWorkspaceObservers()

        if let graph {
            do {
                try graph.tearDown()
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        drainTask?.cancel()
        if let drainTask {
            await drainTask.value
        }
        if let consumer {
            do {
                try await consumer.finish()
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        clearPipelineReferences()
        return failures.isEmpty ? nil : failures.joined(separator: " ")
    }

    private func clearPipelineReferences() {
        ringBuffer = nil
        consumer = nil
        drainTask = nil
        graph = nil
        outputURL = nil
        isRecovering = false
        isSleeping = false
    }
}

private struct CoreAudioListenerRegistration: @unchecked Sendable {
    let objectID: AudioObjectID
    let address: AudioObjectPropertyAddress
    let queue: DispatchQueue
    let block: AudioObjectPropertyListenerBlock
}

private struct SystemWorkspaceObserver: @unchecked Sendable {
    let center: NotificationCenter
    let token: any NSObjectProtocol
}
