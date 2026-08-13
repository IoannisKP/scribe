import AudioCapture
import Foundation
import Intelligence
import SessionStore
import XCTest

final class SummaryGenerationTests: XCTestCase {
    func testSinglePassStreamsThenWritesProvenanceAndRevision() async throws {
        try await withSession { directory in
            let provider = MockSummaryProvider(chunks: ["# Result\n", "Done."])
            let plan = try makePlan()
            let recorder = ChunkRecorder()

            let result = try await SinglePassSummaryGenerator().generate(
                plan: plan,
                provider: provider,
                sessionDirectory: directory,
                onChunk: { chunk in await recorder.append(chunk) }
            )

            let streamedText = await recorder.text
            XCTAssertEqual(streamedText, "# Result\nDone.")
            XCTAssertEqual(result.text, "# Result\nDone.")
            let summary = try String(
                contentsOf: directory.appendingPathComponent("summary.md"),
                encoding: .utf8
            )
            XCTAssertTrue(summary.hasPrefix(
                "> Scribe summary · Provider: OpenAI · Model: gpt-4.1-nano · Template: Meeting summary\n\n"
            ))
            XCTAssertTrue(summary.hasSuffix("# Result\nDone.\n"))
            XCTAssertEqual(
                try String(
                    contentsOf: directory.appendingPathComponent("notes.md"),
                    encoding: .utf8
                ),
                "Private notes"
            )

            let manifest = try CaptureSessionManifest.load(from: directory)
            XCTAssertEqual(manifest.summaryHistory.count, 1)
            let revision = try XCTUnwrap(manifest.summaryHistory.first)
            XCTAssertEqual(revision.providerIdentifier, "openai")
            XCTAssertEqual(revision.providerDisplayName, "OpenAI")
            XCTAssertEqual(revision.modelIdentifier, "gpt-4.1-nano")
            XCTAssertEqual(revision.templateName, "Meeting summary")
            XCTAssertEqual(
                manifest.artifacts.filter { $0.relativePath == "summary.md" }
                    .map(\.kind),
                [.summary]
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath:
                directory.appendingPathComponent(revision.artifacts[0]).path
            ))
        }
    }

    func testRegenerationPreservesEarlierRevision() async throws {
        try await withSession { directory in
            let generator = SinglePassSummaryGenerator()
            let plan = try makePlan()
            let first = try await generator.generate(
                plan: plan,
                provider: MockSummaryProvider(chunks: ["First version"]),
                sessionDirectory: directory
            )
            let second = try await generator.generate(
                plan: plan,
                provider: MockSummaryProvider(chunks: ["Second version"]),
                sessionDirectory: directory
            )

            XCTAssertNotEqual(first.artifact.revisionFile, second.artifact.revisionFile)
            XCTAssertTrue(try String(
                contentsOf: first.artifact.revisionFile,
                encoding: .utf8
            ).contains("First version"))
            XCTAssertTrue(try String(
                contentsOf: second.artifact.currentFile,
                encoding: .utf8
            ).contains("Second version"))
            XCTAssertEqual(
                try CaptureSessionManifest.load(from: directory)
                    .summaryHistory.count,
                2
            )
        }
    }

    func testMidStreamFailureLeavesPriorSummaryManifestAndNotesUntouched()
        async throws
    {
        try await withSession { directory in
            let existing = Data("Existing summary".utf8)
            try existing.write(
                to: directory.appendingPathComponent("summary.md"),
                options: .atomic
            )
            let beforeManifest = try Data(contentsOf:
                directory.appendingPathComponent("session.json")
            )
            let plan = try makePlan()
            do {
                _ = try await SinglePassSummaryGenerator().generate(
                    plan: plan,
                    provider: MockSummaryProvider(
                        chunks: ["Partial text"],
                        failure: .simulated
                    ),
                    sessionDirectory: directory
                )
                XCTFail("Expected stream failure")
            } catch {
                XCTAssertEqual(error as? MockSummaryError, .simulated)
            }

            XCTAssertEqual(
                try Data(contentsOf:
                    directory.appendingPathComponent("summary.md")
                ),
                existing
            )
            XCTAssertEqual(
                try Data(contentsOf:
                    directory.appendingPathComponent("session.json")
                ),
                beforeManifest
            )
            XCTAssertEqual(
                try String(
                    contentsOf: directory.appendingPathComponent("notes.md"),
                    encoding: .utf8
                ),
                "Private notes"
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath:
                directory.appendingPathComponent("Summaries").path
            ))
        }
    }

    func testInputBuilderIncludesPinsAndNearbyTranscript() throws {
        try withSessionSync { directory in
            let transcript = "**You · 0:00**\n\nAn important decision happened.\n"
            try Data(transcript.utf8).write(
                to: directory.appendingPathComponent("transcript.md"),
                options: .atomic
            )
            let json = """
                [{"text":"An important decision happened.","startTime":4.0,"endTime":8.0,"source":"microphone"}]
                """
            try Data(json.utf8).write(
                to: directory.appendingPathComponent("transcript.json"),
                options: .atomic
            )
            let pin = CaptureSessionManifest.Pin(
                sampleOffset: 6 * 16_000,
                label: "Decision"
            )
            let manifest = try CaptureSessionManifest.load(from: directory)
                .appendingPin(pin)
            try manifest.write(to: directory)

            let input = try SummaryGenerationInputBuilder().load(
                from: directory
            )
            XCTAssertEqual(input.context.notes, "Private notes")
            XCTAssertTrue(input.context.pins.contains("[0:06] — Decision"))
            XCTAssertTrue(input.context.pins.contains(
                "An important decision happened."
            ))
        }
    }

    func testOversizedSinglePassPlanStopsBeforeProviderCall() throws {
        let policy = SummaryModelPolicy(
            contextTokenLimit: 100,
            maximumOutputTokens: 20
        )
        XCTAssertThrowsError(try SummaryGenerationPlan(
            providerIdentifier: "custom",
            providerDisplayName: "Custom",
            model: LLMModel(identifier: "tiny"),
            template: template,
            input: SummaryGenerationInput(context: SummaryTemplateContext(
                notes: "",
                transcript: String(repeating: "long transcript ", count: 100),
                title: "Test",
                date: "2026-08-13",
                participants: "You",
                pins: ""
            )),
            isLocal: false,
            policy: policy
        )) { error in
            guard case .requiresChunking = error as? SummaryGenerationError else {
                return XCTFail("Expected requiresChunking, got \(error)")
            }
        }
    }

    func testCloudRequiresConfirmationAndOnlyKnownPricingHasCost() throws {
        let cloud = try makePlan()
        XCTAssertTrue(cloud.requiresConfirmation)
        XCTAssertNotNil(cloud.estimatedMaximumCost)

        let local = try SummaryGenerationPlan(
            providerIdentifier: "custom-local",
            providerDisplayName: "Local model",
            model: LLMModel(identifier: "unknown"),
            template: template,
            input: SummaryGenerationInput(context: SummaryTemplateContext(
                notes: "",
                transcript: "Short transcript",
                title: "Test",
                date: "2026-08-13",
                participants: "You",
                pins: ""
            )),
            isLocal: true
        )
        XCTAssertFalse(local.requiresConfirmation)
        XCTAssertNil(local.estimatedMaximumCost)
    }

    private var template: SummaryTemplate {
        SummaryTemplate(
            id: "built-in.meeting-summary",
            name: "Meeting summary",
            body: "Summarise {{transcript}} Notes: {{notes}} Pins: {{pins}}",
            builtInKey: "meeting-summary",
            sortOrder: 0,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func makePlan() throws -> SummaryGenerationPlan {
        try SummaryGenerationPlan(
            providerIdentifier: "openai",
            providerDisplayName: "OpenAI",
            model: LLMModel(identifier: "gpt-4.1-nano"),
            template: template,
            input: SummaryGenerationInput(context: SummaryTemplateContext(
                notes: "Private notes",
                transcript: "A decision was made.",
                title: "Review",
                date: "2026-08-13",
                participants: "You, Others",
                pins: "[0:06] Decision"
            )),
            isLocal: false
        )
    }

    private func withSession(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    private func withSessionSync(_ body: (URL) throws -> Void) throws {
        let directory = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func makeSession() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SummaryGenerationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let manifest = CaptureSessionManifest.pendingDualTrack(
            sessionID: UUID(),
            title: "Review",
            createdAt: Date(timeIntervalSince1970: 1_786_579_200)
        )
        try manifest.write(to: directory)
        try Data("Private notes".utf8).write(
            to: directory.appendingPathComponent("notes.md"),
            options: .atomic
        )
        return directory
    }
}

private actor ChunkRecorder {
    private(set) var text = ""
    func append(_ chunk: String) { text += chunk }
}

private enum MockSummaryError: Error, Equatable {
    case simulated
}

private struct MockSummaryProvider: IntelligenceProvider {
    let identifier = "mock"
    let displayName = "Mock"
    let requiresKey = false
    let chunks: [String]
    let failure: MockSummaryError?

    init(chunks: [String], failure: MockSummaryError? = nil) {
        self.chunks = chunks
        self.failure = failure
    }

    func availableModels() async throws -> [LLMModel] {
        [LLMModel(identifier: "mock")]
    }

    func complete(
        system: String,
        messages: [LLMMessage],
        model: LLMModel
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.finish()
            }
        }
    }
}
