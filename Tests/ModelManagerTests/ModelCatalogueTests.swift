@testable import ModelManager
import XCTest

final class ModelCatalogueTests: XCTestCase {
    func testBuiltInCatalogueDescribesExistingModels() throws {
        let catalogue = try ScribeModelCatalogue.builtIn()

        XCTAssertEqual(catalogue.models.count, 3)
        XCTAssertEqual(catalogue.models(for: .transcription).count, 2)
        XCTAssertEqual(
            catalogue.models(for: .voiceActivityDetection).count,
            1
        )
        let multilingual = try XCTUnwrap(
            catalogue[ScribeModelIdentifiers.parakeetV3Multilingual]
        )
        XCTAssertEqual(multilingual.provider, .fluidAudio)
        XCTAssertEqual(multilingual.windowGeometry?.duration, 14)
        XCTAssertEqual(multilingual.windowGeometry?.overlap, 1.5)
        XCTAssertEqual(multilingual.supportedLanguages.count, 25)
        XCTAssertTrue(multilingual.supportedLanguages.contains("el"))
        XCTAssertTrue(multilingual.supportedLanguages.contains("sv"))
        let vad = try XCTUnwrap(
            catalogue[ScribeModelIdentifiers.sileroVAD]
        )
        XCTAssertNil(vad.windowGeometry)
        XCTAssertEqual(vad.installationDirectoryName, "silero-vad")
    }

    func testCatalogueRejectsDuplicateIdentityAndDirectory() throws {
        let original = try XCTUnwrap(
            try ScribeModelCatalogue.builtIn()[
                ScribeModelIdentifiers.parakeetV2English
            ]
        )

        XCTAssertThrowsError(
            try ModelCatalogue(models: [original, original])
        ) { error in
            XCTAssertEqual(
                error as? ModelCatalogueError,
                .duplicateIdentifier(original.id)
            )
        }
        let duplicateDirectory = try ModelDescriptor(
            id: ModelIdentifier(rawValue: "different.id"),
            displayName: "Different",
            detail: "",
            provider: .whisperKit,
            task: .transcription,
            installationDirectoryName:
                original.installationDirectoryName,
            supportedLanguages: ["en"],
            supportsLiveProcessing: false,
            windowGeometry: ModelWindowGeometry(
                duration: 30,
                overlap: 0
            )
        )
        XCTAssertThrowsError(
            try ModelCatalogue(models: [original, duplicateDirectory])
        ) { error in
            XCTAssertEqual(
                error as? ModelCatalogueError,
                .duplicateInstallationDirectory(
                    original.installationDirectoryName
                )
            )
        }
    }

    func testDescriptorRejectsUnsafePathsAndInvalidGeometry() {
        XCTAssertThrowsError(
            try descriptor(directory: "../Models")
        ) { error in
            XCTAssertEqual(
                error as? ModelCatalogueError,
                .invalidInstallationDirectory("../Models")
            )
        }
        XCTAssertThrowsError(
            try descriptor(
                geometry: ModelWindowGeometry(
                    duration: 30,
                    overlap: 30
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ModelCatalogueError,
                .invalidWindowOverlap(
                    ModelIdentifier(rawValue: "test.model"),
                    30
                )
            )
        }
    }

    private func descriptor(
        directory: String = "safe-model",
        geometry: ModelWindowGeometry = .init(
            duration: 30,
            overlap: 0
        )
    ) throws -> ModelDescriptor {
        try ModelDescriptor(
            id: ModelIdentifier(rawValue: "test.model"),
            displayName: "Test model",
            detail: "",
            provider: .whisperKit,
            task: .transcription,
            installationDirectoryName: directory,
            supportedLanguages: ["en"],
            supportsLiveProcessing: false,
            windowGeometry: geometry
        )
    }
}
