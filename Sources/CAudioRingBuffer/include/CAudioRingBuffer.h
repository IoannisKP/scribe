#ifndef CSCRIBE_FLOAT_RING_BUFFER_H
#define CSCRIBE_FLOAT_RING_BUFFER_H

#include <stdbool.h>
#include <CoreAudio/CoreAudioTypes.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if __has_feature(nullability)
#pragma clang assume_nonnull begin
#endif

typedef struct ScribeFloatRingBuffer ScribeFloatRingBuffer;

/// Creates a single-producer, single-consumer ring buffer.
///
/// The returned buffer owns preallocated storage for exactly `capacity` float
/// samples. Creation and destruction must not happen on a realtime audio
/// thread.
ScribeFloatRingBuffer * _Nullable scribe_float_ring_buffer_create(size_t capacity);

void scribe_float_ring_buffer_destroy(ScribeFloatRingBuffer *buffer);

size_t scribe_float_ring_buffer_capacity(const ScribeFloatRingBuffer *buffer);
size_t scribe_float_ring_buffer_readable_count(const ScribeFloatRingBuffer *buffer);
size_t scribe_float_ring_buffer_writable_count(const ScribeFloatRingBuffer *buffer);

/// Writes as many samples as fit and returns the number written.
///
/// This operation is wait-free for the single producer and performs no
/// allocation, locking, or logging.
size_t scribe_float_ring_buffer_write(
    ScribeFloatRingBuffer *buffer,
    const float *samples,
    size_t count
);

/// Mixes noninterleaved Float32 channels to mono and writes frames that fit.
///
/// This operation is wait-free for the single producer and performs no
/// allocation, locking, or logging.
size_t scribe_float_ring_buffer_write_planar_mix(
    ScribeFloatRingBuffer *buffer,
    float * _Nonnull const * _Nonnull channels,
    size_t channel_count,
    size_t frame_count
);

/// Mixes a Float32 AudioBufferList to mono and writes frames that fit.
///
/// Both interleaved and noninterleaved layouts are supported. This operation
/// is wait-free for the single producer and performs no allocation, locking,
/// or logging.
size_t scribe_float_ring_buffer_write_audio_buffer_list_mix(
    ScribeFloatRingBuffer *buffer,
    const AudioBufferList *buffer_list
);

/// Reads as many samples as available and returns the number read.
///
/// This operation is wait-free for the single consumer and performs no
/// allocation, locking, or logging.
size_t scribe_float_ring_buffer_read(
    ScribeFloatRingBuffer *buffer,
    float *destination,
    size_t count
);

/// Discards buffered samples. Call only while producer and consumer are idle.
void scribe_float_ring_buffer_clear(ScribeFloatRingBuffer *buffer);

/// Total samples rejected by writes because the buffer was full.
uint64_t scribe_float_ring_buffer_dropped_sample_count(
    const ScribeFloatRingBuffer *buffer
);

#if __has_feature(nullability)
#pragma clang assume_nonnull end
#endif

#ifdef __cplusplus
}
#endif

#endif
