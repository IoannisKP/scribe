import AudioCapture
import Foundation
import SpeechPipeline

public struct DerivedSessionTitle: Equatable, Sendable {
    public let title: String
    public let source: SessionTitleSource

    public init(title: String, source: SessionTitleSource) {
        self.title = title
        self.source = source
    }
}

/// Builds a short descriptive session title from content that is already on
/// this Mac.
///
/// Nothing here performs any network work. A bad title is worse than no title,
/// so every entry point returns nil rather than guessing, and the caller keeps
/// the existing date-and-time title when it does.
public enum SessionTitleDerivation {
    /// Words a title is never built from: function words plus the spoken
    /// filler that dominates raw transcripts. Without this, frequency
    /// extraction reliably produces titles like "yeah think actually".
    static let stopwords: Set<String> = [
        "a", "about", "actually", "after", "again", "against", "all", "also",
        "am", "an", "and", "another", "any", "anyway", "are", "as", "at",
        "back", "basically", "be", "because", "been", "before", "being",
        "between", "both", "but", "by", "can", "cannot", "come", "could",
        "definitely", "did", "do", "does", "doing", "done", "down", "each",
        "either", "else", "even", "ever", "every", "exactly", "for", "from",
        "get", "gets", "getting", "give", "go", "going", "gonna", "good",
        "got", "great", "guess", "had", "has", "have", "having", "he", "hello",
        "her", "here", "hey", "him", "his", "how", "however", "if", "in",
        "into", "is", "it", "its", "just", "kind", "know", "let", "like",
        "literally", "little", "look", "lot", "make", "many", "maybe", "me",
        "mean", "might", "mine", "more", "most", "much", "must", "my",
        "need", "never", "new", "next", "no", "nope", "not", "now", "obviously",
        "of", "off", "okay", "on", "once", "one", "only", "or", "other",
        "our", "out", "over", "own", "people", "perhaps", "probably", "put",
        "quite", "really", "right", "said", "same", "say", "see", "seen",
        "she", "should", "so", "some", "something", "sorry", "sort", "still",
        "stuff", "such", "sure", "take", "talk", "than", "that", "the",
        "their", "them", "then", "there", "these", "they", "thing", "things",
        "think", "this", "those", "though", "thought", "through", "time",
        "to", "today", "too", "totally", "try", "under", "up", "us", "use",
        "very", "want", "was", "way", "we", "well", "were", "what", "when",
        "where", "which", "while", "who", "why", "will", "with", "would",
        "yeah", "yes", "yep", "yet", "you", "your", "hmm", "uh", "um", "er",
        "ah", "oh", "mhm", "gotcha", "alright"
    ]

    /// Transcript before this point is skipped, so greetings and audio checks
    /// do not decide the title.
    public static let openingSecondsIgnored: TimeInterval = 20

    /// A word must appear in at least this many distinct segments, or this
    /// many times overall, to count as being about something.
    static let minimumSegmentSpread = 2
    static let minimumTotalOccurrences = 3

    /// Below two qualifying words there is nothing worth naming a session
    /// after.
    static let minimumWordsForTitle = 2
    static let maximumWordsForTitle = 3

    // MARK: - From a summary

    /// Derives a title from an existing summary.
    ///
    /// Preferred whenever a summary exists: it was already generated and
    /// already consented to, so it costs nothing extra and reads best.
    public static func fromSummary(_ markdown: String) -> DerivedSessionTitle? {
        let lines = markdown
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let heading = lines.first { $0.hasPrefix("#") }
        let candidate = heading ?? lines.first { !$0.isEmpty }
        guard let candidate else {
            return nil
        }

        let stripped = candidate
            .drop(while: { $0 == "#" })
            .trimmingCharacters(in: .whitespaces)
        guard let title = normalize(stripped, maximumWords: 6) else {
            return nil
        }
        return DerivedSessionTitle(title: title, source: .summary)
    }

    // MARK: - From a model's reply

    /// Cleans a model's reply into a usable title, or returns nil if the reply
    /// cannot be made into one.
    public static func fromModelReply(
        _ reply: String,
        source: SessionTitleSource
    ) -> DerivedSessionTitle? {
        let firstLine = reply
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard
            let firstLine,
            let title = normalize(firstLine, maximumWords: 6)
        else {
            return nil
        }
        return DerivedSessionTitle(title: title, source: source)
    }

    /// The prompt used for both local and cloud titling. Deliberately tiny:
    /// only the opening of the transcript is ever sent.
    public static func titlePrompt(
        forTranscriptExcerpt excerpt: String
    ) -> String {
        """
        Give a title of three to six words for this meeting transcript. \
        Reply with the title only: no punctuation, no quotes, no explanation.

        \(excerpt)
        """
    }

    /// The opening of a transcript, capped by time and characters so a long
    /// session never turns into a long prompt.
    public static func transcriptExcerpt(
        _ segments: [TranscriptSegment],
        maximumDuration: TimeInterval = 180,
        maximumCharacters: Int = 4_000
    ) -> String {
        var excerpt = ""
        for segment in segments.sorted(by: { $0.startTime < $1.startTime }) {
            guard segment.startTime <= maximumDuration else { break }
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if excerpt.count + text.count + 1 > maximumCharacters { break }
            excerpt += excerpt.isEmpty ? text : " " + text
        }
        return excerpt
    }

    // MARK: - From the transcript, with no model

    /// Extracts a title from the transcript using frequency alone.
    ///
    /// The fallback that must always work: no provider, no key, no network.
    /// Returns nil when the transcript does not support a meaningful title, so
    /// the caller can keep the date-and-time name.
    public static func fromTranscript(
        _ segments: [TranscriptSegment]
    ) -> DerivedSessionTitle? {
        let considered = segments
            .filter { $0.endTime > openingSecondsIgnored }
            .sorted(by: { $0.startTime < $1.startTime })
        guard !considered.isEmpty else {
            return nil
        }

        var totalOccurrences: [String: Int] = [:]
        var segmentSpread: [String: Int] = [:]
        var firstAppearance: [String: Int] = [:]

        for (index, segment) in considered.enumerated() {
            var seenInSegment: Set<String> = []
            for word in contentWords(in: segment.text) {
                totalOccurrences[word, default: 0] += 1
                if firstAppearance[word] == nil {
                    firstAppearance[word] = index
                }
                seenInSegment.insert(word)
            }
            for word in seenInSegment {
                segmentSpread[word, default: 0] += 1
            }
        }

        // A word earns its place by recurring across the conversation, not by
        // being repeated once inside a single sentence.
        let qualifying = totalOccurrences.keys.filter { word in
            let spread = segmentSpread[word] ?? 0
            let total = totalOccurrences[word] ?? 0
            return spread >= minimumSegmentSpread
                || total >= minimumTotalOccurrences
        }
        guard qualifying.count >= minimumWordsForTitle else {
            return nil
        }

        let ranked = qualifying.sorted { left, right in
            let leftSpread = segmentSpread[left] ?? 0
            let rightSpread = segmentSpread[right] ?? 0
            if leftSpread != rightSpread {
                return leftSpread > rightSpread
            }
            let leftTotal = totalOccurrences[left] ?? 0
            let rightTotal = totalOccurrences[right] ?? 0
            if leftTotal != rightTotal {
                return leftTotal > rightTotal
            }
            return left < right
        }

        let chosen = ranked.prefix(maximumWordsForTitle)
        guard chosen.count >= minimumWordsForTitle else {
            return nil
        }

        // Reading order beats frequency order: "pricing page rebuild" rather
        // than whichever word happened to recur most.
        let ordered = chosen.sorted {
            (firstAppearance[$0] ?? 0) < (firstAppearance[$1] ?? 0)
        }
        guard let title = normalize(
            ordered.joined(separator: " "),
            maximumWords: maximumWordsForTitle
        ) else {
            return nil
        }
        return DerivedSessionTitle(title: title, source: .keywords)
    }

    static func contentWords(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { word in
                word.count >= 3 && !stopwords.contains(word)
            }
    }

    // MARK: - Shared cleaning

    /// Trims a candidate to a usable title, or nil when nothing usable is
    /// left. Also removes the characters that cannot appear in a folder name.
    static func normalize(
        _ raw: String,
        maximumWords: Int
    ) -> String? {
        let unquoted = raw.trimmingCharacters(
            in: CharacterSet(charactersIn: "\"'“”‘’ \t")
        )
        let words = unquoted
            .components(separatedBy: .whitespacesAndNewlines)
            .map { word in
                word.trimmingCharacters(
                    in: CharacterSet.punctuationCharacters
                        .union(.symbols)
                        .subtracting(CharacterSet(charactersIn: "-"))
                )
            }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else {
            return nil
        }
        let clipped = words.prefix(maximumWords).joined(separator: " ")
        let safe = clipped
            .components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else {
            return nil
        }
        return safe.prefix(1).uppercased() + safe.dropFirst()
    }
}
