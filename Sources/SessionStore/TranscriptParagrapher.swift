import AudioCapture
import Foundation
import SpeechPipeline

public struct TranscriptParagraphingConfiguration: Equatable, Sendable {
    public var sentencePauseThreshold: TimeInterval
    public var maximumDuration: TimeInterval

    public static let `default` = TranscriptParagraphingConfiguration()

    public init(
        sentencePauseThreshold: TimeInterval = 0.4,
        maximumDuration: TimeInterval = 45
    ) {
        self.sentencePauseThreshold = sentencePauseThreshold
        self.maximumDuration = maximumDuration
    }
}

public struct TranscriptParagraph: Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let source: AudioSource
    public let speakerID: String?
    public let words: [WordTiming]?

    public init(
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        source: AudioSource,
        speakerID: String?,
        words: [WordTiming]?
    ) {
        self.id = [
            source.rawValue,
            speakerID ?? "unassigned",
            String(startTime.bitPattern)
        ].joined(separator: ":")
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.source = source
        self.speakerID = speakerID
        self.words = words
    }
}

public enum TranscriptParagrapher {
    public static func paragraphs(
        from segments: [TranscriptSegment],
        configuration: TranscriptParagraphingConfiguration = .default
    ) -> [TranscriptParagraph] {
        precondition(configuration.sentencePauseThreshold >= 0)
        precondition(configuration.maximumDuration > 0)

        let ordered = TranscriptTimeline.merge(segments)
        var paragraphs: [TranscriptParagraph] = []
        var timedRun: TimedRun?

        func flushTimedRun() {
            guard let run = timedRun else { return }
            paragraphs.append(
                contentsOf: makeParagraphs(
                    words: run.words,
                    source: run.source,
                    speakerID: run.speakerID,
                    configuration: configuration
                )
            )
            timedRun = nil
        }

        for segment in ordered {
            guard let words = usableWords(for: segment) else {
                flushTimedRun()
                paragraphs.append(
                    TranscriptParagraph(
                        text: segment.text,
                        startTime: segment.startTime,
                        endTime: segment.endTime,
                        source: segment.source,
                        speakerID: segment.speakerID,
                        words: nil
                    )
                )
                continue
            }

            let sameSpeaker = timedRun?.source == segment.source
                && timedRun?.speakerID == segment.speakerID
            if !sameSpeaker {
                flushTimedRun()
                timedRun = TimedRun(
                    source: segment.source,
                    speakerID: segment.speakerID,
                    words: words
                )
            } else {
                timedRun?.words.append(contentsOf: words)
            }
        }
        flushTimedRun()
        return paragraphs
    }

    private static func makeParagraphs(
        words: [WordTiming],
        source: AudioSource,
        speakerID: String?,
        configuration: TranscriptParagraphingConfiguration
    ) -> [TranscriptParagraph] {
        let words = ordered(words)
        guard !words.isEmpty else { return [] }
        var result: [TranscriptParagraph] = []
        var paragraphStart = 0

        while paragraphStart < words.count {
            var breakAfter: Int?
            var sentenceEndings: [Int] = []
            var largestGapAfter: Int?
            var largestGap = -TimeInterval.infinity

            if paragraphStart < words.count - 1 {
                for index in paragraphStart..<(words.count - 1) {
                    let current = words[index]
                    let next = words[index + 1]
                    let gap = max(0, next.startTime - current.endTime)
                    if gap >= largestGap {
                        largestGap = gap
                        largestGapAfter = index
                    }
                    if isSentenceEnding(current.text) {
                        sentenceEndings.append(index)
                        if gap > configuration.sentencePauseThreshold {
                            breakAfter = index
                            break
                        }
                    }
                    if next.endTime - words[paragraphStart].startTime
                        > configuration.maximumDuration
                    {
                        breakAfter = sentenceEndings.last
                            ?? largestGapAfter
                            ?? index
                        break
                    }
                }
            }

            let paragraphEnd = breakAfter ?? words.index(before: words.endIndex)
            let paragraphWords = Array(words[paragraphStart...paragraphEnd])
            result.append(
                TranscriptParagraph(
                    text: joinedText(paragraphWords),
                    startTime: paragraphWords[0].startTime,
                    endTime: paragraphWords[paragraphWords.count - 1].endTime,
                    source: source,
                    speakerID: speakerID,
                    words: paragraphWords
                )
            )
            paragraphStart = paragraphEnd + 1
        }
        return result
    }

    private static func usableWords(
        for segment: TranscriptSegment
    ) -> [WordTiming]? {
        guard let words = segment.words, !words.isEmpty else { return nil }
        let orderedWords = ordered(words)
        guard
            orderedWords.allSatisfy({ word in
                !word.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                    && word.startTime.isFinite
                    && word.endTime.isFinite
                    && word.endTime >= word.startTime
            }),
            normalized(joinedText(orderedWords)) == normalized(segment.text)
        else {
            return nil
        }
        return orderedWords
    }

    private static func ordered(_ words: [WordTiming]) -> [WordTiming] {
        words.enumerated().sorted { lhs, rhs in
            if lhs.element.startTime != rhs.element.startTime {
                return lhs.element.startTime < rhs.element.startTime
            }
            if lhs.element.endTime != rhs.element.endTime {
                return lhs.element.endTime < rhs.element.endTime
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func joinedText(_ words: [WordTiming]) -> String {
        var result = ""
        for word in words {
            let token = word.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !token.isEmpty else { continue }
            if result.isEmpty
                || beginsWithClosingPunctuation(token)
                || endsWithOpeningPunctuation(result)
            {
                result += token
            } else {
                result += " " + token
            }
        }
        return result
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private static func isSentenceEnding(_ text: String) -> Bool {
        var characters = Array(
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let trailingClosers = CharacterSet(
            charactersIn: "\"'’”)]}»"
        )
        while let last = characters.last,
            String(last).rangeOfCharacter(from: trailingClosers) != nil
        {
            characters.removeLast()
        }
        guard let last = characters.last else { return false }
        return ".?!…。！？".contains(last)
    }

    private static func beginsWithClosingPunctuation(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return ".,!?;:%…)]}»。！？、".contains(first)
    }

    private static func endsWithOpeningPunctuation(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "([{«“".contains(last)
    }
}

private struct TimedRun {
    let source: AudioSource
    let speakerID: String?
    var words: [WordTiming]
}
