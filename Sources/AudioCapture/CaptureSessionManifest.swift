import Foundation

public struct CaptureSessionManifest: Codable, Equatable, Sendable {
    public static let currentVersion = 6
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

    public struct SummaryRevision: Codable, Equatable, Sendable {
        public let id: UUID
        public let providerIdentifier: String
        public let providerDisplayName: String
        public let modelIdentifier: String
        public let templateIdentifier: String
        public let templateName: String
        public let createdAt: Date
        public let artifacts: [String]

        public init(
            id: UUID = UUID(),
            providerIdentifier: String,
            providerDisplayName: String,
            modelIdentifier: String,
            templateIdentifier: String,
            templateName: String,
            createdAt: Date = Date(),
            artifacts: [String]
        ) {
            self.id = id
            self.providerIdentifier = providerIdentifier
            self.providerDisplayName = providerDisplayName
            self.modelIdentifier = modelIdentifier
            self.templateIdentifier = templateIdentifier
            self.templateName = templateName
            self.createdAt = createdAt
            self.artifacts = artifacts
        }
    }

    public struct Pin: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public let sampleOffset: Int64
        public let label: String?
        public let createdAt: Date

        public init(
            id: UUID = UUID(),
            sampleOffset: Int64,
            label: String? = nil,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.sampleOffset = sampleOffset
            self.label = Self.cleanLabel(label)
            self.createdAt = createdAt
        }

        public func labeling(_ label: String?) -> Pin {
            Pin(
                id: id,
                sampleOffset: sampleOffset,
                label: label,
                createdAt: createdAt
            )
        }

        private static func cleanLabel(_ label: String?) -> String? {
            let clean = label?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return clean?.isEmpty == false ? clean : nil
        }
    }

    public enum SpeakerNameAssignment: String, Codable, Sendable {
        case machineAssigned
        case userAssigned
    }

    public struct SpeakerIdentity: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let displayName: String?
        public let source: AudioSource
        public let nameAssignment: SpeakerNameAssignment?

        public init(
            id: String,
            displayName: String? = nil,
            source: AudioSource,
            nameAssignment: SpeakerNameAssignment? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.source = source
            self.nameAssignment = nameAssignment
        }

        public func renaming(
            to displayName: String?,
            assignment: SpeakerNameAssignment
        ) -> SpeakerIdentity {
            let cleanName = displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = cleanName?.isEmpty == false ? cleanName : nil
            return SpeakerIdentity(
                id: id,
                displayName: resolvedName,
                source: source,
                nameAssignment: resolvedName == nil ? nil : assignment
            )
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
    public let speakerIdentities: [SpeakerIdentity]
    public let artifacts: [Artifact]
    public let transcriptionHistory: [TranscriptionRevision]
    public let summaryHistory: [SummaryRevision]
    public let pins: [Pin]
    public let originalFilename: String?
    public let originalFormat: String?
    public let systemAudioStartupStageTimings:
        [SystemAudioStartupStageTiming]?
    public let systemAudioGraphPreparation: SystemAudioGraphPreparation?
    public let microphoneInputDevice: MicrophoneInputDeviceIdentity?

    public init(
        version: Int = Self.currentVersion,
        sessionID: UUID = UUID(),
        title: String = "Untitled Session",
        createdAt: Date = Date(),
        source: SessionSource = .liveCapture,
        sampleRate: Double = CanonicalAudioFormat.sampleRate,
        channelCount: UInt32 = CanonicalAudioFormat.channelCount,
        tracks: [Track],
        speakerIdentities: [SpeakerIdentity]? = nil,
        artifacts: [Artifact] = [],
        transcriptionHistory: [TranscriptionRevision] = [],
        summaryHistory: [SummaryRevision] = [],
        pins: [Pin] = [],
        originalFilename: String? = nil,
        originalFormat: String? = nil,
        systemAudioStartupStageTimings:
            [SystemAudioStartupStageTiming]? = nil,
        systemAudioGraphPreparation: SystemAudioGraphPreparation? = nil,
        microphoneInputDevice: MicrophoneInputDeviceIdentity? = nil
    ) {
        self.version = version
        self.sessionID = sessionID
        self.title = title
        self.createdAt = createdAt
        self.source = source
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.tracks = tracks
        self.speakerIdentities = speakerIdentities
            ?? Self.defaultSpeakerIdentities(for: tracks)
        self.artifacts = artifacts
        self.transcriptionHistory = transcriptionHistory
        self.summaryHistory = summaryHistory
        self.pins = pins
        self.originalFilename = originalFilename
        self.originalFormat = originalFormat
        self.systemAudioStartupStageTimings = systemAudioStartupStageTimings
        self.systemAudioGraphPreparation = systemAudioGraphPreparation
        self.microphoneInputDevice = microphoneInputDevice
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

    public func speakerIdentity(
        identifiedBy id: String
    ) -> SpeakerIdentity? {
        speakerIdentities.first { $0.id == id }
    }

    public func speakerIdentities(
        for source: AudioSource
    ) -> [SpeakerIdentity] {
        speakerIdentities.filter { $0.source == source }
    }

    public func soleSpeakerIdentity(
        for source: AudioSource
    ) -> SpeakerIdentity? {
        let matches = speakerIdentities(for: source)
        return matches.count == 1 ? matches[0] : nil
    }

    public func renamingSpeaker(
        identifiedBy id: String,
        to displayName: String?,
        assignment: SpeakerNameAssignment = .userAssigned
    ) throws -> CaptureSessionManifest {
        guard let index = speakerIdentities.firstIndex(where: { $0.id == id })
        else {
            throw CaptureSessionManifestError.speakerNotFound(id)
        }
        var updated = speakerIdentities
        updated[index] = updated[index].renaming(
            to: displayName,
            assignment: assignment
        )
        let manifest = replacing(speakerIdentities: updated)
        try manifest.validate()
        return manifest
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

    public func replacingMicrophoneInputDevice(
        _ identity: MicrophoneInputDeviceIdentity
    ) -> CaptureSessionManifest {
        replacing(microphoneInputDevice: identity)
    }

    public func appendingPin(_ pin: Pin) throws -> CaptureSessionManifest {
        var updated = pins.filter { $0.id != pin.id }
        updated.append(pin)
        updated.sort {
            if $0.sampleOffset != $1.sampleOffset {
                return $0.sampleOffset < $1.sampleOffset
            }
            return $0.createdAt < $1.createdAt
        }
        let manifest = replacing(pins: updated)
        try manifest.validate()
        return manifest
    }

    public func labelingPin(
        identifiedBy id: UUID,
        label: String?
    ) throws -> CaptureSessionManifest {
        guard let index = pins.firstIndex(where: { $0.id == id }) else {
            throw CaptureSessionManifestError.pinNotFound(id)
        }
        var updated = pins
        updated[index] = updated[index].labeling(label)
        let manifest = replacing(pins: updated)
        try manifest.validate()
        return manifest
    }

    public func replacing(
        sessionID: UUID? = nil,
        title: String? = nil,
        tracks: [Track]? = nil,
        speakerIdentities: [SpeakerIdentity]? = nil,
        artifacts: [Artifact]? = nil,
        transcriptionHistory: [TranscriptionRevision]? = nil,
        summaryHistory: [SummaryRevision]? = nil,
        pins: [Pin]? = nil,
        systemAudioStartupStageTimings:
            [SystemAudioStartupStageTiming]? = nil,
        systemAudioGraphPreparation: SystemAudioGraphPreparation? = nil,
        microphoneInputDevice: MicrophoneInputDeviceIdentity? = nil
    ) -> CaptureSessionManifest {
        CaptureSessionManifest(
            version: Self.currentVersion,
            sessionID: sessionID ?? self.sessionID,
            title: title ?? self.title,
            createdAt: createdAt,
            source: source,
            sampleRate: sampleRate,
            channelCount: channelCount,
            tracks: tracks ?? self.tracks,
            speakerIdentities:
                speakerIdentities ?? self.speakerIdentities,
            artifacts: artifacts ?? self.artifacts,
            transcriptionHistory:
                transcriptionHistory ?? self.transcriptionHistory,
            summaryHistory: summaryHistory ?? self.summaryHistory,
            pins: pins ?? self.pins,
            originalFilename: originalFilename,
            originalFormat: originalFormat,
            systemAudioStartupStageTimings:
                systemAudioStartupStageTimings
                ?? self.systemAudioStartupStageTimings,
            systemAudioGraphPreparation:
                systemAudioGraphPreparation
                ?? self.systemAudioGraphPreparation,
            microphoneInputDevice:
                microphoneInputDevice ?? self.microphoneInputDevice
        )
    }

    public func validate() throws {
        guard (1...Self.currentVersion).contains(version) else {
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
        let speakerIDs = speakerIdentities.map(\.id)
        guard
            !speakerIdentities.isEmpty,
            Set(speakerIDs).count == speakerIDs.count,
            speakerIdentities.allSatisfy({
                !$0.id.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            }),
            Set(speakerIdentities.map(\.source)) == expectedSources
        else {
            throw CaptureSessionManifestError.invalidSpeakerSet
        }
        for speaker in speakerIdentities {
            let cleanName = speaker.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                (cleanName == nil && speaker.nameAssignment == nil)
                    || (cleanName?.isEmpty == false
                        && speaker.nameAssignment != nil)
            else {
                throw CaptureSessionManifestError.invalidSpeakerName(
                    speaker.id
                )
            }
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
        for revision in summaryHistory {
            for path in revision.artifacts {
                try Self.validate(relativePath: path)
            }
        }
        guard
            Set(pins.map(\.id)).count == pins.count,
            pins.allSatisfy({ $0.sampleOffset >= 0 })
        else {
            throw CaptureSessionManifestError.invalidPins
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

    private static func defaultSpeakerIdentities(
        for tracks: [Track]
    ) -> [SpeakerIdentity] {
        tracks.map { track in
            SpeakerIdentity(
                id: "source.\(track.source.rawValue)",
                source: track.source
            )
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
        case speakerIdentities
        case artifacts
        case transcriptionHistory
        case summaryHistory
        case pins
        case originalFilename
        case originalFormat
        case systemAudioStartupStageTimings
        case systemAudioGraphPreparation
        case microphoneInputDevice
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
        speakerIdentities = try container.decodeIfPresent(
            [SpeakerIdentity].self,
            forKey: .speakerIdentities
        ) ?? Self.defaultSpeakerIdentities(for: tracks)
        artifacts = try container.decodeIfPresent(
            [Artifact].self,
            forKey: .artifacts
        ) ?? tracks.map { Artifact(relativePath: $0.relativePath, kind: .audio) }
        transcriptionHistory = try container.decodeIfPresent(
            [TranscriptionRevision].self,
            forKey: .transcriptionHistory
        ) ?? []
        summaryHistory = try container.decodeIfPresent(
            [SummaryRevision].self,
            forKey: .summaryHistory
        ) ?? []
        pins = try container.decodeIfPresent(
            [Pin].self,
            forKey: .pins
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
        microphoneInputDevice = try container.decodeIfPresent(
            MicrophoneInputDeviceIdentity.self,
            forKey: .microphoneInputDevice
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
    case invalidSpeakerSet
    case invalidSpeakerName(String)
    case speakerNotFound(String)
    case pinNotFound(UUID)
    case invalidPins
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
        case .invalidSpeakerSet:
            "Session metadata needs unique speaker identities covering every audio source."
        case let .invalidSpeakerName(id):
            "Speaker \(id) has an invalid display-name assignment."
        case let .speakerNotFound(id):
            "Session metadata does not contain speaker \(id)."
        case let .pinNotFound(id):
            "Session metadata does not contain pin \(id.uuidString)."
        case .invalidPins:
            "Session metadata contains duplicate pins or a negative pin offset."
        case .invalidTitle:
            "Session metadata must contain a title."
        case let .invalidStartTime(source, startTime):
            "The \(source.rawValue) track has an invalid start time: \(startTime)."
        case let .invalidRelativePath(path):
            "Session metadata contains an unsafe relative path: \(path)."
        }
    }
}

/// Serializes every in-place mutation of session.json. Each operation reloads
/// the latest durable value before changing only the fields it owns, so a
/// delayed writer cannot restore a stale snapshot over another feature's data.
public actor CaptureSessionManifestStore {
    public static let shared = CaptureSessionManifestStore()

    public func appendPin(
        _ pin: CaptureSessionManifest.Pin,
        in sessionDirectory: URL
    ) throws {
        let manifest = try CaptureSessionManifest.load(
            from: sessionDirectory
        )
        try manifest.appendingPin(pin).write(to: sessionDirectory)
    }

    public func replaceTrackOffsets(
        microphone: Int64?,
        system: Int64?,
        in sessionDirectory: URL
    ) throws {
        let manifest = try CaptureSessionManifest.load(
            from: sessionDirectory
        ).replacingTrackOffsets(
            microphone: microphone,
            system: system
        )
        try manifest.write(to: sessionDirectory)
    }

    public func replaceArtifacts(
        _ artifacts: [CaptureSessionManifest.Artifact],
        in sessionDirectory: URL
    ) throws -> CaptureSessionManifest {
        let manifest = try CaptureSessionManifest.load(
            from: sessionDirectory
        ).replacing(artifacts: artifacts)
        try manifest.write(to: sessionDirectory)
        return manifest
    }

    public func replaceSessionID(
        _ sessionID: UUID,
        in sessionDirectory: URL
    ) throws -> CaptureSessionManifest {
        let manifest = try CaptureSessionManifest.load(
            from: sessionDirectory
        ).replacing(sessionID: sessionID)
        try manifest.write(to: sessionDirectory)
        return manifest
    }

    public func renameSpeaker(
        identifiedBy id: String,
        to displayName: String?,
        assignment: CaptureSessionManifest.SpeakerNameAssignment,
        in sessionDirectory: URL
    ) throws -> CaptureSessionManifest {
        let manifest = try CaptureSessionManifest.load(
            from: sessionDirectory
        )
        let updated = try manifest.renamingSpeaker(
            identifiedBy: id,
            to: displayName,
            assignment: assignment
        )
        try updated.write(to: sessionDirectory)
        return updated
    }

    public func commitTranscriptionRevision(
        _ revision: CaptureSessionManifest.TranscriptionRevision,
        currentArtifacts: [CaptureSessionManifest.Artifact],
        in sessionDirectory: URL
    ) throws -> CaptureSessionManifest {
        let manifest = try CaptureSessionManifest.load(
            from: sessionDirectory
        )
        let currentPaths = Set(currentArtifacts.map(\.relativePath))
        let updated = manifest.replacing(
            artifacts: manifest.artifacts.filter {
                !currentPaths.contains($0.relativePath)
            } + currentArtifacts,
            transcriptionHistory: manifest.transcriptionHistory + [revision]
        )
        try updated.write(to: sessionDirectory)
        return updated
    }

    public func commitSummaryRevision(
        _ revision: CaptureSessionManifest.SummaryRevision,
        in sessionDirectory: URL
    ) throws -> CaptureSessionManifest {
        let manifest = try CaptureSessionManifest.load(
            from: sessionDirectory
        )
        let summaryArtifact = CaptureSessionManifest.Artifact(
            relativePath: "summary.md",
            kind: .summary
        )
        let updated = manifest.replacing(
            artifacts: manifest.artifacts.filter {
                $0.relativePath != summaryArtifact.relativePath
            } + [summaryArtifact],
            summaryHistory: manifest.summaryHistory + [revision]
        )
        try updated.write(to: sessionDirectory)
        return updated
    }

    public func replaceTitle(
        _ title: String,
        in sessionDirectory: URL
    ) throws -> CaptureSessionManifest {
        let manifest = try CaptureSessionManifest.load(
            from: sessionDirectory
        ).replacing(title: title)
        try manifest.write(to: sessionDirectory)
        return manifest
    }
}
