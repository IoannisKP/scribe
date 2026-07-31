@preconcurrency import CoreAudio
import Foundation

public enum SystemAudioAuthorizationStatus: String, Codable, Sendable {
    case notDetermined
    case authorized
    case denied

    public var requiresSystemSettings: Bool {
        self == .denied
    }

    public static let systemSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
    )
}

public protocol SystemAudioPermissionStatusProviding: Sendable {
    func authorizationStatus() async -> SystemAudioAuthorizationStatus
}

public protocol SystemAudioPermissionRecording: Sendable {
    func recordAuthorizationStatus(
        _ status: SystemAudioAuthorizationStatus
    ) async
}

public protocol SystemAudioPermissionAuthorizing:
    SystemAudioPermissionStatusProviding,
    SystemAudioPermissionRecording,
    Sendable
{
    func requestAuthorization() async throws -> SystemAudioAuthorizationStatus
}

public actor SystemAudioPermissionAuthorizer:
    SystemAudioPermissionAuthorizing
{
    private static let defaultsKey =
        "SystemAudioPermissionAuthorizer.lastKnownStatus"

    private var lastKnownStatus: SystemAudioAuthorizationStatus
    private let persistence: PermissionStatusPersistence?

    public init() {
        let persistence = PermissionStatusPersistence(
            defaults: .standard,
            key: Self.defaultsKey
        )
        self.persistence = persistence
        self.lastKnownStatus = persistence.read()
    }

    public init(initialStatus: SystemAudioAuthorizationStatus) {
        self.persistence = nil
        self.lastKnownStatus = initialStatus
    }

    public func authorizationStatus() -> SystemAudioAuthorizationStatus {
        lastKnownStatus
    }

    public func recordAuthorizationStatus(
        _ status: SystemAudioAuthorizationStatus
    ) {
        lastKnownStatus = status
        persistence?.write(status)
    }

    public func requestAuthorization() async throws
        -> SystemAudioAuthorizationStatus
    {
        let ringBuffer = try FloatRingBuffer(capacity: 4_096)
        let graph = CoreAudioSystemTapGraph(
            ringBuffer: ringBuffer,
            tapScope: .allProcesses
        )

        do {
            try graph.prepare()
            try graph.start()
            try graph.tearDown()
            recordAuthorizationStatus(.authorized)
            return .authorized
        } catch {
            let primaryError = error
            var cleanupMessage: String?
            do {
                try graph.tearDown()
            } catch {
                cleanupMessage = error.localizedDescription
            }

            if primaryError as? AudioCaptureError
                == .systemAudioPermissionDenied
            {
                recordAuthorizationStatus(.denied)
                return .denied
            }

            let primaryMessage = primaryError.localizedDescription
            let combinedMessage = cleanupMessage.map {
                "\(primaryMessage) Cleanup also failed: \($0)"
            } ?? primaryMessage
            throw AudioCaptureError.systemAudioPermissionCheckFailed(
                combinedMessage
            )
        }
    }
}

private final class PermissionStatusPersistence: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func read() -> SystemAudioAuthorizationStatus {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard
            let rawValue = defaults.string(forKey: key),
            let status = SystemAudioAuthorizationStatus(rawValue: rawValue)
        else {
            return .notDetermined
        }
        return status
    }

    func write(_ status: SystemAudioAuthorizationStatus) {
        lock.lock()
        defaults.set(status.rawValue, forKey: key)
        lock.unlock()
    }
}
