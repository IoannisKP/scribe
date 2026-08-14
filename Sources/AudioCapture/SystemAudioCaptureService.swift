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

public enum SystemAudioPrewarmState: Equatable, Sendable {
    case idle
    case preparing
    case ready
    case inUse
    case failed(message: String)
}

public actor SystemAudioCaptureService: AudioTrackCapturing {
    public private(set) var state: SystemAudioCaptureState = .idle
    public private(set) var prewarmState: SystemAudioPrewarmState = .idle

    private let listenerQueue = DispatchQueue(
        label: "com.localfirst.Scribe.system-audio-listeners",
        qos: .userInitiated
    )

    private var ringBuffer: FloatRingBuffer?
    private var consumer: CanonicalAudioFileConsumer?
    private var drainTask: Task<Void, Never>?
    private var graph: CoreAudioSystemTapGraph?
    private var realtimeRouter: SystemAudioRealtimeRouter?
    private var firstSampleTime: FirstSampleHostTime?
    private var recordedStartupStageTimings: [SystemAudioStartupStageTiming] = []
    private var recordedGraphPreparation: SystemAudioGraphPreparation?
    private var outputURL: URL?
    private var isRecovering = false
    private var isSleeping = false
    private var isRebuildingPreparedGraph = false
    private var coreAudioListeners: [CoreAudioListenerRegistration] = []
    private var workspaceObservers: [SystemWorkspaceObserver] = []
    private let permissionRecorder: any SystemAudioPermissionRecording
    private let liveSink: (any CanonicalAudioBlockSink)?
    private let prewarmGate = SingleFlightPreparation<PreparedSystemAudioGraph>()

    public init(
        permissionRecorder: any SystemAudioPermissionRecording =
            SystemAudioPermissionAuthorizer(),
        liveSink: (any CanonicalAudioBlockSink)? = nil
    ) {
        self.permissionRecorder = permissionRecorder
        self.liveSink = liveSink
    }

    /// Prepares the private process tap, aggregate device, and unstarted
    /// IOProc. Audio storage and writing remain unallocated until recording.
    public func prewarm() async {
        guard
            !state.isActive,
            !isSleeping
        else {
            return
        }

        do {
            _ = try await ensurePreparedGraph()
        } catch is CancellationError {
            if !isSleeping {
                prewarmState = .idle
            }
        } catch {
            let message = error.localizedDescription
            prewarmState = .failed(message: message)
        }
    }

    public func startRecording(to outputURL: URL) async throws {
        guard !state.isActive else {
            throw AudioCaptureError.systemCaptureAlreadyRunning
        }

        let preparationWasAlreadyUnderway =
            prewarmState == .preparing
            || (graph != nil && realtimeRouter != nil)
        state = .starting
        recordedStartupStageTimings = []
        recordedGraphPreparation = nil
        var serviceProfiler = SystemAudioStartupProfiler()
        do {
            let recordingStartedPreparation = try await ensurePreparedGraph()
            recordedGraphPreparation = preparationWasAlreadyUnderway
                || !recordingStartedPreparation
                ? .prewarmed
                : .builtAtRecordingStart

            // Ten seconds at the highest conventional Core Audio hardware rate.
            let ringBuffer = try FloatRingBuffer(capacity: 1_920_000)
            let firstSampleTime = try FirstSampleHostTime()
            guard
                let graph = self.graph,
                let realtimeRouter = self.realtimeRouter,
                !graph.isStarted,
                !realtimeRouter.isAttached
            else {
                throw AudioCaptureError.coreAudioOperationFailed(
                    operation: "Using the prepared system-audio graph",
                    status: kAudioHardwareUnspecifiedError,
                    statusDescription:
                        "The shared preparation completed without a reusable graph."
                )
            }
            realtimeRouter.attach(
                ringBuffer: ringBuffer,
                firstSampleTime: firstSampleTime
            )
            prewarmState = .inUse
            recordedStartupStageTimings = graph.startupStageTimings.filter {
                $0.stage != .audioDeviceStart
            }

            let writer = try serviceProfiler.measure(
                .wavWriterCreationAndHeaderFlush
            ) {
                try Int16WAVWriter(url: outputURL)
            }
            recordedStartupStageTimings.append(
                contentsOf: serviceProfiler.timings
            )
            // prepare() ran at launch, and the tap's advertised format does
            // not track a Bluetooth output switching into headset mode. The
            // aggregate clocks off the output subdevice, so read that.
            try graph.refreshTapFormat()
            let tapSampleRate = try graph.currentDeliveredSampleRate()
            let consumer = try CanonicalAudioFileConsumer(
                source: .system,
                ringBuffer: ringBuffer,
                inputSampleRate: tapSampleRate,
                outputURL: outputURL,
                writer: writer,
                liveSink: liveSink
            )
            self.ringBuffer = ringBuffer
            self.firstSampleTime = firstSampleTime
            self.consumer = consumer
            self.outputURL = outputURL
            startDrainTask(consumer: consumer)
            serviceProfiler = SystemAudioStartupProfiler()
            try serviceProfiler.measure(.listenerRegistration) {
                try registerCoreAudioListeners(for: graph)
                registerWorkspaceObservers()
            }
            recordedStartupStageTimings.append(
                contentsOf: serviceProfiler.timings
            )
            try graph.start()
            if let startTiming = graph.startupStageTimings.last(where: {
                $0.stage == .audioDeviceStart
            }) {
                recordedStartupStageTimings.append(startTiming)
            }
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
            prewarmState = .failed(message: combinedMessage)
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
        if let graph {
            do {
                try graph.stop()
                realtimeRouter?.detach()
            } catch {
                failures.append(error.localizedDescription)
            }
        }

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
        let capturedFirstSampleHostTime = firstSampleTime?.value
        let result = AudioTrackCaptureResult(
            source: .system,
            outputURL: outputURL,
            droppedSampleCount: droppedSampleCount,
            firstSampleHostTime: capturedFirstSampleHostTime
        )
        if !failures.isEmpty {
            await prewarmGate.clear(cancelling: true)
            failures.append(contentsOf: unregisterCoreAudioListeners())
            unregisterWorkspaceObservers()
            if let graph {
                do {
                    try graph.tearDown()
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            realtimeRouter?.detach()
            self.graph = nil
            realtimeRouter = nil
            clearRecordingPipelineReferences()
            let message = failures.joined(separator: " ")
            prewarmState = .failed(message: message)
            state = .failed(message: message)
            throw AudioCaptureError.systemGraphTeardownFailed(message)
        }

        clearRecordingPipelineReferences()
        prewarmState = graph != nil && realtimeRouter != nil
            ? .ready
            : .idle
        state = .stopped(
            outputURL: outputURL,
            droppedSampleCount: droppedSampleCount
        )
        return result
    }

    public func firstSampleHostTime() async -> UInt64? {
        firstSampleTime?.value
    }

    public func systemStartupStageTimings() async
        -> [SystemAudioStartupStageTiming]
    {
        recordedStartupStageTimings
    }

    public func systemAudioGraphPreparation() async
        -> SystemAudioGraphPreparation?
    {
        recordedGraphPreparation
    }

    /// Returns true only to the caller that created the shared operation.
    /// Other callers await that exact operation and reuse its graph.
    private func ensurePreparedGraph() async throws -> Bool {
        if
            let graph,
            let realtimeRouter,
            !graph.isStarted,
            !realtimeRouter.isAttached
        {
            prewarmState = .ready
            return false
        }

        prewarmState = .preparing
        let result: SingleFlightPreparation<PreparedSystemAudioGraph>.Result
        do {
            result = try await prewarmGate.value {
                let realtimeRouter = try SystemAudioRealtimeRouter()
                let graph = CoreAudioSystemTapGraph(
                    realtimeRouter: realtimeRouter
                )
                do {
                    try graph.prepare()
                    return PreparedSystemAudioGraph(
                        graph: graph,
                        realtimeRouter: realtimeRouter
                    )
                } catch {
                    try? graph.tearDown()
                    realtimeRouter.detach()
                    throw error
                }
            }
        } catch {
            await prewarmGate.clear(cancelling: false)
            throw error
        }

        guard await prewarmGate.isCurrent(result.operationID) else {
            try? result.value.graph.tearDown()
            result.value.realtimeRouter.detach()
            throw CancellationError()
        }

        if graph == nil, realtimeRouter == nil {
            do {
                try registerCoreAudioListeners(for: result.value.graph)
                registerWorkspaceObservers()
                graph = result.value.graph
                realtimeRouter = result.value.realtimeRouter
                recordedStartupStageTimings =
                    result.value.graph.startupStageTimings
            } catch {
                try? result.value.graph.tearDown()
                result.value.realtimeRouter.detach()
                await prewarmGate.clear(
                    operationID: result.operationID,
                    cancelling: false
                )
                throw error
            }
        }

        prewarmState = .ready
        return result.startedNewOperation
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
        await prewarmGate.clear(cancelling: true)
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
        realtimeRouter?.detach()
        if let consumer {
            do {
                try await consumer.finalizeAfterBackgroundFailure()
            } catch {
                finalMessage += " Finalizing the WAV also failed: \(error.localizedDescription)"
            }
        }

        clearAllPipelineReferences()
        prewarmState = .failed(message: finalMessage)
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
            objectID: graph.outputDeviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            reason: "The output device changed sample rate."
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
        guard !isRecovering, !isSleeping else {
            return
        }
        if state.isActive {
            await recoverGraph(reason: reason)
        } else {
            await rebuildPreparedGraph(reason: reason)
        }
    }

    private func handleWillSleep() async {
        guard !isSleeping else {
            return
        }

        isSleeping = true
        await prewarmGate.clear(cancelling: true)
        guard state.isActive, let outputURL else {
            _ = unregisterCoreAudioListeners()
            if let graph {
                try? graph.tearDown()
            }
            realtimeRouter?.detach()
            graph = nil
            realtimeRouter = nil
            prewarmState = .idle
            return
        }

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
                realtimeRouter?.detach()
                realtimeRouter = nil
            } catch {
                await failRecovery(message: error.localizedDescription)
            }
        }
    }

    private func handleDidWake() async {
        guard isSleeping else {
            return
        }
        isSleeping = false
        if state.isActive {
            isRecovering = false
            await recoverGraph(reason: "The Mac woke from sleep.")
        } else {
            await prewarm()
        }
    }

    private func rebuildPreparedGraph(reason: String) async {
        guard
            !state.isActive,
            !isRebuildingPreparedGraph,
            graph != nil || realtimeRouter != nil
        else {
            return
        }

        isRebuildingPreparedGraph = true
        prewarmState = .preparing
        await prewarmGate.clear(cancelling: true)
        _ = unregisterCoreAudioListeners()
        if let graph {
            try? graph.tearDown()
        }
        realtimeRouter?.detach()
        graph = nil
        realtimeRouter = nil
        isRebuildingPreparedGraph = false
        await prewarm()
    }

    private func recoverGraph(reason: String) async {
        guard
            let ringBuffer,
            let consumer,
            let outputURL,
            let firstSampleTime
        else {
            return
        }

        isRecovering = true
        state = .recovering(reason: reason, outputURL: outputURL)
        await prewarmGate.clear(cancelling: true)
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
            realtimeRouter?.detach()
            realtimeRouter = nil
            try await waitUntilDrained(ringBuffer)

            let replacementRouter = try SystemAudioRealtimeRouter()
            replacementRouter.attach(
                ringBuffer: ringBuffer,
                firstSampleTime: firstSampleTime
            )
            let replacementGraph = CoreAudioSystemTapGraph(
                realtimeRouter: replacementRouter
            )
            try replacementGraph.prepare()
            try await consumer.reconfigure(
                inputSampleRate: (
                    try? replacementGraph.currentDeliveredSampleRate()
                ) ?? replacementGraph.sampleRate
            )
            self.realtimeRouter = replacementRouter
            self.graph = replacementGraph
            try registerCoreAudioListeners(for: replacementGraph)
            try replacementGraph.start()
            prewarmState = .inUse
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
        await prewarmGate.clear(cancelling: true)
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
        realtimeRouter?.detach()
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

        clearAllPipelineReferences()
        prewarmState = .failed(message: finalMessage)
        state = .failed(
            message: AudioCaptureError
                .systemRecoveryFailed(finalMessage)
                .localizedDescription
        )
    }

    private func shutDownPipelineAfterFailure() async -> String? {
        var failures: [String] = []
        await prewarmGate.clear(cancelling: true)
        failures.append(contentsOf: unregisterCoreAudioListeners())
        unregisterWorkspaceObservers()

        if let graph {
            do {
                try graph.tearDown()
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        realtimeRouter?.detach()

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

        clearAllPipelineReferences()
        return failures.isEmpty ? nil : failures.joined(separator: " ")
    }

    private func clearRecordingPipelineReferences() {
        ringBuffer = nil
        firstSampleTime = nil
        consumer = nil
        drainTask = nil
        outputURL = nil
        isRecovering = false
    }

    private func clearAllPipelineReferences() {
        clearRecordingPipelineReferences()
        graph = nil
        realtimeRouter = nil
        isSleeping = false
        isRebuildingPreparedGraph = false
    }
}

private struct PreparedSystemAudioGraph: @unchecked Sendable {
    let graph: CoreAudioSystemTapGraph
    let realtimeRouter: SystemAudioRealtimeRouter
}

/// Owns exactly one asynchronous preparation operation. Callers arriving
/// while it runs await the same task instead of creating competing graphs.
actor SingleFlightPreparation<Value: Sendable> {
    struct Result: Sendable {
        let value: Value
        let operationID: UUID
        let startedNewOperation: Bool
    }

    private struct Operation: Sendable {
        let id: UUID
        let task: Task<Value, any Error>
    }

    private var operation: Operation?

    func value(
        operation create: @escaping @Sendable () async throws -> Value
    ) async throws -> Result {
        let selected: Operation
        let startedNewOperation: Bool
        if let operation {
            selected = operation
            startedNewOperation = false
        } else {
            selected = Operation(
                id: UUID(),
                task: Task.detached(priority: .userInitiated) {
                    try await create()
                }
            )
            operation = selected
            startedNewOperation = true
        }

        return try await Result(
            value: selected.task.value,
            operationID: selected.id,
            startedNewOperation: startedNewOperation
        )
    }

    func isCurrent(_ operationID: UUID) -> Bool {
        operation?.id == operationID
    }

    func clear(
        operationID: UUID? = nil,
        cancelling: Bool
    ) {
        guard
            operationID == nil || operation?.id == operationID
        else {
            return
        }
        if cancelling {
            operation?.task.cancel()
        }
        operation = nil
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
