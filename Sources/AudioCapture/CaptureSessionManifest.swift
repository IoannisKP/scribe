import Foundation

public struct CaptureSessionManifest: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public static let fileName = "session.json"
    public static let legacyFileName = "capture-session.json"

    public enum SessionSource: String, Codable, Sendable {
        case liveCapture
        case importedFile
    }

    public enum TimingPrecision: String, Codable, Sendable {
        case sampleAccurate
        case legacyEstimated
        case unavailable
    }

    public struct Track: Codable, Equatable, Sendable {
        public let source: AudioSource
        public let relativePath: String
        public let startSampleOffset: Int64?
        public let timingPrecision: TimingPrecision

        public var startTime: TimeInterval {
            Double(startSampleOffset ?? 0) / CanonicalAudioFormat.sampleRate
        }

        public init(
            source: AudioSource,
            relativePath: String,
            startSampleOffset: Int64?,
            timingPrecision: TimingPrecision
        ) {
            self.source = source
            self.relativePath = relativePath
            self.startSampleOffset = startSampleOffset
            self.timingPrecision = timingPrecision
        }

        /// Compatibility initializer for callers and version-1 manifests.
        public init(
            source: AudioSource,
            relativePath: String,
            startTime: TimeInterval
        ) {
            self.init(
                source: source,
                relativePath: relativePath,
                startSampleOffset: Int64(
                    (startTime * CanonicalAudioFormat.sampleRate).rounded()
                ),
                timingPrecision: .legacyEstimated
            )
        }

        private enum CodingKeys: String, CodingKey {
            case source
            case relativePath
            case startSampleOffset
            case timingPrecision
            case startTime
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            source = try container.decode(AudioSource.self, forKey: .source)
            relativePath = try container.decode(
                String.self,
                forKey: .relativePath
            )
            if container.contains(.startSampleOffset)
                || container.contains(.timingPrecision)
            {
                startSampleOffset = try container.decodeIfPresent(
                    Int64.self,
                    forKey: .startSampleOffset
                )
                timingPrecision = try container.decodeIfPresent(
                    TimingPrecision.self,
                    forKey: .timingPrecision
                ) ?? (startSampleOffset == nil ? .unavailable : .sampleAccurate)
            } else {
                let legacyTime = try container.decode(
                    TimeInterval.self,
                    forKey: .startTime
                )
                startSampleOffset = Int64(
                    (legacyTime * CanonicalAudioFormat.sampleRate).rounded()
                )
                timingPrecision = .legacyEstimated
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(source, forKey: .source)
            try container.encode(relativePath, forKey: .relativePath)
            try container.encodeIfPresent(
                startSampleOffset,
                forKey: .startSampleOffset
            )
            try container.encode(timingPrecision, forKey: .timingPrecision)
        }
    }

    public enum ArtifactKind: String, Codable, Sendable {
        case audio
        case transcriptMarkdown
        case transcriptJSON
        case subtitles
        case notes
        case summary
        case originalImport
        case additional
    }

    public struct Artifact: Codable, Equatable, Sendable {
        public let relativePath: String
        public let kind: ArtifactKind

        public init(relativePath: String, kind: ArtifactKind) {
            self.relativePath = relativePath
            self.kind = kind
        }
    }

    public struct TranscriptionRevision: Codable, Equatable, Sendable {
        public let id: UUID
        public let modelIdentifier: String
        public let createdAt: Date
        public let artifacts: [String]

        public init(
            id: UUID = UUID(),
            modelIdentifier: String,
            createdAt: Date = Date(),
            artifacts: [String]
        ) {
            self.id = id
            self.modelIdentifier = modelIdentifier
            self.createdAt = createdAt
            self.artifacts = artifacts
        }
    }

    public let version: Int
    public let sessionID: UUID
    public let title: String
    public let createdAt: Date
    public let source: SessionSource
    public let sampleRate: Double
    public let channelCount: UInt32
    public let tracks: [Track]
    public let artifacts: [Artifact]
    public let transcriptionHistory: [TranscriptionRevision]
    public let originalFilename: String?
    public let originalFormat: String?
    public let systemAudioStartupStageTimings:
        [SystemAudioStartupStageTiming]?
    public let systemAudioGraphPreparation: SystemAudioGraphPreparation?

    public init(
        version: Int = Self.currentVersion,
        sessionID: UUID = UUID(),
        title: String = "Untitled Session",
        createdAt: Date = Date(),
        source: SessionSource = .liveCapture,
        sampleRate: Double = CanonicalAudioFormat.sampleRate,
        channelCount: UInt32 = CanonicalAudioFormat.channelCount,
        tracks: [Track],
        artifacts: [Artifact] = [],
        transcriptionHistory: [TranscriptionRevision] = [],
        originalFilename: String? = nil,
        originalFormat: String? = nil,
        systemAudioStartupStageTimings:
            [SystemAudioStartupStageTiming]? = nil,
        systemAudioGraphPreparation: SystemAudioGraphPreparation? = nil
    ) {
        self.version = version
        self.sessionID = sessionID
        self.title = title
        self.createdAt = createdAt
        self.source = source
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.tracks = tracks
        self.artifacts = artifacts
        self.transcriptionHistory = transcriptionHistory
        self.originalFilename = originalFilename
        self.originalFormat = originalFormat
        self.systemAudioStartupStageTimings = systemAudioStartupStageTimings
        self.systemAudioGraphPreparation = systemAudioGraphPreparation
    }

    public static func dualTrack(
        microphoneStartTime: TimeInterval,
        systemStartTime: TimeInterval
    ) -> CaptureSessionManifest {
        CaptureSessionManifest(
            createdAt: Date(
                timeIntervalSince1970: floor(Date().timeIntervalSince1970)
            ),
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
            ],
            artifacts: [
                Artifact(relativePath: "microphone.wav", kind: .audio),
                Artifact(relativePath: "system.wav", kind: .audio)
            ]
        )
    }

    public static func pendingDualTrack(
        sessionID: UUID,
        title: String,
        createdAt: Date
    ) -> CaptureSessionManifest {
        CaptureSessionManifest(
            sessionID: sessionID,
            title: title,
            createdAt: createdAt,
            tracks: [
                Track(
                    source: .microphone,
                    relativePath: "microphone.wav",
                    startSampleOffset: nil,
                    timingPrecision: .unavailable
                ),
                Track(
                    source: .system,
                    relativePath: "system.wav",
                    startSampleOffset: nil,
                    timingPrecision: .unavailable
                )
            ],
            artifacts: [
                Artifact(relativePath: "microphone.wav", kind: .audio),
                Artifact(relativePath: "system.wav", kind: .audio)
            ]
        )
    }

    public static func importedFile(
        sessionID: UUID = UUID(),
        title: String,
        createdAt: Date,
        originalFilename: String,
        originalFormat: String,
        originalRelativePath: String
    ) -> CaptureSessionManifest {
        CaptureSessionManifest(
            sessionID: sessionID,
            title: title,
            createdAt: Date(
                timeIntervalSince1970: floor(createdAt.timeIntervalSince1970)
            ),
            source: .importedFile,
            tracks: [
                Track(
                    source: .imported,
                    relativePath: "audio.wav",
                    startSampleOffset: 0,
                    timingPrecision: .sampleAccurate
                )
            ],
            artifacts: [
                Artifact(
                    relativePath: originalRelativePath,
                    kind: .originalImport
                ),
                Artifact(relativePath: "audio.wav", kind: .audio)
            ],
            originalFilename: originalFilename,
            originalFormat: originalFormat
        )
    }

    public func track(for source: AudioSource) -> Track? {
        tracks.first { $0.source == source }
    }

    public func replacingTrackOffsets(
        microphone: Int64?,
        system: Int64?
    ) -> CaptureSessionManifest {
        let replacements: [AudioSource: Int64?] = [
            .microphone: microphone,
            .system: system
        ]
        return replacing(
            tracks: tracks.map { track in
                guard track.source != .imported else { return track }
                let offset = replacements[track.source] ?? nil
                return Track(
                    source: track.source,
                    relativePath: track.relativePath,
                    startSampleOffset: offset,
                    timingPrecision: offset == nil
                        ? .unavailable
                        : .sampleAccurate
                )
            }
        )
    }

    public func replacingSystemAudioStartupStageTimings(
        _ timings: [SystemAudioStartupStageTiming]
    ) -> CaptureSessionManifest {
        replacing(systemAudioStartupStageTimings: timings)
    }

    public func replacingSystemAudioGraphPreparation(
        _ preparation: SystemAudioGraphPreparation
    ) -> CaptureSessionManifest {
        replacing(systemAudioGraphPreparation: preparation)
    }

    public func replacing(
        sessionID: UUID? = nil,
        tracks: [Track]? = nil,
        artifacts: [Artifact]? = nil,
        transcriptionHistory: [TranscriptionRevision]? = nil,
        systemAudioStartupStageTimings:
            [SystemAudioStartupStageTiming]? = nil,
        systemAudioGraphPreparation: SystemAudioGraphPreparation? = nil
    ) -> CaptureSessionManifest {
        CaptureSessionManifest(
            version: Self.currentVersion,
            sessionID: sessionID ?? self.sessionID,
            title: title,
            createdAt: createdAt,
            source: source,
            sampleRate: sampleRate,
            channelCount: channelCount,
            tracks: tracks ?? self.tracks,
            artifacts: artifacts ?? self.artifacts,
            transcriptionHistory:
                transcriptionHistory ?? self.transcriptionHistory,
            originalFilename: originalFilename,
            originalFormat: originalFormat,
            systemAudioStartupStageTimings:
                systemAudioStartupStageTimings
                ?? self.systemAudioStartupStageTimings,
            systemAudioGraphPreparation:
                systemAudioGraphPreparation
                ?? self.systemAudioGraphPreparation
        )
    }

    public func validate() throws {
        guard version == 1 || version == Self.currentVersion else {
            throw CaptureSessionManifestError.unsupportedVersion(version)
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CaptureSessionManifestError.invalidTitle
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
        let expectedSources: Set<AudioSource>
        switch source {
        case .liveCapture:
            expectedSources = Set(AudioSource.liveCaptureSources)
        case .importedFile:
            expectedSources = [.imported]
        }
        guard tracks.count == expectedSources.count,
            sources == expectedSources
        else {
            throw CaptureSessionManifestError.invalidTrackSet
        }

        for track in tracks {
            if let offset = track.startSampleOffset, offset < 0 {
                throw CaptureSessionManifestError.invalidStartTime(
                    source: track.source,
                    startTime: track.startTime
                )
            }
            try Self.validate(relativePath: track.relativePath)
        }
        for artifact in artifacts {
            try Self.validate(relativePath: artifact.relativePath)
        }
        for revision in transcriptionHistory {
            for path in revision.artifacts {
                try Self.validate(relativePath: path)
            }
        }
    }

    private static func validate(relativePath: String) throws {
        let pathComponents = NSString(string: relativePath).pathComponents
        guard
            !relativePath.hasPrefix("/"),
            !pathComponents.contains(".."),
            !relativePath.isEmpty
        else {
            throw CaptureSessionManifestError.invalidRelativePath(relativePath)
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
        encoder.dateEncodingStrategy = .iso8601
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
        let currentURL = sessionDirectory.appendingPathComponent(
            Self.fileName,
            isDirectory: false
        )
        let legacyURL = sessionDirectory.appendingPathComponent(
            Self.legacyFileName,
            isDirectory: false
        )
        let inputURL = FileManager.default.fileExists(atPath: currentURL.path)
            ? currentURL
            : legacyURL
        let data = try Data(contentsOf: inputURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(CaptureSessionManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case sessionID
        case title
        case createdAt
        case source
        case sampleRate
        case channelCount
        case tracks
        case artifacts
        case transcriptionHistory
        case originalFilename
        case originalFormat
        case systemAudioStartupStageTimings
        case systemAudioGraphPreparation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
            ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title)
            ?? "Recovered Session"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
            ?? Date(timeIntervalSince1970: 0)
        source = try container.decodeIfPresent(SessionSource.self, forKey: .source)
            ?? .liveCapture
        sampleRate = try container.decode(Double.self, forKey: .sampleRate)
        channelCount = try container.decode(UInt32.self, forKey: .channelCount)
        tracks = try container.decode([Track].self, forKey: .tracks)
        artifacts = try container.decodeIfPresent(
            [Artifact].self,
            forKey: .artifacts
        ) ?? tracks.map { Artifact(relativePath: $0.relativePath, kind: .audio) }
        transcriptionHistory = try container.decodeIfPresent(
            [TranscriptionRevision].self,
            forKey: .transcriptionHistory
        ) ?? []
        originalFilename = try container.decodeIfPresent(
            String.self,
            forKey: .originalFilename
        )
        originalFormat = try container.decodeIfPresent(
            String.self,
            forKey: .originalFormat
        )
        systemAudioStartupStageTimings = try container.decodeIfPresent(
            [SystemAudioStartupStageTiming].self,
            forKey: .systemAudioStartupStageTimings
        )
        systemAudioGraphPreparation = try container.decodeIfPresent(
            SystemAudioGraphPreparation.self,
            forKey: .systemAudioGraphPreparation
        )
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
    case invalidTitle
    case invalidStartTime(source: AudioSource, startTime: TimeInterval)
    case invalidRelativePath(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            "Session metadata version \(version) is not supported."
        case let .unsupportedFormat(sampleRate, channelCount):
            "Session metadata describes unsupported audio: \(sampleRate) Hz, \(channelCount) channels."
        case .invalidTrackSet:
            "Live sessions need microphone and system tracks; imported sessions need one imported-audio track."
        case .invalidTitle:
            "Session metadata must contain a title."
        case let .invalidStartTime(source, startTime):
            "The \(source.rawValue) track has an invalid start time: \(startTime)."
        case let .invalidRelativePath(path):
            "Session metadata contains an unsafe relative path: \(path)."
        }
    }
}
