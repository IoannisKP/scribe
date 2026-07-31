import AudioCapture
import XCTest

final class SystemAudioPermissionTests: XCTestCase {
    func testTracksOnlyObservedSystemAudioAuthorization() async {
        let authorizer = SystemAudioPermissionAuthorizer(
            initialStatus: .notDetermined
        )

        var status = await authorizer.authorizationStatus()
        XCTAssertEqual(status, .notDetermined)

        await authorizer.recordAuthorizationStatus(.authorized)
        status = await authorizer.authorizationStatus()
        XCTAssertEqual(status, .authorized)

        await authorizer.recordAuthorizationStatus(.denied)
        status = await authorizer.authorizationStatus()
        XCTAssertEqual(status, .denied)
        XCTAssertTrue(status.requiresSystemSettings)
    }

    func testPrivacyDeepLinksTargetSeparateAudioPanes() throws {
        let microphoneURL = try XCTUnwrap(
            MicrophoneAuthorizationStatus.systemSettingsURL
        )
        let systemAudioURL = try XCTUnwrap(
            SystemAudioAuthorizationStatus.systemSettingsURL
        )

        XCTAssertTrue(
            microphoneURL.absoluteString.hasSuffix("Privacy_Microphone")
        )
        XCTAssertTrue(
            systemAudioURL.absoluteString.hasSuffix("Privacy_AudioCapture")
        )
        XCTAssertNotEqual(microphoneURL, systemAudioURL)
    }
}
