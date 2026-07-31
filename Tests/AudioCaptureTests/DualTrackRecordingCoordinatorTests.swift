import AudioCapture
import Foundation
import XCTest

final class DualTrackRecordingCoordinatorTests: XCTestCase {
    func testStartsAndStopsIndependentTrackFiles() async throws {
        let microphone = FakeTrackCapture(source: .microphone)
        let system = FakeTrackCapture(source: .system)
        let coordinator = DualTrackRecordingCoordinator(
            microphoneCapture: microphone,
            systemCapture: system
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
            systemCapture: system
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
            systemCapture: system
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
