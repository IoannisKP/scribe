@preconcurrency import CoreAudio
@preconcurrency import AudioToolbox
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
    static func defaultInputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
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
            operation: "Reading the default input device"
        )
        guard deviceID != kAudioObjectUnknown else {
            throw AudioCaptureError.microphoneInputUnavailable
        }
        return deviceID
    }

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

    /// The device's current nominal sample rate.
    ///
    /// For a Bluetooth output switching into headset mode this tracks reality
    /// while `kAudioTapPropertyFormat` does not: measured on the affected
    /// AirPods, the output device moved 48000 -> 24000 while the tap kept
    /// reporting 48000 and its format listener never fired.
    static func nominalSampleRate(
        _ deviceID: AudioDeviceID
    ) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        try CoreAudioCallError.check(
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                &sampleRate
            ),
            operation: "Reading the audio device nominal sample rate"
        )
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw AudioCaptureError.systemTapFormatUnsupported
        }
        return sampleRate
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
            operation: "Reading the audio device UID"
        )
        guard let unmanagedUID else {
            throw AudioCaptureError.audioDeviceIdentityUnavailable
        }
        return unmanagedUID.takeRetainedValue() as String
    }

    static func deviceName(_ deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &unmanagedName
        )
        try CoreAudioCallError.check(
            status,
            operation: "Reading the audio device name"
        )
        guard let unmanagedName else {
            throw AudioCaptureError.audioDeviceIdentityUnavailable
        }
        return unmanagedName.takeRetainedValue() as String
    }

    static func inputDeviceIdentity(
        _ deviceID: AudioDeviceID
    ) throws -> MicrophoneInputDeviceIdentity {
        MicrophoneInputDeviceIdentity(
            audioDeviceID: deviceID,
            uid: try deviceUID(deviceID),
            name: try deviceName(deviceID)
        )
    }

    static func bindInputDevice(
        _ deviceID: AudioDeviceID,
        to audioUnit: AudioUnit
    ) throws {
        var requestedDeviceID = deviceID
        try CoreAudioCallError.check(
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &requestedDeviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            ),
            operation: "Binding the microphone engine to the selected input device"
        )

        var boundDeviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try CoreAudioCallError.check(
            AudioUnitGetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &boundDeviceID,
                &size
            ),
            operation: "Verifying the microphone input-device binding"
        )
        guard boundDeviceID == deviceID else {
            throw AudioCaptureError.microphoneInputDeviceBindingMismatch(
                requested: deviceID,
                bound: boundDeviceID
            )
        }
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
