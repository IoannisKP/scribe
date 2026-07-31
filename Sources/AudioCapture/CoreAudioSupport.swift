@preconcurrency import CoreAudio
import Darwin
import Foundation

struct CoreAudioCallError: Error, Equatable, LocalizedError, Sendable {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        AudioCaptureError.coreAudioOperationFailed(
            operation: operation,
            status: status,
            statusDescription: Self.describe(status)
        ).localizedDescription
    }

    static func check(_ status: OSStatus, operation: String) throws {
        guard status != noErr else {
            return
        }
        throw CoreAudioCallError(operation: operation, status: status)
    }

    static func checkSystemAudio(
        _ status: OSStatus,
        operation: String
    ) throws {
        if status == kAudioDevicePermissionsError {
            throw AudioCaptureError.systemAudioPermissionDenied
        }
        try check(status, operation: operation)
    }

    static func describe(_ status: OSStatus) -> String {
        var bigEndian = UInt32(bitPattern: status).bigEndian
        let characters = Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            bytes.map { byte -> Character in
                let isPrintableASCII = byte >= 32 && byte <= 126
                return isPrintableASCII ? Character(UnicodeScalar(byte)) : "?"
            }
        }
        let fourCharacterCode = String(characters)
        if fourCharacterCode.allSatisfy({ $0 == "?" }) {
            return "unprintable OSStatus"
        }
        return "'\(fourCharacterCode)'"
    }
}

enum CoreAudioProperties {
    static func defaultOutputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        try CoreAudioCallError.check(
            status,
            operation: "Reading the default output device"
        )
        guard deviceID != kAudioObjectUnknown else {
            throw AudioCaptureError.systemOutputDeviceUnavailable
        }
        return deviceID
    }

    static func deviceUID(_ deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedUID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &unmanagedUID
        )
        try CoreAudioCallError.check(
            status,
            operation: "Reading the default output device UID"
        )
        guard let unmanagedUID else {
            throw AudioCaptureError.systemOutputDeviceUnavailable
        }
        return unmanagedUID.takeRetainedValue() as String
    }

    static func currentProcessObjectID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processID = getpid()
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var outputSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &processID) { processIDPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                processIDPointer,
                &outputSize,
                &processObjectID
            )
        }
        try CoreAudioCallError.check(
            status,
            operation: "Resolving Scribe's Core Audio process"
        )
        guard processObjectID != kAudioObjectUnknown else {
            throw AudioCaptureError.systemProcessObjectUnavailable
        }
        return processObjectID
    }

    static func tapFormat(_ tapID: AudioObjectID) throws
        -> AudioStreamBasicDescription
    {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(
            tapID,
            &address,
            0,
            nil,
            &size,
            &format
        )
        try CoreAudioCallError.check(
            status,
            operation: "Reading the system-audio tap format"
        )
        return format
    }
}
