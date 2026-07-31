@preconcurrency import AVFoundation
import Foundation

/// Converts mono Float32 samples to another sample rate using AVAudioConverter.
///
/// Conversion allocates output storage and must run on a consumer queue, never
/// in an audio device callback. An instance preserves converter state between
/// calls and therefore must be used serially.
public final class AudioResampler {
    public let inputSampleRate: Double
    public let outputSampleRate: Double

    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    public init(
        inputSampleRate: Double,
        outputSampleRate: Double = CanonicalAudioFormat.sampleRate
    ) throws {
        guard inputSampleRate.isFinite, inputSampleRate > 0 else {
            throw AudioCaptureError.invalidSampleRate(inputSampleRate)
        }
        guard outputSampleRate.isFinite, outputSampleRate > 0 else {
            throw AudioCaptureError.invalidSampleRate(outputSampleRate)
        }
        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputSampleRate,
                channels: 1,
                interleaved: false
            ),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: outputSampleRate,
                channels: 1,
                interleaved: false
            )
        else {
            throw AudioCaptureError.audioFormatCreationFailed
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioCaptureError.audioConverterCreationFailed
        }

        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    public func convert(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty else {
            return []
        }
        guard samples.count <= Int(AVAudioFrameCount.max) else {
            throw AudioCaptureError.audioBufferAllocationFailed
        }

        let inputFrameCount = AVAudioFrameCount(samples.count)
        guard
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: inputFrameCount
            ),
            let inputChannel = inputBuffer.floatChannelData?.pointee
        else {
            throw AudioCaptureError.audioBufferAllocationFailed
        }

        inputBuffer.frameLength = inputFrameCount
        samples.withUnsafeBufferPointer { source in
            if let sourceAddress = source.baseAddress {
                inputChannel.update(from: sourceAddress, count: source.count)
            }
        }

        let ratio = outputSampleRate / inputSampleRate
        let estimatedFrames = ceil(Double(samples.count) * ratio) + 64
        guard estimatedFrames <= Double(AVAudioFrameCount.max) else {
            throw AudioCaptureError.audioBufferAllocationFailed
        }
        let outputCapacity = AVAudioFrameCount(estimatedFrames)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            throw AudioCaptureError.audioBufferAllocationFailed
        }

        let inputState = ConverterInputState(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(
            to: outputBuffer,
            error: &conversionError
        ) { _, inputStatus in
            guard !inputState.wasSupplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }

            inputState.wasSupplied = true
            inputStatus.pointee = .haveData
            return inputState.buffer
        }

        if status == .error {
            let message = conversionError?.localizedDescription
                ?? "AVAudioConverter returned an unspecified error."
            throw AudioCaptureError.audioConversionFailed(message)
        }
        if let conversionError {
            throw AudioCaptureError.audioConversionFailed(
                conversionError.localizedDescription
            )
        }
        guard let outputChannel = outputBuffer.floatChannelData?.pointee else {
            throw AudioCaptureError.audioConversionProducedNoChannelData
        }

        return UnsafeBufferPointer(
            start: outputChannel,
            count: Int(outputBuffer.frameLength)
        ).map { min(1, max(-1, $0)) }
    }

    public func reset() {
        converter.reset()
    }
}

/// AVAudioConverter invokes its input block synchronously and serially during a
/// `convert` call. The box avoids treating a captured local variable as shared
/// mutable state under Swift 6's imported `@Sendable` block signature.
private final class ConverterInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var wasSupplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
