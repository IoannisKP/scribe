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
            let readers = try makeReaders(
                manifest: manifest,
                sessionDirectory: sessionDirectory
            )

            try await engine.prepare()
            var microphoneChunk = try await readers.microphone.nextChunk()
            var systemChunk = try await readers.system.nextChunk()
            var segments: [TranscriptSegment] = []
            var processedChunkCount = 0

            while microphoneChunk != nil || systemChunk != nil {
                let selection = Self.selectNext(
                    microphone: microphoneChunk,
                    system: systemChunk
                )
                guard let selection else {
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

                switch selection.source {
                case .microphone:
                    microphoneChunk =
                        try await readers.microphone.nextChunk()
                case .system:
                    systemChunk = try await readers.system.nextChunk()
                }
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
    ) throws -> (
        microphone: CanonicalWAVChunkReader,
        system: CanonicalWAVChunkReader
    ) {
        guard
            let microphoneTrack = manifest.track(for: .microphone),
            let systemTrack = manifest.track(for: .system)
        else {
            throw CaptureSessionManifestError.invalidTrackSet
        }

        let microphoneReader = try CanonicalWAVChunkReader(
            url: sessionDirectory.appendingPathComponent(
                microphoneTrack.relativePath,
                isDirectory: false
            ),
            source: .microphone,
            trackStartTime: microphoneTrack.startTime,
            chunkDuration: chunkDuration,
            overlapDuration: engine.preferredOverlap
        )
        let systemReader = try CanonicalWAVChunkReader(
            url: sessionDirectory.appendingPathComponent(
                systemTrack.relativePath,
                isDirectory: false
            ),
            source: .system,
            trackStartTime: systemTrack.startTime,
            chunkDuration: chunkDuration,
            overlapDuration: engine.preferredOverlap
        )
        return (microphoneReader, systemReader)
    }

    private static func selectNext(
        microphone: AudioChunk?,
        system: AudioChunk?
    ) -> AudioChunk? {
        switch (microphone, system) {
        case let (.some(microphone), .some(system)):
            if microphone.startTime <= system.startTime {
                return microphone
            }
            return system
        case let (.some(microphone), .none):
            return microphone
        case let (.none, .some(system)):
            return system
        case (.none, .none):
            return nil
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
        segments.sorted { lhs, rhs in
            if lhs.startTime != rhs.startTime {
                return lhs.startTime < rhs.startTime
            }
            if lhs.endTime != rhs.endTime {
                return lhs.endTime < rhs.endTime
            }
            if lhs.source != rhs.source {
                return sourceOrder(lhs.source) < sourceOrder(rhs.source)
            }
            return lhs.text < rhs.text
        }
    }

    private static func sourceOrder(_ source: AudioSource) -> Int {
        switch source {
        case .microphone:
            0
        case .system:
            1
        }
    }
}
