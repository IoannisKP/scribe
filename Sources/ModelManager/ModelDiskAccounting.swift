import Foundation

public struct ModelDiskUsage: Equatable, Sendable {
    public let isInstalled: Bool
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let regularFileCount: Int

    public init(
        isInstalled: Bool,
        logicalBytes: Int64,
        allocatedBytes: Int64,
        regularFileCount: Int
    ) {
        self.isInstalled = isInstalled
        self.logicalBytes = max(0, logicalBytes)
        self.allocatedBytes = max(0, allocatedBytes)
        self.regularFileCount = max(0, regularFileCount)
    }
}

public enum ModelDiskAccountingError:
    Error,
    LocalizedError,
    Sendable
{
    case unableToEnumerate(URL)

    public var errorDescription: String? {
        switch self {
        case let .unableToEnumerate(url):
            "Scribe could not enumerate model files under \(url.path)."
        }
    }
}

public actor ModelDiskAccounting {
    public init() {}

    public func usage(
        of descriptor: ModelDescriptor,
        in paths: ModelStoragePaths
    ) throws -> ModelDiskUsage {
        let directory = paths.installationDirectory(for: descriptor)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return ModelDiskUsage(
                isInstalled: false,
                logicalBytes: 0,
                allocatedBytes: 0,
                regularFileCount: 0
            )
        }
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw ModelDiskAccountingError.unableToEnumerate(directory)
        }
        var logicalBytes: Int64 = 0
        var allocatedBytes: Int64 = 0
        var fileCount = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true,
                values.isRegularFile == true
            else {
                continue
            }
            logicalBytes = Self.saturatingAdd(
                logicalBytes,
                Int64(values.fileSize ?? 0)
            )
            let allocated = values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize
                ?? 0
            allocatedBytes = Self.saturatingAdd(
                allocatedBytes,
                Int64(allocated)
            )
            fileCount += 1
        }
        return ModelDiskUsage(
            isInstalled: true,
            logicalBytes: logicalBytes,
            allocatedBytes: allocatedBytes,
            regularFileCount: fileCount
        )
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }
}
