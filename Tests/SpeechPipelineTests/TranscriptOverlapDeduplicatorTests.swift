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

    func testTimedOverlapDoesNotRequireMatchingBoundaryText() {
        let previous = TranscriptSegment(
            text: "will test the offline transition",
            startTime: 0,
            endTime: 5,
            source: .microphone,
            words: [
                word("will", 1, 2),
                word("test", 2, 3),
                word("the", 3, 3.5),
                word("offline", 3.5, 4.25),
                word("transition", 4.25, 5),
            ]
        )
        let current = TranscriptSegment(
            text: "will test the offline transcription workflow",
            startTime: 3,
            endTime: 7,
            source: .microphone,
            words: [
                word("will", 3, 3.5),
                word("test", 3.5, 4),
                word("the", 4, 4.25),
                word("offline", 4.25, 4.75),
                word("transcription", 4.75, 5.5),
                word("workflow", 5.5, 7),
            ]
        )

        let result = TranscriptOverlapDeduplicator.deduplicate(
            previous: previous,
            current: current
        )

        XCTAssertEqual(result?.text, "workflow")
        XCTAssertEqual(result?.startTime, 5.5)
        XCTAssertEqual(result?.words?.map(\.text), ["workflow"])
    }

    func testTimedEndpointToleranceRemovesCorruptedBoundaryWord() {
        let previous = TranscriptSegment(
            text: "timestamps help every",
            startTime: 1,
            endTime: 5,
            source: .microphone,
            words: [
                word("timestamps", 1, 3),
                word("help", 3, 4),
                word("every", 4, 5),
            ]
        )
        let current = TranscriptSegment(
            text: "everyone understand",
            startTime: 5.14,
            endTime: 7,
            source: .microphone,
            words: [
                word("everyone", 5.14, 6),
                word("understand", 6, 7),
            ]
        )

        let result = TranscriptOverlapDeduplicator.deduplicate(
            previous: previous,
            current: current
        )

        XCTAssertEqual(result?.text, "understand")
        XCTAssertEqual(result?.words?.map(\.text), ["understand"])
    }

    func testTimedDeduplicationOrdersUnorderedRemainderByTime() {
        let previous = TranscriptSegment(
            text: "hello world",
            startTime: 0,
            endTime: 2,
            source: .microphone,
            words: [
                word("world", 1, 2),
                word("hello", 0, 1),
            ]
        )
        let current = TranscriptSegment(
            text: "world agenda today",
            startTime: 1.5,
            endTime: 4,
            source: .microphone,
            words: [
                word("today", 3, 4),
                word("world", 1.5, 2),
                word("agenda", 2.5, 3),
            ]
        )

        let result = TranscriptOverlapDeduplicator.deduplicate(
            previous: previous,
            current: current
        )

        XCTAssertEqual(result?.text, "agenda today")
        XCTAssertEqual(result?.startTime, 2.5)
        XCTAssertEqual(result?.endTime, 4)
        XCTAssertEqual(result?.words?.map(\.text), ["agenda", "today"])
    }

    func testFinalizedBoundaryCanPreferCompleteCurrentRendering() {
        let previous = TranscriptSegment(
            text: "clear time step camps",
            startTime: 0,
            endTime: 1,
            source: .microphone,
            words: [
                word("clear", 0, 0.5),
                word("time", 0.76, 0.80),
                word("step", 0.80, 0.90),
                word("camps", 0.90, 1),
            ]
        )
        let current = TranscriptSegment(
            text: "timestamps help everyone",
            startTime: 0.75,
            endTime: 2,
            source: .microphone,
            words: [
                word("timestamps", 0.75, 1.05),
                word("help", 1.10, 1.40),
                word("everyone", 1.50, 2),
            ]
        )

        for tolerance in [0.125, 0.250, 0.500] {
            let reconciled =
                TranscriptOverlapDeduplicator
                    .reconcilePreferringCurrent(
                        previous: previous,
                        current: current,
                        overlapStartTime: 0.75,
                        overlapTimingTolerance: tolerance
                    )

            XCTAssertEqual(reconciled.previous?.text, "clear")
            XCTAssertEqual(
                reconciled.current.text,
                "timestamps help everyone"
            )
            XCTAssertNotEqual(
                reconciled.previous?.words?.last?.text,
                reconciled.current.words?.first?.text
            )
        }
    }

    func testBatchStitchPrefersCompleteCurrentRendering() {
        let previous = TranscriptSegment(
            text: "clear time step camps",
            startTime: 0,
            endTime: 1,
            source: .microphone,
            words: [
                word("clear", 0, 0.5),
                word("time", 0.76, 0.80),
                word("step", 0.80, 0.90),
                word("camps", 0.90, 1),
            ]
        )
        let current = TranscriptSegment(
            text: "timestamps help everyone",
            startTime: 0.75,
            endTime: 2,
            source: .microphone,
            words: [
                word("timestamps", 0.75, 1.05),
                word("help", 1.10, 1.40),
                word("everyone", 1.50, 2),
            ]
        )

        let result = TranscriptOverlapDeduplicator.stitch(
            [previous, current]
        )

        XCTAssertEqual(result.map(\.text), ["clear", "timestamps help everyone"])
        XCTAssertEqual(
            result.flatMap { $0.words ?? [] }.map(\.text),
            ["clear", "timestamps", "help", "everyone"]
        )
    }

    func testBatchStitchRemovesPreviousWordWhoseSpanCrossesSeam() {
        let previous = TranscriptSegment(
            text: "clear transition",
            startTime: 0,
            endTime: 1,
            source: .microphone,
            words: [
                word("clear", 0, 0.5),
                word("transition", 0.70, 1),
            ]
        )
        let current = TranscriptSegment(
            text: "transcription continues",
            startTime: 0.75,
            endTime: 2,
            source: .microphone,
            words: [
                word("transcription", 0.75, 1.05),
                word("continues", 1.10, 2),
            ]
        )

        let result = TranscriptOverlapDeduplicator.stitch(
            [previous, current]
        )

        XCTAssertEqual(result.map(\.text), ["clear", "transcription continues"])
        XCTAssertEqual(
            result.flatMap { $0.words ?? [] }.map(\.text),
            ["clear", "transcription", "continues"]
        )
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

    func testUntimedFallbackToleratesMismatchedFinalBoundaryToken() {
        let previous = TranscriptSegment(
            text: "will test the offline transition",
            startTime: 0,
            endTime: 5,
            source: .system
        )
        let current = TranscriptSegment(
            text: "will test the offline transcription workflow",
            startTime: 4,
            endTime: 8,
            source: .system
        )

        let result = TranscriptOverlapDeduplicator.deduplicate(
            previous: previous,
            current: current
        )

        XCTAssertEqual(result?.text, "workflow")
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
