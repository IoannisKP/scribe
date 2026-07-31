import Foundation

/// A post-resampling block from one capture source.
///
/// Blocks are delivered only from the non-realtime consumer, after the same
/// canonical samples have been committed to the session WAV. The sample index
/// is relative to the beginning of that source's WAV.
public struct CanonicalAudioBlock: Equatable, Sendable {
    public let source: AudioSource
    public let firstSampleIndex: UInt64
    public let samples: [Float]

    public init(
        source: AudioSource,
        firstSampleIndex: UInt64,
        samples: [Float]
    ) {
        self.source = source
        self.firstSampleIndex = firstSampleIndex
        self.samples = samples
    }

    public var startTime: TimeInterval {
        Double(firstSampleIndex) / CanonicalAudioFormat.sampleRate
    }

    public var duration: TimeInterval {
        Double(samples.count) / CanonicalAudioFormat.sampleRate
    }
}

/// Optional live destination for canonical capture blocks.
///
/// Implementations must return promptly and bound their memory use. Failures
/// belong to the live pipeline and must be represented by the sink's state;
/// they do not invalidate audio already committed to the session WAV.
public protocol CanonicalAudioBlockSink: Sendable {
    func receive(_ block: CanonicalAudioBlock) async
}
