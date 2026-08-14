import Foundation

/// What the microphone service should do about a tap that is not delivering
/// audio.
///
/// A tap that is working delivers frames continuously even in a silent room,
/// because silence is still samples. An installed tap that delivers nothing is
/// therefore always a fault, never quietness, and this type never has to guess
/// about signal level.
public enum MicrophoneLivenessDecision: Equatable, Sendable {
    /// The tap is delivering, or has not yet used up its grace period.
    case keepWaiting

    /// Rebind the current input route and reinstall the tap.
    case rebuildRoute

    /// Rebuilding has not restored audio within the configured budget.
    case failNoAudio
}

/// Timing policy for proving that an installed microphone tap actually
/// delivers audio.
///
/// A Bluetooth input device can report a complete, self-consistent format while
/// it is still switching into headset mode, and a tap installed against that
/// transient format keeps `AVAudioEngine.isRunning` true while delivering
/// nothing. No Core Audio property distinguishes the transient state from the
/// settled one, so the service waits for frames instead of waiting for a
/// property.
public struct MicrophoneLivenessPolicy: Equatable, Sendable {
    /// How long a freshly installed tap may deliver nothing before its route
    /// is treated as stale. AirPods settle into headset mode roughly two
    /// seconds after binding, so several short attempts span the transition
    /// without making a healthy built-in microphone wait.
    public let firstFrameGrace: Duration

    /// How long an established tap may deliver nothing before it is rebuilt.
    /// Longer than `firstFrameGrace` because an established route only stops
    /// for a real interruption.
    public let deliveryGap: Duration

    /// How often the watchdog samples the accepted-frame counter.
    public let pollInterval: Duration

    /// How many consecutive rebuilds may be attempted before the recording is
    /// failed. Reset as soon as frames arrive.
    public let maximumConsecutiveRebuilds: Int

    public init(
        firstFrameGrace: Duration = .milliseconds(750),
        deliveryGap: Duration = .seconds(3),
        pollInterval: Duration = .milliseconds(100),
        maximumConsecutiveRebuilds: Int = 6
    ) {
        self.firstFrameGrace = firstFrameGrace
        self.deliveryGap = deliveryGap
        self.pollInterval = pollInterval
        self.maximumConsecutiveRebuilds = maximumConsecutiveRebuilds
    }

    /// - Parameters:
    ///   - hasCapturedAudio: whether any frame has been accepted since the
    ///     recording started.
    ///   - sinceLastAcceptedFrame: elapsed time since the last accepted frame,
    ///     measured from the most recent tap installation when no frame has
    ///     ever been accepted.
    ///   - consecutiveRebuilds: rebuilds attempted since audio last arrived.
    public func decide(
        hasCapturedAudio: Bool,
        sinceLastAcceptedFrame: Duration,
        consecutiveRebuilds: Int
    ) -> MicrophoneLivenessDecision {
        let tolerated = hasCapturedAudio ? deliveryGap : firstFrameGrace
        guard sinceLastAcceptedFrame >= tolerated else {
            return .keepWaiting
        }
        guard consecutiveRebuilds >= maximumConsecutiveRebuilds else {
            return .rebuildRoute
        }
        return .failNoAudio
    }
}
