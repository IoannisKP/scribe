@testable import ModelManager
import XCTest

final class ModelCatalogueTests: XCTestCase {
    func testBuiltInCatalogueDescribesExistingModels() throws {
        let catalogue = try ScribeModelCatalogue.builtIn()

        XCTAssertEqual(catalogue.models.count, 15)
        XCTAssertEqual(catalogue.models(for: .transcription).count, 14)
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

    func testWhisperCatalogueUsesExactThirtySecondGeometryAndMetadata()
        throws
    {
        let catalogue = try ScribeModelCatalogue.builtIn()
        let whisper = ScribeModelIdentifiers.whisper.map {
            catalogue[$0]
        }
        XCTAssertEqual(whisper.count, 12)
        XCTAssertTrue(whisper.allSatisfy { $0 != nil })
        for descriptor in whisper.compactMap({ $0 }) {
            XCTAssertEqual(descriptor.provider, .whisperKit)
            XCTAssertEqual(descriptor.windowGeometry?.duration, 30)
            XCTAssertEqual(descriptor.windowGeometry?.overlap, 1.5)
            XCTAssertNotNil(descriptor.parameterCountMillions)
            XCTAssertNotNil(descriptor.quantization)
            XCTAssertNotNil(descriptor.speedRating)
            XCTAssertNotNil(descriptor.resourceProfile)
            if case .measured = descriptor.resourceProfile?.evidence {
                // Expected: every UI-visible Whisper model is measured.
            } else {
                XCTFail("\(descriptor.id.rawValue) lacks measured evidence.")
            }
        }
        let tinyEnglish = try XCTUnwrap(
            catalogue[ScribeModelIdentifiers.whisperTinyEnglish]
        )
        XCTAssertEqual(tinyEnglish.supportedLanguages, ["en"])
        let distil = try XCTUnwrap(
            catalogue[ScribeModelIdentifiers.whisperDistilLargeV3]
        )
        XCTAssertEqual(distil.supportedLanguages, ["en"])
        let turbo = try XCTUnwrap(
            catalogue[ScribeModelIdentifiers.whisperLargeV3Turbo]
        )
        XCTAssertEqual(
            turbo.installationDirectoryName,
            "openai_whisper-large-v3-v20240930"
        )
        XCTAssertTrue(turbo.supportedLanguages.contains("el"))
        XCTAssertTrue(turbo.supportedLanguages.contains("sv"))
    }

    func testWhisperCatalogueRecordsMeasuredDiskAndPeakMemory()
        throws
    {
        let catalogue = try ScribeModelCatalogue.builtIn()
        let expected: [ModelIdentifier: (Int64, Int64)] = [
            ScribeModelIdentifiers.whisperTiny:
                (79_398_546, 229_294_080),
            ScribeModelIdentifiers.whisperTinyEnglish:
                (155_399_288, 302_841_856),
            ScribeModelIdentifiers.whisperBase:
                (149_482_602, 344_489_984),
            ScribeModelIdentifiers.whisperSmall:
                (489_250_614, 895_385_600),
            ScribeModelIdentifiers.whisperMedium:
                (1_532_417_382, 2_553_430_016),
            ScribeModelIdentifiers.whisperLargeV3:
                (3_093_083_359, 4_440_883_200),
            ScribeModelIdentifiers.whisperLargeV3Turbo:
                (1_622_294_723, 3_020_783_616),
            ScribeModelIdentifiers.whisperDistilLargeV3:
                (1_517_298_160, 2_907_111_424),
            ScribeModelIdentifiers.whisperLargeV3TurboCompressed:
                (629_481_698, 1_173_094_400),
            ScribeModelIdentifiers.whisperLargeV3TurboOptimizedCompressed:
                (648_432_373, 1_477_410_816),
            ScribeModelIdentifiers.whisperLargeV3OptimizedCompressed:
                (1_055_612_340, 1_828_929_536),
            ScribeModelIdentifiers.whisperDistilLargeV3OptimizedCompressed:
                (609_877_791, 1_376_993_280),
        ]

        for (identifier, measurements) in expected {
            let profile = try XCTUnwrap(
                catalogue[identifier]?.resourceProfile
            )
            XCTAssertEqual(profile.downloadBytes, measurements.0)
            XCTAssertEqual(profile.installedBytes, measurements.0)
            XCTAssertEqual(profile.peakMemoryBytes, measurements.1)
        }
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
        XCTAssertThrowsError(
            try descriptor(parameterCountMillions: 0)
        ) { error in
            XCTAssertEqual(
                error as? ModelCatalogueError,
                .invalidParameterCount(
                    ModelIdentifier(rawValue: "test.model"),
                    0
                )
            )
        }
    }

    private func descriptor(
        directory: String = "safe-model",
        geometry: ModelWindowGeometry = .init(
            duration: 30,
            overlap: 0
        ),
        parameterCountMillions: Int? = nil
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
            windowGeometry: geometry,
            parameterCountMillions: parameterCountMillions
        )
    }
}
