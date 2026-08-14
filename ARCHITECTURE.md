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

`AudioCapture`, `SpeechPipeline`, `ModelManager`, and the app shell now exist.
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

`ModelManager` is dependency-free and owns validated, engine-neutral model
identity, catalogue metadata, and the canonical Application Support model
layout. The built-in catalogue describes Parakeet v3/v2, Silero, and twelve
verified Whisper variants, including provider, task, language coverage,
safe installation folder, transcription geometry,
parameter/quantization/speed labels, and evidence-backed disk/RAM requirements.
Whisper declares exact 30-second windows with 1.5-second overlap; Parakeet keeps
its 14-second geometry. `ManagedModelRegistry` owns provider-neutral
availability, disk accounting, resource evaluation, and acquisition state.
Provider adapters in `SpeechPipeline` supply SDK-specific validation and
transport behavior without moving those policies into the SDKs.

Model acquisition is split into policy and provider transport.
`ModelDownloadController` owns per-model state, staging below `.Downloads`,
pause/resume tokens, cancellation cleanup, streamed integrity verification, and
promotion into the final installation folder only after verification succeeds.
Provider adapters implement `ModelDownloadTransport`; this keeps FluidAudio and
future WhisperKit network APIs outside the manager's policy layer.
`ModelIntegrityVerifier` reads artifacts in bounded chunks, validates exact byte
counts and SHA-256 digests, and rejects missing files, traversal, duplicate
manifest entries, and symlinks resolving outside the staged installation.
`HuggingFaceIntegrityManifestResolver` reads official tree metadata before
transfer. It uses LFS SHA-256 values directly and downloads regular Git files
below Hugging Face's 10 MiB large-file boundary to calculate their SHA-256. A
source change between manifest resolution and transfer fails verification
rather than promoting mismatched files.

`Intelligence` owns the network provider boundary for summary generation. Its
public
`IntelligenceProvider` contract exposes model discovery and streamed text
completion. `OpenAICompatibleProvider` implements the configurable
`/models` plus `/chat/completions` convention used by OpenAI, DeepSeek, Groq,
Ollama, LM Studio, and custom compatible endpoints. `AnthropicProvider`
separately implements Anthropic's `/models` and Messages streaming shapes.
Adding another compatible vendor is therefore configuration, not another HTTP
client.

Provider presets and custom entries contain only non-secret configuration.
Remote custom URLs require HTTPS, loopback URLs may use HTTP, and embedded URL
credentials, queries, and fragments are rejected. Keys are generic-password
Keychain items indexed by provider ID. `ProviderCredential` is deliberately not
Codable and prints only a redacted marker; the HTTP layer discards failure
bodies and reports status-only errors so a provider cannot reflect a secret
into app diagnostics. UserDefaults persists selection and custom endpoint
metadata, never credentials. The connection test performs model discovery,
which validates endpoint and authentication without sending meeting content.

Summary templates are owned by `SessionStore` because GRDB and application
data persistence already terminate at that module. They deliberately do not
share `sessions.sqlite`: the session index is a rebuildable filesystem
projection, while template edits are original user data. A dedicated
`Data/templates.sqlite` database stores stable IDs, names, instruction bodies,
built-in identity, ordering, and timestamps.

On every open, the template store inserts missing built-ins without updating
existing rows. This lets releases add defaults while preserving any edit to a
shipped template. Custom templates are independently creatable, duplicable,
editable, and removable; built-ins are editable and duplicable but protected
from deletion. `SummaryTemplateRenderer` substitutes only the six declared
context variables and rejects unknown or malformed placeholders.

`SessionStore` owns single-pass orchestration. It derives template context from
authoritative session artifacts, including a short transcript neighborhood
around each pin; estimates prompt size; enforces a model-policy context
allowance before sending; consumes the provider stream; and commits output only
after successful completion. The UI owns cloud consent: loopback destinations
need no dialog, while every non-loopback destination is named in a confirmation
before transcript or notes leave the Mac.

`SummaryArtifactWriter` writes a provenance header plus result to both current
`summary.md` and a unique `Summaries/` revision. It then asks the shared
`CaptureSessionManifestStore` actor to reload and append structured provenance,
so summary writes cannot restore stale pins, track timing, speaker names, or
transcription history. Streaming state is memory-only; provider failure cannot
expose a partial summary as a durable artifact. Part 1 rejects inputs beyond one
context before the completion call. Time-based map-reduce is the remaining
Phase 2 Part 2 boundary.

`ModelDiskAccounting` recursively measures actual installed logical and
allocated bytes while refusing to follow symbolic links.
`ManagedModelRegistry` also scans direct child folders that match neither a
catalogue installation nor the internal `.Downloads` staging area. These
unrecognized folders are measured, included in the UI's total, and movable to
macOS Trash only through a confirmation-protected exact-child operation that
rechecks path and symlink safety. Managed transcription models and Silero VAD
use the same recoverable removal path.
`ModelResourceSafetyEvaluator` can compare evidence-backed download, installed,
and peak-memory requirements with current disk capacity and physical memory.
Unknown requirements and unavailable capacity produce a denied evaluation.
Resource profiles must cite either a local measurement or a primary upstream
source; parameter-count estimates are not accepted as operational safety data.

## Audio path

The planned two-source path keeps microphone and system audio isolated:

```text
Microphone AVAudioEngine tap ── dedicated preallocated ring buffer
Core Audio process-tap IOProc ─ attachable ring allocated at Record
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
    engine-aware speech segments → overlapping
       engine-selected disk-backed ASR windows
        (14 s Parakeet / 30 s Whisper)
                     │
                     ▼
            selected live ASR
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
100 ms boundary padding. The continuous-speech ceiling has a 30-second baseline
and is raised, when necessary, to the selected engine's window plus overlap so
that every live-capable window geometry can emit a partial before finalization.
It remains 30 seconds for Parakeet and becomes 31.5 seconds for Whisper.

Speech is divided with the selected engine's declared geometry: 14-second
windows for Parakeet and 30-second windows for Whisper, currently with a
1.5-second overlap for both. During long active speech, complete windows are
emitted as partial work once one window plus its overlap is available. Whisper's
30-second window therefore emits as a nonfinal partial after 31.5 seconds of
continuous speech, immediately followed by the overlapping final tail at the
same engine-derived hard boundary. Every window after the first in a segment
repeats the selected overlap from the preceding window, and the tail is
explicitly marked final. Windows are serialized into one
`LiveSpeechWindows/<source>.speechwindows` file per source; the pipeline holds
only its current detector frame, active segment samples, and counters in memory.

A hard ceiling starts a new technical speech segment and row, but its first
window reaches back by the selected engine's overlap. The prior finalized seam
is retained per source. When that continuation produces timed words, its more
complete rendering replaces only the preceding row's overlap tail; the prior
row keeps its stable ID, timeline position, and final status. The transcript UI
must therefore allow the last few words of a final row to be corrected once.
Ordinary partial windows within one row retain the earlier rendering and do not
rewrite already accepted text.

`TranscriptOverlapDeduplicator` operates only on adjacent segments from the
same source. With word timings, it removes words whose starts fall inside the
already-emitted time range; a 250 ms seam tolerance removes an exact or strongly
prefix-related boundary rendering when ASR timestamps jitter across the range
edge. Untimed output uses normalized suffix/prefix matching and tolerates one
mismatched final token only after two exact anchor tokens.

Timed-word arrays have one module-wide invariant: consumers order them by
absolute start time, then end time. Both engine adapters normalize at their
mapping boundary; the ordinary and later-window overlap paths normalize before
trimming; and live row assembly normalizes before deriving row bounds. Segment
and row start/end values therefore come from the earliest and latest timed word,
not provider array position.

The Parakeet golden regression shifts a production-sized 14-second/1.5-second
window grid so a seam crosses each whole-second fixture position from 2 through
18 seconds. It records substitutions, insertions, and deletions independently at
125, 250, and 500 ms seam tolerances. Batch stitching prefers the later
window's more complete overlap rendering. A previous-window word is retained
only when its complete time span ends before the replacement threshold; a word
that straddles the seam is replaced by the later rendering. The production path
has a 0.06 WER ceiling derived from the observed 0.0392 worst case plus one
reference-word edit; all three tolerances produced the same worst case, and any
deletion fails the sweep regardless of total WER.

## Live transcription

`LiveTranscriptionPipeline` owns one selected `TranscriptionEngine` and
round-robins the microphone and system window readers. Selected-engine
preparation, local inference, result validation, overlap removal, and row
assembly remain actor-isolated. The main actor polls immutable state and row
snapshots at 250 ms intervals; it never runs inference or reads audio files.

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

After successful drain, final live rows pass through the same
`TranscriptArtifactWriter` as batch results. It replaces the current
`transcript.md`, `transcript.json`, and `transcript.srt`, creates an immutable
revision under `Transcriptions`, and updates both the manifest artifact list and
`transcriptionHistory`. A successful zero-row run still records that empty
revision; failed or partial live output is not presented as a completed durable
transcript, and the captured audio remains available for batch re-transcription.

## Speaker identity and paragraph boundaries

Speaker identity belongs to `session.json`, not to a particular transcription
revision. A stable string ID, source, optional display name, and name-assignment
provenance form the registry. Old manifests derive deterministic source IDs while
loading, and the registry permits more than one identity per source so later
diarization does not require a storage migration. A rename atomically changes
only session metadata; subsequent renders resolve the same transcript speaker ID
through the updated registry.

`TranscriptParagrapher` is the single paragraph-boundary implementation for
`transcript.md` and the live and reading views. It first sorts segments and word
timings on the absolute session timeline. A sentence ending followed by a pause
greater than 400 ms ends a paragraph. If a paragraph would exceed 45 seconds, it
ends at the latest sentence ending in that span, or at the largest word gap when
no sentence ending exists. Source and speaker changes always flush the current
paragraph. Untimed segments, or timed words that cannot faithfully reconstruct
the engine's text, pass through unchanged; display structure must never alter
the durable transcript wording.

## Realtime ring buffer

Swift does not yet provide a deployment-compatible standard atomic primitive
for the macOS 26 target. The ring's indices therefore live in a small C17
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

Before reading the input format or installing the tap, the service resolves
`kAudioHardwarePropertyDefaultInputDevice`, binds that concrete device to the
input node's AUHAL with `kAudioOutputUnitProperty_CurrentDevice`, and reads the
property back. A mismatched binding or a route resolving to Scribe's private
system-tap aggregate fails closed instead of risking two copies of system audio.
Only after the verified binding does it read `inputNode.inputFormat(forBus:)`;
that exact format is installed on the tap, including Bluetooth headset rates
below 48 kHz. The bound device, sample rate, channel count, timestamp, and
change reason are stored in `session.json` as
`microphoneInputRouteChanges`, while `microphoneInputDevice` remains the latest
device for compatibility.

The realtime tap retains only a small sink containing the ring buffer. A
detached high-priority consumer drains that ring through actor-isolated
processing, preserving one serial `AVAudioConverter` and WAV writer.

The service observes:

- `AVAudioEngineConfigurationChange` for input-device and format changes;
- `NSWorkspace.willSleepNotification`;
- `NSWorkspace.didWakeNotification`.

Notifications alone are not sufficient. A Bluetooth input reports a complete,
self-consistent format while it is still switching into headset mode, and a tap
installed against that transient format delivers nothing once the route
settles, with `AVAudioEngine.isRunning` still true and no notification or error
raised. The service therefore also watches evidence rather than properties: the
realtime sink adds every accepted frame to a lock-free atomic counter, and a
watchdog polls it against `MicrophoneLivenessPolicy`. A tap that delivers
nothing past its grace period is rebuilt through the same route-recovery path
under the `captureDeliveredNoAudio` reason; consecutive rebuilds beyond the
budget fail the recording instead of retrying forever. Because a working input
delivers frames even in a silent room, an absence of frames is unambiguously a
fault and the watchdog never inspects signal level.

Zero captured frames is reported, not hidden. `AudioTrackCaptureResult` carries
`capturedSampleCount`, and the dual-track coordinator fails a stop whose
microphone track captured nothing, after both WAVs and the session metadata are
finalized so no captured audio is discarded by the failure. The same rule is
deliberately not applied to the system track: a meeting where the remote side
never speaks is a valid recording.

Recovery stops and removes the old tap, lets already captured frames drain,
binds the current concrete device, reads its new input format, creates a
converter for that rate, then reinstalls and restarts the tap. Transient route
settling after a Bluetooth rate switch or disconnect is retried for up to three
seconds. The canonical WAV remains 16 kHz, so the same file continues across
the transition. A failed recovery finalizes all audio already written and moves
the service to an actionable failed state.

The ring counts every frame rejected because of capacity pressure. Stop results
surface this count instead of silently hiding an overrun.

## Core Audio system capture

The system track deliberately does not use `AVAudioEngine` or
ScreenCaptureKit. At launch, concurrently with ordinary app initialization,
Scribe prewarms the non-recording portion of the graph:

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
7. Hold the registered IOProc without calling `AudioDeviceStart`.

The prepared IOProc points at a lock-free atomic routing slot. While idle the
slot is empty: no 7.32 MiB ring, first-sample latch, consumer, or WAV writer
exists. Pressing Record allocates those recording resources, publishes the
realtime sink into the slot, and then calls `AudioDeviceStart`. A clean stop
calls `AudioDeviceStop`, clears and releases the sink, and retains the unstarted
graph for the next recording.

Launch prewarming and an immediate Record request enter one single-flight
preparation gate. If preparation is still running, Record awaits that exact
operation; it cannot construct a competing graph. The UI remains responsive
and displays the preparing state because the cold Core Audio work runs outside
the capture actor. Each live `session.json` stores
`systemAudioGraphPreparation` as `prewarmed` or `builtAtRecordingStart` rather
than asking diagnostics to infer provenance from timing.

The IOProc passes its `AudioBufferList` to a C17 mixer that handles interleaved
or noninterleaved Float32 buffers and writes mono samples directly into the
system ring. It does not construct `AVAudioPCMBuffer`, allocate, resample, log,
lock, or write to disk.

Full invalidation always attempts, in order: device stop, IOProc destruction,
aggregate destruction, and process-tap destruction. It occurs before sleep, on
default-output or tap-format change, aggregate death, and after a Core Audio
service restart. Wake and live route recovery construct a fresh graph. Every
failing `OSStatus` is retained and surfaced rather than hiding later cleanup
failures.

System recovery listens for default output changes, aggregate liveness, tap
format changes, Core Audio service restarts, sleep, and wake. It removes the
old graph, drains samples captured at the old rate, creates a fresh graph for
the current output, replaces the resampler, and continues the same
`system.wav`.

## Dual-track coordination

`DualTrackRecordingCoordinator` depends on the common `AudioTrackCapturing`
protocol, allowing deterministic mocks without requesting TCC permission or
touching hardware.

The self-excluding system graph is already prepared before Record. The
coordinator starts its device first, then starts the microphone, so slow graph
preparation costs launch latency instead of missing remote speech. If system
capture fails, microphone capture never starts. Stop always attempts both
sources even if the first reports an error.

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

The prepared tap already excludes Scribe's resolved Core Audio process. After
`AudioDeviceStart`, the system and microphone callbacks can arrive in either
order, so the two WAV files do not begin at exactly the same wall-clock instant.

Each realtime callback latches its first successfully accepted frame exactly
once through a lock-free C atomic. The microphone uses the tap's valid
`AVAudioTime.hostTime`; the system IOProc uses `inInputTime.mHostTime`, which is
the acquisition time of the first input frame rather than the scheduling time in
`inNow`. On stop, the coordinator converts the host-tick delta through
`mach_timebase_info`, rounds it to the nearest canonical 16 kHz sample, and
atomically updates `session.json`. A track that captured no sample keeps an
explicit unavailable offset rather than an invented activation proxy.

The manifest is versioned, validates exactly one relative path per source, and
rejects traversal paths, negative times, non-finite times, and noncanonical
format declarations.

## Batch speech pipeline

```text
session.json
        │
        ├── microphone.wav ── engine-sized reader ─┐
        │                                          ├─ earliest chunk first
        └── system.wav ────── engine-sized reader ─┘
                                                        │
                                               TranscriptionEngine
                                                        │
                                          validate timing + source
                                                        │
                                         deterministic timeline merge
```

`CanonicalWAVChunkReader` is an actor owning one `AVAudioFile`. It accepts
Scribe's 16 kHz mono Int16 durable files and legacy Float32 sessions, converting
to canonical Float32 samples on bounded reads. Chunk duration and overlap come
from the selected engine: Parakeet requests 14/1.5 seconds and Whisper requests
30/1.5 seconds. Batch and live paths reuse the same source-aware overlap
de-duplicator so engine changes cannot silently reintroduce seam word loss.

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
FluidAudioModelManager
    │
    ├── official manifest + shared staged lifecycle
    └── network allowed ── FluidAudio download/compile
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

`FluidAudioModelManager` is the only application type that disables
FluidAudio's offline guard, and it does so only inside explicit install or
resume operations. Parakeet and Silero use the same registry, download state,
staging, pause/cancel cleanup, checksum pass, and atomic promotion. Pausing
FluidAudio cancels the active file request but retains completed staged files;
resume asks FluidAudio to skip complete files and continue the remainder. Engine
preparation first checks that all compiled models and vocabulary files exist.
An incomplete cache produces an actionable missing-model error before any
loader is invoked. Preparation then enables FluidAudio offline mode, loads the
selected v3 INT8 or v2 model, and creates an actor-isolated `AsrManager`.

Each batch call gets a fresh two-layer TDT decoder state. A final audio fragment
shorter than FluidAudio's 300 ms input minimum is zero-padded for inference,
while all result timestamps remain clamped to the original unpadded chunk.
FluidAudio token timings are aggregated into words and shifted by the chunk's
shared-session start offset. One transcript segment is emitted per nonempty
batch chunk; overlapping windows and the shared seam de-duplicator retain
speech across chunk boundaries.

The production backend is hidden behind a `Sendable` adapter protocol. Unit
tests verify lifecycle and timestamp mapping without Core ML. The committed
golden fixture runs automatically when its model is already installed and skips
with the missing model's name otherwise; the suite never acquires a model or
touches the network.

## Whisper catalogue and inference boundary

SpeechPipeline links only the individual `WhisperKit` library product from the
exactly pinned `argmax-oss-swift` 1.0.0 package. `WhisperKitModelManager`
projects exact artifact trees from Argmax's official `whisperkit-coreml`
repository into one manager-owned installation folder and adds the corresponding
OpenAI tokenizer files. Downloads are explicit, staged, file-resumable, and
SHA-256/size verified before promotion. Ordinary tests and inference never
download.

`WhisperKitTranscriptionEngine` accepts one exact `WhisperModel`; a missing or
failed model is named and never replaced. Preparation validates and parses the
local tokenizer first, constructs WhisperKit with download disabled, then lets
`loadModels()` detect vocabulary/encoder shape and multilingual state before it
loads that same local tokenizer. This order is required: preassigning a tokenizer
causes WhisperKit to skip model-shape detection. Multilingual models use local
language detection; English-only Tiny and Distil variants use English prefill.
All variants request word timestamps and map returned words/segments into the
engine-neutral transcript contract.

The catalogue exposes standard Tiny, Tiny English, Base, Small, Medium, Large
v3, the 2024 Large v3 Turbo architecture, Distil Large v3, and four explicit
compressed/Argmax-optimized variants. `_turbo` in Argmax folder names means a
streaming optimization, while `_*MB` names compressed weights; neither label is
silently inferred. Every exposed entry has a committed WER limit and measured
installed-byte/first-load peak-RSS profile. The committed clean synthetic fixture
is a regression guard, not evidence of noisy-meeting accuracy.

## Imported-media pipeline

An import is a single-source session. `SessionMediaImporter` reserves a normal
human-readable session folder, copies the source without modification, and asks
`ImportedMediaConverter` to stream the first AVFoundation audio track into
canonical `audio.wav`. The decoder requests 16 kHz mono Float32 sample buffers;
the existing `Int16WAVWriter` performs the sole durable quantization and keeps
the RIFF header synchronized. Neither conversion nor batch ASR retains the full
asset in memory.

The manifest uses `source=importedFile`, one `.imported` track at sample offset
zero, and distinct `.originalImport` and `.audio` artifacts. Validation remains
source-specific: live sessions require microphone plus system, while imports
require exactly one imported track. Live transport, VAD, and live-ASR loops use
`AudioSource.liveCaptureSources`, so adding `.imported` cannot accidentally
create a third live spool or detector state.

`BatchTranscriptionPipeline` constructs readers from the validated manifest's
actual tracks instead of assuming a microphone/system tuple. Imported segments
remain `.imported` through overlap reconciliation, timeline merge, JSON, and
SRT. Markdown and UI renderers deliberately omit a participant label for that
source. The copied original is retained even after a later transcription
failure; conversion failures remove the incomplete session folder and never
modify the external source.

## Single-resident transcription engine

`ResidentTranscriptionEngineCoordinator` owns the only prepared ASR engine in
the process. `CoordinatedTranscriptionEngine` preserves the existing engine
contract for batch/live pipelines while routing prepare, transcribe, finish, and
unload through a generation-stamped lease. Preparing a different engine unloads
the resident engine first. A stale wrapper cannot transcribe through or unload
the replacement, but it can later prepare again to switch back.

Inference is exclusive. A switch attempted while a transcribe/finish call is in
flight fails with the exact resident identifier instead of unloading Core ML
mid-call. An unload requested during inference waits for that call and then
releases the model. Loading and unloading transitions reject overlapping model
changes. If replacement preparation fails, the failing engine is unloaded, no
engine remains resident, and the coordinator records its identifier and original
error text; it never restores or substitutes the previous model silently.

## Catalogue-driven model UI

`TranscriptionModelSelection` is the exact UI-to-provider mapping for the two
Parakeet and twelve verified Whisper entries. The same selection creates batch
and live engines, so SwiftUI cannot select one model while a pipeline prepares
another. The saved default is captured when recording starts.

`MeetingRecorderViewModel` projects both provider managers into one availability,
download-progress, pause/resume/cancel, disk-accounting, and resource-safety
surface. It evaluates disk before a measured model install and the safe physical-
RAM budget before load. Installed and invalid exact folders can be removed only
while recording and inference are idle. Total usage is summed from files actually
on disk, including Silero. A missing or failed selection can expose the closest
smaller installed measured model, but selection changes only after an explicit
user action; no fallback is automatic.

Switching verification has two layers. Deterministic mocks assert exact
prepare/transcribe/unload order across three identities. A real-model regression
keeps one coordinator alive while replacing Parakeet v3 with Whisper Tiny,
Small, and Medium and transcribing the same committed audio after every switch.
The final unload returns the coordinator to idle; missing models cause an
explicit skip rather than acquisition or substitution.

## Recording workspace presentation

`ScribeShellView` is the persistent window owner. A bounded, collapsible native
sidebar contains the recording/import split action, real index-derived smart
folders, Finder-backed manual folders, and Settings. The detail column owns the
search header and switches among library, recording, and settings content
without starting, stopping, or replacing capture actors. The root drop target
keeps imported media independent of the currently displayed detail pane.

When capture is starting, running, or stopping, the sidebar's split action is
replaced in place by elapsed time, both Silero meters, and Stop. Selecting other
sidebar destinations changes only presentation, so the capture control remains
visible while browsing. The former floating control and the notes editor's
reserved bottom gutter were deleted; recording chrome no longer overlays the
content surface.

`RecordingWorkspaceView` remains the recording detail. Its notes editor writes
plain UTF-8 Markdown to the active session's existing `notes.md`; AppKit
attributes highlight syntax without changing the stored string.
Revision-stamped atomic writes serialize rapid edits, and stop—including an
automatic low-disk stop—flushes the latest text.

The notes/transcript split defaults to roughly 60/40, persists the transcript
width and collapsed state, and clamps resizing so both panes remain usable.
Transcript paragraph presentation is cached only when `LiveTranscriptRow`
changes. Notes keystrokes therefore update their own published text and atomic
writer without rerunning paragraph construction on the main actor.

The transcript rail projects `LiveTranscriptRow` values through the shared
`TranscriptParagrapher`. Paragraphs may span engine windows and are therefore
independent of whether a source produced 12-second or 30-second blocks. Stable
live-row-derived identities keep partial rows in place while final tail text is
rewritten. Speaker colors use a stable identifier hash over an eight-color
palette rather than assuming exactly two future speakers.

`LiveSpeechPipelineMetrics` retains only the latest Silero speech probability
for each live source. The workspace polls those small values with the existing
pipeline state, so the You/Others meters remain independent of ASR availability
or backpressure. The first-text estimate comes from the selected engine's
window duration plus overlap; no Parakeet-specific delay is embedded in the
view. Preparing, buffering, catch-up, missing-model, missing-Silero, load
failure, and quiet-system states are pure presentation projections whose copy
lives in `ScribeCopy` and `scribe-copy.md`.

Capture notices and transcription notices are separate projections. Preparing
system audio, buffering, catch-up, and a silent system track render in the
persistent sidebar control. Engine waiting, missing model, failed model, and
missing Silero render in the transcript rail, so simultaneous capture and ASR
conditions cannot hide one another.

During recording, a Carbon application-global Command-Shift-K registration
captures a pin even when Scribe has no focused window. It is registered only
while capture is active, requires no Accessibility permission, and is released
before stopping so it does not consume the shortcut at other times. The key
event's mach host time is mapped from the earliest first-sample host timestamp
to a canonical sample offset. `session.json` version 4 stores the pin UUID,
sample offset, optional label, and creation date. A shared manifest actor
serializes every ordinary in-place mutation: pins, final track offsets, artifact
inventory, duplicate identity repair, speaker and session renames, and the
compound current-transcript plus revision-history commit. Every operation
reloads the latest manifest inside the actor before writing only its owned
fields, so reconciliation cannot restore a stale snapshot over later user data.
Creation and one-time legacy conversion are the only direct manifest writes
because no current manifest is being mutated. A missing first-sample timestamp
is a valid unavailable track offset and does not block the actor. Pin success
appears only after the atomic manifest write returns; a write failure appears
in the same sidebar status position instead of showing a success confirmation.

## Session folders and shell index projections

`SessionReconciler` discovers session manifests recursively beneath the save
location and stops traversal at each session boundary. A top-level directory
without a manifest is therefore a manual folder, while a directory containing
`session.json` remains a session. Hidden directories, aliases, symlinks, and
packages are never traversed. `SessionManualFolderManager` creates top-level
folders and moves complete session directories into them; the embedded UUID
remains identity and the next reconciliation updates the incidental path.

The SQLite derivative computes All sessions, Needs summary, and Imported counts
from indexed sessions, artifact kinds, and manifest source. No UI category is
inferred from titles or filenames. The index keeps the Needs summary projection
ready, but the shell capability-gates that destination until summary generation
exists; a previously persisted selection resolves safely to All sessions while
the capability is off. Sidebar visibility and selection use stable UserDefaults
keys; session and folder data remain filesystem-owned.

The library projects each indexed UUID back through its authoritative manifest
and canonical WAV headers. Sessions are grouped by local calendar day and then
creation time, newest first. Duration is the maximum track end after applying
its canonical start-sample offset; speaker count comes from the manifest's
stable identity registry. Four independent presence flags drive meaningful
notes, transcript, summary, and audio icons, with immutable transcription
revisions excluded from the current-transcript flag.

FTS5 selects sessions from notes and current transcript text. Result
presentation then reads matching transcript segments so hits stay grouped under
their session and carry real segment timecodes. Notes are searchable but have
no temporal mapping, so their hits are labelled Notes rather than being given
an invented timestamp. A search-hit navigation value preserves the session UUID
and optional seek time for the Phase D reading view.

Renaming moves the complete session folder within its current parent and then
updates the title through the manifest actor, rolling the move back if metadata
cannot be committed. Deletion uses the system Trash and confirms the measured
size of the complete folder; it never unlinks session data directly.

## Session reading projection and playback

`SessionReadingPresentation` derives the detail view entirely from a session
folder and its manifest. It orders the artifact rail by notes, current
transcript, summary, audio, additional files, and immutable transcription
revisions, then chooses the most substantive present artifact without creating
placeholder files. Transcript paragraphs are projected from timed words and
remain independent of whether their source blocks came from 26–30-second live
VAD segments or 12–13-second batch strides.

The playback controller maps every track through its signed canonical sample
offset. Timeline regions, pins, paragraph highlighting, seeking, and talk-time
totals share the session timeline; no source is assumed to begin first.
Imported audio therefore appears as one lane, while live sessions retain You
and Others. Speaker renames update stable identities through the manifest actor
and remain valid when a later transcription replaces the current artifacts.

The empty reader is the only decorative color surface. A 104-by-17 monospace
character field draws separate violet and teal waveforms; its timeline pauses
whenever the window is not key and is fixed under Reduce Motion. All other
reader surfaces and actions use system-neutral materials and controls.

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
