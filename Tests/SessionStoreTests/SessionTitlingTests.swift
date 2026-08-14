import AudioCapture
@testable import SessionStore
import SpeechPipeline
import XCTest

/// Records every prompt a provider was asked to complete, so a test can assert
/// on what would have left the Mac rather than on whether a flag was set.
private actor PromptRecorder {
    private(set) var prompts: [String] = []
    private let reply: String?

    init(reply: String?) {
        self.reply = reply
    }

    func complete(_ prompt: String) throws -> String {
        prompts.append(prompt)
        guard let reply else {
            throw SessionTitlingTestError.providerUnavailable
        }
        return reply
    }
}

private enum SessionTitlingTestError: Error {
    case providerUnavailable
}

final class SessionTitlingTests: XCTestCase {
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

    private var substantiveTranscript: [TranscriptSegment] {
        [
            segment("Hey, can you hear me?", start: 0, end: 10),
            segment("The pricing page needs a rebuild.", start: 25, end: 31),
            segment("Right, the pricing tiers confuse people.", start: 32, end: 39),
            segment("So the rebuild simplifies pricing.", start: 40, end: 47)
        ]
    }

    private func input(
        summary: String? = nil,
        transcript: [TranscriptSegment]? = nil,
        titleSource: SessionTitleSource = .dateTime
    ) -> SessionTitlingInput {
        SessionTitlingInput(
            summaryMarkdown: summary,
            transcript: transcript ?? substantiveTranscript,
            currentTitleSource: titleSource
        )
    }

    // MARK: - Priority order

    func testSummaryWinsOverEveryOtherSource() async {
        let local = PromptRecorder(reply: "Local model title")
        let policy = SessionTitlingPolicy(
            settings: SessionTitlingSettings(allowsCloudTitling: true),
            localCompletion: { try await local.complete($0) },
            cloudCompletion: { _ in "Cloud title" }
        )

        let derived = await policy.derivedTitle(
            for: input(summary: "# Quarterly roadmap review")
        )

        XCTAssertEqual(derived?.source, .summary)
        XCTAssertEqual(derived?.title, "Quarterly roadmap review")
        let prompts = await local.prompts
        XCTAssertTrue(
            prompts.isEmpty,
            "A summary was available, so no provider should have been asked."
        )
    }

    func testLocalProviderIsPreferredOverKeywordExtraction() async {
        let policy = SessionTitlingPolicy(
            localCompletion: { _ in "Pricing tier overhaul" }
        )
        let derived = await policy.derivedTitle(for: input())
        XCTAssertEqual(derived?.source, .localModel)
        XCTAssertEqual(derived?.title, "Pricing tier overhaul")
    }

    func testKeywordExtractionIsUsedWhenNoProviderIsConfigured() async {
        let policy = SessionTitlingPolicy()
        let derived = await policy.derivedTitle(for: input())
        XCTAssertEqual(derived?.source, .keywords)
    }

    func testKeywordExtractionCoversAFailingLocalProvider() async {
        let local = PromptRecorder(reply: nil)
        let policy = SessionTitlingPolicy(
            localCompletion: { try await local.complete($0) }
        )
        let derived = await policy.derivedTitle(for: input())
        XCTAssertEqual(
            derived?.source,
            .keywords,
            "A broken local provider must not cost the session its title."
        )
    }

    // MARK: - The privacy constraint

    /// The core promise: with cloud titling off, no transcript text is offered
    /// to a cloud provider under any circumstance, including when every local
    /// source fails.
    func testNothingReachesTheCloudWhenTheSettingIsOff() async {
        let cloud = PromptRecorder(reply: "Cloud title")
        let policy = SessionTitlingPolicy(
            settings: SessionTitlingSettings(allowsCloudTitling: false),
            cloudCompletion: { try await cloud.complete($0) }
        )

        // Filler only, so summary, local and keyword extraction all decline.
        let fillerOnly = [
            segment("Yeah, I think so.", start: 25, end: 30),
            segment("Right, you know.", start: 31, end: 36)
        ]
        let derived = await policy.derivedTitle(
            for: input(transcript: fillerOnly)
        )

        XCTAssertNil(derived, "The date-and-time title should have stood.")
        let prompts = await cloud.prompts
        XCTAssertTrue(
            prompts.isEmpty,
            "Transcript text was sent to a cloud provider without opt-in."
        )
    }

    func testCloudIsTheLastResortEvenWhenEnabled() async {
        let cloud = PromptRecorder(reply: "Cloud title")
        let policy = SessionTitlingPolicy(
            settings: SessionTitlingSettings(allowsCloudTitling: true),
            cloudCompletion: { try await cloud.complete($0) }
        )

        let derived = await policy.derivedTitle(for: input())

        XCTAssertEqual(
            derived?.source,
            .keywords,
            "Keyword extraction succeeded, so the network was unnecessary."
        )
        let prompts = await cloud.prompts
        XCTAssertTrue(prompts.isEmpty)
    }

    func testCloudRunsOnlyAfterEveryLocalSourceDeclines() async {
        let cloud = PromptRecorder(reply: "Budget planning session")
        let policy = SessionTitlingPolicy(
            settings: SessionTitlingSettings(allowsCloudTitling: true),
            cloudCompletion: { try await cloud.complete($0) }
        )
        let fillerOnly = [
            segment("Yeah, I think so.", start: 25, end: 30),
            segment("Right, you know.", start: 31, end: 36)
        ]

        let derived = await policy.derivedTitle(
            for: input(transcript: fillerOnly)
        )

        XCTAssertEqual(derived?.source, .cloudModel)
        let prompts = await cloud.prompts
        XCTAssertEqual(prompts.count, 1)
    }

    /// Whatever is sent is bounded to the opening of the transcript.
    func testOnlyTheOpeningOfTheTranscriptIsEverSent() async {
        let cloud = PromptRecorder(reply: "Budget planning session")
        let policy = SessionTitlingPolicy(
            settings: SessionTitlingSettings(allowsCloudTitling: true),
            cloudCompletion: { try await cloud.complete($0) }
        )
        let transcript = [
            segment("Yeah, I think so.", start: 25, end: 30),
            segment("Right, you know.", start: 31, end: 36),
            segment("The acquisition price is confidential.", start: 900, end: 910)
        ]

        _ = await policy.derivedTitle(for: input(transcript: transcript))

        let prompt = await cloud.prompts.first ?? ""
        XCTAssertFalse(
            prompt.contains("confidential"),
            "Transcript beyond the excerpt cap was sent to a cloud provider."
        )
    }

    // MARK: - The user's title is untouchable

    func testAUserSetTitleStopsDerivationEntirely() async {
        let local = PromptRecorder(reply: "Something else")
        let policy = SessionTitlingPolicy(
            localCompletion: { try await local.complete($0) }
        )

        let derived = await policy.derivedTitle(
            for: input(summary: "# A summary title", titleSource: .userSet)
        )

        XCTAssertNil(derived)
        let prompts = await local.prompts
        XCTAssertTrue(
            prompts.isEmpty,
            "A user-set title should stop titling before any work happens."
        )
    }

    // MARK: - Applying a title, including the rename failure path

    private func sessionDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "titling-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        try CaptureSessionManifest(
            title: "2026-08-14 08.53",
            titleSource: .dateTime,
            tracks: [
                CaptureSessionManifest.Track(
                    source: .microphone,
                    relativePath: "microphone.wav",
                    startSampleOffset: 0,
                    timingPrecision: .sampleAccurate
                ),
                CaptureSessionManifest.Track(
                    source: .system,
                    relativePath: "system.wav",
                    startSampleOffset: 0,
                    timingPrecision: .sampleAccurate
                )
            ]
        ).write(to: url)
        return url
    }

    func testApplyingATitleStoresItAndRenamesTheFolder() async throws {
        let directory = try sessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let applier = SessionTitleApplier { url, _ in url }
        let outcome = try await applier.apply(
            DerivedSessionTitle(title: "Pricing page rebuild", source: .keywords),
            to: directory
        )

        XCTAssertEqual(
            outcome,
            .titled(
                DerivedSessionTitle(
                    title: "Pricing page rebuild",
                    source: .keywords
                )
            )
        )
        let manifest = try CaptureSessionManifest.load(from: directory)
        XCTAssertEqual(manifest.title, "Pricing page rebuild")
        XCTAssertEqual(manifest.titleSource, .keywords)
    }

    /// The folder may be open in Finder, moved, or referenced elsewhere. A
    /// failed rename must keep the title rather than fail the session.
    func testFailedFolderRenameKeepsTheTitleAndReportsTheMismatch() async throws {
        let directory = try sessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let applier = SessionTitleApplier { _, _ in
            throw SessionTitlingTestError.providerUnavailable
        }
        let outcome = try await applier.apply(
            DerivedSessionTitle(title: "Pricing page rebuild", source: .keywords),
            to: directory
        )

        guard case let .titledButFolderNotRenamed(derived, reason) = outcome else {
            XCTFail("Expected a reported mismatch; got \(outcome).")
            return
        }
        XCTAssertEqual(derived.title, "Pricing page rebuild")
        XCTAssertFalse(reason.isEmpty)

        let manifest = try CaptureSessionManifest.load(from: directory)
        XCTAssertEqual(
            manifest.title,
            "Pricing page rebuild",
            "The title was discarded because the folder could not be renamed."
        )
    }

    func testApplyingOverAUserSetTitleChangesNothing() async throws {
        let directory = try sessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await CaptureSessionManifestStore.shared.replaceTitle(
            "Board sync",
            source: .userSet,
            in: directory
        )

        let renameTracker = PromptRecorder(reply: "renamed")
        let applier = SessionTitleApplier { url, _ in
            _ = try await renameTracker.complete(url.path)
            return url
        }
        let outcome = try await applier.apply(
            DerivedSessionTitle(title: "Yeah think actually", source: .keywords),
            to: directory
        )

        XCTAssertEqual(outcome, .preservedProtectedTitle)
        let renameAttempts = await renameTracker.prompts
        XCTAssertTrue(
            renameAttempts.isEmpty,
            "A protected title must not trigger a folder rename."
        )
        let manifest = try CaptureSessionManifest.load(from: directory)
        XCTAssertEqual(manifest.title, "Board sync")
    }
}
