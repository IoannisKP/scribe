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
}
