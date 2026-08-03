@testable import SpeechPipeline
import ModelManager
import XCTest

final class TranscriptionModelSelectionTests: XCTestCase {
    func testEveryCatalogueTranscriptionModelHasOneExactSelection() throws {
        let catalogue = try ScribeModelCatalogue.builtIn()
        let descriptors = catalogue.models(for: .transcription)

        XCTAssertEqual(TranscriptionModelSelection.allCases.count, 14)
        XCTAssertEqual(
            Set(TranscriptionModelSelection.allCases.map(\.id)),
            Set(descriptors.map(\.id))
        )
        XCTAssertTrue(
            TranscriptionModelSelection.allCases.allSatisfy {
                $0.descriptor.id == $0.id
            }
        )
    }

    func testIdentifierRoundTripNeverSubstitutesAnotherModel() {
        for selection in TranscriptionModelSelection.allCases {
            XCTAssertEqual(
                TranscriptionModelSelection(identifier: selection.id),
                selection
            )
        }

        XCTAssertNil(
            TranscriptionModelSelection(
                identifier: ModelIdentifier(rawValue: "unknown")
            )
        )
    }

    func testWhisperAndParakeetKeepTheirDeclaredWindowGeometry() {
        for selection in TranscriptionModelSelection.allCases {
            let geometry = selection.descriptor.windowGeometry
            switch selection {
            case .parakeet:
                XCTAssertEqual(geometry?.duration, 14)
                XCTAssertEqual(geometry?.overlap, 1.5)
            case .whisper:
                XCTAssertEqual(geometry?.duration, 30)
                XCTAssertEqual(geometry?.overlap, 1.5)
            }
        }
    }

    func testFallbackCandidatesAreStrictlySmallerAndClosestFirst() {
        let selected = TranscriptionModelSelection.whisper(.medium)
        let candidates = selected.smallerFallbackCandidates
        let sizes = candidates.compactMap {
            $0.descriptor.resourceProfile?.installedBytes
        }

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(sizes.allSatisfy {
            $0 < (selected.descriptor.resourceProfile?.installedBytes ?? 0)
        })
        XCTAssertEqual(sizes, sizes.sorted(by: >))
        XCTAssertEqual(candidates.first, .whisper(.distilLargeV3))
        XCTAssertTrue(
            TranscriptionModelSelection.whisper(.tiny)
                .smallerFallbackCandidates.isEmpty
        )
    }
}
