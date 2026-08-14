@preconcurrency import AVFoundation
@preconcurrency import CoreAudio
#if canImport(CAudioRingBuffer)
import CAudioRingBuffer
#endif
import Darwin
import Foundation

final class CoreAudioSystemTapGraph: @unchecked Sendable {
    enum TapScope: Sendable {
        case excludingCurrentProcess
        case allProcesses
    }

    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private(set) var ioProcID: AudioDeviceIOProcID?
    private(set) var outputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private(set) var sampleRate: Double = 0
    private(set) var isStarted = false
    private(set) var startupStageTimings: [SystemAudioStartupStageTiming] = []

    private let realtimeRouter: SystemAudioRealtimeRouter?
    private let diagnosticCallbackCounter: RealtimeCallbackCounter?
    private let tapScope: TapScope

    init(
        ringBuffer: FloatRingBuffer,
        firstSampleTime: FirstSampleHostTime,
        tapScope: TapScope = .excludingCurrentProcess
    ) throws {
        let realtimeRouter = try SystemAudioRealtimeRouter()
        realtimeRouter.attach(
            ringBuffer: ringBuffer,
            firstSampleTime: firstSampleTime
        )
        self.realtimeRouter = realtimeRouter
        self.diagnosticCallbackCounter = nil
        self.tapScope = tapScope
    }

    init(
        realtimeRouter: SystemAudioRealtimeRouter,
        tapScope: TapScope = .excludingCurrentProcess
    ) {
        self.realtimeRouter = realtimeRouter
        self.diagnosticCallbackCounter = nil
        self.tapScope = tapScope
    }

    init(
        diagnosticCallbackCounter: RealtimeCallbackCounter,
        tapScope: TapScope = .excludingCurrentProcess
    ) {
        self.realtimeRouter = nil
        self.diagnosticCallbackCounter = diagnosticCallbackCounter
        self.tapScope = tapScope
    }

    deinit {
        try? tearDown()
    }

    func prepare() throws {
        guard tapID == kAudioObjectUnknown else {
            throw AudioCaptureError.systemCaptureAlreadyRunning
        }

        var profiler = SystemAudioStartupProfiler()
        defer {
            startupStageTimings = profiler.timings
        }
        do {
            outputDeviceID = try CoreAudioProperties.defaultOutputDevice()
            let outputDeviceUID = try CoreAudioProperties.deviceUID(outputDeviceID)
            let excludedProcessObjectIDs: [AudioObjectID]
            switch tapScope {
            case .excludingCurrentProcess:
                excludedProcessObjectIDs = [
                    try CoreAudioProperties.currentProcessObjectID()
                ]
            case .allProcesses:
                excludedProcessObjectIDs = []
            }

            let tapDescription = CATapDescription(
                monoGlobalTapButExcludeProcesses: excludedProcessObjectIDs
            )
            tapDescription.name = "Scribe System Audio \(UUID().uuidString)"
            tapDescription.isPrivate = true
            tapDescription.muteBehavior = .unmuted

            var newTapID = AudioObjectID(kAudioObjectUnknown)
            try profiler.measure(.processTapCreation) {
                try CoreAudioCallError.checkSystemAudio(
                    AudioHardwareCreateProcessTap(tapDescription, &newTapID),
                    operation: "Creating the system-audio process tap"
                )
            }
            tapID = newTapID

            var streamDescription = try profiler.measure(.tapFormatLookup) {
                try CoreAudioProperties.tapFormat(tapID)
            }
            guard
                streamDescription.mFormatID == kAudioFormatLinearPCM,
                streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                streamDescription.mBitsPerChannel == 32,
                streamDescription.mSampleRate.isFinite,
                streamDescription.mSampleRate > 0,
                streamDescription.mChannelsPerFrame == 1,
                withUnsafePointer(to: &streamDescription, {
                    AVAudioFormat(streamDescription: $0)
                }) != nil
            else {
                throw AudioCaptureError.systemTapFormatUnsupported
            }
            sampleRate = streamDescription.mSampleRate

            let aggregateDescription = SystemTapAggregateDescription.make(
                outputDeviceUID: outputDeviceUID,
                tapUID: tapDescription.uuid.uuidString,
                aggregateUID:
                    "com.localfirst.Scribe.SystemTap.\(UUID().uuidString)"
            )

            var newAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            try profiler.measure(.aggregateDeviceCreation) {
                try CoreAudioCallError.checkSystemAudio(
                    AudioHardwareCreateAggregateDevice(
                        aggregateDescription as CFDictionary,
                        &newAggregateDeviceID
                    ),
                    operation: "Creating the private system-audio aggregate device"
                )
            }
            aggregateDeviceID = newAggregateDeviceID

            var newIOProcID: AudioDeviceIOProcID?
            try profiler.measure(.ioProcRegistration) {
                try CoreAudioCallError.checkSystemAudio(
                    AudioDeviceCreateIOProcIDWithBlock(
                        &newIOProcID,
                        aggregateDeviceID,
                        nil
                    ) {
                        [realtimeRouter, diagnosticCallbackCounter]
                        _, inputData, inputTime, _, _ in
                        diagnosticCallbackCounter?.increment()
                        realtimeRouter?.receive(
                            inputData,
                            inputTime: inputTime
                        )
                    },
                    operation: "Registering the system-audio aggregate IOProc"
                )
            }
            guard let newIOProcID else {
                throw AudioCaptureError.coreAudioOperationFailed(
                    operation: "Registering the system-audio aggregate IOProc",
                    status: kAudioHardwareUnspecifiedError,
                    statusDescription: "Core Audio returned no IOProc identifier"
                )
            }
            ioProcID = newIOProcID
        } catch {
            let cleanupMessage = cleanupAfterSetupFailure()
            if let cleanupMessage {
                throw AudioCaptureError.systemGraphTeardownFailed(
                    "\(error.localizedDescription) Cleanup: \(cleanupMessage)"
                )
            }
            throw error
        }
    }

    func registerAdditionalDiagnosticIOProc(
        callbackCounter: RealtimeCallbackCounter
    ) throws -> (
        ioProcID: AudioDeviceIOProcID,
        timing: SystemAudioStartupStageTiming
    ) {
        guard aggregateDeviceID != kAudioObjectUnknown else {
            throw AudioCaptureError.systemCaptureNotRunning
        }

        var newIOProcID: AudioDeviceIOProcID?
        var profiler = SystemAudioStartupProfiler()
        try profiler.measure(.ioProcRegistration) {
            try CoreAudioCallError.checkSystemAudio(
                AudioDeviceCreateIOProcIDWithBlock(
                    &newIOProcID,
                    aggregateDeviceID,
                    nil
                ) { [callbackCounter] _, _, _, _, _ in
                    callbackCounter.increment()
                },
                operation: "Registering the comparison system-audio IOProc"
            )
        }
        guard let newIOProcID, let timing = profiler.timings.first else {
            throw AudioCaptureError.coreAudioOperationFailed(
                operation: "Registering the comparison system-audio IOProc",
                status: kAudioHardwareUnspecifiedError,
                statusDescription: "Core Audio returned no IOProc identifier"
            )
        }
        return (newIOProcID, timing)
    }

    func destroyAdditionalDiagnosticIOProc(
        _ ioProcID: AudioDeviceIOProcID
    ) throws {
        try CoreAudioCallError.check(
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID),
            operation: "Destroying the comparison system-audio IOProc"
        )
    }

    /// The rate the aggregate is actually clocking at, which is the rate the
    /// IOProc delivers frames at.
    ///
    /// Deliberately reads the output device rather than the tap. Measured on
    /// the affected AirPods, when the device switched into headset mode the
    /// output device moved 48000 -> 24000 while `kAudioTapPropertyFormat` kept
    /// reporting 48000 and its listener never fired. The aggregate clocks off
    /// this output subdevice, so its rate is what the resampler must be
    /// configured from; the tap's advertised format is not trustworthy for
    /// this purpose.
    func currentDeliveredSampleRate() throws -> Double {
        guard outputDeviceID != kAudioObjectUnknown else {
            throw AudioCaptureError.systemCaptureNotRunning
        }
        return try CoreAudioProperties.nominalSampleRate(outputDeviceID)
    }

    /// Re-reads `kAudioTapPropertyFormat` and returns the tap's current rate.
    ///
    /// `prepare()` runs at launch, so the rate it captured describes whichever
    /// output device was default then, at whichever rate that device was
    /// running. A Bluetooth output that switches into headset mode between
    /// launch and Record changes rate without changing which device is default,
    /// so nothing in the prepared graph is stale except this number, and a
    /// resampler configured from it decimates by the wrong factor for the whole
    /// session. Recording reads the live value instead of trusting the
    /// prewarmed one.
    @discardableResult
    func refreshTapFormat() throws -> Double {
        guard tapID != kAudioObjectUnknown else {
            throw AudioCaptureError.systemCaptureNotRunning
        }
        var streamDescription = try CoreAudioProperties.tapFormat(tapID)
        guard
            streamDescription.mFormatID == kAudioFormatLinearPCM,
            streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            streamDescription.mBitsPerChannel == 32,
            streamDescription.mSampleRate.isFinite,
            streamDescription.mSampleRate > 0,
            streamDescription.mChannelsPerFrame == 1,
            withUnsafePointer(to: &streamDescription, {
                AVAudioFormat(streamDescription: $0)
            }) != nil
        else {
            throw AudioCaptureError.systemTapFormatUnsupported
        }
        sampleRate = streamDescription.mSampleRate
        return sampleRate
    }

    /// Whether the private aggregate is still alive.
    func isAggregateAlive() -> Bool {
        guard aggregateDeviceID != kAudioObjectUnknown else {
            return false
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAlive = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            aggregateDeviceID, &address, 0, nil, &size, &isAlive
        )
        return status == noErr && isAlive != 0
    }

    func start() throws {
        guard
            aggregateDeviceID != kAudioObjectUnknown,
            let ioProcID
        else {
            throw AudioCaptureError.systemCaptureNotRunning
        }
        guard !isStarted else {
            return
        }

        var profiler = SystemAudioStartupProfiler()
        defer {
            startupStageTimings.append(contentsOf: profiler.timings)
        }
        try profiler.measure(.audioDeviceStart) {
            try CoreAudioCallError.checkSystemAudio(
                AudioDeviceStart(aggregateDeviceID, ioProcID),
                operation: "Starting the system-audio aggregate device"
            )
        }
        isStarted = true
    }

    func stop() throws {
        guard isStarted, let ioProcID else {
            return
        }
        try CoreAudioCallError.check(
            AudioDeviceStop(aggregateDeviceID, ioProcID),
            operation: "Stopping the system-audio aggregate device"
        )
        isStarted = false
    }

    func tearDown() throws {
        var failures: [String] = []

        if isStarted, let ioProcID {
            let status = AudioDeviceStop(aggregateDeviceID, ioProcID)
            if status != noErr {
                failures.append(
                    CoreAudioCallError(
                        operation: "Stopping the system-audio aggregate device",
                        status: status
                    ).localizedDescription
                )
            }
            isStarted = false
        }

        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            let status = AudioDeviceDestroyIOProcID(
                aggregateDeviceID,
                ioProcID
            )
            if status != noErr {
                failures.append(
                    CoreAudioCallError(
                        operation: "Destroying the system-audio IOProc",
                        status: status
                    ).localizedDescription
                )
            }
            self.ioProcID = nil
        }

        if aggregateDeviceID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(
                aggregateDeviceID
            )
            if status != noErr {
                failures.append(
                    CoreAudioCallError(
                        operation: "Destroying the private aggregate device",
                        status: status
                    ).localizedDescription
                )
            }
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status != noErr {
                failures.append(
                    CoreAudioCallError(
                        operation: "Destroying the system-audio process tap",
                        status: status
                    ).localizedDescription
                )
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        outputDeviceID = AudioDeviceID(kAudioObjectUnknown)
        sampleRate = 0
        if !failures.isEmpty {
            throw AudioCaptureError.systemGraphTeardownFailed(
                failures.joined(separator: " ")
            )
        }
    }

    private func cleanupAfterSetupFailure() -> String? {
        do {
            try tearDown()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

enum SystemTapAggregateDescription {
    static func make(
        outputDeviceUID: String,
        tapUID: String,
        aggregateUID: String
    ) -> [String: Any] {
        let subdevice: [String: Any] = [
            kAudioSubDeviceUIDKey: outputDeviceUID,
            kAudioSubDeviceInputChannelsKey: 0
        ]
        let subtap: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: true
        ]
        return [
            kAudioAggregateDeviceNameKey: "Scribe Private System Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceSubDeviceListKey: [subdevice],
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceTapListKey: [subtap],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceIsPrivateKey: true
        ]
    }
}

private final class SystemAudioRealtimeSink: @unchecked Sendable {
    private let ringBuffer: FloatRingBuffer
    private let firstSampleTime: FirstSampleHostTime

    init(
        ringBuffer: FloatRingBuffer,
        firstSampleTime: FirstSampleHostTime
    ) {
        self.ringBuffer = ringBuffer
        self.firstSampleTime = firstSampleTime
    }

    func receive(
        _ inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        let written = ringBuffer.writeAudioBufferListMix(inputData)
        let timestamp = inputTime.pointee
        if
            written > 0,
            timestamp.mFlags.contains(.hostTimeValid)
        {
            firstSampleTime.capture(timestamp.mHostTime)
        }
    }
}

final class SystemAudioRealtimeRouter: @unchecked Sendable {
    private let storage: OpaquePointer
    private var retainedSink: Unmanaged<SystemAudioRealtimeSink>?

    init() throws {
        guard let storage = scribe_atomic_pointer_create() else {
            throw AudioCaptureError.realtimeRouterAllocationFailed
        }
        self.storage = storage
    }

    deinit {
        detach()
        scribe_atomic_pointer_destroy(storage)
    }

    var isAttached: Bool {
        retainedSink != nil
    }

    func attach(
        ringBuffer: FloatRingBuffer,
        firstSampleTime: FirstSampleHostTime
    ) {
        precondition(retainedSink == nil)
        let sink = SystemAudioRealtimeSink(
            ringBuffer: ringBuffer,
            firstSampleTime: firstSampleTime
        )
        let retainedSink = Unmanaged.passRetained(sink)
        self.retainedSink = retainedSink
        scribe_atomic_pointer_store(storage, retainedSink.toOpaque())
    }

    func detach() {
        scribe_atomic_pointer_store(storage, nil)
        retainedSink?.release()
        retainedSink = nil
    }

    func receive(
        _ inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        guard let pointer = scribe_atomic_pointer_load(storage) else {
            return
        }
        Unmanaged<SystemAudioRealtimeSink>
            .fromOpaque(pointer)
            .takeUnretainedValue()
            .receive(inputData, inputTime: inputTime)
    }
}

public actor SystemTapPrewarmDiagnostic {
    public static let defaultHoldSeconds = 90

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func runPrivacyDiagnostic(
        holdSeconds: Int = defaultHoldSeconds,
        progress: @escaping @Sendable (SystemTapDiagnosticProgress) async -> Void
    ) async throws -> SystemTapPrivacyDiagnosticReport {
        precondition(holdSeconds > 0)
        let runID = UUID()
        let startedAt = Date()
        let primaryCounter = try RealtimeCallbackCounter()
        let comparisonCounter = try RealtimeCallbackCounter()
        let graph = CoreAudioSystemTapGraph(
            diagnosticCallbackCounter: primaryCounter
        )
        var comparisonIOProcID: AudioDeviceIOProcID?

        defer {
            if let comparisonIOProcID {
                try? graph.destroyAdditionalDiagnosticIOProc(
                    comparisonIOProcID
                )
            }
            try? graph.tearDown()
        }

        await progress(.preparing)
        let resourcesBeforePreparation = SystemTapResourceSampler.snapshot()
        try Task.checkCancellation()
        try graph.prepare()
        try Task.checkCancellation()
        let outputDeviceUID = try CoreAudioProperties.deviceUID(
            graph.outputDeviceID
        )
        let resourcesAfterPreparation = SystemTapResourceSampler.snapshot()

        for secondsRemaining in stride(
            from: holdSeconds,
            through: 1,
            by: -1
        ) {
            try Task.checkCancellation()
            await progress(
                .holding(
                    secondsRemaining: secondsRemaining,
                    callbackCount: primaryCounter.value
                )
            )
            try await Task.sleep(for: .seconds(1))
        }

        let resourcesAfterHold = SystemTapResourceSampler.snapshot()
        try Task.checkCancellation()
        await progress(.registeringComparison)
        let comparison = try graph.registerAdditionalDiagnosticIOProc(
            callbackCounter: comparisonCounter
        )
        comparisonIOProcID = comparison.ioProcID
        await progress(.cleaningUp)

        let report = SystemTapPrivacyDiagnosticReport(
            runID: runID,
            startedAt: startedAt,
            completedAt: Date(),
            holdSeconds: holdSeconds,
            outputDeviceUID: outputDeviceUID,
            preparationTimings: graph.startupStageTimings,
            secondIOProcRegistrationTiming: comparison.timing,
            primaryCallbackCount: primaryCounter.value,
            secondIOProcCallbackCount: comparisonCounter.value,
            resourcesBeforePreparation: resourcesBeforePreparation,
            resourcesAfterPreparation: resourcesAfterPreparation,
            resourcesAfterHold: resourcesAfterHold,
            ringBufferAllocated: false,
            wavWriterCreated: false
        )
        try appendLog(kind: "privacy-hold", value: report)
        return report
    }

    public func runTimingSample() throws -> SystemTapTimingSample {
        try Task.checkCancellation()
        let callbackCounter = try RealtimeCallbackCounter()
        let graph = CoreAudioSystemTapGraph(
            diagnosticCallbackCounter: callbackCounter
        )
        defer {
            try? graph.tearDown()
        }

        try graph.prepare()
        try Task.checkCancellation()
        let sample = SystemTapTimingSample(
            runID: UUID(),
            capturedAt: Date(),
            outputDeviceUID: try CoreAudioProperties.deviceUID(
                graph.outputDeviceID
            ),
            timings: graph.startupStageTimings,
            callbackCount: callbackCounter.value,
            ringBufferAllocated: false,
            wavWriterCreated: false
        )
        try appendLog(kind: "timing-sample", value: sample)
        return sample
    }

    public func logURL() throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("Scribe/Diagnostics", isDirectory: true)
            .appendingPathComponent("system-tap-diagnostic.jsonl")
    }

    private func appendLog<Value: Encodable>(
        kind: String,
        value: Value
    ) throws {
        let url = try logURL()
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(value)
        let envelope: [String: Any] = [
            "kind": kind,
            "payload": try JSONSerialization.jsonObject(with: payload)
        ]
        var data = try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys]
        )
        data.append(0x0A)

        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

enum SystemTapResourceSampler {
    static func snapshot() -> SystemTapResourceSnapshot {
        SystemTapResourceSnapshot(
            capturedAt: Date(),
            app: metrics(for: getpid(), name: "Scribe"),
            coreaudiod: coreaudiodProcessID().flatMap {
                metrics(for: $0, name: "coreaudiod")
            }
        )
    }

    private static func metrics(
        for processID: pid_t,
        name: String
    ) -> SystemTapProcessMetrics? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutableBytes(of: &usage) { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return Int32(-1)
            }
            return proc_pid_rusage(
                processID,
                RUSAGE_INFO_V4,
                baseAddress.assumingMemoryBound(to: rusage_info_t?.self)
            )
        }
        guard result == 0 else {
            return nil
        }
        return SystemTapProcessMetrics(
            processID: processID,
            processName: name,
            residentBytes: usage.ri_resident_size,
            physicalFootprintBytes: usage.ri_phys_footprint,
            packageIdleWakeups: usage.ri_pkg_idle_wkups,
            interruptWakeups: usage.ri_interrupt_wkups
        )
    }

    private static func coreaudiodProcessID() -> pid_t? {
        let capacity = max(proc_listallpids(nil, 0), 64)
        var processIDs = [pid_t](repeating: 0, count: Int(capacity))
        _ = processIDs.withUnsafeMutableBytes { bytes in
            proc_listallpids(bytes.baseAddress, Int32(bytes.count))
        }
        return processIDs.first { processID in
            processID > 0 && processName(for: processID) == "coreaudiod"
        }
    }

    private static func processName(for processID: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_name(processID, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0 else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map {
            UInt8(bitPattern: $0)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
