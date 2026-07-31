#if canImport(CAudioRingBuffer)
import CAudioRingBuffer
#endif
import CoreAudioTypes

/// A preallocated single-producer, single-consumer FIFO for Float32 samples.
///
/// `write` and `read` are wait-free for their respective caller. They perform
/// no allocation, locking, logging, or reference-counted mutation. Exactly one
/// producer and one consumer may access an instance concurrently.
public final class FloatRingBuffer: @unchecked Sendable {
    private let storage: OpaquePointer

    public let capacity: Int

    public init(capacity: Int) throws {
        guard capacity > 0 else {
            throw AudioCaptureError.invalidRingBufferCapacity(capacity)
        }
        guard let storage = scribe_float_ring_buffer_create(capacity) else {
            throw AudioCaptureError.ringBufferAllocationFailed(capacity)
        }

        self.storage = storage
        self.capacity = capacity
    }

    deinit {
        scribe_float_ring_buffer_destroy(storage)
    }

    public var readableCount: Int {
        Int(scribe_float_ring_buffer_readable_count(storage))
    }

    public var writableCount: Int {
        Int(scribe_float_ring_buffer_writable_count(storage))
    }

    public var droppedSampleCount: UInt64 {
        scribe_float_ring_buffer_dropped_sample_count(storage)
    }

    @discardableResult
    public func write(_ samples: UnsafeBufferPointer<Float>) -> Int {
        guard let baseAddress = samples.baseAddress else {
            return 0
        }
        return Int(
            scribe_float_ring_buffer_write(storage, baseAddress, samples.count)
        )
    }

    @discardableResult
    public func read(into destination: UnsafeMutableBufferPointer<Float>) -> Int {
        guard let baseAddress = destination.baseAddress else {
            return 0
        }
        return Int(
            scribe_float_ring_buffer_read(storage, baseAddress, destination.count)
        )
    }

    /// Mixes noninterleaved Float32 channels to mono and writes frames that fit.
    ///
    /// The channel pointers and their samples must remain valid for the call.
    @discardableResult
    public func writePlanarMix(
        channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int
    ) -> Int {
        guard channelCount > 0, frameCount > 0 else {
            return 0
        }

        return Int(
            scribe_float_ring_buffer_write_planar_mix(
                storage,
                channels,
                channelCount,
                frameCount
            )
        )
    }

    /// Mixes Float32 buffers, including interleaved layouts, to mono.
    ///
    /// Core Audio reports disabled input streams with a nil data pointer while
    /// retaining the byte count that would have been rendered. Those frames
    /// are committed as silence so source sample indices remain wall-clock
    /// linear through system-rendering gaps.
    @discardableResult
    public func writeAudioBufferListMix(
        _ bufferList: UnsafePointer<AudioBufferList>
    ) -> Int {
        Int(
            scribe_float_ring_buffer_write_audio_buffer_list_mix(
                storage,
                bufferList
            )
        )
    }

    /// Discards all buffered samples.
    ///
    /// The producer and consumer must both be idle when this method is called.
    public func clear() {
        scribe_float_ring_buffer_clear(storage)
    }
}
