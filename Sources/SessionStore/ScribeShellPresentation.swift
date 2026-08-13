import Foundation

public struct ScribeShellPreferences: @unchecked Sendable {
    public static let sidebarVisibleKey = "Scribe.shell.sidebarVisible"
    public static let selectionKey = "Scribe.shell.selection"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var sidebarVisible: Bool {
        get {
            defaults.object(forKey: Self.sidebarVisibleKey) == nil
                || defaults.bool(forKey: Self.sidebarVisibleKey)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.sidebarVisibleKey)
        }
    }

    public var selectionID: String {
        get {
            defaults.string(forKey: Self.selectionKey) ?? "smart.all"
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.selectionKey)
        }
    }
}

public enum ScribeFeatureAvailability {
    public static let summaryGeneration = true
}

public enum ScribeShellPresentation {
    public static func primaryControlShowsRecording(
        captureIsStarting: Bool,
        captureIsRecording: Bool,
        captureIsStopping: Bool
    ) -> Bool {
        captureIsStarting || captureIsRecording || captureIsStopping
    }

    public static func shouldShowRecordingPane(
        selectedRecording: Bool,
        captureIsActive: Bool
    ) -> Bool {
        selectedRecording && captureIsActive
    }

    public static func resolvedSelectionID(
        _ selectionID: String,
        summaryFeatureAvailable: Bool
    ) -> String {
        if selectionID == "smart.needsSummary",
            !summaryFeatureAvailable
        {
            return "smart.all"
        }
        return selectionID
    }
}
