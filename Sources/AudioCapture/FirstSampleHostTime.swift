#if canImport(CAudioRingBuffer)
import CAudioRingBuffer
#endif
import Darwin.Mach
import Foundation

final class FirstSampleHostTime: @unchecked Sendable {
    private let storage: OpaquePointer

    init() throws {
        guard let storage = scribe_atomic_host_time_create() else {
            throw AudioCaptureError.hostTimeLatchAllocationFailed
        }
        self.storage = storage
    }

    deinit {
        scribe_atomic_host_time_destroy(storage)
    }

    func capture(_ hostTime: UInt64) {
        _ = scribe_atomic_host_time_capture_first(storage, hostTime)
    }

    var value: UInt64? {
        let value = scribe_atomic_host_time_load(storage)
        return value == 0 ? nil : value
    }
}

public enum AudioHostTime {
    public static func canonicalSampleOffset(
        from earlierHostTime: UInt64,
        to laterHostTime: UInt64
    ) -> Int64 {
        guard laterHostTime > earlierHostTime else { return 0 }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = laterHostTime - earlierHostTime
        let nanoseconds = Double(ticks)
            * Double(timebase.numer)
            / Double(timebase.denom)
        return Int64(
            (nanoseconds * CanonicalAudioFormat.sampleRate / 1_000_000_000)
                .rounded()
        )
    }

    public static func normalizedCanonicalOffsets(
        microphoneHostTime: UInt64?,
        systemHostTime: UInt64?
    ) -> (microphone: Int64?, system: Int64?) {
        guard let microphoneHostTime, let systemHostTime else {
            return (
                microphoneHostTime == nil ? nil : 0,
                systemHostTime == nil ? nil : 0
            )
        }
        if microphoneHostTime <= systemHostTime {
            return (
                0,
                canonicalSampleOffset(
                    from: microphoneHostTime,
                    to: systemHostTime
                )
            )
        }
        return (
            canonicalSampleOffset(
                from: systemHostTime,
                to: microphoneHostTime
            ),
            0
        )
    }
}
