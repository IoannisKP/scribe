import AudioCapture
import Foundation
import SpeechPipeline

/// Whether cloud titling is permitted. Off by default: generating a title from
/// a transcript means processing that transcript, and sending it to a cloud
/// provider silently would break the promise the application is built on.
public struct SessionTitlingSettings: Codable, Equatable, Sendable {
    public var allowsCloudTitling: Bool

    public init(allowsCloudTitling: Bool = false) {
        self.allowsCloudTitling = allowsCloudTitling
    }
}

/// What a titling attempt did, so callers can report honestly instead of
/// guessing.
public enum SessionTitlingOutcome: Equatable, Sendable {
    /// A title was produced and applied.
    case titled(DerivedSessionTitle)

    /// Nothing usable was found, so the date-and-time title stands.
    case keptExistingTitle

    /// The stored title is the user's, or already came from a better source.
    case preservedProtectedTitle

    /// A title was produced and stored, but the folder could not be renamed.
    /// Reported rather than left to diverge silently.
    case titledButFolderNotRenamed(
        DerivedSessionTitle,
        reason: String
    )
}

/// Content a session offers a titler, gathered by the caller so this type
/// never touches the file system and stays testable.
public struct SessionTitlingInput: Equatable, Sendable {
    public let summaryMarkdown: String?
    public let transcript: [TranscriptSegment]
    public let currentTitleSource: SessionTitleSource

    public init(
        summaryMarkdown: String?,
        transcript: [TranscriptSegment],
        currentTitleSource: SessionTitleSource
    ) {
        self.summaryMarkdown = summaryMarkdown
        self.transcript = transcript
        self.currentTitleSource = currentTitleSource
    }
}

/// Chooses a session title from the cheapest and most private source that can
/// produce an acceptable one.
///
/// Order: an existing summary, then a provider running on this Mac, then
/// keyword extraction that needs no model at all, and only then an opted-in
/// cloud provider. Cloud is last deliberately, so the network is reached for
/// only when nothing local could name the session.
public struct SessionTitlingPolicy: Sendable {
    /// Asks a local provider for a title. Nil when none is configured.
    public typealias Completion = @Sendable (String) async throws -> String

    private let localCompletion: Completion?
    private let cloudCompletion: Completion?
    private let settings: SessionTitlingSettings

    public init(
        settings: SessionTitlingSettings = SessionTitlingSettings(),
        localCompletion: Completion? = nil,
        cloudCompletion: Completion? = nil
    ) {
        self.settings = settings
        self.localCompletion = localCompletion
        self.cloudCompletion = cloudCompletion
    }

    /// Whether any transcript text would leave this Mac for the given input.
    ///
    /// Exposed so the decision can be asserted directly by tests rather than
    /// inferred from whether a stub was called.
    public func wouldUseCloud(for input: SessionTitlingInput) -> Bool {
        settings.allowsCloudTitling && cloudCompletion != nil
    }

    public func derivedTitle(
        for input: SessionTitlingInput
    ) async -> DerivedSessionTitle? {
        guard input.currentTitleSource.isReplaceableByGeneration else {
            return nil
        }

        if
            let summaryMarkdown = input.summaryMarkdown,
            let fromSummary = SessionTitleDerivation.fromSummary(
                summaryMarkdown
            )
        {
            return fromSummary
        }

        let excerpt = SessionTitleDerivation.transcriptExcerpt(
            input.transcript
        )

        if let localCompletion, !excerpt.isEmpty {
            let prompt = SessionTitleDerivation.titlePrompt(
                forTranscriptExcerpt: excerpt
            )
            if
                let reply = try? await localCompletion(prompt),
                let title = SessionTitleDerivation.fromModelReply(
                    reply,
                    source: .localModel
                )
            {
                return title
            }
        }

        if let fromKeywords = SessionTitleDerivation.fromTranscript(
            input.transcript
        ) {
            return fromKeywords
        }

        // Only now, and only with explicit opt-in, does any text leave.
        guard
            settings.allowsCloudTitling,
            let cloudCompletion,
            !excerpt.isEmpty
        else {
            return nil
        }
        let prompt = SessionTitleDerivation.titlePrompt(
            forTranscriptExcerpt: excerpt
        )
        guard let reply = try? await cloudCompletion(prompt) else {
            return nil
        }
        return SessionTitleDerivation.fromModelReply(
            reply,
            source: .cloudModel
        )
    }
}

/// Applies a derived title to a session: stores it through the manifest store,
/// then renames the folder to match.
///
/// Session folders are named from the title, so this renames a directory the
/// user may have open in Finder, may have moved, or may have referenced
/// elsewhere. When the rename fails the title is kept and the folder is left
/// alone, and the mismatch is reported rather than allowed to diverge quietly.
public struct SessionTitleApplier: Sendable {
    public typealias RenameFolder = @Sendable (URL, String) async throws -> URL

    private let renameFolder: RenameFolder

    public init(renameFolder: @escaping RenameFolder) {
        self.renameFolder = renameFolder
    }

    public func apply(
        _ derived: DerivedSessionTitle,
        to sessionDirectory: URL
    ) async throws -> SessionTitlingOutcome {
        let stored = try await CaptureSessionManifestStore.shared
            .applyGeneratedTitle(
                derived.title,
                source: derived.source,
                in: sessionDirectory
            )
        guard stored != nil else {
            return .preservedProtectedTitle
        }

        do {
            _ = try await renameFolder(sessionDirectory, derived.title)
            return .titled(derived)
        } catch {
            // The title is already saved and correct. Losing it because the
            // directory could not be moved would be the worse outcome.
            return .titledButFolderNotRenamed(
                derived,
                reason: error.localizedDescription
            )
        }
    }
}
