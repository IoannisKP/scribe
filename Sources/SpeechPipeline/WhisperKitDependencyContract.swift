import WhisperKit

/// Compile-time boundary for Scribe's exact WhisperKit package dependency.
///
/// Model acquisition and inference stay out of this file. Milestone 4 adapters
/// build on this boundary without allowing WhisperKit to choose or download a
/// model implicitly.
public enum WhisperKitDependencyContract {
    public static let exactPackageVersion = "1.0.0"

    public static var backendTypeName: String {
        String(reflecting: WhisperKit.self)
    }
}
