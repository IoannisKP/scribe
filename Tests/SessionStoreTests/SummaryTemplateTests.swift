import Foundation
import XCTest
@testable import SessionStore

final class SummaryTemplateTests: XCTestCase {
    func testShipsSixOrderedBuiltInTemplates() async throws {
        try await withStore { store in
            let templates = try await store.templates()
            XCTAssertEqual(templates.count, 6)
            XCTAssertEqual(
                templates.map(\.name),
                [
                    "Meeting summary",
                    "Decisions and actions",
                    "Interview notes",
                    "One-to-one",
                    "Lecture or talk",
                    "Raw cleanup"
                ]
            )
            XCTAssertTrue(templates.allSatisfy(\.isBuiltIn))
            XCTAssertEqual(Set(templates.compactMap(\.builtInKey)).count, 6)
            for template in templates {
                XCTAssertNoThrow(try SummaryTemplateRenderer.render(
                    template,
                    context: emptyContext
                ))
            }
        }
    }

    func testSubstitutesEveryVariableIncludingPins() throws {
        let template = makeTemplate(
            body: """
                {{title}}|{{date}}|{{participants}}
                {{notes}}
                {{transcript}}
                {{pins}}
                """
        )
        let result = try SummaryTemplateRenderer.render(
            template,
            context: SummaryTemplateContext(
                notes: "Bring the prototype.",
                transcript: "[00:14] We approved the prototype.",
                title: "Design review",
                date: "2026-08-13",
                participants: "Alex, Morgan",
                pins: "[00:14] Decision — We approved the prototype."
            )
        )

        XCTAssertEqual(
            result,
            """
                Design review|2026-08-13|Alex, Morgan
                Bring the prototype.
                [00:14] We approved the prototype.
                [00:14] Decision — We approved the prototype.
                """
        )
    }

    func testUnknownVariableFailsClearly() throws {
        let template = makeTemplate(body: "Use {{transcript}} and {{agenda}}")
        XCTAssertThrowsError(try SummaryTemplateRenderer.render(
            template,
            context: emptyContext
        )) { error in
            XCTAssertEqual(
                error as? SummaryTemplateError,
                .unknownVariable("agenda")
            )
            XCTAssertEqual(
                error.localizedDescription,
                "Unknown template variable: {{agenda}}."
            )
        }
    }

    func testTemplateCanBeDuplicatedAndEditedIndependently() async throws {
        try await withStore { store in
            let initialTemplates = try await store.templates()
            let original = try XCTUnwrap(initialTemplates.first)
            let duplicate = try await store.duplicate(
                id: original.id,
                name: "My meeting summary"
            )
            let edited = try await store.save(
                id: duplicate.id,
                name: "Weekly review",
                body: "Review {{pins}} then {{transcript}}"
            )
            let templates = try await store.templates()
            let unchanged = try XCTUnwrap(
                templates.first(where: { $0.id == original.id })
            )

            XCTAssertFalse(edited.isBuiltIn)
            XCTAssertEqual(edited.name, "Weekly review")
            XCTAssertEqual(edited.body, "Review {{pins}} then {{transcript}}")
            XCTAssertEqual(unchanged.name, original.name)
            XCTAssertEqual(unchanged.body, original.body)
        }
    }

    func testUpdateAddsDefaultsWithoutOverwritingUserEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SummaryTemplateUpdateTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("templates.sqlite")
        let firstSeed = SummaryTemplateStore.Seed(
            key: "existing",
            name: "Existing default",
            body: "Original {{transcript}}",
            sortOrder: 0
        )
        let firstStore = try SummaryTemplateStore(
            databaseURL: databaseURL,
            seeds: [firstSeed]
        )
        _ = try await firstStore.save(
            id: firstSeed.id,
            name: "My edited default",
            body: "Keep my edit {{notes}}"
        )

        let secondStore = try SummaryTemplateStore(
            databaseURL: databaseURL,
            seeds: [
                SummaryTemplateStore.Seed(
                    key: "existing",
                    name: "Renamed by app update",
                    body: "Replaced by app update",
                    sortOrder: 0
                ),
                SummaryTemplateStore.Seed(
                    key: "new-default",
                    name: "New default",
                    body: "New {{transcript}}",
                    sortOrder: 1
                )
            ]
        )
        let templates = try await secondStore.templates()

        XCTAssertEqual(templates.count, 2)
        XCTAssertEqual(templates[0].name, "My edited default")
        XCTAssertEqual(templates[0].body, "Keep my edit {{notes}}")
        XCTAssertEqual(templates[1].name, "New default")
    }

    func testCustomTemplateCanBeRemovedButBuiltInCannot() async throws {
        try await withStore { store in
            let initialTemplates = try await store.templates()
            let builtIn = try XCTUnwrap(initialTemplates.first)
            do {
                try await store.delete(id: builtIn.id)
                XCTFail("Expected built-in removal to fail")
            } catch {
                XCTAssertEqual(
                    error as? SummaryTemplateError,
                    .builtInTemplateCannotBeDeleted
                )
            }

            let custom = try await store.create(
                name: "Custom",
                body: "Use {{transcript}}"
            )
            try await store.delete(id: custom.id)
            let remainingTemplates = try await store.templates()
            XCTAssertFalse(remainingTemplates.contains {
                $0.id == custom.id
            })
        }
    }

    private var emptyContext: SummaryTemplateContext {
        SummaryTemplateContext(
            notes: "",
            transcript: "",
            title: "",
            date: "",
            participants: "",
            pins: ""
        )
    }

    private func makeTemplate(body: String) -> SummaryTemplate {
        SummaryTemplate(
            id: "test",
            name: "Test",
            body: body,
            sortOrder: 0,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func withStore(
        _ body: (SummaryTemplateStore) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SummaryTemplateTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SummaryTemplateStore(
            databaseURL: root.appendingPathComponent("templates.sqlite")
        )
        try await body(store)
    }
}
