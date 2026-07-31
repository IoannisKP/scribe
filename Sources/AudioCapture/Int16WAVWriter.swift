import Foundation

/// Streams canonical mono Float32 samples to a durable 16-bit PCM RIFF/WAVE.
///
/// Quantization happens only on the non-realtime file path. Capture, live
/// fan-out, VAD, and transcription continue to receive the original Float32
/// samples. Headers are synchronized after every append so an interrupted
/// process leaves a readable file.
public actor Int16WAVWriter {
    public let url: URL

    public static let bytesPerSample: UInt16 = 2
    public static let bitsPerSample: UInt16 = 16

    private static let headerByteCount: UInt64 = 44
    private static let maximumDataByteCount = UInt64(UInt32.max) - 36

    private let fileHandle: FileHandle
    private var dataByteCount: UInt64 = 0
    private var isFinalized = false

    public init(url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw AudioCaptureError.wavFileAlreadyExists(url)
        }

        let parentDirectory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw AudioCaptureError.wavFileCreationFailed(url)
        }

        let fileHandle = try FileHandle(forWritingTo: url)
        try fileHandle.write(contentsOf: Self.makeHeader(dataByteCount: 0))
        try fileHandle.synchronize()
        self.url = url
        self.fileHandle = fileHandle
    }

    public var sampleCount: UInt64 {
        dataByteCount / UInt64(Self.bytesPerSample)
    }

    public func append(_ samples: [Float]) throws {
        guard !isFinalized else {
            throw AudioCaptureError.wavWriterFinalized
        }
        let appendedByteCount = UInt64(samples.count)
            * UInt64(Self.bytesPerSample)
        guard dataByteCount + appendedByteCount <= Self.maximumDataByteCount else {
            throw AudioCaptureError.wavFileTooLarge
        }

        var encoded = Data()
        encoded.reserveCapacity(Int(appendedByteCount))
        for sample in samples {
            let quantized = Self.quantize(sample)
            var littleEndian = quantized.littleEndian
            withUnsafeBytes(of: &littleEndian) {
                encoded.append(contentsOf: $0)
            }
        }

        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: encoded)
        dataByteCount += appendedByteCount
        try updateHeader()
        try fileHandle.synchronize()
    }

    public func finish() throws {
        guard !isFinalized else {
            return
        }
        try updateHeader()
        try fileHandle.synchronize()
        try fileHandle.close()
        isFinalized = true
    }

    private func updateHeader() throws {
        let header = Self.makeHeader(dataByteCount: UInt32(dataByteCount))
        try fileHandle.seek(toOffset: 0)
        try fileHandle.write(contentsOf: header)
        try fileHandle.seekToEnd()
    }

    private static func quantize(_ sample: Float) -> Int16 {
        guard sample.isFinite else {
            return 0
        }
        if sample <= -1 {
            return .min
        }
        if sample >= 1 {
            return .max
        }
        let scaled = (sample * 32_768).rounded()
        return Int16(
            min(
                Float(Int16.max),
                max(Float(Int16.min), scaled)
            )
        )
    }

    private static func makeHeader(dataByteCount: UInt32) -> Data {
        var data = Data()
        data.reserveCapacity(Int(headerByteCount))
        data.appendASCII("RIFF")
        data.appendLittleEndian(dataByteCount + 36)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(CanonicalAudioFormat.channelCount))
        data.appendLittleEndian(UInt32(CanonicalAudioFormat.sampleRate))
        let byteRate = UInt32(CanonicalAudioFormat.sampleRate)
            * UInt32(Self.bytesPerSample)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(Self.bytesPerSample)
        data.appendLittleEndian(Self.bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(dataByteCount)
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ value: StaticString) {
        value.withUTF8Buffer { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) {
            append(contentsOf: $0)
        }
    }
}
