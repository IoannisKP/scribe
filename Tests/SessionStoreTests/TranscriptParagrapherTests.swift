import AudioCapture
import Foundation
import SessionStore
import SpeechPipeline
import XCTest

final class TranscriptParagrapherTests: XCTestCase {
    func testSentenceEndingWithMoreThanFourHundredMillisecondPauseBreaks() {
        let segment = makeSegment([
            word("First.", 0, 0.5),
            word("Second", 1.001, 1.4)
        ])

        let paragraphs = TranscriptParagrapher.paragraphs(from: [segment])

        XCTAssertEqual(paragraphs.map(\.text), ["First.", "Second"])
        XCTAssertEqual(paragraphs.map(\.startTime), [0, 1.001])
    }

    func testExactlyFourHundredMillisecondPauseDoesNotBreak() {
        let segment = makeSegment([
            word("First.", 0, 0.5),
            word("Second", 0.9, 1.4)
        ])

        XCTAssertEqual(
            TranscriptParagrapher.paragraphs(from: [segment]).map(\.text),
            ["First. Second"]
        )
    }

    func testDurationCeilingBreaksAtLatestSentenceEndingInSpan() {
        let segment = makeSegment([
            word("Opening", 0, 0.2),
            word("sentence.", 20, 20.2),
            word("Still", 20.2, 44.9),
            word("going", 44.9, 45.1)
        ])

        let paragraphs = TranscriptParagrapher.paragraphs(
            from: [segment],
            configuration: .init(
                sentencePauseThreshold: 30,
                maximumDuration: 45
            )
        )

        XCTAssertEqual(
            paragraphs.map(\.text),
            ["Opening sentence.", "Still going"]
        )
    }

    func testDurationCeilingWithoutSentenceUsesLargestWordGap() {
        let segment = makeSegment([
            word("alpha", 0, 1),
            word("beta", 16, 17),
            word("gamma", 30, 44.5),
            word("delta", 45, 46)
        ])

        let paragraphs = TranscriptParagrapher.paragraphs(from: [segment])

        XCTAssertEqual(
            paragraphs.map(\.text),
            ["alpha", "beta gamma delta"]
        )
    }

    func testSpeakerAndSourceChangesAlwaysForceParagraphs() {
        let segments = [
            makeSegment(
                [word("One", 0, 0.2)],
                source: .microphone,
                speakerID: "local-a"
            ),
            makeSegment(
                [word("Two", 0.2, 0.4)],
                source: .microphone,
                speakerID: "local-b"
            ),
            makeSegment(
                [word("Three", 0.4, 0.6)],
                source: .system,
                speakerID: "remote-a"
            )
        ]

        let paragraphs = TranscriptParagrapher.paragraphs(from: segments)

        XCTAssertEqual(paragraphs.map(\.text), ["One", "Two", "Three"])
        XCTAssertEqual(
            paragraphs.map(\.speakerID),
            ["local-a", "local-b", "remote-a"]
        )
    }

    func testAdjacentSegmentsForSameSpeakerShareParagraphRules() {
        let segments = [
            makeSegment(
                [word("A sentence.", 0, 0.5)],
                speakerID: "speaker"
            ),
            makeSegment(
                [word("Next thought", 1.1, 1.5)],
                speakerID: "speaker"
            )
        ]

        XCTAssertEqual(
            TranscriptParagrapher.paragraphs(from: segments).map(\.text),
            ["A sentence.", "Next thought"]
        )
    }

    func testSegmentWithoutWordTimingsFallsBackWithoutChangingText() {
        let segment = TranscriptSegment(
            text: "Exact provider text -- unchanged.",
            startTime: 7,
            endTime: 12,
            source: .imported,
            speakerID: nil,
            words: nil
        )

        let paragraphs = TranscriptParagrapher.paragraphs(from: [segment])

        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].text, segment.text)
        XCTAssertEqual(paragraphs[0].startTime, 7)
        XCTAssertEqual(paragraphs[0].endTime, 12)
        XCTAssertNil(paragraphs[0].words)
    }

    func testUnorderedOrMismatchedWordsNeverLoseProviderText() {
        let segment = TranscriptSegment(
            text: "Provider included extra text",
            startTime: 0,
            endTime: 2,
            source: .microphone,
            words: [
                word("text", 1, 1.2),
                word("Provider", 0, 0.2)
            ]
        )

        let paragraphs = TranscriptParagrapher.paragraphs(from: [segment])

        XCTAssertEqual(paragraphs.map(\.text), [segment.text])
        XCTAssertNil(paragraphs[0].words)
    }

    private func makeSegment(
        _ words: [WordTiming],
        source: AudioSource = .microphone,
        speakerID: String? = nil
    ) -> TranscriptSegment {
        let ordered = words.sorted { $0.startTime < $1.startTime }
        return TranscriptSegment(
            text: ordered.map(\.text).joined(separator: " "),
            startTime: ordered.first?.startTime ?? 0,
            endTime: ordered.last?.endTime ?? 0,
            source: source,
            speakerID: speakerID,
            words: words
        )
    }

    private func word(
        _ text: String,
        _ start: TimeInterval,
        _ end: TimeInterval
    ) -> WordTiming {
        WordTiming(text: text, startTime: start, endTime: end)
    }
}
