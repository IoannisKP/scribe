import Foundation

/// Streams canonical mono Float32 audio to a RIFF/WAVE file.
///
/// The actor keeps disk I/O off realtime audio callbacks. After every append it
/// updates and synchronizes the RIFF lengths, leaving a readable file if the
/// process terminates before an orderly `finish()`.
public actor Float32WAVWriter {
    public let url: URL

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

        do {
            let fileHandle = try FileHandle(forWritingTo: url)
            try fileHandle.write(contentsOf: Self.makeHeader(dataByteCount: 0))
            try fileHandle.synchronize()
            self.url = url
            self.fileHandle = fileHandle
        } catch {
            throw error
        }
    }

    public var sampleCount: UInt64 {
        dataByteCount / UInt64(CanonicalAudioFormat.bytesPerSample)
    }

    public func append(_ samples: [Float]) throws {
        guard !isFinalized else {
            throw AudioCaptureError.wavWriterFinalized
        }

        let appendedByteCount = UInt64(samples.count)
            * UInt64(CanonicalAudioFormat.bytesPerSample)
        guard dataByteCount + appendedByteCount <= Self.maximumDataByteCount else {
            throw AudioCaptureError.wavFileTooLarge
        }

        var encoded = Data()
        encoded.reserveCapacity(Int(appendedByteCount))
        for sample in samples {
            var bitPattern = min(1, max(-1, sample)).bitPattern.littleEndian
            withUnsafeBytes(of: &bitPattern) { bytes in
                encoded.append(contentsOf: bytes)
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

    private static func makeHeader(dataByteCount: UInt32) -> Data {
        var data = Data()
        data.reserveCapacity(Int(headerByteCount))
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(dataByteCount) + 36)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(3))
        data.appendLittleEndian(UInt16(CanonicalAudioFormat.channelCount))
        data.appendLittleEndian(UInt32(CanonicalAudioFormat.sampleRate))

        let byteRate = UInt32(CanonicalAudioFormat.sampleRate)
            * UInt32(CanonicalAudioFormat.bytesPerSample)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(CanonicalAudioFormat.bytesPerSample)
        data.appendLittleEndian(CanonicalAudioFormat.bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(dataByteCount)
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ value: StaticString) {
        value.withUTF8Buffer { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }
}
