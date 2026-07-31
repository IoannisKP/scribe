import AudioCapture
import Foundation
import XCTest

final class CaptureSessionManifestTests: XCTestCase {
    func testRoundTripsCanonicalDualTrackTimeline() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Unable to remove test directory: \(error)")
            }
        }
        let manifest = CaptureSessionManifest.dualTrack(
            microphoneStartTime: 0,
            systemStartTime: 0.375
        )

        try manifest.write(to: directory)
        let decoded = try CaptureSessionManifest.load(from: directory)

        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(
            decoded.track(for: .system)?.startTime,
            0.375
        )
    }

    func testRejectsUnsafeTrackPath() {
        let manifest = CaptureSessionManifest(
            tracks: [
                .init(
                    source: .microphone,
                    relativePath: "../microphone.wav",
                    startTime: 0
                ),
                .init(
                    source: .system,
                    relativePath: "system.wav",
                    startTime: 0
                )
            ]
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(
                error as? CaptureSessionManifestError,
                .invalidRelativePath("../microphone.wav")
            )
        }
    }

    func testRequiresExactlyOneTrackPerSource() {
        let manifest = CaptureSessionManifest(
            tracks: [
                .init(
                    source: .microphone,
                    relativePath: "microphone.wav",
                    startTime: 0
                )
            ]
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(
                error as? CaptureSessionManifestError,
                .invalidTrackSet
            )
        }
    }
}
