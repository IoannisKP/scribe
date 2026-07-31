@preconcurrency import AVFoundation
import AudioCapture
import Foundation

public actor CanonicalWAVChunkReader {
    public let source: AudioSource
    public let trackStartTime: TimeInterval
    public let chunkDuration: TimeInterval
    public let overlapDuration: TimeInterval
    public let totalSampleCount: Int64

    private let url: URL
    private let audioFile: AVAudioFile
    private let processingFormat: AVAudioFormat
    private let framesPerChunk: AVAudioFrameCount
    private let framesPerStep: Int64
    private var nextSampleIndex: Int64 = 0

    public init(
        url: URL,
        source: AudioSource,
        trackStartTime: TimeInterval,
        chunkDuration: TimeInterval,
        overlapDuration: TimeInterval = 0
    ) throws {
        guard chunkDuration.isFinite, chunkDuration > 0 else {
            throw SpeechPipelineError.invalidChunkDuration(chunkDuration)
        }
        guard trackStartTime.isFinite, trackStartTime >= 0 else {
            throw SpeechPipelineError.invalidTrackStartTime(trackStartTime)
        }
        guard
            overlapDuration.isFinite,
            overlapDuration >= 0,
            overlapDuration < chunkDuration
        else {
            throw SpeechPipelineError.invalidChunkOverlap(overlapDuration)
        }

        let audioFile = try AVAudioFile(forReading: url)
        let fileFormat = audioFile.fileFormat
        let isCanonical = fileFormat.sampleRate
                == CanonicalAudioFormat.sampleRate
            && fileFormat.channelCount
                == CanonicalAudioFormat.channelCount
            && fileFormat.commonFormat == .pcmFormatFloat32
        guard isCanonical else {
            throw SpeechPipelineError.unsupportedAudioFormat(
                url: url,
                sampleRate: fileFormat.sampleRate,
                channelCount: fileFormat.channelCount,
                isFloat: fileFormat.commonFormat == .pcmFormatFloat32
            )
        }

        let requestedFrames =
            chunkDuration * CanonicalAudioFormat.sampleRate
        guard
            requestedFrames.isFinite,
            requestedFrames >= 1,
            requestedFrames <= Double(UInt32.max)
        else {
            throw SpeechPipelineError.invalidChunkDuration(chunkDuration)
        }

        self.url = url
        self.source = source
        self.trackStartTime = trackStartTime
        self.chunkDuration = chunkDuration
        self.overlapDuration = overlapDuration
        self.audioFile = audioFile
        self.processingFormat = audioFile.processingFormat
        self.framesPerChunk = AVAudioFrameCount(
            requestedFrames.rounded(.down)
        )
        let overlapFrames = Int64(
            (overlapDuration * CanonicalAudioFormat.sampleRate)
                .rounded(.down)
        )
        self.framesPerStep = Int64(self.framesPerChunk) - overlapFrames
        guard framesPerStep > 0 else {
            throw SpeechPipelineError.invalidChunkOverlap(overlapDuration)
        }
        self.totalSampleCount = audioFile.length
    }

    public var remainingSampleCount: Int64 {
        max(0, totalSampleCount - nextSampleIndex)
    }

    public func nextChunk() throws -> AudioChunk? {
        guard nextSampleIndex < totalSampleCount else {
            return nil
        }

        let chunkStartSample = nextSampleIndex
        audioFile.framePosition = chunkStartSample
        let remaining = totalSampleCount - chunkStartSample
        let requestedFrameCount = AVAudioFrameCount(
            min(Int64(framesPerChunk), remaining)
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: requestedFrameCount
        ) else {
            throw SpeechPipelineError.audioBufferAllocationFailed(url)
        }

        try audioFile.read(
            into: buffer,
            frameCount: requestedFrameCount
        )
        let frameLength = Int(buffer.frameLength)
        guard
            frameLength > 0,
            let channelData = buffer.floatChannelData
        else {
            throw SpeechPipelineError.audioFileProducedNoSamples(url)
        }

        let startTime = trackStartTime
            + Double(chunkStartSample) / CanonicalAudioFormat.sampleRate
        let samples = Array(
            UnsafeBufferPointer(
                start: channelData[0],
                count: frameLength
            )
        )
        let chunkEndSample = chunkStartSample + Int64(frameLength)
        nextSampleIndex = chunkEndSample >= totalSampleCount
            ? totalSampleCount
            : chunkStartSample + framesPerStep

        return AudioChunk(
            samples: samples,
            startTime: startTime,
            source: source
        )
    }
}
