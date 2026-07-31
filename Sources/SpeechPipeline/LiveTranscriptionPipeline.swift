import AudioCapture
import Foundation

public struct LiveTranscriptRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let speechSegmentIndex: UInt64
    public let segment: TranscriptSegment
    public let isFinal: Bool

    public init(
        source: AudioSource,
        speechSegmentIndex: UInt64,
        segment: TranscriptSegment,
        isFinal: Bool
    ) {
        self.id = "\(source.rawValue)-\(speechSegmentIndex)"
        self.speechSegmentIndex = speechSegmentIndex
        self.segment = segment
        self.isFinal = isFinal
    }
}

public enum LiveTranscriptionPipelineState: Equatable, Sendable {
    case idle
    case modelUnavailable(reason: LiveTranscriptionUnavailableReason)
    case preparing
    case running(pendingWindowCount: UInt64)
    case bufferingToDisk(pendingWindowCount: UInt64)
    case catchingUp(pendingWindowCount: UInt64)
    case finishing(pendingWindowCount: UInt64)
    case completed(finalRowCount: Int)
    case failed(message: String)

    public var isModelUnavailable: Bool {
        if case .modelUnavailable = self {
            return true
        }
        return false
    }
}

public enum LiveTranscriptionUnavailableReason: Equatable, Sendable {
    case voiceActivityModel
    case transcriptionModel
}

public struct LiveTranscriptionPipelineMetrics: Equatable, Sendable {
    public let processedWindowCount: UInt64
    public let pendingWindowCount: UInt64
    public let peakPendingWindowCount: UInt64
    public let peakInFlightSampleCount: Int
    public let peakActivePartialRowCount: Int
    public let finalRowCount: Int

    public static let zero = LiveTranscriptionPipelineMetrics(
        processedWindowCount: 0,
        pendingWindowCount: 0,
        peakPendingWindowCount: 0,
        peakInFlightSampleCount: 0,
        peakActivePartialRowCount: 0,
        finalRowCount: 0
    )
}

public struct LiveTranscriptionBackpressureConfiguration:
    Equatable,
    Sendable
{
    public var bufferingWindowCount: UInt64
    public var recoveredWindowCount: UInt64

    public static let `default` =
        LiveTranscriptionBackpressureConfiguration()

    public init(
        bufferingWindowCount: UInt64 = 3,
        recoveredWindowCount: UInt64 = 1
    ) {
        self.bufferingWindowCount = bufferingWindowCount
        self.recoveredWindowCount = recoveredWindowCount
    }
}

public enum LiveTranscriptionPipelineError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case invalidBackpressureConfiguration
    case sessionAlreadyActive
    case sessionNotActive
    case speechPipelineFailed(String)
    case segmentOutsideWindow(
        text: String,
        windowStart: TimeInterval,
        windowEnd: TimeInterval
    )
    case ambiguousFinishOutput
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBackpressureConfiguration:
            "Live transcription buffering must recover below a nonzero buffering threshold."
        case .sessionAlreadyActive:
            "A live transcription session is already active."
        case .sessionNotActive:
            "There is no active live transcription session."
        case let .speechPipelineFailed(message):
            "Live transcription stopped because speech segmentation failed: \(message)"
        case let .segmentOutsideWindow(text, start, end):
            "Live transcription returned “\(text)” outside its \(start)–\(end) second audio window."
        case .ambiguousFinishOutput:
            "The live transcription engine returned final text without a source window, so Scribe could not attribute it safely."
        case let .operationFailed(message):
            "Live transcription failed: \(message)"
        }
    }
}

protocol LiveSpeechWindowProviding: Sendable {
    func nextWindow(for source: AudioSource) async throws
        -> LiveSpeechWindow?
    func pipelineState() async -> LiveSpeechPipelineState
}

struct LiveSpeechPipelineWindowProvider:
    LiveSpeechWindowProviding,
    Sendable
{
    let pipeline: LiveSpeechPipeline

    func nextWindow(
        for source: AudioSource
    ) async throws -> LiveSpeechWindow? {
        try await pipeline.nextWindow(for: source)
    }

    func pipelineState() async -> LiveSpeechPipelineState {
        await pipeline.state
    }
}

enum LiveTranscriptionBackpressureMode: Equatable, Sendable {
    case keepingUp
    case bufferingToDisk
    case catchingUp
}

struct LiveTranscriptionBackpressureTracker: Sendable {
    private(set) var mode:
        LiveTranscriptionBackpressureMode = .keepingUp
    let configuration: LiveTranscriptionBackpressureConfiguration

    mutating func update(
        pendingWindowCount: UInt64
    ) -> LiveTranscriptionBackpressureMode {
        switch mode {
        case .keepingUp:
            if pendingWindowCount
                >= configuration.bufferingWindowCount
            {
                mode = .bufferingToDisk
            }
        case .bufferingToDisk, .catchingUp:
            if pendingWindowCount
                <= configuration.recoveredWindowCount
            {
                mode = .keepingUp
            } else {
                mode = .catchingUp
            }
        }
        return mode
    }
}

public actor LiveTranscriptionPipeline {
    public private(set) var state:
        LiveTranscriptionPipelineState = .idle
    public private(set) var metrics:
        LiveTranscriptionPipelineMetrics = .zero
    public private(set) var rows: [LiveTranscriptRow] = []

    private let windowProvider: any LiveSpeechWindowProviding
    private let engine: any TranscriptionEngine
    private let backpressureConfiguration:
        LiveTranscriptionBackpressureConfiguration

    private var drainTask: Task<Void, Never>?
    private var failureMessage: String?
    private var rowByKey: [SpeechSegmentKey: LiveTranscriptRow] = [:]
    private var workingByKey:
        [SpeechSegmentKey: WorkingTranscript] = [:]
    private var backpressureTracker: LiveTranscriptionBackpressureTracker

    public init(
        speechPipeline: LiveSpeechPipeline,
        engine: any TranscriptionEngine,
        backpressureConfiguration:
            LiveTranscriptionBackpressureConfiguration = .default
    ) throws {
        try Self.validate(backpressureConfiguration)
        self.windowProvider = LiveSpeechPipelineWindowProvider(
            pipeline: speechPipeline
        )
        self.engine = engine
        self.backpressureConfiguration = backpressureConfiguration
        self.backpressureTracker =
            LiveTranscriptionBackpressureTracker(
                configuration: backpressureConfiguration
            )
    }

    init(
        windowProvider: any LiveSpeechWindowProviding,
        engine: any TranscriptionEngine,
        backpressureConfiguration:
            LiveTranscriptionBackpressureConfiguration = .default
    ) throws {
        try Self.validate(backpressureConfiguration)
        self.windowProvider = windowProvider
        self.engine = engine
        self.backpressureConfiguration = backpressureConfiguration
        self.backpressureTracker =
            LiveTranscriptionBackpressureTracker(
                configuration: backpressureConfiguration
            )
    }

    public func beginSession() async throws {
        guard drainTask == nil else {
            throw LiveTranscriptionPipelineError.sessionAlreadyActive
        }

        state = .preparing
        do {
            try await engine.prepare()
        } catch {
            let message = error.localizedDescription
            failureMessage = message
            state = .failed(message: message)
            await engine.unload()
            throw error
        }

        metrics = .zero
        rows = []
        rowByKey = [:]
        workingByKey = [:]
        failureMessage = nil
        backpressureTracker =
            LiveTranscriptionBackpressureTracker(
                configuration: backpressureConfiguration
            )
        state = .running(pendingWindowCount: 0)
        drainTask = Task { [weak self] in
            await self?.drainWindows()
        }
    }

    public func waitUntilFinished() async throws {
        guard let drainTask else {
            throw LiveTranscriptionPipelineError.sessionNotActive
        }
        await drainTask.value
        if let failureMessage {
            throw LiveTranscriptionPipelineError.operationFailed(
                failureMessage
            )
        }
    }

    public func shutdown(
        finalState: LiveTranscriptionPipelineState = .idle
    ) async {
        drainTask?.cancel()
        await drainTask?.value
        drainTask = nil
        await engine.unload()
        workingByKey.removeAll(keepingCapacity: false)
        failureMessage = nil
        state = finalState
    }

    private func drainWindows() async {
        do {
            while !Task.isCancelled {
                let sourceState = await windowProvider.pipelineState()
                let pendingWindowCount =
                    Self.pendingWindowCount(in: sourceState)
                updateBackpressureState(
                    pendingWindowCount: pendingWindowCount,
                    sourceState: sourceState
                )

                var processedWindow = false
                for source in AudioSource.allCases {
                    guard
                        let window = try await windowProvider
                            .nextWindow(for: source)
                    else {
                        continue
                    }
                    try await process(window)
                    processedWindow = true
                }

                if processedWindow {
                    continue
                }

                switch sourceState {
                case let .failed(message):
                    throw LiveTranscriptionPipelineError
                        .speechPipelineFailed(message)
                case .completed where pendingWindowCount == 0:
                    try await finishEngine()
                    state = .completed(
                        finalRowCount: metrics.finalRowCount
                    )
                    await engine.unload()
                    return
                case .idle, .modelUnavailable:
                    throw LiveTranscriptionPipelineError
                        .speechPipelineFailed(
                            "The speech-window source stopped before completion."
                        )
                case .preparing, .running, .finishing, .completed:
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
        } catch is CancellationError {
            await engine.unload()
        } catch {
            let message = error.localizedDescription
            failureMessage = message
            state = .failed(message: message)
            await engine.unload()
        }
    }

    private func process(_ window: LiveSpeechWindow) async throws {
        let output = try await engine.transcribe(window.audioChunk)
        try Self.validate(output, for: window)

        let key = SpeechSegmentKey(
            source: window.source,
            segmentIndex: window.speechSegmentIndex
        )
        var working = workingByKey[key] ?? WorkingTranscript()
        for segment in output {
            let deduplicated =
                TranscriptOverlapDeduplicator.deduplicate(
                    previous: working.seamSegment,
                    current: segment
                )
            working.seamSegment = segment
            if let deduplicated {
                working.append(deduplicated)
            }
        }

        if let combined = working.combinedSegment {
            rowByKey[key] = LiveTranscriptRow(
                source: key.source,
                speechSegmentIndex: key.segmentIndex,
                segment: combined,
                isFinal: window.isFinalWindow
            )
            rows = Self.sortedRows(rowByKey.values)
        }

        if window.isFinalWindow {
            workingByKey[key] = nil
        } else {
            workingByKey[key] = working
        }

        let sourceState = await windowProvider.pipelineState()
        let pendingWindowCount =
            Self.pendingWindowCount(in: sourceState)
        let finalRowCount = rowByKey.values.reduce(into: 0) {
            if $1.isFinal {
                $0 += 1
            }
        }
        metrics = LiveTranscriptionPipelineMetrics(
            processedWindowCount: metrics.processedWindowCount + 1,
            pendingWindowCount: pendingWindowCount,
            peakPendingWindowCount: max(
                metrics.peakPendingWindowCount,
                pendingWindowCount
            ),
            peakInFlightSampleCount: max(
                metrics.peakInFlightSampleCount,
                window.samples.count
            ),
            peakActivePartialRowCount: max(
                metrics.peakActivePartialRowCount,
                workingByKey.count
            ),
            finalRowCount: finalRowCount
        )
        updateBackpressureState(
            pendingWindowCount: pendingWindowCount,
            sourceState: sourceState
        )
    }

    private func finishEngine() async throws {
        state = .finishing(
            pendingWindowCount: metrics.pendingWindowCount
        )
        let output = try await engine.finish()
        guard output.isEmpty else {
            throw LiveTranscriptionPipelineError.ambiguousFinishOutput
        }
        guard workingByKey.isEmpty else {
            throw LiveTranscriptionPipelineError.operationFailed(
                "One or more partial transcript rows had no final speech window."
            )
        }
    }

    private func updateBackpressureState(
        pendingWindowCount: UInt64,
        sourceState: LiveSpeechPipelineState
    ) {
        if pendingWindowCount > metrics.peakPendingWindowCount {
            metrics = LiveTranscriptionPipelineMetrics(
                processedWindowCount: metrics.processedWindowCount,
                pendingWindowCount: pendingWindowCount,
                peakPendingWindowCount: pendingWindowCount,
                peakInFlightSampleCount:
                    metrics.peakInFlightSampleCount,
                peakActivePartialRowCount:
                    metrics.peakActivePartialRowCount,
                finalRowCount: metrics.finalRowCount
            )
        }
        let mode = backpressureTracker.update(
            pendingWindowCount: pendingWindowCount
        )
        switch mode {
        case .bufferingToDisk:
            state = .bufferingToDisk(
                pendingWindowCount: pendingWindowCount
            )
        case .catchingUp:
            state = .catchingUp(
                pendingWindowCount: pendingWindowCount
            )
        case .keepingUp:
            if case .finishing = sourceState {
                state = .finishing(
                    pendingWindowCount: pendingWindowCount
                )
            } else if case .completed = sourceState {
                state = .finishing(
                    pendingWindowCount: pendingWindowCount
                )
            } else {
                state = .running(
                    pendingWindowCount: pendingWindowCount
                )
            }
        }
    }

    private nonisolated static func validate(
        _ configuration: LiveTranscriptionBackpressureConfiguration
    ) throws {
        guard
            configuration.bufferingWindowCount > 0,
            configuration.recoveredWindowCount
                < configuration.bufferingWindowCount
        else {
            throw LiveTranscriptionPipelineError
                .invalidBackpressureConfiguration
        }
    }

    private nonisolated static func pendingWindowCount(
        in state: LiveSpeechPipelineState
    ) -> UInt64 {
        switch state {
        case let .running(count),
            let .finishing(count),
            let .completed(count):
            count
        case .idle, .modelUnavailable, .preparing, .failed:
            0
        }
    }

    private nonisolated static func validate(
        _ segments: [TranscriptSegment],
        for window: LiveSpeechWindow
    ) throws {
        let tolerance = 0.001
        for segment in segments {
            guard
                segment.source == window.source,
                segment.startTime.isFinite,
                segment.endTime.isFinite,
                segment.startTime >= window.startTime - tolerance,
                segment.endTime >= segment.startTime,
                segment.endTime
                    <= window.startTime + window.duration + tolerance
            else {
                if segment.source != window.source {
                    throw SpeechPipelineError.segmentSourceMismatch(
                        expected: window.source,
                        actual: segment.source
                    )
                }
                throw LiveTranscriptionPipelineError
                    .segmentOutsideWindow(
                        text: segment.text,
                        windowStart: window.startTime,
                        windowEnd: window.startTime + window.duration
                    )
            }
            if let words = segment.words {
                for word in words {
                    guard
                        word.startTime.isFinite,
                        word.endTime.isFinite,
                        word.startTime >= window.startTime - tolerance,
                        word.endTime >= word.startTime,
                        word.endTime
                            <= window.startTime
                                + window.duration
                                + tolerance
                    else {
                        throw SpeechPipelineError.invalidWordTiming(
                            text: word.text,
                            startTime: word.startTime,
                            endTime: word.endTime
                        )
                    }
                }
            }
        }
    }

    private nonisolated static func sortedRows(
        _ rows: Dictionary<SpeechSegmentKey, LiveTranscriptRow>.Values
    ) -> [LiveTranscriptRow] {
        rows.sorted { lhs, rhs in
            if TranscriptTimeline.precedes(lhs.segment, rhs.segment) {
                return true
            }
            if TranscriptTimeline.precedes(rhs.segment, lhs.segment) {
                return false
            }
            return lhs.id < rhs.id
        }
    }
}

private struct SpeechSegmentKey: Hashable, Sendable {
    let source: AudioSource
    let segmentIndex: UInt64
}

private struct WorkingTranscript: Sendable {
    var seamSegment: TranscriptSegment?
    private var acceptedSegments: [TranscriptSegment] = []

    mutating func append(_ segment: TranscriptSegment) {
        acceptedSegments.append(segment)
    }

    var combinedSegment: TranscriptSegment? {
        guard let first = acceptedSegments.first else {
            return nil
        }
        let text = acceptedSegments
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else {
            return nil
        }

        let allHaveWords = acceptedSegments.allSatisfy {
            $0.words != nil
        }
        let words: [WordTiming]?
        if allHaveWords {
            words = acceptedSegments.flatMap { $0.words ?? [] }
        } else {
            words = nil
        }
        let speakerIDs = Set(
            acceptedSegments.compactMap(\.speakerID)
        )
        return TranscriptSegment(
            text: text,
            startTime: first.startTime,
            endTime: acceptedSegments
                .map(\.endTime)
                .max() ?? first.endTime,
            source: first.source,
            speakerID:
                speakerIDs.count == 1
                ? speakerIDs.first
                : nil,
            confidence: acceptedSegments.last?.confidence,
            words: words
        )
    }
}
