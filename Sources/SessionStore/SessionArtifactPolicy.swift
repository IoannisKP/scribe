import AudioCapture
import Foundation

public enum SessionArtifactPolicy {
    private static let surfacedExtensions: Set<String> = [
        "pdf", "txt", "md", "rtf", "rtfd", "doc", "docx", "pages",
        "key", "keynote", "ppt", "pptx", "xls", "xlsx", "csv", "tsv",
        "jpg", "jpeg", "png", "heic", "gif", "tif", "tiff", "webp",
        "svg", "wav", "m4a", "mp3", "aac", "flac", "caf", "aif",
        "aiff", "mp4", "mov", "m4v", "mkv", "avi"
    ]

    private static let ignoredNames: Set<String> = [
        ".DS_Store", "Thumbs.db", "desktop.ini", CaptureSessionManifest.fileName,
        CaptureSessionManifest.legacyFileName
    ]

    public static func shouldSurfaceAdditionalFile(
        _ url: URL,
        resourceValues: URLResourceValues
    ) -> Bool {
        let name = url.lastPathComponent
        guard
            resourceValues.isRegularFile == true,
            resourceValues.isSymbolicLink != true,
            resourceValues.isAliasFile != true,
            resourceValues.isHidden != true,
            !ignoredNames.contains(name),
            !name.hasPrefix("."),
            !name.hasPrefix("~"),
            !name.hasPrefix("._"),
            !name.hasSuffix("~")
        else { return false }

        let ext = url.pathExtension.lowercased()
        guard surfacedExtensions.contains(ext) else { return false }
        let lower = name.lowercased()
        return !lower.hasSuffix(".tmp")
            && !lower.hasSuffix(".temp")
            && !lower.hasSuffix(".swp")
            && !lower.hasSuffix(".swo")
            && !lower.hasSuffix(".part")
            && !lower.hasSuffix(".download")
    }
}
