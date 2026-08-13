@testable import AudioCapture
import XCTest

final class FirstSampleHostTimeTests: XCTestCase {
    func testRealtimeCallbackCounterStartsAtZeroAndCountsEveryIncrement() throws {
        let counter = try RealtimeCallbackCounter()

        XCTAssertEqual(counter.value, 0)
        counter.increment()
        counter.increment()

        XCTAssertEqual(counter.value, 2)
    }

    func testLatchKeepsOnlyFirstValidTimestamp() throws {
        let latch = try FirstSampleHostTime()
        XCTAssertNil(latch.value)
        latch.capture(0)
        XCTAssertNil(latch.value)
        latch.capture(123_456)
        latch.capture(999_999)
        XCTAssertEqual(latch.value, 123_456)
    }

    func testRealtimeRouterDefersAndReleasesAudioStorageAttachment() throws {
        let router = try SystemAudioRealtimeRouter()
        let ringBuffer = try FloatRingBuffer(capacity: 64)
        let firstSampleTime = try FirstSampleHostTime()

        XCTAssertFalse(router.isAttached)
        router.attach(
            ringBuffer: ringBuffer,
            firstSampleTime: firstSampleTime
        )
        XCTAssertTrue(router.isAttached)
        router.detach()
        XCTAssertFalse(router.isAttached)
    }
}
