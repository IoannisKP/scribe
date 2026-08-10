import AudioCapture
import Foundation
@testable import SpeechPipeline
import XCTest

final class ParakeetGoldenFileTests: XCTestCase {
    func testCommittedSyntheticFixtureWithinWordErrorRateTolerance()
        async throws
    {
        let environment = ProcessInfo.processInfo.environment
        let model = Self.configuredModel(environment: environment)
        let wavURL = try Self.fixtureURL(
            resource: "parakeet-golden",
            extension: "wav"
        )
        let referenceURL = try Self.fixtureURL(
            resource: "parakeet-golden-reference",
            extension: "txt"
        )
        let expectedText = try String(
            contentsOf: referenceURL,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        try await assertGoldenFixture(
            wavURL: wavURL,
            expectedText: expectedText,
            model: model,
            tolerance: Self.tolerance(
                environment: environment,
                defaultValue: 0.20
            ),
            label: "committed synthetic fixture"
        )
    }

    func testDurableInt16CopyWithinWordErrorRateTolerance() async throws {
        let environment = ProcessInfo.processInfo.environment
        let sourceURL = try Self.fixtureURL(
            resource: "parakeet-golden",
            extension: "wav"
        )
        let referenceURL = try Self.fixtureURL(
            resource: "parakeet-golden-reference",
            extension: "txt"
        )
        let expectedText = try String(
            contentsOf: referenceURL,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let reader = try CanonicalWAVChunkReader(
            url: sourceURL,
            source: .microphone,
            trackStartTime: 0,
            chunkDuration: 30
        )
        var samples: [Float] = []
        while let chunk = try await reader.nextChunk() {
            samples.append(contentsOf: chunk.samples)
        }
        let directory = try makeTestDirectory()
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        let durableURL = directory.appendingPathComponent("durable-int16.wav")
        try await writeDurableSessionWAV(samples: samples, to: durableURL)

        try await assertGoldenFixture(
            wavURL: durableURL,
            expectedText: expectedText,
            model: Self.configuredModel(environment: environment),
            tolerance: Self.tolerance(
                environment: environment,
                defaultValue: 0.20
            ),
            label: "durable Int16 copy"
        )
    }

    func testOptionalRecordedFixtureWithinWordErrorRateTolerance()
        async throws
    {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SCRIBE_RUN_PARAKEET_GOLDEN"] == "1" else {
            throw XCTSkip(
                "Optional recorded-audio golden fixture was not requested; set SCRIBE_RUN_PARAKEET_GOLDEN=1 to enable it."
            )
        }
        guard
            let wavPath = environment["SCRIBE_GOLDEN_WAV"],
            let expectedText = environment["SCRIBE_GOLDEN_TEXT"],
            !expectedText.isEmpty
        else {
            XCTFail(
                "SCRIBE_GOLDEN_WAV and SCRIBE_GOLDEN_TEXT are required."
            )
            return
        }

        try await assertGoldenFixture(
            wavURL: URL(fileURLWithPath: wavPath),
            expectedText: expectedText,
            model: Self.configuredModel(environment: environment),
            tolerance: Self.tolerance(
                environment: environment,
                defaultValue: 0.25
            ),
            label: "optional recorded fixture"
        )
    }

    func testGoldenFixtureBatchSeamSweep()
        async throws
    {
        let environment = ProcessInfo.processInfo.environment
        let model = Self.configuredModel(environment: environment)
        let store = try FluidAudioModelManager()
        guard await store.availability(of: model) == .available else {
            let modelDirectory = await store.directory(for: model)
            throw XCTSkip(
                "Batch seam sweep requires \(model.displayName), which is missing from \(modelDirectory.path)."
            )
        }
        let wavURL = try Self.fixtureURL(
            resource: "parakeet-golden",
            extension: "wav"
        )
        let referenceURL = try Self.fixtureURL(
            resource: "parakeet-golden-reference",
            extension: "txt"
        )
        let expectedText = try String(
            contentsOf: referenceURL,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let reader = try CanonicalWAVChunkReader(
            url: wavURL,
            source: .microphone,
            trackStartTime: 0,
            chunkDuration: 30
        )
        var samples: [Float] = []
        while let chunk = try await reader.nextChunk() {
            samples.append(contentsOf: chunk.samples)
        }
        let sampleRate = CanonicalAudioFormat.sampleRate
        let windowDuration: TimeInterval = 14
        let overlapDuration: TimeInterval = 1.5
        let stepDuration = windowDuration - overlapDuration
        let boundaries = stride(
            from: TimeInterval(2),
            through: TimeInterval(18),
            by: 1
        ).map { $0 }
        let timingTolerances: [TimeInterval] = [0.125, 0.250, 0.500]
        let engine = ParakeetTranscriptionEngine(
            model: model,
            modelDirectory: await store.directory(for: model)
        )
        var results: [SeamSweepResult] = []

        try await engine.prepare()
        do {
            for boundary in boundaries {
                var paddingDuration = (windowDuration - boundary)
                    .truncatingRemainder(dividingBy: stepDuration)
                if paddingDuration < 0 {
                    paddingDuration += stepDuration
                }
                let paddingSampleCount = Int(
                    (paddingDuration * sampleRate).rounded()
                )
                let paddedSamples = Array(
                    repeating: Float.zero,
                    count: paddingSampleCount
                ) + samples
                let windowSampleCount = Int(
                    (windowDuration * sampleRate).rounded()
                )
                let stepSampleCount = Int(
                    (stepDuration * sampleRate).rounded()
                )
                var rawSegments: [TranscriptSegment] = []
                var chunkStart = 0
                while chunkStart < paddedSamples.count {
                    let chunkEnd = min(
                        paddedSamples.count,
                        chunkStart + windowSampleCount
                    )
                    let chunk = AudioChunk(
                        samples: Array(
                            paddedSamples[chunkStart..<chunkEnd]
                        ),
                        startTime: Double(chunkStart) / sampleRate,
                        source: .microphone
                    )
                    rawSegments.append(
                        contentsOf: try await engine.transcribe(chunk)
                    )
                    guard chunkEnd < paddedSamples.count else {
                        break
                    }
                    chunkStart += stepSampleCount
                }

                for timingTolerance in timingTolerances {
                    let stitched = TranscriptOverlapDeduplicator.stitch(
                        rawSegments,
                        overlapTimingTolerance: timingTolerance
                    )
                    let actualText = stitched
                        .map(\.text)
                        .joined(separator: " ")
                    results.append(
                        SeamSweepResult(
                            boundary: boundary,
                            timingTolerance: timingTolerance,
                            actualText: actualText,
                            edits: Self.wordErrorMeasurement(
                                expected: expectedText,
                                actual: actualText
                            )
                        )
                    )
                }
            }
            _ = try await engine.finish()
            await engine.unload()
        } catch {
            await engine.unload()
            throw error
        }

        for result in results {
            print(
                String(
                    format:
                        "Parakeet seam sweep boundary=%.0fs tolerance=%.0fms WER=%.4f S=%d I=%d D=%d",
                    result.boundary,
                    result.timingTolerance * 1_000,
                    result.edits.wordErrorRate,
                    result.edits.substitutions,
                    result.edits.insertions,
                    result.edits.deletions
                )
            )
            if !result.edits.insertedTokens.isEmpty {
                print(
                    "Parakeet seam sweep inserted tokens: "
                        + result.edits.insertedTokens.joined(separator: ", ")
                )
            }
        }

        let productionResults = results.filter {
            $0.timingTolerance
                == TranscriptOverlapDeduplicator
                    .defaultOverlapTimingTolerance
        }
        let worstProduction = try XCTUnwrap(
            productionResults.max {
                $0.edits.wordErrorRate < $1.edits.wordErrorRate
            }
        )
        // With span-aware later-window replacement, the measured worst case
        // is 2/51 (0.0392). One additional reference-word error is 3/51
        // (0.0588), rounded to 0.06.
        let measuredDistributionCeiling = 0.06
        print(
            "Parakeet seam sweep worst actual: \(worstProduction.actualText)"
        )
        XCTAssertLessThanOrEqual(
            worstProduction.edits.wordErrorRate,
            measuredDistributionCeiling
        )
        XCTAssertFalse(
            results.contains { $0.edits.deletions > 0 },
            "A forced batch seam dropped reference words."
        )
    }

    func testGoldenFixtureLiveCeilingSeamPreservesBoundaryWord()
        async throws
    {
        let environment = ProcessInfo.processInfo.environment
        let model = Self.configuredModel(environment: environment)
        let store = try FluidAudioModelManager()
        guard await store.availability(of: model) == .available else {
            let modelDirectory = await store.directory(for: model)
            throw XCTSkip(
                "Live ceiling seam regression requires \(model.displayName), which is missing from \(modelDirectory.path)."
            )
        }
        let wavURL = try Self.fixtureURL(
            resource: "parakeet-golden",
            extension: "wav"
        )
        let referenceURL = try Self.fixtureURL(
            resource: "parakeet-golden-reference",
            extension: "txt"
        )
        let expectedText = try String(
            contentsOf: referenceURL,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let reader = try CanonicalWAVChunkReader(
            url: wavURL,
            source: .microphone,
            trackStartTime: 0,
            chunkDuration: 30
        )
        var samples: [Float] = []
        while let chunk = try await reader.nextChunk() {
            samples.append(contentsOf: chunk.samples)
        }

        let configuration = LiveSpeechSegmentationConfiguration(
            minimumSpeechDuration: 0.15,
            minimumSilenceDuration: 0.75,
            speechPadding: 0,
            maximumSpeechDuration: 17,
            windowDuration: 14,
            windowOverlap: 1.5
        )
        var processor = LiveSpeechSourceProcessor(
            source: .microphone,
            trackStartTime: 0,
            configuration: configuration
        )
        let detector = AlwaysSpeechDetector()
        let ingestResult = try await processor.ingest(
            CanonicalAudioBlock(
                source: .microphone,
                firstSampleIndex: 0,
                samples: samples
            ),
            detector: detector
        )
        let finishResult = try await processor.finish(
            detector: detector
        )
        let windows = ingestResult.windows + finishResult.windows
        let continuationWindows = windows.filter {
            $0.speechSegmentIndex == 1
        }
        let continuation = try XCTUnwrap(continuationWindows.first)
        XCTAssertEqual(continuation.firstSampleIndex, 248_000)
        XCTAssertEqual(continuation.overlapSampleCount, 24_000)

        for tolerance in [0.125, 0.250, 0.500] {
            let provider = CeilingWindowProvider(windows: windows)
            let engine = ParakeetTranscriptionEngine(
                model: model,
                modelDirectory: await store.directory(for: model)
            )
            let pipeline = try LiveTranscriptionPipeline(
                windowProvider: provider,
                engine: engine,
                overlapTimingTolerance: tolerance
            )
            try await pipeline.beginSession()
            try await pipeline.waitUntilFinished()

            let rows = await pipeline.rows
            let actualText = rows
                .map(\.segment.text)
                .joined(separator: " ")
            let edits = Self.wordErrorMeasurement(
                expected: expectedText,
                actual: actualText
            )
            print(
                String(
                    format:
                        "Parakeet live ceiling seam tolerance=%.0fms WER=%.4f S=%d I=%d D=%d",
                    tolerance * 1_000,
                    edits.wordErrorRate,
                    edits.substitutions,
                    edits.insertions,
                    edits.deletions
                )
            )
            XCTAssertEqual(
                edits.deletions,
                0,
                "A forced live ceiling seam dropped reference words at \(tolerance * 1_000) ms."
            )
            XCTAssertLessThanOrEqual(edits.wordErrorRate, 0.10)
            XCTAssertGreaterThanOrEqual(rows.count, 2)
            let previousWords = Self.normalizedWords(
                rows[0].segment.text
            )
            let continuationWords = Self.normalizedWords(
                rows[1].segment.text
            )
            XCTAssertNotEqual(
                previousWords.last,
                continuationWords.first,
                "The continuation row begins with the preceding row's final word at \(tolerance * 1_000) ms."
            )
        }
    }

    private func assertGoldenFixture(
        wavURL: URL,
        expectedText: String,
        model: ParakeetModel,
        tolerance: Double,
        label: String
    ) async throws {
        let store = try FluidAudioModelManager()
        guard await store.availability(of: model) == .available else {
            let directory = await store.directory(for: model)
            throw XCTSkip(
                "\(label) requires \(model.displayName), which is missing from \(directory.path). Download that model in Scribe to run this regression."
            )
        }

        let directory = await store.directory(for: model)
        let engine = ParakeetTranscriptionEngine(
            model: model,
            modelDirectory: directory
        )
        let reader = try CanonicalWAVChunkReader(
            url: wavURL,
            source: .microphone,
            trackStartTime: 0,
            chunkDuration: engine.preferredWindowDuration
        )

        try await engine.prepare()
        var segments: [TranscriptSegment] = []
        do {
            while let chunk = try await reader.nextChunk() {
                segments.append(
                    contentsOf: try await engine.transcribe(chunk)
                )
            }
            segments.append(contentsOf: try await engine.finish())
            await engine.unload()
        } catch {
            await engine.unload()
            throw error
        }

        let actualText = segments.map(\.text).joined(separator: " ")
        let measuredWER = Self.wordErrorRate(
            expected: expectedText,
            actual: actualText
        )
        print(
            "Parakeet golden WER [\(model.rawValue), \(label)]: "
                + String(format: "%.4f", measuredWER)
        )
        XCTAssertLessThanOrEqual(
            measuredWER,
            tolerance,
            "Expected “\(expectedText)”; received “\(actualText)”."
        )
    }

    private static func configuredModel(
        environment: [String: String]
    ) -> ParakeetModel {
        environment["SCRIBE_GOLDEN_MODEL"] == "v2"
            ? .v2English : .v3Multilingual
    }

    private static func tolerance(
        environment: [String: String],
        defaultValue: Double
    ) -> Double {
        guard
            let value = environment["SCRIBE_GOLDEN_MAX_WER"],
            let tolerance = Double(value),
            tolerance.isFinite,
            tolerance >= 0
        else {
            return defaultValue
        }
        return tolerance
    }

    private static func fixtureURL(
        resource: String,
        extension fileExtension: String
    ) throws -> URL {
        guard
            let url = Bundle.module.url(
                forResource: resource,
                withExtension: fileExtension
            )
        else {
            throw SpeechPipelineTestSupportError.fixtureMissing
        }
        return url
    }

    private static func wordErrorRate(
        expected: String,
        actual: String
    ) -> Double {
        wordErrorMeasurement(
            expected: expected,
            actual: actual
        ).wordErrorRate
    }

    private static func wordErrorMeasurement(
        expected: String,
        actual: String
    ) -> WordErrorMeasurement {
        let expectedWords = normalizedWords(expected)
        let actualWords = normalizedWords(actual)
        guard !expectedWords.isEmpty else {
            return WordErrorMeasurement(
                substitutions: 0,
                insertions: actualWords.count,
                deletions: 0,
                insertedTokens: actualWords,
                referenceWordCount: 0
            )
        }

        var matrix = Array(
            repeating: Array(
                repeating: WordEditState.zero,
                count: actualWords.count + 1
            ),
            count: expectedWords.count + 1
        )
        for expectedIndex in 1...expectedWords.count {
            matrix[expectedIndex][0] = WordEditState(
                substitutions: 0,
                insertions: 0,
                deletions: expectedIndex,
                insertedTokens: []
            )
        }
        if !actualWords.isEmpty {
            for actualIndex in 1...actualWords.count {
                matrix[0][actualIndex] = WordEditState(
                    substitutions: 0,
                    insertions: actualIndex,
                    deletions: 0,
                    insertedTokens: Array(
                        actualWords.prefix(actualIndex)
                    )
                )
            }
        }
        for expectedWordIndex in expectedWords.indices {
            let expectedIndex = expectedWordIndex + 1
            for actualWordIndex in actualWords.indices {
                let actualIndex = actualWordIndex + 1
                if
                    expectedWords[expectedWordIndex]
                        == actualWords[actualWordIndex]
                {
                    matrix[expectedIndex][actualIndex] =
                        matrix[expectedIndex - 1][actualIndex - 1]
                    continue
                }
                let candidates = [
                    matrix[expectedIndex - 1][actualIndex - 1]
                        .addingSubstitution(),
                    matrix[expectedIndex][actualIndex - 1]
                        .addingInsertion(
                            actualWords[actualWordIndex]
                        ),
                    matrix[expectedIndex - 1][actualIndex]
                        .addingDeletion(),
                ]
                matrix[expectedIndex][actualIndex] =
                    candidates.min(by: WordEditState.precedes) ?? .zero
            }
        }
        let state = matrix[expectedWords.count][actualWords.count]
        return WordErrorMeasurement(
            substitutions: state.substitutions,
            insertions: state.insertions,
            deletions: state.deletions,
            insertedTokens: state.insertedTokens,
            referenceWordCount: expectedWords.count
        )
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

private struct SeamSweepResult {
    let boundary: TimeInterval
    let timingTolerance: TimeInterval
    let actualText: String
    let edits: WordErrorMeasurement
}

private struct WordErrorMeasurement {
    let substitutions: Int
    let insertions: Int
    let deletions: Int
    let insertedTokens: [String]
    let referenceWordCount: Int

    var wordErrorRate: Double {
        guard referenceWordCount > 0 else {
            return insertions == 0 ? 0 : 1
        }
        return Double(substitutions + insertions + deletions)
            / Double(referenceWordCount)
    }
}

private struct WordEditState {
    let substitutions: Int
    let insertions: Int
    let deletions: Int
    let insertedTokens: [String]

    static let zero = WordEditState(
        substitutions: 0,
        insertions: 0,
        deletions: 0,
        insertedTokens: []
    )

    var total: Int {
        substitutions + insertions + deletions
    }

    func addingSubstitution() -> Self {
        Self(
            substitutions: substitutions + 1,
            insertions: insertions,
            deletions: deletions,
            insertedTokens: insertedTokens
        )
    }

    func addingInsertion(_ token: String) -> Self {
        Self(
            substitutions: substitutions,
            insertions: insertions + 1,
            deletions: deletions,
            insertedTokens: insertedTokens + [token]
        )
    }

    func addingDeletion() -> Self {
        Self(
            substitutions: substitutions,
            insertions: insertions,
            deletions: deletions + 1,
            insertedTokens: insertedTokens
        )
    }

    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.total != rhs.total {
            return lhs.total < rhs.total
        }
        // On equally minimal WER alignments, count a deletion only when it
        // cannot be represented as corruption or insertion instead.
        if lhs.deletions != rhs.deletions {
            return lhs.deletions < rhs.deletions
        }
        if lhs.insertions != rhs.insertions {
            return lhs.insertions < rhs.insertions
        }
        return lhs.substitutions < rhs.substitutions
    }
}

private actor AlwaysSpeechDetector: LiveVoiceActivityDetecting {
    func prepare() async throws {}

    func speechProbability(
        for samples: [Float],
        source: AudioSource
    ) async throws -> Float {
        0.95
    }

    func unload() async {}
}

private actor CeilingWindowProvider: LiveSpeechWindowProviding {
    private var windowsBySource: [AudioSource: [LiveSpeechWindow]]

    init(windows: [LiveSpeechWindow]) {
        self.windowsBySource = Dictionary(
            grouping: windows,
            by: \.source
        )
    }

    func nextWindow(
        for source: AudioSource
    ) async throws -> LiveSpeechWindow? {
        guard
            var windows = windowsBySource[source],
            !windows.isEmpty
        else {
            return nil
        }
        let window = windows.removeFirst()
        windowsBySource[source] = windows
        return window
    }

    func pipelineState() async -> LiveSpeechPipelineState {
        let pending = windowsBySource.values.reduce(0) {
            $0 + UInt64($1.count)
        }
        return .completed(pendingWindowCount: pending)
    }
}
