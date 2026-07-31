import AudioCapture
import Foundation

/// Removes repeated leading words produced when adjacent ASR windows overlap.
///
/// The operation is source-aware and deterministic. Word timings are preferred
/// when both results provide them; otherwise a conservative whitespace-token
/// fallback is used. Results that do not overlap in time are left unchanged.
public enum TranscriptOverlapDeduplicator {
    public static func deduplicate(
        previous: TranscriptSegment?,
        current: TranscriptSegment
    ) -> TranscriptSegment? {
        guard let previous else {
            return current
        }
        guard
            previous.source == current.source,
            current.startTime <= previous.endTime + 0.25
        else {
            return current
        }

        if
            let previousWords = previous.words,
            !previousWords.isEmpty,
            let currentWords = current.words,
            !currentWords.isEmpty
        {
            let duplicateCount = longestSharedBoundary(
                previousWords.map(\.text),
                currentWords.map(\.text)
            )
            guard duplicateCount > 0 else {
                return current
            }
            let remainingWords = Array(
                currentWords.dropFirst(duplicateCount)
            )
            guard let firstWord = remainingWords.first else {
                return nil
            }
            let text = remainingWords
                .map(\.text)
                .joined(separator: " ")
            return TranscriptSegment(
                text: text,
                startTime: firstWord.startTime,
                endTime: max(
                    firstWord.startTime,
                    remainingWords.last?.endTime
                        ?? current.endTime
                ),
                source: current.source,
                speakerID: current.speakerID,
                confidence: current.confidence,
                words: remainingWords
            )
        }

        let previousTokens = textTokens(previous.text)
        let currentTokens = textTokens(current.text)
        let duplicateCount = longestSharedBoundary(
            previousTokens,
            currentTokens
        )
        guard duplicateCount > 0 else {
            return current
        }
        let remainingTokens = currentTokens.dropFirst(duplicateCount)
        guard !remainingTokens.isEmpty else {
            return nil
        }
        return TranscriptSegment(
            text: remainingTokens.joined(separator: " "),
            startTime: max(current.startTime, previous.endTime),
            endTime: max(previous.endTime, current.endTime),
            source: current.source,
            speakerID: current.speakerID,
            confidence: current.confidence,
            words: nil
        )
    }

    public static func stitch(
        _ segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var latestBySource: [AudioSource: TranscriptSegment] = [:]
        for segment in segments {
            guard
                let deduplicated = deduplicate(
                    previous: latestBySource[segment.source],
                    current: segment
                )
            else {
                continue
            }
            result.append(deduplicated)
            latestBySource[segment.source] = deduplicated
        }
        return result
    }

    private static func longestSharedBoundary(
        _ previous: [String],
        _ current: [String]
    ) -> Int {
        let maximum = min(previous.count, current.count, 64)
        guard maximum > 0 else {
            return 0
        }
        for length in stride(from: maximum, through: 1, by: -1) {
            let previousStart = previous.count - length
            var matches = true
            for offset in 0..<length {
                if
                    normalize(previous[previousStart + offset])
                    != normalize(current[offset])
                {
                    matches = false
                    break
                }
            }
            if matches {
                return length
            }
        }
        return 0
    }

    private static func textTokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func normalize(_ token: String) -> String {
        token
            .lowercased()
            .unicodeScalars
            .filter {
                CharacterSet.alphanumerics.contains($0)
            }
            .map(String.init)
            .joined()
    }
}
