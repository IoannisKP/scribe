@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

public struct ImportedMediaConversionResult: Equatable, Sendable {
    public let outputURL: URL
    public let sampleCount: UInt64

    public var duration: TimeInterval {
        Double(sampleCount) / CanonicalAudioFormat.sampleRate
    }
}

public enum ImportedMediaConversionError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case unsupportedFormat(filename: String)
    case noAudioTrack(filename: String)
    case producedNoAudio(filename: String)
    case readerFailed(filename: String, detail: String)
    case unexpectedPCMFormat

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(filename):
            "Scribe can't read “\(filename)”. Choose an audio or video format supported by macOS."
        case let .noAudioTrack(filename):
            "“\(filename)” doesn't contain an audio track. Choose a file with audio."
        case let .producedNoAudio(filename):
            "Scribe found no audio samples in “\(filename)”. Choose a file that contains playable audio."
        case let .readerFailed(filename, _):
            "Scribe couldn't decode audio from “\(filename)”. The original file is untouched."
        case .unexpectedPCMFormat:
            "The macOS audio decoder returned an unexpected sample format."
        }
    }
}

/// Streams the first audio track of an AVFoundation-readable asset into the
/// canonical 16 kHz mono Int16 WAV format. Conversion is bounded by the asset
/// reader's current sample buffer and never loads the full source into memory.
public actor ImportedMediaConverter {
    public init() {}

    public func convert(
        sourceURL: URL,
        outputURL: URL
    ) async throws -> ImportedMediaConversionResult {
        let filename = sourceURL.lastPathComponent
        let asset = AVURLAsset(url: sourceURL)
        let isPlayable: Bool
        do {
            isPlayable = try await asset.load(.isPlayable)
        } catch {
            throw ImportedMediaConversionError.unsupportedFormat(
                filename: filename
            )
        }
        guard isPlayable else {
            throw ImportedMediaConversionError.unsupportedFormat(
                filename: filename
            )
        }

        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ImportedMediaConversionError.unsupportedFormat(
                filename: filename
            )
        }
        guard let audioTrack = audioTracks.first else {
            throw ImportedMediaConversionError.noAudioTrack(
                filename: filename
            )
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ImportedMediaConversionError.readerFailed(
                filename: filename,
                detail: error.localizedDescription
            )
        }
        let output = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: CanonicalAudioFormat.sampleRate,
                AVNumberOfChannelsKey: CanonicalAudioFormat.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ImportedMediaConversionError.readerFailed(
                filename: filename,
                detail: "AVAssetReader rejected its audio output."
            )
        }
        reader.add(output)

        let writer = try Int16WAVWriter(url: outputURL)
        do {
            guard reader.startReading() else {
                throw ImportedMediaConversionError.readerFailed(
                    filename: filename,
                    detail: reader.error?.localizedDescription
                        ?? "AVAssetReader did not start."
                )
            }
            var sampleCount: UInt64 = 0
            while reader.status == .reading {
                try Task.checkCancellation()
                guard let sampleBuffer = output.copyNextSampleBuffer() else {
                    break
                }
                let samples = try Self.floatSamples(from: sampleBuffer)
                CMSampleBufferInvalidate(sampleBuffer)
                if !samples.isEmpty {
                    try await writer.append(samples)
                    sampleCount += UInt64(samples.count)
                }
            }
            guard reader.status == .completed else {
                throw ImportedMediaConversionError.readerFailed(
                    filename: filename,
                    detail: reader.error?.localizedDescription
                        ?? "AVAssetReader stopped before completion."
                )
            }
            guard sampleCount > 0 else {
                throw ImportedMediaConversionError.producedNoAudio(
                    filename: filename
                )
            }
            try await writer.finish()
            return ImportedMediaConversionResult(
                outputURL: outputURL,
                sampleCount: sampleCount
            )
        } catch {
            reader.cancelReading()
            try? await writer.finish()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func floatSamples(
        from sampleBuffer: CMSampleBuffer
    ) throws -> [Float] {
        guard
            let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let stream = CMAudioFormatDescriptionGetStreamBasicDescription(
                description
            )?.pointee,
            stream.mFormatID == kAudioFormatLinearPCM,
            stream.mChannelsPerFrame == CanonicalAudioFormat.channelCount,
            stream.mBitsPerChannel == 32,
            stream.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            stream.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        else {
            throw ImportedMediaConversionError.unexpectedPCMFormat
        }

        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: CanonicalAudioFormat.channelCount,
                mDataByteSize: 0,
                mData: nil
            )
        )
        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(
                kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment
            ),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr,
            audioBufferList.mNumberBuffers == 1,
            let data = audioBufferList.mBuffers.mData
        else {
            throw ImportedMediaConversionError.unexpectedPCMFormat
        }
        let byteCount = Int(audioBufferList.mBuffers.mDataByteSize)
        guard byteCount.isMultiple(of: MemoryLayout<Float>.size) else {
            throw ImportedMediaConversionError.unexpectedPCMFormat
        }
        let count = byteCount / MemoryLayout<Float>.size
        return Array(
            UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: Float.self),
                count: count
            )
        )
    }
}
