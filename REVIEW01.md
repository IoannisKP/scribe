# Scribe implementation review 01

**Review date:** 1 August 2026  
**Scope:** Milestones 1 through 3  
**Milestone 4 status:** Not started  
**Workspace:** `/Users/ioanniskoupidis/Desktop/Transcription app`

## Executive summary

Scribe currently has a credible local-first foundation for two-source meeting
capture, offline batch transcription, and bounded live transcription on Apple
Silicon. Milestones 1 through 3 are implemented in code. The automated suite is
green under Swift 6, and the arm64 Debug and Release app configurations build
without project warnings.

The strongest parts of the implementation are the realtime audio boundary,
source separation, monotonic two-track timeline, fail-closed validation, and
disk-backed live pipeline. The architecture consistently treats the WAV files
as the durable source of truth and treats VAD and ASR as optional consumers that
must not invalidate a recording.

The project is not yet a production-complete meeting application. The remaining
manual acceptance work for Milestones 1 through 3 requires real permissions,
audio hardware, device changes, and downloaded Silero/Parakeet models. Live and
batch transcripts are not persisted in a database, downloaded model management
is still Parakeet/Silero-specific, and crash recovery has not yet been built.
Those gaps belong primarily to Milestones 4, 5, and 8.

### Overall assessment

| Area | Assessment |
|---|---|
| Architecture | Sound foundation with clear actor and module boundaries |
| Realtime safety | Deliberately designed and covered by deterministic tests |
| Source attribution | Preserved end-to-end rather than inferred after mixing |
| Offline behavior | Explicit acquisition, offline inference, no silent fallback |
| Memory behavior | Bounded by ring buffers, fixed chunks, and disk spools |
| Disk behavior | Predictable but potentially large during long recordings |
| Automated verification | 61 tests, 0 failures, 1 intentional real-model skip |
| Hardware/model acceptance | Still manual and not yet recorded as completed |
| Persistence and recovery | WAV durability exists; transcript/session recovery does not |
| Readiness for Milestone 4 | Ready, with model-store consolidation needed first |

## Review basis

This review used the current source tree, package manifests, Xcode build
settings, tests, README, architecture document, and technical decision log.
The following verification was rerun on 1 August 2026:

```text
swift test
  61 tests executed
  0 failures
  1 skipped opt-in Parakeet Core ML golden test

xcodebuild -quiet ... Debug ... arm64 build
  succeeded with no output warnings

xcodebuild -quiet ... Release ... arm64 build
  succeeded with no output warnings
```

Swift Package Manager currently emits one planning warning from FluidAudio
0.15.5 because that dependency contains an unhandled `benchmark.md` file. The
warning is in the pinned third-party package, not Scribe source. Scribe does not
patch dependency checkouts because those files are disposable and would be
restored by package resolution.

## Current project shape

The implemented targets are intentionally fewer than the final planned module
map. Modules are created only when they own working behavior.

```text
ScribeApp
  ├── SwiftUI application and view model
  ├── AudioCapture
  │   └── CAudioRingBuffer
  └── SpeechPipeline
      └── FluidAudio 0.15.5
```

Implemented code and tests total approximately 11,700 lines. The actual source,
tests, project metadata, and documentation occupy less than 1 MB. The current
2.8 GB project-directory footprint is almost entirely `.build` output and
historical derived-data folders, not application code.

Planned modules not yet created are `ModelManager`, `Persistence`,
`Intelligence`, and a separate `ScribeUI` target. Their absence is intentional
at this milestone boundary.

## End-to-end architecture

The live path is:

```text
microphone AVAudioEngine                 Core Audio process tap
          │                                      │
          ▼                                      ▼
preallocated SPSC ring buffer        preallocated SPSC ring buffer
          │                                      │
          └──────── serial source consumers ─────┘
                              │
                    resample/mix/clamp
                       16 kHz mono Float32
                              │
                    append + synchronize WAV
                              │
                     CanonicalAudioBlock
                              │
                source-specific raw disk spool
                              │
                  per-source offline Silero VAD
                              │
             14 s windows, 1.5 s overlap, 30 s cap
                              │
               source-specific speech disk spool
                              │
                selected offline Parakeet engine
                              │
                   validate + de-duplicate seams
                              │
                 stable partial/final transcript rows
                              │
                  small snapshots polled by SwiftUI
```

The batch path reads the same durable WAV files in bounded 14-second chunks,
dispatches the earliest next chunk on the shared session timeline, validates
engine output, and merges results deterministically.

## Milestone 1 review: audio capture

### Implemented

- A native macOS SwiftUI app targeting macOS 14.4 or newer and arm64 only.
- Independent microphone and system-audio services.
- A Core Audio global process tap that excludes Scribe's own process.
- A private aggregate device with a physical output device as the main
  subdevice and the process tap attached as a drift-compensated subtap.
- Direct aggregate-device reads through
  `AudioDeviceCreateIOProcIDWithBlock`; `AVAudioEngine` is not incorrectly used
  for the tap-backed aggregate.
- A separate `AVAudioEngine` microphone input tap.
- A preallocated C17-atomic single-producer/single-consumer ring per source.
- Allocation-free microphone planar mixdown in the C realtime primitive.
- Serial non-realtime consumers for resampling and disk writes.
- `AVAudioConverter`-backed conversion to canonical 16 kHz mono Float32.
- Sample clamping to `[-1, 1]`.
- Independent `microphone.wav` and `system.wav` files.
- WAV header length synchronization after each append so a completed append
  leaves a readable file even before orderly close.
- A versioned `capture-session.json` containing safe relative paths and
  monotonic track offsets.
- Recovery state and restart paths for route/device changes, tap or aggregate
  death, sample-rate changes, Core Audio restart, sleep, and wake.
- First-run microphone and system-audio permission UI with actionable errors
  and links to the correct System Settings panes.
- A no-file system-audio permission probe using a disposable process tap.

### Important design properties

The realtime callbacks do not log, allocate application buffers, acquire Swift
locks, write files, or run inference. They only feed fixed-capacity ring
buffers. Backpressure at this boundary is explicit: ring saturation is treated
as an actionable failure rather than overwriting unread samples silently.

Microphone capture starts before the global process tap. This ordering prevents
the system track from capturing Scribe's own microphone-processing activity and
allows deterministic cleanup if system capture fails to start.

System-audio authorization has no public Core Audio preflight API. The app
therefore displays only `Not checked`, `Allowed (last checked)`, or `Denied`
based on a real attempt. It does not inspect the TCC database or use private
frameworks.

### Verification coverage

- Ring FIFO ordering, wraparound, overflow behavior, clearing, channel mixdown,
  clamping, and concurrent producer/consumer preservation.
- Resampling a known sine sweep from 48 kHz to 16 kHz.
- Canonical timing and contiguous block commit behavior.
- WAV format, clamping, synchronized output, and refusal to overwrite.
- Aggregate-device dictionary composition and OSStatus formatting.
- Microphone permission paths.
- System permission state and privacy links.
- Dual-track startup and partial-failure cleanup.
- Capture manifest round-trip and unsafe-path rejection.

### Still requiring manual acceptance

- Simultaneous real microphone speech and browser/system playback.
- Confirmation that the two WAV tracks remain isolated, allowing for physical
  acoustic bleed when speakers rather than headphones are used.
- Real default-output changes during recording.
- Headphone plug/unplug behavior.
- Sleep/wake recovery.
- Real Core Audio daemon/tap failure behavior.
- Confirmation of final WAV compatibility in an external audio editor.

The implementation and unit coverage are present, but these hardware and TCC
behaviors cannot be considered fully accepted until exercised on the target
Mac.

## Milestone 2 review: offline batch transcription

### Engine boundary

`SpeechPipeline` defines a `Sendable` `TranscriptionEngine` contract with:

- stable engine identity;
- streaming and network capability metadata;
- supported languages;
- asynchronous prepare, transcribe, finish, and unload operations;
- source-attributed audio chunks;
- source-attributed transcript segments;
- optional confidence, speaker ID, and word timing.

The batch coordinator owns engine lifecycle and guarantees `unload()` after
success or any preparation, transcription, validation, or finish failure.

### Parakeet implementation

- Parakeet TDT 0.6B v3 is exposed as the multilingual option.
- Parakeet TDT 0.6B v2 is exposed as the English-only option.
- FluidAudio is pinned exactly at version `0.15.5`, revision
  `19600a485baa4998812e4654b70d2bab8f2c9949`.
- Model acquisition and inference are separate operations.
- Download is initiated only by an explicit UI action.
- Engine preparation requires a complete compiled cache and enables
  FluidAudio offline mode before local Core ML loading.
- Missing or incomplete models fail with actionable errors rather than
  initiating an implicit network request.
- FluidAudio result types stay behind a `Sendable` backend adapter.
- Chunk-local token timing is aggregated into words, clamped to the original
  unpadded audio duration, and shifted onto the shared meeting timeline.

### Bounded batch processing

Each WAV is read through an actor-owned `AVAudioFile` in at most 14-second
chunks. A one-hour meeting is not loaded into one `[Float]`. The next chunk is
selected by shared-session start time, and ties use deterministic source
ordering. Returned source and timing metadata are validated before publication.

### UI behavior

The app currently provides:

- Parakeet v3/v2 selection;
- visible availability and download progress;
- explicit download action;
- batch-transcription progress;
- an interleaved timeline with `You` and `Others` labels;
- actionable missing-model and inference failures.

### Still requiring manual acceptance

- Download and compile each Parakeet option on the target Apple Silicon Mac.
- Disconnect networking and confirm successful local transcription.
- Transcribe a real dual-source session and inspect early timeline offset
  ordering.
- Run the opt-in golden test with a known WAV/reference transcript and evaluate
  the configured word-error-rate tolerance.

The normal test suite deliberately skips the real Core ML golden test so CI and
ordinary local tests cannot download or load a large model unexpectedly.

## Milestone 3 review: live transcription

### Durable fan-out and raw transport

Canonical live blocks are emitted only after the same samples have been
appended and synchronized in the corresponding WAV. Live failure can therefore
disable the live consumer without invalidating the recording.

`LiveAudioTransport` serializes each source into its own append-only spool. It
holds counters and at most the current block rather than an unbounded audio
array. Backlog drives visible `keeping up`, `buffering to disk`, and
`catching up` states with hysteresis.

The append-only reader is gated by an actor-owned per-source pending count.
This fixes a discovered race in which polling an empty file before its first
append could leave a reader behaving as though it remained at end-of-file.
Tests cover the pre-append polling case directly and through the full live path.

### Per-source Silero VAD

- Silero model acquisition is an explicit user action.
- Recording-time preparation manually loads the compiled Core ML model in
  offline mode.
- Microphone and system tracks have independent recurrent VAD state.
- Entry and exit thresholds are 0.85 and 0.70.
- Minimum speech is 150 ms.
- Trailing silence is 750 ms.
- Boundary padding is 100 ms.
- Continuous speech has an exact 30-second sample ceiling.
- Long active speech can emit work before the final speech boundary.

### Windowing and seam handling

Speech is emitted in windows of at most 14 seconds, stepped by 12.5 seconds for
approximately 1.5 seconds of overlap. A final tail is marked explicitly.
Speech windows are persisted to per-source append-only files until the ASR
consumer drains them.

`TranscriptOverlapDeduplicator` compares only timeline-adjacent results from
the same source. It prefers timed word boundaries and falls back to normalized
text tokens. It removes the longest suffix/prefix match rather than assuming a
fixed number of repeated words.

### Live Parakeet consumer

`LiveTranscriptionPipeline` owns one explicitly selected engine for the
session. It round-robins the two source spools, validates source attribution and
timing, performs inference outside the main actor, removes overlap seams, and
publishes rows sorted on the shared timeline.

Each source/segment pair has a stable row identity. Nonfinal windows extend a
partial row; the final window replaces that same row with `isFinal = true`.
This keeps SwiftUI updates small and prevents overlap windows from appearing as
separate duplicate transcript rows.

Three pending ASR windows enter `buffering to disk`; the state remains
`catching up` until one or fewer remain. The app never silently changes the
selected model. If Parakeet is missing or fails, WAV capture and VAD continue
and the UI reports recording-only behavior.

### Main-actor behavior

Capture, file I/O, VAD, Core ML preparation/inference, de-duplication, and live
row assembly are actor-isolated outside the main actor. The main-actor view
model polls small immutable state and row snapshots at 250 ms intervals. The
transcript list updates by stable identity.

### Latency limitation

FluidAudio's current Parakeet adapter is window-based rather than incremental
token streaming. Short phrases appear as final rows after their speech boundary.
Continuous speech first produces a partial only after a complete 14-second
window plus overlap is available, approximately 15.5 seconds. The UI is live,
but it is not low-latency word-by-word transcription.

### Verification coverage

- Raw spool file round-trip and source isolation.
- Backpressure hysteresis and fail-closed continuity validation.
- One-hour/two-source transport simulation with one-block peak memory.
- Independent VAD state and bounded one-hour silence processing.
- Exact continuous-speech ceiling.
- Partial window emission before a long-speech boundary.
- 14-second windows and 1.5-second overlap.
- Source-aware word and token seam de-duplication.
- Stable partial-to-final row replacement.
- ASR backpressure hysteresis.
- Source-attribution mismatch rejection.
- Raw transport to mock VAD to real speech-window spool to mock ASR
  integration.
- Virtual one-hour/two-source ASR run with one bounded window in flight.

### Still requiring manual acceptance

- Run live transcription with downloaded Silero and Parakeet models while
  physically offline.
- Alternate microphone and system speech and verify row attribution.
- Confirm partial/final replacement during more than 16 seconds of continuous
  speech.
- Confirm the 30-second ceiling with real inference.
- Observe UI smoothness under real Core ML and Core Audio load.
- Create genuine ASR lag and observe disk-buffering/catch-up transitions.
- Stop with queued ASR work and confirm orderly drain and valid WAV output.

## Concurrency and safety review

All targets use Swift 6 language mode and complete strict concurrency checking.
The Xcode project explicitly sets:

```text
ARCHS = arm64
MACOSX_DEPLOYMENT_TARGET = 14.4
SWIFT_VERSION = 6.0
SWIFT_STRICT_CONCURRENCY = complete
ENABLE_APP_SANDBOX = NO
ENABLE_HARDENED_RUNTIME = YES
```

The main intentional escape hatches are narrow:

- `FloatRingBuffer` is `@unchecked Sendable` because synchronization is
  implemented in the underlying C atomic SPSC structure.
- Core Audio graph ownership crosses callback boundaries under a documented
  lifetime invariant.
- Raw and speech spool storage wrappers are `@unchecked Sendable`, but each is
  exclusively owned and invoked by one actor.

These are reasonable uses of unchecked conformance, but they remain areas where
future refactoring must preserve single-owner and callback-lifetime invariants.

The current static audit found no `try!`, forced `as!` casts, `fatalError`,
`preconditionFailure`, TODO/FIXME markers, or empty `catch` blocks in Scribe
Swift sources and tests. Errors are generally localized and surfaced through
explicit UI state. Realtime sinks that cannot throw fail closed by changing
pipeline state and preserving the already-written WAV.

## Privacy and security review

### Current privacy posture

- No telemetry or analytics SDK is present.
- No crash-reporting service is present.
- No cloud transcription or intelligence client exists yet.
- Recording and inference paths do not initiate network activity.
- Model acquisition requires explicit user actions.
- Models, recordings, and manifests are stored locally under Scribe's
  Application Support directory.
- API keys and cloud opt-ins do not exist yet because Milestone 6 has not
  started.
- Actual macOS privacy grants remain owned by TCC; Scribe stores only the
  first-run flag and last-observed system-audio state in `UserDefaults`.

### Entitlements and distribution

The app declares microphone and audio-capture usage strings plus the audio-input
entitlement. It is intentionally non-sandboxed because private aggregate-device
creation and the current process-tap architecture are not treated as reliably
sandbox-compatible. Hardened runtime is enabled for the app configurations.

This is appropriate for direct distribution but is not a Mac App Store-ready
security profile. Store distribution would require an explicit reassessment of
aggregate-device and process-tap behavior under App Sandbox.

### Model integrity limitation

Current Parakeet and Silero availability checks verify the expected local cache
shape before inference, but Scribe does not yet own a general checksum manifest
or resumable downloader. Full checksum verification, download lifecycle, and
model deletion belong to Milestone 4.

## Data durability and disk review

### Durable data

Each completed capture stores:

```text
~/Library/Application Support/Scribe/Sessions/<UUID>/microphone.wav
~/Library/Application Support/Scribe/Sessions/<UUID>/system.wav
~/Library/Application Support/Scribe/Sessions/<UUID>/capture-session.json
```

The WAV files are the current durable source of truth. Their length headers are
updated after appends, improving survivability if the process exits after a
successful write. The manifest contains paths and timing metadata, not audio or
transcript content.

### Transient data

During a live session Scribe creates:

```text
LiveSpool/<source>.livepcm
LiveSpeechWindows/<source>.speechwindows
```

These files are removed after orderly pipeline completion or handled startup
failure. They are not a recovery database and may remain after a crash until a
future cleanup/recovery path is implemented.

### Capacity implications

Two canonical 16 kHz mono Float32 WAV tracks require approximately 439 MiB per
hour in total. The raw live spool temporarily duplicates approximately the same
amount. With continuous speech, overlapping speech-window records can add up to
roughly another 490 MiB per hour. Peak working disk can therefore approach
about 1.3 GiB per hour before the transient spools are removed, while the final
retained WAVs remain about 439 MiB per hour.

The spool files are append-only for the session; consumed records are not
compacted while recording. There is currently no free-space threshold,
preflight estimate, quota, or emergency low-disk stop. This is a material
operational risk for long recordings and should be addressed no later than the
storage/hardening work.

### Build artifact size

The workspace currently contains approximately 2.8 GB in `.build`, including
multiple historical Xcode derived-data directories and SwiftPM products. These
are disposable and regenerable. They should not be shipped or committed. Model
weights introduced in Milestone 4 should remain under Application Support, not
inside the project or app bundle.

## UI review

The current SwiftUI app supports the implemented foundation rather than the
final Granola-style product. It includes:

- first-run permission setup;
- per-permission status and recovery guidance;
- record/stop controls;
- per-source capture and recovery state;
- reveal-WAVs action;
- Parakeet selection and explicit download progress;
- Silero download state;
- raw, VAD, and live-ASR pipeline status;
- batch transcription progress;
- interleaved batch/live transcript rows;
- visible partial/final live-row badges.

Not yet implemented:

- session database and searchable session list;
- primary Markdown notes editor;
- persisted transcript rows;
- collapsed/expandable transcript pane;
- menu bar controls;
- audio playback and click-to-seek;
- calendar suggestions;
- model-management Settings screen with disk/RAM accounting;
- Whisper choices;
- accessibility and UI automation pass.

The existing UI is appropriate as a functional engineering shell, not as the
final Milestone 5 product surface.

## Automated test inventory

| Suite | Tests | Result |
|---|---:|---|
| AudioResamplerTests | 3 | Pass |
| CanonicalAudioBlockTests | 2 | Pass |
| CaptureSessionManifestTests | 3 | Pass |
| CoreAudioSupportTests | 3 | Pass |
| DualTrackRecordingCoordinatorTests | 3 | Pass |
| Float32WAVWriterTests | 2 | Pass |
| FloatRingBufferTests | 7 | Pass |
| MicrophoneCaptureServiceTests | 3 | Pass |
| SystemAudioPermissionTests | 2 | Pass |
| CanonicalWAVChunkReaderTests | 2 | Pass |
| BatchTranscriptionPipelineTests | 3 | Pass |
| ParakeetTranscriptionEngineTests | 6 | Pass |
| ParakeetGoldenFileTests | 1 | Skipped unless explicitly enabled |
| SileroVADModelStoreTests | 1 | Pass |
| LiveAudioTransportTests | 6 | Pass |
| LiveSpeechPipelineTests | 5 | Pass |
| TranscriptOverlapDeduplicatorTests | 4 | Pass |
| LiveTranscriptionPipelineTests | 5 | Pass |
| **Total** | **61** | **60 pass, 1 intentional skip, 0 failures** |

### What the tests do not prove

- Real TCC prompt and denial behavior across macOS versions.
- Real process-tap reliability under hardware churn.
- Acoustic track isolation.
- Real Parakeet accuracy or performance.
- Real Silero boundary quality on varied rooms and languages.
- Core ML thermal, CPU, GPU/ANE, and memory behavior over a wall-clock hour.
- UI frame pacing during a real recording.
- Crash recovery across arbitrary termination points.
- Accessibility and keyboard navigation.

The soak tests are deterministic bounded-memory simulations. They demonstrate
data-structure bounds and pipeline behavior, not Instruments-level production
performance. The latter remains a Milestone 8 acceptance item.

## Technical decisions that have worked well

1. **WAV-first live fan-out.** Optional live features cannot corrupt the
   durable recording.
2. **Source identity throughout the pipeline.** Attribution is reliable before
   diarization and does not depend on post-hoc guessing.
3. **Monotonic track offsets.** Sequential capture startup does not silently
   distort transcript ordering.
4. **Direct Core Audio IOProc for system audio.** The implementation avoids the
   known `AVAudioEngine` aggregate-device trap.
5. **Explicit acquisition versus offline preparation.** Missing models cannot
   unexpectedly trigger network access during recording or transcription.
6. **Fixed memory boundaries plus disk backpressure.** Long sessions do not
   accumulate unbounded `[Float]` queues.
7. **Stable live-row identity.** Partial/final replacement maps cleanly to
   SwiftUI and overlap de-duplication.
8. **Actor-owned lifecycle cleanup.** Large engines and file handles have clear
   serial owners.
9. **Fail-closed validation.** Source mismatches, timeline errors, discontinuity,
   and malformed spool records become explicit failures.

## Findings and risks

### High priority before calling the app production-ready

1. **Complete real-device acceptance.** Automated coverage cannot substitute
   for process-tap, TCC, device-route, sleep/wake, and source-isolation testing.
2. **Add disk-capacity protection.** Long sessions can use roughly 1.3 GiB per
   hour while live spools exist, and no low-disk policy currently protects the
   recording.
3. **Persist finalized transcript data.** A crash currently leaves the WAVs in
   a comparatively recoverable state but loses in-memory live transcript rows.
4. **Implement session discovery and crash cleanup/recovery.** Orphaned spool
   directories and recoverable WAV sessions are not surfaced on next launch.

### Medium priority

1. **Consolidate model lifecycle.** Parakeet and Silero stores are separate
   milestone-specific implementations rather than one catalogue/downloader.
2. **Add checksums and resumable transfer semantics.** Cache-shape validation is
   useful but not a general integrity manager.
3. **Measure real inference behavior.** Virtual one-hour tests do not provide
   CPU, RAM, thermal, energy, or UI frame-time numbers.
4. **Add UI automation.** The view model has unit-testable dependencies, but the
   current suite does not drive the actual SwiftUI permission/record/model flow.
5. **Plan App Store implications.** The deliberate non-sandbox architecture is
   compatible with direct distribution, not automatically with store rules.

### Low priority and documentation/tooling notes

1. SwiftPM reports FluidAudio's unhandled `benchmark.md`; Xcode app builds are
   warning-free. This should be revisited when FluidAudio is upgraded rather
   than patched in `.build`.
2. `LM_FILTER_WARNINGS = YES` suppresses the irrelevant automatic App Intents
   metadata warning for targets that do not use App Intents. Compiler and
   linker diagnostics remain visible.
3. Historical build directories account for almost all workspace size and can
   be cleaned without deleting source or user recordings.
4. A sentence in the batch architecture section still describes Milestone 3
   in future tense even though the separate live path is now implemented. This
   is cosmetic and should be corrected during the next documentation pass.

## Readiness for Milestone 4

The foundation is ready for the model-manager milestone. The engine protocol,
offline preparation boundary, application-support paths, model selection UI,
and unload invariants already provide useful seams.

Milestone 4 should begin by introducing a real `ModelManager` module rather
than extending `ParakeetModelStore` indefinitely. The recommended order is:

1. Define the general model descriptor and catalogue.
2. Centralize application-support model paths.
3. Abstract download, progress, pause/resume/cancel, and checksum verification.
4. Add disk accounting and physical-RAM safety evaluation.
5. Move Parakeet and Silero under that manager without breaking offline
   inference.
6. Add and pin the approved WhisperKit dependency.
7. Implement the required Whisper catalogue and adapter.
8. Add a single-resident-large-model coordinator.
9. Replace milestone-specific model controls with the model-management UI.
10. Verify switching and comparison with mocks first, then opt-in real models.

No Milestone 4 implementation was performed as part of this review.

## Acceptance status at this handoff

| Milestone | Code | Automated tests | Xcode build | Manual target-Mac acceptance |
|---|---|---|---|---|
| 1 — Audio capture | Implemented | Pass | Pass | Pending |
| 2 — Batch Parakeet | Implemented | Pass; real golden opt-in skipped | Pass | Pending |
| 3 — Live VAD/ASR | Implemented | Pass, including virtual soaks | Pass | Pending |
| 4 — Model manager/Whisper | Not started | Not applicable | Not applicable | Not applicable |

## Key files

### Application

- `ScribeApp/MeetingRecorderViewModel.swift`
- `ScribeApp/ContentView.swift`
- `ScribeApp/Info.plist`
- `ScribeApp/Scribe.entitlements`

### Audio capture

- `Sources/AudioCapture/MicrophoneCaptureService.swift`
- `Sources/AudioCapture/SystemAudioCaptureService.swift`
- `Sources/AudioCapture/CoreAudioSystemTapGraph.swift`
- `Sources/AudioCapture/DualTrackRecordingCoordinator.swift`
- `Sources/AudioCapture/CanonicalAudioFileConsumer.swift`
- `Sources/AudioCapture/Float32WAVWriter.swift`
- `Sources/AudioCapture/AudioResampler.swift`
- `Sources/AudioCapture/CaptureSessionManifest.swift`
- `Sources/CAudioRingBuffer/CAudioRingBuffer.c`

### Speech pipeline

- `Sources/SpeechPipeline/SpeechTypes.swift`
- `Sources/SpeechPipeline/ParakeetTranscriptionEngine.swift`
- `Sources/SpeechPipeline/BatchTranscriptionPipeline.swift`
- `Sources/SpeechPipeline/LiveAudioTransport.swift`
- `Sources/SpeechPipeline/SileroVoiceActivityDetector.swift`
- `Sources/SpeechPipeline/LiveSpeechPipeline.swift`
- `Sources/SpeechPipeline/TranscriptOverlapDeduplicator.swift`
- `Sources/SpeechPipeline/LiveTranscriptionPipeline.swift`

### Documentation and verification

- `README.md`
- `ARCHITECTURE.md`
- `DECISIONS.md`
- `Tests/AudioCaptureTests/`
- `Tests/SpeechPipelineTests/`

## Final review conclusion

Milestones 1 through 3 form a coherent and defensible technical foundation.
The code is organized around the correct failure hierarchy: preserve captured
audio first, preserve source and timeline identity second, and treat live VAD
and ASR as recoverable optional layers. Memory bounds are explicit, offline
behavior is intentional, and the automated evidence is strong for deterministic
logic.

The main caveat is acceptance, not hidden completeness: real hardware/model
testing, persistent session/transcript storage, disk exhaustion handling, and
crash recovery remain open. With those limitations stated plainly, the project
is ready to proceed to Milestone 4 after explicit approval.
