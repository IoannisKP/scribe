import AudioCapture
@testable import SpeechPipeline
import XCTest

final class TranscriptOverlapDeduplicatorTests: XCTestCase {
    func testRemovesMatchingWordTimingPrefixAtWindowSeam() {
        let previous = TranscriptSegment(
            text: "hello brave new world",
            startTime: 0,
            endTime: 10,
            source: .microphone,
            words: [
                word("hello", 0, 1),
                word("brave", 3, 4),
                word("new", 8, 9),
                word("world", 9, 10),
            ]
        )
        let current = TranscriptSegment(
            text: "new world today agenda",
            startTime: 8,
            endTime: 14,
            source: .microphone,
            words: [
                word("new", 8, 9),
                word("world", 9, 10),
                word("today", 11, 12),
                word("agenda", 13, 14),
            ]
        )

        let result = TranscriptOverlapDeduplicator.deduplicate(
            previous: previous,
            current: current
        )

        XCTAssertEqual(result?.text, "today agenda")
        XCTAssertEqual(result?.startTime, 11)
        XCTAssertEqual(result?.words?.map(\.text), ["today", "agenda"])
    }

    func testFallsBackToNormalizedTextTokens() {
        let previous = TranscriptSegment(
            text: "We agreed: ship Friday.",
            startTime: 0,
            endTime: 5,
            source: .system
        )
        let current = TranscriptSegment(
            text: "ship Friday then review metrics",
            startTime: 4,
            endTime: 9,
            source: .system
        )

        let result = TranscriptOverlapDeduplicator.deduplicate(
            previous: previous,
            current: current
        )

        XCTAssertEqual(result?.text, "then review metrics")
        XCTAssertEqual(result?.startTime, 5)
    }

    func testDoesNotDeduplicateAcrossSourcesOrSeparatedTime() {
        let previous = TranscriptSegment(
            text: "same phrase",
            startTime: 0,
            endTime: 2,
            source: .microphone
        )
        let otherSource = TranscriptSegment(
            text: "same phrase continues",
            startTime: 1,
            endTime: 3,
            source: .system
        )
        let later = TranscriptSegment(
            text: "same phrase returns",
            startTime: 20,
            endTime: 22,
            source: .microphone
        )

        XCTAssertEqual(
            TranscriptOverlapDeduplicator.deduplicate(
                previous: previous,
                current: otherSource
            ),
            otherSource
        )
        XCTAssertEqual(
            TranscriptOverlapDeduplicator.deduplicate(
                previous: previous,
                current: later
            ),
            later
        )
    }

    func testDropsWindowThatContainsOnlyDuplicateWords() {
        let previous = TranscriptSegment(
            text: "exact duplicate",
            startTime: 0,
            endTime: 2,
            source: .system
        )
        let current = TranscriptSegment(
            text: "exact duplicate",
            startTime: 1,
            endTime: 2,
            source: .system
        )

        XCTAssertNil(
            TranscriptOverlapDeduplicator.deduplicate(
                previous: previous,
                current: current
            )
        )
    }

    private func word(
        _ text: String,
        _ start: TimeInterval,
        _ end: TimeInterval
    ) -> WordTiming {
        WordTiming(
            text: text,
            startTime: start,
            endTime: end
        )
    }
}
