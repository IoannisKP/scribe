@testable import AudioCapture
import XCTest

final class FirstSampleHostTimeTests: XCTestCase {
    func testConcurrentPreparationCallersShareOneOperation() async throws {
        let gate = SingleFlightPreparation<Int>()
        let probe = PreparationProbe()

        async let launchPrewarm = gate.value {
            try await probe.prepare()
        }
        try await Task.sleep(for: .milliseconds(10))
        async let immediateRecord = gate.value {
            try await probe.prepare()
        }

        let (prewarmResult, recordResult) = try await (
            launchPrewarm,
            immediateRecord
        )

        XCTAssertEqual(prewarmResult.value, 42)
        XCTAssertEqual(recordResult.value, 42)
        XCTAssertEqual(prewarmResult.operationID, recordResult.operationID)
        XCTAssertTrue(prewarmResult.startedNewOperation)
        XCTAssertFalse(recordResult.startedNewOperation)
        let preparationCount = await probe.preparationCount
        XCTAssertEqual(preparationCount, 1)
    }

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

private actor PreparationProbe {
    private(set) var preparationCount = 0

    func prepare() async throws -> Int {
        preparationCount += 1
        try await Task.sleep(for: .milliseconds(50))
        return 42
    }
}
