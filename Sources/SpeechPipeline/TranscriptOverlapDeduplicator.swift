import AudioCapture
import Foundation

/// Removes repeated leading words produced when adjacent ASR windows overlap.
///
/// The operation is source-aware and deterministic. When both results provide
/// word timings, the already-emitted time range is authoritative even when ASR
/// renders a split boundary word differently in the two windows. Untimed
/// results use a conservative whitespace-token fallback. Results that do not
/// overlap in time are left unchanged.
public enum TranscriptOverlapDeduplicator {
    static let defaultOverlapTimingTolerance: TimeInterval = 0.25

    /// Reconciles a finalized boundary in favor of the later window, whose
    /// overlap contains the complete audio context. Timed results replace only
    /// the prior row's overlapping tail. Untimed results can replace an exact
    /// or conservatively anchored textual boundary; otherwise the prior row is
    /// left intact rather than risking content loss.
    static func reconcilePreferringCurrent(
        previous: TranscriptSegment,
        current: TranscriptSegment,
        overlapStartTime: TimeInterval? = nil,
        overlapTimingTolerance: TimeInterval =
            defaultOverlapTimingTolerance
    ) -> (previous: TranscriptSegment?, current: TranscriptSegment) {
        guard
            previous.source == current.source,
            current.startTime
                <= previous.endTime + overlapTimingTolerance
        else {
            return (previous, current)
        }

        if
            let previousWords = previous.words,
            !previousWords.isEmpty,
            let currentWords = current.words,
            !currentWords.isEmpty,
            let firstCurrentStart = currentWords
                .map(\.startTime)
                .min()
        {
            let orderedPreviousWords =
                previousWords.orderedByAbsoluteTime
            let orderedCurrentWords =
                currentWords.orderedByAbsoluteTime
            let replacementThreshold =
                overlapStartTime ?? firstCurrentStart
            let timingRetainedCount = orderedPreviousWords.prefix {
                $0.endTime <= replacementThreshold
            }.count
            let matchingFirstCurrentIndex = orderedPreviousWords
                .lastIndex {
                    normalize($0.text)
                        == normalize(orderedCurrentWords[0].text)
                        && $0.endTime
                            >= replacementThreshold
                                - overlapTimingTolerance
                }
            let textReplacementCount = longestSharedBoundary(
                orderedPreviousWords.map(\.text),
                orderedCurrentWords.map(\.text)
            ) ?? longestSharedBoundaryWithMismatchedFinalToken(
                orderedPreviousWords.map(\.text),
                orderedCurrentWords.map(\.text)
            ) ?? 0
            let textRetainedCount =
                orderedPreviousWords.count - textReplacementCount
            let matchingRetainedCount =
                matchingFirstCurrentIndex
                ?? orderedPreviousWords.count
            let retainedWords = Array(
                orderedPreviousWords.prefix(
                    min(
                        timingRetainedCount,
                        min(
                            textRetainedCount,
                            matchingRetainedCount
                        )
                    )
                )
            )
            return (
                segment(
                    replacingWordsIn: previous,
                    with: retainedWords
                ),
                segment(
                    replacingWordsIn: current,
                    with: orderedCurrentWords
                ) ?? current
            )
        }

        let previousTokens = textTokens(previous.text)
        let currentTokens = textTokens(current.text)
        guard
            let replacementCount = longestSharedBoundary(
                previousTokens,
                currentTokens
            ) ?? longestSharedBoundaryWithMismatchedFinalToken(
                previousTokens,
                currentTokens
            )
        else {
            return (previous, current)
        }
        let retainedTokens = previousTokens.dropLast(replacementCount)
        guard !retainedTokens.isEmpty else {
            return (nil, current)
        }
        return (
            TranscriptSegment(
                text: retainedTokens.joined(separator: " "),
                startTime: previous.startTime,
                endTime: min(previous.endTime, current.startTime),
                source: previous.source,
                speakerID: previous.speakerID,
                confidence: previous.confidence,
                words: nil
            ),
            current
        )
    }

    public static func deduplicate(
        previous: TranscriptSegment?,
        current: TranscriptSegment
    ) -> TranscriptSegment? {
        deduplicate(
            previous: previous,
            current: current,
            overlapTimingTolerance: defaultOverlapTimingTolerance
        )
    }

    static func deduplicate(
        previous: TranscriptSegment?,
        current: TranscriptSegment,
        overlapTimingTolerance: TimeInterval
    ) -> TranscriptSegment? {
        guard let previous else {
            return current
        }
        guard
            previous.source == current.source,
            current.startTime
                <= previous.endTime + overlapTimingTolerance
        else {
            return current
        }

        if
            let previousWords = previous.words,
            !previousWords.isEmpty,
            let currentWords = current.words,
            !currentWords.isEmpty
        {
            let orderedPreviousWords =
                previousWords.orderedByAbsoluteTime
            let orderedCurrentWords =
                currentWords.orderedByAbsoluteTime
            let emittedStart = orderedPreviousWords
                .map(\.startTime)
                .min() ?? previous.startTime
            let emittedEnd = orderedPreviousWords
                .map(\.endTime)
                .max() ?? previous.endTime
            let boundaryWord = orderedPreviousWords.max {
                $0.endTime < $1.endTime
            }
            let remainingWords = orderedCurrentWords.filter { word in
                if
                    word.startTime >= emittedStart,
                    word.startTime < emittedEnd
                {
                    return false
                }
                if
                    word.startTime >= emittedEnd,
                    word.startTime
                        <= emittedEnd + overlapTimingTolerance,
                    let boundaryWord,
                    likelySameBoundaryToken(
                        boundaryWord.text,
                        word.text
                    )
                {
                    return false
                }
                return true
            }
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
        guard
            let duplicateCount = longestSharedBoundary(
                previousTokens,
                currentTokens
            ) ?? longestSharedBoundaryWithMismatchedFinalToken(
                previousTokens,
                currentTokens
            )
        else {
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
        stitch(
            segments,
            overlapTimingTolerance: defaultOverlapTimingTolerance
        )
    }

    static func stitch(
        _ segments: [TranscriptSegment],
        overlapTimingTolerance: TimeInterval
    ) -> [TranscriptSegment] {
        // Batch output is not displayed incrementally, so retain the later
        // window's rendering at an overlap seam. Optional slots let a later
        // segment replace the prior source tail without invalidating indices
        // for interleaved microphone and system segments.
        var result: [TranscriptSegment?] = []
        var latestIndexBySource: [AudioSource: Int] = [:]
        for segment in segments {
            if
                let previousIndex = latestIndexBySource[segment.source],
                let previous = result[previousIndex]
            {
                let reconciled = reconcilePreferringCurrent(
                    previous: previous,
                    current: segment,
                    overlapTimingTolerance: overlapTimingTolerance
                )
                result[previousIndex] = reconciled.previous
                result.append(reconciled.current)
            } else {
                result.append(segment)
            }
            latestIndexBySource[segment.source] = result.count - 1
        }
        return result.compactMap { $0 }
    }

    private static func longestSharedBoundary(
        _ previous: [String],
        _ current: [String]
    ) -> Int? {
        let maximum = min(previous.count, current.count, 64)
        guard maximum > 0 else {
            return nil
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
        return nil
    }

    private static func segment(
        replacingWordsIn segment: TranscriptSegment,
        with words: [WordTiming]
    ) -> TranscriptSegment? {
        let orderedWords = words.orderedByAbsoluteTime
        guard
            let first = orderedWords.first,
            let last = orderedWords.last
        else {
            return nil
        }
        return TranscriptSegment(
            text: orderedWords.map(\.text).joined(separator: " "),
            startTime: first.startTime,
            endTime: max(first.startTime, last.endTime),
            source: segment.source,
            speakerID: segment.speakerID,
            confidence: segment.confidence,
            words: orderedWords
        )
    }

    /// Untimed ASR sometimes produces an otherwise identical boundary phrase
    /// whose final, split token differs between windows. Require at least two
    /// exact anchor tokens before tolerating that one final mismatch so an
    /// unrelated single leading word is never discarded.
    private static func longestSharedBoundaryWithMismatchedFinalToken(
        _ previous: [String],
        _ current: [String]
    ) -> Int? {
        let maximum = min(previous.count, current.count, 64)
        guard maximum >= 3 else {
            return nil
        }
        for length in stride(from: maximum, through: 3, by: -1) {
            let previousStart = previous.count - length
            let finalOffset = length - 1
            guard
                normalize(previous[previousStart + finalOffset])
                    != normalize(current[finalOffset])
            else {
                continue
            }
            var anchorsMatch = true
            for offset in 0..<finalOffset {
                if
                    normalize(previous[previousStart + offset])
                    != normalize(current[offset])
                {
                    anchorsMatch = false
                    break
                }
            }
            if anchorsMatch {
                return length
            }
        }
        return nil
    }

    private static func textTokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Timed words use half-open ranges so a genuinely new word may begin at
    /// the preceding end time. Within the bounded seam-timing tolerance, an
    /// exact or strongly prefix-related rendering is the same jittered
    /// boundary word.
    private static func likelySameBoundaryToken(
        _ previous: String,
        _ current: String
    ) -> Bool {
        let normalizedPrevious = normalize(previous)
        let normalizedCurrent = normalize(current)
        guard
            !normalizedPrevious.isEmpty,
            !normalizedCurrent.isEmpty
        else {
            return false
        }
        if normalizedPrevious == normalizedCurrent {
            return true
        }
        let sharedPrefixCount = zip(
            normalizedPrevious,
            normalizedCurrent
        ).prefix { $0.0 == $0.1 }.count
        let shorterCount = min(
            normalizedPrevious.count,
            normalizedCurrent.count
        )
        return sharedPrefixCount >= 4
            && sharedPrefixCount * 2 >= shorterCount
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
