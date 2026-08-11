#include "CAudioRingBuffer.h"

#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct ScribeFloatRingBuffer {
    size_t capacity;
    float *samples;
    _Alignas(64) _Atomic uint64_t write_index;
    _Alignas(64) _Atomic uint64_t read_index;
    _Alignas(64) _Atomic uint64_t dropped_sample_count;
};

struct ScribeAtomicHostTime {
    _Atomic uint64_t value;
};

ScribeAtomicHostTime *scribe_atomic_host_time_create(void) {
    ScribeAtomicHostTime *latch = calloc(1, sizeof(ScribeAtomicHostTime));
    if (latch != NULL) {
        atomic_init(&latch->value, 0);
    }
    return latch;
}

void scribe_atomic_host_time_destroy(ScribeAtomicHostTime *latch) {
    free(latch);
}

bool scribe_atomic_host_time_capture_first(
    ScribeAtomicHostTime *latch,
    uint64_t host_time
) {
    if (latch == NULL || host_time == 0) {
        return false;
    }
    uint64_t expected = 0;
    return atomic_compare_exchange_strong_explicit(
        &latch->value,
        &expected,
        host_time,
        memory_order_release,
        memory_order_relaxed
    );
}

uint64_t scribe_atomic_host_time_load(const ScribeAtomicHostTime *latch) {
    if (latch == NULL) {
        return 0;
    }
    return atomic_load_explicit(&latch->value, memory_order_acquire);
}

ScribeFloatRingBuffer *scribe_float_ring_buffer_create(size_t capacity) {
    if (capacity == 0) {
        return NULL;
    }

    ScribeFloatRingBuffer *buffer = calloc(1, sizeof(ScribeFloatRingBuffer));
    if (buffer == NULL) {
        return NULL;
    }

    buffer->samples = calloc(capacity, sizeof(float));
    if (buffer->samples == NULL) {
        free(buffer);
        return NULL;
    }

    buffer->capacity = capacity;
    atomic_init(&buffer->write_index, 0);
    atomic_init(&buffer->read_index, 0);
    atomic_init(&buffer->dropped_sample_count, 0);
    return buffer;
}

void scribe_float_ring_buffer_destroy(ScribeFloatRingBuffer *buffer) {
    if (buffer == NULL) {
        return;
    }

    free(buffer->samples);
    buffer->samples = NULL;
    free(buffer);
}

size_t scribe_float_ring_buffer_capacity(const ScribeFloatRingBuffer *buffer) {
    return buffer == NULL ? 0 : buffer->capacity;
}

size_t scribe_float_ring_buffer_readable_count(const ScribeFloatRingBuffer *buffer) {
    if (buffer == NULL) {
        return 0;
    }

    uint64_t write_index = atomic_load_explicit(&buffer->write_index, memory_order_acquire);
    uint64_t read_index = atomic_load_explicit(&buffer->read_index, memory_order_acquire);
    uint64_t readable = write_index - read_index;
    return readable > buffer->capacity ? buffer->capacity : (size_t)readable;
}

size_t scribe_float_ring_buffer_writable_count(const ScribeFloatRingBuffer *buffer) {
    if (buffer == NULL) {
        return 0;
    }

    return buffer->capacity - scribe_float_ring_buffer_readable_count(buffer);
}

size_t scribe_float_ring_buffer_write(
    ScribeFloatRingBuffer *buffer,
    const float *samples,
    size_t count
) {
    if (buffer == NULL || samples == NULL || count == 0) {
        return 0;
    }

    uint64_t write_index = atomic_load_explicit(&buffer->write_index, memory_order_relaxed);
    uint64_t read_index = atomic_load_explicit(&buffer->read_index, memory_order_acquire);
    uint64_t used = write_index - read_index;
    size_t writable = used >= buffer->capacity ? 0 : buffer->capacity - (size_t)used;
    size_t write_count = count < writable ? count : writable;
    size_t dropped_count = count - write_count;
    if (dropped_count > 0) {
        atomic_fetch_add_explicit(
            &buffer->dropped_sample_count,
            dropped_count,
            memory_order_relaxed
        );
    }
    if (write_count == 0) {
        return 0;
    }

    size_t offset = (size_t)(write_index % buffer->capacity);
    size_t first_count = write_count < buffer->capacity - offset
        ? write_count
        : buffer->capacity - offset;
    memcpy(buffer->samples + offset, samples, first_count * sizeof(float));

    size_t second_count = write_count - first_count;
    if (second_count > 0) {
        memcpy(buffer->samples, samples + first_count, second_count * sizeof(float));
    }

    atomic_store_explicit(
        &buffer->write_index,
        write_index + write_count,
        memory_order_release
    );
    return write_count;
}

size_t scribe_float_ring_buffer_write_planar_mix(
    ScribeFloatRingBuffer *buffer,
    float * const *channels,
    size_t channel_count,
    size_t frame_count
) {
    if (
        buffer == NULL
        || channels == NULL
        || channel_count == 0
        || frame_count == 0
    ) {
        return 0;
    }

    for (size_t channel = 0; channel < channel_count; channel += 1) {
        if (channels[channel] == NULL) {
            return 0;
        }
    }

    if (channel_count == 1) {
        return scribe_float_ring_buffer_write(
            buffer,
            channels[0],
            frame_count
        );
    }

    uint64_t write_index = atomic_load_explicit(&buffer->write_index, memory_order_relaxed);
    uint64_t read_index = atomic_load_explicit(&buffer->read_index, memory_order_acquire);
    uint64_t used = write_index - read_index;
    size_t writable = used >= buffer->capacity ? 0 : buffer->capacity - (size_t)used;
    size_t write_count = frame_count < writable ? frame_count : writable;
    size_t dropped_count = frame_count - write_count;
    if (dropped_count > 0) {
        atomic_fetch_add_explicit(
            &buffer->dropped_sample_count,
            dropped_count,
            memory_order_relaxed
        );
    }
    if (write_count == 0) {
        return 0;
    }

    for (size_t frame = 0; frame < write_count; frame += 1) {
        float sum = 0;
        for (size_t channel = 0; channel < channel_count; channel += 1) {
            sum += channels[channel][frame];
        }

        float mixed = sum / (float)channel_count;
        if (mixed > 1) {
            mixed = 1;
        } else if (mixed < -1) {
            mixed = -1;
        }

        size_t offset = (size_t)((write_index + frame) % buffer->capacity);
        buffer->samples[offset] = mixed;
    }

    atomic_store_explicit(
        &buffer->write_index,
        write_index + write_count,
        memory_order_release
    );
    return write_count;
}

size_t scribe_float_ring_buffer_write_audio_buffer_list_mix(
    ScribeFloatRingBuffer *buffer,
    const AudioBufferList *buffer_list
) {
    if (
        buffer == NULL
        || buffer_list == NULL
        || buffer_list->mNumberBuffers == 0
    ) {
        return 0;
    }

    size_t total_channels = 0;
    size_t frame_count = SIZE_MAX;
    for (
        UInt32 buffer_index = 0;
        buffer_index < buffer_list->mNumberBuffers;
        buffer_index += 1
    ) {
        const AudioBuffer *audio_buffer = &buffer_list->mBuffers[buffer_index];
        if (
            audio_buffer->mNumberChannels == 0
            || audio_buffer->mDataByteSize < sizeof(float)
        ) {
            continue;
        }

        size_t sample_count = audio_buffer->mDataByteSize / sizeof(float);
        size_t frames_in_buffer = sample_count / audio_buffer->mNumberChannels;
        if (frames_in_buffer < frame_count) {
            frame_count = frames_in_buffer;
        }
        total_channels += audio_buffer->mNumberChannels;
    }

    if (
        total_channels == 0
        || frame_count == 0
        || frame_count == SIZE_MAX
    ) {
        return 0;
    }

    uint64_t write_index = atomic_load_explicit(&buffer->write_index, memory_order_relaxed);
    uint64_t read_index = atomic_load_explicit(&buffer->read_index, memory_order_acquire);
    uint64_t used = write_index - read_index;
    size_t writable = used >= buffer->capacity ? 0 : buffer->capacity - (size_t)used;
    size_t write_count = frame_count < writable ? frame_count : writable;
    size_t dropped_count = frame_count - write_count;
    if (dropped_count > 0) {
        atomic_fetch_add_explicit(
            &buffer->dropped_sample_count,
            dropped_count,
            memory_order_relaxed
        );
    }
    if (write_count == 0) {
        return 0;
    }

    for (size_t frame = 0; frame < write_count; frame += 1) {
        float sum = 0;
        size_t mixed_channels = 0;
        for (
            UInt32 buffer_index = 0;
            buffer_index < buffer_list->mNumberBuffers;
            buffer_index += 1
        ) {
            const AudioBuffer *audio_buffer = &buffer_list->mBuffers[buffer_index];
            if (
                audio_buffer->mData == NULL
                || audio_buffer->mNumberChannels == 0
            ) {
                continue;
            }

            const float *samples = audio_buffer->mData;
            for (
                UInt32 channel = 0;
                channel < audio_buffer->mNumberChannels;
                channel += 1
            ) {
                sum += samples[
                    (frame * audio_buffer->mNumberChannels) + channel
                ];
                mixed_channels += 1;
            }
        }

        float mixed = mixed_channels == 0 ? 0 : sum / (float)mixed_channels;
        if (mixed > 1) {
            mixed = 1;
        } else if (mixed < -1) {
            mixed = -1;
        }

        size_t offset = (size_t)((write_index + frame) % buffer->capacity);
        buffer->samples[offset] = mixed;
    }

    atomic_store_explicit(
        &buffer->write_index,
        write_index + write_count,
        memory_order_release
    );
    return write_count;
}

size_t scribe_float_ring_buffer_read(
    ScribeFloatRingBuffer *buffer,
    float *destination,
    size_t count
) {
    if (buffer == NULL || destination == NULL || count == 0) {
        return 0;
    }

    uint64_t read_index = atomic_load_explicit(&buffer->read_index, memory_order_relaxed);
    uint64_t write_index = atomic_load_explicit(&buffer->write_index, memory_order_acquire);
    uint64_t available = write_index - read_index;
    size_t read_count = count < available ? count : (size_t)available;
    if (read_count == 0) {
        return 0;
    }

    size_t offset = (size_t)(read_index % buffer->capacity);
    size_t first_count = read_count < buffer->capacity - offset
        ? read_count
        : buffer->capacity - offset;
    memcpy(destination, buffer->samples + offset, first_count * sizeof(float));

    size_t second_count = read_count - first_count;
    if (second_count > 0) {
        memcpy(destination + first_count, buffer->samples, second_count * sizeof(float));
    }

    atomic_store_explicit(
        &buffer->read_index,
        read_index + read_count,
        memory_order_release
    );
    return read_count;
}

void scribe_float_ring_buffer_clear(ScribeFloatRingBuffer *buffer) {
    if (buffer == NULL) {
        return;
    }

    uint64_t write_index = atomic_load_explicit(&buffer->write_index, memory_order_acquire);
    atomic_store_explicit(&buffer->read_index, write_index, memory_order_release);
}

uint64_t scribe_float_ring_buffer_dropped_sample_count(
    const ScribeFloatRingBuffer *buffer
) {
    if (buffer == NULL) {
        return 0;
    }

    return atomic_load_explicit(
        &buffer->dropped_sample_count,
        memory_order_relaxed
    );
}
