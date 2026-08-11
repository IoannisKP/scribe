import AudioCapture
import Foundation

public enum BatchTranscriptionState: Equatable, Sendable {
    case idle
    case preparing
    case transcribing(processedChunkCount: Int)
    case finished(segmentCount: Int)
    case failed(message: String)

    public var isActive: Bool {
        switch self {
        case .preparing, .transcribing:
            true
        case .idle, .finished, .failed:
            false
        }
    }
}

public actor BatchTranscriptionPipeline {
    public private(set) var state: BatchTranscriptionState = .idle

    private let engine: any TranscriptionEngine
    private let chunkDuration: TimeInterval

    public init(
        engine: any TranscriptionEngine
    ) throws {
        let chunkDuration = engine.preferredWindowDuration
        guard chunkDuration.isFinite, chunkDuration > 0 else {
            throw SpeechPipelineError.invalidChunkDuration(chunkDuration)
        }
        self.engine = engine
        self.chunkDuration = chunkDuration
    }

    public func transcribeSession(
        at sessionDirectory: URL
    ) async throws -> [TranscriptSegment] {
        guard !state.isActive else {
            throw SpeechPipelineError.transcriptionAlreadyRunning
        }

        state = .preparing
        do {
            let manifest = try CaptureSessionManifest.load(
                from: sessionDirectory
            )
            var readers = try makeReaders(
                manifest: manifest,
                sessionDirectory: sessionDirectory
            )

            try await engine.prepare()
            for index in readers.indices {
                readers[index].nextChunk = try await readers[index].reader
                    .nextChunk()
            }
            var segments: [TranscriptSegment] = []
            var processedChunkCount = 0

            while let selectedIndex = Self.selectNextReader(in: readers) {
                guard let selection = readers[selectedIndex].nextChunk else {
                    break
                }

                let produced = try await engine.transcribe(selection)
                try Self.validate(
                    produced,
                    expectedSource: selection.source
                )
                segments.append(contentsOf: produced)
                processedChunkCount += 1
                state = .transcribing(
                    processedChunkCount: processedChunkCount
                )

                readers[selectedIndex].nextChunk = try await readers[
                    selectedIndex
                ].reader.nextChunk()
            }

            let finalSegments = try await engine.finish()
            try Self.validate(finalSegments, expectedSource: nil)
            segments.append(contentsOf: finalSegments)
            let stitched = TranscriptOverlapDeduplicator.stitch(segments)
            let merged = TranscriptTimeline.merge(stitched)
            await engine.unload()
            state = .finished(segmentCount: merged.count)
            return merged
        } catch {
            await engine.unload()
            let message = error.localizedDescription
            state = .failed(message: message)
            if let pipelineError = error as? SpeechPipelineError {
                throw pipelineError
            }
            throw SpeechPipelineError.batchTranscriptionFailed(message)
        }
    }

    private func makeReaders(
        manifest: CaptureSessionManifest,
        sessionDirectory: URL
    ) throws -> [BatchTrackReader] {
        guard !manifest.tracks.isEmpty else {
            throw CaptureSessionManifestError.invalidTrackSet
        }
        return try manifest.tracks.map { track in
            BatchTrackReader(
                source: track.source,
                reader: try CanonicalWAVChunkReader(
                    url: sessionDirectory.appendingPathComponent(
                        track.relativePath,
                        isDirectory: false
                    ),
                    source: track.source,
                    trackStartTime: track.startTime,
                    chunkDuration: chunkDuration,
                    overlapDuration: engine.preferredOverlap
                )
            )
        }
    }

    private static func selectNextReader(
        in readers: [BatchTrackReader]
    ) -> Int? {
        readers.indices
            .filter { readers[$0].nextChunk != nil }
            .min { lhs, rhs in
                guard
                    let left = readers[lhs].nextChunk,
                    let right = readers[rhs].nextChunk
                else {
                    return lhs < rhs
                }
                if left.startTime != right.startTime {
                    return left.startTime < right.startTime
                }
                return TranscriptTimeline.sourceOrder(left.source)
                    < TranscriptTimeline.sourceOrder(right.source)
            }
    }

    private static func validate(
        _ segments: [TranscriptSegment],
        expectedSource: AudioSource?
    ) throws {
        for segment in segments {
            guard
                segment.startTime.isFinite,
                segment.endTime.isFinite,
                segment.startTime >= 0,
                segment.endTime >= segment.startTime
            else {
                throw SpeechPipelineError.invalidSegmentTiming(
                    text: segment.text,
                    startTime: segment.startTime,
                    endTime: segment.endTime
                )
            }
            if
                let expectedSource,
                segment.source != expectedSource
            {
                throw SpeechPipelineError.segmentSourceMismatch(
                    expected: expectedSource,
                    actual: segment.source
                )
            }
            if let words = segment.words {
                for word in words {
                    guard
                        word.startTime.isFinite,
                        word.endTime.isFinite,
                        word.startTime >= 0,
                        word.endTime >= word.startTime
                    else {
                        throw SpeechPipelineError.invalidWordTiming(
                            text: word.text,
                            startTime: word.startTime,
                            endTime: word.endTime
                        )
                    }
                }
            }
        }
    }
}

public enum TranscriptTimeline {
    public static func merge(
        _ segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        segments.sorted(by: precedes)
    }

    static func precedes(
        _ lhs: TranscriptSegment,
        _ rhs: TranscriptSegment
    ) -> Bool {
        if lhs.startTime != rhs.startTime {
            return lhs.startTime < rhs.startTime
        }
        if lhs.source != rhs.source {
            return sourceOrder(lhs.source) < sourceOrder(rhs.source)
        }
        if lhs.endTime != rhs.endTime {
            return lhs.endTime < rhs.endTime
        }
        return lhs.text < rhs.text
    }

    static func sourceOrder(_ source: AudioSource) -> Int {
        switch source {
        case .microphone:
            0
        case .system:
            1
        case .imported:
            2
        }
    }
}

private struct BatchTrackReader {
    let source: AudioSource
    let reader: CanonicalWAVChunkReader
    var nextChunk: AudioChunk?

    init(source: AudioSource, reader: CanonicalWAVChunkReader) {
        self.source = source
        self.reader = reader
        self.nextChunk = nil
    }
}
