import Foundation

public protocol RecordingFreeSpaceProviding: Sendable {
    func availableCapacity(at url: URL) async throws -> Int64
}

public struct VolumeRecordingFreeSpaceProvider:
    RecordingFreeSpaceProviding,
    Sendable
{
    public init() {}

    public func availableCapacity(at url: URL) async throws -> Int64 {
        let volumeURL = Self.nearestExistingAncestor(of: url)
        let values = try volumeURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let capacity = values.volumeAvailableCapacityForImportantUsage {
            return max(0, capacity)
        }
        if let capacity = values.volumeAvailableCapacity {
            return Int64(max(0, capacity))
        }
        throw AudioCaptureError.recordingDiskSpaceCheckFailed(
            "macOS did not report available capacity for \(volumeURL.path)."
        )
    }

    private static func nearestExistingAncestor(of url: URL) -> URL {
        var candidate = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent != candidate else {
                break
            }
            candidate = parent
        }
        return candidate
    }
}

public struct RecordingDiskSpaceConfiguration: Equatable, Sendable {
    /// Int16 dual-track WAVs plus worst-case raw and speech-window Float32
    /// transient copies: 320,000 bytes per second in total.
    public static let estimatedBytesPerSecond: Int64 = 320_000

    public let expectedDuration: TimeInterval
    public let minimumFreeSpaceReserveBytes: Int64
    public let monitoringInterval: Duration

    public init(
        expectedDuration: TimeInterval = 2 * 60 * 60,
        minimumFreeSpaceReserveBytes: Int64 = 512 * 1_024 * 1_024,
        monitoringInterval: Duration = .seconds(5)
    ) {
        self.expectedDuration = expectedDuration.isFinite
            ? max(0, expectedDuration)
            : 0
        self.minimumFreeSpaceReserveBytes = max(
            0,
            minimumFreeSpaceReserveBytes
        )
        self.monitoringInterval = monitoringInterval > .zero
            ? monitoringInterval
            : .seconds(1)
    }

    public var estimatedRecordingBytes: Int64 {
        let estimate = expectedDuration
            * Double(Self.estimatedBytesPerSecond)
        guard estimate < Double(Int64.max) else {
            return .max
        }
        return Int64(estimate.rounded(.up))
    }

    public var requiredFreeSpaceBeforeRecordingBytes: Int64 {
        let (total, overflow) = estimatedRecordingBytes.addingReportingOverflow(
            minimumFreeSpaceReserveBytes
        )
        return overflow ? .max : total
    }
}
