@testable import AudioCapture
import XCTest

final class FirstSampleHostTimeTests: XCTestCase {
    func testLatchKeepsOnlyFirstValidTimestamp() throws {
        let latch = try FirstSampleHostTime()
        XCTAssertNil(latch.value)
        latch.capture(0)
        XCTAssertNil(latch.value)
        latch.capture(123_456)
        latch.capture(999_999)
        XCTAssertEqual(latch.value, 123_456)
    }
}
