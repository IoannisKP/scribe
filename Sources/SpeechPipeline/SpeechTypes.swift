import AudioCapture
import Foundation

public struct AudioChunk: Equatable, Sendable {
    public let samples: [Float]
    public let startTime: TimeInterval
    public let source: AudioSource

    public init(
        samples: [Float],
        startTime: TimeInterval,
        source: AudioSource
    ) {
        self.samples = samples
        self.startTime = startTime
        self.source = source
    }

    public var duration: TimeInterval {
        Double(samples.count) / CanonicalAudioFormat.sampleRate
    }

    public var endTime: TimeInterval {
        startTime + duration
    }
}

public struct WordTiming: Equatable, Sendable {
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let confidence: Float?

    public init(
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Float? = nil
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

extension Array where Element == WordTiming {
    var orderedByAbsoluteTime: [WordTiming] {
        enumerated().sorted { lhs, rhs in
            if lhs.element.startTime != rhs.element.startTime {
                return lhs.element.startTime < rhs.element.startTime
            }
            if lhs.element.endTime != rhs.element.endTime {
                return lhs.element.endTime < rhs.element.endTime
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

public struct TranscriptSegment: Equatable, Sendable {
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let source: AudioSource
    public let speakerID: String?
    public let confidence: Float?
    public let words: [WordTiming]?

    public init(
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        source: AudioSource,
        speakerID: String? = nil,
        confidence: Float? = nil,
        words: [WordTiming]? = nil
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.source = source
        self.speakerID = speakerID
        self.confidence = confidence
        self.words = words
    }
}

public protocol TranscriptionEngine: Sendable {
    var identifier: String { get }
    var supportsStreaming: Bool { get }
    var requiresNetwork: Bool { get }
    var supportedLanguages: [String] { get }
    var preferredWindowDuration: TimeInterval { get }
    var preferredOverlap: TimeInterval { get }

    func prepare() async throws
    func transcribe(_ chunk: AudioChunk) async throws
        -> [TranscriptSegment]
    func finish() async throws -> [TranscriptSegment]
    func unload() async
}

public extension TranscriptionEngine {
    var preferredWindowDuration: TimeInterval { 14 }
    var preferredOverlap: TimeInterval { 1.5 }
}

public enum SpeechPipelineError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case invalidChunkDuration(TimeInterval)
    case invalidChunkOverlap(TimeInterval)
    case invalidTrackStartTime(TimeInterval)
    case unsupportedAudioFormat(
        url: URL,
        sampleRate: Double,
        channelCount: UInt32,
        formatDescription: String
    )
    case audioBufferAllocationFailed(URL)
    case audioFileProducedNoSamples(URL)
    case transcriptionAlreadyRunning
    case invalidSegmentTiming(
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval
    )
    case invalidWordTiming(
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval
    )
    case segmentSourceMismatch(
        expected: AudioSource,
        actual: AudioSource
    )
    case batchTranscriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidChunkDuration(duration):
            "Audio chunk duration must be finite and positive; received \(duration)."
        case let .invalidChunkOverlap(overlap):
            "Audio chunk overlap must be finite, nonnegative, and shorter than the chunk; received \(overlap)."
        case let .invalidTrackStartTime(startTime):
            "Audio track start time must be finite and nonnegative; received \(startTime)."
        case let .unsupportedAudioFormat(
            url,
            sampleRate,
            channelCount,
            formatDescription
        ):
            "The audio file at \(url.path) is not supported canonical audio. Expected 16 kHz mono Int16 PCM or legacy Float32; received rate \(sampleRate), channels \(channelCount), format \(formatDescription)."
        case let .audioBufferAllocationFailed(url):
            "Unable to allocate a bounded read buffer for \(url.path)."
        case let .audioFileProducedNoSamples(url):
            "The audio file at \(url.path) ended before its declared samples could be read."
        case .transcriptionAlreadyRunning:
            "A batch transcription is already running."
        case let .invalidSegmentTiming(text, startTime, endTime):
            "The transcription engine returned invalid timing \(startTime)–\(endTime) for “\(text)”."
        case let .invalidWordTiming(text, startTime, endTime):
            "The transcription engine returned invalid word timing \(startTime)–\(endTime) for “\(text)”."
        case let .segmentSourceMismatch(expected, actual):
            "The transcription engine returned \(actual.rawValue) output while processing the \(expected.rawValue) track."
        case let .batchTranscriptionFailed(message):
            "Batch transcription failed: \(message)"
        }
    }
}
