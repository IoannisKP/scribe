import AudioCapture
import Foundation
import ModelManager
@testable import SpeechPipeline
import XCTest

final class RealModelSwitchingTests: XCTestCase {
    func testSameFixtureSwitchesFromParakeetThroughThreeWhisperSizes()
        async throws
    {
        let selections: [TranscriptionModelSelection] = [
            .parakeet(.v3Multilingual),
            .whisper(.tiny),
            .whisper(.small),
            .whisper(.medium),
        ]
        let fluidManager = try FluidAudioModelManager()
        let whisperManager = try WhisperKitModelManager()
        var missing: [String] = []
        for selection in selections {
            switch selection {
            case let .parakeet(model):
                if await fluidManager.availability(of: model) != .available {
                    missing.append(selection.descriptor.displayName)
                }
            case let .whisper(model):
                let availability = try await whisperManager.availability(
                    of: model
                )
                if !availability.isInstalled {
                    missing.append(selection.descriptor.displayName)
                }
            }
        }
        guard missing.isEmpty else {
            throw XCTSkip(
                "Real model switching requires installed "
                    + missing.joined(separator: ", ")
                    + "; ordinary tests never download models."
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
        let firstChunk = try await reader.nextChunk()
        let chunk = try XCTUnwrap(firstChunk)
        let trailingChunk = try await reader.nextChunk()
        XCTAssertNil(trailingChunk)

        let coordinator = ResidentTranscriptionEngineCoordinator()
        var lastEngine: CoordinatedTranscriptionEngine?
        var measured: [ModelIdentifier: Double] = [:]
        for selection in selections {
            let rawEngine: any TranscriptionEngine
            switch selection {
            case let .parakeet(model):
                rawEngine = ParakeetTranscriptionEngine(
                    model: model,
                    modelDirectory: await fluidManager.directory(for: model)
                )
            case let .whisper(model):
                rawEngine = try WhisperKitTranscriptionEngine(
                    model: model,
                    modelManager: whisperManager
                )
            }
            let engine = CoordinatedTranscriptionEngine(
                engine: rawEngine,
                coordinator: coordinator
            )
            try await engine.prepare()
            var segments = try await engine.transcribe(chunk)
            segments.append(contentsOf: try await engine.finish())
            let actualText = segments.map(\.text).joined(separator: " ")
            let wer = Self.wordErrorRate(
                expected: expectedText,
                actual: actualText
            )
            measured[selection.id] = wer
            print(
                "Real model switch [\(selection.descriptor.displayName)]: WER "
                    + String(format: "%.4f", wer)
            )
            XCTAssertFalse(
                actualText.isEmpty,
                "\(selection.descriptor.displayName) returned no text."
            )
            XCTAssertLessThanOrEqual(
                wer,
                Self.maximumWER(for: selection),
                "\(selection.descriptor.displayName) received ‘\(actualText)’"
            )
            let residentState = await coordinator.state
            XCTAssertEqual(
                residentState,
                .resident(identifier: selection.id.rawValue)
            )
            lastEngine = engine
        }

        XCTAssertEqual(Set(measured.keys), Set(selections.map(\.id)))
        await lastEngine?.unload()
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    private static func maximumWER(
        for selection: TranscriptionModelSelection
    ) -> Double {
        switch selection {
        case .parakeet:
            0.20
        case .whisper(.tiny):
            0.10
        case .whisper(.small), .whisper(.medium):
            0.05
        case .whisper:
            0.10
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
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
