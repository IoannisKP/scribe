@testable import AudioCapture
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import XCTest

final class MicrophoneCaptureServiceTests: XCTestCase {
    func testTapFormatIsReadOnlyAfterConcreteDeviceBinding() throws {
        let stalePrebindingFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let boundAirPodsFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 24_000,
                channels: 1,
                interleaved: false
            )
        )
        var operations: [String] = []
        var isBound = false
        let deviceID = AudioDeviceID(52)
        let identity = MicrophoneInputDeviceIdentity(
            audioDeviceID: deviceID,
            uid: "test.airpods-microphone",
            name: "AirPods Microphone"
        )
        let resolver = MicrophoneInputRouteResolver(
            defaultInputDevice: {
                operations.append("resolve")
                return deviceID
            },
            inputDeviceIdentity: { resolvedDeviceID in
                operations.append("identity")
                XCTAssertEqual(resolvedDeviceID, deviceID)
                return identity
            },
            bindAndVerify: { resolvedDeviceID in
                operations.append("bind-and-verify")
                XCTAssertEqual(resolvedDeviceID, deviceID)
                isBound = true
            },
            boundInputFormat: {
                operations.append("input-format")
                return isBound ? boundAirPodsFormat : stalePrebindingFormat
            },
            now: { Date(timeIntervalSince1970: 100) }
        )

        let resolved = try resolver.resolve(reason: .recordingStarted)

        XCTAssertEqual(
            operations,
            ["resolve", "identity", "bind-and-verify", "input-format"]
        )
        XCTAssertEqual(resolved.tapFormat.sampleRate, 24_000)
        XCTAssertEqual(resolved.change.inputSampleRate, 24_000)
        XCTAssertEqual(resolved.change.device, identity)
    }

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
