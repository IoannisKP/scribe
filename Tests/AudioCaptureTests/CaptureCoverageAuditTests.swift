@testable import AudioCapture
import Foundation
import XCTest

/// The single assertion that catches both observed capture defects: written
/// sample count must account for the time the recording covered, per track.
///
/// Measured on the affected hardware:
///   2026-08-13 15.07  mic 38.6s  sys 38.6s   last good
///   2026-08-13 22.39  mic  0.0s  sys 16.6s   empty microphone
///   2026-08-14 08.21  mic 48.2s  sys 26.7s   undersampled system
final class CaptureCoverageAuditTests: XCTestCase {
    private let audit = CaptureCoverageAudit()

    // MARK: - The audit itself

    func testCompleteTrackPassesTheAudit() {
        XCTAssertEqual(
            audit.verdict(capturedSampleCount: 16_000 * 30, duration: 30),
            .complete
        )
    }

    func testEmptyTrackIsReportedSeparatelyFromAShortOne() {
        XCTAssertEqual(
            audit.verdict(capturedSampleCount: 0, duration: 30),
            .empty
        )
    }

    /// The 08.21 system track: 26.7 s of samples across a 48.2 s recording.
    func testMeasuredUndersampledSystemTrackIsCaught() {
        let verdict = audit.verdict(
            capturedSampleCount: UInt64(26.7 * 16_000),
            duration: 48.2
        )
        guard case let .undersampled(ratio) = verdict else {
            XCTFail("Expected undersampled; got \(verdict).")
            return
        }
        XCTAssertEqual(ratio, 26.7 / 48.2, accuracy: 0.01)
    }

    /// A resampler told 48 kHz while the hardware delivers 24 kHz decimates
    /// 3:1 instead of 1.5:1 and writes half the samples it should.
    func testHalfRateTrackIsCaught() {
        let verdict = audit.verdict(
            capturedSampleCount: 16_000 * 15,
            duration: 30
        )
        guard case let .undersampled(ratio) = verdict else {
            XCTFail("Expected undersampled; got \(verdict).")
            return
        }
        XCTAssertEqual(ratio, 0.5, accuracy: 0.001)
    }

    func testStartStopSkewStaysWithinTolerance() {
        // The last good session: both tracks 38.6 s, and healthy sessions
        // historically differ by under one percent between tracks.
        XCTAssertEqual(
            audit.verdict(
                capturedSampleCount: UInt64(38.6 * 16_000),
                duration: 38.9
            ),
            .complete
        )
    }

    func testOversampledTrackIsCaught() {
        let verdict = audit.verdict(
            capturedSampleCount: 16_000 * 60,
            duration: 30
        )
        guard case .oversampled = verdict else {
            XCTFail("Expected oversampled; got \(verdict).")
            return
        }
    }

    // MARK: - Applied to real written WAV files

    /// A consumer configured with the rate the hardware is actually delivering
    /// writes a file whose duration matches the audio it was fed.
    func testConsumerConfiguredWithTheActualRateWritesAFullLengthTrack()
        async throws
    {
        let seconds = 3.0
        let hardwareRate = 24_000.0
        let url = try await writeTrack(
            seconds: seconds,
            hardwareRate: hardwareRate,
            configuredRate: hardwareRate
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let written = try canonicalSampleCount(of: url)
        XCTAssertEqual(
            audit.verdict(capturedSampleCount: written, duration: seconds),
            .complete
        )
    }

    /// The system defect, reproduced end to end through the real resampler and
    /// the real WAV writer: a stale 48 kHz source rate against 24 kHz hardware
    /// silently writes about half the samples, with a correct 16 kHz header and
    /// no error anywhere. This assertion is what the shipped code lacked.
    func testStaleSourceRateSilentlyWritesAShortTrack() async throws {
        let seconds = 3.0
        let url = try await writeTrack(
            seconds: seconds,
            hardwareRate: 24_000,
            configuredRate: 48_000
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let header = try wavHeader(of: url)
        XCTAssertEqual(
            header.sampleRate,
            UInt32(CanonicalAudioFormat.sampleRate),
            "The header is correct, which is why this defect stayed invisible."
        )

        let written = try canonicalSampleCount(of: url)
        let verdict = audit.verdict(
            capturedSampleCount: written,
            duration: seconds
        )
        guard case let .undersampled(ratio) = verdict else {
            XCTFail("A stale source rate went undetected; got \(verdict).")
            return
        }
        XCTAssertEqual(ratio, 0.5, accuracy: 0.05)
    }

    // MARK: - Support

    private func writeTrack(
        seconds: Double,
        hardwareRate: Double,
        configuredRate: Double
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "coverage-\(UUID().uuidString).wav",
                isDirectory: false
            )
        let frameCount = Int(hardwareRate * seconds)
        let ringBuffer = try FloatRingBuffer(capacity: 8_192)
        let consumer = try CanonicalAudioFileConsumer(
            source: .system,
            ringBuffer: ringBuffer,
            inputSampleRate: configuredRate,
            outputURL: url
        )

        // A 440 Hz tone at the rate the hardware really produces.
        var written = 0
        while written < frameCount {
            let chunk = min(2_048, frameCount - written)
            var samples = [Float](repeating: 0, count: chunk)
            for index in 0..<chunk {
                let phase = Double(written + index) * 440 * 2 * .pi
                    / hardwareRate
                samples[index] = Float(sin(phase)) * 0.25
            }
            var offset = 0
            while offset < chunk {
                let accepted = samples[offset...].withUnsafeBufferPointer {
                    ringBuffer.write($0)
                }
                offset += accepted
                if accepted == 0 {
                    _ = try await consumer.processAvailable()
                }
            }
            written += chunk
            _ = try await consumer.processAvailable()
        }
        try await consumer.finish()
        return url
    }

    private struct WAVHeader {
        let sampleRate: UInt32
        let bitsPerSample: UInt16
        let dataByteCount: UInt32
    }

    private func wavHeader(of url: URL) throws -> WAVHeader {
        let data = try Data(contentsOf: url)
        func uint32(at offset: Int) -> UInt32 {
            data[offset..<(offset + 4)].reversed().reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
        }
        func uint16(at offset: Int) -> UInt16 {
            data[offset..<(offset + 2)].reversed().reduce(UInt16(0)) {
                ($0 << 8) | UInt16($1)
            }
        }
        return WAVHeader(
            sampleRate: uint32(at: 24),
            bitsPerSample: uint16(at: 34),
            dataByteCount: uint32(at: 40)
        )
    }

    private func canonicalSampleCount(of url: URL) throws -> UInt64 {
        let header = try wavHeader(of: url)
        let bytesPerSample = UInt32(header.bitsPerSample / 8)
        XCTAssertGreaterThan(bytesPerSample, 0)
        return UInt64(header.dataByteCount / bytesPerSample)
    }
}
