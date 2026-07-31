import AudioCapture
import Foundation
import XCTest

final class DualTrackRecordingCoordinatorTests: XCTestCase {
    func testStartsAndStopsIndependentTrackFiles() async throws {
        let microphone = FakeTrackCapture(source: .microphone)
        let system = FakeTrackCapture(source: .system)
        let coordinator = DualTrackRecordingCoordinator(
            microphoneCapture: microphone,
            systemCapture: system,
            freeSpaceProvider: MutableFreeSpaceProvider(
                availableBytes: .max
            ),
            diskSpaceConfiguration: testDiskConfiguration()
        )
        let directory = testDirectory()
        defer {
            removeTestDirectory(directory)
        }

        let paths = try await coordinator.startRecording(in: directory)
        XCTAssertEqual(paths.microphoneURL.lastPathComponent, "microphone.wav")
        XCTAssertEqual(paths.systemURL.lastPathComponent, "system.wav")

        let result = try await coordinator.stopRecording()
        XCTAssertEqual(result.microphone.source, .microphone)
        XCTAssertEqual(result.system.source, .system)
        XCTAssertNotEqual(
            result.microphone.outputURL,
            result.system.outputURL
        )

        let microphoneStarts = await microphone.startCount
        let microphoneStops = await microphone.stopCount
        let systemStarts = await system.startCount
        let systemStops = await system.stopCount
        XCTAssertEqual(microphoneStarts, 1)
        XCTAssertEqual(microphoneStops, 1)
        XCTAssertEqual(systemStarts, 1)
        XCTAssertEqual(systemStops, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paths.manifestURL.path)
        )
        let manifest = try CaptureSessionManifest.load(from: directory)
        XCTAssertEqual(
            manifest.track(for: .microphone)?.startTime,
            0
        )
        let systemStartTime = try XCTUnwrap(
            manifest.track(for: .system)?.startTime
        )
        XCTAssertGreaterThanOrEqual(systemStartTime, 0)
    }

    func testSystemStartFailureStopsAlreadyRunningMicrophone() async {
        let microphone = FakeTrackCapture(source: .microphone)
        let system = FakeTrackCapture(
            source: .system,
            startFailure: .systemAudioPermissionDenied
        )
        let coordinator = DualTrackRecordingCoordinator(
            microphoneCapture: microphone,
            systemCapture: system,
            freeSpaceProvider: MutableFreeSpaceProvider(
                availableBytes: .max
            ),
            diskSpaceConfiguration: testDiskConfiguration()
        )

        let directory = testDirectory()
        defer {
            removeTestDirectory(directory)
        }
        do {
            try await coordinator.startRecording(
                in: directory
            )
            XCTFail("Expected the system track to fail.")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("permission")
            )
        }

        let microphoneStops = await microphone.stopCount
        XCTAssertEqual(microphoneStops, 1)
        let state = await coordinator.state
        if case .failed = state {
            // Expected terminal state.
        } else {
            XCTFail("Expected a failed coordinator state.")
        }
    }

    func testStopAttemptsMicrophoneAfterSystemStopFailure() async throws {
        let microphone = FakeTrackCapture(source: .microphone)
        let system = FakeTrackCapture(
            source: .system,
            stopFailure: .systemGraphTeardownFailed("Synthetic failure")
        )
        let coordinator = DualTrackRecordingCoordinator(
            microphoneCapture: microphone,
            systemCapture: system,
            freeSpaceProvider: MutableFreeSpaceProvider(
                availableBytes: .max
            ),
            diskSpaceConfiguration: testDiskConfiguration()
        )

        let directory = testDirectory()
        defer {
            removeTestDirectory(directory)
        }
        _ = try await coordinator.startRecording(in: directory)

        do {
            _ = try await coordinator.stopRecording()
            XCTFail("Expected stop to surface the system failure.")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("Synthetic failure")
            )
        }

        let microphoneStops = await microphone.stopCount
        let systemStops = await system.stopCount
        XCTAssertEqual(systemStops, 1)
        XCTAssertEqual(microphoneStops, 1)
    }

    func testEstimatesWorstCaseExpectedSessionStorage() {
        let configuration = RecordingDiskSpaceConfiguration(
            expectedDuration: 60 * 60,
            minimumFreeSpaceReserveBytes: 100
        )

        XCTAssertEqual(
            configuration.estimatedRecordingBytes,
            1_152_000_000
        )
        XCTAssertEqual(
            configuration.requiredFreeSpaceBeforeRecordingBytes,
            1_152_000_100
        )
        let cappedConfiguration = RecordingDiskSpaceConfiguration(
            expectedDuration: .greatestFiniteMagnitude,
            minimumFreeSpaceReserveBytes: .max
        )
        XCTAssertEqual(cappedConfiguration.estimatedRecordingBytes, .max)
        XCTAssertEqual(
            cappedConfiguration.requiredFreeSpaceBeforeRecordingBytes,
            .max
        )
    }

    func testRefusesToStartBeforeEitherTrackWhenSpaceIsInsufficient()
        async
    {
        let microphone = FakeTrackCapture(source: .microphone)
        let system = FakeTrackCapture(source: .system)
        let configuration = RecordingDiskSpaceConfiguration(
            expectedDuration: 60,
            minimumFreeSpaceReserveBytes: 1_000,
            monitoringInterval: .seconds(3_600)
        )
        let required = configuration.requiredFreeSpaceBeforeRecordingBytes
        let coordinator = DualTrackRecordingCoordinator(
            microphoneCapture: microphone,
            systemCapture: system,
            freeSpaceProvider: MutableFreeSpaceProvider(
                availableBytes: required - 1
            ),
            diskSpaceConfiguration: configuration
        )

        do {
            _ = try await coordinator.startRecording(in: testDirectory())
            XCTFail("Expected disk-space preflight to refuse recording.")
        } catch let error as AudioCaptureError {
            XCTAssertEqual(
                error,
                .insufficientRecordingDiskSpace(
                    requiredBytes: required,
                    availableBytes: required - 1
                )
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let microphoneStarts = await microphone.startCount
        let systemStarts = await system.startCount
        XCTAssertEqual(microphoneStarts, 0)
        XCTAssertEqual(systemStarts, 0)
    }

    func testMonitoringFloorStopsAndFinalizesBothTracks() async throws {
        let microphone = FakeTrackCapture(source: .microphone)
        let system = FakeTrackCapture(source: .system)
        let provider = MutableFreeSpaceProvider(availableBytes: 10_000)
        let configuration = RecordingDiskSpaceConfiguration(
            expectedDuration: 0,
            minimumFreeSpaceReserveBytes: 1_000,
            monitoringInterval: .seconds(3_600)
        )
        let coordinator = DualTrackRecordingCoordinator(
            microphoneCapture: microphone,
            systemCapture: system,
            freeSpaceProvider: provider,
            diskSpaceConfiguration: configuration
        )
        let directory = testDirectory()
        defer {
            removeTestDirectory(directory)
        }
        _ = try await coordinator.startRecording(in: directory)
        await provider.setAvailableBytes(1_000)

        let result = try await coordinator.checkAvailableDiskSpace()

        XCTAssertEqual(
            result?.stopReason,
            .lowDiskSpace(availableBytes: 1_000, reserveBytes: 1_000)
        )
        let microphoneStops = await microphone.stopCount
        let systemStops = await system.stopCount
        XCTAssertEqual(microphoneStops, 1)
        XCTAssertEqual(systemStops, 1)
        let state = await coordinator.state
        guard case let .stopped(stoppedResult) = state else {
            return XCTFail("Expected a clean stopped state.")
        }
        XCTAssertEqual(stoppedResult, result)
    }

    private func testDiskConfiguration()
        -> RecordingDiskSpaceConfiguration
    {
        RecordingDiskSpaceConfiguration(
            expectedDuration: 0,
            minimumFreeSpaceReserveBytes: 0,
            monitoringInterval: .seconds(3_600)
        )
    }

    private func testDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "ScribeDualTrackTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func removeTestDirectory(_ directory: URL) {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            XCTFail("Unable to remove test directory: \(error)")
        }
    }
}

private actor MutableFreeSpaceProvider: RecordingFreeSpaceProviding {
    private var availableBytes: Int64

    init(availableBytes: Int64) {
        self.availableBytes = availableBytes
    }

    func availableCapacity(at _: URL) -> Int64 {
        availableBytes
    }

    func setAvailableBytes(_ availableBytes: Int64) {
        self.availableBytes = availableBytes
    }
}

private actor FakeTrackCapture: AudioTrackCapturing {
    let source: AudioSource
    let startFailure: AudioCaptureError?
    let stopFailure: AudioCaptureError?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var outputURL: URL?

    init(
        source: AudioSource,
        startFailure: AudioCaptureError? = nil,
        stopFailure: AudioCaptureError? = nil
    ) {
        self.source = source
        self.startFailure = startFailure
        self.stopFailure = stopFailure
    }

    func startRecording(to outputURL: URL) throws {
        startCount += 1
        if let startFailure {
            throw startFailure
        }
        self.outputURL = outputURL
    }

    func stopCapture() throws -> AudioTrackCaptureResult {
        stopCount += 1
        if let stopFailure {
            throw stopFailure
        }
        guard let outputURL else {
            throw AudioCaptureError.audioConsumerFailed(
                "Fake capture was never started."
            )
        }
        return AudioTrackCaptureResult(
            source: source,
            outputURL: outputURL,
            droppedSampleCount: 0
        )
    }
}
