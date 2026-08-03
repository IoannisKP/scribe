import Foundation
@testable import SpeechPipeline
import XCTest

final class FluidAudioModelManagerSileroTests: XCTestCase {
    func testMissingModelIsReportedWithoutNetworkAccess() async throws {
        let directory = try makeTestDirectory()
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        let store = try FluidAudioModelManager(
            modelsDirectory: directory
        )

        let availability = await store.sileroAvailability()
        let modelURL = await store.sileroModelURL
        XCTAssertEqual(availability, .notDownloaded)
        XCTAssertEqual(
            modelURL.deletingLastPathComponent().lastPathComponent,
            "silero-vad"
        )
        XCTAssertEqual(
            modelURL.lastPathComponent,
            "silero-vad-unified-256ms-v6.2.1.mlmodelc"
        )
    }
}
