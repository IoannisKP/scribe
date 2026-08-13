import Foundation

public struct SessionNotesEditingState: Equatable, Sendable {
    public private(set) var text: String
    public private(set) var isEditing: Bool

    public init(text: String) {
        self.text = text
        isEditing = !text.isEmpty
    }

    public mutating func beginEditing() {
        isEditing = true
    }

    public mutating func updateText(_ text: String) {
        self.text = text
    }
}

public actor SessionNotesFileWriter {
    private var latestRevisionByURL: [URL: UInt64] = [:]

    public init() {}

    public func write(
        _ text: String,
        to url: URL,
        revision: UInt64
    ) throws {
        let latest = latestRevisionByURL[url] ?? 0
        guard revision >= latest else { return }
        try Data(text.utf8).write(to: url, options: .atomic)
        latestRevisionByURL[url] = revision
    }
}
