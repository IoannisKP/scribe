import AudioCapture
@testable import SpeechPipeline
import XCTest

final class ParakeetGoldenFileTests: XCTestCase {
    func testOptInGoldenWAVWithinWordErrorRateTolerance()
        async throws
    {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SCRIBE_RUN_PARAKEET_GOLDEN"] == "1" else {
            throw XCTSkip(
                "Set SCRIBE_RUN_PARAKEET_GOLDEN=1 to run local Core ML acceptance."
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

        let model: ParakeetModel =
            environment["SCRIBE_GOLDEN_MODEL"] == "v2"
            ? .v2English : .v3Multilingual
        let store = try ParakeetModelStore()
        guard await store.availability(of: model) == .available else {
            throw XCTSkip(
                "\(model.displayName) is not present in Scribe's model directory."
            )
        }

        let directory = await store.directory(for: model)
        let engine = ParakeetTranscriptionEngine(
            model: model,
            modelDirectory: directory
        )
        let reader = try CanonicalWAVChunkReader(
            url: URL(fileURLWithPath: wavPath),
            source: .microphone,
            trackStartTime: 0
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
        let tolerance = Double(
            environment["SCRIBE_GOLDEN_MAX_WER"] ?? "0.25"
        ) ?? 0.25
        XCTAssertLessThanOrEqual(
            Self.wordErrorRate(
                expected: expectedText,
                actual: actualText
            ),
            tolerance,
            "Expected “\(expectedText)”; received “\(actualText)”."
        )
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
