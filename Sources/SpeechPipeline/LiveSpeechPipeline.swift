import AudioCapture
import Foundation

public struct LiveSpeechSegmentationConfiguration:
    Equatable,
    Sendable
{
    public var entryThreshold: Float
    public var exitThreshold: Float
    public var minimumSpeechDuration: TimeInterval
    public var minimumSilenceDuration: TimeInterval
    public var speechPadding: TimeInterval
    public var maximumSpeechDuration: TimeInterval
    public var windowDuration: TimeInterval
    public var windowOverlap: TimeInterval

    public static let `default` = LiveSpeechSegmentationConfiguration()

    public init(
        entryThreshold: Float = 0.85,
        exitThreshold: Float = 0.70,
        minimumSpeechDuration: TimeInterval = 0.15,
        minimumSilenceDuration: TimeInterval = 0.75,
        speechPadding: TimeInterval = 0.10,
        maximumSpeechDuration: TimeInterval = 30,
        windowDuration: TimeInterval = 14,
        windowOverlap: TimeInterval = 1.5
    ) {
        self.entryThreshold = entryThreshold
        self.exitThreshold = exitThreshold
        self.minimumSpeechDuration = minimumSpeechDuration
        self.minimumSilenceDuration = minimumSilenceDuration
        self.speechPadding = speechPadding
        self.maximumSpeechDuration = maximumSpeechDuration
        self.windowDuration = windowDuration
        self.windowOverlap = windowOverlap
    }

    func usingWindowGeometry(
        from engine: any TranscriptionEngine
    ) -> Self {
        var resolved = self
        resolved.windowDuration = engine.preferredWindowDuration
        resolved.windowOverlap = engine.preferredOverlap
        resolved.maximumSpeechDuration = max(
            maximumSpeechDuration,
            engine.preferredWindowDuration + engine.preferredOverlap
        )
        return resolved
    }
}

public struct LiveSpeechWindow: Equatable, Sendable {
    public let source: AudioSource
    public let speechSegmentIndex: UInt64
    public let firstSampleIndex: UInt64
    public let trackStartTime: TimeInterval
    public let overlapSampleCount: Int
    public let isFinalWindow: Bool
    public let samples: [Float]

    public init(
        source: AudioSource,
        speechSegmentIndex: UInt64,
        firstSampleIndex: UInt64,
        trackStartTime: TimeInterval,
        overlapSampleCount: Int,
        isFinalWindow: Bool = true,
        samples: [Float]
    ) {
        self.source = source
        self.speechSegmentIndex = speechSegmentIndex
        self.firstSampleIndex = firstSampleIndex
        self.trackStartTime = trackStartTime
        self.overlapSampleCount = overlapSampleCount
        self.isFinalWindow = isFinalWindow
        self.samples = samples
    }

    public var startTime: TimeInterval {
        trackStartTime
            + Double(firstSampleIndex)
                / CanonicalAudioFormat.sampleRate
    }

    public var duration: TimeInterval {
        Double(samples.count) / CanonicalAudioFormat.sampleRate
    }

    public var audioChunk: AudioChunk {
        AudioChunk(
            samples: samples,
            startTime: startTime,
            source: source
        )
    }
}

public enum LiveSpeechPipelineState: Equatable, Sendable {
    case idle
    case modelUnavailable
    case preparing
    case running(pendingWindowCount: UInt64)
    case finishing(pendingWindowCount: UInt64)
    case completed(pendingWindowCount: UInt64)
    case failed(message: String)
}

public struct LiveSpeechPipelineMetrics: Equatable, Sendable {
    public let processedBlockCount: UInt64
    public let processedSampleCount: UInt64
    public let emittedSpeechSegmentCount: UInt64
    public let emittedWindowCount: UInt64
    public let deliveredWindowCount: UInt64
    public let pendingWindowCount: UInt64
    public let peakBufferedSampleCountPerSource: Int
    public let speechProbabilities: [AudioSource: Float]

    public init(
        processedBlockCount: UInt64,
        processedSampleCount: UInt64,
        emittedSpeechSegmentCount: UInt64,
        emittedWindowCount: UInt64,
        deliveredWindowCount: UInt64,
        pendingWindowCount: UInt64,
        peakBufferedSampleCountPerSource: Int,
        speechProbabilities: [AudioSource: Float]
    ) {
        self.processedBlockCount = processedBlockCount
        self.processedSampleCount = processedSampleCount
        self.emittedSpeechSegmentCount = emittedSpeechSegmentCount
        self.emittedWindowCount = emittedWindowCount
        self.deliveredWindowCount = deliveredWindowCount
        self.pendingWindowCount = pendingWindowCount
        self.peakBufferedSampleCountPerSource =
            peakBufferedSampleCountPerSource
        self.speechProbabilities = speechProbabilities
    }

    public static let zero = LiveSpeechPipelineMetrics(
        processedBlockCount: 0,
        processedSampleCount: 0,
        emittedSpeechSegmentCount: 0,
        emittedWindowCount: 0,
        deliveredWindowCount: 0,
        pendingWindowCount: 0,
        peakBufferedSampleCountPerSource: 0,
        speechProbabilities: [:]
    )
}

public enum LiveSpeechPipelineError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case invalidConfiguration(String)
    case sessionAlreadyActive
    case sessionNotActive
    case missingTrack(AudioSource)
    case noncontiguousBlock(
        source: AudioSource,
        expectedSampleIndex: UInt64,
        actualSampleIndex: UInt64
    )
    case spoolDirectoryAlreadyExists(URL)
    case malformedWindowSpool(URL)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            "Live speech segmentation configuration is invalid: \(message)"
        case .sessionAlreadyActive:
            "A live speech pipeline session is already active."
        case .sessionNotActive:
            "There is no active live speech pipeline session."
        case let .missingTrack(source):
            "Capture metadata has no \(source.rawValue) track."
        case let .noncontiguousBlock(source, expected, actual):
            "The \(source.rawValue) VAD feed skipped from sample \(expected) to \(actual)."
        case let .spoolDirectoryAlreadyExists(url):
            "Refusing to overwrite the existing speech-window spool at \(url.path)."
        case let .malformedWindowSpool(url):
            "The speech-window spool contains a malformed record at \(url.path)."
        case let .operationFailed(message):
            "The live speech pipeline failed: \(message)"
        }
    }
}

protocol LiveSpeechWindowSpoolStorage: Sendable {
    var source: AudioSource { get }
    var url: URL { get }

    func append(_ window: LiveSpeechWindow) throws
    func next() throws -> LiveSpeechWindow?
    func finishWriting() throws
    func discard() throws
}

typealias LiveSpeechWindowSpoolFactory =
    @Sendable (
        URL,
        AudioSource,
        TimeInterval
    ) throws -> any LiveSpeechWindowSpoolStorage

public actor LiveSpeechPipeline {
    public private(set) var state: LiveSpeechPipelineState = .idle
    public private(set) var metrics: LiveSpeechPipelineMetrics = .zero

    private let audioTransport: LiveAudioTransport
    private let detector: any LiveVoiceActivityDetecting
    private let configuration: LiveSpeechSegmentationConfiguration
    private let storageFactory: LiveSpeechWindowSpoolFactory

    private var processors: [AudioSource: LiveSpeechSourceProcessor] = [:]
    private var storages:
        [AudioSource: any LiveSpeechWindowSpoolStorage] = [:]
    private var pendingWindowsBySource:
        [AudioSource: UInt64] = [:]
    private var drainTask: Task<Void, Never>?
    private var failureMessage: String?

    public init(
        audioTransport: LiveAudioTransport,
        sileroModelURL: URL,
        transcriptionEngine: any TranscriptionEngine,
        configuration: LiveSpeechSegmentationConfiguration = .default
    ) throws {
        let resolvedConfiguration = configuration.usingWindowGeometry(
            from: transcriptionEngine
        )
        try Self.validate(resolvedConfiguration)
        self.audioTransport = audioTransport
        self.detector = FluidAudioSileroVAD(modelURL: sileroModelURL)
        self.configuration = resolvedConfiguration
        self.storageFactory = { directory, source, trackStartTime in
            try FileLiveSpeechWindowSpoolStorage(
                directory: directory,
                source: source,
                trackStartTime: trackStartTime
            )
        }
    }

    init(
        audioTransport: LiveAudioTransport,
        detector: any LiveVoiceActivityDetecting,
        configuration: LiveSpeechSegmentationConfiguration = .default,
        storageFactory: @escaping LiveSpeechWindowSpoolFactory
    ) throws {
        try Self.validate(configuration)
        self.audioTransport = audioTransport
        self.detector = detector
        self.configuration = configuration
        self.storageFactory = storageFactory
    }

    init(
        audioTransport: LiveAudioTransport,
        detector: any LiveVoiceActivityDetecting,
        transcriptionEngine: any TranscriptionEngine,
        configuration: LiveSpeechSegmentationConfiguration = .default,
        storageFactory: @escaping LiveSpeechWindowSpoolFactory
    ) throws {
        let resolvedConfiguration = configuration.usingWindowGeometry(
            from: transcriptionEngine
        )
        try Self.validate(resolvedConfiguration)
        self.audioTransport = audioTransport
        self.detector = detector
        self.configuration = resolvedConfiguration
        self.storageFactory = storageFactory
    }

    public func beginSession(
        in sessionDirectory: URL,
        manifest: CaptureSessionManifest
    ) async throws {
        guard storages.isEmpty, drainTask == nil else {
            throw LiveSpeechPipelineError.sessionAlreadyActive
        }
        try manifest.validate()
        state = .preparing

        do {
            try await detector.prepare()
        } catch {
            state = .failed(message: error.localizedDescription)
            throw error
        }

        let spoolDirectory = sessionDirectory.appendingPathComponent(
            "LiveSpeechWindows",
            isDirectory: true
        )
        guard
            !FileManager.default.fileExists(atPath: spoolDirectory.path)
        else {
            await detector.unload()
            state = .failed(
                message: LiveSpeechPipelineError
                    .spoolDirectoryAlreadyExists(spoolDirectory)
                    .localizedDescription
            )
            throw LiveSpeechPipelineError.spoolDirectoryAlreadyExists(
                spoolDirectory
            )
        }

        do {
            try FileManager.default.createDirectory(
                at: spoolDirectory,
                withIntermediateDirectories: true
            )
            for source in AudioSource.liveCaptureSources {
                guard let track = manifest.track(for: source) else {
                    throw LiveSpeechPipelineError.missingTrack(source)
                }
                storages[source] = try storageFactory(
                    spoolDirectory,
                    source,
                    track.startTime
                )
                processors[source] = LiveSpeechSourceProcessor(
                    source: source,
                    trackStartTime: track.startTime,
                    configuration: configuration
                )
            }
            pendingWindowsBySource = Dictionary(
                uniqueKeysWithValues:
                    AudioSource.liveCaptureSources.map { ($0, 0) }
            )
        } catch {
            let originalMessage = error.localizedDescription
            do {
                if FileManager.default.fileExists(
                    atPath: spoolDirectory.path
                ) {
                    try FileManager.default.removeItem(at: spoolDirectory)
                }
            } catch {
                await detector.unload()
                let message =
                    "\(originalMessage) Removing the partial speech spool also failed: \(error.localizedDescription)"
                state = .failed(message: message)
                throw LiveSpeechPipelineError.operationFailed(message)
            }
            await detector.unload()
            state = .failed(message: originalMessage)
            throw LiveSpeechPipelineError.operationFailed(originalMessage)
        }

        metrics = .zero
        failureMessage = nil
        state = .running(pendingWindowCount: 0)
        drainTask = Task { [weak self] in
            await self?.drainAudioTransport()
        }
    }

    public func nextWindow(
        for source: AudioSource
    ) throws -> LiveSpeechWindow? {
        guard let storage = storages[source] else {
            throw LiveSpeechPipelineError.sessionNotActive
        }
        let sourcePending = pendingWindowsBySource[source] ?? 0
        guard sourcePending > 0 else {
            return nil
        }
        guard let window = try storage.next() else {
            throw LiveSpeechPipelineError.malformedWindowSpool(
                storage.url
            )
        }
        guard metrics.pendingWindowCount > 0 else {
            throw LiveSpeechPipelineError.malformedWindowSpool(
                storage.url
            )
        }
        pendingWindowsBySource[source] = sourcePending - 1
        metrics = LiveSpeechPipelineMetrics(
            processedBlockCount: metrics.processedBlockCount,
            processedSampleCount: metrics.processedSampleCount,
            emittedSpeechSegmentCount:
                metrics.emittedSpeechSegmentCount,
            emittedWindowCount: metrics.emittedWindowCount,
            deliveredWindowCount: metrics.deliveredWindowCount + 1,
            pendingWindowCount: metrics.pendingWindowCount - 1,
            peakBufferedSampleCountPerSource:
                metrics.peakBufferedSampleCountPerSource,
            speechProbabilities: metrics.speechProbabilities
        )
        updateStateForPendingWindows()
        return window
    }

    public func waitUntilFinished() async throws {
        guard let drainTask else {
            throw LiveSpeechPipelineError.sessionNotActive
        }
        await drainTask.value
        if let failureMessage {
            throw LiveSpeechPipelineError.operationFailed(failureMessage)
        }
    }

    public func cancelAndDiscard(
        finalState: LiveSpeechPipelineState = .idle
    ) async throws {
        drainTask?.cancel()
        await drainTask?.value
        drainTask = nil
        await detector.unload()

        var failures: [String] = []
        var spoolDirectory: URL?
        for storage in storages.values {
            spoolDirectory = storage.url.deletingLastPathComponent()
            do {
                try storage.discard()
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if let spoolDirectory,
            FileManager.default.fileExists(atPath: spoolDirectory.path)
        {
            do {
                try FileManager.default.removeItem(at: spoolDirectory)
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        processors.removeAll(keepingCapacity: false)
        storages.removeAll(keepingCapacity: false)
        pendingWindowsBySource.removeAll(keepingCapacity: false)
        metrics = .zero
        failureMessage = nil

        if failures.isEmpty {
            state = finalState
        } else {
            let message = failures.joined(separator: " ")
            state = .failed(message: message)
            throw LiveSpeechPipelineError.operationFailed(message)
        }
    }

    private func drainAudioTransport() async {
        do {
            while !Task.isCancelled {
                var processedBlock = false
                for source in AudioSource.liveCaptureSources {
                    guard
                        let block = try await audioTransport.nextBlock(
                            for: source
                        )
                    else {
                        continue
                    }
                    try await process(block)
                    processedBlock = true
                }

                if processedBlock {
                    continue
                }
                let transportState = await audioTransport.state
                if Self.isFinishedProducing(transportState) {
                    try await finishProcessors()
                    try finishWindowSpools()
                    state = .completed(
                        pendingWindowCount: metrics.pendingWindowCount
                    )
                    await detector.unload()
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch is CancellationError {
            return
        } catch {
            let message = error.localizedDescription
            failureMessage = message
            state = .failed(message: message)
            await detector.unload()
        }
    }

    private func process(_ block: CanonicalAudioBlock) async throws {
        guard var processor = processors[block.source] else {
            throw LiveSpeechPipelineError.missingTrack(block.source)
        }
        let result = try await processor.ingest(
            block,
            detector: detector
        )
        processors[block.source] = processor
        try append(result.windows)
        var probabilities = metrics.speechProbabilities
        if let probability = processor.latestSpeechProbability {
            probabilities[block.source] = probability
        }

        metrics = LiveSpeechPipelineMetrics(
            processedBlockCount: metrics.processedBlockCount + 1,
            processedSampleCount:
                metrics.processedSampleCount
                + UInt64(block.samples.count),
            emittedSpeechSegmentCount:
                metrics.emittedSpeechSegmentCount
                + UInt64(result.emittedSegmentCount),
            emittedWindowCount: metrics.emittedWindowCount,
            deliveredWindowCount: metrics.deliveredWindowCount,
            pendingWindowCount: metrics.pendingWindowCount,
            peakBufferedSampleCountPerSource: max(
                metrics.peakBufferedSampleCountPerSource,
                processor.peakBufferedSampleCount
            ),
            speechProbabilities: probabilities
        )
        updateStateForPendingWindows()
    }

    private func finishProcessors() async throws {
        state = .finishing(
            pendingWindowCount: metrics.pendingWindowCount
        )
        for source in AudioSource.liveCaptureSources {
            guard var processor = processors[source] else {
                throw LiveSpeechPipelineError.missingTrack(source)
            }
            let result = try await processor.finish(detector: detector)
            processors[source] = processor
            try append(result.windows)
            var probabilities = metrics.speechProbabilities
            if let probability = processor.latestSpeechProbability {
                probabilities[source] = probability
            }
            metrics = LiveSpeechPipelineMetrics(
                processedBlockCount: metrics.processedBlockCount,
                processedSampleCount: metrics.processedSampleCount,
                emittedSpeechSegmentCount:
                    metrics.emittedSpeechSegmentCount
                    + UInt64(result.emittedSegmentCount),
                emittedWindowCount: metrics.emittedWindowCount,
                deliveredWindowCount: metrics.deliveredWindowCount,
                pendingWindowCount: metrics.pendingWindowCount,
                peakBufferedSampleCountPerSource: max(
                    metrics.peakBufferedSampleCountPerSource,
                    processor.peakBufferedSampleCount
                ),
                speechProbabilities: probabilities
            )
        }
    }

    private func append(_ windows: [LiveSpeechWindow]) throws {
        for window in windows {
            guard let storage = storages[window.source] else {
                throw LiveSpeechPipelineError.missingTrack(
                    window.source
                )
            }
            try storage.append(window)
            pendingWindowsBySource[window.source] =
                (pendingWindowsBySource[window.source] ?? 0) + 1
            metrics = LiveSpeechPipelineMetrics(
                processedBlockCount: metrics.processedBlockCount,
                processedSampleCount: metrics.processedSampleCount,
                emittedSpeechSegmentCount:
                    metrics.emittedSpeechSegmentCount,
                emittedWindowCount: metrics.emittedWindowCount + 1,
                deliveredWindowCount: metrics.deliveredWindowCount,
                pendingWindowCount: metrics.pendingWindowCount + 1,
                peakBufferedSampleCountPerSource:
                    metrics.peakBufferedSampleCountPerSource,
                speechProbabilities: metrics.speechProbabilities
            )
        }
    }

    private func finishWindowSpools() throws {
        var failures: [String] = []
        for storage in storages.values {
            do {
                try storage.finishWriting()
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !failures.isEmpty {
            throw LiveSpeechPipelineError.operationFailed(
                failures.joined(separator: " ")
            )
        }
    }

    private func updateStateForPendingWindows() {
        switch state {
        case .running:
            state = .running(
                pendingWindowCount: metrics.pendingWindowCount
            )
        case .finishing:
            state = .finishing(
                pendingWindowCount: metrics.pendingWindowCount
            )
        case .completed:
            state = .completed(
                pendingWindowCount: metrics.pendingWindowCount
            )
        case .idle, .modelUnavailable, .preparing, .failed:
            break
        }
    }

    private nonisolated static func isFinishedProducing(
        _ state: LiveAudioTransportState
    ) -> Bool {
        switch state {
        case .recordingComplete, .drained:
            true
        case .idle, .ready, .keepingUp, .bufferingToDisk,
            .catchingUp, .failed:
            false
        }
    }

    private nonisolated static func validate(
        _ configuration: LiveSpeechSegmentationConfiguration
    ) throws {
        let durations = [
            configuration.minimumSpeechDuration,
            configuration.minimumSilenceDuration,
            configuration.speechPadding,
            configuration.maximumSpeechDuration,
            configuration.windowDuration,
            configuration.windowOverlap,
        ]
        guard durations.allSatisfy(\.isFinite) else {
            throw LiveSpeechPipelineError.invalidConfiguration(
                "all durations must be finite"
            )
        }
        let largestSafeDuration =
            Double(Int.max) / CanonicalAudioFormat.sampleRate
        guard durations.allSatisfy({ $0 <= largestSafeDuration }) else {
            throw LiveSpeechPipelineError.invalidConfiguration(
                "durations are too large to represent as canonical sample counts"
            )
        }
        guard
            configuration.entryThreshold.isFinite,
            configuration.exitThreshold.isFinite,
            (0...1).contains(configuration.entryThreshold),
            (0...1).contains(configuration.exitThreshold),
            configuration.exitThreshold
                < configuration.entryThreshold
        else {
            throw LiveSpeechPipelineError.invalidConfiguration(
                "probability thresholds must be in [0, 1] and the exit threshold must be lower"
            )
        }
        guard
            configuration.minimumSpeechDuration >= 0,
            configuration.minimumSilenceDuration >= 0,
            configuration.speechPadding >= 0,
            configuration.maximumSpeechDuration > 0,
            configuration.windowDuration > 0,
            configuration.windowOverlap >= 0,
            configuration.windowOverlap
                < configuration.windowDuration,
            configuration.windowDuration
                <= configuration.maximumSpeechDuration
        else {
            throw LiveSpeechPipelineError.invalidConfiguration(
                "durations must be nonnegative, and overlap < window ≤ maximum speech duration"
            )
        }
    }
}

struct LiveSpeechSourceProcessResult {
    let windows: [LiveSpeechWindow]
    let emittedSegmentCount: Int
}

struct LiveSpeechSourceProcessor {
    let source: AudioSource
    let trackStartTime: TimeInterval
    let configuration: LiveSpeechSegmentationConfiguration

    private(set) var peakBufferedSampleCount = 0
    private(set) var latestSpeechProbability: Float?
    private var buffer = TimelineSampleBuffer()
    private var expectedSampleIndex: UInt64 = 0
    private var nextFrameStart: UInt64 = 0
    private var activeSpeechStart: UInt64?
    private var pendingSilenceStart: UInt64?
    private var nextWindowStart: UInt64?
    private var hasEmittedWindowForActiveSegment = false
    private var nextSpeechSegmentIndex: UInt64 = 0
    private var isFinished = false

    init(
        source: AudioSource,
        trackStartTime: TimeInterval,
        configuration: LiveSpeechSegmentationConfiguration
    ) {
        self.source = source
        self.trackStartTime = trackStartTime
        self.configuration = configuration
    }

    mutating func ingest(
        _ block: CanonicalAudioBlock,
        detector: any LiveVoiceActivityDetecting
    ) async throws -> LiveSpeechSourceProcessResult {
        guard !isFinished else {
            throw LiveSpeechPipelineError.operationFailed(
                "The \(source.rawValue) VAD processor was already finished."
            )
        }
        guard block.source == source else {
            throw LiveSpeechPipelineError.operationFailed(
                "A \(block.source.rawValue) block reached the \(source.rawValue) VAD processor."
            )
        }
        guard block.firstSampleIndex == expectedSampleIndex else {
            throw LiveSpeechPipelineError.noncontiguousBlock(
                source: source,
                expectedSampleIndex: expectedSampleIndex,
                actualSampleIndex: block.firstSampleIndex
            )
        }
        expectedSampleIndex += UInt64(block.samples.count)
        try buffer.append(
            block.samples,
            firstSampleIndex: block.firstSampleIndex
        )
        peakBufferedSampleCount = max(
            peakBufferedSampleCount,
            buffer.count
        )

        var windows: [LiveSpeechWindow] = []
        var segmentCount = 0
        let frameCount = UInt64(4_096)
        while nextFrameStart + frameCount <= buffer.endSampleIndex {
            let frameEnd = nextFrameStart + frameCount
            let frame = try buffer.samples(
                from: nextFrameStart,
                to: frameEnd
            )
            let probability = try await detector.speechProbability(
                for: frame,
                source: source
            )
            latestSpeechProbability = probability
            let result = try processObservation(
                probability: probability,
                frameStart: nextFrameStart,
                frameEnd: frameEnd
            )
            windows.append(contentsOf: result.windows)
            segmentCount += result.emittedSegmentCount
            nextFrameStart = frameEnd
            discardUnneededHistory()
        }

        peakBufferedSampleCount = max(
            peakBufferedSampleCount,
            buffer.count
        )
        return LiveSpeechSourceProcessResult(
            windows: windows,
            emittedSegmentCount: segmentCount
        )
    }

    mutating func finish(
        detector: any LiveVoiceActivityDetecting
    ) async throws -> LiveSpeechSourceProcessResult {
        guard !isFinished else {
            return LiveSpeechSourceProcessResult(
                windows: [],
                emittedSegmentCount: 0
            )
        }

        var windows: [LiveSpeechWindow] = []
        var segmentCount = 0
        if nextFrameStart < buffer.endSampleIndex {
            let frameEnd = buffer.endSampleIndex
            let frame = try buffer.samples(
                from: nextFrameStart,
                to: frameEnd
            )
            let probability = try await detector.speechProbability(
                for: frame,
                source: source
            )
            latestSpeechProbability = probability
            let result = try processObservation(
                probability: probability,
                frameStart: nextFrameStart,
                frameEnd: frameEnd
            )
            windows.append(contentsOf: result.windows)
            segmentCount += result.emittedSegmentCount
            nextFrameStart = frameEnd
        }

        if let activeSpeechStart {
            let result = try finalizeSpeech(
                from: activeSpeechStart,
                to: buffer.endSampleIndex
            )
            windows.append(contentsOf: result.windows)
            segmentCount += result.emittedSegmentCount
            self.activeSpeechStart = nil
            pendingSilenceStart = nil
        }
        isFinished = true
        return LiveSpeechSourceProcessResult(
            windows: windows,
            emittedSegmentCount: segmentCount
        )
    }

    private mutating func processObservation(
        probability: Float,
        frameStart: UInt64,
        frameEnd: UInt64
    ) throws -> LiveSpeechSourceProcessResult {
        guard
            probability.isFinite,
            (0...1).contains(probability)
        else {
            throw SileroVADError.invalidProbability(probability)
        }

        let padding = sampleCount(configuration.speechPadding)
        if probability >= configuration.entryThreshold {
            pendingSilenceStart = nil
            if activeSpeechStart == nil {
                let start =
                    frameStart > padding
                    ? frameStart - padding
                    : 0
                activeSpeechStart = start
                nextWindowStart = start
                hasEmittedWindowForActiveSegment = false
            }
        } else if
            probability < configuration.exitThreshold,
            activeSpeechStart != nil,
            pendingSilenceStart == nil
        {
            pendingSilenceStart = frameStart
        }

        var windows: [LiveSpeechWindow] = []
        var segmentCount = 0
        if let speechStart = activeSpeechStart {
            let maximumEnd =
                speechStart
                + sampleCount(configuration.maximumSpeechDuration)
            let speechAvailableEnd: UInt64
            if let pendingSilenceStart {
                speechAvailableEnd = min(
                    frameEnd,
                    pendingSilenceStart + padding
                )
            } else {
                speechAvailableEnd = frameEnd
            }
            windows.append(
                contentsOf: try emitAvailablePartialWindows(
                    speechStart: speechStart,
                    availableEnd: min(maximumEnd, speechAvailableEnd)
                )
            )
        }

        if let speechStart = activeSpeechStart,
            let silenceStart = pendingSilenceStart
        {
            let minimumSilence = sampleCount(
                configuration.minimumSilenceDuration
            )
            if frameEnd >= silenceStart + minimumSilence {
                let paddedEnd = min(
                    buffer.endSampleIndex,
                    silenceStart + padding
                )
                let result = try finalizeSpeech(
                    from: speechStart,
                    to: paddedEnd
                )
                windows.append(contentsOf: result.windows)
                segmentCount += result.emittedSegmentCount
                activeSpeechStart = nil
                pendingSilenceStart = nil
            }
        }

        let maximumSpeech = sampleCount(
            configuration.maximumSpeechDuration
        )
        while let speechStart = activeSpeechStart,
            frameEnd >= speechStart + maximumSpeech
        {
            let hardEnd = speechStart + maximumSpeech
            let result = try finalizeSpeech(
                from: speechStart,
                to: hardEnd
            )
            windows.append(contentsOf: result.windows)
            segmentCount += result.emittedSegmentCount
            let continuationOverlap = sampleCount(
                configuration.windowOverlap
            )
            activeSpeechStart = hardEnd
            nextWindowStart = hardEnd - continuationOverlap
            hasEmittedWindowForActiveSegment = true
            if let pendingSilenceStart,
                pendingSilenceStart < hardEnd
            {
                self.pendingSilenceStart = hardEnd
            }
        }

        return LiveSpeechSourceProcessResult(
            windows: windows,
            emittedSegmentCount: segmentCount
        )
    }

    private mutating func finalizeSpeech(
        from start: UInt64,
        to end: UInt64
    ) throws -> LiveSpeechSourceProcessResult {
        guard end > start else {
            resetActiveWindowState()
            return LiveSpeechSourceProcessResult(
                windows: [],
                emittedSegmentCount: 0
            )
        }
        let minimumSpeech = sampleCount(
            configuration.minimumSpeechDuration
        )
        guard end - start >= minimumSpeech else {
            resetActiveWindowState()
            return LiveSpeechSourceProcessResult(
                windows: [],
                emittedSegmentCount: 0
            )
        }

        let windowSampleCount = sampleCount(
            configuration.windowDuration
        )
        let overlapSampleCount = sampleCount(
            configuration.windowOverlap
        )
        var windows: [LiveSpeechWindow] = []
        var windowStart = nextWindowStart ?? start
        while end - windowStart > windowSampleCount {
            let windowEnd = windowStart + windowSampleCount
            windows.append(
                try makeWindow(
                    from: windowStart,
                    to: windowEnd,
                    isFinal: false,
                    overlapSampleCount: overlapSampleCount
                )
            )
            hasEmittedWindowForActiveSegment = true
            windowStart = windowEnd - overlapSampleCount
        }
        if windowStart < end {
            windows.append(
                try makeWindow(
                    from: windowStart,
                    to: end,
                    isFinal: true,
                    overlapSampleCount: overlapSampleCount
                )
            )
        }
        nextSpeechSegmentIndex += 1
        resetActiveWindowState()
        return LiveSpeechSourceProcessResult(
            windows: windows,
            emittedSegmentCount: 1
        )
    }

    private mutating func discardUnneededHistory() {
        let earliestNeeded: UInt64
        if let activeSpeechStart {
            earliestNeeded = nextWindowStart ?? activeSpeechStart
        } else {
            let reserve =
                sampleCount(configuration.speechPadding) + 4_096
            earliestNeeded =
                nextFrameStart > reserve
                ? nextFrameStart - reserve
                : 0
        }
        buffer.discard(before: earliestNeeded)
    }

    private mutating func emitAvailablePartialWindows(
        speechStart: UInt64,
        availableEnd: UInt64
    ) throws -> [LiveSpeechWindow] {
        let windowSampleCount = sampleCount(
            configuration.windowDuration
        )
        let overlapSampleCount = sampleCount(
            configuration.windowOverlap
        )
        let minimumSpeechSampleCount = sampleCount(
            configuration.minimumSpeechDuration
        )
        var windowStart = nextWindowStart ?? speechStart
        var windows: [LiveSpeechWindow] = []

        while
            availableEnd >= speechStart + minimumSpeechSampleCount,
            availableEnd >= windowStart
                + windowSampleCount
                + overlapSampleCount
        {
            let windowEnd = windowStart + windowSampleCount
            windows.append(
                try makeWindow(
                    from: windowStart,
                    to: windowEnd,
                    isFinal: false,
                    overlapSampleCount: overlapSampleCount
                )
            )
            hasEmittedWindowForActiveSegment = true
            windowStart = windowEnd - overlapSampleCount
        }
        nextWindowStart = windowStart
        return windows
    }

    private func makeWindow(
        from start: UInt64,
        to end: UInt64,
        isFinal: Bool,
        overlapSampleCount: UInt64
    ) throws -> LiveSpeechWindow {
        LiveSpeechWindow(
            source: source,
            speechSegmentIndex: nextSpeechSegmentIndex,
            firstSampleIndex: start,
            trackStartTime: trackStartTime,
            overlapSampleCount:
                hasEmittedWindowForActiveSegment
                ? Int(overlapSampleCount)
                : 0,
            isFinalWindow: isFinal,
            samples: try buffer.samples(from: start, to: end)
        )
    }

    private mutating func resetActiveWindowState() {
        nextWindowStart = nil
        hasEmittedWindowForActiveSegment = false
    }

    private func sampleCount(_ duration: TimeInterval) -> UInt64 {
        UInt64(
            (duration * CanonicalAudioFormat.sampleRate).rounded()
        )
    }
}

private struct TimelineSampleBuffer {
    private var storage: [Float] = []
    private var startOffset = 0
    private(set) var baseSampleIndex: UInt64 = 0

    var count: Int {
        storage.count - startOffset
    }

    var endSampleIndex: UInt64 {
        baseSampleIndex + UInt64(count)
    }

    mutating func append(
        _ samples: [Float],
        firstSampleIndex: UInt64
    ) throws {
        guard firstSampleIndex == endSampleIndex else {
            throw LiveSpeechPipelineError.operationFailed(
                "The VAD timeline buffer expected sample \(endSampleIndex) but received \(firstSampleIndex)."
            )
        }
        storage.append(contentsOf: samples)
    }

    func samples(
        from start: UInt64,
        to end: UInt64
    ) throws -> [Float] {
        guard
            start >= baseSampleIndex,
            end >= start,
            end <= endSampleIndex
        else {
            throw LiveSpeechPipelineError.operationFailed(
                "The requested VAD sample range \(start)..<\(end) is outside \(baseSampleIndex)..<\(endSampleIndex)."
            )
        }
        let lower =
            startOffset + Int(start - baseSampleIndex)
        let upper =
            startOffset + Int(end - baseSampleIndex)
        return Array(storage[lower..<upper])
    }

    mutating func discard(before sampleIndex: UInt64) {
        let clamped = min(
            max(sampleIndex, baseSampleIndex),
            endSampleIndex
        )
        let removedCount = Int(clamped - baseSampleIndex)
        startOffset += removedCount
        baseSampleIndex = clamped

        if
            startOffset >= 65_536,
            startOffset >= storage.count / 2
        {
            storage.removeFirst(startOffset)
            startOffset = 0
        }
    }
}

final class FileLiveSpeechWindowSpoolStorage:
    LiveSpeechWindowSpoolStorage,
    @unchecked Sendable
{
    // LiveSpeechPipeline's actor is the sole serial owner of both handles.
    let source: AudioSource
    let url: URL

    private let trackStartTime: TimeInterval
    private let writer: FileHandle
    private let reader: FileHandle
    private var isWriterClosed = false
    private var isDiscarded = false

    init(
        directory: URL,
        source: AudioSource,
        trackStartTime: TimeInterval
    ) throws {
        self.source = source
        self.trackStartTime = trackStartTime
        self.url = directory.appendingPathComponent(
            "\(source.rawValue).speechwindows",
            isDirectory: false
        )
        guard
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil
            )
        else {
            throw LiveSpeechPipelineError.operationFailed(
                "Unable to create \(url.path)."
            )
        }
        do {
            self.writer = try FileHandle(forWritingTo: url)
            self.reader = try FileHandle(forReadingFrom: url)
        } catch {
            throw LiveSpeechPipelineError.operationFailed(
                "Opening \(url.path) failed: \(error.localizedDescription)"
            )
        }
    }

    func append(_ window: LiveSpeechWindow) throws {
        guard !isWriterClosed, !isDiscarded else {
            throw LiveSpeechPipelineError.operationFailed(
                "Writing to the closed speech spool at \(url.path) was refused."
            )
        }
        guard window.source == source else {
            throw LiveSpeechPipelineError.operationFailed(
                "A \(window.source.rawValue) window reached the \(source.rawValue) spool."
            )
        }
        guard
            window.samples.count <= Int(UInt32.max),
            window.overlapSampleCount >= 0,
            window.overlapSampleCount <= Int(UInt32.max)
        else {
            throw LiveSpeechPipelineError.operationFailed(
                "A live speech window is too large to spool."
            )
        }

        var record = Data(
            capacity: 28 + window.samples.count * 4
        )
        Self.append(window.firstSampleIndex, to: &record)
        Self.append(window.speechSegmentIndex, to: &record)
        Self.append(UInt32(window.overlapSampleCount), to: &record)
        Self.append(UInt32(window.samples.count), to: &record)
        Self.append(window.isFinalWindow ? UInt32(1) : UInt32(0), to: &record)
        for sample in window.samples {
            Self.append(sample.bitPattern, to: &record)
        }
        try writer.write(contentsOf: record)
    }

    func next() throws -> LiveSpeechWindow? {
        guard !isDiscarded else {
            throw LiveSpeechPipelineError.sessionNotActive
        }
        guard let header = try readExactly(28) else {
            return nil
        }
        let firstSampleIndex = Self.decodeUInt64(header, offset: 0)
        let segmentIndex = Self.decodeUInt64(header, offset: 8)
        let overlap = Self.decodeUInt32(header, offset: 16)
        let sampleCount = Self.decodeUInt32(header, offset: 20)
        let flags = Self.decodeUInt32(header, offset: 24)
        guard
            sampleCount > 0,
            sampleCount <= 1_000_000,
            overlap < sampleCount,
            flags <= 1
        else {
            throw LiveSpeechPipelineError.malformedWindowSpool(url)
        }
        guard
            let sampleData = try readExactly(Int(sampleCount) * 4)
        else {
            throw LiveSpeechPipelineError.malformedWindowSpool(url)
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(sampleCount))
        for index in 0..<Int(sampleCount) {
            samples.append(
                Float(
                    bitPattern: Self.decodeUInt32(
                        sampleData,
                        offset: index * 4
                    )
                )
            )
        }
        return LiveSpeechWindow(
            source: source,
            speechSegmentIndex: segmentIndex,
            firstSampleIndex: firstSampleIndex,
            trackStartTime: trackStartTime,
            overlapSampleCount: Int(overlap),
            isFinalWindow: flags == 1,
            samples: samples
        )
    }

    func finishWriting() throws {
        guard !isWriterClosed else {
            return
        }
        try writer.synchronize()
        try writer.close()
        isWriterClosed = true
    }

    func discard() throws {
        guard !isDiscarded else {
            return
        }
        var failures: [String] = []
        if !isWriterClosed {
            do {
                try writer.close()
                isWriterClosed = true
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        do {
            try reader.close()
        } catch {
            failures.append(error.localizedDescription)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        isDiscarded = true
        if !failures.isEmpty {
            throw LiveSpeechPipelineError.operationFailed(
                failures.joined(separator: " ")
            )
        }
    }

    private func readExactly(_ count: Int) throws -> Data? {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard
                let next = try reader.read(
                    upToCount: count - result.count
                ),
                !next.isEmpty
            else {
                break
            }
            result.append(next)
        }
        if result.isEmpty {
            return nil
        }
        guard result.count == count else {
            throw LiveSpeechPipelineError.malformedWindowSpool(url)
        }
        return result
    }

    private static func append(
        _ value: UInt32,
        to data: inout Data
    ) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) {
            data.append(contentsOf: $0)
        }
    }

    private static func append(
        _ value: UInt64,
        to data: inout Data
    ) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) {
            data.append(contentsOf: $0)
        }
    }

    private static func decodeUInt32(
        _ data: Data,
        offset: Int
    ) -> UInt32 {
        var result: UInt32 = 0
        for byteOffset in 0..<4 {
            let index = data.index(
                data.startIndex,
                offsetBy: offset + byteOffset
            )
            result |= UInt32(data[index]) << UInt32(byteOffset * 8)
        }
        return result
    }

    private static func decodeUInt64(
        _ data: Data,
        offset: Int
    ) -> UInt64 {
        var result: UInt64 = 0
        for byteOffset in 0..<8 {
            let index = data.index(
                data.startIndex,
                offsetBy: offset + byteOffset
            )
            result |= UInt64(data[index]) << UInt64(byteOffset * 8)
        }
        return result
    }
}
