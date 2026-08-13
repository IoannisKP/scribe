import AudioCapture
import Foundation

public struct SpeakerIdentityStore: Sendable {
    public init() {}

    @discardableResult
    public func renameSpeaker(
        identifiedBy id: String,
        to displayName: String?,
        assignment: CaptureSessionManifest.SpeakerNameAssignment =
            .userAssigned,
        in sessionDirectory: URL
    ) async throws -> CaptureSessionManifest {
        try await CaptureSessionManifestStore.shared.renameSpeaker(
            identifiedBy: id,
            to: displayName,
            assignment: assignment,
            in: sessionDirectory
        )
    }
}
