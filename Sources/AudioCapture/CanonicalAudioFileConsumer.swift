import Foundation

/// Serial non-realtime consumer shared by microphone and system capture.
actor CanonicalAudioFileConsumer {
    private let source: AudioSource
    private let ringBuffer: FloatRingBuffer
    private let writer: Int16WAVWriter
    private let liveSink: (any CanonicalAudioBlockSink)?
    private var resampler: AudioResampler
    private var readBuffer = Array(repeating: Float.zero, count: 4_096)
    private var emittedSampleCount: UInt64 = 0
    private var backgroundFailureMessage: String?
    private var isFinished = false

    init(
        source: AudioSource,
        ringBuffer: FloatRingBuffer,
        inputSampleRate: Double,
        outputURL: URL,
        liveSink: (any CanonicalAudioBlockSink)? = nil
    ) throws {
        self.source = source
        self.ringBuffer = ringBuffer
        self.resampler = try AudioResampler(inputSampleRate: inputSampleRate)
        self.writer = try Int16WAVWriter(url: outputURL)
        self.liveSink = liveSink
    }

    func processAvailable() async throws -> Int {
        guard !isFinished else {
            return 0
        }
        if let backgroundFailureMessage {
            throw AudioCaptureError.audioConsumerFailed(
                backgroundFailureMessage
            )
        }

        let readCount = readBuffer.withUnsafeMutableBufferPointer {
            ringBuffer.read(into: $0)
        }
        guard readCount > 0 else {
            return 0
        }

        let input = Array(readBuffer.prefix(readCount))
        let output = try resampler.convert(input)
        if !output.isEmpty {
            try await writer.append(output)
            if let liveSink {
                let block = CanonicalAudioBlock(
                    source: source,
                    firstSampleIndex: emittedSampleCount,
                    samples: output
                )
                emittedSampleCount += UInt64(output.count)
                await liveSink.receive(block)
            } else {
                emittedSampleCount += UInt64(output.count)
            }
        }
        return readCount
    }

    func reconfigure(inputSampleRate: Double) throws {
        guard ringBuffer.readableCount == 0 else {
            throw AudioCaptureError.audioFormatChangedBeforeBufferedSamplesDrained
        }
        resampler = try AudioResampler(inputSampleRate: inputSampleRate)
    }

    func recordBackgroundFailure(_ message: String) {
        backgroundFailureMessage = message
    }

    func finalizeAfterBackgroundFailure() async throws {
        guard !isFinished else {
            return
        }
        try await writer.finish()
        isFinished = true
    }

    func finish() async throws {
        guard !isFinished else {
            return
        }

        while try await processAvailable() > 0 {}
        if let backgroundFailureMessage {
            throw AudioCaptureError.audioConsumerFailed(
                backgroundFailureMessage
            )
        }
        try await writer.finish()
        isFinished = true
    }
}
