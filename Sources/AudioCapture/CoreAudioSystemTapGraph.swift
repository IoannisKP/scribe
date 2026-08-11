@preconcurrency import AVFoundation
@preconcurrency import CoreAudio
import Foundation

final class CoreAudioSystemTapGraph: @unchecked Sendable {
    enum TapScope: Sendable {
        case excludingCurrentProcess
        case allProcesses
    }

    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private(set) var ioProcID: AudioDeviceIOProcID?
    private(set) var outputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private(set) var sampleRate: Double = 0
    private(set) var isStarted = false

    private let ringBuffer: FloatRingBuffer
    private let realtimeSink: SystemAudioRealtimeSink
    private let tapScope: TapScope

    init(
        ringBuffer: FloatRingBuffer,
        firstSampleTime: FirstSampleHostTime,
        tapScope: TapScope = .excludingCurrentProcess
    ) {
        self.ringBuffer = ringBuffer
        self.realtimeSink = SystemAudioRealtimeSink(
            ringBuffer: ringBuffer,
            firstSampleTime: firstSampleTime
        )
        self.tapScope = tapScope
    }

    func prepare() throws {
        guard tapID == kAudioObjectUnknown else {
            throw AudioCaptureError.systemCaptureAlreadyRunning
        }

        do {
            outputDeviceID = try CoreAudioProperties.defaultOutputDevice()
            let outputDeviceUID = try CoreAudioProperties.deviceUID(outputDeviceID)
            let excludedProcessObjectIDs: [AudioObjectID]
            switch tapScope {
            case .excludingCurrentProcess:
                excludedProcessObjectIDs = [
                    try CoreAudioProperties.currentProcessObjectID()
                ]
            case .allProcesses:
                excludedProcessObjectIDs = []
            }

            let tapDescription = CATapDescription(
                monoGlobalTapButExcludeProcesses: excludedProcessObjectIDs
            )
            tapDescription.name = "Scribe System Audio \(UUID().uuidString)"
            tapDescription.isPrivate = true
            tapDescription.muteBehavior = .unmuted

            var newTapID = AudioObjectID(kAudioObjectUnknown)
            try CoreAudioCallError.checkSystemAudio(
                AudioHardwareCreateProcessTap(tapDescription, &newTapID),
                operation: "Creating the system-audio process tap"
            )
            tapID = newTapID

            var streamDescription = try CoreAudioProperties.tapFormat(tapID)
            guard
                streamDescription.mFormatID == kAudioFormatLinearPCM,
                streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                streamDescription.mBitsPerChannel == 32,
                streamDescription.mSampleRate.isFinite,
                streamDescription.mSampleRate > 0,
                streamDescription.mChannelsPerFrame == 1,
                withUnsafePointer(to: &streamDescription, {
                    AVAudioFormat(streamDescription: $0)
                }) != nil
            else {
                throw AudioCaptureError.systemTapFormatUnsupported
            }
            sampleRate = streamDescription.mSampleRate

            let aggregateDescription = SystemTapAggregateDescription.make(
                outputDeviceUID: outputDeviceUID,
                tapUID: tapDescription.uuid.uuidString,
                aggregateUID:
                    "com.localfirst.Scribe.SystemTap.\(UUID().uuidString)"
            )

            var newAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            try CoreAudioCallError.checkSystemAudio(
                AudioHardwareCreateAggregateDevice(
                    aggregateDescription as CFDictionary,
                    &newAggregateDeviceID
                ),
                operation: "Creating the private system-audio aggregate device"
            )
            aggregateDeviceID = newAggregateDeviceID

            var newIOProcID: AudioDeviceIOProcID?
            try CoreAudioCallError.checkSystemAudio(
                AudioDeviceCreateIOProcIDWithBlock(
                    &newIOProcID,
                    aggregateDeviceID,
                    nil
                ) { [realtimeSink] _, inputData, inputTime, _, _ in
                    realtimeSink.receive(inputData, inputTime: inputTime)
                },
                operation: "Registering the system-audio aggregate IOProc"
            )
            guard let newIOProcID else {
                throw AudioCaptureError.coreAudioOperationFailed(
                    operation: "Registering the system-audio aggregate IOProc",
                    status: kAudioHardwareUnspecifiedError,
                    statusDescription: "Core Audio returned no IOProc identifier"
                )
            }
            ioProcID = newIOProcID
        } catch {
            let cleanupMessage = cleanupAfterSetupFailure()
            if let cleanupMessage {
                throw AudioCaptureError.systemGraphTeardownFailed(
                    "\(error.localizedDescription) Cleanup: \(cleanupMessage)"
                )
            }
            throw error
        }
    }

    func start() throws {
        guard
            aggregateDeviceID != kAudioObjectUnknown,
            let ioProcID
        else {
            throw AudioCaptureError.systemCaptureNotRunning
        }
        guard !isStarted else {
            return
        }

        try CoreAudioCallError.checkSystemAudio(
            AudioDeviceStart(aggregateDeviceID, ioProcID),
            operation: "Starting the system-audio aggregate device"
        )
        isStarted = true
    }

    func tearDown() throws {
        var failures: [String] = []

        if isStarted, let ioProcID {
            let status = AudioDeviceStop(aggregateDeviceID, ioProcID)
            if status != noErr {
                failures.append(
                    CoreAudioCallError(
                        operation: "Stopping the system-audio aggregate device",
                        status: status
                    ).localizedDescription
                )
            }
            isStarted = false
        }

        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            let status = AudioDeviceDestroyIOProcID(
                aggregateDeviceID,
                ioProcID
            )
            if status != noErr {
                failures.append(
                    CoreAudioCallError(
                        operation: "Destroying the system-audio IOProc",
                        status: status
                    ).localizedDescription
                )
            }
            self.ioProcID = nil
        }

        if aggregateDeviceID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(
                aggregateDeviceID
            )
            if status != noErr {
                failures.append(
                    CoreAudioCallError(
                        operation: "Destroying the private aggregate device",
                        status: status
                    ).localizedDescription
                )
            }
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status != noErr {
                failures.append(
                    CoreAudioCallError(
                        operation: "Destroying the system-audio process tap",
                        status: status
                    ).localizedDescription
                )
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        outputDeviceID = AudioDeviceID(kAudioObjectUnknown)
        sampleRate = 0
        if !failures.isEmpty {
            throw AudioCaptureError.systemGraphTeardownFailed(
                failures.joined(separator: " ")
            )
        }
    }

    private func cleanupAfterSetupFailure() -> String? {
        do {
            try tearDown()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

enum SystemTapAggregateDescription {
    static func make(
        outputDeviceUID: String,
        tapUID: String,
        aggregateUID: String
    ) -> [String: Any] {
        let subdevice: [String: Any] = [
            kAudioSubDeviceUIDKey: outputDeviceUID,
            kAudioSubDeviceInputChannelsKey: 0
        ]
        let subtap: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: true
        ]
        return [
            kAudioAggregateDeviceNameKey: "Scribe Private System Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceSubDeviceListKey: [subdevice],
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceTapListKey: [subtap],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceIsPrivateKey: true
        ]
    }
}

private final class SystemAudioRealtimeSink: @unchecked Sendable {
    private let ringBuffer: FloatRingBuffer
    private let firstSampleTime: FirstSampleHostTime

    init(
        ringBuffer: FloatRingBuffer,
        firstSampleTime: FirstSampleHostTime
    ) {
        self.ringBuffer = ringBuffer
        self.firstSampleTime = firstSampleTime
    }

    func receive(
        _ inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        let written = ringBuffer.writeAudioBufferListMix(inputData)
        let timestamp = inputTime.pointee
        if
            written > 0,
            timestamp.mFlags.contains(.hostTimeValid)
        {
            firstSampleTime.capture(timestamp.mHostTime)
        }
    }
}
