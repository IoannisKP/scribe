import Darwin
import Foundation
@testable import SpeechPipeline
import WhisperKit
import XCTest

final class WhisperGoldenFileTests: XCTestCase {
    func testEveryInstalledCatalogueModelProducesMeasuredWER() async throws {
        XCTAssertEqual(
            Set(Self.maximumWER.keys),
            Set(WhisperModel.allCases),
            "Every Whisper catalogue model requires a committed WER threshold."
        )
        let environment = ProcessInfo.processInfo.environment
        if environment["SCRIBE_WHISPER_DEBUG"] == "1" {
            Logging.updateLogLevel(.debug)
        }
        let selectedModels: [WhisperModel]
        if let rawValue = environment["SCRIBE_WHISPER_GOLDEN_MODEL"] {
            selectedModels = [
                try XCTUnwrap(
                    WhisperModel(rawValue: rawValue),
                    "Unknown SCRIBE_WHISPER_GOLDEN_MODEL \(rawValue)."
                ),
            ]
        } else {
            selectedModels = WhisperModel.allCases
        }
        let shouldDownload =
            environment["SCRIBE_DOWNLOAD_WHISPER_GOLDENS"] == "1"
        let maximumWEROverride =
            environment["SCRIBE_WHISPER_GOLDEN_MAX_WER"]
                .flatMap(Double.init)
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
        let manager = try WhisperKitModelManager()
        var measuredModels = 0
        var missing: [String] = []

        for model in selectedModels {
            var availability = try await manager.availability(of: model)
            if !availability.isInstalled, shouldDownload {
                _ = try await manager.download(model)
                availability = try await manager.availability(of: model)
            }
            guard availability.isInstalled else {
                let directory = await manager.directory(for: model)
                missing.append("\(model.rawValue) at \(directory.path)")
                continue
            }
            let engine = try WhisperKitTranscriptionEngine(
                model: model,
                modelManager: manager,
                verboseLogging: environment["SCRIBE_WHISPER_DEBUG"] == "1"
            )
            let reader = try CanonicalWAVChunkReader(
                url: wavURL,
                source: .microphone,
                trackStartTime: 0,
                chunkDuration: engine.preferredWindowDuration,
                overlapDuration: engine.preferredOverlap
            )
            try await engine.prepare()
            var segments: [TranscriptSegment] = []
            do {
                while let chunk = try await reader.nextChunk() {
                    segments.append(
                        contentsOf: try await engine.transcribe(chunk)
                    )
                }
                segments.append(contentsOf: await engine.finish())
            } catch {
                await engine.unload()
                throw error
            }
            let peakResidentBytes = Self.peakResidentBytes()
            await engine.unload()
            let actualText = segments.map(\.text).joined(separator: " ")
            let measuredWER = Self.wordErrorRate(
                expected: expectedText,
                actual: actualText
            )
            let maximumWER = try XCTUnwrap(
                maximumWEROverride ?? Self.maximumWER[model],
                "Missing committed WER threshold for \(model.rawValue)."
            )
            let disk = try await manager.diskUsage(of: model)
            print(
                "Whisper golden metrics [\(model.rawValue)]: WER "
                    + String(format: "%.4f", measuredWER)
                    + ", peak RSS \(peakResidentBytes), installed "
                    + "\(disk.logicalBytes), allocated \(disk.allocatedBytes)"
            )
            XCTAssertLessThanOrEqual(
                measuredWER,
                maximumWER,
                "\(model.rawValue) expected ‘\(expectedText)’; received ‘\(actualText)’."
            )
            measuredModels += 1
        }

        if measuredModels == 0 {
            throw XCTSkip(
                "Whisper golden WER skipped; missing "
                    + missing.joined(separator: ", ")
                    + ". Ordinary tests never download models."
            )
        }
        if !missing.isEmpty {
            print(
                "Whisper golden models not installed: "
                    + missing.joined(separator: ", ")
            )
        }
    }

    private static func fixtureURL(
        resource: String,
        extension fileExtension: String
    ) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: resource,
            withExtension: fileExtension
        ) else {
            throw SpeechPipelineTestSupportError.fixtureMissing
        }
        return url
    }

    private static let maximumWER: [WhisperModel: Double] = [
        .tiny: 0.10,
        .tinyEnglish: 0.05,
        .base: 0.08,
        .small: 0.05,
        .medium: 0.05,
        .largeV3: 0.05,
        .largeV3Turbo: 0.05,
        .distilLargeV3: 0.08,
        .largeV3TurboCompressed: 0.05,
        .largeV3TurboOptimizedCompressed: 0.05,
        .largeV3OptimizedCompressed: 0.05,
        .distilLargeV3OptimizedCompressed: 0.08,
    ]

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
                let substitution = previous[actualIndex]
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

    private static func peakResidentBytes() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Int64(usage.ru_maxrss)
    }
}
