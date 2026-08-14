import AudioCapture
@testable import SessionStore
import SpeechPipeline
import XCTest

final class SessionTitleDerivationTests: XCTestCase {
    private func segment(
        _ text: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            text: text,
            startTime: start,
            endTime: end,
            source: .microphone,
            speakerID: nil,
            confidence: nil,
            words: nil
        )
    }

    // MARK: - From a summary

    func testTitleComesFromTheSummaryHeadingWhenOneExists() {
        let derived = SessionTitleDerivation.fromSummary(
            """
            # Pricing page rebuild

            The team agreed to ship the new pricing page next week.
            """
        )
        XCTAssertEqual(derived?.title, "Pricing page rebuild")
        XCTAssertEqual(derived?.source, .summary)
    }

    func testSummaryWithoutAHeadingUsesItsFirstLine() {
        let derived = SessionTitleDerivation.fromSummary(
            "Quarterly budget review and headcount planning for the platform team."
        )
        XCTAssertEqual(derived?.source, .summary)
        // Trimmed to at most six words.
        XCTAssertEqual(
            derived?.title.split(separator: " ").count,
            6
        )
    }

    func testEmptySummaryYieldsNoTitle() {
        XCTAssertNil(SessionTitleDerivation.fromSummary("   \n\n  "))
    }

    // MARK: - Keyword extraction

    func testKeywordExtractionNamesTheSubjectOfTheConversation() {
        let segments = [
            segment("Hey, can you hear me? Testing the microphone.", start: 0, end: 12),
            segment("Okay so the pricing page needs a rebuild.", start: 25, end: 31),
            segment("Right, the pricing tiers are confusing on that page.", start: 32, end: 39),
            segment("I think the rebuild should simplify the pricing.", start: 40, end: 47)
        ]

        let derived = SessionTitleDerivation.fromTranscript(segments)
        let title = derived?.title.lowercased() ?? ""

        XCTAssertEqual(derived?.source, .keywords)
        XCTAssertTrue(title.contains("pricing"), title)
        XCTAssertTrue(
            title.contains("page") || title.contains("rebuild"),
            title
        )
        XCTAssertLessThanOrEqual(title.split(separator: " ").count, 3)
    }

    /// Greetings and audio checks must not decide the title.
    func testOpeningTwentySecondsAreIgnored() {
        let segments = [
            segment(
                "Testing testing microphone microphone microphone check check check",
                start: 0,
                end: 18
            ),
            segment("The warehouse inventory migration starts Monday.", start: 25, end: 31),
            segment("Inventory counts move to the new warehouse system.", start: 32, end: 39),
            segment("Migration of inventory is the priority.", start: 40, end: 47)
        ]

        let title = SessionTitleDerivation.fromTranscript(segments)?
            .title.lowercased() ?? ""
        XCTAssertFalse(title.contains("microphone"), title)
        XCTAssertTrue(
            title.contains("inventory") || title.contains("warehouse"),
            title
        )
    }

    /// The quality floor. A bad title is worse than no title, so filler-only
    /// speech must produce nothing and leave the date-and-time name in place.
    func testFillerOnlyTranscriptIsRejectedByTheQualityFloor() {
        let segments = [
            segment("Yeah, I think so, actually.", start: 25, end: 30),
            segment("Right, yeah, I mean, you know.", start: 31, end: 36),
            segment("Okay. Sure. Well, yeah.", start: 37, end: 42)
        ]
        XCTAssertNil(
            SessionTitleDerivation.fromTranscript(segments),
            "Filler produced a title instead of preserving the date name."
        )
    }

    func testSingleContentWordIsBelowTheFloor() {
        let segments = [
            segment("Budget.", start: 25, end: 27),
            segment("Budget again.", start: 28, end: 30)
        ]
        XCTAssertNil(SessionTitleDerivation.fromTranscript(segments))
    }

    /// A word repeated inside one segment is not what a session is about.
    func testWordSpreadIsPreferredOverRepetitionInOneSegment() {
        let segments = [
            segment(
                "Deadline deadline deadline deadline deadline.",
                start: 25,
                end: 31
            ),
            segment("The invoice needs approval.", start: 32, end: 38),
            segment("Approval of the invoice is pending.", start: 39, end: 45),
            segment("Invoice approval today.", start: 46, end: 50)
        ]
        let title = SessionTitleDerivation.fromTranscript(segments)?
            .title.lowercased() ?? ""
        XCTAssertTrue(title.contains("invoice"), title)
        XCTAssertTrue(title.contains("approval"), title)
    }

    func testTranscriptShorterThanTheIgnoredOpeningYieldsNoTitle() {
        let segments = [segment("Hello, testing.", start: 0, end: 12)]
        XCTAssertNil(SessionTitleDerivation.fromTranscript(segments))
    }

    // MARK: - Model replies

    func testModelReplyIsStrippedOfQuotesAndPunctuation() {
        let derived = SessionTitleDerivation.fromModelReply(
            "\"Pricing page rebuild.\"\n",
            source: .localModel
        )
        XCTAssertEqual(derived?.title, "Pricing page rebuild")
        XCTAssertEqual(derived?.source, .localModel)
    }

    func testModelReplyWithNothingUsableYieldsNoTitle() {
        XCTAssertNil(
            SessionTitleDerivation.fromModelReply("\n\n", source: .localModel)
        )
    }

    func testTitlesNeverContainPathSeparators() {
        let derived = SessionTitleDerivation.fromModelReply(
            "Q3 planning / budget: review",
            source: .cloudModel
        )
        let title = try? XCTUnwrap(derived?.title)
        XCTAssertFalse(title?.contains("/") == true, title ?? "nil")
        XCTAssertFalse(title?.contains(":") == true, title ?? "nil")
    }

    // MARK: - Excerpting, which bounds what any provider ever receives

    func testExcerptStopsAtTheDurationCap() {
        let segments = [
            segment("Opening remarks about the roadmap.", start: 0, end: 20),
            segment("Still within the first three minutes.", start: 100, end: 120),
            segment("Well past the cap and must not be sent.", start: 400, end: 420)
        ]
        let excerpt = SessionTitleDerivation.transcriptExcerpt(segments)
        XCTAssertTrue(excerpt.contains("roadmap"))
        XCTAssertTrue(excerpt.contains("three minutes"))
        XCTAssertFalse(
            excerpt.contains("must not be sent"),
            "Transcript beyond the cap leaked into the prompt."
        )
    }

    func testExcerptStopsAtTheCharacterCap() {
        let segments = (0..<200).map { index in
            segment(
                "Segment number \(index) discussing the platform migration.",
                start: TimeInterval(index) / 2,
                end: TimeInterval(index) / 2 + 0.4
            )
        }
        let excerpt = SessionTitleDerivation.transcriptExcerpt(segments)
        XCTAssertLessThanOrEqual(excerpt.count, 4_000)
    }

    // MARK: - The user's own title is never overwritten

    func testUserSetTitlesAreNotReplaceableByGeneration() {
        XCTAssertFalse(SessionTitleSource.userSet.isReplaceableByGeneration)
        XCTAssertFalse(SessionTitleSource.summary.isReplaceableByGeneration)
        XCTAssertFalse(SessionTitleSource.localModel.isReplaceableByGeneration)
        XCTAssertFalse(SessionTitleSource.cloudModel.isReplaceableByGeneration)
        XCTAssertTrue(SessionTitleSource.dateTime.isReplaceableByGeneration)
        XCTAssertTrue(SessionTitleSource.keywords.isReplaceableByGeneration)
    }
}
