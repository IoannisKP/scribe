@preconcurrency import AVFoundation
import Foundation

public enum MicrophoneAuthorizationStatus: String, Codable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted

    public var requiresSystemSettings: Bool {
        self == .denied || self == .restricted
    }

    public static let systemSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )
}

public protocol MicrophonePermissionAuthorizing: Sendable {
    func authorizationStatus() async -> MicrophoneAuthorizationStatus
    func requestAuthorization() async -> Bool
}

public struct SystemMicrophonePermissionAuthorizer:
    MicrophonePermissionAuthorizing,
    Sendable
{
    public init() {}

    public func authorizationStatus() async -> MicrophoneAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            .notDetermined
        case .authorized:
            .authorized
        case .denied:
            .denied
        case .restricted:
            .restricted
        @unknown default:
            .restricted
        }
    }

    public func requestAuthorization() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
