@testable import AudioCapture
import CoreAudio
import XCTest

final class CoreAudioSupportTests: XCTestCase {
    func testSystemTapResourceSamplerReadsProcessMetricsWithoutStackCorruption() {
        let snapshot = SystemTapResourceSampler.snapshot()

        XCTAssertNotNil(snapshot.app)
        XCTAssertGreaterThan(snapshot.app?.residentBytes ?? 0, 0)
        XCTAssertGreaterThan(snapshot.app?.physicalFootprintBytes ?? 0, 0)
    }

    func testFormatsPrintableOSStatusAsFourCharacterCode() {
        XCTAssertEqual(
            CoreAudioCallError.describe(kAudioHardwareBadDeviceError),
            "'!dev'"
        )
    }

    func testSystemAudioPermissionStatusMapsToActionableError() {
        XCTAssertThrowsError(
            try CoreAudioCallError.checkSystemAudio(
                kAudioDevicePermissionsError,
                operation: "Test operation"
            )
        ) { error in
            XCTAssertEqual(
                error as? AudioCaptureError,
                .systemAudioPermissionDenied
            )
        }
    }

    func testAggregateDescriptionContainsRealOutputAndPrivateSubtap() throws {
        let description = SystemTapAggregateDescription.make(
            outputDeviceUID: "output-device",
            tapUID: "tap-uid",
            aggregateUID: "aggregate-uid"
        )

        XCTAssertEqual(
            description[kAudioAggregateDeviceMainSubDeviceKey] as? String,
            "output-device"
        )
        XCTAssertEqual(
            description[kAudioAggregateDeviceIsPrivateKey] as? Bool,
            true
        )
        XCTAssertEqual(
            description[kAudioAggregateDeviceTapAutoStartKey] as? Bool,
            true
        )

        let subdevices = try XCTUnwrap(
            description[kAudioAggregateDeviceSubDeviceListKey]
                as? [[String: Any]]
        )
        XCTAssertEqual(subdevices.count, 1)
        XCTAssertEqual(
            subdevices[0][kAudioSubDeviceUIDKey] as? String,
            "output-device"
        )
        XCTAssertEqual(
            subdevices[0][kAudioSubDeviceInputChannelsKey] as? Int,
            0
        )

        let subtaps = try XCTUnwrap(
            description[kAudioAggregateDeviceTapListKey]
                as? [[String: Any]]
        )
        XCTAssertEqual(subtaps.count, 1)
        XCTAssertEqual(
            subtaps[0][kAudioSubTapUIDKey] as? String,
            "tap-uid"
        )
        XCTAssertEqual(
            subtaps[0][kAudioSubTapDriftCompensationKey] as? Bool,
            true
        )
    }
}
