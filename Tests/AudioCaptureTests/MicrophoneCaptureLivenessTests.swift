@testable import AudioCapture
import Foundation
import XCTest

/// Regression coverage for the Bluetooth capture failure observed on real
/// hardware: an AirPods input device reports a complete, self-consistent
/// 48 kHz format while it is still switching into headset mode, the tap is
/// installed against that transient format, and once the route settles to
/// 24 kHz the tap delivers nothing while `AVAudioEngine.isRunning` stays true
/// and no notification or error is raised.
final class MicrophoneCaptureLivenessTests: XCTestCase {
    private let policy = MicrophoneLivenessPolicy()

    func testNewTapIsGivenTimeBeforeItsRouteIsRebuilt() {
        XCTAssertEqual(
            policy.decide(
                hasCapturedAudio: false,
                sinceLastAcceptedFrame: .milliseconds(200),
                consecutiveRebuilds: 0
            ),
            .keepWaiting
        )
    }

    func testTapDeliveringNothingPastItsGraceRebuildsTheRoute() {
        XCTAssertEqual(
            policy.decide(
                hasCapturedAudio: false,
                sinceLastAcceptedFrame: .milliseconds(750),
                consecutiveRebuilds: 0
            ),
            .rebuildRoute
        )
    }

    func testExhaustedRebuildsFailInsteadOfRetryingForever() {
        XCTAssertEqual(
            policy.decide(
                hasCapturedAudio: false,
                sinceLastAcceptedFrame: .seconds(1),
                consecutiveRebuilds: policy.maximumConsecutiveRebuilds
            ),
            .failNoAudio
        )
    }

    /// A working microphone delivers frames continuously even in a silent
    /// room, because silence is still samples. The watchdog must therefore
    /// never treat a quiet speaker as a fault, and it never inspects level.
    func testEstablishedTapGetsMoreSlackThanANewOne() {
        XCTAssertEqual(
            policy.decide(
                hasCapturedAudio: true,
                sinceLastAcceptedFrame: .milliseconds(750),
                consecutiveRebuilds: 0
            ),
            .keepWaiting
        )
        XCTAssertEqual(
            policy.decide(
                hasCapturedAudio: false,
                sinceLastAcceptedFrame: .milliseconds(750),
                consecutiveRebuilds: 0
            ),
            .rebuildRoute
        )
    }

    func testEstablishedTapThatStopsDeliveringIsRebuilt() {
        XCTAssertEqual(
            policy.decide(
                hasCapturedAudio: true,
                sinceLastAcceptedFrame: .seconds(3),
                consecutiveRebuilds: 0
            ),
            .rebuildRoute
        )
    }

    /// The measured AirPods timeline: binding forces a transient 48 kHz
    /// reading, the device settles to its only supported rate 2.1 s later, and
    /// every tap installed before that instant delivers nothing. The default
    /// policy must span the transition and recover rather than give up.
    func testDefaultPolicyRecoversTheMeasuredAirPodsTransition() {
        let settleTime = Duration.milliseconds(2_100)
        // Stopping the engine, rebinding and restarting cost roughly this much
        // per attempt on the measured hardware.
        let rebuildCost = Duration.milliseconds(1_300)

        var elapsed = Duration.zero
        var sinceLastAcceptedFrame = Duration.zero
        var consecutiveRebuilds = 0
        var recovered = false

        for _ in 0..<200 {
            let decision = policy.decide(
                hasCapturedAudio: false,
                sinceLastAcceptedFrame: sinceLastAcceptedFrame,
                consecutiveRebuilds: consecutiveRebuilds
            )
            switch decision {
            case .keepWaiting:
                elapsed += policy.pollInterval
                sinceLastAcceptedFrame += policy.pollInterval
            case .rebuildRoute:
                consecutiveRebuilds += 1
                elapsed += rebuildCost
                sinceLastAcceptedFrame = .zero
                // A tap reinstalled after the device settles delivers audio.
                if elapsed >= settleTime {
                    recovered = true
                }
            case .failNoAudio:
                XCTFail(
                    "The policy gave up after \(consecutiveRebuilds) rebuilds and \(elapsed), before the route could settle."
                )
                return
            }
            if recovered {
                break
            }
        }

        XCTAssertTrue(
            recovered,
            "The policy never rebuilt the route after the AirPods settled."
        )
        XCTAssertLessThanOrEqual(
            consecutiveRebuilds,
            policy.maximumConsecutiveRebuilds,
            "Recovery must fit inside the rebuild budget."
        )
    }

    /// A route that never recovers must terminate, not retry indefinitely.
    func testAPermanentlyDeadRouteReachesFailure() {
        var sinceLastAcceptedFrame = Duration.zero
        var consecutiveRebuilds = 0

        for _ in 0..<1_000 {
            let decision = policy.decide(
                hasCapturedAudio: false,
                sinceLastAcceptedFrame: sinceLastAcceptedFrame,
                consecutiveRebuilds: consecutiveRebuilds
            )
            switch decision {
            case .keepWaiting:
                sinceLastAcceptedFrame += policy.pollInterval
            case .rebuildRoute:
                consecutiveRebuilds += 1
                sinceLastAcceptedFrame = .zero
            case .failNoAudio:
                XCTAssertEqual(
                    consecutiveRebuilds,
                    policy.maximumConsecutiveRebuilds
                )
                return
            }
        }

        XCTFail("A permanently dead route never reached failNoAudio.")
    }

    func testAcceptedFrameCounterAccumulatesFrameCounts() throws {
        let counter = try RealtimeCallbackCounter()
        XCTAssertEqual(counter.value, 0)
        counter.add(2_400)
        counter.add(2_400)
        XCTAssertEqual(counter.value, 4_800)
    }
}
