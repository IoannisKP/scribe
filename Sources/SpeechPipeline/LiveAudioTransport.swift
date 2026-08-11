import AudioCapture
import Foundation

public enum LiveAudioTransportState: Equatable, Sendable {
    case idle
    case ready
    case keepingUp(pendingSampleCount: UInt64)
    case bufferingToDisk(pendingSampleCount: UInt64)
    case catchingUp(pendingSampleCount: UInt64)
    case recordingComplete(pendingSampleCount: UInt64)
    case drained
    case failed(message: String)

    public var isBuffering: Bool {
        if case .bufferingToDisk = self {
            return true
        }
        return false
    }
}

public struct LiveAudioTransportMetrics: Equatable, Sendable {
    public let acceptedBlockCount: UInt64
    public let deliveredBlockCount: UInt64
    public let pendingBlockCount: UInt64
    public let pendingSampleCount: UInt64
    public let peakPendingSampleCount: UInt64
    public let peakInMemorySampleCount: Int

    public init(
        acceptedBlockCount: UInt64,
        deliveredBlockCount: UInt64,
        pendingBlockCount: UInt64,
        pendingSampleCount: UInt64,
        peakPendingSampleCount: UInt64,
        peakInMemorySampleCount: Int
    ) {
        self.acceptedBlockCount = acceptedBlockCount
        self.deliveredBlockCount = deliveredBlockCount
        self.pendingBlockCount = pendingBlockCount
        self.pendingSampleCount = pendingSampleCount
        self.peakPendingSampleCount = peakPendingSampleCount
        self.peakInMemorySampleCount = peakInMemorySampleCount
    }

    public static let zero = LiveAudioTransportMetrics(
        acceptedBlockCount: 0,
        deliveredBlockCount: 0,
        pendingBlockCount: 0,
        pendingSampleCount: 0,
        peakPendingSampleCount: 0,
        peakInMemorySampleCount: 0
    )
}

public enum LiveAudioTransportError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case invalidBackpressureThresholds(
        buffering: TimeInterval,
        recovered: TimeInterval
    )
    case sessionAlreadyActive
    case sessionNotActive
    case spoolDirectoryAlreadyExists(URL)
    case spoolCreationFailed(URL)
    case malformedSpoolRecord(URL)
    case noncontiguousBlock(
        source: AudioSource,
        expectedSampleIndex: UInt64,
        actualSampleIndex: UInt64
    )
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidBackpressureThresholds(buffering, recovered):
            """
            Live-audio buffering thresholds must be finite, represent at least \
            one sample, and recover below the buffering threshold; received \
            \(buffering) s and \(recovered) s.
            """
        case .sessionAlreadyActive:
            "A live-audio transport session is already active."
        case .sessionNotActive:
            "There is no active live-audio transport session."
        case let .spoolDirectoryAlreadyExists(url):
            "Refusing to overwrite the existing live-audio spool at \(url.path)."
        case let .spoolCreationFailed(url):
            "Unable to create the live-audio spool at \(url.path)."
        case let .malformedSpoolRecord(url):
            "The live-audio spool contains a malformed record at \(url.path)."
        case let .noncontiguousBlock(
            source,
            expectedSampleIndex,
            actualSampleIndex
        ):
            "The \(source.rawValue) live feed skipped from sample \(expectedSampleIndex) to \(actualSampleIndex)."
        case let .operationFailed(message):
            "The live-audio transport failed: \(message)"
        }
    }
}

protocol LiveAudioSpoolStorage: Sendable {
    var source: AudioSource { get }
    var url: URL { get }

    func append(_ block: CanonicalAudioBlock) throws
    func next() throws -> CanonicalAudioBlock?
    func finishWriting() throws
    func discard() throws
}

typealias LiveAudioSpoolFactory =
    @Sendable (URL, AudioSource) throws -> any LiveAudioSpoolStorage

public actor LiveAudioTransport: CanonicalAudioBlockSink {
    public private(set) var state: LiveAudioTransportState = .idle
    public private(set) var metrics: LiveAudioTransportMetrics = .zero

    private let bufferingThresholdSamples: UInt64
    private let recoveredThresholdSamples: UInt64
    private let storageFactory: LiveAudioSpoolFactory

    private var storages: [AudioSource: any LiveAudioSpoolStorage] = [:]
    private var expectedSampleIndices: [AudioSource: UInt64] = [:]
    private var pendingSamplesBySource: [AudioSource: UInt64] = [:]
    private var isAccepting = false

    public init(
        bufferingThreshold: TimeInterval = 10,
        recoveredThreshold: TimeInterval = 2
    ) throws {
        let bufferingSampleCount =
            bufferingThreshold * CanonicalAudioFormat.sampleRate
        let recoveredSampleCount =
            recoveredThreshold * CanonicalAudioFormat.sampleRate
        let maximumConvertibleSampleCount =
            Double(UInt64.max).nextDown
        guard
            bufferingThreshold.isFinite,
            recoveredThreshold.isFinite,
            bufferingSampleCount.isFinite,
            recoveredSampleCount.isFinite,
            bufferingSampleCount >= 1,
            bufferingSampleCount <= maximumConvertibleSampleCount,
            recoveredThreshold >= 0,
            recoveredSampleCount >= 0,
            recoveredSampleCount < bufferingSampleCount,
            recoveredSampleCount <= maximumConvertibleSampleCount
        else {
            throw LiveAudioTransportError.invalidBackpressureThresholds(
                buffering: bufferingThreshold,
                recovered: recoveredThreshold
            )
        }

        let bufferingThresholdSamples = UInt64(bufferingSampleCount)
        let recoveredThresholdSamples = UInt64(recoveredSampleCount)
        guard recoveredThresholdSamples < bufferingThresholdSamples else {
            throw LiveAudioTransportError.invalidBackpressureThresholds(
                buffering: bufferingThreshold,
                recovered: recoveredThreshold
            )
        }
        self.bufferingThresholdSamples = bufferingThresholdSamples
        self.recoveredThresholdSamples = recoveredThresholdSamples
        self.storageFactory = { directory, source in
            try FileLiveAudioSpoolStorage(
                directory: directory,
                source: source
            )
        }
    }

    init(
        bufferingThresholdSamples: UInt64,
        recoveredThresholdSamples: UInt64,
        storageFactory: @escaping LiveAudioSpoolFactory
    ) {
        self.bufferingThresholdSamples = bufferingThresholdSamples
        self.recoveredThresholdSamples = recoveredThresholdSamples
        self.storageFactory = storageFactory
    }

    public func beginSession(in sessionDirectory: URL) throws {
        guard storages.isEmpty else {
            throw LiveAudioTransportError.sessionAlreadyActive
        }

        let spoolDirectory = sessionDirectory.appendingPathComponent(
            "LiveSpool",
            isDirectory: true
        )
        guard
            !FileManager.default.fileExists(atPath: spoolDirectory.path)
        else {
            throw LiveAudioTransportError.spoolDirectoryAlreadyExists(
                spoolDirectory
            )
        }

        do {
            try FileManager.default.createDirectory(
                at: spoolDirectory,
                withIntermediateDirectories: true
            )
            var created: [AudioSource: any LiveAudioSpoolStorage] = [:]
            for source in AudioSource.liveCaptureSources {
                created[source] = try storageFactory(
                    spoolDirectory,
                    source
                )
            }
            storages = created
        } catch {
            let originalMessage = error.localizedDescription
            do {
                if FileManager.default.fileExists(
                    atPath: spoolDirectory.path
                ) {
                    try FileManager.default.removeItem(at: spoolDirectory)
                }
            } catch {
                throw LiveAudioTransportError.operationFailed(
                    "\(originalMessage) Removing the partial spool also failed: \(error.localizedDescription)"
                )
            }
            throw LiveAudioTransportError.operationFailed(originalMessage)
        }

        expectedSampleIndices = Dictionary(
            uniqueKeysWithValues: AudioSource.liveCaptureSources.map { ($0, 0) }
        )
        pendingSamplesBySource = expectedSampleIndices
        metrics = .zero
        isAccepting = true
        state = .ready
    }

    public func receive(_ block: CanonicalAudioBlock) async {
        guard isAccepting else {
            return
        }
        do {
            try accept(block)
        } catch {
            state = .failed(message: error.localizedDescription)
            isAccepting = false
        }
    }

    public func nextBlock(
        for source: AudioSource
    ) throws -> CanonicalAudioBlock? {
        guard let storage = storages[source] else {
            throw LiveAudioTransportError.sessionNotActive
        }
        let sourcePending = pendingSamplesBySource[source] ?? 0
        guard sourcePending > 0 else {
            updateStateAfterRead()
            return nil
        }
        guard let block = try storage.next() else {
            throw LiveAudioTransportError.malformedSpoolRecord(
                storage.url
            )
        }

        let sampleCount = UInt64(block.samples.count)
        guard sampleCount <= sourcePending else {
            throw LiveAudioTransportError.malformedSpoolRecord(storage.url)
        }
        pendingSamplesBySource[source] = sourcePending - sampleCount
        metrics = LiveAudioTransportMetrics(
            acceptedBlockCount: metrics.acceptedBlockCount,
            deliveredBlockCount: metrics.deliveredBlockCount + 1,
            pendingBlockCount: metrics.pendingBlockCount - 1,
            pendingSampleCount: metrics.pendingSampleCount - sampleCount,
            peakPendingSampleCount: metrics.peakPendingSampleCount,
            peakInMemorySampleCount: max(
                metrics.peakInMemorySampleCount,
                block.samples.count
            )
        )
        updateStateAfterRead()
        return block
    }

    public func finishProducing() throws {
        guard !storages.isEmpty else {
            throw LiveAudioTransportError.sessionNotActive
        }
        let priorFailureMessage: String?
        if case let .failed(message) = state {
            priorFailureMessage = message
        } else {
            priorFailureMessage = nil
        }
        var failures: [String] = []
        for source in AudioSource.liveCaptureSources {
            guard let storage = storages[source] else {
                failures.append("The \(source.rawValue) spool is missing.")
                continue
            }
            do {
                try storage.finishWriting()
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        isAccepting = false
        if !failures.isEmpty {
            if let priorFailureMessage {
                failures.insert(priorFailureMessage, at: 0)
            }
            let message = failures.joined(separator: " ")
            state = .failed(message: message)
            throw LiveAudioTransportError.operationFailed(message)
        }
        if let priorFailureMessage {
            state = .failed(message: priorFailureMessage)
        } else {
            state =
                metrics.pendingSampleCount == 0
                ? .drained
                : .recordingComplete(
                    pendingSampleCount: metrics.pendingSampleCount
                )
        }
    }

    public func discardSpool(
        finalState: LiveAudioTransportState = .idle
    ) throws {
        guard !storages.isEmpty else {
            state = finalState
            return
        }
        var failures: [String] = []
        var parentDirectory: URL?
        for source in AudioSource.liveCaptureSources {
            guard let storage = storages[source] else {
                continue
            }
            parentDirectory = storage.url.deletingLastPathComponent()
            do {
                try storage.discard()
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if let parentDirectory,
            FileManager.default.fileExists(atPath: parentDirectory.path)
        {
            do {
                try FileManager.default.removeItem(at: parentDirectory)
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        storages.removeAll(keepingCapacity: false)
        expectedSampleIndices.removeAll(keepingCapacity: false)
        pendingSamplesBySource.removeAll(keepingCapacity: false)
        isAccepting = false
        metrics = .zero

        if !failures.isEmpty {
            let message = failures.joined(separator: " ")
            state = .failed(message: message)
            throw LiveAudioTransportError.operationFailed(message)
        }
        state = finalState
    }

    private func accept(_ block: CanonicalAudioBlock) throws {
        guard let storage = storages[block.source] else {
            throw LiveAudioTransportError.sessionNotActive
        }
        let expectedIndex = expectedSampleIndices[block.source] ?? 0
        guard block.firstSampleIndex == expectedIndex else {
            throw LiveAudioTransportError.noncontiguousBlock(
                source: block.source,
                expectedSampleIndex: expectedIndex,
                actualSampleIndex: block.firstSampleIndex
            )
        }
        guard !block.samples.isEmpty else {
            return
        }

        try storage.append(block)
        let sampleCount = UInt64(block.samples.count)
        expectedSampleIndices[block.source] = expectedIndex + sampleCount
        pendingSamplesBySource[block.source] =
            (pendingSamplesBySource[block.source] ?? 0) + sampleCount
        let pendingSampleCount = metrics.pendingSampleCount + sampleCount
        metrics = LiveAudioTransportMetrics(
            acceptedBlockCount: metrics.acceptedBlockCount + 1,
            deliveredBlockCount: metrics.deliveredBlockCount,
            pendingBlockCount: metrics.pendingBlockCount + 1,
            pendingSampleCount: pendingSampleCount,
            peakPendingSampleCount: max(
                metrics.peakPendingSampleCount,
                pendingSampleCount
            ),
            peakInMemorySampleCount: max(
                metrics.peakInMemorySampleCount,
                block.samples.count
            )
        )
        state =
            pendingSampleCount >= bufferingThresholdSamples
            ? .bufferingToDisk(
                pendingSampleCount: pendingSampleCount
            )
            : .keepingUp(pendingSampleCount: pendingSampleCount)
    }

    private func updateStateAfterRead() {
        let pending = metrics.pendingSampleCount
        if !isAccepting {
            state =
                pending == 0
                ? .drained
                : .catchingUp(pendingSampleCount: pending)
            return
        }

        switch state {
        case .bufferingToDisk, .catchingUp:
            if pending <= recoveredThresholdSamples {
                state = .keepingUp(pendingSampleCount: pending)
            } else {
                state = .catchingUp(pendingSampleCount: pending)
            }
        case .idle, .ready, .keepingUp, .recordingComplete, .drained,
            .failed:
            state =
                pending >= bufferingThresholdSamples
                ? .bufferingToDisk(pendingSampleCount: pending)
                : .keepingUp(pendingSampleCount: pending)
        }
    }
}

private final class FileLiveAudioSpoolStorage:
    LiveAudioSpoolStorage,
    @unchecked Sendable
{
    // LiveAudioTransport's actor is the sole owner and serial caller. The
    // unchecked conformance exists only to cross that actor boundary; FileHandle
    // and the mutable offsets are never accessed concurrently.
    let source: AudioSource
    let url: URL

    private let writer: FileHandle
    private let reader: FileHandle
    private var isWriterClosed = false
    private var isDiscarded = false

    init(directory: URL, source: AudioSource) throws {
        self.source = source
        self.url = directory.appendingPathComponent(
            "\(source.rawValue).livepcm",
            isDirectory: false
        )
        guard
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil
            )
        else {
            throw LiveAudioTransportError.spoolCreationFailed(url)
        }
        do {
            self.writer = try FileHandle(forWritingTo: url)
            self.reader = try FileHandle(forReadingFrom: url)
        } catch {
            throw LiveAudioTransportError.operationFailed(
                "Opening \(url.path) failed: \(error.localizedDescription)"
            )
        }
    }

    func append(_ block: CanonicalAudioBlock) throws {
        guard !isWriterClosed, !isDiscarded else {
            throw LiveAudioTransportError.operationFailed(
                "Writing to the closed spool at \(url.path) was refused."
            )
        }
        guard block.source == source else {
            throw LiveAudioTransportError.operationFailed(
                "A \(block.source.rawValue) block was sent to the \(source.rawValue) spool."
            )
        }

        var record = Data(capacity: 12 + block.samples.count * 4)
        Self.append(block.firstSampleIndex, to: &record)
        guard block.samples.count <= Int(UInt32.max) else {
            throw LiveAudioTransportError.operationFailed(
                "A live-audio block is too large to spool."
            )
        }
        Self.append(UInt32(block.samples.count), to: &record)
        for sample in block.samples {
            Self.append(sample.bitPattern, to: &record)
        }
        try writer.write(contentsOf: record)
    }

    func next() throws -> CanonicalAudioBlock? {
        guard !isDiscarded else {
            throw LiveAudioTransportError.sessionNotActive
        }
        guard let header = try readExactly(12) else {
            return nil
        }
        let firstSampleIndex = Self.decodeUInt64(header, offset: 0)
        let sampleCount = Self.decodeUInt32(header, offset: 8)
        guard sampleCount > 0, sampleCount <= 1_000_000 else {
            throw LiveAudioTransportError.malformedSpoolRecord(url)
        }
        let byteCount = Int(sampleCount) * 4
        guard let sampleData = try readExactly(byteCount) else {
            throw LiveAudioTransportError.malformedSpoolRecord(url)
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(sampleCount))
        for index in 0..<Int(sampleCount) {
            let bits = Self.decodeUInt32(
                sampleData,
                offset: index * 4
            )
            samples.append(Float(bitPattern: bits))
        }
        return CanonicalAudioBlock(
            source: source,
            firstSampleIndex: firstSampleIndex,
            samples: samples
        )
    }

    func finishWriting() throws {
        guard !isWriterClosed else {
            return
        }
        try writer.synchronize()
        try writer.close()
        isWriterClosed = true
    }

    func discard() throws {
        guard !isDiscarded else {
            return
        }
        var failures: [String] = []
        if !isWriterClosed {
            do {
                try writer.close()
                isWriterClosed = true
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        do {
            try reader.close()
        } catch {
            failures.append(error.localizedDescription)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        isDiscarded = true
        if !failures.isEmpty {
            throw LiveAudioTransportError.operationFailed(
                failures.joined(separator: " ")
            )
        }
    }

    private func readExactly(_ count: Int) throws -> Data? {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            let remaining = count - result.count
            guard let next = try reader.read(upToCount: remaining) else {
                break
            }
            if next.isEmpty {
                break
            }
            result.append(next)
        }
        if result.isEmpty {
            return nil
        }
        guard result.count == count else {
            throw LiveAudioTransportError.malformedSpoolRecord(url)
        }
        return result
    }

    private static func append(
        _ value: UInt32,
        to data: inout Data
    ) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func append(
        _ value: UInt64,
        to data: inout Data
    ) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func decodeUInt32(
        _ data: Data,
        offset: Int
    ) -> UInt32 {
        var result: UInt32 = 0
        for byteOffset in 0..<4 {
            let index = data.index(
                data.startIndex,
                offsetBy: offset + byteOffset
            )
            result |= UInt32(data[index]) << UInt32(byteOffset * 8)
        }
        return result
    }

    private static func decodeUInt64(
        _ data: Data,
        offset: Int
    ) -> UInt64 {
        var result: UInt64 = 0
        for byteOffset in 0..<8 {
            let index = data.index(
                data.startIndex,
                offsetBy: offset + byteOffset
            )
            result |= UInt64(data[index]) << UInt64(byteOffset * 8)
        }
        return result
    }
}
