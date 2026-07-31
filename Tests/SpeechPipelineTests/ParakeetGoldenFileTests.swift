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

    func testGoldenFixtureKeepsSpeechAcrossMidWordBatchSeam()
        async throws
    {
        let environment = ProcessInfo.processInfo.environment
        let model = Self.configuredModel(environment: environment)
        let store = try ParakeetModelStore()
        guard await store.availability(of: model) == .available else {
            let modelDirectory = await store.directory(for: model)
            throw XCTSkip(
                "Mid-word seam regression requires \(model.displayName), which is missing from \(modelDirectory.path)."
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
        let modelDirectory = await store.directory(for: model)
        let baselineEngine = ParakeetTranscriptionEngine(
            model: model,
            modelDirectory: modelDirectory
        )
        let baselineReader = try CanonicalWAVChunkReader(
            url: wavURL,
            source: .microphone,
            trackStartTime: 0,
            chunkDuration: 30
        )
        try await baselineEngine.prepare()
        var baselineSegments: [TranscriptSegment] = []
        while let chunk = try await baselineReader.nextChunk() {
            baselineSegments.append(
                contentsOf: try await baselineEngine.transcribe(chunk)
            )
        }
        await baselineEngine.unload()
        let baselineWords = baselineSegments.flatMap { $0.words ?? [] }
        let middleWord = try XCTUnwrap(
            baselineWords.min {
                abs(($0.startTime + $0.endTime) / 2 - 9.5)
                    < abs(($1.startTime + $1.endTime) / 2 - 9.5)
            }
        )
        let boundary = (middleWord.startTime + middleWord.endTime) / 2
        XCTAssertGreaterThan(boundary, middleWord.startTime)
        XCTAssertLessThan(boundary, middleWord.endTime)

        let directory = try makeTestDirectory()
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.copyItem(
            at: wavURL,
            to: directory.appendingPathComponent("microphone.wav")
        )
        try await writeCanonicalWAV(
            samples: [0],
            to: directory.appendingPathComponent("system.wav")
        )
        try CaptureSessionManifest.dualTrack(
            microphoneStartTime: 0,
            systemStartTime: 0
        ).write(to: directory)
        let seamEngine = WindowGeometryOverrideEngine(
            wrapped: ParakeetTranscriptionEngine(
                model: model,
                modelDirectory: modelDirectory
            ),
            preferredWindowDuration: boundary,
            preferredOverlap: 1.5
        )
        let pipeline = try BatchTranscriptionPipeline(engine: seamEngine)
        let segments = try await pipeline.transcribeSession(at: directory)
        let actualText = segments.map(\.text).joined(separator: " ")
        let baselineText = baselineSegments.map(\.text).joined(separator: " ")
        let measuredWER = Self.wordErrorRate(
            expected: expectedText,
            actual: actualText
        )
        print(
            "Parakeet golden mid-word seam [\(middleWord.text), "
                + String(format: "%.3f", boundary)
                + "s]: WER " + String(format: "%.4f", measuredWER)
        )
        XCTAssertLessThanOrEqual(measuredWER, 0.20)
        XCTAssertGreaterThanOrEqual(
            Self.normalizedWords(actualText).count,
            Self.normalizedWords(baselineText).count,
            "The overlapped batch path lost words relative to one-window inference."
        )
    }

    private func assertGoldenFixture(
        wavURL: URL,
        expectedText: String,
        model: ParakeetModel,
        tolerance: Double,
        label: String
    ) async throws {
        let store = try ParakeetModelStore()
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
        let expectedWords = normalizedWords(expected)
        let actualWords = normalizedWords(actual)
        guard !expectedWords.isEmpty else {
            return actualWords.isEmpty ? 0 : 1
        }

        var previous = Array(0...actualWords.count)
        for (expectedIndex, expectedWord) in expectedWords.enumerated() {
            var current = Array(repeating: 0, count: actualWords.count + 1)
            current[0] = expectedIndex + 1
            for (actualIndex, actualWord) in actualWords.enumerated() {
                let substitution =
                    previous[actualIndex]
                    + (expectedWord == actualWord ? 0 : 1)
                let insertion = current[actualIndex] + 1
                let deletion = previous[actualIndex + 1] + 1
                current[actualIndex + 1] = min(
                    substitution,
                    min(insertion, deletion)
                )
            }
            previous = current
        }
        return Double(previous[actualWords.count])
            / Double(expectedWords.count)
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

private actor WindowGeometryOverrideEngine: TranscriptionEngine {
    nonisolated let identifier: String
    nonisolated let supportsStreaming: Bool
    nonisolated let requiresNetwork: Bool
    nonisolated let supportedLanguages: [String]
    nonisolated let preferredWindowDuration: TimeInterval
    nonisolated let preferredOverlap: TimeInterval
    private let wrapped: any TranscriptionEngine

    init(
        wrapped: any TranscriptionEngine,
        preferredWindowDuration: TimeInterval,
        preferredOverlap: TimeInterval
    ) {
        self.wrapped = wrapped
        self.identifier = wrapped.identifier + ".geometry-override"
        self.supportsStreaming = wrapped.supportsStreaming
        self.requiresNetwork = wrapped.requiresNetwork
        self.supportedLanguages = wrapped.supportedLanguages
        self.preferredWindowDuration = preferredWindowDuration
        self.preferredOverlap = preferredOverlap
    }

    func prepare() async throws {
        try await wrapped.prepare()
    }

    func transcribe(_ chunk: AudioChunk) async throws
        -> [TranscriptSegment]
    {
        try await wrapped.transcribe(chunk)
    }

    func finish() async throws -> [TranscriptSegment] {
        try await wrapped.finish()
    }

    func unload() async {
        await wrapped.unload()
    }
}
