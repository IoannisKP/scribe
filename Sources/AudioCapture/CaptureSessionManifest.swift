import Foundation

public struct CaptureSessionManifest: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let fileName = "capture-session.json"

    public struct Track: Codable, Equatable, Sendable {
        public let source: AudioSource
        public let relativePath: String
        public let startTime: TimeInterval

        public init(
            source: AudioSource,
            relativePath: String,
            startTime: TimeInterval
        ) {
            self.source = source
            self.relativePath = relativePath
            self.startTime = startTime
        }
    }

    public let version: Int
    public let sampleRate: Double
    public let channelCount: UInt32
    public let tracks: [Track]

    public init(
        version: Int = Self.currentVersion,
        sampleRate: Double = CanonicalAudioFormat.sampleRate,
        channelCount: UInt32 = CanonicalAudioFormat.channelCount,
        tracks: [Track]
    ) {
        self.version = version
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.tracks = tracks
    }

    public static func dualTrack(
        microphoneStartTime: TimeInterval,
        systemStartTime: TimeInterval
    ) -> CaptureSessionManifest {
        CaptureSessionManifest(
            tracks: [
                Track(
                    source: .microphone,
                    relativePath: "microphone.wav",
                    startTime: microphoneStartTime
                ),
                Track(
                    source: .system,
                    relativePath: "system.wav",
                    startTime: systemStartTime
                )
            ]
        )
    }

    public func track(for source: AudioSource) -> Track? {
        tracks.first { $0.source == source }
    }

    public func validate() throws {
        guard version == Self.currentVersion else {
            throw CaptureSessionManifestError.unsupportedVersion(version)
        }
        guard
            sampleRate == CanonicalAudioFormat.sampleRate,
            channelCount == CanonicalAudioFormat.channelCount
        else {
            throw CaptureSessionManifestError.unsupportedFormat(
                sampleRate: sampleRate,
                channelCount: channelCount
            )
        }

        let sources = Set(tracks.map(\.source))
        guard
            tracks.count == AudioSource.allCases.count,
            sources.count == AudioSource.allCases.count,
            AudioSource.allCases.allSatisfy(sources.contains)
        else {
            throw CaptureSessionManifestError.invalidTrackSet
        }

        for track in tracks {
            guard
                track.startTime.isFinite,
                track.startTime >= 0
            else {
                throw CaptureSessionManifestError.invalidStartTime(
                    source: track.source,
                    startTime: track.startTime
                )
            }
            let pathComponents = NSString(
                string: track.relativePath
            ).pathComponents
            guard
                !track.relativePath.hasPrefix("/"),
                !pathComponents.contains(".."),
                !track.relativePath.isEmpty
            else {
                throw CaptureSessionManifestError.invalidRelativePath(
                    track.relativePath
                )
            }
        }
    }

    public func write(to sessionDirectory: URL) throws {
        try validate()
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let outputURL = sessionDirectory.appendingPathComponent(
            Self.fileName,
            isDirectory: false
        )
        try data.write(to: outputURL, options: .atomic)
    }

    public static func load(
        from sessionDirectory: URL
    ) throws -> CaptureSessionManifest {
        let inputURL = sessionDirectory.appendingPathComponent(
            Self.fileName,
            isDirectory: false
        )
        let data = try Data(contentsOf: inputURL)
        let manifest = try JSONDecoder().decode(
            CaptureSessionManifest.self,
            from: data
        )
        try manifest.validate()
        return manifest
    }
}

public enum CaptureSessionManifestError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case unsupportedVersion(Int)
    case unsupportedFormat(sampleRate: Double, channelCount: UInt32)
    case invalidTrackSet
    case invalidStartTime(source: AudioSource, startTime: TimeInterval)
    case invalidRelativePath(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            "Capture-session metadata version \(version) is not supported."
        case let .unsupportedFormat(sampleRate, channelCount):
            "Capture-session metadata describes unsupported audio: \(sampleRate) Hz, \(channelCount) channels."
        case .invalidTrackSet:
            "Capture-session metadata must contain exactly one microphone track and one system track."
        case let .invalidStartTime(source, startTime):
            "The \(source.rawValue) track has an invalid start time: \(startTime)."
        case let .invalidRelativePath(path):
            "Capture-session metadata contains an unsafe relative path: \(path)."
        }
    }
}
