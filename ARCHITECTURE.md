# Scribe architecture

## Module boundaries

Scribe will grow into independent modules inside one workspace:

```text
ScribeApp
  └─ ScribeUI
      ├─ AudioCapture
      ├─ SpeechPipeline
      ├─ ModelManager
      ├─ Intelligence
      └─ Persistence
```

`AudioCapture`, `SpeechPipeline`, and the app shell exist through Milestone 3.
Modules are added when their first complete behavior is implemented rather than
as empty placeholders.

`AudioCapture` currently owns canonical audio types and blocks, realtime sample transport,
microphone permission/capture/recovery, Core Audio system capture, dual-track
coordination, sample-rate conversion, and WAV persistence. It has no storage
database, model, or network dependency.

`SpeechPipeline` depends on `AudioCapture` for the canonical format, source
identity, and capture-session manifest, and on the exactly pinned FluidAudio
package for Parakeet. It owns transcription contracts, model availability and
explicit acquisition, bounded WAV chunk reads, the disk-backed live transport,
per-source Silero VAD, bounded speech-window spooling, overlap de-duplication,
engine lifecycle, timestamp mapping, result validation, and merged timeline
ordering.

## Audio path

The planned two-source path keeps microphone and system audio isolated:

```text
Microphone AVAudioEngine tap ─┐
                             ├─ dedicated preallocated ring buffer
Core Audio process-tap IOProc ┘
                                      │
                                      ▼
                           non-realtime consumer
                                      │
                         AVAudioConverter → 16 kHz
                                      │
                     ▼
              source-specific WAV
                append + sync
                     │
                     ▼
          source-indexed canonical block
                     │
                     ▼
          disk-backed live transport
                     │
                     ▼
          per-source Silero VAD
                     │
                     ▼
       30 s speech segments → overlapping
          disk-backed 14 s ASR windows
                     │
                     ▼
              later live ASR
```

The microphone callback receives noninterleaved Float32 channel pointers. A C17
routine mixes those channels directly into reserved ring slots and clamps each
sample. The callback does not allocate, lock, log, resample, access disk, or
cross onto the main actor.

Each source has a serial non-realtime consumer. That consumer drains its ring,
resamples to 16 kHz mono Float32, clamps samples to `[-1, 1]`, commits the
result to its WAV writer, and only then sends the same samples onward as a
canonical block. A live transport failure therefore cannot make already
committed recording audio invalid.

## Disk-backed live transport

`CanonicalAudioBlock` identifies its source and first source-relative sample.
The file consumer advances that index only after a successful WAV append, so
the live path can validate exact continuity without using wall-clock time.

`LiveAudioTransport` is an actor shared by both source consumers. It serializes
blocks into one append-only `LiveSpool/<source>.livepcm` file per source. Each
record contains a fixed little-endian sample-index/count header followed by
Float32 bit patterns. The actor retains counters plus at most the block being
appended or read; pending meeting audio lives on disk, not in an array-backed
queue. Per-source readers preserve ordering for the Milestone 3B VAD stage.

The actor's per-source pending count gates every read. An empty live reader is
not asked to probe the current file end before its first complete record has
been appended, avoiding a stale end-of-file position while producers and
consumers run concurrently. The speech-window spool uses the same invariant.

Pending samples drive a hysteretic state machine. The default buffering
threshold is ten seconds across both sources and recovery threshold is two
seconds. Crossing the high threshold reports **buffering to disk**; reads move
through **catching up** until the low threshold is reached. Recording proceeds
even if the optional live sink fails because each WAV is the durable source of
truth. The VAD actor drains the transient spool during recording. Both the raw
spool and its derived window spool are removed after orderly pipeline
completion.

## Live VAD and speech windows

`LiveSpeechPipeline` is an actor that round-robins the two raw spool readers.
It reframes each source into FluidAudio's 4,096-sample Silero input size and
maintains a separate `VadStreamState` for microphone and system audio. Model
preparation manually loads the compiled `MLModel` after enabling FluidAudio
offline mode; the download-capable `VadManager` convenience path is never used
during recording.

Entry probability is 0.85 and exit probability is 0.70. Scribe adds explicit
hysteresis, a 150 ms minimum speech duration, 750 ms trailing silence, and
100 ms boundary padding. Continuous speech is finalized at an exact 30-second
sample boundary even when no silence occurs.

Speech becomes at most 14-second windows. During long active speech, complete
windows are emitted as partial work before the speech boundary. Every window
after the first in a segment repeats 1.5 seconds from the preceding window, and
the tail is explicitly marked final. Windows are
serialized into one `LiveSpeechWindows/<source>.speechwindows` file per source;
the pipeline holds only its current detector frame, active segment samples,
and counters in memory.

`TranscriptOverlapDeduplicator` removes the longest matching suffix/prefix only
for adjacent segments from the same source. It uses normalized timed words when
available and a conservative normalized-token fallback otherwise.

## Live transcription

`LiveTranscriptionPipeline` owns one selected `TranscriptionEngine` and
round-robins the microphone and system window readers. Parakeet preparation,
Core ML inference, result validation, overlap removal, and row assembly remain
actor-isolated. The main actor polls immutable state and row snapshots at
250 ms intervals; it never runs inference or reads audio files.

Each source/segment pair has a stable row identity. Nonfinal windows extend its
working transcript after source-aware seam removal. The final window publishes
the same identity with `isFinal = true` and releases the working seam state.
Final rows are sorted on the shared session timeline.

Three pending windows trigger **buffering to disk**. Reads then report
**catching up** until one or fewer remain. The queue itself is the existing
per-source disk spool, so ASR lag does not grow an audio array in memory.
Scribe deliberately does not substitute a smaller model silently; if the
selected model is absent or fails, capture and VAD continue and the UI states
that live transcription is unavailable.

## Realtime ring buffer

Swift does not yet provide a deployment-compatible standard atomic primitive
for the macOS 14.4 target. The ring's indices therefore live in a small C17
implementation using C atomics. The data storage and metadata are allocated
once during initialization. Release/acquire ordering publishes written samples
to the consumer and reclaimed capacity to the producer.

The structure is single-producer, single-consumer by contract. Adding another
producer or consumer requires an external topology change, not a lock inside
the realtime data structure.

## WAV durability

`Float32WAVWriter` is an actor so all file operations are serialized and remain
off audio callbacks. It writes IEEE Float32 RIFF/WAVE at 16 kHz mono. Every
append updates and synchronizes the RIFF and data lengths, leaving the file
readable after an unexpected process exit once the append returns.

Classic RIFF WAV has a 4 GB length limit. The writer detects that boundary and
surfaces an error rather than truncating or wrapping the header fields.

## Microphone lifecycle and recovery

`MicrophoneCaptureService` is an actor that owns `AVAudioEngine` and coordinates
state transitions. Permission checks happen before the output file or audio
engine is created.

The realtime tap retains only a small sink containing the ring buffer. A
detached high-priority consumer drains that ring through actor-isolated
processing, preserving one serial `AVAudioConverter` and WAV writer.

The service observes:

- `AVAudioEngineConfigurationChange` for input-device and format changes;
- `NSWorkspace.willSleepNotification`;
- `NSWorkspace.didWakeNotification`.

Recovery stops and removes the old tap, lets already captured frames drain,
creates a converter for the new hardware rate, then reinstalls and restarts the
tap. The canonical WAV remains 16 kHz, so the same file continues across the
transition. A failed recovery finalizes all audio already written and moves the
service to an actionable failed state.

The ring counts every frame rejected because of capacity pressure. Stop results
surface this count instead of silently hiding an overrun.

## Core Audio system capture

The system track deliberately does not use `AVAudioEngine` or
ScreenCaptureKit:

1. Resolve the default output device and Scribe's Core Audio process object.
2. Create a private mono global `CATapDescription` excluding that process.
3. Create the process tap and read `kAudioTapPropertyFormat`.
4. Validate the tap as mono Float32 PCM and construct a matching
   `AVAudioFormat`.
5. Create a private aggregate with:
   - the real output device as a subdevice and main clock source;
   - zero input channels from that physical subdevice;
   - the tap UUID in an AudioSubTap dictionary;
   - drift compensation and tap autostart enabled.
6. Register `AudioDeviceCreateIOProcIDWithBlock` directly on the aggregate,
   passing a `nil` queue so Core Audio invokes it directly.
7. Start the aggregate with `AudioDeviceStart`.

The IOProc passes its `AudioBufferList` to a C17 mixer that handles interleaved
or noninterleaved Float32 buffers and writes mono samples directly into the
system ring. It does not construct `AVAudioPCMBuffer`, allocate, resample, log,
lock, or write to disk.

Teardown always attempts, in order: device stop, IOProc destruction, aggregate
destruction, and process-tap destruction. Every failing `OSStatus` is retained
and surfaced rather than hiding later cleanup failures.

System recovery listens for default output changes, aggregate liveness, tap
format changes, Core Audio service restarts, sleep, and wake. It removes the
old graph, drains samples captured at the old rate, creates a fresh graph for
the current output, replaces the resampler, and continues the same
`system.wav`.

## Dual-track coordination

`DualTrackRecordingCoordinator` depends on the common `AudioTrackCapturing`
protocol, allowing deterministic mocks without requesting TCC permission or
touching hardware.

It starts the microphone first so Scribe is registered as a Core Audio process
before the global tap resolves and excludes it. The system track starts second.
If system capture fails, the already-running microphone is stopped and
finalized. Stop always attempts both sources even if the first reports an
error.

## Permission model

AVFoundation exposes the microphone's current TCC state and an asynchronous
request API. The app can therefore distinguish not determined, authorized,
denied, and policy-restricted microphone access before constructing a capture
pipeline.

Core Audio process taps expose no public equivalent to that preflight API.
Permission is evaluated when an aggregate containing the tap starts. The
first-run screen uses the same production graph in an all-process,
permission-probe mode: it starts the graph only long enough to receive the
authorization result, discards ring contents, tears down every Core Audio
object, and creates no WAV. Production recording uses the self-excluding graph.

`SystemAudioPermissionAuthorizer` stores only the last status observed from a
real probe or recording attempt. It never claims that this cached value is a
live TCC query. A later permission error replaces the cached state with denied
and returns the UI to setup. The Settings routes target `Privacy_Microphone`
and `Privacy_AudioCapture`, keeping microphone and audio-only system capture
guidance separate.

The app view model polls both capture actors while a session is active. This
keeps device-change, sleep/wake, and tap-rebuild states visible per track even
though capture and recovery remain off the main actor.

## Capture session timeline

The microphone must start before the system tap so Core Audio can resolve and
exclude Scribe's process. As a result, the two WAV files do not begin at exactly
the same wall-clock instant.

`DualTrackRecordingCoordinator` records a `ContinuousClock` instant as soon as
microphone startup succeeds. The microphone track begins at offset zero. After
system capture successfully starts, its offset is the monotonic duration between
those two activation completions. Once both tracks are active, the coordinator
atomically writes `capture-session.json`. Failure to persist that metadata stops
and finalizes both tracks rather than leaving an unalignable recording active.

The manifest is versioned, validates exactly one relative path per source, and
rejects traversal paths, negative times, non-finite times, and noncanonical
format declarations.

## Batch speech pipeline

```text
capture-session.json
        │
        ├── microphone.wav ── bounded 14 s reader ─┐
        │                                          ├─ earliest chunk first
        └── system.wav ────── bounded 14 s reader ─┘
                                                        │
                                               TranscriptionEngine
                                                        │
                                          validate timing + source
                                                        │
                                         deterministic timeline merge
```

`CanonicalWAVChunkReader` is an actor owning one `AVAudioFile`. It accepts only
16 kHz mono Float32 files and copies at most one configured chunk into memory.
The default is 14 seconds, below Parakeet's approximately 15-second batch
window. Fixed chunks deliberately have no overlap in Milestone 2A; VAD,
overlap, and seam de-duplication belong to Milestone 3.

`BatchTranscriptionPipeline` prepares one injected engine, requests chunks in
shared-session order, validates every returned segment, appends `finish()`
output, and always calls `unload()` after success or failure. Engine mocks can
therefore exercise the entire pipeline without loading Core ML or touching the
network.

## Parakeet model and inference boundary

```text
explicit Download Model click
            │
            ▼
ParakeetModelStore ── network allowed ── FluidAudio download/compile
            │
            ▼
~/Library/Application Support/Scribe/Models/<model repo>/
            │
      complete-cache check
            │
            ▼
ParakeetTranscriptionEngine.prepare()
            │
     FluidAudio offline mode = true
            │
            ▼
AsrModels.load → AsrManager → local Core ML inference
```

`ParakeetModelStore` is the only type that disables FluidAudio's offline guard,
and it does so only inside its explicit `download` operation. Engine
preparation first checks that all compiled models and vocabulary files exist.
An incomplete cache produces an actionable missing-model error before any
loader is invoked. Preparation then enables FluidAudio offline mode, loads the
selected v3 INT8 or v2 model, and creates an actor-isolated `AsrManager`.

Each batch call gets a fresh two-layer TDT decoder state. A final audio fragment
shorter than FluidAudio's 300 ms input minimum is zero-padded for inference,
while all result timestamps remain clamped to the original unpadded chunk.
FluidAudio token timings are aggregated into words and shifted by the chunk's
shared-session start offset. One transcript segment is emitted per nonempty
batch chunk; Milestone 3 will replace fixed seams with VAD-aware boundaries and
overlap de-duplication.

The production backend is hidden behind a `Sendable` adapter protocol. Unit
tests verify lifecycle and timestamp mapping without Core ML. The opt-in golden
test requires an already-installed model and caller-supplied known WAV, so the
default test suite cannot acquire models or touch the network.

## Concurrency

All targets use Swift 6 language mode and complete strict concurrency checking.
The C-backed ring buffer is marked `@unchecked Sendable` only because its
thread-safety invariant is enforced by its atomic SPSC implementation. The
resampler is deliberately not `Sendable`; a serial consumer owns each instance.
The file-spool implementation is also `@unchecked Sendable`, but only the
`LiveAudioTransport` actor owns and invokes it, so its file handles and read
offset are never accessed concurrently. The speech-window spool has the same
single-actor ownership invariant under `LiveSpeechPipeline`. Silero model
loading, recurrent state, segmentation, and disk I/O remain outside the main
actor; the app polls only small state values for display.
