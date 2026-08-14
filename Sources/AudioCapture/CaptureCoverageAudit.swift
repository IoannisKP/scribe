import Foundation

public enum TrackCoverageVerdict: Equatable, Sendable {
    /// Written samples account for the elapsed recording time.
    case complete

    /// No sample was ever written. For the microphone this is always a fault,
    /// because a working input delivers frames even in a silent room. For the
    /// system track it is legitimate: a meeting where the remote side never
    /// speaks is a valid recording.
    case empty

    /// Fewer samples than the elapsed time accounts for. The canonical symptom
    /// of a resampler configured with a source rate higher than the one the
    /// hardware is actually delivering, which decimates by too large a factor
    /// and makes playback run fast.
    case undersampled(ratio: Double)

    /// More samples than the elapsed time accounts for, the mirror image of
    /// `undersampled`.
    case oversampled(ratio: Double)
}

/// Checks that a track's written sample count accounts for the time the
/// recording actually covered.
///
/// Both the empty-microphone and undersampled-system defects were invisible to
/// every format-level and header-level check, because the WAV headers were
/// correct and the resampler reported no error. Sample count against elapsed
/// time is the one assertion that catches both, so it is expressed once here
/// and reused by tests and by runtime monitoring.
public struct CaptureCoverageAudit: Equatable, Sendable {
    /// Fractional deviation tolerated before a track is called short or long.
    /// Generous enough to absorb start/stop skew between the two tracks and
    /// one resampler block, far tighter than the 1.8x and 2x deficits seen.
    public let tolerance: Double

    public init(tolerance: Double = 0.10) {
        self.tolerance = tolerance
    }

    public func expectedSampleCount(
        forDuration duration: TimeInterval
    ) -> UInt64 {
        guard duration > 0 else {
            return 0
        }
        return UInt64((duration * CanonicalAudioFormat.sampleRate).rounded())
    }

    public func verdict(
        capturedSampleCount: UInt64,
        expectedSampleCount: UInt64
    ) -> TrackCoverageVerdict {
        guard capturedSampleCount > 0 else {
            return .empty
        }
        guard expectedSampleCount > 0 else {
            return .complete
        }
        let ratio = Double(capturedSampleCount) / Double(expectedSampleCount)
        if ratio < 1 - tolerance {
            return .undersampled(ratio: ratio)
        }
        if ratio > 1 + tolerance {
            return .oversampled(ratio: ratio)
        }
        return .complete
    }

    public func verdict(
        capturedSampleCount: UInt64,
        duration: TimeInterval
    ) -> TrackCoverageVerdict {
        verdict(
            capturedSampleCount: capturedSampleCount,
            expectedSampleCount: expectedSampleCount(forDuration: duration)
        )
    }
}
