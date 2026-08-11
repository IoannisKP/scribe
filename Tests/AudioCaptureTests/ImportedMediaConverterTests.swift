@preconcurrency import AVFoundation
import AudioCapture
import CoreVideo
import Foundation
import XCTest

final class ImportedMediaConverterTests: XCTestCase {
    func testConvertsStereo48kSourceToCanonicalInt16WithoutChangingSource()
        async throws
    {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("stereo-48k.wav")
        let output = directory.appendingPathComponent("audio.wav")
        try writeStereoFixture(to: source)
        let original = try Data(contentsOf: source)

        let result = try await ImportedMediaConverter().convert(
            sourceURL: source,
            outputURL: output
        )

        XCTAssertEqual(try Data(contentsOf: source), original)
        let converted = try AVAudioFile(forReading: output)
        XCTAssertEqual(converted.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(converted.fileFormat.channelCount, 1)
        XCTAssertEqual(converted.fileFormat.commonFormat, .pcmFormatInt16)
        // AVAssetReader's sample-rate converter may discard a handful of
        // priming frames; the duration remains within one millisecond.
        XCTAssertEqual(converted.length, 16_000, accuracy: 16)
        XCTAssertEqual(result.sampleCount, UInt64(converted.length))
    }

    func testRejectsUnreadableFormatWithActionableError() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("broken.mp3")
        try Data("not audio".utf8).write(to: source)

        do {
            _ = try await ImportedMediaConverter().convert(
                sourceURL: source,
                outputURL: directory.appendingPathComponent("audio.wav")
            )
            XCTFail("Expected an unreadable asset to be rejected.")
        } catch let error as ImportedMediaConversionError {
            XCTAssertEqual(error, .unsupportedFormat(filename: "broken.mp3"))
        }
    }

    func testDistinguishesPlayableVideoWithNoAudioTrack() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("silent.mov")
        try await writeVideoOnlyFixture(to: source)

        do {
            _ = try await ImportedMediaConverter().convert(
                sourceURL: source,
                outputURL: directory.appendingPathComponent("audio.wav")
            )
            XCTFail("Expected a video-only asset to be rejected.")
        } catch let error as ImportedMediaConversionError {
            XCTAssertEqual(error, .noAudioTrack(filename: "silent.mov"))
        }
    }

    private func writeStereoFixture(to url: URL) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)
        )
        buffer.frameLength = 48_000
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            let sample = sin(Float(frame) * 2 * .pi * 440 / 48_000) * 0.5
            channels[0][frame] = sample
            channels[1][frame] = sample * 0.5
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private func writeVideoOnlyFixture(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.jpeg,
                AVVideoWidthKey: 16,
                AVVideoHeightKey: 16
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 16,
                kCVPixelBufferHeightKey as String: 16
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        XCTAssertTrue(adaptor.append(try XCTUnwrap(pixelBuffer), withPresentationTime: .zero))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ScribeImportConverter-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
