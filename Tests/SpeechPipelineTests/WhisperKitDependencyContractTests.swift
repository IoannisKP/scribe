import XCTest
@testable import SpeechPipeline

final class WhisperKitDependencyContractTests: XCTestCase {
    func testExactPackageAndBackendAreAvailableToSpeechPipeline() {
        XCTAssertEqual(WhisperKitDependencyContract.exactPackageVersion, "1.0.0")
        XCTAssertEqual(WhisperKitDependencyContract.backendTypeName, "WhisperKit.WhisperKit")
    }
}
