import AudioCapture
import Foundation
import XCTest

final class MicrophoneCaptureServiceTests: XCTestCase {
    func testDeniedPermissionFailsBeforeCreatingOutputFile() async {
        let authorizer = FixedMicrophonePermissionAuthorizer(
            status: .denied,
            requestResult: false
        )
        let service = MicrophoneCaptureService(
            permissionAuthorizer: authorizer
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("microphone.wav")

        do {
            try await service.startRecording(to: url)
            XCTFail("Expected denied permission to prevent recording.")
        } catch {
            XCTAssertEqual(
                error as? AudioCaptureError,
                .microphonePermissionDenied
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let captureState = await service.state
        XCTAssertEqual(
            captureState,
            .failed(
                message: AudioCaptureError
                    .microphonePermissionDenied
                    .localizedDescription
            )
        )
    }

    func testRestrictedPermissionSurfacesPolicyGuidance() async {
        let service = MicrophoneCaptureService(
            permissionAuthorizer: FixedMicrophonePermissionAuthorizer(
                status: .restricted,
                requestResult: false
            )
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("microphone.wav")

        do {
            try await service.startRecording(to: url)
            XCTFail("Expected restricted permission to prevent recording.")
        } catch {
            XCTAssertEqual(
                error as? AudioCaptureError,
                .microphonePermissionRestricted
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testUndeterminedPermissionUsesRequestResult() async {
        let authorizer = FixedMicrophonePermissionAuthorizer(
            status: .notDetermined,
            requestResult: false
        )
        let service = MicrophoneCaptureService(
            permissionAuthorizer: authorizer
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("microphone.wav")

        do {
            try await service.startRecording(to: url)
            XCTFail("Expected a rejected permission request to prevent recording.")
        } catch {
            XCTAssertEqual(
                error as? AudioCaptureError,
                .microphonePermissionDenied
            )
        }
        let requestCount = await authorizer.requestCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

private actor FixedMicrophonePermissionAuthorizer:
    MicrophonePermissionAuthorizing
{
    let status: MicrophoneAuthorizationStatus
    let requestResult: Bool
    private(set) var requestCount = 0

    init(status: MicrophoneAuthorizationStatus, requestResult: Bool) {
        self.status = status
        self.requestResult = requestResult
    }

    func authorizationStatus() -> MicrophoneAuthorizationStatus {
        status
    }

    func requestAuthorization() -> Bool {
        requestCount += 1
        return requestResult
    }
}
